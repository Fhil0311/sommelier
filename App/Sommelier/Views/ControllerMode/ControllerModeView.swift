// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import SwiftUI

// MARK: Focus

/// Where the controller's focus is, among the things on the screen that can take it. Each focusable thing reports
/// its frame (in the CM.width×CM.height design space) and what it does when chosen; layers keep a menu's things apart
/// from the screen's under it.
@MainActor @Observable
final class ControllerFocus {
    /// `owner`: the drawing that put it there; a screen drawn again puts the same ids in before the old drawing's go.
    struct Entry { var layer: String; var frame: CGRect; var gameID: String?; var owner: UUID; var action: () -> Void }

    var current: String? {
        didSet { if let current, !current.hasPrefix("top:"), entries[current]?.layer == "main" { lastContent = current } }
    }
    var layer = "main"
    /// The last thing on the screen itself (not the top bar) that had the focus: Down from the top bar goes back there.
    @ObservationIgnored private var lastContent: String?
    /// Where the focus was on each screen, to land there again when the player comes back to it.
    @ObservationIgnored private var memory: [String: String] = [:]
    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    /// Focus that the screen asked for before its things were on screen (the row to land on after a screen change).
    @ObservationIgnored var wanted: String?

    func register(_ id: String, layer: String, frame: CGRect, gameID: String?, owner: UUID, action: @escaping () -> Void) {
        entries[id] = Entry(layer: layer, frame: frame, gameID: gameID, owner: owner, action: action)
        // The screen asked for this one: it gets the focus as soon as it is on screen.
        if self.layer == layer, wanted == id, current != id { current = id }
    }

    func unregister(_ id: String, owner: UUID) {
        guard entries[id]?.owner == owner else { return }      // already drawn again: the new one stays
        entries[id] = nil
        if current == id { current = nil }
    }

    var focusedGameID: String? { current.flatMap { entries[$0]?.gameID } }

    /// Puts the focus on something of the layer when it has none: the top-left thing of the screen, the top bar
    /// only when the screen has nothing.
    func settle() {
        if let current, let entry = entries[current], entry.layer == layer { return }
        let targets = entries.filter { $0.value.layer == layer }.map { FocusModel.Target(id: $0.key, frame: $0.value.frame) }
        current = (FocusModel.first(among: targets.filter { !$0.id.hasPrefix("top:") }) ?? FocusModel.first(among: targets))?.id
    }

    /// Another screen came up: what had the focus is gone with the old one. The focus goes where it was on the new
    /// screen last time, else where the screen asks, else to its top-left thing.
    func screenChanged(from old: ControllerScreen, to new: ControllerScreen) {
        if let lastContent { memory[old.key] = lastContent }
        current = nil
        lastContent = nil
        layer = "main"
        wanted = memory[new.key]
        if let wanted, entries[wanted]?.layer == layer { current = wanted }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.current.flatMap({ self.entries[$0] }) == nil else { return }
            self.settle()
        }
    }

    func move(_ direction: FocusModel.Direction) {
        wanted = nil
        settle()
        guard let current, let entry = entries[current] else { return }
        // Down from the top bar: back to where the player was on the screen.
        if current.hasPrefix("top:"), direction == .down, let back = lastContent, entries[back]?.layer == layer {
            self.current = back
            return
        }
        let targets = entries.filter { $0.value.layer == layer }.map { FocusModel.Target(id: $0.key, frame: $0.value.frame) }
        if let next = FocusModel.next(from: entry.frame, towards: direction, among: targets, excluding: current) { self.current = next.id }
    }

    func activate() {
        wanted = nil
        settle()
        guard let current, let entry = entries[current], entry.layer == layer else { return }
        entry.action()
    }

    /// Focus on `id` as soon as it exists (now, or when it comes on screen).
    func focus(_ id: String) {
        wanted = id
        if let entry = entries[id], entry.layer == layer { current = id }
    }
}

/// How the ring is drawn around a focused thing.
enum FocusShape { case cover, pill, rect, row }

