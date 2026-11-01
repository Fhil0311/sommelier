// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    /// The sidebar shows unless the toolbar button (or Control-Command-S) hides it; remembered between launches.
    @SceneStorage("sidebarHidden") private var sidebarHidden = false

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.started {
                Color.clear                 // engines aren't read yet: "no engine" isn't a reason to flash the setup
            } else if model.needsSetup {
                SetupView()
            } else {
                NavigationSplitView(columnVisibility: Binding(
                    get: { sidebarHidden ? .detailOnly : .all },
                    set: { sidebarHidden = $0 == .detailOnly })) {
                    Sidebar()
                } detail: {
                    NavigationStack(path: $model.path) {
                        page(model.selection ?? .home)
                            // On the list pages only: a game's page has no search field (the text stays for coming back).
                            .modifier(LibrarySearch(text: $model.search, shown: !model.signedOutEverywhere && !model.onSignedOutStorePage))
                            .navigationDestination(for: Game.self) { GameDetailView(game: $0) }
                    }
                    .overlay(alignment: .top) { AnnouncementBanners().frame(maxWidth: 720) }   // floats over the page, under the toolbar
                    .animation(.easeOut(duration: 0.2), value: model.visibleAnnouncements.map(\.id))
                }
                .tint(Theme.wineLight)
                // Home: the cover wall runs behind the whole window, the sidebar glass over it.
                .background {
                    if model.homeShowsWall, (model.selection ?? .home) == .home, model.path.isEmpty {
                        CoverWall().ignoresSafeArea()
                    } else if let kind = model.signedOutStore, model.path.isEmpty {
                        StorePosterBackdrop(kind: kind).ignoresSafeArea()
                    }
                }
                .toolbar {
                    // With the sidebar hidden its Downloads card is out of sight: a pouring grape in the toolbar stands in.
                    if sidebarHidden, !model.activeDownloads.isEmpty {
                        ToolbarItem(placement: .primaryAction) { ToolbarDownloads() }
                    }
                    if updater.reminderVersion != nil, !updater.showingDetails {
                        ToolbarItem(placement: .primaryAction) { UpdateReminder() }
                    }
                }
                .toolbar(model.viewing == nil ? .visible : .hidden, for: .windowToolbar)   // the viewer has its own top bar
                .onChange(of: model.selection) { model.path = NavigationPath() }
            }
        }
        .overlay(alignment: .top) {
            // A controller just connected: the card at the top, once (Controller Mode shows its own note).
            if let pad = ControllerArrival.shared.shown, !ControllerModeWindow.shared.isOpen {
                ControllerConnectCard(pad: pad)
                    .padding(.top, 24)
                    .transition(.asymmetric(insertion: .offset(y: -22).combined(with: .scale(scale: 0.96)).combined(with: .opacity),
                                            removal: .offset(y: -14).combined(with: .opacity)))
            }
        }
        .environment(model.artwork)
        .overlay(alignment: .bottom) {
            Group {
            if let activity = model.activity {
                ActivityBar(title: activity, progress: model.shownProgress)
            } else if let steam = model.steamLaunchText {
                ActivityBar(title: steam, progress: nil) {
                }
            }
            }
        }
        .overlay {
            if let viewing = model.viewing { ScreenshotViewer(viewer: viewing).environment(model.artwork).transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if let game = model.poured { PouredToast(game: game).padding(.bottom, 22) }
        }
        .animation(.easeOut(duration: 0.25), value: model.poured?.id)
        .animation(.easeOut(duration: 0.2), value: model.steamLaunch)
        .modifier(GameDialogs())
        .modifier(StoreDialogs())
    }

    @ViewBuilder private func page(_ item: SidebarItem) -> some View {
        switch item {
        case .home: HomeView()
        case .allGames: LibraryView(title: String(localized: "All Games"), item: item)
        case .installed: LibraryView(title: String(localized: "Installed"), item: item)
        case .macVersions: LibraryView(title: String(localized: "Mac Versions"), item: item)
        case .collection(let id): CollectionView(id: id)
        case .clips: ClipsView()
        case .mods: ModsView()
        case .controllerMode: HomeView()
        case .store(let kind): LibraryView(title: kind.displayName, item: item)
        }
    }
}

