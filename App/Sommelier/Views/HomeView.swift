// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// Home: a banner that cycles through what matters now, what's downloading, what was played lately, what's ready,
/// what from the library would run well, and the stores. A new user sees three steps instead.
struct HomeView: View {
    /// The page's appearance (the header's art is always dark).
    @Environment(\.colorScheme) private var pageScheme
    @Environment(AppModel.self) private var model
    @Environment(ArtworkStore.self) private var artwork

    /// Which banner the carousel shows; it moves on by itself every few seconds unless the pointer rests on it.
    @State private var slide = 0
    @State private var paused = false
    /// The banner's trailer plays once the pointer has rested on it a moment.
    @State private var showTrailer = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.homeShowsWall { SignedOutHome() } else { home }
    }

    @ViewBuilder private var home: some View {
        let installed = model.games(for: .installed).filter(\.isInstalled)
        let recent = installed.filter { model.lastPlayed($0) != nil }
            .sorted { (model.lastPlayed($0) ?? .distantPast) > (model.lastPlayed($1) ?? .distantPast) }
        let ready = installed.sorted { (model.lastPlayed($0) ?? .distantPast) > (model.lastPlayed($1) ?? .distantPast) }
        let likely = likelyToRun()
        let slides = featured(recent: recent, ready: ready, likely: likely)
        let hero = slides.indices.contains(slide) ? slides[slide] : slides.first
        let tint = hero.flatMap { artwork.tint(model.heroURL(for: $0)) } ?? Theme.wine

        GeometryReader { geo in
            let heroHeight = min(max(geo.size.width * 0.42, 300), 440)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // The art keeps light text on dark in both appearances.
                    if !slides.isEmpty { carousel(slides, height: heroHeight, tint: tint).environment(\.colorScheme, .dark) }

                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        if !ready.isEmpty { row("Ready to Play", ready, width: 150) { model.selection = .installed } }
                        if !recent.isEmpty { recentRow(recent) }
                        if !likely.isEmpty { row("Should Run Well", likely, width: 150) { model.selection = .allGames } }
                        storesRow
                    }
                    .padding(.horizontal, Theme.Space.margin)
                    .padding(.top, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.margin)
                }
            }
            .background(Theme.tintedBackground(tint, heroHeight: heroHeight))
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Home")
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { model.tint = tint }
        .onChange(of: tint) { model.tint = tint }
        .task(id: hero?.id) { if let hero { await model.loadInfo(for: hero) } }
        .task(id: slides.count) {
            // Like Steam's featured banner: the next game every eight seconds, unless the pointer rests on it.
            guard slides.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if !paused { withAnimation(.easeInOut(duration: 0.6)) { slide = (slide + 1) % slides.count } }
            }
        }
    }

    // MARK: What to show

    /// The banner's slides, the most pressing first: a game that just finished installing, then what was played
    /// last, the rest of what's installed, and a few library games that would run well; six at most.
    private func featured(recent: [Game], ready: [Game], likely: [Game]) -> [Game] {
        var picks: [Game] = []
        func add(_ games: [Game]) { for g in games where picks.count < 6 && !picks.contains(where: { $0.id == g.id }) { picks.append(g) } }
        add(ready.filter { model.justInstalled(game: $0) })
        add(recent)
        add(ready)
        add(likely)
        return picks
    }

    /// Library games not installed that look likely to run: Steam Deck verified or playable, or with a Mac
    /// version that runs here; best first, ten at most.
    private func likelyToRun() -> [Game] {
        model.games(for: .allGames).filter { !$0.isInstalled && model.installState(of: $0) == nil }
            .filter { model.compatibility(of: $0).verdict <= .likely }
            .sorted { model.compatibility(of: $0).verdict < model.compatibility(of: $1).verdict }
            .prefix(10).map { $0 }
    }

    private func eyebrow(for game: Game) -> String {
        if model.justInstalled(game: game) { return String(localized: "Just installed") }
        if !game.isInstalled { return String(localized: "Should run well") }
        return model.lastPlayed(game) == nil ? String(localized: "Ready to play") : String(localized: "Continue playing")
    }

    // MARK: Banner

    private func carousel(_ slides: [Game], height: CGFloat, tint: Color) -> some View {
        let current = min(slide, slides.count - 1)
        return ZStack(alignment: .bottomTrailing) {
            banner(slides[current], height: height, tint: tint)
                .id(slides[current].id)
                .transition(.opacity)
            if slides.count > 1 {
                // Dots in the corner, clear of the title: each picks a game; the current one is a longer cream bar.
                HStack(spacing: 6) {
                    ForEach(slides.indices, id: \.self) { i in
                        Button { withAnimation(.easeInOut(duration: 0.4)) { slide = i } } label: {
                            Capsule().fill(i == current ? Theme.cream : .white.opacity(0.4))
                                .frame(width: i == current ? 20 : 7, height: 7)
                                .padding(4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(slides[i].title)
                    }
                }
                .padding(.horizontal, Theme.Space.margin).padding(.bottom, Theme.Space.l)
                .animation(.easeInOut(duration: 0.3), value: current)
            }
        }
        .onHover { paused = $0 }
        .task(id: paused) {
            showTrailer = false
            guard paused, !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { showTrailer = true }
        }
        .animation(.easeInOut(duration: 0.6), value: current)
        .accessibilityElement(children: .contain)
    }

    private func banner(_ game: Game, height: CGFloat, tint: Color) -> some View {
        let info = model.info[game.id]
        let subtitle = [info?.developers.first, info?.year, info?.genres.first, game.store.displayName]
            .compactMap { $0 }.joined(separator: " · ")
        return ZStack(alignment: .bottomLeading) {
            Artwork(url: model.heroURL(for: game), title: game.title, titleOnPlaceholder: false)
                .frame(height: height).frame(maxWidth: .infinity)
            if showTrailer, let trailer = info?.trailerURL {
                TrailerPlayer(url: trailer).frame(height: height).frame(maxWidth: .infinity).allowsHitTesting(false)
            }
            // Dark on the left where the words are, clear on the right where the art is; fading into the page below.
            LinearGradient(stops: [.init(color: Theme.ink.opacity(0.85), location: 0), .init(color: Theme.ink.opacity(0.35), location: 0.55),
                                   .init(color: Theme.ink.opacity(0), location: 0.8)], startPoint: .leading, endPoint: .trailing)
            if pageScheme == .dark {
                Theme.artFade(into: tint, page: .dark)
            } else {
                // Light pages, as on the game page: the art stays dark behind the words and the buttons, and dissolves
                // into tinted paper only below them.
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: tint.opacity(0.75), location: 0.72),
                                       .init(color: tint.opacity(0.35), location: 0.9), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                Theme.artFade(into: tint, page: .light, from: 0.86)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Theme.eyebrow(eyebrow(for: game))
                TitleOrLogo(title: game.title, logoURL: model.logoURL(for: game), maxWidth: 380, maxHeight: 100, infoPending: info == nil)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(Theme.onDarkSecondary)
                }
                HStack(spacing: Theme.Space.s + 2) {
                    if game.isInstalled {
                        Button {
                            Task { if model.storeDialogs[game.id] != nil { await model.showStoreDialog(for: game) } else { await model.play(game) } }
                        } label: { PlayLabel(game: game) }
                            .buttonStyle(PlayButtonStyle())
                            .keyboardShortcut(.defaultAction)
                            // Clickable while the launch waits on Steam's window (it shows it again).
                            .disabled((model.isActive(game) && model.storeDialogs[game.id] == nil) || model.waitsForSteam(game))
                            .accessibilityHint("Starts \(game.title)")
                    } else {
                        Button { Task { await model.install(game) } } label: { Label("Install", systemImage: "arrow.down.circle.fill") }
                            .buttonStyle(PlayButtonStyle())
                            .disabled(model.installState(of: game) != nil)
                    }
                    Button { model.open(game) } label: { Image(systemName: "info") }
                        .buttonStyle(GlassCircleButtonStyle())
                        .accessibilityLabel("Details for \(game.title)")
                }
                .padding(.top, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.margin)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    private func row(_ title: LocalizedStringKey, _ games: [Game], width: CGFloat = 150, seeAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: title, count: games.count) { Button("See All", action: seeAll) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Space.m + 4) {
                    ForEach(games) { game in GameCard(game: game, width: width) }
                }
                .padding(.vertical, Theme.Space.s)      // room for the hover lift
            }
            .padding(.horizontal, -Theme.Space.s).padding(.leading, Theme.Space.s)
        }
    }

    /// Recently played, as wide art with when and how long, and the week's total on the right.
    private func recentRow(_ games: [Game]) -> some View {
        let week = model.weekStats
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Recently Played") {
                if week.games > 0 {
                    Text(String(localized: "This week: \(week.time.playTime) · \(week.games) games"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            // The last three, side by side in wide art.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.m, alignment: .top), count: 3),
                      alignment: .leading, spacing: Theme.Space.m) {
                ForEach(games.prefix(3)) { game in RecentCard(game: game) }
            }
        }
    }

    /// The stores the user is in, in their colours with a few of their covers, and one card to add another.
    private var storesRow: some View {
        let connected = StoreKind.allCases.filter { model.isSignedIn($0) }
        let others = ([.steam] + AppModel.directStores + AppModel.launcherStores).filter { !connected.contains($0) }
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Stores")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                ForEach(connected, id: \.self) { kind in
                    StoreCard(kind: kind, status: status(of: kind), games: model.games(for: .store(kind)), busy: model.storeActivity[kind] != nil) {
                        model.selection = .store(kind)
                    }
                }
                if !others.isEmpty {
                    Menu {
                        ForEach(others, id: \.self) { kind in
                            Button { connect(kind) } label: { Label(kind.displayName, image: kind.logoName) }
                        }
                    } label: {
                        HStack(spacing: Theme.Space.m - 4) {
                            Image(systemName: "plus").font(.title2).frame(width: 40, height: 40)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.14)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect a Store").font(.headline).foregroundStyle(Theme.onDark)
                                Text(others.map(\.displayName).joined(separator: ", ")).font(Theme.Font.meta).foregroundStyle(Theme.onDarkSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.fill(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [6, 4])))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                }
            }
        }
    }

    private func connect(_ kind: StoreKind) {
        switch kind {
        case .steam: Task { await model.openSteam() }
        case .epic, .gog: Task { await model.connect(kind) }
        default: Task { await model.openLauncher(kind) }
        }
    }

    private func status(of kind: StoreKind) -> String {
        if let activity = model.storeActivity[kind] { return activity }
        if kind == .steam {
            if model.steamLaunch != .idle { return String(localized: "Opening…") }
            if model.running["steam"] != nil { return String(localized: "Running") }
        } else if model.running[kind.rawValue] != nil { return String(localized: "Running") }
        let count = model.games(for: .store(kind)).count
        let installed = model.games(for: .store(kind)).filter(\.isInstalled).count
        if count == 0 { return String(localized: "Open to sign in") }
        return installed > 0 ? String(localized: "\(count) games · \(installed) installed") : String(localized: "\(count) games")
    }
}

