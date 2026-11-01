// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVKit
import SommelierKit
import SwiftUI

/// A game's page: its art across the top, the name and Play; then compatibility, screenshots and the description,
/// with the facts in a card beside them.
/// The art's colour fades into the neutral surface so text below keeps its contrast.
struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(ArtworkStore.self) private var artwork
    /// The game as it was when the page opened; `game` follows the library, so an install that finishes
    /// while the page is open turns Install into Play.
    private let opened: Game
    private var game: Game { model.library.games.first { $0.id == opened.id } ?? opened }
    @State private var automaticPick: GraphicsBackend?
    /// The trailer plays behind the header as soon as it loads, as on the site; not with reduced motion.
    @State private var playTrailer = false
    /// SOMMELIER_DEBUG_SCROLL=bottom shows the end of the page (for screenshots).
    @State private var debugScroll: String?
    /// The gallery strip: the first tile in view, and whether the pointer is over it (to show the arrows).
    @State private var galleryFirst: Int?
    @State private var galleryHover = false
    @State private var galleryWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The page's appearance (the header over the art is always dark).
    @Environment(\.colorScheme) private var pageScheme

    init(game: Game) { opened = game }

    var body: some View {
        let info = model.info[game.id]
        let heroURL = model.heroURL(for: game)
        let tint = artwork.tint(heroURL) ?? artwork.tint(model.coverURL(for: game)) ?? Theme.graphite

        GeometryReader { geo in
            let heroHeight = min(max(geo.size.width * 0.4, 280), 420)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        Artwork(url: heroURL, title: game.title, titleOnPlaceholder: false)
                            .frame(height: heroHeight).frame(maxWidth: .infinity)
                        if playTrailer, let trailer = info?.trailerURL, model.viewing == nil {
                            TrailerPlayer(url: trailer).frame(height: heroHeight).frame(maxWidth: .infinity).allowsHitTesting(false)
                        }
                        LinearGradient(stops: [.init(color: Theme.ink.opacity(0.8), location: 0), .init(color: Theme.ink.opacity(0.25), location: 0.6),
                                               .init(color: .clear, location: 0.85)], startPoint: .leading, endPoint: .trailing)
                        if pageScheme == .dark {
                            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: tint.opacity(0.75), location: 0.8),
                                                   .init(color: tint, location: 1)], startPoint: .top, endPoint: .bottom)
                        } else {
                            // Light pages: the art still darkens behind the words, then dissolves into tinted paper.
                            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: tint.opacity(0.75), location: 0.72),
                                                   .init(color: tint.opacity(0.35), location: 0.9), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                            Theme.artFade(into: tint, page: .light, from: 0.86)
                        }
                        header(info)
                            .padding(.horizontal, Theme.Space.margin).padding(.bottom, Theme.Space.l)
                    }
                    .frame(height: heroHeight)
                    .environment(\.colorScheme, .dark)               // over the art: light words in both appearances

                    // Two columns as on the site: what matters on the left, the facts in a card on the right;
                    // one column under each other when the window is narrow.
                    Group {
                        if geo.size.width > 760 {
                            HStack(alignment: .top, spacing: 20) {
                                mainColumn(info)
                                sideColumn(info).frame(width: 236)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: Theme.Space.l) { mainColumn(info); sideColumn(info) }
                        }
                    }
                    .padding(.horizontal, Theme.Space.margin)
                    .padding(.top, Theme.Space.m)
                    similar(info)
                        .padding(.horizontal, Theme.Space.margin)
                        .padding(.top, Theme.Space.section).padding(.bottom, Theme.Space.margin)
                        .id("similar")
                }
            }
            .scrollPosition(id: $debugScroll, anchor: .bottom)
            .background(Theme.tintedBackground(tint, heroHeight: heroHeight))
        }
        .ignoresSafeArea(edges: .top)
        .environment(\.pageScheme, pageScheme)
        .navigationTitle(game.title)
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { model.tint = tint }
        .onChange(of: tint) { model.tint = tint }
        .task {
            await model.loadInfo(for: game); refreshPick(); await model.loadFacts(for: game); await model.loadSimilar(to: game)
            if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_SCROLL"] == "bottom" {
                try? await Task.sleep(for: .seconds(2)); debugScroll = "similar"
            }
        }
        .task(id: game.id) {
            playTrailer = !reduceMotion   // the header is the trailer, as on the site; it fades in over the art
        }
    }

    // MARK: Header

    private func header(_ info: GameInfo?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TitleOrLogo(title: game.title, logoURL: model.logoURL(for: game), infoPending: info == nil)
            // Owned in several stores: the page is about the copy the lists chose (the installed or last played one),
            // and the store to install from is asked at Install. Only with two copies installed is there something to
            // pick here, so only then does the store name become a small menu.
            let installedCopies = model.copies(of: game).filter(\.isInstalled)
            let meta = [info?.developers.first, info?.year, info?.genres.first,
                        installedCopies.count > 1 ? nil : game.store.displayName].compactMap { $0 }
            HStack(spacing: Theme.Space.m - 4) {
                if let notice = model.disputeNotice, notice.gameID == game.id {
                    // For a few seconds after a dispute: what happened, and Undo.
                    HStack(spacing: 6) {
                        Text(notice.reportSent ? (notice.markRemoved ? String(localized: "Thank you. Mark removed, report sent.")
                                                                    : String(localized: "Report sent. Thank you!"))
                                               : String(localized: "Mark removed."))
                            .foregroundStyle(Theme.onDark)
                        if notice.markRemoved {
                            Button("Undo") { model.undoStatusDispute(of: game) }.buttonStyle(.plain).underline().foregroundStyle(Theme.onDark)
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(.white.opacity(0.08), in: Capsule())
                    .task(id: notice.shown) {
                        try? await Task.sleep(for: .seconds(6))
                        if model.disputeNotice == notice { model.disputeNotice = nil }
                    }
                } else {
                    Text(meta.joined(separator: " · ")).font(.callout).foregroundStyle(Theme.onDarkSecondary)
                }
                if installedCopies.count > 1 {
                    Menu {
                        ForEach(installedCopies) { copy in
                            Button { if copy.id != game.id { model.switchCopy(to: copy) } } label: {
                                if copy.id == game.id { Label(copy.store.displayName, systemImage: "checkmark") } else { Text(copy.store.displayName) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(game.store.displayName)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.callout).foregroundStyle(Theme.onDarkSecondary)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Installed from several stores: choose which copy to play")
                }
                // The compatibility answer as a chip in the meta line; the details open on hover (or a click).
                CompatibilityChip(compatibility: model.compatibility(of: game), macNote: macNote,
                                  antiCheat: model.antiCheatEntry(of: game), needsDirectX12: model.needsD3DMetal(game),
                                  setUpDirectX12: { model.beginD3DMetalSetup() },
                                  onDispute: model.canDisputeStatus(game) ? { model.reportProblem(with: game) } : nil,
                                  disputedProblem: model.disputedProblem(game),
                                  onUndoDispute: { model.undoStatusDispute(of: game) })
            }
            HStack(spacing: Theme.Space.s + 2) {
                if let removal = model.uninstallState(of: game) {
                    let pill = HStack(spacing: 8) {
                        LoadingGrape().foregroundStyle(.white)
                        Text(removal == .removing ? "Uninstalling…" : "Confirm in Steam")
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(minHeight: 36).padding(.horizontal, Theme.Space.m + 4)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    if removal == .removing {
                        pill
                    } else {
                        // Steam's confirmation may be behind other windows: a click brings it forward.
                        Button { Task { await model.showSteamConfirmation(for: game) } } label: { pill }
                            .buttonStyle(.plain).help(String(localized: "Show \(StoreKind.steam.displayName)"))
                    }
                } else if let state = model.state(of: game) {
                    if let store = model.storeDialogs[game.id] {
                        // The launch waits on the store's own window: a click brings it forward again.
                        Button { Task { await model.showStoreDialog(for: game) } } label: {
                            GameStateBadge(state: state, large: true, waitingIn: store)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Show \(store.displayName)"))
                    } else {
                        GameStateBadge(state: state, large: true)
                    }
                } else if let install = model.installState(of: game) {
                    let progress = InstallProgressView(state: install)
                        .frame(minWidth: 180, alignment: .leading)
                        .padding(.leading, 10).padding(.trailing, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        .background(Theme.graphite.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    if install == .confirmInSteam {
                        // "Confirm the install in Steam": a click brings Steam's install dialog forward.
                        Button { Task { await model.showSteamConfirmation(for: game) } } label: { progress }
                            .buttonStyle(.plain).help(String(localized: "Show \(StoreKind.steam.displayName)"))
                    } else {
                        progress
                    }
                    if model.canPause(game, install) {
                        Button { Task { await model.pauseDownload(game) } } label: { Image(systemName: "pause.fill") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help("Pause Download")
                            .accessibilityLabel("Pause Download")
                    } else if model.canResume(game, install) {
                        Button { Task { await model.resumeDownload(game) } } label: { Image(systemName: "play.fill") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help("Resume Download")
                            .accessibilityLabel("Resume Download")
                    }
                    if case .direct = install {
                        Button { model.cancelDirectInstall(game) } label: { Image(systemName: "xmark") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help("Cancel Download")
                            .accessibilityLabel("Cancel Download")
                    } else if case .launcher(let store, _) = install {
                        Button { Task { await model.openLauncher(store) } } label: { Image(systemName: "macwindow") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help(String(localized: "Show in \(store.displayName)"))
                            .accessibilityLabel(String(localized: "Show in \(store.displayName)"))
                    } else {
                        // Stops the download (Steam asks to confirm); Steam's own list is in the … menu.
                        Button { Task { await model.uninstall(game) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(GlassCircleButtonStyle())
                            .help("Cancel Download")
                            .accessibilityLabel("Cancel Download")
                    }
                } else if game.isInstalled && model.needsD3DMetal(game) {
                    Button { model.beginD3DMetalSetup() } label: { Label("Set Up DirectX 12", systemImage: "cpu") }
                        .buttonStyle(PlayButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else if game.isInstalled {
                    Button { Task { await model.play(game) } } label: { Label("Play", systemImage: "play.fill") }
                        .buttonStyle(PlayButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .help("Play (Return)")
                        .disabled(model.waitsForSteam(game))
                } else {
                    Button { Task { await model.install(game) } } label: { Label("Install", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(PlayButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .help(game.store == .steam ? String(localized: "Opens Steam's install dialog")
                              : model.installsNatively(game) ? String(localized: "Downloads the Mac version from \(game.store.displayName)")
                              : String(localized: "Downloads the game from \(game.store.displayName)"))
                }
                collectionMenu
                if game.isInstalled {
                    Button { model.revealGame(game) } label: { Image(systemName: "folder") }
                        .buttonStyle(GlassCircleButtonStyle()).help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                }
                GraphicsButton(game: game, hdrAvailable: hdrAvailable, directX12: usesD3DMetal)
                GameMoreMenu(game: game, automaticPick: $automaticPick)
            }
            .padding(.top, Theme.Space.xs)
        }
    }

    /// "Add to Collection" (or "In a Collection" with a tick): each collection to tick, and a new one.
    private var collectionMenu: some View {
        let inOne = model.isInAnyCollection(game)
        return Menu {
            Section("Add to collection") {
                ForEach(model.collections) { shelf in
                    Button { model.toggle(game, in: shelf.id) } label: {
                        if model.isIn(game, collection: shelf.id) { Label(shelf.name, systemImage: "checkmark") } else { Text(shelf.name) }
                    }
                }
            }
            Divider()
            Button("New Collection…") { model.beginNamingCollection(with: game) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: inOne ? "checkmark" : "plus").font(.system(size: 12, weight: .bold))
                Text(inOne ? "In a Collection" : "Add to Collection")
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 36)
            .background(.ultraThinMaterial, in: Capsule())
            .background(.white.opacity(inOne ? 0.22 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            .environment(\.colorScheme, .dark)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    /// The line about the game's Mac version under the rating: how to get it running natively, or that it already
    /// is. Intel-only versions get a word about Rosetta, which Apple ends in macOS 28.
    private var macNote: String? {
        let build = model.macBuild(of: game)
        let rosetta = build == .intel ? " " + String(localized: "This version is built for Intel Macs and runs through Rosetta, which Apple ends in macOS 28.") : ""
        if game.isNative { return build == .intel ? String(localized: "Installed as a Mac app.") + rosetta : nil }
        guard build?.runsHere == true else { return nil }
        switch game.store {
        case .epic: return String(localized: "Epic Games sells a Mac version of this game: it installs as a Mac app, without Wine.") + rosetta
        case .steam:
            if model.settings.steamMacVersions == "windows" {
                return String(localized: "This game has a Mac version. Sommelier installs the Windows version, as set in Settings > Games.") + rosetta
            }
            return (SteamMacClient.isInstalled ? String(localized: "This game has a Mac version: it installs through Steam for Mac, as a Mac app.")
                    : String(localized: "This game has a Mac version. Sommelier can set up Steam for Mac to install it natively.")) + rosetta
        default: return String(localized: "Your \(game.store.displayName) copy has a Mac version. Download it from \(game.store.displayName) to play natively.") + rosetta
        }
    }

    static let hdrSwitch = false

    /// The game is drawn through D3DMetal (DirectX 12): Turbo can't join it.
    private var usesD3DMetal: Bool {
        let profile = model.profile(for: game)
        return (profile.backend == .auto ? automaticPick : profile.backend) == .d3dMetal
    }

    /// On an HDR display, for games drawn through DXMT (DirectX 10–11): off tells the game the display is SDR.
    /// Not for D3DMetal (DirectX 12): Apple's layer decides HDR there, and nothing outside it can switch it.
    private var hdrAvailable: Bool {
        // The HDR switch is off for now (decided 22.10): games set HDR in their own settings; a game whose HDR is
        // broken gets a recipe that hides it (DXMT's forceSDR).
        if !Self.hdrSwitch { return false }
        // Only for a game that has shown it knows HDR (DXMT notes it when the game asks for HDR).
        guard model.knowsHDR(game) else { return false }
        let profile = model.profile(for: game)
        return (NSScreen.screens.map(\.maximumPotentialExtendedDynamicRangeColorComponentValue).max() ?? 1) > 1
            && (profile.backend == .auto ? automaticPick : profile.backend) == .dxmt
    }

    // MARK: Columns

    private func mainColumn(_ info: GameInfo?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Won't run stays in sight on the page: it's the warning before a download.
            if model.compatibility(of: game).verdict == .wontRun {
                CompatibilityPanel(compatibility: model.compatibility(of: game),
                                   macNote: macNote,
                                   antiCheat: model.antiCheatEntry(of: game),
                                   needsDirectX12: model.needsD3DMetal(game),
                                   setUpDirectX12: { model.beginD3DMetalSetup() })
            }
            if let note = KnownIssues.note(for: game) {
                Label { Text(note).foregroundStyle(Theme.onDark) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.wineLight)
                }
                .font(.callout)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.wineLight.opacity(0.12)))
            }
            if let info, !info.screenshots.isEmpty || info.trailerURL != nil { gallery(info) }
            if let summary = info?.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Theme.eyebrow(String(localized: "About"), color: Theme.onDarkTertiary)
                    Text(summary).font(.system(size: 13)).lineSpacing(4).foregroundStyle(Theme.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The download's full size while Steam fetches the game, before the game has a size of its own.
    private var downloadTotal: String? {
        guard case .steam(let d) = model.installState(of: game), d.bytesTotal > 0 else { return nil }
        return d.bytesTotal.fileSize
    }

    /// The facts card: details, saves, and what kind of play the game offers.
    private func sideColumn(_ info: GameInfo?) -> some View {
        let copies = model.copies(of: game)
        // Not installed and owned in several stores: where it can come from; otherwise where it plays from.
        let offered = copies.count > 1 && !game.isInstalled && model.installState(of: game) == nil
        let facts: [(String, String)] = [
            (String(localized: "Developer"), info?.developers.first ?? "—"),
            (String(localized: "Released"), info?.year ?? "—"),
            (String(localized: "Size"), game.knownSize ?? downloadTotal ?? "—"),
            (String(localized: "Played"), model.playTime(game) > 0 ? model.playTime(game).playTime : "—"),
            (String(localized: "Last played"), model.lastPlayed(game)?.playedAgo ?? String(localized: "Never")),
            offered ? (String(localized: "Available in"), copies.map(\.store.displayName).joined(separator: ", "))
                    : (String(localized: "Store"), game.store.displayName),
        ]
        let features = (info?.players ?? []).map(\.localizedName)
            + (info?.controllerSupport.map { [$0 == "full" ? String(localized: "Full controller support") : String(localized: "Partial controller support")] } ?? [])
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Theme.eyebrow(String(localized: "Details"), color: Theme.onDarkTertiary)
                // The critics' score sits with the facts, not in the header next to the actions.
                if let score = info?.metacritic {
                    HStack(spacing: 10) {
                        Text(verbatim: "Metacritic").foregroundStyle(Theme.onDarkTertiary)
                        Spacer(minLength: 0)
                        MetacriticBadge(score: score, compact: true)
                    }
                    .font(.system(size: 12.5))
                    .accessibilityElement(children: .combine)
                }
                ForEach(facts, id: \.0) { key, value in fact(key, value) }
                if model.supportsMods(game) { modsRow }
            }
            if let status = model.saveSyncStatus(of: game) {
                VStack(alignment: .leading, spacing: 7) {
                    Theme.eyebrow(String(localized: "Saves"), color: Theme.onDarkTertiary)
                    SaveSyncLine(status: status, online: model.online)
                }
            }
            ClipsCard(game: game)
            if !features.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Theme.eyebrow(String(localized: "Features"), color: Theme.onDarkTertiary)
                    FlowLayout(spacing: 5) {
                        ForEach(features, id: \.self) { feature in
                            Text(feature).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.onDarkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 9).padding(.vertical, 4).frame(minHeight: 24)
                                .background(Theme.fill(0.08), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line(0.08)))
    }

    /// One line of the facts card: name on the left, value on the right. A value that doesn't fit beside its name
    /// is never cut off: the name goes above it and the value runs over as many lines as it needs, as in the
    /// system's own info panels. Selectable, so it can be copied.
    private func fact(_ key: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text(key).foregroundStyle(Theme.onDarkTertiary).lineLimit(1)
                Spacer(minLength: 0)
                Text(value).fontWeight(.semibold).foregroundStyle(Theme.onDark).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(key).foregroundStyle(Theme.onDarkTertiary)
                Text(value).fontWeight(.semibold).foregroundStyle(Theme.onDark)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    /// "Mods · 3 on" among the facts, for a game with a mods profile: a click opens the Mods page on it.
    private var modsRow: some View {
        Button { model.showMods(for: game) } label: {
            HStack(spacing: 10) {
                Text("Mods").foregroundStyle(Theme.onDarkTertiary).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(localized: "\(model.modsOnCount(of: game)) on")).fontWeight(.semibold).foregroundStyle(Theme.onDark)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.onDarkTertiary)
            }
            .font(.system(size: 12.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Mods")
        .task(id: game.id) { model.reloadMods(for: game) }
    }

    /// Up to five library games of the same genre that should run, when there are at least three.
    /// Five games like this one: Steam's own recommendations ("More Like This"), the user's copy where they own
    /// it and the store's card with its price where they don't. Without them (no Steam match, or offline), library
    /// games of the same genre that should run, when there are at least three.
    @ViewBuilder private func similar(_ info: GameInfo?) -> some View {
        let picks = model.similar(to: game)
        let genre = info?.genres.first
        let fallback = !picks.isEmpty || genre == nil ? [] : model.games(for: .allGames)
            .filter { $0.id != game.id && model.info[$0.id]?.genres.first == genre && model.compatibility(of: $0).verdict != .wontRun }
            .sorted { ($0.isInstalled ? 0 : 1, $0.title) < ($1.isInstalled ? 0 : 1, $1.title) }
        if picks.count >= 3 || fallback.count >= 3 {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SectionHeader(title: "Similar Games")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 5),
                          alignment: .leading, spacing: Theme.Space.m) {
                    if picks.isEmpty {
                        ForEach(fallback.prefix(5)) { GameCard(game: $0) }
                    } else {
                        ForEach(picks.prefix(5)) { pick in
                            switch pick {
                            case .owned(let owned): GameCard(game: owned)
                            case .store(let item): StoreGameCard(item: item)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A strip of 16:9 tiles, the trailer first (with a play mark), then every screenshot; each opens the viewer.
    /// Four fit with half of the next one showing, so it reads as scrollable; trackpad swipes scroll it, and on
    /// hover round arrows page by four for a mouse.
    private func gallery(_ info: GameInfo) -> some View {
        let items = AppModel.ScreenshotViewing.items(trailer: info.trailerURL, thumbnail: info.trailerThumbnail, shots: info.screenshots)
        let open = { (index: Int) in
            withAnimation(.easeOut(duration: 0.2)) { model.viewing = .init(title: game.title, items: items, index: index) }
        }
        let scrolls = items.count > 4
        // The tiles' size from the strip's width, so its height is exactly a tile's (plus room for the hover lift):
        // a strip that sizes itself from its tiles (16:9 inside a scroll view) took far more height than they need,
        // leaving empty bands above and below.
        let columns = scrolls ? 9.0 : 4.0, span = scrolls ? 2.0 : 1.0, gap = 8.0
        let tileWidth = galleryWidth > 0 ? ((galleryWidth - gap * (columns - 1)) / columns * span + gap * (span - 1)).rounded(.down) : 240
        let tileHeight = (tileWidth * 9 / 16).rounded(.down)
        let first = galleryFirst ?? 0
        let page = { (step: Int) in
            withAnimation(.easeInOut(duration: 0.35)) { galleryFirst = min(max(0, first + step), max(0, items.count - 4)) }
        }
        return ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button { open(index) } label: {
                    Color.clear.frame(width: tileWidth, height: tileHeight)
                        .overlay { Artwork(url: item.still, title: "", titleOnPlaceholder: false) }
                        .overlay {
                            if item.isVideo {
                                ZStack {
                                    Color.black.opacity(0.25)
                                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.ink)
                                        .frame(width: 28, height: 28).background(.white.opacity(0.92), in: Circle())
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        .hoverLift()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.isVideo ? String(localized: "Trailer") : String(localized: "Screenshot \(index + 1) of \(items.count)"))
                .accessibilityHint("Opens it full size")
                .id(index)
            }
          }
          .scrollTargetLayout()
          .padding(.vertical, 4)        // room for the hover lift
        }
        .frame(height: tileHeight + 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { galleryWidth = $0 }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $galleryFirst, anchor: .leading)
        .scrollDisabled(!scrolls)
        .overlay(alignment: .leading) {
            if scrolls && galleryHover && first > 0 { galleryArrow("chevron.left") { page(-4) }.padding(.leading, 6) }
        }
        .overlay(alignment: .trailing) {
            if scrolls && galleryHover && first < items.count - 4 { galleryArrow("chevron.right") { page(4) }.padding(.trailing, 6) }
        }
        .onHover { galleryHover = $0 }
        .animation(.easeOut(duration: 0.15), value: galleryHover)
        .onChange(of: game.id) { galleryFirst = nil }
        .onAppear { if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_SCREENSHOT"] == "1" { open(0) } }
    }

    private func galleryArrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(GlassCircleButtonStyle())
            .accessibilityLabel(symbol == "chevron.left" ? String(localized: "Previous screenshots") : String(localized: "Next screenshots"))
            .transition(.opacity)
    }

    // MARK: Helpers

    private func refreshPick() {
        guard let engine = model.engine(for: game.store.bottleKind) else { return }
        var auto = model.profile(for: game)
        auto.backend = .auto
        Task { automaticPick = await model.resolvedBackend(for: game, profile: auto, engine: engine) }
    }
}

/// The game page's "…" menu: graphics, logs, saves, fixes, uninstall. Its own view, so the page's every-second
/// updates (download progress, play time) don't rebuild it while it is open, which closed its submenus under the
/// pointer.
private struct GameMoreMenu: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @Binding var automaticPick: GraphicsBackend?

    var body: some View {
        let profile = model.profile(for: game)
        return Menu {
            if !game.isNative {
            Picker("Graphics", selection: Binding(
                get: { profile.backend },
                set: { var p = profile; p.backend = $0; model.setProfile(p, for: game); refreshPick() }
            )) {
                ForEach(model.backends(for: game), id: \.self) { backend in
                    if backend == .auto, let pick = automaticPick { Text("Automatic (\(pick.localizedName))").tag(backend) }
                    else { Text(backend.localizedName).tag(backend) }
                }
            }
            #if DEBUG
            // Apple's Metal HUD: a developer's tool (read at launch), only in debug builds; players have the in-game counter.
            Toggle("Performance HUD", isOn: Binding(
                get: { profile.performanceHUD }, set: { var p = profile; p.performanceHUD = $0; model.setProfile(p, for: game) }))
            #endif
            Toggle("Retina Resolution", isOn: Binding(
                get: { profile.retina }, set: { model.setRetina($0, for: game) }))
            Divider()
            }
            Button("Show Log") { model.showLog(for: game.id) }
            if (model.settings.clips ?? ClipSettings()).enabled {
                Toggle("Record Clips in This Game", isOn: Binding(
                    get: { (model.settings.clips ?? ClipSettings()).records(game.id) },
                    set: { on in
                        var c = model.settings.clips ?? ClipSettings()
                        c.disabledGames.removeAll { $0 == game.id }
                        if !on { c.disabledGames.append(game.id) }
                        model.settings.clips = c
                    }))
            }
            if !game.isNative, game.isInstalled {
                let backups = model.saveBackups(of: game)
                Menu("Restore Saves") {
                    if backups.isEmpty {
                        Text("No backups yet")
                    } else {
                        ForEach(backups.prefix(10)) { backup in
                            Button(backup.created.formatted(date: .abbreviated, time: .shortened)) { model.restoreSaves(backup, of: game) }
                        }
                    }
                    Divider()
                    Button("Show Backups in Finder") { model.showSaveBackups(of: game) }
                }
                .disabled(model.isActive(game))
            }
            if model.steamInstallingIDs.contains(game.id) {
                Button("Show Downloads in Steam") { Task { await model.openSteamDownloads(for: game) } }
            }
            // The fixes the failure sheet would offer, by hand: only those that can apply to this game (its files
            // say so), none already applied. Applied without starting the game.
            let manual = model.manualFixes(for: game)
            if !manual.isEmpty {
                Menu("Fix Launch") {
                    ForEach(manual, id: \.action.summary) { fix in
                        Button(fix.recommended ? String(localized: "\(model.fixTitle(fix.action, for: game)) (recommended)") : model.fixTitle(fix.action, for: game)) {
                            Task { await model.applyFix(FixRule(id: "manual", cause: "", patterns: [], action: fix.action), to: game, thenPlay: false) }
                        }
                    }
                }
            }
            let fixes = model.appliedFixes(of: game)
            if !fixes.isEmpty {
                Menu("Applied Fixes") {
                    ForEach(fixes) { fix in
                        Button(String(localized: "Undo: \(model.fixTitle(fix.action, for: game))")) { Task { await model.undoFix(fix, for: game) } }
                            .disabled(!fix.action.isUndoable)
                    }
                }
            }
            if game.isInstalled {
                Button("Report a Problem…") { model.reportProblem(with: game) }
            }
            if game.isInstalled || model.installingIDs.contains(game.id) {
                Divider()
                Button(game.isInstalled ? "Uninstall…" : "Cancel Download…", role: .destructive) {
                    Task { await model.uninstall(game) }
                }
                .disabled(model.isActive(game) || model.uninstallState(of: game) != nil)
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Graphics and options")
        .accessibilityLabel("More options")
    }

    private func refreshPick() {
        guard let engine = model.engine(for: game.store.bottleKind) else { return }
        var auto = model.profile(for: game)
        auto.backend = .auto
        Task { automaticPick = await model.resolvedBackend(for: game, profile: auto, engine: engine) }
    }
}

/// Will the game run: the answer, why, its notes, and where the answer comes from. Setting up DirectX 12 is an
/// action, shown under them when the game needs it.
struct CompatibilityPanel: View {
    let compatibility: Compatibility
    /// What to say about the game's Mac version, when there's something to say.
    let macNote: String?
    var antiCheat: AntiCheat.Entry? = nil
    var needsDirectX12 = false
    var setUpDirectX12: () -> Void = {}
    /// "Doesn't work?" under a "Works" from playing here or from players (nil: not offered), and the line saying
    /// the player took it back, with Undo.
    var onDispute: (() -> Void)? = nil
    var disputedProblem: StatusDispute.Problem? = nil
    var onUndoDispute: () -> Void = {}

    private var verdict: Compatibility.Verdict { compatibility.verdict }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m - 4) {
            row(icon: verdict.mark.foregroundStyle(verdict.color).frame(width: 26, height: 26)) {
                Text(verdict.localizedTitle).font(.headline).foregroundStyle(Theme.onDark)
                // Taken back by the player with nothing else known: "if it runs for you…" would contradict them.
                let explanation = disputedProblem != nil && compatibility.reason == .noData
                    ? String(localized: "No other reports about it yet.") : compatibility.localizedExplanation
                if let explanation {
                    Text(explanation)
                        .font(.callout).foregroundStyle(Theme.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let onDispute {
                    Button("Doesn't work?", action: onDispute)
                        .buttonStyle(.plain).font(.callout).underline()
                        .foregroundStyle(Theme.onDark.opacity(0.85)).padding(.top, 2)
                }
            }
            if let problem = disputedProblem {
                Divider().overlay(Theme.hairline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(problem == .other ? String(localized: "You marked that it doesn't work for you.")
                         : String(localized: "You marked that it doesn't work for you: \(problem.localizedInSentence)."))
                        .font(.callout).foregroundStyle(Theme.onDarkSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Undo", action: onUndoDispute).buttonStyle(.plain).font(.callout).underline().foregroundStyle(Theme.onDark)
                }
            }
            // A Mac version that is the answer's reason is already explained above.
            ForEach(compatibility.notes.filter { !(compatibility.reason == .macVersion && $0 == .macVersion) }, id: \.self) { note in
                Divider().overlay(Theme.hairline)
                row(icon: symbol(note.symbol, note.color)) {
                    Text(note.localizedTitle).font(.callout.weight(.semibold)).foregroundStyle(Theme.onDark)
                    Text(note == .macVersion ? (macNote ?? note.localizedExplanation) : note.localizedExplanation)
                        .font(.callout).foregroundStyle(Theme.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if needsDirectX12 && verdict != .wontRun {
                Divider().overlay(Theme.hairline)
                row(icon: symbol("cpu", Theme.onDark)) {
                    Text("Needs DirectX 12 setup").font(.callout.weight(.semibold)).foregroundStyle(Theme.onDark)
                    Text("This game needs DirectX 12. Set it up once, and every DirectX 12 game can run.")
                        .font(.callout).foregroundStyle(Theme.onDarkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Set Up DirectX 12", action: setUpDirectX12)
                        .buttonStyle(QuickPlayButtonStyle()).padding(.top, Theme.Space.xs)
                }
            }
        }
        .padding(.vertical, 14).padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(verdict == .wontRun ? Theme.wineLight.opacity(0.5) : Theme.line(0.1)))
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.title3).foregroundStyle(color)
    }

    private func row<Icon: View, Content: View>(icon: Icon, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m - 4) {
            icon.frame(width: 30)
            VStack(alignment: .leading, spacing: 3) { content() }
        }
    }
}

/// The answer in a small capsule (grape and word) beside the game's facts. Hovering shows the full panel in a
/// popover; it stays open while the pointer is over it, so its button (DirectX 12 setup) can be clicked.
/// "Won't run" fills the capsule with wine.
struct CompatibilityChip: View {
    let compatibility: Compatibility
    let macNote: String?
    var antiCheat: AntiCheat.Entry? = nil
    var needsDirectX12 = false
    var setUpDirectX12: () -> Void = {}
    var onDispute: (() -> Void)? = nil
    var disputedProblem: StatusDispute.Problem? = nil
    var onUndoDispute: () -> Void = {}
    @State private var overChip = false
    @State private var overCard = false
    @State private var shown = false
    @Environment(\.pageScheme) private var pageScheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let verdict = compatibility.verdict
        let wont = verdict == .wontRun
        Button { shown.toggle() } label: {
            HStack(spacing: 5) {
                verdict.mark.foregroundStyle(wont ? Theme.onDark : verdict.color).frame(width: 13, height: 13)
                Text(verdict.localizedTitle)
                if needsDirectX12 && !wont { Circle().fill(Theme.wineLight).frame(width: 5, height: 5) }
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 22)
            .background(wont ? AnyShapeStyle(Theme.wine) : AnyShapeStyle(.black.opacity(0.35)), in: Capsule())
            .overlay(Capsule().strokeBorder(wont ? Theme.wineLight : .white.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { overChip = $0; sync() }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            CompatibilityPanel(compatibility: compatibility, macNote: macNote, antiCheat: antiCheat,
                               needsDirectX12: needsDirectX12, setUpDirectX12: { shown = false; setUpDirectX12() },
                               onDispute: onDispute.map { act in { shown = false; act() } },
                               disputedProblem: disputedProblem, onUndoDispute: onUndoDispute)
                .frame(width: 340)
                .padding(4)
                .onHover { overCard = $0; sync() }
                .environment(\.colorScheme, pageScheme ?? scheme)
        }
        .accessibilityLabel(verdict.localizedTitle)
    }

    /// Opens at once on hover; closes a moment after the pointer has left both the chip and the card.
    private func sync() {
        if overChip || overCard { shown = true; return }
        Task { try? await Task.sleep(for: .milliseconds(250)); if !overChip && !overCard { shown = false } }
    }
}

/// "Saves synced 5 minutes ago", "Saves waiting to upload", "Saves not synced: no internet connection".
struct SaveSyncLine: View {
    let status: SaveSyncStatus
    let online: Bool

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12)).foregroundStyle(status.state == .synced ? Theme.onDarkSecondary : Theme.wineLight)
            .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status.state {
        case .synced: "icloud"
        case .pendingUpload: "icloud.and.arrow.up"
        case .failed: "icloud.slash"
        }
    }

    private var text: String {
        switch status.state {
        case .synced: String(localized: "Saves synced \(status.date.formatted(.relative(presentation: .named)))")
        case .pendingUpload: online ? String(localized: "Saves waiting to upload") : String(localized: "Saves waiting to upload: no internet connection")
        case .failed: String(localized: "Saves not synced: \(status.message ?? "")")
        }
    }
}

/// The game's logo over its art where the store has one (Steam's `logo.png`), the name in text where it hasn't.
struct TitleOrLogo: View {
    @Environment(ArtworkStore.self) private var store
    let title: String
    let logoURL: URL?
    var maxWidth: CGFloat = 440
    var maxHeight: CGFloat = 140
    /// The store page isn't in yet, so a logo may still turn up: don't settle on the name right away.
    var infoPending = false
    /// The logo took too long: show the name rather than nothing (it fades to the logo if one arrives).
    @State private var waitedEnough = false

    var body: some View {
        let image = store.image(logoURL)
        _ = store.failedCount                                        // re-renders when a load gives up
        return ZStack(alignment: .leading) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                    .accessibilityLabel(title)
                    .transition(.opacity)
            } else if (logoURL == nil ? !infoPending : store.hasFailed(logoURL)) || waitedEnough {
                Text(title).font(Theme.Font.hero).foregroundStyle(Theme.onDark).lineLimit(2)
                    .transition(.opacity)
            } else {
                Color.clear.frame(height: 44)                         // the logo's place while it loads
            }
        }
        .animation(.easeInOut(duration: 0.25), value: image == nil)
        .onAppear { store.load(logoURL) }
        .onChange(of: logoURL) { store.load(logoURL) }
        .task(id: logoURL) {
            waitedEnough = false
            try? await Task.sleep(for: .milliseconds(1200))
            waitedEnough = true
        }
    }
}


extension GameInfo.PlayerMode {
    var localizedName: String {
        switch self {
        case .single: String(localized: "Single-player")
        case .multi: String(localized: "Multiplayer")
        case .coop: String(localized: "Co-op")
        case .online: String(localized: "Online")
        }
    }

    var symbol: String {
        switch self {
        case .single: "person"
        case .multi: "person.2"
        case .coop: "person.2.wave.2"
        case .online: "globe"
        }
    }
}

/// The trailer in the viewer: its still with a play button first (the video opens on a rating card), then the
/// video with the system's controls, starting silent.
private struct TrailerControls: View {
    let url: URL
    let still: URL?
    @State private var playing = false

    var body: some View {
        ZStack {
            Color.black
            if playing {
                TrailerPlayerView(url: url)
            } else {
                Artwork(url: still, title: "", titleOnPlaceholder: false)
                Button { playing = true } label: {
                    Image(systemName: "play.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                        .frame(width: 64, height: 64).background(.white.opacity(0.92), in: Circle())
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel("Play Trailer")
            }
        }
        .onChange(of: url) { playing = false }
    }
}

/// AppKit's player view (SwiftUI's VideoPlayer crashes on load in this setup).
private struct TrailerPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        player.isMuted = true
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause() }
}

/// Screenshots full size inside the window, over everything: the game's name and "2 / 8" at the top, the
/// picture in the middle with arrows at the sides, and a strip of all of them below. Esc or a click outside closes.
struct ScreenshotViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(ArtworkStore.self) private var store
    let viewer: AppModel.ScreenshotViewing

    var body: some View {
        let items = viewer.items, index = min(viewer.index, items.count - 1)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(viewer.title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.onDark).lineLimit(1)
                Text(verbatim: "\(index + 1) / \(items.count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(.white.opacity(0.12), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 84).padding(.trailing, 18).frame(height: 52)   // clear of the window's buttons
            .padding(.top, 2)

            ZStack {
                Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                picture(items[index])
                    .id(index)
                    .transition(.opacity)
                    .padding(.horizontal, 70)
                if items.count > 1 {
                    HStack {
                        arrow("chevron.left", by: -1).keyboardShortcut(.leftArrow, modifiers: [])
                        Spacer()
                        arrow("chevron.right", by: 1).keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .padding(.horizontal, Theme.Space.m)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    Button { go(to: i) } label: {
                        Color.clear.frame(width: 96, height: 54)
                            .overlay { Artwork(url: item.still, title: "", titleOnPlaceholder: false) }
                            .overlay {
                                if item.isVideo {
                                    Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.8), radius: 3)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white, lineWidth: i == index ? 2 : 0))
                            .opacity(i == index ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isVideo ? String(localized: "Trailer") : String(localized: "Screenshot \(i + 1) of \(items.count)"))
                }
            }
            .frame(height: 92)
        }
        .background {
            ZStack { Rectangle().fill(.ultraThinMaterial); Color(red: 16 / 255, green: 13 / 255, blue: 12 / 255).opacity(0.92) }
                .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: index)
        .ignoresSafeArea()
    }

    private func picture(_ item: AppModel.ScreenshotViewing.Item) -> some View {
        Group {
            if case .video(let url, let still) = item {
                TrailerControls(url: url, still: still).aspectRatio(16.0 / 9.0, contentMode: .fit)
            } else if let image = store.image(item.still) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Artwork(url: item.still, title: "", titleOnPlaceholder: false).aspectRatio(16.0 / 9.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.9), radius: 40, y: 20)
    }

    private func arrow(_ symbol: String, by: Int) -> some View {
        Button { go(to: (viewer.index + by + viewer.items.count) % viewer.items.count) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(.white.opacity(0.14), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(by < 0 ? "Previous screenshot" : "Next screenshot")
    }

    private func go(to i: Int) { model.viewing?.index = i }
    private func close() { withAnimation(.easeOut(duration: 0.2)) { model.viewing = nil } }
}

/// Lays out its children in rows, wrapping to the next row when one is full (for chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.items + [index], needed, max(current.height, size.height))
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// A game the user doesn't own, from the store's recommendations: its cover with the price in the corner (in the
/// currency of the user's region), and its name. Opens its store page.
struct StoreGameCard: View {
    let item: SteamStore.Item

    var body: some View {
        Button { NSWorkspace.shared.open(item.storePage) } label: {
            VStack(alignment: .leading, spacing: Theme.Space.s - 2) {
                Artwork(url: item.cover, title: item.name)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if let price = item.price { priceTag(price).padding(7) }
                    }
                    .hoverLift()
                Text(item.name).font(Theme.Font.cardTitle).lineLimit(1).padding(.top, Theme.Space.xs)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Opens \(item.name) in the Steam store"))
        .accessibilityLabel([item.name, item.price].compactMap { $0 }.joined(separator: ", "))
    }

    /// The price in the cover's corner; on sale, the old price struck through before it, in one line. It never
    /// grows wider than the card leaves it: the text shrinks a little first.
    private func priceTag(_ price: String) -> some View {
        HStack(spacing: 6) {
            if let original = item.originalPrice, (item.discount ?? 0) > 0 {
                Text(verbatim: original)
                    .font(.system(size: 11, weight: .medium)).strikethrough(color: .white.opacity(0.6))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(verbatim: price).font(.system(size: 12, weight: .bold))
        }
        .monospacedDigit().foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
