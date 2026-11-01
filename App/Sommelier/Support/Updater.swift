// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import Observation
import SommelierKit
import Sparkle

/// App updates through Sparkle, with the player's consent. Checks are always on (daily, not a setting): when Sparkle
/// finds a version it tells us, the sidebar says so, and nothing is downloaded or installed until the player chooses
/// "Update". Sparkle verifies each update's EdDSA signature against SUPublicEDKey before installing it.
///
/// Sparkle's own windows (with "Skip This Version") are replaced by this user driver: the sidebar note
/// (`UpdateBadge`) and the "What's new" sheet (`UpdateSheet`). An update the appcast marks critical can't be put off.
@MainActor @Observable
final class Updater: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    struct Available: Equatable {
        var version: String
        var notes: String          // HTML from the appcast
        var critical: Bool
        /// The archive's size from the appcast, 0 when it doesn't say.
        var bytes: Int64 = 0
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case failed
        /// Found; waiting for the player.
        case available(Available)
        case downloading(version: String, progress: Double?)
        case installing(version: String)
        /// Downloaded and verified while a game was running; restarts when the player says so.
        case readyToRestart(version: String)
    }

    private(set) var state: State = .idle
    /// The "What's new" sheet (`UpdateSheet`): it pops up once per app run when an update is found and no game is
    /// running, and again from the toolbar reminder or the menu bar's "Update…".
    var showingDetails = false
    /// Bytes of the update downloaded so far, and of the whole archive, for the sheet's progress line.
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    /// When "Later" was last pressed, so the toolbar reminder lands with a little bounce.
    private(set) var putOff: Date?

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var restartReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var poppedUp = false
    /// Whether a game is running (a restart then waits for the player).
    @ObservationIgnored var isPlaying: () -> Bool = { false }

    /// Each step of an update, in Logs/Update.log: what Sparkle asked, what the app answered, how long quitting took.
    nonisolated static func log(_ text: String) {
        guard let file = logFile else { return }
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 200_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: line)
        } else { try? line.write(to: file) }
    }
    nonisolated(unsafe) static var logFile: URL? = {
        let logs = Paths().logs
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Update.log")
    }()

    override init() {
        super.init()
        #if DEBUG
        // SOMMELIER_DEBUG_UPDATE=big|small shows the sheet for a made-up release (for design checks).
        if let kind = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_UPDATE"] {
            state = .available(kind == "big"
                ? Available(version: "1.4", notes: "<ul><li>Turbo: more frames in DirectX 10–11 games.</li><li>The library can be browsed with a controller.</li><li>Games no longer close after the intro.</li></ul>", critical: false, bytes: 48_000_000)
                : Available(version: "0.1.4", notes: "<p>Fixes: GOG installs work again; Epic downloads no longer stop at 99%.</p>", critical: false, bytes: 6_000_000))
            showingDetails = true
            return
        }
        // Development builds would update themselves from the local API: only when asked to.
        guard ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_UPDATES"] == "1" else { return }
        #endif
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater.automaticallyChecksForUpdates = true      // not a setting: everyone hears about updates
        updater.automaticallyDownloadsUpdates = false     // nothing downloads before the player agrees
        try? updater.start()
        self.updater = updater
        Self.log("updater started, app \(currentVersion)")
    }

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// "Check Now": shows what's waiting, or asks the appcast.
    func check() {
        switch state {
        case .available: showingDetails = true
        case .checking, .downloading, .installing, .readyToRestart: break
        default:
            guard let updater else { settle(.upToDate); return }
            updater.checkForUpdates()
        }
    }

    /// The player chose "Update": download, verify, install and relaunch. The sheet stays open and shows the
    /// progress in place of its buttons.
    func update() {
        guard case .available(let item) = state, let reply = foundReply else { return }
        Self.log("player chose Update to \(item.version)")
        foundReply = nil
        downloadedBytes = 0; totalBytes = item.bytes
        state = .downloading(version: item.version, progress: nil)
        reply(.install)
    }

    /// "Later": the sheet goes away into the toolbar reminder, which stays until the update is installed. A critical
    /// update has no "Later".
    func later() {
        showingDetails = false
        putOff = Date()
    }

    /// Whether the toolbar reminder shows: an update waits, or is on its way.
    var reminderVersion: String? {
        switch state {
        case .available(let item): item.version
        case .downloading(let version, _), .installing(let version), .readyToRestart(let version): version
        default: nil
        }
    }

    /// A big release (a new major or minor version) gets a short list and the falling grapes; a small one, one line.
    static func isMajorRelease(_ version: String, over current: String) -> Bool {
        func head(_ v: String) -> [Int] { v.split(separator: ".").prefix(2).map { Int($0) ?? 0 } + [0, 0] }
        return Array(head(version).prefix(2)) != Array(head(current).prefix(2))
    }

    /// Restarts into an update that finished downloading during a game.
    func restart() {
        guard let reply = restartReply else { return }
        restartReply = nil
        if case .readyToRestart(let version) = state { state = .installing(version: version) }
        reply(.install)
    }

    private func settle(_ new: State) {
        state = new
        guard new == .upToDate || new == .failed else { return }
        Task {                                            // the note fades after a few seconds
            try? await Task.sleep(for: .seconds(4))
            if state == new { state = .idle }
        }
    }

    private var currentUpdateVersion: String {
        switch state {
        case .available(let a): a.version
        case .downloading(let v, _), .installing(let v), .readyToRestart(let v): v
        default: ""
        }
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["SOMMELIER_UPDATE_FEED"]      // another appcast while developing
    }

    // MARK: SPUUserDriver (Sparkle calls these on the main thread)

    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated { state = .checking }
    }

    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state userState: SPUUserUpdateState,
                                     reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let found = Available(version: appcastItem.displayVersionString, notes: appcastItem.itemDescription ?? "",
                              critical: appcastItem.isCriticalUpdate, bytes: Int64(appcastItem.contentLength))
        let informational = appcastItem.isInformationOnlyUpdate
        nonisolated(unsafe) let reply = reply
        MainActor.assumeIsolated {
            Self.log("found \(found.version)\(informational ? " (informational)" : "")")
            if informational { reply(.dismiss); state = .idle; return }
            foundReply = reply
            state = .available(found)
            #if DEBUG
            // SOMMELIER_DEBUG_AUTOUPDATE=<seconds>: a check without clicking, after the app has settled.
            if let wait = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_AUTOUPDATE"].flatMap(Double.init) {
                Task { try? await Task.sleep(for: .seconds(wait)); self.update() }
                return
            }
            #endif
            // Once per run, unasked, only when no game is running; the toolbar reminder holds it otherwise.
            if found.critical || userState.userInitiated || (!poppedUp && !isPlaying()) {
                poppedUp = true
                showingDetails = true
            }
        }
    }

    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    nonisolated func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        MainActor.assumeIsolated { if state == .checking { settle(.upToDate) } }
    }

    nonisolated func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        Self.log("error: \(error.localizedDescription)")
        MainActor.assumeIsolated {
            switch state {
            case .checking, .downloading, .installing: settle(.failed)
            default: break
            }
        }
    }

    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            downloadedBytes = 0
            state = .downloading(version: currentUpdateVersion, progress: nil)
        }
    }

    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { if expectedContentLength > 0 { totalBytes = Int64(expectedContentLength) } }
    }

    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated {
            downloadedBytes += Int64(length)
            guard totalBytes > 0 else { return }
            state = .downloading(version: currentUpdateVersion, progress: min(1, Double(downloadedBytes) / Double(totalBytes)))
        }
    }

    nonisolated func showDownloadDidStartExtractingUpdate() {
        Self.log("extracting")
        MainActor.assumeIsolated { state = .installing(version: currentUpdateVersion) }
    }

    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}

    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        nonisolated(unsafe) let reply = reply
        MainActor.assumeIsolated {
            Self.log("ready to install; game running: \(isPlaying())")
            // The player already chose to update; only a running game makes the restart wait for them.
            if isPlaying() {
                restartReply = reply
                state = .readyToRestart(version: currentUpdateVersion)
            } else {
                state = .installing(version: currentUpdateVersion)
                reply(.install)
            }
        }
    }

    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                                          retryTerminatingApplication: @escaping () -> Void) {
        Self.log("installing; app terminated: \(applicationTerminated)")
        MainActor.assumeIsolated { state = .installing(version: currentUpdateVersion) }
    }

    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        Self.log("installed; relaunched: \(relaunched)")
        acknowledgement()
    }

    nonisolated func showUpdateInFocus() {
        MainActor.assumeIsolated { if case .available = state { showingDetails = true } }
    }

    nonisolated func dismissUpdateInstallation() {
        Self.log("dismissed")
        MainActor.assumeIsolated {
            switch state {
            case .available, .readyToRestart, .upToDate, .failed: break     // still shown (or fading by itself)
            default: state = .idle
            }
        }
    }
}
