// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
@preconcurrency import GameController
@preconcurrency import ScreenCaptureKit
import SommelierKit
import SwiftUI

/// Clips: keeps the last stretch of the game being played in memory and turns it into a clip on a key press, a
/// pad button, or when the game crashes. One `ClipCapture` per game running; nothing is written to the disk until
/// a clip is saved. The game is never touched: the window is only looked at.
@MainActor @Observable
final class ClipRecorder {
    static let shared = ClipRecorder()

    enum Access { case unknown, allowed, denied }

    /// Whether macOS lets Sommelier record the screen, as far as it has been tried.
    private(set) var access: Access = .unknown
    /// A recording ended on its own in the last game (the window changed too often, the Mac slept).
    private(set) var stoppedEarly = false
    /// Games being recorded now.
    private(set) var recording: Set<String> = []
    /// The clips in the folder, newest first.
    private(set) var clips: [Clip] = []
    private(set) var freeSpaceLow = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var captures: [String: ClipCapture] = [:]
    @ObservationIgnored private var endedAt: [String: Date] = [:]
    @ObservationIgnored private var starting: Set<String> = []
    @ObservationIgnored private var restarts: [String: Int] = [:]
    @ObservationIgnored private var windowGone: [String: Int] = [:]
    @ObservationIgnored private var accessChecked = false
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var hotKeyHandler: EventHandlerRef?
    @ObservationIgnored private var registeredKey: (Int, Int)?
    @ObservationIgnored private var padHold: Task<Void, Never>?
    @ObservationIgnored private var saving = false
    @ObservationIgnored private let toast = ClipToastWindow()
    @ObservationIgnored private var hinted: Set<String> = []
    @ObservationIgnored private let store = ClipStore(folder: ClipStore.standardFolder())

    var folder: URL { store.folder }

    var settings: ClipSettings {
        get { model?.settings.clips ?? ClipSettings() }
        set { model?.settings.clips = newValue }
    }

