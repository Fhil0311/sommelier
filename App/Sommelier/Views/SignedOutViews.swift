// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

// Sommelier before any store is signed in to (design: signed-out.html): Home says "sign in to a store" with a card
// per store, All Games and Installed list the stores with one button each, and a store's page says "You're not
// signed in" with the same button and what it does.

/// The small cream "Sign In" capsule the signed-out screens share.
struct SignInButtonStyle: ButtonStyle {
    /// Off while a sign-in is under way: dimmed, as Play is.
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(Theme.cream.opacity(isEnabled ? 1 : 0.6)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Home before any sign-in: the title and a card per store over a wall of popular games' covers. The wall itself is
/// drawn behind the whole window, sidebar included (`CoverWall`, set in `ContentView`); this page is see-through.
struct SignedOutHome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(model.signedOutEverywhere ? "Sign in to a store,\nand your games will show up here" : "Your Windows games on a Mac")
                        .font(.system(size: 36, weight: .bold)).tracking(-0.7).foregroundStyle(Theme.onDark)
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can connect several: it all comes together in one library.")
                        .font(.callout).foregroundStyle(Theme.onDarkSecondary)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                }
                .padding(.leading, 34)
                .padding(.top, min(200, geo.size.height * 0.28))
                VStack {
                    Spacer(minLength: 0)
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        ForEach(AppModel.signInOrder, id: \.self) { StoreSignInCard(kind: $0) }
                    }
                    .fixedSize(horizontal: false, vertical: true)       // cards as tall as they need, not the page
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 30)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Home")
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .environment(\.colorScheme, .dark)
    }
}

/// Popular games' covers as a wall behind the whole window (design: signed-out.html, .wall): four lanes, tilted 4°,
/// drifting in turn left and right (100, 120, 140 and 120 seconds a lap), under a scrim that keeps the title and
/// the cards legible. Still with Reduce Motion.
struct CoverWall: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The covers that ship with the app (WallCovers: the design's mix, a lane per line of wall-covers.txt), so the
    /// wall is there at once and offline.
    static let bundledLanes: [[URL]] = {
        guard let list = Bundle.main.url(forResource: "wall-covers", withExtension: "txt"),
              let text = try? String(contentsOf: list, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in
            line.split(separator: " ").compactMap { Bundle.main.url(forResource: "c-\($0)", withExtension: "jpg") }
        }.filter { !$0.isEmpty }
    }()

    static let laps: [Double] = [100, 120, 140, 120]
    static let tile: CGFloat = 128, gap: CGFloat = 12

    var body: some View {
        let lanes = Self.bundledLanes
        ZStack {
            Theme.ink
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || lanes.isEmpty)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(lanes.indices, id: \.self) { i in
                        let lane = lanes[i]
                        let lap = CGFloat(lane.count) * (Self.tile + Self.gap)
                        let moved = CGFloat(t / Self.laps[i % 4]).truncatingRemainder(dividingBy: 1) * lap
                        row(lane + lane + lane).offset(x: i % 2 == 0 ? -moved : moved - lap)
                    }
                }
                .drawingGroup()          // one layer: moving it doesn't redraw every cover
                .rotationEffect(.degrees(-4))
                .padding(.horizontal, -60).padding(.top, -70)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Scrim: darker on the left where the title is, and towards the bottom where the cards are.
            LinearGradient(stops: [.init(color: Theme.ink.opacity(0.55), location: 0), .init(color: Theme.ink.opacity(0.9), location: 0.24),
                                   .init(color: Theme.ink.opacity(0.55), location: 0.62), .init(color: Theme.ink.opacity(0.25), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: Theme.ink.opacity(0.15), location: 0.3), .init(color: Theme.ink.opacity(0.92), location: 0.78)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The bundled covers, decoded once (the wall redraws 30 times a second while it moves).
    @MainActor static func image(_ url: URL) -> NSImage? {
        if let cached = images[url] { return cached }
        let image = NSImage(contentsOf: url)
        images[url] = image
        return image
    }
    @MainActor private static var images: [URL: NSImage?] = [:]

    private func row(_ urls: [URL]) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                Group {
                    if let image = Self.image(url) { Image(nsImage: image).resizable().scaledToFill() } else { Theme.surface }
                }
                    .frame(width: Self.tile, height: Self.tile * 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .opacity(0.62)
            }
        }
        .fixedSize()
    }
}