struct FocusTarget: ViewModifier {
    @Environment(ControllerFocus.self) private var focus
    @State private var input = ControllerInput.shared
    @State private var owner = UUID()
    let id: String
    let layer: String
    let shape: FocusShape
    let gameID: String?
    let action: () -> Void

    private var focused: Bool { focus.current == id && focus.layer == layer }
    private var ringOn: Bool { focused && input.usingController }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geometry in
                let frame = geometry.frame(in: .named("controllerMode"))
                Color.clear
                    .onAppear { focus.register(id, layer: layer, frame: frame, gameID: gameID, owner: owner, action: action) }
                    .onChange(of: frame) { _, new in focus.register(id, layer: layer, frame: new, gameID: gameID, owner: owner, action: action) }
                    .onDisappear { focus.unregister(id, owner: owner) }
            })
            .overlay {
                if ringOn {
                    switch shape {
                    case .cover: RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: -5).strokeBorder(CM.ground, lineWidth: 5)
                            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).inset(by: -10).strokeBorder(CM.ivory, lineWidth: 5))
                    case .pill: Capsule().inset(by: -4).strokeBorder(CM.ivory, lineWidth: 4)
                    case .rect: RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: -5).strokeBorder(CM.ground, lineWidth: 5)
                            .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).inset(by: -10).strokeBorder(CM.ivory, lineWidth: 5))
                    case .row: RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CM.ivory, lineWidth: 4)
                    }
                }
            }
            .scaleEffect(ringOn && shape == .cover ? 1.06 : 1)
            .zIndex(ringOn ? 2 : 0)
            .animation(.easeOut(duration: 0.16), value: ringOn)
            .contentShape(Rectangle())
            .onTapGesture { focus.wanted = nil; focus.current = id; action() }
            .onHover { if $0 && !input.usingController { focus.wanted = nil; focus.current = id } }
    }
}

extension View {
    func focusTarget(_ id: String, layer: String = "main", shape: FocusShape = .cover, game: Game? = nil, action: @escaping () -> Void) -> some View {
        modifier(FocusTarget(id: id, layer: layer, shape: shape, gameID: game?.id, action: action))
    }
}

// MARK: Looks

/// Controller Mode's palette and type: the design's, on a CM.width×CM.height canvas with a 26 pt base.
enum CM {
    /// The background setting: Cool trades the warm greys under everything for slate ones. Set before the view is made.
    nonisolated(unsafe) static var background = ControllerModeSettings.Background.warm
    static func hex(_ v: Int) -> Color { Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255) }
    static var ground: Color { hex(background == .cool ? 0x12161d : 0x141110) }
    /// Solid panels: the Guide menu, dialogs, cards.
    static var graphite: Color { hex(background == .cool ? 0x171c26 : 0x221b19) }
    /// Keys and fields.
    static var graphite2: Color { hex(background == .cool ? 0x262d3b : 0x2c2523) }
    static let ivory = Color(red: 0xef / 255, green: 0xe6 / 255, blue: 0xda / 255)
    static let stone = Color(red: 0x9b / 255, green: 0x90 / 255, blue: 0x87 / 255)
    static let wine = Color(red: 0x8e / 255, green: 0x23 / 255, blue: 0x35 / 255)
    static let wineHi = Color(red: 0xb8 / 255, green: 0x40 / 255, blue: 0x4f / 255)
    static let warn = Color(red: 0xe4 / 255, green: 0xb0 / 255, blue: 0x5a / 255)
    static let t2 = ivory.opacity(0.70)
    static let t3 = ivory.opacity(0.48)
    static let line = ivory.opacity(0.12)
    static let margin: CGFloat = 72
    /// The canvas: 1920 wide as designed, and as tall as the display's shape needs (1080 at 16:9, 1200 at 16:10),
    /// so Controller Mode fills the screen. Set before the view is made.
    nonisolated(unsafe) static var width: CGFloat = 1920
    nonisolated(unsafe) static var height: CGFloat = 1080

    /// `size` larger draws everything bigger: the canvas is narrower and scaled up to the same screen.
    static func fit(_ screen: CGSize, size: ControllerModeSettings.Size = .standard) {
        width = (1920 / size.scale).rounded()
        height = max((1080 / size.scale).rounded(), (width * screen.height / max(screen.width, 1)).rounded())
    }
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

