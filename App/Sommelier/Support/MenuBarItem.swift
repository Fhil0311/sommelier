// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import SwiftUI

/// Sommelier's icon in the Mac's menu bar (design: brand/menubar). The grape on the 24-unit grid, monochrome and a
/// template so macOS tints it: outlined berries at rest, all filled while a game runs, filling bottom-up while one
/// downloads, breathing while one starts, with a dot while an app update waits. Its menu says what's going on and
/// starts the last game. The launchers' own tray icons stay out of the menu bar (`SOMMELIER_NO_TRAY`).
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    static let shared = MenuBarItem()

    private var item: NSStatusItem?
    private weak var model: AppModel?
    private weak var updater: Updater?
    private var openWindow: (() -> Void)?
    private var timer: Timer?
    private var shown = ""
    /// The grape opens a small window (now playing, downloads, recent games), not a plain menu.
    private var popover: NSPopover?
    /// SwiftUI's openSettings, handed over by the main window (see MainWindowOpener).
    var openSettingsWindow: (() -> Void)?

    func start(model: AppModel, updater: Updater, openWindow: @escaping () -> Void) {
        guard item == nil else { return }
        self.model = model
        self.updater = updater
        self.openWindow = openWindow
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = model.settings.showInMenuBar != false
        item.button?.toolTip = "Sommelier"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu                                    // the plain menu (variant A); MenuBarPanel below is variant B
        self.item = item
        refresh()
        // Often enough for the breathing grape while a game starts; the image is only redrawn when it changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in Task { @MainActor in MenuBarItem.shared.refresh() } }
    }

    /// Settings → General → "Show Sommelier in the menu bar".
    func setVisible(_ visible: Bool) { item?.isVisible = visible }

    // MARK: Icon

    private enum State: Equatable {
        case idle, playing, starting(phase: Int), downloading(Double)
    }

    private var state: State {
        guard let model else { return .idle }
        if model.gameStates.values.contains(where: { if case .playing = $0 { true } else { false } }) { return .playing }
        if model.gameStates.values.contains(where: { if case .starting = $0 { true } else { false } }) {
            return .starting(phase: Int(Date().timeIntervalSinceReferenceDate * 4) % 8)
        }
        let downloads = model.library.games.compactMap { model.installState(of: $0) }
        if !downloads.isEmpty { return .downloading(downloads.compactMap(\.fraction).min() ?? 0) }
        return .idle
    }

    private var updateWaiting: Bool {
        switch updater?.state {
        case .available?, .downloading?, .installing?, .readyToRestart?: true
        default: false
        }
    }

    func refresh() {
        let state = state, dot = updateWaiting
        let key: String
        switch state {
        case .idle: key = "idle"
        case .playing: key = "playing"
        case .starting(let phase): key = "start\(phase)"
        case .downloading(let f): key = "dl\(Int(f * 50))"
        }
        let full = key + (dot ? "+dot" : "")
        guard full != shown, let button = item?.button else { return }
        shown = full
        button.image = Self.icon(state, dot: dot)
    }

    /// The grape drawn as on the brand's menubar SVGs: 18 pt, the 24-unit grid, the curved stem.
    private static func icon(_ state: State, dot: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let k = side / 24
            ctx.scaleBy(x: k, y: k)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            // The stem.
            ctx.setLineWidth(1.8); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 12, y: 6.3)); ctx.addLine(to: CGPoint(x: 12, y: 4))
            ctx.addCurve(to: CGPoint(x: 14.9, y: 1.3), control1: CGPoint(x: 12, y: 2.5), control2: CGPoint(x: 13.2, y: 1.3))
            ctx.strokePath()
            // The leaf: the full sprig, as on the logo.
            ctx.move(to: CGPoint(x: 13.2, y: 3.6))
            ctx.addCurve(to: CGPoint(x: 21.4, y: 1.2), control1: CGPoint(x: 15, y: 0.9), control2: CGPoint(x: 18.4, y: 0.1))
            ctx.addCurve(to: CGPoint(x: 13.2, y: 3.6), control1: CGPoint(x: 19.8, y: 3.8), control2: CGPoint(x: 16.4, y: 4.8))
            ctx.fillPath()
            let berries = GrapeMark.grapes
            func berry(_ p: CGPoint) -> CGPath { CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: 5, height: 5), cornerWidth: 1.1, cornerHeight: 1.1, transform: nil) }
            func outline(_ p: CGPoint) {
                ctx.addPath(CGPath(roundedRect: CGRect(x: p.x + 0.55, y: p.y + 0.55, width: 3.9, height: 3.9), cornerWidth: 0.9, cornerHeight: 0.9, transform: nil))
                ctx.setLineWidth(1.1); ctx.strokePath()
            }
            switch state {
            case .idle:
                berries.forEach(outline)
            case .playing:
                for p in berries { ctx.addPath(berry(p)); ctx.fillPath() }
            case .downloading(let fraction):
                berries.forEach(outline)
                let level = 23.8 - max(0, min(1, fraction)) * 17.2
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: level, width: 24, height: 24 - level))
                for p in berries { ctx.addPath(berry(p)); ctx.fillPath() }
                ctx.restoreGState()
            case .starting(let phase):
                // Three berries dim in turn, as the breathing grape does.
                let t = Double(phase) / 8
                for (i, p) in berries.enumerated() {
                    let delay: Double? = i == 0 ? 0 : i == 1 ? 0.25 : i == 3 ? 0.5 : nil
                    let alpha = delay.map { 0.675 + 0.325 * cos((t - $0) * 2 * .pi) } ?? 1
                    ctx.setAlpha(alpha); ctx.addPath(berry(p)); ctx.fillPath(); ctx.setAlpha(1)
                }
            }
            if dot {
                ctx.fillEllipse(in: CGRect(x: 18.5, y: 17.5, width: 5.5, height: 5.5))
            }
            return true
        }
        image.isTemplate = true                     // macOS colours it for a light or dark menu bar
        return image
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        // Now: the running game with its cover and session time, and what can be done with it.
        if let game = model.library.games.first(where: { model.gameStates[$0.id] != nil }) {
            switch model.gameStates[game.id] {
            case .playing(let since)?:
                let line = String(localized: "In game · \(ContinueCard.clock(Date().timeIntervalSince(since)))")
                menu.addItem(cover(game, title: "\(game.title) · \(line)", enabled: false))
                menu.addItem(entry(String(localized: "Back to the Game"), action: #selector(backToGame(_:)), id: game.id))
                menu.addItem(entry(String(localized: "Close the Game…"), action: #selector(closeGame(_:)), id: game.id))
            default:
                menu.addItem(cover(game, title: "\(game.title) · \(String(localized: "Starting…"))", enabled: false))
            }
            menu.addItem(.separator())
        }
        // Downloads, one line each with its cover and percentage.
        let downloads = model.activeDownloads
        if !downloads.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Downloads")))
            for (game, install) in downloads {
                var line = game.title + " · " + (install.fraction.map { "\(Int(($0 * 100).rounded())) %" } ?? String(localized: "waiting"))
                if case .steam(let d) = install, d.bytesTotal > 0 {
                    let done = ByteCountFormatter.string(fromByteCount: d.bytesDone, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: d.bytesTotal, countStyle: .file)
                    line += " · " + String(localized: "\(done) of \(total)")
                }
                let item = cover(game, title: line, enabled: true)
                item.action = #selector(openApp); item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        // The last installed games, a click starts one.
        let playing = Set(model.gameStates.keys)
        let recent = model.games(for: .installed).filter { $0.isInstalled && model.lastPlayed($0) != nil && !playing.contains($0.id) }
            .sorted { model.lastPlayed($0)! > model.lastPlayed($1)! }.prefix(4)
        if !recent.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Recently Played")))
            for game in recent {
                let item = cover(game, title: game.title, enabled: true)
                item.action = #selector(play(_:)); item.target = self; item.representedObject = game.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if let version = updateVersion {
            menu.addItem(entry(String(localized: "Update \(version)…"), action: #selector(showUpdate), id: nil))
            menu.addItem(.separator())
        }
        menu.addItem(entry(String(localized: "Open Sommelier"), action: #selector(openApp), id: nil))
        let settings = entry(String(localized: "Settings…"), action: #selector(openSettings), id: nil)
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = entry(String(localized: "Quit Sommelier"), action: #selector(quitApp), id: nil)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// A menu line with the game's small cover in front.
    private func cover(_ game: Game, title: String, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        if let model, let image = model.artwork.image(model.coverURL(for: game)) ?? model.artwork.image(model.headerURL(for: game)) {
            item.image = Self.thumbnail(image)
        }
        return item
    }

    /// 15 × 20 pt with rounded corners, the size of a menu line.
    private static func thumbnail(_ source: NSImage) -> NSImage {
        let size = NSSize(width: 15, height: 20)
        return NSImage(size: size, flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
            let s = source.size, scale = max(rect.width / max(s.width, 1), rect.height / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            source.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
    }

    private var updateVersion: String? {
        switch updater?.state {
        case .available(let item)?: item.version
        case .downloading(let version, _)?, .installing(let version)?, .readyToRestart(let version)?: version
        default: nil
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func entry(_ title: String, action: Selector, id: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    private func game(_ sender: NSMenuItem) -> Game? {
        guard let id = sender.representedObject as? String else { return nil }
        return model?.library.games.first { $0.id == id }
    }

    @objc private func openApp() {
        NSApp.activate()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openWindow?() }
    }

    @objc private func openSettings() {
        NSApp.activate()
        if let openSettingsWindow { openSettingsWindow() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }

    @objc private func showUpdate() {
        openApp()
        updater?.showingDetails = true
    }

    @objc private func play(_ sender: NSMenuItem) {
        guard let game = game(sender) else { return }
        Task { await model?.play(game) }
    }

    @objc private func backToGame(_ sender: NSMenuItem) {
        guard let model, let game = game(sender) else { return }
        let engines = model.paths.engines.path, marker = game.installPath?.lastPathComponent ?? game.title
        if let owner = WineWindows.gameWindowOwner(enginesFolder: engines, marker: marker) { model.giveFocus(to: owner) }
    }

    @objc private func closeGame(_ sender: NSMenuItem) {
        guard let model, let game = game(sender) else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Close \(game.title)?")
        alert.informativeText = String(localized: "Unsaved progress is lost.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.closeGame(game)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if let popover, popover.isShown { popover.performClose(sender); return }
        guard let model, let button = item?.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient                       // closes on Esc or a click elsewhere
        popover.animates = true
        let panel = MenuBarPanel(
            updateVersion: updateVersion,
            close: { [weak self] in self?.popover?.performClose(nil) },
            openApp: { [weak self] in self?.popover?.performClose(nil); self?.openApp() },
            openSettings: { [weak self] in self?.popover?.performClose(nil); self?.openSettings() },
            showUpdate: { [weak self] in self?.popover?.performClose(nil); self?.showUpdate() },
            backToGame: { [weak self] game in self?.popover?.performClose(nil); self?.focus(game) },
            closeGame: { [weak self] game in self?.popover?.performClose(nil); self?.confirmClose(game) },
            quit: { NSApp.terminate(nil) })
            .environment(model).environment(model.artwork)
        popover.contentViewController = NSHostingController(rootView: panel)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
    }

    private func focus(_ game: Game) {
        guard let model else { return }
        let engines = model.paths.engines.path, marker = game.installPath?.lastPathComponent ?? game.title
        if let owner = WineWindows.gameWindowOwner(enginesFolder: engines, marker: marker) { model.giveFocus(to: owner) }
    }

    private func confirmClose(_ game: Game) {
        guard let model else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Close \(game.title)?")
        alert.informativeText = String(localized: "Unsaved progress is lost.")
        alert.addButton(withTitle: String(localized: "Close"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.closeGame(game)
    }
}

/// The grape's window: the running game with its counter switch, downloads, the last games to start in a click,
/// a strip when an app update waits, and the way into the app. Sections with nothing to show aren't drawn.
private struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    let updateVersion: String?
    let close: () -> Void
    let openApp: () -> Void
    let openSettings: () -> Void
    let showUpdate: () -> Void
    let backToGame: (Game) -> Void
    let closeGame: (Game) -> Void
    let quit: () -> Void

    var body: some View {
        let running = model.library.games.first { model.gameStates[$0.id] != nil }
        let downloads = model.activeDownloads
        let recent = model.games(for: .installed).filter { $0.isInstalled && model.lastPlayed($0) != nil && $0.id != running?.id }
            .sorted { model.lastPlayed($0)! > model.lastPlayed($1)! }.prefix(5)
        VStack(alignment: .leading, spacing: 0) {
            if let running { nowPlaying(running) }
            if !downloads.isEmpty {
                section("Downloads") {
                    ForEach(downloads, id: \.game.id) { game, state in downloadRow(game, state) }
                }
            }
            if !recent.isEmpty {
                section("Recently Played") {
                    HStack(spacing: 7) {
                        ForEach(Array(recent)) { game in
                            Button { close(); Task { await model.play(game) } } label: {
                                Artwork(url: model.coverURL(for: game), title: game.title, fallback: model.headerURL(for: game))
                                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain).help(game.title)
                        }
                        ForEach(0..<max(0, 5 - recent.count), id: \.self) { _ in Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit) }
                    }
                }
            }
            if let updateVersion {
                Button(action: showUpdate) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.wineLight).frame(width: 6, height: 6)
                        Text(String(localized: "Update \(updateVersion)…")).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.wine.opacity(0.25))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 14) {
                Button("Open Sommelier", action: openApp)
                Spacer()
                Button("Settings…", action: openSettings)
                Button("Quit Sommelier", action: quit)
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.onDark.opacity(0.75))
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 340)
        .background(Theme.surface)
    }

    @ViewBuilder private func nowPlaying(_ game: Game) -> some View {
        var counter = model.settings.inGameCounter ?? InGameCounter()
        ZStack(alignment: .bottomLeading) {
            Artwork(url: model.heroURL(for: game), title: game.title, titleOnPlaceholder: false)
                .frame(height: 118).clipped()
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.45)], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Artwork(url: model.coverURL(for: game), title: game.title, fallback: model.headerURL(for: game))
                        .frame(width: 40, height: 54).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.title).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        if case .playing(let since) = model.gameStates[game.id] {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(String(localized: "In game · \(ContinueCard.clock(context.date.timeIntervalSince(since)))"))
                            }
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                        } else {
                            Text("Starting…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                HStack(spacing: 6) {
                    Button { backToGame(game) } label: { Text("Back to the Game") }.buttonStyle(QuickPlayButtonStyle())
                    Button { closeGame(game) } label: { Text("Close the Game…") }.buttonStyle(QuickPlayButtonStyle(ghost: true))
                    Spacer()
                    // The in-game counter is Sommelier's own overlay, so it switches while the game runs.
                    Toggle("Counter", isOn: Binding(get: { counter.enabled }, set: { counter.enabled = $0; model.settings.inGameCounter = counter }))
                        .toggleStyle(.switch).controlSize(.mini).tint(Theme.wine)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .padding(14)
        }
    }

    private func downloadRow(_ game: Game, _ state: AppModel.InstallState) -> some View {
        HStack(spacing: 10) {
            Artwork(url: model.coverURL(for: game), title: game.title, fallback: model.headerURL(for: game))
                .frame(width: 22, height: 30).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let fraction = state.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.onDark).controlSize(.mini)
                    Text("\(Int((fraction * 100).rounded())) %").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    LoadingGrape()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onDark.opacity(0.5))
            content()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
    }
}

extension AppModel {
    /// Stops a running game: every program running from its folder (the session's follower then sees it end).
    func closeGame(_ game: Game) {
        guard let folder = game.installPath?.lastPathComponent, !folder.isEmpty else { return }
        let name = folder.lowercased()
        for program in WineWindows.programs(enginesFolder: paths.engines.path) {
            let line = program.commandLine.lowercased()
            if line.contains("\\\(name)\\") || line.contains("/\(name)/") { kill(program.pid, SIGTERM) }
        }
    }
}
