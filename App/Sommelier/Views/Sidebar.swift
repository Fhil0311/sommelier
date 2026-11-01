// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

enum SidebarItem: Hashable {
    case home, allGames, installed, macVersions, clips, mods, controllerMode
    case collection(String)
    case store(StoreKind)
}

/// Navigation on the system sidebar material, over the app's warm surface. Counts sit in small pills.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: GameCollection?
    @State private var newName = ""

    var body: some View {
        // Rows select themselves rather than through List selection: the system highlight takes the wine accent,
        // and the design wants a light row instead.
        List {
            item(.home) { Label { Text("Home") } icon: { NavGlyph(kind: .home) }.labelStyle(DimmedIcon(selected: isSelected(.home))) }
            // Library and Collections wait for a store to be signed in to: until then they would only be empty.
            if !model.signedOutEverywhere {
            Section("Library") {
                row(String(localized: "All Games"), .allGames) { NavGlyph(kind: .all) }
                // Only once a game is installed or installing: before that the page would only be empty.
                if !model.games(for: .installed).isEmpty {
                    row(String(localized: "Installed"), .installed) { NavGlyph(kind: .installed) }
                }
                if !model.games(for: .macVersions).isEmpty {
                    row(String(localized: "Mac Versions"), "apple.logo", .macVersions)
                }
                item(.mods) {
                    Label { Text("Mods") } icon: { Image(systemName: "puzzlepiece.extension") }.labelStyle(DimmedIcon(selected: isSelected(.mods)))
                }
                item(.clips) {
                    Label { counted(String(localized: "Clips"), ClipRecorder.shared.clips.count) } icon: { Image(systemName: "film") }
                        .labelStyle(DimmedIcon(selected: isSelected(.clips)))
                }
            }
            Section("Collections") {
                ForEach(model.collections) { shelf in collectionRow(shelf) }
                if model.naming != nil {
                    NamingRow()
                } else {
                    Button { model.beginNamingCollection() } label: {
                        Label("New Collection", systemImage: "plus")
                            .foregroundStyle(Theme.onDarkTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            }
            Section("Stores") {
                ForEach(model.storesInUse, id: \.self) { kind in
                    storeRow(kind)
                }
            }
            // Controller Mode is left out of the sidebar for now (its page stays for later).
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
          VStack(spacing: Theme.Space.s) {
            SidebarDownloads()
            // The last game, as a compact "now playing" strip at the foot: the menu itself starts with Home.
            if model.settings.showContinueCard == true, let game = continueGame {
                ContinueCard(game: game).padding(.horizontal, Theme.Space.s + 2)
            }
            UpdateBadge()
            // Controller Mode changes the whole app's look, so it sits with Settings rather than among the pages.
            Button { ControllerModeWindow.shared.enter(model: model) } label: {
                Label { Text("Controller Mode") } icon: { Image(systemName: "gamecontroller").frame(width: 15, height: 15) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.m + 2)
            // Settings are also in the app menu (⌘,); this makes them visible without knowing that.
            SettingsLink {
                Label { Text("Settings") } icon: { BerryGear().frame(width: 15, height: 15) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.m + 2)
            .padding(.vertical, Theme.Space.m - 4)
            .help("Settings (⌘,)")
          }
        }
        .scrollContentBackground(.hidden)
        .background {
            if (model.homeShowsWall && (model.selection ?? .home) == .home && model.path.isEmpty)
                || (model.signedOutStore != nil && model.path.isEmpty) {
                // Glass over the signed-out Home's cover wall.
                Rectangle().fill(.ultraThinMaterial).overlay(Theme.ink.opacity(0.55)).ignoresSafeArea()
            } else {
                Theme.surface.overlay(Theme.fill(0.055)).ignoresSafeArea()
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        // The last game uninstalled while Installed is open: its row goes, so the page moves to All Games.
        .onChange(of: model.games(for: .installed).isEmpty) { _, empty in
            if empty, model.selection == .installed { model.selection = .allGames }
        }
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Collection name", text: $newName)
            Button("Rename") { if let renaming { model.rename(collection: renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ symbol: String, _ item: SidebarItem) -> some View {
        row(title, item) { Image(systemName: symbol) }
    }

    private func row<Icon: View>(_ title: String, _ item: SidebarItem, @ViewBuilder icon: () -> Icon) -> some View {
        let count = model.games(for: item).count
        return self.item(item) { Label { counted(title, count) } icon: { icon() }.labelStyle(DimmedIcon(selected: isSelected(item))) }
            .accessibilityLabel(String(localized: "\(title), \(count) games"))
    }

    /// The game running now, or else the one played last.
    private var continueGame: Game? {
        let installed = model.games(for: .installed).filter(\.isInstalled)
        return installed.first { model.state(of: $0) != nil }
            ?? installed.filter { model.lastPlayed($0) != nil }.max { model.lastPlayed($0)! < model.lastPlayed($1)! }
    }

    /// A row that selects its page; the selected one sits on a light plate with a brighter icon.
    private func isSelected(_ item: SidebarItem) -> Bool { (model.selection ?? .home) == item }

    private func item<Content: View>(_ item: SidebarItem, @ViewBuilder label: () -> Content) -> some View {
        let selected = (model.selection ?? .home) == item
        return Button { model.selection = item } label: {
            label()
                .foregroundStyle(selected ? Theme.onDark : Theme.onDark.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.fill(selected ? 0.13 : 0))
                .padding(.horizontal, Theme.Space.s + 2)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func collectionRow(_ shelf: GameCollection) -> some View {
        let games = model.gamesIn(collection: shelf.id)
        return item(.collection(shelf.id)) {
            Label { counted(shelf.name, games.count) } icon: { CollectionMosaic(games: games, size: 18) }
        }
        .contextMenu {
            Button("Rename…") { renaming = shelf; newName = shelf.name }
            Button("Delete Collection", role: .destructive) { model.delete(collection: shelf.id) }
        }
        .accessibilityLabel(String(localized: "\(shelf.name), \(games.count) games"))
    }

    /// A row's name with its count in a pill at the trailing edge.
    private func counted(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            Text(count, format: .number)
                .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.onDarkTertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.fill(0.07), in: Capsule())
        }
    }

    private func storeRow(_ kind: StoreKind) -> some View {
        let count = model.games(for: .store(kind)).count
        return item(.store(kind)) {
            // No count for a store not signed in to: "0" would read as "you have no games there".
            Label { if model.storesWithAccount.contains(kind) { counted(kind.displayName, count) } else { Text(kind.displayName) } } icon: { kind.logo.resizable().scaledToFit().frame(width: 15, height: 15) }
                .labelStyle(DimmedIcon(selected: isSelected(.store(kind))))
        }
            .accessibilityLabel(String(localized: "\(kind.displayName), \(count) games"))
    }
}

/// The row where a new collection gets its name: a field in place, outlined in the accent. Return makes it,
/// Esc or clicking away drops it.
struct NamingRow: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.line(0.3), lineWidth: 1.5)
                .frame(width: 18, height: 18)
            TextField("Collection name", text: $name)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.finishNamingCollection(name) }
                .onExitCommand { model.naming = nil }
        }
        .padding(.horizontal, 6).frame(height: 26)
        .background(Theme.fill(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.wineLight, lineWidth: 1.5))
        .onAppear { focused = true }
        .onChange(of: focused) { if !focused, model.naming != nil { model.finishNamingCollection(name) } }
    }
}

/// Up to four covers in a square: a collection's picture. Empty, an outlined square.
struct CollectionMosaic: View {
    let games: [Game]
    var size: CGFloat = 18
    @Environment(AppModel.self) private var model

    var body: some View {
        let radius = size > 40 ? 14.0 : 5.0
        Group {
            if games.isEmpty {
                // Dashed, so the empty tile doesn't read as a checkbox; the large one says what to do.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.line(0.3), style: StrokeStyle(lineWidth: size > 40 ? 2 : 1.5, dash: size > 40 ? [6, 4] : [2.5, 2]))
                    .overlay { if size > 40 { Image(systemName: "plus").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.onDarkTertiary) } }
            } else if games.count < 4 {
                cover(games[0])
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cover(games[0]); cover(games[1]) }
                    GridRow { cover(games[2]); cover(games[3]) }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: Theme.shadow(size > 40 ? 0.7 : 0), radius: 15, y: 12)
    }

    private func cover(_ game: Game) -> some View {
        Theme.fill(0.08)
            .overlay { Artwork(url: model.coverURL(for: game), title: game.title, titleOnPlaceholder: false, fallback: model.headerURL(for: game)) }
            .clipped()
    }
}

/// The game to go back to, at the top of the sidebar: its art, name, when it was last played, and Play.
/// While it runs, the line under the name becomes "In game · 12:04", the session ticking.
struct ContinueCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var hovering = false

    var body: some View {
        let playing = model.state(of: game) != nil
        Button { model.open(game) } label: {
            HStack(spacing: 9) {
                Artwork(url: model.coverURL(for: game), title: game.title, fallback: model.headerURL(for: game))
                    .frame(width: 30, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                    if case .playing(let since) = model.state(of: game) {
                        // The session's time, ticking: it says the game is running without anything blinking.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(String(localized: "In game · \(Self.clock(context.date.timeIntervalSince(since)))"))
                        }
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.onDarkSecondary)
                    } else if playing {
                        Text("Starting…").font(.system(size: 11)).foregroundStyle(Theme.onDarkSecondary)
                    } else {
                        Text(meta).font(.system(size: 11)).foregroundStyle(Theme.onDarkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 34)   // room for the round Play button laid over the row
            }
            .padding(6)
            .background {   // opaque, so rows scrolling under it don't show through
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.fill(hovering ? 0.11 : 0.07)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if !playing {
                Button { Task { await model.play(game) } } label: {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 26, height: 26).background(Theme.cream, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .accessibilityLabel("Play \(game.title)")
                .help("Play")
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(game.title)
    }

    /// "12:04", or "1:12:04" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds)), h = s / 3600, m = s % 3600 / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    private var meta: String {
        [model.lastPlayed(game)?.playedAgo, model.playTime(game) > 0 ? model.playTime(game).playTime : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// "Downloads" at the foot of the sidebar: each game's cover, name and progress, with its grapes filling up.
/// Clicking opens the game's page; the context menu pauses, resumes, cancels or shows the download in its store.
struct SidebarDownloads: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.activeDownloads
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Downloads").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onDarkTertiary)
                    .padding(.horizontal, 2)
                ForEach(active, id: \.game.id) { game, state in row(game, state) }
            }
            .padding(Theme.Space.s)
            .background {   // opaque, so rows scrolling under it don't show through
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.11)))
            }
            .padding(.horizontal, Theme.Space.s + 2)
            .transition(.opacity)
        }
    }

    private func row(_ game: Game, _ state: AppModel.InstallState) -> some View {
        Button { model.open(game) } label: {
            HStack(spacing: 9) {
                Artwork(url: model.coverURL(for: game), title: game.title, titleOnPlaceholder: false, fallback: model.headerURL(for: game))
                    .frame(width: 22, height: 33)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                    Text(model.downloadShort(game, state)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Theme.onDarkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let fraction = state.fraction {
                    GrapePour(fraction: fraction).foregroundStyle(Theme.wineLight).frame(width: 22, height: 22)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.downloadDetail(game, state))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .contextMenu {
            if model.canPause(game, state) {
                Button("Pause") { Task { await model.pauseDownload(game) } }
            } else if model.canResume(game, state) {
                Button("Resume") { Task { await model.resumeDownload(game) } }
            }
            if case .direct = state {
                Button("Cancel Download") { model.cancelDirectInstall(game) }
            } else if case .launcher(let store, _) = state {
                Button(String(localized: "Show in \(store.displayName)")) { Task { await model.openLauncher(store) } }
            } else {
                Button("Cancel Download…") { Task { await model.uninstall(game) } }
                Button("Show Downloads in Steam") { Task { await model.openSteamDownloads(for: game) } }
            }
        }
    }
}

/// A small icon and word, close together.
struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.font(.system(size: 9, weight: .bold)); configuration.title }
    }
}

/// The small cream "Play" pill on cards: a word rather than a bare media glyph. The ghost one, for Install in
/// lists, is a faint light pill instead.
struct QuickPlayButtonStyle: ButtonStyle {
    var ghost = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(ghost ? Theme.onDark : Theme.ink)
            .padding(.leading, 8).padding(.trailing, 10).frame(height: 24)
            .background(ghost ? AnyShapeStyle(Theme.fill(0.1)) : AnyShapeStyle(Theme.cream), in: Capsule())
            .shadow(color: Theme.shadow(ghost ? 0 : 0.35), radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// The wine dot that pulses while a game runs.
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle().fill(Theme.wineLight).frame(width: 6, height: 6)
            .background(Circle().fill(Theme.wineLight.opacity(pulse ? 0.08 : 0.25)).padding(pulse ? -5 : -3))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

extension StoreKind {
    /// The store's logo, one colour (it takes the colour of the text around it). Only names the store.
    var logo: Image { Image(logoName) }

    var logoName: String {
        switch self {
        case .steam: "StoreSteam"
        case .epic: "StoreEpic"
        case .gog: "StoreGOG"
        case .ubisoft: "StoreUbisoft"
        case .ea: "StoreEA"
        case .battlenet: "StoreBattleNet"
        }
    }
}

/// A sidebar row's icon is quieter than its name until the row is selected, as on the site's demo.
private struct DimmedIcon: LabelStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        Label { configuration.title } icon: { configuration.icon.opacity(selected ? 1 : 0.68) }
            .labelStyle(DefaultLabelStyle())
    }
}

/// Home, All Games and Installed (design: nav-icons.html, set C): familiar shapes at the berry gear's line weight,
/// each with one berry: the house's window, the poured cell, the light on the disk.
private struct NavGlyph: View {
    enum Kind { case home, all, installed }
    let kind: Kind

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 24
            ctx.scaleBy(x: k, y: k)
            let line = StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
            func berry(_ x: Double, _ y: Double, _ side: Double, _ radius: Double) {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerRadius: radius), with: .foreground)
            }
            switch kind {
            case .home:
                var house = Path()
                house.move(to: CGPoint(x: 3.5, y: 11)); house.addLine(to: CGPoint(x: 12, y: 3.8)); house.addLine(to: CGPoint(x: 20.5, y: 11))
                house.move(to: CGPoint(x: 5.8, y: 9.4)); house.addLine(to: CGPoint(x: 5.8, y: 19.5))
                house.addLine(to: CGPoint(x: 18.2, y: 19.5)); house.addLine(to: CGPoint(x: 18.2, y: 9.4))
                ctx.stroke(house, with: .foreground, style: line)
                berry(9.6, 12.6, 4.8, 1.1)
            case .all:
                for (x, y) in [(3.5, 3.5), (13.5, 3.5), (3.5, 13.5)] {
                    ctx.stroke(Path(roundedRect: CGRect(x: x, y: y, width: 7, height: 7), cornerRadius: 1.8), with: .foreground, lineWidth: 1.7)
                }
                berry(13.5, 13.5, 7, 1.8)
            case .installed:
                var arrow = Path()
                arrow.move(to: CGPoint(x: 12, y: 3)); arrow.addLine(to: CGPoint(x: 12, y: 11.5))
                arrow.move(to: CGPoint(x: 8.3, y: 8.2)); arrow.addLine(to: CGPoint(x: 12, y: 11.8)); arrow.addLine(to: CGPoint(x: 15.7, y: 8.2))
                ctx.stroke(arrow, with: .foreground, style: line)
                ctx.stroke(Path(roundedRect: CGRect(x: 3.5, y: 14, width: 17, height: 6.5), cornerRadius: 1.8), with: .foreground, style: line)
                berry(15.3, 16.1, 2.4, 0.6)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}