// MARK: The root

/// Which screen is up, and what lies over it.
enum ControllerScreen: Equatable {
    case home, library, search, settings
    case game(Game)
    static func == (a: ControllerScreen, b: ControllerScreen) -> Bool {
        switch (a, b) {
        case (.home, .home), (.library, .library), (.search, .search), (.settings, .settings): true
        case (.game(let x), .game(let y)): x.id == y.id
        default: false
        }
    }
    /// Which screen this is, to remember the focus by.
    var key: String {
        switch self {
        case .home: "home"; case .library: "library"; case .search: "search"; case .settings: "settings"
        case .game(let game): "game:\(game.id)"
        }
    }
}

enum ControllerOverlay: Equatable {
    case guide, noController
    case launching(Game), running(Game), closeAsk(Game)
    case status(Game), more(Game), uninstallAsk(Game)
    case exitAsk
    case clip([Clip], Int), screenshot(Game, [URL], Int)
    static func == (a: ControllerOverlay, b: ControllerOverlay) -> Bool {
        switch (a, b) {
        case (.guide, .guide), (.noController, .noController), (.exitAsk, .exitAsk): true
        case (.launching(let x), .launching(let y)), (.running(let x), .running(let y)), (.closeAsk(let x), .closeAsk(let y)),
             (.status(let x), .status(let y)), (.more(let x), .more(let y)), (.uninstallAsk(let x), .uninstallAsk(let y)): x.id == y.id
        case (.clip(let x, let i), .clip(let y, let j)): x.map(\.id) == y.map(\.id) && i == j
        case (.screenshot(let x, _, let i), .screenshot(let y, _, let j)): x.id == y.id && i == j
        default: false
        }
    }

    /// A viewer over the whole screen: no focus of its own, the bumpers page through it.
    var isViewer: Bool {
        switch self { case .clip, .screenshot: true; default: false }
    }
}

@MainActor @Observable
final class ControllerModeState {
    var screen = ControllerScreen.home
    var overlay: ControllerOverlay?
    var stack: [ControllerScreen] = []
    var storeFilter: StoreKind?
    var sortByRecent = false
    /// The game whose art fills the background: the one in focus, else the one the screen is about.
    var backdrop: Game?
    /// What kind of thing has the focus, for the hints (set by the focus).
    var focusedKind: String?
    /// Where the focus goes when the overlay closes.
    @ObservationIgnored var returnFocus: String?

    /// Closes the overlay and puts the focus back on what opened it.
    func closeOverlay(focus: ControllerFocus, back id: String) {
        returnFocus = id
        overlay = nil
    }

    func go(_ screen: ControllerScreen) {
        guard screen != self.screen else { return }
        stack.append(self.screen)
        self.screen = screen
    }

    func back() -> Bool {
        guard let last = stack.popLast() else { return false }
        screen = last
        return true
    }
}

struct ControllerModeView: View {
    @Environment(AppModel.self) private var model
    @State private var focus = ControllerFocus()
    @State private var state = ControllerModeState()
    @State private var input = ControllerInput.shared
    @State private var canvasKey = UUID()
    let screenSize: CGSize

    private var fit: CGFloat { min(screenSize.width / CM.width, screenSize.height / CM.height) }