    func start(model: AppModel) {
        self.model = model
        guard timer == nil else { return }
        ClipLog.file = model.paths.logs.appendingPathComponent("Clips.log")
        ClipCapture.log = { ClipLog.note($0) }
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleeping() }
        }
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let pad = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.watch(pad) }
        }
        GCController.controllers().forEach(watch)
    }

    // MARK: The list

    func reload() {
        let store = store
        Task.detached(priority: .utility) {
            let all = store.clips()
            await MainActor.run { ClipRecorder.shared.clips = all }
        }
    }

    func setFavorite(_ on: Bool, _ clip: Clip) { store.setFavorite(on, for: clip); reload() }
    func rename(_ clip: Clip, to name: String) { store.rename(clip, to: name); reload() }
    func delete(_ clip: Clip) {
        let store = store
        Task.detached { store.delete(clip); await MainActor.run { ClipRecorder.shared.reload() } }
    }

    func removeAutomaticClips() {
        let store = store
        let automatic = clips.filter { $0.isAutomatic && !$0.favorite }
        Task.detached { automatic.forEach { store.delete($0) }; await MainActor.run { ClipRecorder.shared.reload() } }
    }

    var totalBytes: Int { ClipStore.totalBytes(clips) }

    // MARK: Turning it on

    /// The player turned clips on: macOS asks now (once), not at some later moment in a game.
    func requestAccess() {
        accessChecked = true
        if CGPreflightScreenCaptureAccess() { access = .allowed; return }
        _ = CGRequestScreenCaptureAccess()
        Task {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                access = .allowed
            } catch { access = .denied }
        }
    }

    /// Whether macOS lets Sommelier record, looked up once when the app starts (quietly: no request on screen).
    /// macOS keeps this answer until the app restarts, as it does for every app, so a permission given or taken
    /// away later shows after a restart, which System Settings itself offers; a capture refused says so as well.
    private func checkAccess() {
        guard !accessChecked else { return }
        accessChecked = true
        access = CGPreflightScreenCaptureAccess() ? .allowed : .denied
        if access == .denied { ClipLog.note("screen recording not allowed at start") }
    }

    /// Opens Sommelier again: how a permission changed in System Settings takes effect.
    func relaunch() {
        let bundle = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", bundle]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Following the games

    private var playing: [Game] {
        guard let model else { return [] }
        return model.gameStates.compactMap { id, state -> Game? in
            guard case .playing = state else { return nil }
            return model.library.games.first { $0.id == id }
        }
    }

    private func tick() {
        guard let model else { return }
        let settings = self.settings
        // The key is Sommelier's only while a game is being recorded; otherwise other apps keep it.
        registerHotKey(settings.enabled && captures.values.contains { $0.isCapturing } ? settings : nil)
        // Old captures nobody claimed (the game quit without a crash decision): let go.
        for (id, date) in endedAt where Date().timeIntervalSince(date) > 180 { captures[id] = nil; endedAt[id] = nil }

        guard settings.enabled else {
            for id in Array(captures.keys) { drop(id) }
            recording = []
            return
        }
        checkAccess()
        let live = Set(playing.map(\.id))
        for (id, capture) in captures {
            if !live.contains(id) || !settings.records(id) {
                // The game is over (or clips are off for it): stop capturing, keep what's in the ring for a crash.
                if capture.isCapturing { Task { await capture.stop() } }
                if endedAt[id] == nil { endedAt[id] = Date() }
                if !settings.records(id) { drop(id) }
            } else if capture.isCapturing {
                endedAt[id] = nil
                if capture.length != settings.length { capture.setLength(settings.length) }
                // The window went (the game changed its mode, or a launcher handed over) and the stream didn't
                // say so: after a few seconds, start over on the window there is now.
                if InGameCounterWindow.windowFrame(of: capture.pid) == nil, capture.quietFor > 3 {
                    windowGone[id, default: 0] += 1
                    if windowGone[id, default: 0] >= 3 {
                        ClipLog.note("window of \(capture.title) gone for 3 s: capture restarted")
                        windowGone[id] = nil
                        Task { await capture.stop() }
                        captureEnded(id)
                    }
                } else { windowGone[id] = nil }
            }
        }
        recording = Set(captures.filter { $0.value.isCapturing }.keys)
        freeSpaceLow = (store.freeSpace() ?? .max) < ClipStore.freeSpaceNeeded

        for game in playing where settings.records(game.id) {
            let capture = captures[game.id]
            if capture?.isCapturing == true { continue }
            guard !starting.contains(game.id), (retryAfter[game.id] ?? .distantPast) < Date() else { continue }
            // Without the permission, trying would only put the system's request up: the page says what to do.
            if freeSpaceLow || access == .denied { continue }
            beginCapture(of: game, replacing: capture, settings: settings)
        }
        _ = model
    }

    private func drop(_ id: String) {
        if let capture = captures[id], capture.isCapturing { Task { await capture.stop() } }
        captures[id] = nil; endedAt[id] = nil; restarts[id] = nil
    }

    private func beginCapture(of game: Game, replacing old: ClipCapture?, settings: ClipSettings) {
        guard let model else { return }
        starting.insert(game.id)
        let engines = model.paths.engines.path
        Task {
            defer { starting.remove(game.id) }
            // The game's window: the process that owns it (by its folder, or Steam's own marker).
            let pid: Int32? = await Task.detached {
                AppModel.runningProcess(of: game, enginesFolder: engines) ?? WineWindows.gameWindowOwner(enginesFolder: engines)
            }.value
            guard let pid else { retryAfter[game.id] = Date().addingTimeInterval(3); return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                access = .allowed
                // The game's biggest real window; a launcher's little ones don't count.
                let window = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width >= 300 && $0.frame.height >= 200 && $0.windowLayer == 0 || ($0.owningApplication?.processID == pid && $0.frame.width >= 300 && $0.frame.height >= 200 && $0.windowLayer >= 25) }
                    .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                guard let window else { retryAfter[game.id] = Date().addingTimeInterval(3); return }
                let capture = ClipCapture(gameID: game.id, title: game.title, pid: pid, settings: settings)
                capture.onEnded = { [weak self] _ in
                    Task { @MainActor in self?.captureEnded(game.id) }
                }
                // The sound of every process in the game's environment: the game's own, and whatever it started.
                let bottle = Bottle(kind: game.store.bottleKind, paths: model.paths).url
                let sound: [pid_t] = await Task.detached {
                    WineWindows.programs(enginesFolder: engines).map(\.pid).filter { WineWindows.runs($0, in: bottle) }
                }.value
                try await capture.start(window: window, soundOf: sound.isEmpty ? [pid] : sound)
                if let old, old.isCapturing { await old.stop() }
                captures[game.id] = capture
                endedAt[game.id] = nil
                stoppedEarly = false
                ClipLog.note("capturing \(game.title): pid \(pid), window \(Int(window.frame.width))×\(Int(window.frame.height)) at \(Int(capture.pixelSize.width))×\(Int(capture.pixelSize.height)) px, \(settings.quality.rawValue), \(Int(settings.length.seconds)) s, sound \(settings.gameSound ? "on" : "off")")
                hint(for: game, pid: pid)
            } catch {
                ClipLog.note("capture of \(game.title) didn't start: \(error.localizedDescription)")
                if Self.isDenied(error) { access = .denied }    // tried again once the quiet check says yes
                else { retryAfter[game.id] = Date().addingTimeInterval(5) }
            }
        }
    }

    private static func isDenied(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.userDeclined.rawValue
    }

    /// The stream ended by itself: the window closed (a crash, a new window coming), or the system stopped it.
    private func captureEnded(_ id: String) {
        guard let capture = captures[id] else { return }
        if endedAt[id] == nil { endedAt[id] = Date() }
        guard playing.contains(where: { $0.id == id }) else { return }
        restarts[id, default: 0] += 1
        if restarts[id, default: 0] > 6 {
            stoppedEarly = true
            retryAfter[id] = .distantFuture
            toast.show(.stopped, over: capture.pid)
        }
    }

    private func sleeping() {
        for (id, capture) in captures { Task { await capture.stop() }; _ = id }
        captures.removeAll(); endedAt.removeAll()
    }

    /// Called when a game's session is over. A crash or a freeze with the setting on saves the last 30 seconds.
    func gameEnded(_ gameID: String, title: String, crashed: Bool) {
        guard let capture = captures[gameID] else { return }
        let settings = self.settings
        if crashed, settings.saveOnCrash, settings.records(gameID), capture.hasVideo {
            save(from: capture, seconds: 30, origin: .crash, gameID: gameID, title: title, notify: false)
        }
        if capture.isCapturing { Task { await capture.stop() } }
        captures[gameID] = nil; endedAt[gameID] = nil; restarts[gameID] = nil; retryAfter[gameID] = nil
    }

    // MARK: Saving

    /// Saves the last stretch of the game in front (the key, the pad, the menu).
    func saveNow(origin: Clip.Origin = .key) {
        guard settings.enabled else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let capture = captures.values.first { $0.pid == front && $0.isCapturing }
            ?? captures.values.first { $0.isCapturing }
        guard let capture else { return }
        save(from: capture, seconds: settings.length.seconds, origin: origin, gameID: capture.gameID, title: capture.title, notify: true)
    }

    private func save(from capture: ClipCapture, seconds: Double, origin: Clip.Origin, gameID: String, title: String, notify: Bool) {
        guard !saving else { ClipLog.note("save asked while the last clip is still being written"); return }
        let pid = capture.pid
        if (store.freeSpace() ?? .max) < ClipStore.freeSpaceNeeded {
            if notify { toast.show(.noSpace, over: pid) }
            return
        }
        guard let snapshot = capture.snapshot(last: seconds) else { ClipLog.note("save asked, nothing kept yet"); return }
        saving = true
        let sound = snapshot.pieces.filter { !$0.isVideo }
        let pictures = snapshot.pieces.filter { $0.isVideo }
        ClipLog.note("saving \(origin.rawValue) clip of \(title): \(snapshot.seconds.rounded()) s, \(pictures.count) pictures \(pictures.first?.time ?? 0)–\(pictures.last?.time ?? 0), \(sound.count) sound blocks \(sound.first?.time ?? 0)–\(sound.last?.time ?? 0), sound \(snapshot.hasSound)")
        let store = store
        let date = Date()
        let url = store.newURL(game: title, at: date)
        let limit = settings.automaticLimitGB * 1_000_000_000
        let noSoundAsked = settings.gameSound
        let quality = Self.qualityLabel(snapshot)
        Task {
            do {
                try await ClipCapture.write(snapshot, to: url)
                let clip = Clip(id: url.deletingPathExtension().lastPathComponent, gameID: gameID, gameTitle: title, date: date,
                                seconds: snapshot.seconds, origin: origin, hasSound: snapshot.hasSound, quality: quality)
                store.save(clip, for: url)
                let all = store.clips()
                ClipStore.clipsToRemove(from: all, limitBytes: limit).forEach { store.delete($0) }
                clips = store.clips()
                if notify {
                    let seconds = min(Int(snapshot.seconds.rounded()), Int(seconds))
                    toast.show(snapshot.hasSound || !noSoundAsked ? (origin == .controller ? .savedFromPad(seconds) : .saved(seconds)) : .savedWithoutSound, over: pid)
                }
                ClipLog.note("saved \(url.lastPathComponent)")
            } catch {
                try? FileManager.default.removeItem(at: url)
                ClipLog.note("save failed: \(error)")
                if notify { toast.show((store.freeSpace() ?? .max) < ClipStore.freeSpaceNeeded ? .noSpace : .failed, over: pid) }
            }
            saving = false
        }
    }

    private static func qualityLabel(_ snapshot: ClipCapture.Snapshot) -> String {
        let name: String
        switch snapshot.quality {
        case .light: name = String(localized: "Light")
        case .normal: name = String(localized: "Normal")
        case .high: name = String(localized: "High")
        }
        return "\(name) · \(Int(snapshot.size.height))p, \(snapshot.fps) fps"
    }

    /// "⌥⌘S saves the last minute": in each of the first three games after clips were turned on.
    private func hint(for game: Game, pid: Int32) {
        var settings = self.settings
        guard settings.hintsShown < ClipSettings.hintLimit, !hinted.contains(game.id) else { return }
        hinted.insert(game.id)
        settings.hintsShown += 1
        self.settings = settings
        Task {
            try? await Task.sleep(for: .seconds(5))
            toast.show(.hint(settings.keyName, Int(settings.length.seconds)), over: pid)
        }
    }

    // MARK: The key

    private func registerHotKey(_ settings: ClipSettings?) {
        guard let settings else { unregisterHotKey(); return }
        let wanted = (settings.keyCode, settings.keyModifiers)
        if let registeredKey, registeredKey == wanted { return }
        unregisterHotKey()
        guard ClipSettings.isValidKey(code: wanted.0, modifiers: wanted.1) else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == OSType(0x534D4C43) else { return OSStatus(eventNotHandledErr) }    // "SMLC": not ours
            DispatchQueue.main.async { MainActor.assumeIsolated { ClipRecorder.shared.saveNow() } }
            return noErr
        }, 1, &type, nil, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x534D4C43), id: 2)
        RegisterEventHotKey(UInt32(wanted.0), UInt32(wanted.1), id, GetApplicationEventTarget(), 0, &hotKey)
        registeredKey = wanted
    }

    private func unregisterHotKey() {
        if let key = hotKey { UnregisterEventHotKey(key); hotKey = nil }
        if let handler = hotKeyHandler { RemoveEventHandler(handler); hotKeyHandler = nil }
        registeredKey = nil
    }

    // MARK: The pad

    private func watch(_ pad: GCController) {
        guard let share = pad.physicalInputProfile.buttons[GCInputButtonShare] else { return }
        share.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.padButton(pressed) }
        }
    }

    /// Held for a second: a clip. A tap does nothing (the console's own screenshot gesture isn't ours).
    private func padButton(_ pressed: Bool) {
        padHold?.cancel()
        guard pressed, settings.enabled, settings.controllerButton, !captures.isEmpty else { return }
        padHold = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow(origin: .controller)
        }
    }
}