/// "Elden Ring · Ready to play": a full grape and the news, for three seconds after an install ends.
struct PouredToast: View {
    @Environment(AppModel.self) private var model
    let game: Game

    /// The game's ready-made shaders came down with it: a second line, and the note stays a little longer.
    private var shadersReady: Bool { model.shadersReady.contains(game.id) }

    var body: some View {
        Button { model.open(game); model.poured = nil } label: {
            HStack(spacing: 10) {
                GrapePour(fraction: 1).foregroundStyle(Theme.wineLight).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(game.title).fontWeight(.bold) + Text(" · ") + Text("Ready to play"))
                        .foregroundStyle(Theme.onDark).lineLimit(1)
                    if shadersReady {
                        Text("Ready-made shaders downloaded").font(.caption).foregroundStyle(Theme.onDark.opacity(0.7))
                    }
                }
            }
            .padding(.leading, 12).padding(.trailing, Theme.Space.m).padding(.vertical, 10)
            .background(Theme.graphite.opacity(0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line(0.12)))
            .shadow(color: Theme.shadow(0.5), radius: 20, y: 10)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: "\(game.id) \(shadersReady)") {
            try? await Task.sleep(for: .seconds(3.2))
            if model.poured?.id == game.id { model.poured = nil }
        }
        .accessibilityAddTraits(.isStaticText)
    }
}

/// "Open Steam" that turns into a spinner while Steam is starting.
struct OpenSteamLabel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.steamLaunch != .idle {
            HStack(spacing: 6) { LoadingGrape(); Text("Opening…") }
                .accessibilityLabel("Opening Steam")
        } else {
            Label("Open Steam", systemImage: "macwindow")
        }
    }
}

struct ActivityBar<Accessory: View>: View {
    let title: String
    let progress: Double?
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, progress: Double?, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title; self.progress = progress; self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: 12) {
            if let progress { ProgressView(value: progress).frame(width: 160) } else { LoadingGrape() }
            Text(title).font(.callout)
            accessory()
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .padding(.bottom, Theme.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension ActivityBar where Accessory == EmptyView {
    init(title: String, progress: Double?) { self.init(title: title, progress: progress) { EmptyView() } }
}

/// "Starting…" with a spinner, then "In game" with the breathing grape: a game's launch state wherever it shows.
struct GameStateBadge: View {
    let state: AppModel.GameState
    var large = false
    /// The store window the launch waits on ("Answer in Steam"), when it waits on one.
    var waitingIn: StoreKind? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                switch state {
                case .starting:
                    if let store = waitingIn {
                        Image(systemName: "exclamationmark.bubble.fill")
                        Text("Answer in \(store.displayName)")
                    } else {
                        LoadingGrape().foregroundStyle(.white)
                        Text("Starting…")
                    }
                case .playing:
                    GrapeMark(filled: 6).frame(width: large ? 16 : 12, height: large ? 16 : 12)
                    Text("In game")
                }
            }
            .font(.system(size: large ? 14 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minHeight: large ? 36 : 22)
            .padding(.horizontal, large ? Theme.Space.m + 4 : Theme.Space.s + 2)
            .background(Capsule().fill(isPlaying ? Theme.wine : Color.black.opacity(0.6)))
            .animation(.easeOut(duration: 0.25), value: isPlaying)
        }
        .accessibilityElement(children: .combine)
    }

    private var isPlaying: Bool { if case .playing = state { true } else { false } }

}

/// The Play button's label: "Play", or the game's state while it starts or runs.
struct PlayLabel: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        switch model.state(of: game) {
        case .starting:
            if let store = model.storeDialogs[game.id] {
                HStack(spacing: 6) { Image(systemName: "exclamationmark.bubble.fill"); Text("Answer in \(store.displayName)") }
            } else {
                HStack(spacing: 6) { LoadingGrape(); Text("Starting…") }
            }
        case .playing: HStack(spacing: 7) { GrapeMark(filled: 6).frame(width: 15, height: 15); Text("In game") }
        case nil: Label("Play", systemImage: "play.fill")
        }
    }
}

