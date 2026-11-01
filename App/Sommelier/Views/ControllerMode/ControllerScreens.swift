// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVKit
import SommelierKit
import SwiftUI

// MARK: Home

/// Home: the focused game large at the top, rows of covers below (recently played, installed, everything).
struct HomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus

    private var installed: [Game] { model.games(for: .installed).filter(\.isInstalled) }
    private var recent: [Game] {
        installed.filter { model.lastPlayed($0) != nil }.sorted { model.lastPlayed($0)! > model.lastPlayed($1)! }.prefix(8).map { $0 }
    }
    private var all: [Game] { model.games(for: .allGames) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let game = state.backdrop ?? recent.first ?? installed.first ?? all.first { HeroText(game: game).offset(x: CM.margin, y: 150) }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 44) {
                        if !recent.isEmpty { CoverRow(title: String(localized: "Recently Played"), games: recent, key: "recent", wide: true).id("row:recent") }
                        if !installed.isEmpty { CoverRow(title: String(localized: "Installed"), games: installed, key: "installed").id("row:installed") }
                        CoverRow(title: String(localized: "All Games"), count: all.count, games: Array(all.prefix(20)), key: "all", more: all.count > 20).id("row:all")
                    }
                    .padding(.top, 12).padding(.bottom, 120)
                }
                .frame(width: CM.width, height: CM.height - 500 - 96)
                .offset(y: 500)
                .onChange(of: focus.current) { _, id in
                    guard let id, let row = id.split(separator: ":").dropFirst().first else { return }
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("row:\(row)", anchor: .top) }
                }
            }
        }
        .onAppear {
            let first = recent.first ?? installed.first ?? all.first
            if state.backdrop == nil { state.backdrop = first }
            if focus.current == nil, focus.wanted == nil, let first { focus.focus("g:\(recent.isEmpty ? (installed.isEmpty ? "all" : "installed") : "recent"):\(first.id)") }
        }
    }
}

/// The big name and the facts of the game in focus.
struct HeroText: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let logo = model.logoURL(for: game) {
                Artwork(url: logo, title: game.title, titleOnPlaceholder: false).frame(maxWidth: 620, maxHeight: 190, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 6)
            } else {
                Text(game.title).font(.system(size: 92, weight: .heavy)).tracking(-2).lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 4)
            }
            HStack(spacing: 30) {
                StatusMark(verdict: model.compatibility(of: game).verdict)
                if game.isInstalled { Text("Installed") } else if let size = game.knownSize { Text(size) }
                if model.playTime(game) > 0 { Text(String(localized: "\(model.playTime(game).playTime) played")) }
            }
            .font(CM.font(27)).foregroundStyle(CM.t2)
        }
        .frame(width: 1000, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: game.id)
    }
}

/// "Works" with the grape cluster, as the main app shows it.
struct StatusMark: View {
    let verdict: Compatibility.Verdict
    var body: some View {
        HStack(spacing: 12) {
            verdict.mark.frame(width: 30, height: 30)
            Text(verdict.localizedTitle).font(CM.font(27, .semibold))
        }
        .foregroundStyle(verdict == .wontRun ? CM.wineHi : CM.ivory)
    }
}

/// A row of covers that scrolls sideways to the one in focus.
struct CoverRow: View {
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    let title: String
    var count: Int? = nil
    let games: [Game]
    let key: String
    var wide = false
    var more = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).font(CM.font(32, .bold))
                if let count { Text(count, format: .number).font(CM.font(27, .medium)).foregroundStyle(CM.t3) }
            }
            .padding(.horizontal, CM.margin)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(games) { game in
                            CoverTile(game: game, wide: wide, key: key).id("g:\(key):\(game.id)")
                        }
                        if more {
                            VStack(spacing: 6) {
                                Text("All Games").font(CM.font(30, .bold))
                                if let count { Text(count, format: .number).font(CM.font(24)).foregroundStyle(CM.t3) }
                            }
                            .frame(width: 238, height: 357)
                            .background(CM.graphite, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CM.line, lineWidth: 2))
                            .focusTarget("g:\(key):more") { state.stack.removeAll(); state.screen = .library }
                            .id("g:\(key):more")
                        }
                    }
                    .padding(.horizontal, CM.margin).padding(.vertical, 14)
                }
                .onChange(of: focus.current) { _, id in
                    guard let id, id.hasPrefix("g:\(key):") else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

struct CoverTile: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    let game: Game
    var wide = false
    let key: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(url: wide ? model.headerURL(for: game) ?? model.coverURL(for: game) : model.coverURL(for: game), title: game.title,
                    fallback: model.headerURL(for: game))
                .frame(width: wide ? 420 : 238, height: wide ? 236 : 357)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if game.isInstalled {
                Image(systemName: "checkmark").font(CM.font(22, .bold)).frame(width: 40, height: 40)
                    .background(CM.ground.opacity(0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(12)
            }
            if let install = model.installState(of: game), case .steam(let d) = install, let fraction = d.fraction {
                GeometryReader { g in
                    Capsule().fill(CM.ground.opacity(0.8)).frame(height: 8)
                        .overlay(alignment: .leading) { Capsule().fill(CM.ivory).frame(width: g.size.width * fraction, height: 8) }
                }
                .frame(height: 8).padding(12)
            }
        }
        .background(CM.graphite, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusTarget("g:\(key):\(game.id)", game: game) { state.go(.game(game)) }
    }
}

// MARK: Library

/// Every game, seven to a row, with the store filter above.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus

    private var games: [Game] {
        var list = model.games(for: .allGames)
        if let store = state.storeFilter { list = model.visibleGames.filter { $0.store == store } }
        if state.sortByRecent { list.sort { (model.lastPlayed($0) ?? .distantPast) > (model.lastPlayed($1) ?? .distantPast) } }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Glyph(.leftTrigger).frame(height: 36)
                chip(String(localized: "All"), nil)
                ForEach(model.storesInUse, id: \.self) { chip($0.displayName, $0) }
                Glyph(.rightTrigger).frame(height: 36)
                Spacer()
                Text(games.count, format: .number).foregroundStyle(CM.t3)
            }
            .padding(.horizontal, CM.margin)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(238), spacing: 26), count: 7), alignment: .leading, spacing: 30) {
                        ForEach(games) { game in CoverTile(game: game, key: "lib").id("g:lib:\(game.id)") }
                    }
                    .padding(.horizontal, CM.margin).padding(.vertical, 14)
                }
                .safeAreaPadding(.bottom, 110)                 // the hints bar lies over the bottom
                .onChange(of: focus.current) { _, id in
                    guard let id, id.hasPrefix("g:lib:") else { return }
                    // Just enough to bring the row into view, so the first row stays under the filters, not behind them.
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: nil) }
                }
            }
        }
        .padding(.top, 120)
        .frame(width: CM.width, height: CM.height - 96, alignment: .topLeading)
        .onAppear { if focus.current == nil, focus.wanted == nil, let first = games.first { focus.focus("g:lib:\(first.id)") } }
    }

    private func chip(_ title: String, _ store: StoreKind?) -> some View {
        let on = state.storeFilter == store
        return Text(title).font(CM.font(24, .semibold)).foregroundStyle(on ? CM.ground : CM.t2)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(on ? CM.ivory : CM.ivory.opacity(0.08), in: Capsule())
            .focusTarget("chip:\(title)", shape: .pill) { state.storeFilter = store }
    }
}