/// Recently played: wide art with the game's logo on a dark fade, so the card reads as that game and not as a bare
/// picture (Steam's hero art carries no title). Play appears on hover; a running game shows "In game" instead.
struct RecentCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ArtworkStore.self) private var store
    let game: Game
    @State private var hovering = false

    var body: some View {
        let playing = model.state(of: game) != nil
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { model.open(game) } label: {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { Artwork(url: model.heroURL(for: game), title: game.title) }
                    .overlay {
                        LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .black.opacity(0.25), location: 0.55),
                                               .init(color: .clear, location: 0.85)], startPoint: .bottomLeading, endPoint: .topTrailing)
                    }
                    .overlay(alignment: .bottomLeading) { logo.padding(14).padding(.trailing, 96) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous).strokeBorder(.white.opacity(0.06)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if playing {
                        HStack(spacing: 5) { GrapeMark(filled: 6).frame(width: 11, height: 11); Text("In game") }
                            .font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Theme.wine, in: Capsule())
                            
                    } else if hovering {
                        Button { Task { await model.play(game) } } label: {
                            Label("Play", systemImage: "play.fill").labelStyle(PillLabelStyle())
                        }
                        .buttonStyle(QuickPlayButtonStyle())
                        .disabled(model.waitsForSteam(game))
                        .accessibilityLabel("Play \(game.title)")
                        .transition(.opacity)
                    }
                }
                .padding(12)
            }
            .hoverLift()
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            Text([model.lastPlayed(game)?.playedAgo, model.playTime(game) > 0 ? model.playTime(game).playTime : nil].compactMap { $0 }.joined(separator: " · "))
                .font(Theme.Font.meta).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(game.title)
        .help(game.title)
    }

    /// The game's logo; its name in type when the store has no logo.
    @ViewBuilder private var logo: some View {
        let url = model.logoURL(for: game)
        if let image = store.image(url) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: 220, maxHeight: 54, alignment: .bottomLeading)
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
        } else {
            Text(game.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .onAppear { store.load(url) }
        }
    }
}