/// An install's progress: "Downloading 45% · 1.2 GB of 2.7 GB" with a bar, or what Steam is waiting for.
struct InstallProgressView: View {
    @Environment(AppModel.self) private var model
    let state: AppModel.InstallState
    var compact = false
    /// White text on cover art and the game page; the normal text colour in list rows.
    var onArtwork = true

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            if let fraction {
                GrapePour(fraction: fraction).foregroundStyle(Theme.wineLight).frame(width: compact ? 12 : 30, height: compact ? 12 : 30)
            } else {
                ProgressView().controlSize(compact ? .mini : .small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                    .font(compact ? .caption.weight(.semibold) : .system(size: 13, weight: .bold))
                if !compact, let sizeLine {
                    Text(sizeLine).font(.system(size: 11.5)).foregroundStyle(onArtwork ? Theme.onArt.opacity(0.6) : Theme.onDarkSecondary).lineLimit(1)
                }
            }
            .monospacedDigit()
        }
        .foregroundStyle(onArtwork ? AnyShapeStyle(Theme.onArt) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .combine)
    }

    /// "3.6 GB of 15 GB", when Steam says.
    private var sizeLine: String? {
        guard case .steam(let d) = state, d.phase == .downloading || d.phase == .paused, d.bytesTotal > 0 else { return nil }
        return String(localized: "\(d.bytesDone.fileSize) of \(d.bytesTotal.fileSize)")
    }

    private var fraction: Double? {
        if case .steam(let d) = state, d.phase == .downloading || d.phase == .installing || d.phase == .paused { return d.fraction }
        if case .direct(let d) = state { return d.fraction }
        if case .launcher(_, let d) = state, d.phase != .queued { return d.fraction }
        return nil
    }

    private var title: String {
        switch state {
        case .confirmInSteam: return String(localized: "Confirm the install in Steam")
        case .direct(.downloading(let f)): return String(localized: "Downloading \(Int(f * 100))%")
        case .direct(let d): return d.title
        case .launcher(let store, let d):
            if d.phase == .downloading, let f = d.fraction { return String(localized: "Downloading \(Int(f * 100))%") }
            return d.title(store)
        case .steam(let d):
            let percent = d.fraction.map { Int($0 * 100) } ?? 0
            switch d.phase {
            case .queued: return String(localized: "Queued in Steam")
            case .paused: return String(localized: "Paused · \(percent)%")
            case .installing: return String(localized: "Installing…")
            case .done: return String(localized: "Installed")
            case .downloading: return String(localized: "Downloading \(percent)%")
            }
        }
    }
}

extension AppModel {
    /// A download in a few words for the sidebar: "24% · 3.6 GB", or what it's waiting for.
    func downloadShort(_ game: Game, _ state: InstallState) -> String {
        if case .direct(let d) = state { return d.title }
        if case .launcher(let store, let d) = state { return d.title(store) }
        guard case .steam(let d) = state else { return String(localized: "Confirm the install in Steam") }
        let percent = Int((d.fraction ?? 0) * 100)
        switch d.phase {
        case .queued: return String(localized: "Queued in Steam")
        case .paused: return String(localized: "Paused · \(percent)%")
        case .installing: return String(localized: "Installing…")
        case .done: return String(localized: "Installed")
        case .downloading: return d.bytesDone > 0 ? "\(percent)% · \(d.bytesDone.fileSize)" : "\(percent)%"
        }
    }

    /// The same with speed and time left, for the tooltip: "24% · 3.6 GB of 15 GB · 12 MB/s · 16 min left".
    func downloadDetail(_ game: Game, _ state: InstallState) -> String {
        guard case .steam(let d) = state, d.phase == .downloading else { return downloadShort(game, state) }
        let percent = Int((d.fraction ?? 0) * 100)
        var parts = [String(localized: "\(percent)% · \(d.bytesDone.fileSize) of \(d.bytesTotal.fileSize)")]
        if let rate = downloadRates[game.id], rate > 0 {
            parts.append(String(localized: "\(Int64(rate).fileSize)/s"))
            let left = Double(d.bytesTotal - d.bytesDone) / rate
            // Seconds only near the end; over ten minutes they just flicker.
            Self.eta.allowedUnits = left > 600 ? [.hour, .minute] : [.minute, .second]
            if left > 0, left < 360_000, let eta = Self.eta.string(from: left) {
                parts.append(String(localized: "\(eta) left"))
            }
        }
        return parts.joined(separator: " · ")
    }