extension ClipCapture {
    var length: ClipSettings.Length { settings.length }
}

// MARK: The note over the game

/// What the note over the game says, for two or three seconds.
enum ClipToast: Equatable {
    case saved(Int), savedFromPad(Int), savedWithoutSound, noSpace, failed, stopped
    case hint(String, Int)

    var title: String {
        switch self {
        case .saved, .savedFromPad: String(localized: "Clip saved")
        case .savedWithoutSound: String(localized: "Clip saved without sound")
        case .noSpace, .failed: String(localized: "Clip not saved")
        case .stopped: String(localized: "Recording stopped")
        case .hint(let key, let seconds): String(localized: "\(key) saves the last \(seconds) seconds")
        }
    }

    var detail: String? {
        switch self {
        case .saved(let s): String(localized: "The last \(s) seconds")
        case .savedFromPad(let s): String(localized: "The last \(s) seconds · controller")
        case .savedWithoutSound: String(localized: "The game’s sound didn’t reach the recording")
        case .noSpace: String(localized: "Not enough space on this Mac")
        case .failed: String(localized: "The clip couldn’t be written")
        case .stopped: String(localized: "Clips are off until the next game")
        case .hint: nil
        }
    }

    var symbol: String {
        switch self {
        case .saved, .savedFromPad, .hint: "film"
        case .savedWithoutSound: "speaker.slash"
        case .noSpace, .failed, .stopped: "exclamationmark.triangle"
        }
    }
}