// MARK: The game's page

/// The game as a console shows a game you own: the logo, Play and "…" with the numbers beside them, the status
/// line (A opens what it rests on), then rows: your clips (installed) or screenshots (not installed), and more games
/// that work. The page scrolls under the top bar; a focused row comes up to just under it.
struct GamePageScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    @State private var recorder = ClipRecorder.shared
    let game: Game

    private var compatibility: Compatibility { model.compatibility(of: game) }
    private var info: GameInfo? { model.info[game.id] }
    private var installing: AppModel.InstallState? { model.installState(of: game) }
    private var clips: [Clip] { recorder.clips.filter { $0.gameID == game.id } }
    private var others: [Game] {
        model.games(for: .allGames).filter { $0.id != game.id && model.compatibility(of: $0).verdict == .works }.prefix(14).map { $0 }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 56) {
                    Color.clear.frame(height: 150 - 56).id("sec:top")
                    header.id("sec:header")
                    if game.isInstalled && installing == nil { clipsRow.id("sec:clips") }
                    if let shots = info?.screenshots, !shots.isEmpty { screenshotsRow(shots).id("sec:shots") }
                    if !others.isEmpty {
                        CoverRow(title: String(localized: "More games that work"), games: others, key: "works").id("sec:works")
                            .padding(.horizontal, -CM.margin)
                    }
                }
                .padding(.horizontal, CM.margin).padding(.bottom, 420)          // room for the last row to come up too
            }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 174.0 / (CM.height - 96)),
                                         .init(color: .black, location: (CM.height - 196) / (CM.height - 96)), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: focus.current) { _, id in
                guard let id else { return }
                let section = id.hasPrefix("game:") ? "sec:header" : id.hasPrefix("clip:") ? "sec:clips" : id.hasPrefix("shot:") ? "sec:shots"
                    : id.hasPrefix("g:works:") ? "sec:works" : nil
                guard let section else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    if section == "sec:header" { proxy.scrollTo("sec:top", anchor: .top) }
                    // The row's title 70 pt under the top bar (104 pt): 174 pt down the page.
                    else { proxy.scrollTo(section, anchor: UnitPoint(x: 0, y: 174.0 / (CM.height - 96))) }
                }
            }
        }
        .frame(width: CM.width, height: CM.height - 96, alignment: .topLeading)
        .onAppear {
            state.focusedKind = nil
            if focus.current == nil, focus.wanted == nil { focus.focus("game:primary") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .controllerModeMore)) { _ in openMore() }
        // The store's details (screenshots, logo) as the ordinary game page loads them: a game never opened there
        // has none yet.
        .task(id: game.id) { await model.loadInfo(for: game) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 34) {
            if let logo = model.logoURL(for: game) {
                Artwork(url: logo, title: game.title, titleOnPlaceholder: false).frame(maxWidth: 620, maxHeight: 190, alignment: .leading)
                    .frame(height: 190, alignment: .leading)
            } else {
                Text(game.title).font(.system(size: 80, weight: .heavy)).tracking(-1.5).lineLimit(2)
            }
            if let installing { progress(installing) }
            HStack(alignment: .center, spacing: 16) {
                buttons
                HStack(spacing: 56) {
                    if game.isInstalled {
                        fact(String(localized: "Last played"), model.lastPlayed(game)?.playedAgo ?? String(localized: "Never"))
                        fact(String(localized: "Played"), model.playTime(game) > 0 ? model.playTime(game).playTime : "—")
                    } else {
                        fact(String(localized: "Size"), game.knownSize ?? "—")
                    }
                    fact(String(localized: "From"), game.store.displayName)
                }
                .padding(.leading, 40)
            }
            statusLine
        }
    }

    @ViewBuilder private var buttons: some View {
        if let installing {
            if model.canPause(game, installing) {
                pill(String(localized: "Pause"), "pause.fill", id: "game:primary", prominent: true) { Task { await model.pauseDownload(game) } }
            } else if model.canResume(game, installing) {
                pill(String(localized: "Resume"), "play.fill", id: "game:primary", prominent: true) { Task { await model.resumeDownload(game) } }
            }
            if case .direct = installing {
                pill(String(localized: "Cancel Install"), "xmark", id: "game:cancel") { model.cancelDirectInstall(game) }
            } else if case .launcher = installing {
                EmptyView()
            } else {
                pill(String(localized: "Cancel Install"), "xmark", id: "game:cancel") { Task { await model.uninstall(game) } }
            }
        } else if model.isActive(game) {
            pill(String(localized: "Return to Game"), "play.fill", id: "game:primary", prominent: true) { returnToGame() }
            pill(String(localized: "Close Game…"), "xmark", id: "game:close") { state.overlay = .closeAsk(game) }
            more
        } else if game.isInstalled {
            pill(String(localized: "Play"), "play.fill", id: "game:primary", prominent: true) { play() }
            more
        } else {
            pill(String(localized: "Install"), "arrow.down.to.line", id: "game:primary", prominent: true) { Task { await model.install(game) } }
            more
        }
    }

    private var more: some View {
        Text(verbatim: "⋯").font(CM.font(30, .bold)).frame(width: 72, height: 72)
            .background(CM.ivory.opacity(0.1), in: Circle())
            .focusTarget("game:more", shape: .pill) { openMore() }
    }

    private func progress(_ install: AppModel.InstallState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.downloadShort(game, install)).font(CM.font(28, .semibold))
            GeometryReader { g in
                Capsule().fill(CM.ivory.opacity(0.15))
                    .overlay(alignment: .leading) { Capsule().fill(CM.ivory).frame(width: g.size.width * (fraction(install) ?? 0)) }
            }
            .frame(width: 900, height: 10)
        }
    }

    private func fraction(_ install: AppModel.InstallState) -> Double? { install.fraction }

    /// The answer in one line: the grapes, the word, and what it means; A opens the rest.
    private var statusLine: some View {
        HStack(spacing: 18) {
            StatusMark(verdict: compatibility.verdict)
            Text(Self.sentence(compatibility.verdict)).font(CM.font(25)).foregroundStyle(CM.t2)
            Image(systemName: "chevron.right").font(CM.font(20, .semibold)).foregroundStyle(CM.t3)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(CM.ground.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .focusTarget("game:status", shape: .rect) { state.overlay = .status(game) }
    }

    static func sentence(_ verdict: Compatibility.Verdict) -> String {
        switch verdict {
        case .works: String(localized: "Starts and plays well on Macs like this one.")
        case .likely: String(localized: "Similar games work. Not tested on this Mac yet.")
        case .unknown: String(localized: "Nobody has tried it with Sommelier yet.")
        case .wontRun: String(localized: "Its anti-cheat blocks it on a Mac.")
        }
    }

    // MARK: Rows

    private var clipsRow: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Your Clips").font(CM.font(32, .bold))
                if !clips.isEmpty { Text(clips.count, format: .number).font(CM.font(27, .medium)).foregroundStyle(CM.t3) }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        if clips.isEmpty {
                            Text(noClipsText).font(CM.font(25)).foregroundStyle(CM.t2).multilineTextAlignment(.leading)
                                .padding(30).frame(width: 640, height: 236, alignment: .leading)
                                .background(CM.graphite, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(CM.line, lineWidth: 2))
                                .focusTarget("clip:none", shape: .cover) {}
                        }
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            ClipTile(clip: clip).id("clip:\(clip.id)")
                                .focusTarget("clip:\(clip.id)", shape: .cover) { state.overlay = .clip(clips, index) }
                        }
                    }
                    .padding(.vertical, 14).padding(.horizontal, CM.margin)
                }
                .padding(.horizontal, -CM.margin)
                .onChange(of: focus.current) { _, id in scrollRow(proxy, id, prefix: "clip:", ids: clips.map { "clip:\($0.id)" }) }
            }
        }
    }

    private var noClipsText: String {
        let settings = model.settings.clips ?? ClipSettings()
        let button = ControllerInput.shared.kind == .playStation ? "Create" : "Share"
        return String(localized: "No clips yet. Hold the \(button) button while you play to save the last \(Int(settings.length.seconds)) seconds.")
    }

    private func screenshotsRow(_ shots: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Screenshots").font(CM.font(32, .bold))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) {
                        ForEach(Array(shots.enumerated()), id: \.offset) { index, shot in
                            Artwork(url: shot, title: game.title, titleOnPlaceholder: false).frame(width: 574, height: 323)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .id("shot:\(index)")
                                .focusTarget("shot:\(index)", shape: .cover) { state.overlay = .screenshot(game, shots, index) }
                        }
                    }
                    .padding(.vertical, 14).padding(.horizontal, CM.margin)
                }
                .padding(.horizontal, -CM.margin)
                .onChange(of: focus.current) { _, id in scrollRow(proxy, id, prefix: "shot:", ids: shots.indices.map { "shot:\($0)" }) }
            }
        }
    }

    /// From the third item on, the row moves so the focus sits in the second place.
    private func scrollRow(_ proxy: ScrollViewProxy, _ id: String?, prefix: String, ids: [String]) {
        guard let id, id.hasPrefix(prefix), let index = ids.firstIndex(of: id) else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(ids[max(0, index - 1)], anchor: .leading) }
    }

    // MARK: Pieces

    private func pill(_ title: String, _ symbol: String, id: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) { Image(systemName: symbol).font(CM.font(26, .bold)); Text(title).font(CM.font(30, .bold)) }
            .foregroundStyle(prominent ? CM.ground : CM.ivory)
            .padding(.horizontal, 40).frame(height: 72)
            .background(prominent ? CM.ivory : CM.ivory.opacity(0.1), in: Capsule())
            .focusTarget(id, shape: .pill, action: action)
    }

    private func fact(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).font(CM.font(22)).foregroundStyle(CM.t3)
            Text(value).font(CM.font(28, .semibold))
        }
    }

    private func openMore() { state.overlay = .more(game) }

    private func play() {
        state.overlay = .launching(game)
        Task { await model.play(game) }
    }

    private func returnToGame() {
        guard let pid = AppModel.runningProcess(of: game, enginesFolder: model.paths.engines.path) else { return }
        model.giveFocus(to: pid)
    }
}

