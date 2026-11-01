// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit

/// How play sessions went, sent to the compatibility database when the player allows it: Sommelier tells by itself
/// whether a game started, crashed or ran (and for how long), without asking after each game. Asked once; a switch
/// in Settings after that. Reports and shader sharing share that one answer.
extension AppModel {
    var sharesReports: Bool { settings.shareReports == true }

    /// The one-time question, right at the first launch.
    var needsSharingConsent: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_CONSENT"] == "1", !sharingConsentShown { return true }
        #endif
        return settings.shareReports == nil
    }

    var sharesHardware: Bool { sharesReports && settings.shareHardware == true }

    func answerSharing(_ allow: Bool, hardware: Bool) {
        sharingConsentShown = true
        settings.shareReports = allow
        settings.usageNoticeShown = true            // the consent window lists it already
        if !allow { leaveInstallCount() }
        settings.shareHardware = allow && hardware
        if settings.shareShaders == nil { settings.shareShaders = allow }
    }

    /// "Delete my data": the server forgets what this Mac sent, and the next report starts under a new random id.
    /// Nothing sent yet (no id) is a success with nothing to do.
    func deleteSentData() async -> Bool {
        leaveInstallCount()
        guard let client = settings.reportClientID else { return true }
        guard await reporter.forget(client: client) else { return false }
        settings.reportClientID = nil
        return true
    }

    var reporter: CompatibilityReporter {
        CompatibilityReporter(paths: paths, clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    /// Reports a session: `.ran` after a long enough play, `.crashed` or `.didNotStart` from a failed launch.
    /// Mac versions aren't reported: the database is about running Windows games.
    func reportSession(_ game: Game, outcome: CompatibilityReport.Outcome, seconds: TimeInterval?, since: Date) {
        guard sharesReports, !game.isNative else { return }
        let sharesHardware = sharesHardware
        let client: String
        if let id = settings.reportClientID { client = id } else { client = UUID().uuidString.lowercased(); settings.reportClientID = client }
        let steamAppID = game.store == .steam ? nil : info[game.id]?.steamAppID
        let engine = engine(for: game.store.bottleKind)
        let profile = profile(for: game)
        let settings = CompatibilityReport.Settings(
            profile: profile, applied: library.userData[game.id]?.appliedFixes ?? [],
            shadersFromOthers: library.userData[game.id]?.shadersDecanted != nil)
        let reporter = reporter
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        let folder = game.installPath
        let mods = modsInPlay(game)                 // a flag only: which mods never leaves the Mac
        Task {
            // DXMT's quiet frame counter, for a session that ran (games on D3DMetal aren't measured yet).
            let fps = outcome == .ran ? await Task.detached { FrameStats.session(in: bottle, since: since, gameFolder: folder) }.value : nil
            var backend = profile.backend
            if let engine { backend = await resolvedBackend(for: game, profile: profile, engine: engine) }
            // Whether it asked for HDR: known only on DXMT, and only when its counter wrote.
            let samples = backend == .dxmt ? await Task.detached { FrameStats.samples(in: bottle, since: since, gameFolder: folder) }.value : []
            let hdr: Bool? = samples.isEmpty ? nil : samples.contains { $0.hdr != 0 }
            let report = CompatibilityReport(
                client: client,
                game: .init(store: game.store.rawValue, id: game.storeID, title: game.title, steamAppID: steamAppID),
                outcome: outcome,
                minutes: seconds.map { Int($0 / 60) },
                fps: fps,
                system: sharesHardware ? MacSystem.current : nil,
                sommelier: .init(app: reporter.clientVersion, engine: engine?.version, backend: backend.rawValue),
                settings: settings, hdr: hdr, mods: mods)
            await Task.detached { await reporter.send(report) }.value
        }
    }

    /// Reports that couldn't go earlier (offline, service down).
    func sendPendingReports() {
        guard sharesReports else { return }
        let reporter = reporter
        Task.detached(priority: .background) { await reporter.sendPending() }
    }
}