/// The see-through note in a corner of the game's window while it is in front: no focus, clicks pass through,
/// and it is a window of Sommelier's own, so it is never in the game's picture.
@MainActor
final class ClipToastWindow {
    private var panel: NSPanel?
    private let state = ToastState()
    private var hideTask: Task<Void, Never>?

    func show(_ toast: ClipToast, over pid: Int32) {
        guard let frame = InGameCounterWindow.windowFrame(of: pid),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        state.toast = toast
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        var area = frame
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }), screen.safeAreaInsets.top > 0 {
            area.size.height = min(area.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - area.minY
        }
        let inset: CGFloat = 12
        panel.setFrame(NSRect(x: (area.maxX - size.width - inset).rounded(), y: (area.maxY - size.height - inset).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(toast == .noSpace || toast == .failed || toast == .stopped ? 4 : 3))
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ToastView(state: state))
        return panel
    }
}

@MainActor @Observable
final class ToastState { var toast: ClipToast = .saved(60) }

struct ToastView: View {
    let state: ToastState

    var body: some View {
        let toast = state.toast
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                if let detail = toast.detail { Text(detail).font(.system(size: 11)).opacity(0.75) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .fixedSize()
    }
}

// MARK: The log

/// `Logs/Clips.log`: what the recorder did, a line each, for looking into a clip that didn't come. Kept short.
enum ClipLog {
    nonisolated(unsafe) static var file: URL?
    private static let lock = NSLock()

    static func note(_ text: String) {
        guard let file else { return }
        lock.withLock {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = Data("\(stamp) \(text)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) ?? 0 > 1_000_000 {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }
}