/// A clip in the "Your Clips" row: the picture, its length, a star when it's a favourite, when and why.
struct ClipTile: View {
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                ClipThumbnail(url: clip.url).frame(width: 420, height: 236)
                VStack {
                    HStack {
                        if clip.favorite { Image(systemName: "star.fill").font(CM.font(22)).foregroundStyle(CM.ivory) }
                        Spacer()
                        if clip.seconds > 0 { Text(ClipCard.length(clip.seconds)).font(CM.font(20, .semibold)).monospacedDigit() }
                    }
                    Spacer()
                }
                .padding(14).shadow(color: .black.opacity(0.7), radius: 4)
            }
            .frame(width: 420, height: 236)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(caption).font(CM.font(22)).foregroundStyle(CM.t3)
        }
    }

    private var caption: String {
        let day = ClipsView.dayName(Calendar.current.startOfDay(for: clip.date))
        let why: String = switch clip.origin {
        case .controller: String(localized: "Controller")
        case .crash: String(localized: "Crash")
        case .key: String(localized: "Manual")
        }
        return "\(day) · \(why)"
    }
}

// MARK: Over the game's page

/// What the status rests on, as far as the app knows it.
struct StatusDetails: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    let game: Game

    private var compatibility: Compatibility { model.compatibility(of: game) }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        switch compatibility.verdict {
        case .works, .likely:
            if let why = compatibility.localizedExplanation { rows.append((String(localized: "Why we think so"), why)) }
        case .unknown:
            rows.append((String(localized: "Not checked yet"), String(localized: "Nobody has played it with Sommelier on a Mac like yours.")))
            rows.append((String(localized: "If it fails"), String(localized: "Sommelier offers the next option to try, step by step.")))
        case .wontRun:
            if let why = compatibility.localizedExplanation { rows.append((String(localized: "Why"), why)) }
            rows.append((String(localized: "What can change"), String(localized: "Only the game’s makers can allow it. Sommelier will update the status if they do.")))
        }
        let issues = compatibility.notes.map(\.localizedExplanation)
        if compatibility.verdict != .unknown {
            rows.append((String(localized: "Known issues"), issues.isEmpty ? String(localized: "None reported") : issues.joined(separator: "\n")))
        }
        return rows
    }

    var body: some View {
        CenterBox {
            StatusMark(verdict: compatibility.verdict)
            Text(GamePageScreen.sentence(compatibility.verdict)).font(CM.font(26)).foregroundStyle(CM.t2)
            Grid(alignment: .topLeading, horizontalSpacing: 30, verticalSpacing: 18) {
                ForEach(rows, id: \.0) { key, value in
                    GridRow {
                        Text(key).font(CM.font(23)).foregroundStyle(CM.t3).frame(width: 230, alignment: .leading)
                        Text(value).font(CM.font(24)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 10)
            Text("Close").font(CM.font(27, .semibold)).padding(.horizontal, 30).padding(.vertical, 12)
                .background(CM.ivory.opacity(0.1), in: Capsule())
                .focusTarget("status:close", layer: "overlay", shape: .pill) { state.closeOverlay(focus: focus, back: "game:status") }
        }
        .onAppear { focus.focus("status:close") }
    }
}

/// The "…" panel on the right.
struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    let game: Game

    private var clipSettings: ClipSettings { model.settings.clips ?? ClipSettings() }

    var body: some View {
        ZStack(alignment: .trailing) {
            CM.ground.opacity(0.5).contentShape(Rectangle()).onTapGesture { state.closeOverlay(focus: focus, back: "game:more") }
            VStack(alignment: .leading, spacing: 8) {
                Text(game.title).font(CM.font(34, .bold)).lineLimit(2)
                Text(game.isInstalled ? String(localized: "Installed, \(game.knownSize ?? "—")") : String(localized: "Not installed, \(game.knownSize ?? "—")"))
                    .font(CM.font(23)).foregroundStyle(CM.t3).padding(.bottom, 24)
                row(String(localized: "Game Settings…"), id: "more:settings") { model.open(game); ControllerModeWindow.shared.exit() }
                if game.isInstalled, clipSettings.enabled {
                    row(String(localized: "Record Clips in This Game"), value: clipSettings.records(game.id) ? String(localized: "On") : String(localized: "Off"), id: "more:clips") {
                        var c = clipSettings
                        if c.disabledGames.contains(game.id) { c.disabledGames.removeAll { $0 == game.id } } else { c.disabledGames.append(game.id) }
                        model.settings.clips = c
                    }
                }
                row(String(localized: "Open in \(game.store.displayName)"), id: "more:store") { model.openStoreWebsite(game.store) }
                if game.isInstalled, !model.isActive(game) {
                    Divider().overlay(CM.line).padding(.vertical, 10)
                    row(String(localized: "Uninstall…"), id: "more:uninstall") { state.overlay = .uninstallAsk(game) }
                }
                Spacer()
            }
            .padding(50).frame(width: 640, height: CM.height, alignment: .topLeading)
            .background(CM.graphite.opacity(0.98))
        }
        .frame(width: CM.width, height: CM.height)
        .zIndex(5)
        .onAppear { focus.focus("more:settings") }
    }

    private func row(_ title: String, value: String? = nil, id: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(CM.font(28, .semibold))
            Spacer()
            if let value { Text(value).font(CM.font(26)).foregroundStyle(CM.t2) }
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(CM.ivory.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusTarget(id, layer: "overlay", shape: .row, action: action)
    }
}

struct UninstallAskOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    let game: Game

    var body: some View {
        CenterBox {
            Text(String(localized: "Uninstall \(game.title)?")).font(CM.font(40, .bold))
            Text("Your saves stay. You can install it again at any time.").font(CM.font(25)).foregroundStyle(CM.t2)
            HStack(spacing: 16) {
                Text("Uninstall").font(CM.font(27, .semibold)).foregroundStyle(CM.ground).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.wineHi, in: Capsule())
                    .focusTarget("uninstall:yes", layer: "overlay", shape: .pill) {
                        state.closeOverlay(focus: focus, back: "game:primary")
                        Task { await model.uninstall(game) }
                    }
                Text("Cancel").font(CM.font(27, .semibold)).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.ivory.opacity(0.1), in: Capsule())
                    .focusTarget("uninstall:no", layer: "overlay", shape: .pill) { state.closeOverlay(focus: focus, back: "game:more") }
            }
        }
        .onAppear { focus.focus("uninstall:no") }
    }
}