    var body: some View {
        ZStack {
            Color.black
            canvas
                .id(canvasKey)
                .frame(width: CM.width, height: CM.height)
                .coordinateSpace(name: "controllerMode")
                .clipped()
                .scaleEffect(fit)
                .frame(width: CM.width * fit, height: CM.height * fit)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .environment(focus)
        .environment(state)
        .onAppear {
            input.onEvent = { handle($0) }
            if !input.connected { state.overlay = .noController }
        }
        .onChange(of: input.usingController) { _, on in ControllerModeWindow.shared.setCursorHidden(on) }
        .onChange(of: model.settings.controllerMode?.size) { _, size in
            CM.fit(screenSize, size: size ?? .standard)
            let kept = focus.current
            canvasKey = UUID()                  // laid out again at the new size
            if let kept { focus.focus(kept) }      // the focus stays on the setting just changed
        }
        .onChange(of: model.settings.controllerMode?.background) { _, background in
            CM.background = background ?? .warm
            let kept = focus.current
            canvasKey = UUID()                  // drawn again in the new colours, straight away
            if let kept { focus.focus(kept) }      // the focus stays on the setting just changed
        }
        .onChange(of: input.connected) { _, on in
            if !on, state.overlay == nil { state.overlay = .noController }
            if on, state.overlay == .noController { state.overlay = nil }
        }
        .onChange(of: focus.current) { _, id in
            if let game = focus.focusedGameID.flatMap({ gid in model.library.games.first { $0.id == gid } }) { state.backdrop = game }
        }
        .onChange(of: state.screen) { old, screen in
            focus.screenChanged(from: old, to: screen)
            if case .game(let game) = screen { state.backdrop = game }
        }
        .onChange(of: state.overlay) { old, overlay in
            focus.layer = overlay == nil || overlay?.isViewer == true ? (overlay == nil ? "main" : "viewer") : "overlay"
            if overlay == nil {
                // Back to what opened it (the status line, "…"), else to where the focus was.
                if let back = state.returnFocus ?? Self.opener(of: old) { focus.focus(back) }
                state.returnFocus = nil
            } else if let wanted = focus.wanted, focus.entries[wanted]?.layer == focus.layer { focus.current = wanted } else { focus.current = nil }
        }
        .onChange(of: playingIDs) { old, new in gamesChanged(from: old, to: new) }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            CM.ground
            Backdrop(game: showsArt ? state.backdrop : nil)
            Group {
                switch state.screen {
                case .home: HomeScreen()
                case .library: LibraryScreen()
                case .game(let game): GamePageScreen(game: game)
                case .search: SearchScreen()
                case .settings: ControllerSettingsScreen()
                }
            }
            TopBar()
            HintsBar()
            if let pad = ControllerArrival.shared.shown {
                ControllerConnectNote(pad: pad)
                    .frame(width: CM.width, alignment: .trailing).padding(.trailing, CM.margin)
                    .offset(y: 124)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(4)
            }
            if let overlay = state.overlay {
                switch overlay {
                case .guide: GuideMenu()
                case .noController: NoControllerOverlay()
                case .launching(let game): LaunchingOverlay(game: game)
                case .running(let game): RunningOverlay(game: game)
                case .closeAsk(let game): CloseAskOverlay(game: game)
                case .status(let game): StatusDetails(game: game)
                case .more(let game): MoreMenu(game: game)
                case .uninstallAsk(let game): UninstallAskOverlay(game: game)
                case .exitAsk: ExitAskOverlay()
                case .clip(let clips, let index):
                    MediaViewer(items: clips.map { .clip($0.url) }, index: index, title: clips[index].name ?? clips[index].gameTitle)
                case .screenshot(let game, let shots, let index):
                    MediaViewer(items: shots.map { .image($0) }, index: index, title: game.title)
                }
            }
        }
        .font(CM.font(26))
        .foregroundStyle(CM.ivory)
    }

    /// The focused game's art fills the background on Home, All Games and a game's page; everywhere else (search,
    /// settings, the questions, the disconnected screen) the plain background does.
    private var showsArt: Bool {
        switch state.overlay {
        case .uninstallAsk, .exitAsk, .closeAsk, .noController: return false
        default: break
        }
        switch state.screen {
        case .home, .library, .game: return true
        case .search, .settings: return false
        }
    }