    nonisolated(unsafe) static let eta: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()
}

extension DirectInstall {
    var title: String {
        switch self {
        case .queued: String(localized: "Waiting for another download")
        case .preparing: String(localized: "Preparing…")
        case .downloading(let f): String(localized: "Downloading \(Int(f * 100))%")
        case .paused(let f): f.map { String(localized: "Paused · \(Int($0 * 100))%") } ?? String(localized: "Paused")
        }
    }
}

extension LauncherDownload {
    func title(_ store: StoreKind) -> String {
        let percent = fraction.map { Int($0 * 100) }
        switch phase {
        case .opening: return String(localized: "Opening \(store.displayName)…")
        case .confirm: return String(localized: "Confirm in \(store.displayName)")
        case .queued: return String(localized: "Queued in \(store.displayName)")
        case .paused: return percent.map { String(localized: "Paused · \($0)%") } ?? String(localized: "Paused")
        case .downloading: return percent.map { String(localized: "Downloading \($0)%") } ?? String(localized: "Downloading…")
        }
    }
}

extension StoreKind: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// "The game didn't start": what went wrong, in plain words, and one button that fixes it and tries again.
struct LaunchFailureView: View {
    @Environment(AppModel.self) private var model
    let failure: LaunchFailure
    /// The report's preview: exactly what "Send" sends.
    @State private var showingReport = false