/// A store's card on Home: its colours and logo, what "Sign In" does, and the button.
struct StoreSignInCard: View {
    @Environment(AppModel.self) private var model
    let kind: StoreKind

    var body: some View {
        let brand = kind.brandColors
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 7) {
                kind.logo.resizable().scaledToFit().frame(width: 17, height: 17)
                Text(kind.displayName).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Theme.onDark)
            Text(signedIn ? String(localized: "\(model.games(for: .store(kind)).count) games") : model.signInHint(kind))
                .font(.system(size: 12)).foregroundStyle(Theme.onDarkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            if signedIn {
                Button("Browse Library") { model.selection = .store(kind) }.buttonStyle(SignInButtonStyle())
            } else {
                signInButton
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: [brand.top, brand.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
                kind.logo.resizable().scaledToFit().frame(width: 64, height: 64)
                    .foregroundStyle(.white.opacity(0.08)).offset(x: 10, y: 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.hairline))
    }

    private var signedIn: Bool { model.storesWithAccount.contains(kind) }

    @ViewBuilder private var signInButton: some View {
        if let activity = model.storeActivity[kind] {
            HStack(spacing: 6) { LoadingGrape(); Text(activity).lineLimit(1) }.font(.caption).foregroundStyle(Theme.onDarkSecondary)
        } else {
            Button(model.signInTitle(kind)) { Task { await model.signInOrShow(kind) } }
                .buttonStyle(SignInButtonStyle())
                .disabled(model.signInDisabled(kind))
        }
    }
}

/// All Games and Installed before any sign-in: a title, a line, and the stores with one button each, over faint
/// tiles where covers will be.
struct SignedOutLibrary: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let text: LocalizedStringKey

    var body: some View {
        ZStack(alignment: .top) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                ForEach(0..<18, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous).fill(Theme.fill(0.04)).aspectRatio(2.0 / 3.0, contentMode: .fit)
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
            VStack(spacing: Theme.Space.s) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.onDark)
                Text(text).font(.callout).foregroundStyle(Theme.onDarkSecondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 400).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Theme.Space.s) {
                    ForEach(AppModel.signInOrder, id: \.self) { kind in
                        HStack(spacing: Theme.Space.s) {
                            kind.logo.resizable().scaledToFit().frame(width: 16, height: 16)
                            Text(kind.displayName).font(.system(size: 13, weight: .semibold))
                            Spacer(minLength: 0)
                            if let activity = model.storeActivity[kind] {
                                HStack(spacing: 6) { LoadingGrape(); Text(activity).lineLimit(1) }.font(.caption).foregroundStyle(.secondary)
                            } else if model.storesWithAccount.contains(kind) {
                                Button("Browse Library") { model.selection = .store(kind) }
                                    .buttonStyle(SignInButtonStyle())
                            } else {
                                Button(model.signInTitle(kind)) { Task { await model.signInOrShow(kind) } }
                                    .buttonStyle(SignInButtonStyle())
                                    .disabled(model.signInDisabled(kind))
                            }
                        }
                        .foregroundStyle(Theme.onDark)
                        .padding(.leading, Theme.Space.m).padding(.trailing, 6).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
                    }
                }
                .frame(width: 340)
                .padding(.top, Theme.Space.m)
            }
            .padding(.top, 50)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The art a signed-out store page shows: its most played games (cover and hero ship in the app, `StoreArt`), the
/// store's colours and its line (design: signed-out.html, "poster").
struct StorePoster {
    struct Game: Identifiable { let slug: String; let title: String; var id: String { slug } }
    let colors: (Color, Color)
    let games: [Game]