    /// The thing that opened an overlay, for the focus to go back to.
    private static func opener(of overlay: ControllerOverlay?) -> String? {
        switch overlay {
        case .status: "game:status"
        case .more, .uninstallAsk: "game:more"
        case .clip(let clips, let index): "clip:\(clips[index].id)"
        case .screenshot(_, _, let index): "shot:\(index)"
        default: nil
        }
    }

    // MARK: Events

    /// A soft click as the focus moves and a deeper one on a choice, when the player wants sounds.
    private func click(_ event: ControllerEvent) {
        guard (model.settings.controllerMode ?? ControllerModeSettings()).sounds else { return }
        let name: NSSound.Name? = switch event {
        case .move: "Tink"
        case .a: "Pop"
        case .b: "Bottle"
        default: nil
        }
        guard let name, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = 0.15
        sound.play()
    }

    private func handle(_ event: ControllerEvent) {
        click(event)
        if ControllerArrival.shared.shown != nil { ControllerArrival.shared.dismiss() }
        if state.overlay == .noController {
            // Only the keyboard gets here; it works as the note says.
            if case .b = event { state.overlay = nil }
            else if case .move(let d) = event { focus.move(d) }
            else if case .a = event { focus.activate() }
            return
        }
        // On the search screen the face buttons and triggers type (delete, space, capitals, results, voice).
        if state.overlay == nil, state.screen == .search, [.x, .y, .leftTrigger, .rightTrigger, .menu, .view].contains(event) {
            NotificationCenter.default.post(name: .controllerModeSearchKey, object: event)
            return
        }
        switch event {
        case .move(let direction): focus.move(direction)
        case .a: focus.activate()
        case .b: back()
        case .guide, .menu:
            if state.overlay == .guide { state.overlay = nil } else if state.overlay == nil { state.overlay = .guide }
        case .guideHeld: ControllerLog.note("guide held a second (overlay later)")
        case .leftBumper: if state.overlay == nil { tab(-1) } else { page(-1) }
        case .rightBumper: if state.overlay == nil { tab(1) } else { page(1) }
        case .leftTrigger: if state.overlay == nil, state.screen == .library { store(-1) }
        case .rightTrigger: if state.overlay == nil, state.screen == .library { store(1) }
        case .x:
            if state.overlay == nil, state.screen == .library { state.sortByRecent.toggle() }
            else if state.overlay == nil, case .game(let game) = state.screen, model.installState(of: game) == nil { state.overlay = .more(game) }
        case .y: if state.overlay == nil { state.go(.search) }
        case .view: break
        }
    }

    private func back() {
        if state.overlay != nil {
            if case .launching = state.overlay { return }           // not until the game is up or gave up
            if case .running(let game) = state.overlay { ControllerModeWindow.shared.comeForward(); _ = game; return }
            state.overlay = nil
            return
        }
        if state.back() { return }
        // At the top: from another tab B goes Home; on Home it asks before leaving Controller Mode.
        if state.screen != .home { state.screen = .home } else { state.returnFocus = focus.current; state.overlay = .exitAsk }
    }

    /// The bumpers in a viewer: the previous and next clip or screenshot.
    private func page(_ step: Int) {
        switch state.overlay {
        case .clip(let clips, let index): state.overlay = .clip(clips, min(max(index + step, 0), clips.count - 1))
        case .screenshot(let game, let shots, let index): state.overlay = .screenshot(game, shots, min(max(index + step, 0), shots.count - 1))
        default: break
        }
    }

    /// The bumpers go through these, the settings (the gear at the top right) last.
    private static let tabs: [ControllerScreen] = [.home, .library, .search, .settings]

    private func tab(_ step: Int) {
        // From a game's page: next to the tab it was opened from.
        let from = Self.tabs.contains(state.screen) ? state.screen : (state.stack.first { Self.tabs.contains($0) } ?? .home)
        let index = Self.tabs.firstIndex(of: from) ?? 0
        let next = (index + step + Self.tabs.count) % Self.tabs.count
        state.stack.removeAll()
        state.screen = Self.tabs[next]
    }