/// A clip or a screenshot over the whole screen; the bumpers go to the previous and next.
struct MediaViewer: View {
    @Environment(ControllerModeState.self) private var state
    let items: [MediaItem]
    let index: Int
    let title: String
    @State private var player = AVPlayer()

    enum MediaItem: Equatable { case clip(URL?), image(URL) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            switch items[index] {
            case .clip(let url):
                VideoPlayer(player: player).disabled(true)
                    .onAppear { start(url) }
                    .onChange(of: index) { _, _ in if case .clip(let url) = items[index] { start(url) } }
            case .image(let url):
                Artwork(url: url, title: title, titleOnPlaceholder: false).aspectRatio(contentMode: .fit).frame(width: CM.width, height: CM.height)
            }
            Text(String(localized: "\(title) · \(index + 1) of \(items.count)")).font(CM.font(26)).foregroundStyle(CM.t2)
                .padding(.horizontal, CM.margin).padding(.bottom, 40)
        }
        .frame(width: CM.width, height: CM.height)
        .zIndex(6)
        .onDisappear { player.pause() }
    }

    private func start(_ url: URL?) {
        guard let url else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }
}

// MARK: Search

/// Search with the on-screen keyboard: results above, letters below.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    @State private var text = ""
    @State private var shifted = false
    @State private var symbols = false
    @State private var voice = VoiceSearch()
    @State private var layouts = KeyboardLayouts.enabled()
    @State private var layoutIndex = 0

    private var results: [Game] {
        // Every word in the title in any order; failing that, words that sound alike (speech gets titles wrong).
        TitleSearch.matches(text, in: model.games(for: .allGames)) { $0.title }
    }

    private static let digits = ["1234567890", "-/:;()$&@", ".,?!'\""].map { $0.map(String.init) }

    /// The keyboard in use: one of the layouts turned on in macOS, or digits and symbols.
    private var layout: KeyboardLayouts.Layout { layouts[min(layoutIndex, layouts.count - 1)] }
    private var rows: [[String]] { symbols ? Self.digits : layout.rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 18) {
                Image(systemName: voice.phase == .listening ? "waveform" : "magnifyingglass").font(CM.font(32))
                    .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening)
                Text(field).font(CM.font(40, .semibold)).foregroundStyle(text.isEmpty ? CM.t3 : CM.ivory)
                if voice.phase != .listening { Rectangle().fill(CM.ivory).frame(width: 3, height: 44) }
            }
            .padding(.horizontal, CM.margin)
            if !text.isEmpty {
                Text(String(localized: "Games with “\(text)”")).font(CM.font(27)).foregroundStyle(CM.t2) + Text(verbatim: "  ") + Text(results.count, format: .number).font(CM.font(27)).foregroundStyle(CM.t3)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 26) { ForEach(results.prefix(20)) { CoverTile(game: $0, key: "search").id("g:search:\($0.id)") } }
                        .padding(.horizontal, CM.margin).padding(.vertical, 14)
                }
                .onChange(of: focus.current) { _, id in
                    guard let id, id.hasPrefix("g:search:") else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(height: 390)
            keyboard
        }
        .padding(.top, 130)
        .frame(width: CM.width, height: CM.height - 96, alignment: .topLeading)
        .onAppear {
            if focus.current == nil, focus.wanted == nil { focus.focus("key:0:0") }
            voice.onHeard = { text = $0 }
            voice.language = layout.language
            // The library's titles as hints, the played and installed first (the recognizer takes a hundred or so).
            let games = model.games(for: .allGames)
            let first = games.filter { $0.isInstalled || model.lastPlayed($0) != nil }
            voice.hints = Array((first + games.filter { !first.contains($0) }).map(\.title).prefix(100))
        }
        .onDisappear { voice.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .controllerModeSearchKey)) { note in
            guard let event = note.object as? ControllerEvent else { return }
            press(event)
        }
    }

    private var field: String {
        switch voice.phase {
        case .listening: text.isEmpty ? String(localized: "Listening…") : text
        case .denied: String(localized: "Sommelier needs the microphone and speech recognition for voice search.")
        case .unavailable: String(localized: "Voice search isn’t available on this Mac right now.")
        case .idle: text.isEmpty ? String(localized: "Search") : text
        }
    }

    /// The controller's shortcuts on the keyboard, as consoles have them: X deletes, Y types a space, LT switches
    /// capitals, RT jumps to the results, Menu speaks.
    private func press(_ event: ControllerEvent) {
        switch event {
        case .x: if !text.isEmpty { text.removeLast() }
        case .y: text += " "
        case .leftTrigger: shifted.toggle()
        case .rightTrigger: if let first = results.first { focus.focus("g:search:\(first.id)") }
        case .menu, .view: voice.toggle()
        default: break
        }
    }

    private var keyboard: some View {
        VStack(spacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 12) {
                    ForEach(Array(row.enumerated()), id: \.offset) { c, char in
                        let shown = shifted ? char.uppercased() : char
                        key(shown, id: "key:\(r):\(c)", width: 86) { text += shown; if shifted { shifted = false } }
                    }
                }
            }
            HStack(spacing: 12) {
                key(symbols ? "abc" : "#+=", id: "key:symbols", width: 130) { symbols.toggle() }
                if layouts.count > 1 {
                    HStack(spacing: 10) { Image(systemName: "globe").font(CM.font(26)); Text(layout.name).font(CM.font(26, .semibold)).lineLimit(1) }
                        .frame(width: 230, height: 76)
                        .background(CM.ivory.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .focusTarget("key:language", shape: .rect) {
                            layoutIndex = (layoutIndex + 1) % layouts.count; symbols = false
                            voice.language = layout.language
                        }
                }
                key(String(localized: "Shift"), hint: .leftTrigger, id: "key:shift", width: 170, on: shifted) { shifted.toggle() }
                key(String(localized: "Space"), hint: .y, id: "key:space", width: 360) { text += " " }
                key(String(localized: "Delete"), hint: .x, id: "key:delete", width: 190) { if !text.isEmpty { text.removeLast() } }
                symbolKey(voice.phase == .listening ? "mic.fill" : "mic", hint: .menu, id: "key:voice", on: voice.phase == .listening) { voice.toggle() }
                key(String(localized: "Done"), hint: .rightTrigger, id: "key:done", width: 180) {
                    if let first = results.first { focus.focus("g:search:\(first.id)") }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func key(_ label: String, hint: ControllerEvent? = nil, id: String, width: CGFloat, on: Bool = false, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(CM.font(30, .semibold))
            if let hint { Glyph(hint).frame(height: 30).opacity(0.7) }
        }
        .foregroundStyle(on ? CM.ground : CM.ivory)
        .frame(width: width, height: 76)
        .background(on ? CM.ivory : CM.ivory.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusTarget(id, shape: .rect, action: action)
    }

    private func symbolKey(_ symbol: String, hint: ControllerEvent, id: String, on: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(CM.font(30, .semibold))
            Glyph(hint).frame(height: 30).opacity(0.7)
        }
        .foregroundStyle(on ? CM.ground : CM.ivory)
        .frame(width: 170, height: 76)
        .background(on ? CM.ivory : CM.ivory.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .focusTarget(id, shape: .rect, action: action)
    }
}

// MARK: Settings

struct ControllerSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerFocus.self) private var focus

    private var settings: ControllerModeSettings { model.settings.controllerMode ?? ControllerModeSettings() }
    private func update(_ change: (inout ControllerModeSettings) -> Void) {
        var next = settings; change(&next); model.settings.controllerMode = next
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Controller Mode Settings").font(CM.font(44, .bold)).padding(.bottom, 20).padding(.horizontal, CM.margin)
            // More rows than fit at the larger sizes: the list scrolls to keep the focused one in view.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    rows.padding(.horizontal, CM.margin).padding(.vertical, 8)
                }
                .safeAreaPadding(.bottom, 110)                 // the hints bar lies over the bottom
                .onChange(of: focus.current) { _, id in
                    guard let id, id.hasPrefix("set:") else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: nil) }
                }
            }
        }
        .padding(.top, 130)
        .frame(width: CM.width, height: CM.height - 96, alignment: .topLeading)
        .onAppear { if focus.current == nil, focus.wanted == nil { focus.focus("set:size") } }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(String(localized: "Interface size"), String(localized: "How large everything is. Larger reads better from the couch."), value: sizeName, id: "set:size") {
                update { s in let all = ControllerModeSettings.Size.allCases; s.size = all[(all.firstIndex(of: s.size)! + 1) % all.count] }
            }
            row(String(localized: "Display"), String(localized: "Where Controller Mode opens."), value: settings.display ?? NSScreen.main?.localizedName ?? "", id: "set:display") {
                let names = NSScreen.screens.map(\.localizedName)
                update { s in let i = names.firstIndex(of: s.display ?? "") ?? 0; s.display = names[(i + 1) % max(1, names.count)] }
            }
            row(String(localized: "Background"), String(localized: "Behind search, settings and dialogs. Games keep their own art."),
                value: settings.background == .cool ? String(localized: "Cool") : String(localized: "Warm"), id: "set:background") {
                update { $0.background = $0.background == .cool ? .warm : .cool }
            }
            row(String(localized: "Open in Controller Mode when a controller connects"), String(localized: "Also when Sommelier starts with a controller already on."),
                value: settings.openWhenControllerConnects ? String(localized: "On") : String(localized: "Off"), id: "set:auto") { update { $0.openWhenControllerConnects.toggle() } }
            row(String(localized: "Button labels"), String(localized: "Automatic shows the buttons of the controller in your hands."), value: labelsName, id: "set:labels") {
                update { s in let all = ControllerModeSettings.Labels.allCases; s.labels = all[(all.firstIndex(of: s.labels)! + 1) % all.count] }
            }
            // The same as Settings › Controllers.
            row(String(localized: "PlayStation controllers as Xbox controllers"), String(localized: "Takes effect when the game’s store next starts."),
                value: model.playStationAsXbox ? String(localized: "On") : String(localized: "Off"), id: "set:psxbox") {
                model.settings.playStationAsXbox = !model.playStationAsXbox; model.applyControllerChoice()
            }
            row(String(localized: "PlayStation button prompts in games that have them"),
                String(localized: "While a PlayStation controller is connected, these games show its buttons instead of Xbox ones."),
                value: model.playStationPrompts ? String(localized: "On") : String(localized: "Off"), id: "set:psprompts") {
                model.settings.playStationPrompts = !model.playStationPrompts
            }
            row(String(localized: "PS / Xbox button"), guideName, value: "", id: "set:guide") {
                update { s in let all = ControllerModeSettings.GuideButton.allCases; s.guideButton = all[(all.firstIndex(of: s.guideButton)! + 1) % all.count] }
            }
            row(String(localized: "Sounds"), String(localized: "Soft clicks as you move around."), value: settings.sounds ? String(localized: "On") : String(localized: "Off"), id: "set:sounds") { update { $0.sounds.toggle() } }
            row(String(localized: "Keep the display awake"), String(localized: "While you browse. The Mac sleeps as usual after you leave Controller Mode."),
                value: settings.keepDisplayAwake ? String(localized: "On") : String(localized: "Off"), id: "set:awake") { update { $0.keepDisplayAwake.toggle() } }
            Text("Left and right change a value").font(CM.font(22)).foregroundStyle(CM.t3).padding(.top, 20)
        }
    }

    private var sizeName: String {
        switch settings.size { case .standard: String(localized: "Standard"); case .large: String(localized: "Large"); case .extraLarge: String(localized: "Extra Large") }
    }
    private var guideName: String {
        switch settings.guideButton {
        case .whileInFront: String(localized: "Opens Controller Mode while Sommelier is in front")
        case .anywhere: String(localized: "Opens Controller Mode from anywhere, even over a game")
        case .nothing: String(localized: "Does nothing")
        }
    }
    private var labelsName: String {
        switch settings.labels { case .automatic: String(localized: "Automatic"); case .xbox: "Xbox"; case .playStation: "PlayStation" }
    }

    private func row(_ title: String, _ detail: String, value: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CM.font(28, .semibold))
                Text(detail).font(CM.font(22)).foregroundStyle(CM.t3)
            }
            Spacer()
            Text(value).font(CM.font(28, .semibold)).foregroundStyle(CM.t2)
        }
        .padding(.horizontal, 26).padding(.vertical, 18).frame(width: 1200)
        .background(CM.ivory.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusTarget(id, shape: .row, action: action)
        .id(id)
    }
}