    static func of(_ kind: StoreKind) -> StorePoster? {
        func hex(_ v: UInt32) -> Color { Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255) }
        func games(_ list: [(String, String)]) -> [Game] { list.map { Game(slug: $0.0, title: $0.1) } }
        switch kind {
        case .steam:
            return StorePoster(colors: (hex(0x1b2838), hex(0x2a6f97)), games: games([("cs2", "Counter-Strike 2"), ("dota2", "Dota 2"),
                ("rivals", "Marvel Rivals"), ("bg3", "Baldur's Gate 3"), ("helldivers2", "Helldivers 2")]))
        case .epic:
            return StorePoster(colors: (hex(0x101014), hex(0x0b5cc4)), games: games([("gta5", "GTA V"), ("borderlands3", "Borderlands 3"),
                ("control", "Control"), ("rdr2", "Red Dead Redemption 2"), ("hogwarts", "Hogwarts Legacy")]))
        case .gog:
            return StorePoster(colors: (hex(0x2a0f3d), hex(0x86328a)), games: games([("cyberpunk", "Cyberpunk 2077"), ("witcher3", "The Witcher 3"),
                ("dos2", "Divinity: Original Sin 2"), ("kcd2", "Kingdom Come: Deliverance II"), ("disco", "Disco Elysium")]))
        case .ubisoft:
            return StorePoster(colors: (hex(0x06142e), hex(0x0060d6)), games: games([("acshadows", "Assassin's Creed Shadows"),
                ("farcry6", "Far Cry 6"), ("valhalla", "Assassin's Creed Valhalla"), ("forhonor", "For Honor")]))
        case .ea:
            return StorePoster(colors: (hex(0x120d22), hex(0xe8434b)), games: games([("sims4", "The Sims 4"), ("split", "Split Fiction"),
                ("ittakestwo", "It Takes Two"), ("jedi", "Star Wars Jedi: Survivor"), ("deadspace", "Dead Space")]))
        case .battlenet:
            return StorePoster(colors: (hex(0x081428), hex(0x0560c8)), games: games([("crash4", "Crash Bandicoot 4"),
                ("hearthstone", "Hearthstone"), ("diablo4", "Diablo IV"), ("warcraft3", "Warcraft III: Reforged"), ("overwatch2", "Overwatch 2")]))
        }
    }

    static func tagline(_ kind: StoreKind) -> String {
        switch kind {
        case .steam: String(localized: "All your Steam library, on Mac.")
        case .epic: String(localized: "Epic games without the Epic Games Launcher.")
        case .gog: String(localized: "Games without DRM, without a launcher.")
        case .ubisoft: String(localized: "Your Ubisoft games next to all the others.")
        case .ea: String(localized: "Your EA games next to all the others.")
        case .battlenet: String(localized: "Your Blizzard games next to all the others.")
        }
    }

    /// A bundled picture (`StoreArt/<slug>-c.jpg` cover, `-h.jpg` hero), decoded once: the views ask on every redraw.
    @MainActor static func image(_ slug: String, _ kind: String) -> NSImage? {
        let key = "\(slug)-\(kind)"
        if let cached = cache[key] { return cached }
        let image = Bundle.main.url(forResource: key, withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }
        cache[key] = image
        return image
    }
    @MainActor private static var cache: [String: NSImage?] = [:]
}

/// Which game the signed-out store page shows: its own little store, so a change redraws the poster only, not the
/// sidebar and the rest of the window (that redrew everything on every hover).
@MainActor @Observable final class PosterState {
    static let shared = PosterState()
    var pick = 0
    /// When the pick last changed: a hover right after is the fan moving under the pointer, not the player.
    @ObservationIgnored var changed = Date.distantPast

    func select(_ index: Int) {
        guard index != pick else { return }
        pick = index
        changed = Date()
    }
}