    private func store(_ step: Int) {
        let stores: [StoreKind?] = [nil] + model.storesInUse
        let index = stores.firstIndex(of: state.storeFilter) ?? 0
        state.storeFilter = stores[(index + step + stores.count) % stores.count]
    }

    // MARK: Games starting and ending

    private var playingIDs: Set<String> {
        Set(model.gameStates.compactMap { id, s in if case .playing = s { id } else { nil } })
    }

    private func gamesChanged(from old: Set<String>, to new: Set<String>) {
        if case .launching(let game) = state.overlay, new.contains(game.id) { state.overlay = .running(game) }
        if case .launching(let game) = state.overlay, model.gameStates[game.id] == nil { state.overlay = nil }   // never started
        if case .running(let game) = state.overlay, !new.contains(game.id), model.gameStates[game.id] == nil {
            state.overlay = nil
            ControllerModeWindow.shared.comeForward()
        }
        if case .closeAsk(let game) = state.overlay, model.gameStates[game.id] == nil {
            state.overlay = nil
            ControllerModeWindow.shared.comeForward()
        }
    }
}

extension Notification.Name {
    static let controllerModeMore = Notification.Name("gg.sommelier.controllerMode.more")
    static let controllerModeSearchKey = Notification.Name("gg.sommelier.controllerMode.searchKey")
}

/// The focused game's art behind everything, darkened below and to the left so the text reads.
struct Backdrop: View {
    @Environment(AppModel.self) private var model
    let game: Game?

    var body: some View {
        ZStack {
            DefaultBackdrop()
            if let game {
                art(game).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: game?.id)
    }

    /// The game's art, darkened below and to the left; only over art, never over the plain background.
    private func art(_ game: Game) -> some View {
        ZStack {
            CM.ground
            Artwork(url: model.heroURL(for: game), title: game.title, titleOnPlaceholder: false)
                .frame(width: CM.width, height: CM.height)
                .clipped()
            LinearGradient(stops: [.init(color: CM.ground.opacity(0.25), location: 0), .init(color: CM.ground.opacity(0.55), location: 0.34),
                                   .init(color: CM.ground.opacity(0.96), location: 0.58), .init(color: CM.ground, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [CM.ground.opacity(0.75), .clear], startPoint: .leading, endPoint: .init(x: 0.6, y: 0.5))
        }
        .id(game.id)
    }
}

/// Behind the screens without a game: Warm, a dark room with one wine-coloured lamp at the top right; Cool, slate
/// blue lit from the top left.
struct DefaultBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            if CM.background == .cool {
                CM.ground
                EllipticalGradient(stops: [.init(color: CM.hex(0x273041), location: 0), .init(color: CM.hex(0x1b212c), location: 0.4),
                                           .init(color: CM.ground, location: 1)], endRadiusFraction: 0.5)
                    .frame(width: CM.width * 1.8, height: CM.height * 1.4)
                    .position(x: CM.width * 0.15, y: 0)
            } else {
                RadialGradient(colors: [CM.hex(0x1a1615), CM.hex(0x0d0b0a)], center: .center, startRadius: 0,
                               endRadius: hypot(CM.width, CM.height) / 2)
                EllipticalGradient(stops: [.init(color: CM.wine.opacity(0.42), location: 0), .init(color: CM.wine.opacity(0.12), location: 0.35),
                                           .init(color: CM.wine.opacity(0), location: 0.62)], endRadiusFraction: 0.5)
                    .frame(width: CM.width * 1.4, height: CM.height * 1.2)
                    .position(x: CM.width * 0.88, y: CM.height * 0.08)
            }
        }
        .frame(width: CM.width, height: CM.height)
        .clipped()
    }
}

// MARK: Chrome

struct TopBar: View {
    @Environment(ControllerModeState.self) private var state
    @State private var input = ControllerInput.shared