// MARK: Overlays

/// The Guide menu on the left.
struct GuideMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    @State private var input = ControllerInput.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CM.ground.opacity(0.55).contentShape(Rectangle()).onTapGesture { state.overlay = nil }
            VStack(alignment: .leading, spacing: 8) {
                Text("Sommelier").font(CM.font(36, .bold))
                Text("Controller Mode").font(CM.font(24)).foregroundStyle(CM.t3).padding(.bottom, 30)
                item(String(localized: "Home"), "house", id: "guide:home") { state.overlay = nil; state.stack.removeAll(); state.screen = .home }
                item(String(localized: "Search"), "magnifyingglass", id: "guide:search") { state.overlay = nil; state.go(.search) }
                item(String(localized: "Controller Mode Settings"), "slider.horizontal.3", id: "guide:settings") { state.overlay = nil; state.go(.settings) }
                item(String(localized: "Exit Controller Mode"), "rectangle.portrait.and.arrow.right", id: "guide:exit") { ControllerModeWindow.shared.exit() }
                Divider().overlay(CM.line).padding(.vertical, 10)
                item(String(localized: "Sleep"), "moon", id: "guide:sleep") { sleepMac() }
                item(String(localized: "Shut Down…"), "power", id: "guide:shutdown") { shutDown() }
                Spacer()
                HStack(spacing: 30) {
                    if input.connected {
                        HStack(spacing: 10) {
                            PadIcon(kind: input.kind).frame(width: 34, height: 34)
                            if let battery = input.battery { Text(String(localized: "Controller \(Int((battery * 100).rounded()))%")) }
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { Text($0.date.formatted(date: .omitted, time: .shortened)) }
                }
                .font(CM.font(24)).foregroundStyle(CM.t3)
            }
            .padding(60).frame(width: 640, height: CM.height, alignment: .topLeading)
            .background(CM.graphite.opacity(0.98))
        }
        .frame(width: CM.width, height: CM.height)
        .zIndex(5)
        .onAppear { focus.focus("guide:home") }
    }

    private func item(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 18) { Image(systemName: symbol).font(CM.font(26)).frame(width: 36); Text(title).font(CM.font(29, .semibold)) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 16)
            .background(CM.ivory.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .focusTarget(id, layer: "overlay", shape: .row, action: action)
    }

    private func sleepMac() {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        script?.executeAndReturnError(nil)
    }

    private func shutDown() {
        // macOS asks its own question before shutting down.
        let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
        script?.executeAndReturnError(nil)
    }
}

