// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon.HIToolbox
import SommelierKit
import SwiftUI

/// The in-game counter: a small see-through panel Sommelier keeps over the game's window while it is in front,
/// showing what the player picked in Settings (frame rate, frame time, GPU and CPU load, the game's memory, heat).
/// The frame rate comes from the engine's Mac driver (`LiveFrameRate`), the rest is measured from outside the game.
/// ⌥⌘F hides and shows it while a game runs. Clicks pass through to the game.
@MainActor
final class InGameCounterWindow {
    static let shared = InGameCounterWindow()

    private weak var model: AppModel?
    private var panel: NSPanel?
    private let readings = CounterReadings()
    private let load = SystemLoad()
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var hiddenByPlayer = false
    private var currentPID: Int32?
    private var lastCleanUp = Date.distantPast

    func start(model: AppModel) {
        self.model = model
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let model else { return }
        let settings = model.settings.inGameCounter ?? InGameCounter()
        guard settings.enabled, let game = playingGame(in: model) else {
            hide()
            setHotKey(false)
            hiddenByPlayer = false
            currentPID = nil
            if Date().timeIntervalSince(lastCleanUp) > 30 {
                lastCleanUp = Date()
                let folders = BottleKind.allCases.map { FrameStats.folder(in: Bottle(kind: $0, paths: model.paths)) }
                Task.detached(priority: .utility) { folders.forEach { LiveFrameRate.cleanUp(in: $0) } }
            }
            return
        }
        setHotKey(true)
        let folder = FrameStats.folder(in: Bottle(kind: game.store.bottleKind, paths: model.paths))
        guard let live = LiveFrameRate.current(in: folder, excluding: AppModel.notGameExecutables) else { hide(); return }
        if live.pid != currentPID { currentPID = live.pid; hiddenByPlayer = false }
        // Only over the game while it is in front: switching to another app takes the counter away.
        guard !hiddenByPlayer, NSWorkspace.shared.frontmostApplication?.processIdentifier == live.pid,
              let window = Self.windowFrame(of: live.pid) else { hide(); return }

        readings.settings = settings
        readings.fps = live.fps
        readings.frameMs = live.frameMs
        if settings.shows(.gpu) { readings.gpu = SystemLoad.gpuPercent() }
        if settings.shows(.cpu) { readings.cpu = load.cpuPercent() }
        if settings.shows(.memory) { readings.memory = SystemLoad.memory(of: live.pid) }
        readings.thermal = ProcessInfo.processInfo.thermalState
        show(over: window, corner: settings.corner)
    }

    private func playingGame(in model: AppModel) -> Game? {
        for (id, state) in model.gameStates {
            guard case .playing = state, let game = model.library.games.first(where: { $0.id == id }), !game.isNative else { continue }
            return game
        }
        return nil
    }

    // MARK: The panel

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.appearance = NSAppearance(named: .darkAqua)       // over the game: always the dark counter
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Above a game that took the whole display (Wine captures it for full-screen modes), on every Space.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CounterView(readings: readings))
        return panel
    }

    private func show(over gameWindow: NSRect, corner: InGameCounter.Corner) {
        // A full-screen game's window covers the band beside the camera notch too: keep below it.
        var window = gameWindow
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(gameWindow) }), screen.safeAreaInsets.top > 0 {
            window.size.height = min(window.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - window.minY
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        let inset: CGFloat = 12
        let x = corner == .topLeft || corner == .bottomLeft ? window.minX + inset : window.maxX - size.width - inset
        let y = corner == .topLeft || corner == .topRight ? window.maxY - size.height - inset : window.minY + inset
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func hide() { panel?.orderOut(nil) }

    /// The game's biggest on-screen window, in AppKit's coordinates (origin at the bottom left of the main display).
    static func windowFrame(of pid: Int32) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        var best: CGRect?
        for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width >= 200, rect.height >= 150 else { continue }
            if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
        }
        guard let best else { return nil }
        return NSRect(x: best.minX, y: mainHeight - best.maxY, width: best.width, height: best.height)
    }

    // MARK: ⌥⌘F

    private func setHotKey(_ on: Bool) {
        if on, hotKey == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                guard pressed.signature == OSType(0x534D4C52) else { return OSStatus(eventNotHandledErr) }   // another key's (clips)
                DispatchQueue.main.async { MainActor.assumeIsolated { InGameCounterWindow.shared.toggleByPlayer() } }
                return noErr
            }, 1, &type, nil, &hotKeyHandler)
            let id = EventHotKeyID(signature: OSType(0x534D4C52), id: 1)          // "SMLR"
            RegisterEventHotKey(UInt32(kVK_ANSI_F), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        } else if !on, let key = hotKey {
            UnregisterEventHotKey(key)
            hotKey = nil
            if let handler = hotKeyHandler { RemoveEventHandler(handler); hotKeyHandler = nil }
        }
    }

    private func toggleByPlayer() {
        hiddenByPlayer.toggle()
        tick()
    }
}