    var body: some View {
        HStack(spacing: 12) {
            Glyph(.leftBumper).frame(height: 38)
            HStack(spacing: 6) {
                tab(String(localized: "Home"), .home)
                tab(String(localized: "All Games"), .library)
                tab(String(localized: "Search"), .search)
            }
            Glyph(.rightBumper).frame(height: 38)
            Spacer()
            HStack(spacing: 34) {
                if input.connected {
                    HStack(spacing: 10) {
                        PadIcon(kind: input.kind).frame(width: 40, height: 40)
                        if let battery = input.battery {
                            Text(verbatim: "\(Int((battery * 100).rounded()))%")
                            if input.charging { Image(systemName: "bolt.fill").font(CM.font(20)) }
                        }
                    }
                }
                // The Mac's battery, read again every minute (a Mac without one shows nothing).
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    if let mac = MacBattery.read() {
                        HStack(spacing: 10) {
                            Image(systemName: Self.batterySymbol(mac)).font(CM.font(28))
                            Text(verbatim: "\(mac.percent)%")
                        }
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                }
                // Settings, next to the status: the app's own settings mark (the sidebar's), in a round button that
                // lights while its screen is open.
                BerryGear().frame(width: 30, height: 30)
                    .foregroundStyle(state.screen == .settings ? CM.ground : CM.t2)
                    .frame(width: 54, height: 54)
                    .background(state.screen == .settings ? CM.ivory : CM.ivory.opacity(0.1), in: Circle())
                    .accessibilityElement().accessibilityLabel(Text("Controller Mode Settings"))
                    .focusTarget("top:settings", shape: .pill) { state.stack.removeAll(); state.screen = .settings }
                // Leaving: the icon alone, the same round button.
                Image(systemName: "rectangle.portrait.and.arrow.right").font(CM.font(24))
                    .frame(width: 54, height: 54)
                    .background(CM.ivory.opacity(0.1), in: Circle())
                    .accessibilityElement().accessibilityLabel(Text("Exit Controller Mode"))
                    .focusTarget("top:exit", shape: .pill) { ControllerModeWindow.shared.exit() }
            }
            .font(CM.font(25)).foregroundStyle(CM.t2)
        }
        .padding(.horizontal, CM.margin)
        .frame(width: CM.width, height: 104)
        .zIndex(3)
    }

    static func batterySymbol(_ mac: MacBattery.Reading) -> String {
        if mac.charging || mac.onPower { return "battery.100percent.bolt" }
        switch mac.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func tab(_ title: String, _ screen: ControllerScreen) -> some View {
        let on = state.screen == screen
        return Text(title).font(CM.font(27, .semibold))
            .foregroundStyle(on ? CM.ground : CM.t2)
            .padding(.horizontal, 26).padding(.vertical, 10)
            .background(on ? CM.ivory : .clear, in: Capsule())
            .focusTarget("top:\(title)", shape: .pill) { state.stack.removeAll(); state.screen = screen }
    }
}

/// The buttons at the bottom right: what A, B and the others do here.
struct HintsBar: View {
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    @Environment(AppModel.self) private var model

    private var installingNote: Bool {
        if state.overlay == nil, case .game(let game) = state.screen { return model.installState(of: game) != nil }
        return false
    }

    var body: some View {
        HStack(spacing: 36) {
            if installingNote { Text("You can keep browsing while it installs.").font(CM.font(24)) }
            Spacer()
            ForEach(hints, id: \.1) { hint in
                HStack(spacing: 12) { Glyph(hint.0).frame(height: 40); Text(hint.1).font(CM.font(24)) }
            }
        }
        .foregroundStyle(CM.t2)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, CM.margin)
        .frame(width: CM.width, height: 96)
        .offset(y: CM.height - 96)
        .zIndex(3)
    }