/// A box in the middle of the screen.
struct CenterBox<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            CM.ground.opacity(0.7)
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(48).frame(width: 900, alignment: .leading)
                .background(CM.graphite, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(CM.line, lineWidth: 2))
        }
        .frame(width: CM.width, height: CM.height)
        .zIndex(5)
    }
}

struct NoControllerOverlay: View {
    @Environment(ControllerFocus.self) private var focus
    var body: some View {
        CenterBox {
            HStack(spacing: 20) {
                PadIcon(kind: ControllerInput.shared.kind, disconnected: true).frame(width: 64, height: 64)
                Text("Controller disconnected").font(CM.font(40, .bold))
            }
            Text("Turn it back on or plug it in, and carry on where you were. The keyboard works too: arrows to move, Return to select, Esc to go back.")
                .font(CM.font(25)).foregroundStyle(CM.t2).fixedSize(horizontal: false, vertical: true)
            Text("Exit Controller Mode").font(CM.font(27, .semibold)).padding(.horizontal, 30).padding(.vertical, 12)
                .background(CM.ivory.opacity(0.1), in: Capsule())
                .focusTarget("nopad:exit", layer: "overlay", shape: .pill) { ControllerModeWindow.shared.exit() }
        }
        .onAppear { focus.focus("nopad:exit") }
    }
}