/// A store's page while it isn't signed in to: the game's hero art over the whole window, a fan of the store's
/// popular games on the right, the store's name, line and "Sign In" on the left. The art and the glass sidebar come
/// from `StorePosterBackdrop` (set in `ContentView`).
struct SignedOutStore: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: StoreKind
    @State private var hovering = false
    private var poster: PosterState { PosterState.shared }

    var body: some View {
        let games = StorePoster.of(kind)?.games ?? []
        let pick = poster.pick % max(games.count, 1)
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: 12) {
                    kind.logo.resizable().scaledToFit().frame(width: 38, height: 38)
                    Text(kind.displayName).font(.system(size: 40, weight: .bold)).tracking(-0.9).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white).shadow(color: .black.opacity(0.4), radius: 14, y: 2)
                Text(StorePoster.tagline(kind)).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                signIn
            }
            .frame(maxWidth: 330, alignment: .leading)
            Spacer(minLength: Theme.Space.l)
            if !games.isEmpty { fan(games, pick: pick) }
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .task(id: kind) { poster.select(0) }
        .task(id: "\(kind.rawValue)-\(hovering)-\(poster.pick)") {
            // Without the pointer on the fan, the next game every six seconds (not with Reduce Motion).
            guard !hovering, !reduceMotion, games.count > 1 else { return }
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.45)) { poster.select((pick + 1) % games.count) } }
        }
    }

    @ViewBuilder private var signIn: some View {
        if let activity = model.storeActivity[kind] {
            HStack(spacing: 6) { LoadingGrape(); Text(activity).lineLimit(1) }.foregroundStyle(.white.opacity(0.8))
        } else {
            HStack(spacing: 12) {
                Button { Task { await model.signInOrShow(kind) } } label: {
                    Text(model.signInTitle(kind)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 20).frame(height: 36).background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(model.signInDisabled(kind))
                .opacity(model.signInDisabled(kind) ? 0.55 : 1)                 // a plain button doesn't dim by itself
                Text(model.signInHint(kind)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The covers fanned round the chosen one; a hover picks one.
    private func fan(_ games: [StorePoster.Game], pick: Int) -> some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(Array(games.enumerated()), id: \.element.id) { j, game in
                    let n = games.count
                    var d = j - pick
                    let _ = { if d > n / 2 { d -= n }; if d < -n / 2 { d += n } }()
                    let chosen = d == 0
                    Group {
                        if let image = StorePoster.image(game.slug, "c") {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else { Theme.surface }
                    }
                    .frame(width: 132, height: 198)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(chosen ? 0.9 : 0), lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: chosen ? 24 : 12, y: chosen ? 14 : 8)
                    .brightness(chosen ? 0 : -0.2).saturation(chosen ? 1 : 0.8)
                    .scaleEffect(chosen ? 1.12 : 1 - CGFloat(abs(d)) * 0.06)
                    .rotationEffect(.degrees(Double(d) * 7))
                    .offset(x: CGFloat(d) * 56, y: chosen ? -26 : CGFloat(abs(d)) * 8)
                    .zIndex(Double(10 - abs(d)))
                    .accessibilityLabel(game.title)
                }
            }
            .frame(width: 132 + 56 * 4 + 40, height: 260)
            .allowsHitTesting(false)            // a picture that turns by itself, not something to point at
            .animation(.easeInOut(duration: 0.45), value: pick)
            let current = games[pick]
            (Text(current.title).bold() + Text(" · ") + Text("available in \(kind.displayName)"))
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// Behind the whole window on a signed-out store page: the chosen game's hero, drifting slowly (scale 1.12 to 1,
/// 14 s) and crossfading when the game changes, under the store's colour wash and scrim, its logo faint in the corner.
struct StorePosterBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: StoreKind

    var body: some View {
        let poster = StorePoster.of(kind)
        let games = poster?.games ?? []
        let pick = PosterState.shared.pick % max(games.count, 1)
        ZStack {
            Color(red: 0.07, green: 0.06, blue: 0.06)
            if let poster, !games.isEmpty {
                ForEach(Array(games.enumerated()), id: \.element.id) { j, game in
                    hero(game, active: j == pick)
                }
                LinearGradient(colors: [poster.colors.0, poster.colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55).blendMode(.color)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black.opacity(0.82), location: 0.22),
                                   .init(color: .black.opacity(0.45), location: 0.55), .init(color: .black.opacity(0.1), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.55), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            kind.logo.resizable().scaledToFit().frame(width: 420, height: 420).foregroundStyle(.white.opacity(0.05))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 20).padding(.trailing, -60)
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func hero(_ game: StorePoster.Game, active: Bool) -> some View {
        // The hero at the window's width, anchored at the top and fading into the dark below: stretched to the
        // window's height it was blown up three times over and looked coarse.
        Group {
            if let image = StorePoster.image(game.slug, "h") ?? StorePoster.image(game.slug, "c") {
                // Below the picture, the same picture blurred over the whole window: its colours carry on down
                // instead of black.
                Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill().blur(radius: 60).opacity(0.7) }
                    .clipped()
                    .overlay(alignment: .top) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    }
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        // No slow zoom: it kept the window redrawing all the time (the crossfade is enough).
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 1.4), value: active)
    }
}