    private var hints: [(ControllerEvent, String)] {
        switch state.overlay {
        case .guide, .more: return [(.a, String(localized: "Select")), (.b, String(localized: "Close"))]
        case .status: return [(.b, String(localized: "Close"))]
        case .uninstallAsk, .exitAsk: return [(.a, String(localized: "Select")), (.b, String(localized: "Cancel"))]
        case .clip, .screenshot: return [(.leftBumper, String(localized: "Previous")), (.rightBumper, String(localized: "Next")), (.b, String(localized: "Close"))]
        case .noController: return []
        case .launching: return []
        case .running: return [(.a, String(localized: "Select")), (.b, String(localized: "Return to Game"))]
        case .closeAsk: return [(.a, String(localized: "Select")), (.b, String(localized: "Cancel"))]
        case nil: break
        }
        switch state.screen {
        case .home: return [(.a, String(localized: "Open")), (.y, String(localized: "Search")), (.guide, String(localized: "Menu"))]
        case .library: return [(.a, String(localized: "Open")), (.x, state.sortByRecent ? String(localized: "Sort: A to Z") : String(localized: "Sort: Recent")),
                               (.leftTrigger, String(localized: "Store")), (.guide, String(localized: "Menu"))]
        case .game(let game):
            let id = focus.current ?? ""
            if id == "game:status" { return [(.a, String(localized: "Details")), (.b, String(localized: "Back")), (.guide, String(localized: "Menu"))] }
            if id.hasPrefix("clip:") || id.hasPrefix("shot:") || id.hasPrefix("g:") { return [(.a, String(localized: "Open")), (.b, String(localized: "Back")), (.guide, String(localized: "Menu"))] }
            if model.installState(of: game) != nil { return [(.a, String(localized: "Select")), (.b, String(localized: "Back")), (.guide, String(localized: "Menu"))] }
            let primary = model.isActive(game) ? String(localized: "Select") : game.isInstalled ? String(localized: "Play") : String(localized: "Install")
            return [(.a, primary), (.x, String(localized: "More")), (.b, String(localized: "Back")), (.guide, String(localized: "Menu"))]
        case .search: return [(.a, String(localized: "Type")), (.x, String(localized: "Delete")), (.y, String(localized: "Space")),
                              (.menu, String(localized: "Voice")), (.b, String(localized: "Back"))]
        case .settings: return [(.a, String(localized: "Change")), (.b, String(localized: "Back")), (.guide, String(localized: "Menu"))]
        }
    }
}

/// A button of the controller in hand, drawn plain: a letter or a PlayStation shape in a ring, a bumper or trigger
/// as a rounded box, Guide as a controller in a ring. No brand colours or logos.
struct Glyph: View {
    @Environment(AppModel.self) private var model
    @State private var input = ControllerInput.shared
    let event: ControllerEvent

    init(_ event: ControllerEvent) { self.event = event }

    private var playStation: Bool {
        switch model.settings.controllerMode?.labels ?? .automatic {
        case .xbox: false
        case .playStation: true
        case .automatic: input.kind == .playStation
        }
    }

    var body: some View {
        switch event {
        case .a, .b, .x, .y: ring(label)
        case .guide, .guideHeld: Circle().strokeBorder(CM.t2, lineWidth: 2.5).overlay(Image(systemName: "gamecontroller").font(CM.font(18, .semibold))).aspectRatio(1, contentMode: .fit)
        default: Text(label).font(CM.font(18, .bold)).padding(.horizontal, 10).frame(minWidth: 64, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CM.t2.opacity(0.5), lineWidth: 2))
        }
    }

    private func ring(_ text: String) -> some View {
        Circle().strokeBorder(CM.t2, lineWidth: 2.5).overlay(Text(text).font(CM.font(20, .bold))).aspectRatio(1, contentMode: .fit)
    }

    private var label: String {
        switch event {
        case .a: playStation ? "✕" : "A"
        case .b: playStation ? "○" : "B"
        case .x: playStation ? "□" : "X"
        case .y: playStation ? "△" : "Y"
        case .leftBumper: playStation ? "L1" : "LB"
        case .rightBumper: playStation ? "R1" : "RB"
        case .leftTrigger: playStation ? "L2" : "LT"
        case .rightTrigger: playStation ? "R2" : "RT"
        case .menu: playStation ? "Options" : "Menu"
        case .view: playStation ? "Create" : "View"
        default: ""
        }
    }
}