/// What the counter shows; updated twice a second.
@MainActor @Observable
final class CounterReadings {
    var settings = InGameCounter()
    var fps: Double = 0
    var frameMs: Double = 0
    var gpu: Int?
    var cpu: Int?
    var memory: UInt64?
    var thermal: ProcessInfo.ThermalState = .nominal
}

struct CounterView: View {
    let readings: CounterReadings

    private var fontSize: CGFloat {
        switch readings.settings.size { case .small: 11; case .medium: 13; case .large: 17 }
    }

    var body: some View {
        let s = readings.settings
        VStack(alignment: .leading, spacing: fontSize * 0.25) {
            Grid(alignment: .leading, horizontalSpacing: fontSize * 0.9, verticalSpacing: fontSize * 0.25) {
                if s.shows(.fps) { row("FPS", Text(verbatim: "\(Int(readings.fps.rounded()))"), color: fpsColor) }
                if s.shows(.frameTime) {
                    row(String(localized: "Frame"), Text("\(readings.frameMs.formatted(.number.precision(.fractionLength(1)))) ms"))
                }
                if s.shows(.gpu) { row(String(localized: "GPU"), percent(readings.gpu)) }
                if s.shows(.cpu) { row(String(localized: "CPU"), percent(readings.cpu)) }
                if s.shows(.memory) {
                    row(String(localized: "Memory"), readings.memory.map {
                        Text("\((Double($0) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))) GB")
                    } ?? Text(verbatim: "—"))
                }
            }
            if s.shows(.thermal), readings.thermal == .serious || readings.thermal == .critical {
                Text(readings.thermal == .critical ? "Mac is too hot: slowing down" : "Mac is hot")
                    .foregroundStyle(Theme.wineLight)
            }
        }
        .lineLimit(1)
        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.9), radius: 1.5, y: 0.5)
        .opacity(1 - min(s.textTransparency, InGameCounter.maxTextTransparency))
        .padding(.horizontal, fontSize * 0.7)
        .padding(.vertical, fontSize * 0.5)
        .background(RoundedRectangle(cornerRadius: fontSize * 0.5).fill(.black.opacity(0.8 * (1 - s.transparency))))
        .overlay(RoundedRectangle(cornerRadius: fontSize * 0.5).strokeBorder(.white.opacity(0.12 * (1 - s.transparency))))
        .fixedSize()
    }

    private var fpsColor: Color {
        readings.fps >= 30 ? Theme.onDark : Theme.wineLight   // smooth reads plain; a struggling game stands out in the accent
    }

    private func percent(_ value: Int?) -> Text { value.map { Text(verbatim: "\($0)%") } ?? Text(verbatim: "—") }

    private func row(_ label: String, _ value: Text, color: Color = .white) -> some View {
        GridRow {
            Text(label).foregroundStyle(.white.opacity(0.75))
            value.foregroundStyle(color)
        }
    }
}

/// Settings' live preview of the counter: a game's picture with the counter on it, as the player sets it up.
/// Every change shows at once; the numbers move a little so it reads as live.
struct CounterPreview: View {
    @Environment(AppModel.self) private var model
    let settings: InGameCounter

    var body: some View {
        ZStack(alignment: alignment) {
            background
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                CounterView(readings: sample(at: context.date)).environment(\.colorScheme, .dark)
                    .scaleEffect(0.72, anchor: unitPoint)
                    .padding(8)
                    .animation(.easeInOut(duration: 0.2), value: settings)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12)))
        .accessibilityLabel(Text("Preview of the in-game counter"))
    }

    /// The picture of the game played last (or any installed one), else a plain backdrop.
    @ViewBuilder private var background: some View {
        let games = model.library.games.filter { $0.isInstalled && !$0.isNative }
        let last = games.max { (model.library.userData[$0.id]?.lastPlayed ?? .distantPast) < (model.library.userData[$1.id]?.lastPlayed ?? .distantPast) }
        if let game = last, let url = model.heroURL(for: game) {
            Artwork(url: url, title: game.title, titleOnPlaceholder: false)
        } else {
            Theme.placeholder
        }
    }

    private func sample(at date: Date) -> CounterReadings {
        let r = CounterReadings()
        let t = date.timeIntervalSinceReferenceDate
        r.settings = settings
        r.fps = 60 + 2 * sin(t * 1.3)
        r.frameMs = 1000 / r.fps
        r.gpu = 72 + Int(4 * sin(t * 0.9))
        r.cpu = 41 + Int(3 * sin(t * 1.7))
        r.memory = 3_400_000_000
        r.thermal = .serious           // so the heat warning can be seen when it is turned on
        return r
    }

    private var alignment: Alignment {
        switch settings.corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    private var unitPoint: UnitPoint {
        switch settings.corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}