struct LaunchingOverlay: View {
    let game: Game
    var body: some View {
        CenterBox {
            HStack(spacing: 24) {
                GrapeMark(filled: 6, leaf: true).frame(width: 44, height: 44)
                Text(String(localized: "Starting \(game.title)…")).font(CM.font(36, .bold))
            }
            Text("The game opens on this display").font(CM.font(24)).foregroundStyle(CM.t3)
        }
    }
}

struct RunningOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    let game: Game

    private var minutes: Int {
        if case .playing(let since) = model.state(of: game) { return Int(Date().timeIntervalSince(since) / 60) }
        return 0
    }

    var body: some View {
        CenterBox {
            Text(game.title).font(CM.font(40, .bold))
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(String(localized: "Playing now, for \(minutes) min")).font(CM.font(26)).foregroundStyle(CM.t2)
            }
            HStack(spacing: 16) {
                Text("Return to Game").font(CM.font(27, .semibold)).foregroundStyle(CM.ground).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.ivory, in: Capsule())
                    .focusTarget("run:return", layer: "overlay", shape: .pill) {
                        if let pid = AppModel.runningProcess(of: game, enginesFolder: model.paths.engines.path) { model.giveFocus(to: pid) }
                    }
                Text("Close Game…").font(CM.font(27, .semibold)).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.ivory.opacity(0.1), in: Capsule())
                    .focusTarget("run:close", layer: "overlay", shape: .pill) { state.overlay = .closeAsk(game) }
            }
            Text("You’re in Sommelier while the game keeps running. When you quit the game, you come back here, to this page.")
                .font(CM.font(23)).foregroundStyle(CM.t3).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { focus.focus("run:return") }
    }
}