    var body: some View {
        let game = failure.game
        let rule = failure.rule
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m - 4) {
                Image(systemName: rule?.action != nil ? "wrench.and.screwdriver.fill" : "exclamationmark.triangle.fill")
                    .font(.title).foregroundStyle(rule?.action != nil ? Theme.onDark : Theme.wineLight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.diagnostics.secondsRunning.map { String(localized: "\(game.title) closed after \($0) seconds") }
                         ?? String(localized: "\(game.title) didn't start")).font(.headline)
                    Text(rule.map { model.fixCause($0, for: game) } ?? String(localized: "Sommelier doesn't recognise the problem yet. The log may say more, and sending a report helps fix it for everyone."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let rule, let action = rule.action {
                Label(model.fixTitle(action, for: game), systemImage: action.isUndoable ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .help(action.isUndoable ? String(localized: "Can be undone from the game's menu") : String(localized: "Harmless to keep"))
            }
            if showingReport { reportPreview }
            HStack(spacing: Theme.Space.m) {
                Button("Show Log") { model.showLog(for: game.id) }.buttonStyle(.textLink)
                reportButton
                Button("Ask on Discord") { Links.open(Links.discord) }.buttonStyle(.textLink)   // when nothing helped: people
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("Close") { model.launchFailure = nil }.keyboardShortcut(.cancelAction)
                if let rule, let action = rule.action {
                    Button { Task { await model.applyFix(rule, to: game) } } label: {
                        if failure.applying { LoadingGrape() } else { Text(model.fixButton(action, for: game)) }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(failure.applying)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: showingReport ? 640 : 500)
        .animation(.easeInOut(duration: 0.2), value: showingReport)
    }

    @ViewBuilder private var reportButton: some View {
        switch failure.reportState {
        case .sent:
            Label("Report sent. Thank you!", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
        case .sending:
            LoadingGrape()
        case .failed:
            Button("Couldn't send. Try Again") { Task { await model.sendFailureReport() } }
        case .notSent:
            if showingReport {
                Button("Send Report") { Task { await model.sendFailureReport() } }
            } else {
                Button("Send Report…") { showingReport = true }.buttonStyle(.textLink)
                    .help(String(localized: "Shows what would be sent first"))
            }
        }
    }

    /// Everything the report holds: a summary in plain words, the end of the game's log with names and accounts
    /// taken out, and on request the report exactly as it is sent.
    private var reportPreview: some View {
        let report = model.failureReport(failure)
        let d = report.diagnostics
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("This is what the report sends. Your name, accounts and home folder are taken out of the logs.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: 3) {
                row(String(localized: "Game"), "\(failure.game.title) · \(failure.game.store.displayName)")
                row("Sommelier", [report.sommelier.app, d.engineVersion.map { String(localized: "engine \($0)") }].compactMap { $0 }.joined(separator: ", "))
                if let backend = d.backend { row(String(localized: "Graphics"), GraphicsBackend(rawValue: backend)?.localizedName ?? backend) }
                row("Mac", [d.chip, d.macOS.isEmpty ? "" : "macOS \(d.macOS)"].filter { !$0.isEmpty }.joined(separator: ", ").ifEmpty("—"))
                row(String(localized: "What happened"), d.secondsRunning.map { String(localized: "Closed after \($0) seconds") } ?? String(localized: "Didn't start"))
                row(String(localized: "Recognised"), report.matched.isEmpty ? String(localized: "Nothing yet") : report.matched.joined(separator: ", "))
            }
            .font(.callout)
            Text("Game log (the end)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(d.logTail.isEmpty ? String(localized: "No log") : d.logTail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(Theme.Space.s)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
            DisclosureGroup("Exactly what is sent") {
                ScrollView([.vertical, .horizontal]) {
                    Text(report.preview).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            .font(.callout)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// A small card over a dimmed window, for a question that needs an answer before going on (the site's sheets).
struct InWindowSheet<Content: View>: View {
    let dismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(18)
                .frame(width: 420, alignment: .leading)
                .background(Theme.graphite, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line(0.12)))
                .shadow(color: Theme.shadow(0.9), radius: 40, y: 30)
                .padding(.top, 120)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
        .onExitCommand(perform: dismiss)
    }
}

/// A sheet's buttons: plain light ones; the recommended answer in cream, or in wine when it's the way out of a warning.
struct SheetButtonStyle: ButtonStyle {
    enum Kind { case plain, primary, warning }
    var kind = Kind.plain
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(kind == .primary ? Theme.ink : kind == .warning ? .white : Theme.onDark)
            .padding(.horizontal, 12).frame(height: 28)
            .background(kind == .primary ? AnyShapeStyle(Theme.cream) : kind == .warning ? AnyShapeStyle(Theme.wine) : AnyShapeStyle(Theme.fill(0.12)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Before installing a game that probably won't run (or needs DirectX 12 set up first): why, and a way out.
struct InstallWarningSheet: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let rating = model.compatibility(of: game)
        let needsSetup = model.needsD3DMetal(game) && !rating.warnsBeforeInstall
        InWindowSheet(dismiss: { model.installWarning = nil }) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if needsSetup { Image(systemName: "cpu").font(.system(size: 22)).foregroundStyle(Theme.onDark) }
                    else { rating.verdict.mark.foregroundStyle(rating.verdict.color) }
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(needsSetup ? String(localized: "\(game.title) needs DirectX 12 setup")
                         : rating.verdict == .wontRun ? String(localized: "\(game.title) probably won't run")
                         : "\(game.title): \(rating.verdict.localizedTitle)")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onDark)
                    Text(needsSetup ? String(localized: "This game needs DirectX 12. Set it up once, and every DirectX 12 game can run.")
                         : rating.localizedExplanation ?? "")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Install Anyway") { model.installWarning = nil; Task { await model.install(game, confirmed: true) } }
                    .buttonStyle(SheetButtonStyle())
                if needsSetup {
                    Button("Set Up DirectX 12") { model.installWarning = nil; model.beginD3DMetalSetup() }
                        .buttonStyle(SheetButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Don't Install") { model.installWarning = nil }
                        .buttonStyle(SheetButtonStyle(kind: .warning)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 6)
        }
    }
}

/// "Install from where?": the same game in several stores, each with how it arrives, the first one chosen.
struct StorePickSheet: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var chosen: String?

    var body: some View {
        let copies = model.copies(of: game)
        let selected = chosen ?? game.id
        InWindowSheet(dismiss: { model.storePick = nil }) {
            HStack(spacing: 12) {
                Artwork(url: model.coverURL(for: game), title: game.title, titleOnPlaceholder: false, fallback: model.headerURL(for: game))
                    .frame(width: 34, height: 46).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install from where?").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onDark)
                    Text(game.title).font(.system(size: 12.5)).foregroundStyle(Theme.onDarkSecondary).lineLimit(1)
                }
            }
            VStack(spacing: 6) {
                ForEach(copies) { copy in
                    let on = copy.id == selected
                    Button { chosen = copy.id } label: {
                        HStack(spacing: 10) {
                            copy.store.logo.resizable().scaledToFit().frame(width: 18, height: 18).foregroundStyle(Theme.onDark)
                            Text(copy.store.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onDark)
                            Spacer()
                            Circle().strokeBorder(on ? Theme.onDark : Theme.line(0.35), lineWidth: on ? 5 : 1.5).frame(width: 16, height: 16)
                        }
                        .padding(10)
                        .background(Theme.fill(on ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line(on ? 0.3 : 0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.storePick = nil }.buttonStyle(SheetButtonStyle())
                Button("Install") {
                    model.storePick = nil
                    let copy = copies.first { $0.id == selected } ?? game
                    Task { await model.install(copy, storeChosen: true) }
                }
                .buttonStyle(SheetButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
    }
}

/// The sheets and alerts about games (set-up, warnings, failures), kept out of `ContentView.body`: one long
/// modifier chain there takes the compiler too long to check.
private struct GameDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
        .overlay {
            if let game = model.installWarning { InstallWarningSheet(game: game) }
            else if let game = model.storePick { StorePickSheet(game: game).environment(model.artwork) }
        }
        .animation(.easeOut(duration: 0.2), value: model.installWarning?.id)
        .animation(.easeOut(duration: 0.2), value: model.storePick?.id)
        .sheet(isPresented: Binding(get: { model.d3dSetup != nil }, set: { if !$0 { model.cancelD3DMetalSetup() } })) {
            DirectX12SetupView().environment(model)
        }
        .sheet(item: $model.signIn) { StoreSignInView(kind: $0).environment(model) }
        .sheet(item: $model.launchFailure) { LaunchFailureView(failure: $0).environment(model) }
        .alert(model.stuckLaunch.map { String(localized: "Launching \($0.title) got stuck") } ?? "",
               isPresented: Binding(get: { model.stuckLaunch != nil }, set: { if !$0 { model.stuckLaunch = nil } }),
               presenting: model.stuckLaunch) { game in
            Button("Close", role: .cancel) { model.stuckLaunch = nil }
            Button("Start Again") { Task { await model.restartStuckLaunch(game) } }.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Sommelier can start the launch again.")
        }
        .sheet(item: $model.tuningNotice) { TuningNoticeView(game: $0).environment(model).interactiveDismissDisabled() }
        .sheet(item: $model.disputeTarget) { DisputeSheet(game: $0).environment(model) }
        // The mods flow (AppModel+Mods): the code sheet, a plan's question, other tools' files before a launch.
        .sheet(item: $model.modConsent) { CodeConsentSheet(consent: $0).interactiveDismissDisabled() }
        .sheet(item: $model.modQuestion) { ModQuestionSheet(question: $0).interactiveDismissDisabled() }
        .sheet(item: $model.modLeftovers) { ModLeftoversSheet(leftovers: $0).environment(model) }
        .sheet(isPresented: Binding(get: { model.needsSharingConsent && model.launchFailure == nil && model.d3dSetup == nil },
                                    set: { _ in })) {
            SharingConsentView().environment(model)
        }
    }
}

/// The alerts about stores and saves.
private struct StoreDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
        .alert(model.saveSyncFailure.map { String(localized: "Couldn't sync saves for \($0.title)") } ?? "",
               isPresented: Binding(get: { model.saveSyncFailure != nil }, set: { if !$0 { model.saveSyncFailure = nil } }),
               presenting: model.saveSyncFailure) { game in
            Button("Play Without Syncing") { Task { await model.playWithoutSyncing(game) } }
            Button("Cancel", role: .cancel) {}
        } message: { game in
            Text("\(game.store.displayName)'s cloud didn't answer. Playing now uses the saves on this Mac; they're synced next time.")
        }
        .alert(model.saveConflict.map { String(localized: "\($0.game.title): saves differ") } ?? "",
               isPresented: Binding(get: { model.saveConflict != nil }, set: { if !$0 { model.saveConflict = nil } }),
               presenting: model.saveConflict) { conflict in
            let launching = !model.isActive(conflict.game)
            Button("Use Cloud Saves") { Task { await model.resolveSaveConflict(conflict, useCloud: true, thenPlay: launching) } }
            Button("Keep This Mac's Saves") { Task { await model.resolveSaveConflict(conflict, useCloud: false, thenPlay: launching) } }
            Button("Cancel", role: .cancel) {}
        } message: { conflict in
            Text("The saves on this Mac and in the cloud both changed since the last sync.\nCloud: \(conflict.cloud)\nThis Mac: \(conflict.local)\nThe other side is replaced.")
        }
        .alert(model.macVersionChoice.map { String(localized: "\($0.title) has a Mac version") } ?? "",
               isPresented: Binding(get: { model.macVersionChoice != nil }, set: { if !$0 { model.macVersionChoice = nil } }),
               presenting: model.macVersionChoice) { game in
            Button("Set Up Steam for Mac and Install") {
                model.settings.steamMacVersions = "native"
                Task { await model.setUpSteamForMac(then: game) }
            }
            Button("Install the Windows Version") {
                model.settings.steamMacVersions = "windows"
                Task { await model.install(game, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The Mac version runs natively and needs Valve's Steam for Mac, which Sommelier can set up now (you sign in to it once). Your choice is remembered; change it in Settings > Games.")
        }
        .alert(model.pendingUninstall.map { String(localized: "Uninstall \($0.title)?") } ?? "",
               isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } }),
               presenting: model.pendingUninstall) { game in
            Button("Uninstall", role: .destructive) { Task { await model.confirmUninstall(game) } }
            Button("Cancel", role: .cancel) {}
        } message: { game in
            Text("Its files are deleted from this Mac\(game.knownSize.map { " (\($0))" } ?? ""). You can install it again from your \(game.store.displayName) library at any time.")
        }
        .modifier(UsageNotice(model: model))
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

/// The toolbar's downloads button while the sidebar is hidden: the leading download's grape filling up and its
/// percentage; clicking shows the same Downloads card as the sidebar.
private struct ToolbarDownloads: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let first = model.activeDownloads.first
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                GrapePour(fraction: first?.state.fraction ?? 0).foregroundStyle(Theme.wineLight).frame(width: 16, height: 16)
                if let fraction = first?.state.fraction {
                    Text("\(Int((fraction * 100).rounded()))%").monospacedDigit()
                }
            }
        }
        .help(String(localized: "Downloads"))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SidebarDownloads().padding(.vertical, Theme.Space.s).frame(width: 280)
        }
    }
}

/// The toolbar's search field, left out until a store is signed in to (nothing to search before that).
private struct LibrarySearch: ViewModifier {
    @Binding var text: String
    let shown: Bool

    func body(content: Content) -> some View {
        if shown { content.searchable(text: $text, placement: .toolbar, prompt: "Search games") } else { content }
    }
}

/// Players who agreed to share before stores and features were part of it: told once.
private struct UsageNotice: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.alert("Now Sommelier also shares which stores and features you use.",
                      isPresented: Binding(get: { model.sharesReports && model.settings.usageNoticeShown != true && !model.needsSharingConsent },
                                           set: { if !$0 { model.settings.usageNoticeShown = true } })) {
            Button("OK") { model.settings.usageNoticeShown = true }
        } message: {
            Text("You can turn sharing off in Settings.")
        }
    }
}