/// "Title  7                                  See All": the header of every content row.
struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var count: Int? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(title: LocalizedStringKey, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.count = count; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Font.section)
            if let count { Text("\(count)").font(.callout).foregroundStyle(.secondary) }
            Spacer()
            trailing().buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, count: Int? = nil) { self.init(title: title, count: count) { EmptyView() } }
}

/// A 2:3 cover with the title and store underneath. One element to VoiceOver; lifts on hover.
struct GameCard: View {
    @Environment(AppModel.self) private var model
    @Environment(ArtworkStore.self) private var artwork
    let game: Game
    var width: CGFloat? = nil
    /// On a collection's page: a cross to take the game off, or a plus (and a click anywhere) to put it on.
    var shelf: ShelfAction? = nil
    @State private var hovering = false

    enum ShelfAction {
        case remove(() -> Void)
        case add(() -> Void)
    }

    var body: some View {
        Button { if case .add(let add) = shelf { add() } else { model.open(game) } } label: {
            let rating = model.compatibility(of: game)
            VStack(alignment: .leading, spacing: Theme.Space.s - 2) {
                Artwork(url: model.coverURL(for: game), title: game.title, fallback: model.headerURL(for: game))
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                    .overlay(alignment: .bottom) {
                        if model.installState(of: game) != nil {
                            EmptyView()   // the grapes in the middle and the status line say it
                        } else if let note = rating.notes.first(where: { $0 != .macVersion }) {   // "Mac" has its own corner
                            Label(note.localizedTitle, systemImage: note.symbol).font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                                .padding(Theme.Space.s)
                        }
                    }
                    .overlay {
                        if let install = model.installState(of: game) {
                            ZStack {
                                Circle().fill(.black.opacity(0.55)).background(.ultraThinMaterial, in: Circle())
                                if let fraction = install.fraction {
                                    GrapePour(fraction: fraction).foregroundStyle(Theme.wineLight).frame(width: 26, height: 26)
                                } else {
                                    ProgressView().controlSize(.small).tint(.white)
                                }
                            }
                            .frame(width: 46, height: 46)
                            .environment(\.colorScheme, .dark)
                        }
                    }
                    .overlay(alignment: .topLeading) { macBadge }
                    .overlay(alignment: .topTrailing) { badge }
                    .overlay(alignment: .bottomTrailing) {
                        if case .add = shelf {
                            Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                                .frame(width: 26, height: 26).background(Theme.cream, in: Circle())
                                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                                .scaleEffect(hovering ? 1.12 : 1).padding(7)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if case .remove(let remove) = shelf, hovering {
                            Button(action: remove) {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 22, height: 22).background(.black.opacity(0.6), in: Circle())
                            }
                            .buttonStyle(.plain).padding(7)
                            .accessibilityLabel("Remove from Collection")
                        }
                    }
                    .hoverLift()
                Text(game.title).font(Theme.Font.cardTitle).lineLimit(1).padding(.top, Theme.Space.xs)
                HStack(spacing: Theme.Space.xs) {
                    if let install = model.installState(of: game) {
                        InstallProgressView(state: install, compact: true, onArtwork: false)
                    } else {
                        rating.verdict.mark.frame(width: 12, height: 12).foregroundStyle(rating.verdict.color)
                            .help(rating.summary)
                        Text([rating.verdict.localizedTitle, game.knownSize].compactMap { $0 }.joined(separator: " · "))
                        if let sync = model.saveSyncStatus(of: game), sync.state != .synced {
                            Image(systemName: sync.state == .pendingUpload ? "icloud.and.arrow.up" : "icloud.slash").foregroundStyle(Theme.wineLight)
                                .help(sync.state == .pendingUpload ? String(localized: "Saves waiting to upload") : String(localized: "Saves not synced"))
                        }
                    }
                }
                .font(Theme.Font.meta).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { artwork.load(model.logoURL(for: game)) }   // so the game's page opens with its logo in place
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the game's page")
        .contextMenu {
            if game.isInstalled {
                Button("Play") { Task { await model.play(game) } }.disabled(model.isActive(game) || model.waitsForSteam(game))
            } else {
                Button("Install") { Task { await model.install(game) } }
            }
            Button("Show in Finder") { model.revealGame(game) }.disabled(game.installPath == nil)
            Button("Show Log") { model.showLog(for: game.id) }
            if game.isInstalled || model.installState(of: game) != nil {
                Divider()
                Button(game.isInstalled ? "Uninstall…" : "Cancel Download…", role: .destructive) {
                    Task { await model.uninstall(game) }
                }
                .disabled(model.isActive(game) || model.uninstallState(of: game) != nil)
            }
        }
    }

    @ViewBuilder private var macBadge: some View {
        if model.hasMacVersion(game) {
            Text("Mac").font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(Theme.Space.s)
                .help("Has a Mac version")
        }
    }

    @ViewBuilder private var badge: some View {
        if model.uninstallState(of: game) != nil {
            LoadingGrape().padding(6).background(Circle().fill(.black.opacity(0.55))).padding(Theme.Space.s)
        } else if let state = model.state(of: game) {
            GameStateBadge(state: state, waitingIn: model.storeDialogs[game.id]).padding(Theme.Space.s)
        } else if !game.isInstalled && model.installState(of: game) == nil {
            Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundStyle(.white, .black.opacity(0.5)).padding(Theme.Space.s)
        }
    }

    private var accessibilityText: String {
        var parts = [game.title, model.storeNames(of: game)]
        if let size = game.knownSize { parts.append(size) }
        switch model.state(of: game) {
        case .starting: parts.append(String(localized: "starting"))
        case .playing: parts.append(String(localized: "playing"))
        case nil: parts.append(game.isInstalled ? String(localized: "installed") : String(localized: "not installed"))
        }
        if model.hasMacVersion(game) { parts.append(String(localized: "has a Mac version")) }
        parts.append(model.compatibility(of: game).summary)
        return parts.joined(separator: ", ")
    }
}

/// A store on Home, in its colours: logo, name, how many games, and a few of their covers. Click opens its page.
struct StoreCard: View {
    @Environment(AppModel.self) private var model
    let kind: StoreKind
    let status: String
    let games: [Game]
    var busy = false
    let action: () -> Void

    var body: some View {
        let brand = kind.brandColors
        let covers = Array(games.sorted { $0.isInstalled && !$1.isInstalled }.prefix(3))
        Button(action: action) {
            HStack(spacing: Theme.Space.m - 4) {
                kind.logo.resizable().scaledToFit().frame(width: 22, height: 22).frame(width: 40, height: 40)
                    .foregroundStyle(Theme.onDark)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    // One line each, shrinking a little before cutting: the name ("Ubisoft Connect") used to wrap
                    // into the covers' space and break onto a second line.
                    Text(kind.displayName).font(.headline).foregroundStyle(Theme.onDark).lineLimit(1).minimumScaleFactor(0.8)
                    Text(status).font(Theme.Font.meta).foregroundStyle(Theme.onDarkSecondary).lineLimit(1).minimumScaleFactor(0.85)
                }
                .layoutPriority(1)
                Spacer(minLength: Theme.Space.s)
                if busy {
                    LoadingGrape().foregroundStyle(.white)
                } else {
                    HStack(spacing: -10) {
                        ForEach(covers) { game in
                            Artwork(url: model.coverURL(for: game), title: game.title, titleOnPlaceholder: false, fallback: model.headerURL(for: game))
                                .frame(width: 30, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .shadow(color: .black.opacity(0.4), radius: 3, x: -2)
                        }
                    }
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(LinearGradient(colors: [brand.top, brand.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)                    // the store's own colours, with white on them, in both
        .accessibilityLabel(Text(verbatim: "\(kind.displayName), \(status)"))
    }
}