struct CloseAskOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus
    let game: Game

    var body: some View {
        CenterBox {
            Text(String(localized: "Close \(game.title)?")).font(CM.font(40, .bold))
            Text("Progress since your last save in the game will be lost.").font(CM.font(25)).foregroundStyle(CM.t2)
            HStack(spacing: 16) {
                Text("Close Game").font(CM.font(27, .semibold)).foregroundStyle(CM.ground).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.wineHi, in: Capsule())
                    .focusTarget("ask:close", layer: "overlay", shape: .pill) { model.closeGame(game); state.overlay = .running(game) }
                Text("Cancel").font(CM.font(27, .semibold)).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.ivory.opacity(0.1), in: Capsule())
                    .focusTarget("ask:cancel", layer: "overlay", shape: .pill) { state.overlay = .running(game) }
            }
        }
        .onAppear { focus.focus("ask:cancel") }
    }
}

/// "Exit Controller Mode?": only for B on Home, where it is easy to press by accident.
struct ExitAskOverlay: View {
    @Environment(ControllerModeState.self) private var state
    @Environment(ControllerFocus.self) private var focus

    var body: some View {
        CenterBox {
            Text("Exit Controller Mode?").font(CM.font(40, .bold))
            Text("Sommelier stays open as a normal window on this Mac.").font(CM.font(25)).foregroundStyle(CM.t2)
            HStack(spacing: 16) {
                Text("Cancel").font(CM.font(27, .semibold)).foregroundStyle(CM.ground).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.ivory, in: Capsule())
                    .focusTarget("exit:cancel", layer: "overlay", shape: .pill) { state.overlay = nil }
                Text("Exit").font(CM.font(27, .semibold)).padding(.horizontal, 30).padding(.vertical, 12)
                    .background(CM.ivory.opacity(0.1), in: Capsule())
                    .focusTarget("exit:yes", layer: "overlay", shape: .pill) { ControllerModeWindow.shared.exit() }
            }
        }
        .onAppear { focus.focus("exit:cancel") }
    }
}
