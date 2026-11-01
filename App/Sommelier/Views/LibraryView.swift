// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// The library: a grid of covers or a list of rows, split into what's ready and what isn't. Chips filter it by
/// compatibility (and by store on All Games); the order and the layout sit beside them.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let item: SidebarItem

    enum Layout: String, CaseIterable {
        case grid, list
        var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
        var label: String { self == .grid ? String(localized: "Grid") : String(localized: "List") }
    }
    enum Size: String, CaseIterable {
        case small, medium, large
        var width: CGFloat { switch self { case .small: 110; case .medium: 140; case .large: 180 } }
        var label: String {
            switch self { case .small: String(localized: "Small"); case .medium: String(localized: "Medium"); case .large: String(localized: "Large") }
        }
    }
    enum Sort: String, CaseIterable {
        case recent = "Recent", title = "Title", size = "Size", rating = "Metacritic"
        var label: String {
            switch self {
            case .recent: String(localized: "Recent")
            case .title: String(localized: "A to Z")
            case .size: String(localized: "Size")
            case .rating: String(localized: "Metacritic")
            }
        }
    }

    @AppStorage("libraryLayout") private var layout: Layout = .grid
    @AppStorage("librarySize") private var size: Size = .medium
    @AppStorage("librarySortV2") private var sort: Sort = .recent
    /// Only games with this answer; nil shows all.
    @State private var status: Compatibility.Verdict?
    /// On All Games: only games in these stores; empty shows all.
    @State private var stores: Set<StoreKind> = []
    @State private var listWidth: CGFloat = 900

    /// The store this page is about, when it's a store's page.
    private var storeKind: StoreKind? { if case .store(let kind) = item { kind } else { nil } }

    var body: some View {
        let base = model.games(for: item).filter(matches)
        let games = sorted(base.filter { status == nil || model.compatibility(of: $0).verdict == status }
            .filter { stores.isEmpty || model.copies(of: $0).contains { stores.contains($0.store) } })
        // Ready and not installed apart only in the plain view; a filter or another order shows one grid.
        let split = sort == .recent && status == nil && stores.isEmpty
        let ready = games.filter(\.isInstalled)
        let notInstalled = games.filter { !$0.isInstalled }

        let store = storeKind
        if let poster = model.signedOutStore, poster == store, model.search.isEmpty {
            // Not signed in to this store: its poster, art behind the whole window (`StorePosterBackdrop`).
            // In a scroll view like every other page: a page without one let the sidebar's list slip up under the
            // window's title bar.
            GeometryReader { geo in
                ScrollView { SignedOutStore(kind: poster).frame(width: geo.size.width, height: geo.size.height) }
                    .scrollDisabled(true)
            }
                .ignoresSafeArea(edges: .top)
                .navigationTitle(title)
                .toolbar(removing: .title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
        GeometryReader { geo in
            let heroHeight = min(max(geo.size.width * 0.3, 220), 300)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let store {
                        StoreHeader(kind: store, games: model.games(for: item), width: geo.size.width, height: heroHeight)
                            .environment(\.colorScheme, .dark)          // the store's colours, white on them, in both
                    } else {
                        header(base).padding(.horizontal, Theme.Space.margin).padding(.top, 60)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.section) {
                        if base.isEmpty {
                            empty
                        } else {
                            tools(base)
                            if games.isEmpty { noMatches }
                            else if !split { section(nil, games) }
                            else {
                                if !ready.isEmpty { section("Ready to Play", ready) }
                                if !notInstalled.isEmpty { section("Not Installed", notInstalled) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.margin)
                    .padding(.top, Theme.Space.m)
                    .padding(.bottom, Theme.Space.l)
                }
            }
            .background {
                if let store { Theme.tintedBackground(store.brandColors.bottom, heroHeight: heroHeight) }
                else { Theme.surface.ignoresSafeArea() }
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle(title)
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onChange(of: item) { status = nil; stores = [] }
        .onAppear { model.tint = store?.brandColors.bottom }
        .onChange(of: store) { model.tint = store?.brandColors.bottom }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh the library (⌘R)")
                if let store = directStore {
                    // No launcher to open: games download without it. The store itself is a web page.
                    if model.storeActivity[store] != nil { LoadingGrape() }
                    Button { model.openStoreWebsite(store) } label: { Label("Open \(store.displayName)", systemImage: "safari") }
                        .help("Opens the \(store.displayName) store in your browser")
                } else if let store = launcherStore {
                    if model.storeActivity[store] != nil { LoadingGrape() }
                    Button { Task { await model.openLauncher(store) } } label: { Label("Open \(store.displayName)", systemImage: "macwindow") }
                        .help(model.isLauncherInstalled(store) ? String(localized: "Open \(store.displayName)") : String(localized: "Sets up \(store.displayName) first"))
                        .disabled(model.storeActivity[store] != nil)
                } else if model.steamLaunch != .idle {
                    LoadingGrape().help("Opening Steam…")
                } else if model.running["steam"] == nil {   // a running Steam is quit from File → Quit Steam
                    Button { Task { await model.openSteam() } } label: { Label("Open Steam", systemImage: "macwindow") }.help("Open Steam")
                }
            }
        }
        }
    }

    // MARK: Header and tools

    /// The page's name and what's in it: "211 games · 8 installed · 113 GB on disk · 15 with a Mac version".
    private func header(_ games: [Game]) -> some View {
        let installed = games.filter(\.isInstalled)
        let disk = installed.compactMap(\.sizeOnDisk).reduce(0, +)
        let mac = games.filter { model.hasMacVersion($0) }.count
        var parts = [AttributedString(localized: "**\(games.count)** games"), AttributedString(localized: "**\(installed.count)** installed")]
        if disk > 0 { parts.append(AttributedString(localized: "**\(disk.fileSize)** on disk")) }
        if mac > 0, item != .macVersions { parts.append(AttributedString(localized: "**\(mac)** with a Mac version")) }
        var line = AttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 { line += AttributedString(" · ") }
            line += part
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(model.search.isEmpty ? title : String(localized: "Found"))
                .font(.system(size: 26, weight: .bold)).tracking(-0.4).foregroundStyle(Theme.onDark)
            if !games.isEmpty {
                Text(line).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.onDarkSecondary)
            }
        }
    }

    /// Status chips, store filters on All Games, the order, and grid or list.
    private func tools(_ games: [Game]) -> some View {
        let showStores = item == .allGames && model.storesInUse.count > 1
        return HStack(spacing: 5) {
            // Everything when it fits; else the store buttons fold into one menu; else the chips scroll sideways
            // (fading at the edge). The order and layout controls stay put.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { statusChips(games); if showStores { storeDivider; storeButtons } }
                HStack(spacing: 5) { statusChips(games); if showStores { storeDivider; storeMenu() } }
                HStack(spacing: 5) { statusChips(games); if showStores { storeDivider; storeMenu(compact: true) } }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) { statusChips(games); if showStores { storeDivider; storeMenu(compact: true) } }
                        .padding(.trailing, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .mask {   // fades out at the right edge instead of cutting a chip in half
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                if layout == .grid {
                    Picker("Cover size", selection: $size) {
                        ForEach(Size.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                // Where the store filters take the room, just the icon (the order is in the tooltip).
                let compact = item == .allGames
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
                    if !compact { Text(sort.label) }
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onDarkSecondary)
                .padding(.horizontal, compact ? 0 : 10).frame(minWidth: 28).frame(height: 28)
                .background(Theme.fill(0.07), in: Capsule())
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(String(localized: "Sort: \(sort.label)"))
            HStack(spacing: 0) {
                ForEach(Layout.allCases, id: \.self) { option in
                    Button { layout = option } label: {
                        Image(systemName: option.symbol).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(layout == option ? Theme.onDark : Theme.onDarkSecondary)
                            .frame(width: 28, height: 24)
                            .background(Theme.fill(layout == option ? 0.18 : 0), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(option.label)
                    .accessibilityLabel(option.label)
                    .accessibilityAddTraits(layout == option ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Theme.fill(0.07), in: Capsule())
        }
    }

    private func statusChips(_ games: [Game]) -> some View {
        HStack(spacing: 4) {
            FilterChip(selected: status == nil, action: { status = nil }) {
                Text("All"); Text("\(games.count)").fontWeight(.medium).opacity(0.6)
            }
            ForEach(Compatibility.Verdict.allCases, id: \.self) { verdict in
                let count = games.filter { model.compatibility(of: $0).verdict == verdict }.count
                if count > 0 {
                    FilterChip(selected: status == verdict, action: { status = status == verdict ? nil : verdict }) {
                        verdict.mark.frame(width: 12, height: 12)
                            .foregroundStyle(status == verdict ? Theme.ink : verdict.color)
                        Text(verdict.localizedTitle); Text("\(count)").fontWeight(.medium).opacity(0.6)
                    }
                }
            }
        }
    }

    private var storeDivider: some View {
        Divider().frame(height: 18).overlay(Theme.line(0.12)).padding(.horizontal, 2)
    }

    private var storeButtons: some View {
        HStack(spacing: 3) {
            ForEach(model.storesInUse, id: \.self) { kind in
                let on = stores.contains(kind)
                Button { toggleStore(kind) } label: {
                    kind.logo.resizable().scaledToFit().frame(width: 13, height: 13)
                        .foregroundStyle(on ? Theme.onDark : Theme.onDarkSecondary)
                        .frame(width: 25, height: 25)
                        .background(Theme.fill(on ? 0.18 : 0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(kind.displayName)
                .accessibilityLabel(kind.displayName)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// The store filters in one button, for when the five don't fit: a tick per chosen store. Compact, just the
    /// icon (and how many are chosen).
    private func storeMenu(compact: Bool = false) -> some View {
        Menu {
            ForEach(model.storesInUse, id: \.self) { kind in
                Button { toggleStore(kind) } label: {
                    if stores.contains(kind) { Label(kind.displayName, systemImage: "checkmark") } else { Text(kind.displayName) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if stores.count == 1, let only = stores.first {
                    only.logo.resizable().scaledToFit().frame(width: 13, height: 13)
                } else {
                    Image(systemName: "bag").font(.system(size: 11, weight: .semibold))
                }
                if !stores.isEmpty { Text("\(stores.count)") } else if !compact { Text("Stores") }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(stores.isEmpty ? Theme.onDarkSecondary : Theme.onDark)
            .padding(.horizontal, 9).frame(height: 28)
            .background(Theme.fill(stores.isEmpty ? 0.07 : 0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Stores")
    }

    private func toggleStore(_ kind: StoreKind) {
        if stores.contains(kind) { stores.remove(kind) } else { stores.insert(kind) }
    }

    /// When the filters leave nothing: say so, and offer to clear them.
    private var noMatches: some View {
        VStack(spacing: 10) {
            Text("Nothing matches these filters.").foregroundStyle(Theme.onDarkSecondary)
            Button("Reset Filters") { status = nil; stores = [] }.buttonStyle(.textLink).fontWeight(.semibold)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity)
        .padding(22)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.line(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
    }

    // MARK: Sections

    @ViewBuilder private func section(_ name: LocalizedStringKey?, _ games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let name { SectionHeader(title: name, count: games.count) }
            switch layout {
            case .grid:
                LazyVGrid(columns: [GridItem(.adaptive(minimum: size.width, maximum: size.width + 30),
                                             spacing: Theme.Space.m + 4, alignment: .top)],
                          alignment: .leading, spacing: Theme.Space.l) {
                    ForEach(games) { GameCard(game: $0) }
                }
                .padding(.horizontal, Theme.Space.s).padding(.top, Theme.Space.s)   // room for the hover lift
            case .list:
                LazyVStack(spacing: 0) {
                    GameRowHeader(statusWidth: GameRow.statusWidth(in: listWidth))
                    ForEach(games) { GameRow(game: $0, statusWidth: GameRow.statusWidth(in: listWidth)) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            }
        }
    }

    /// Epic or GOG, when this page shows one of them.
    private var directStore: StoreKind? {
        if case .store(let kind) = item, AppModel.directStores.contains(kind) { return kind }
        return nil
    }

    /// EA app, Ubisoft Connect or Battle.net, when this page shows one of them.
    private var launcherStore: StoreKind? {
        if case .store(let kind) = item, AppModel.launcherStores.contains(kind) { return kind }
        return nil
    }

    private func refresh() async {
        if let directStore { await model.refreshStore(directStore); return }
        if let launcherStore { await model.refreshLauncher(launcherStore); return }
        if item != .store(.steam) { for kind in AppModel.directStores { Task { await model.refreshStore(kind) } } }
        await model.refreshLibrary()
    }

    @ViewBuilder private var empty: some View {
        if model.search.isEmpty, let store = storeKind, model.accountsChecked, !model.storesWithAccount.contains(store) {
            SignedOutStore(kind: store)
        } else if model.search.isEmpty, model.signedOutEverywhere, item == .allGames {
            SignedOutLibrary(title: "All your games will be here",
                             text: "Sign in to a store: games from every store you connect come together in one list.")
        } else if model.search.isEmpty, model.accountsChecked, item == .installed {
            // Nothing installed, signed in or not: the same page, the signed-in stores with a way to their games.
            SignedOutLibrary(title: "No installed games yet",
                             text: model.signedOutEverywhere
                                 ? "Sign in to a store and install a game. It shows up here, and Sommelier says how it will run on this Mac."
                                 : "Pick one from your library. Sommelier says which ones will run well.")
        } else if let store = directStore, model.search.isEmpty { emptyStore(store) }
        else if let store = launcherStore, model.search.isEmpty { emptyLauncher(store) }
        else { emptySteam }
    }

    private func emptyLauncher(_ store: StoreKind) -> some View {
        ContentUnavailableView {
            Label { Text(model.isLauncherInstalled(store) ? String(localized: "No games yet") : String(localized: "Set Up \(store.displayName)")) }
                icon: { store.logo.resizable().scaledToFit().frame(width: 40, height: 40) }
        } description: {
            Text(model.isLauncherInstalled(store)
                 ? String(localized: "Open \(store.displayName), sign in and install a game there. It appears here by itself.")
                 : String(localized: "\(store.displayName) runs in its own environment, like Steam. Sommelier downloads its official installer and sets it up; you sign in inside it."))
        } actions: {
            if let activity = model.storeActivity[store] {
                HStack(spacing: 6) { LoadingGrape(); Text(activity) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func emptyStore(_ store: StoreKind) -> some View {
        ContentUnavailableView {
            Label { Text(model.isSignedIn(store) ? String(localized: "No games yet") : String(localized: "Sign In to \(store.displayName)")) }
                icon: { store.logo.resizable().scaledToFit().frame(width: 40, height: 40) }
        } description: {
            Text(model.isSignedIn(store)
                 ? String(localized: "Games you own on \(store.displayName) appear here.")
                 : String(localized: "Your \(store.displayName) games appear here. They download straight to this Mac, no launcher needed."))
        } actions: {
            if let activity = model.storeActivity[store] {
                HStack(spacing: 6) { LoadingGrape(); Text(activity) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var emptySteam: some View {
        ContentUnavailableView {
            Label(model.search.isEmpty ? String(localized: "No games yet") : String(localized: "No matches"), systemImage: "gamecontroller")
        } description: {
            Text(model.search.isEmpty
                 ? String(localized: "Open Steam, sign in and install a game. It appears here by itself after a refresh.")
                 : String(localized: "Nothing matches “\(model.search)”."))
        } actions: {
            if model.search.isEmpty {
                Button { Task { await model.openSteam() } } label: { OpenSteamLabel() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.steamLaunch != .idle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func matches(_ game: Game) -> Bool {
        model.search.isEmpty || game.title.localizedCaseInsensitiveContains(model.search)
    }

    private func sorted(_ games: [Game]) -> [Game] {
        switch sort {
        case .title: games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent: games.sorted { (model.lastPlayed($0) ?? .distantPast) > (model.lastPlayed($1) ?? .distantPast) }
        case .size: games.sorted { ($0.sizeOnDisk ?? 0) > ($1.sizeOnDisk ?? 0) }
        case .rating: games.sorted { (model.info[$0.id]?.metacritic ?? -1) > (model.info[$1.id]?.metacritic ?? -1) }
        }
    }
}

/// One game as a list row, the way Apple Games' Library shows them: art, name, when it was played, Play.
/// One game in the list view, in columns: cover, name, compatibility, stores, size, play time, and an action.
struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var statusWidth: CGFloat = 140
    @State private var hovering = false

    /// Column widths, shared with the header row.
    enum Column {
        static let stores: CGFloat = 74, size: CGFloat = 70, played: CGFloat = 84, action: CGFloat = 96
    }

    /// Name and compatibility share what the fixed columns leave, 1.7 to 1.3.
    static func statusWidth(in listWidth: CGFloat) -> CGFloat {
        let fixed = 34 + Column.stores + Column.size + Column.played + Column.action + 12 * 6 + Theme.Space.s * 2
        return max(150, (listWidth - fixed) * 1.3 / 3)   // room for "Should work" with its mark in any language
    }

    var body: some View {
        let rating = model.compatibility(of: game)
        HStack(spacing: 12) {
            Artwork(url: model.coverURL(for: game), title: game.title, titleOnPlaceholder: false, fallback: model.headerURL(for: game))
                .frame(width: 34, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(game.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.onDarkTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                rating.verdict.mark.frame(width: 12, height: 12).foregroundStyle(rating.verdict.color)
                Text(([rating.verdict.localizedTitle] + (rating.notes.contains(.noOnline) ? [Compatibility.Note.noOnline.localizedTitle] : []))
                    .joined(separator: " · "))
                    .foregroundStyle(rating.verdict == .wontRun ? Theme.wineLight : Theme.onDarkSecondary)
                    .lineLimit(1)
            }
            .font(.system(size: 12))
            .frame(width: statusWidth, alignment: .leading)
            .help(rating.summary)
            HStack(spacing: 6) {
                ForEach(model.copies(of: game), id: \.id) { copy in
                    copy.store.logo.resizable().scaledToFit().frame(width: 14, height: 14)
                }
            }
            .foregroundStyle(Theme.onDarkTertiary)
            .frame(width: Column.stores, alignment: .leading)
            .help(model.storeNames(of: game))
            Group {
                Text(game.knownSize ?? "—").frame(width: Column.size, alignment: .leading)
                Text(model.playTime(game) > 0 ? model.playTime(game).playTime : "—").frame(width: Column.played, alignment: .leading)
            }
            .font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.onDarkSecondary).lineLimit(1)
            action.frame(width: Column.action, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, 7)
        .background(Theme.fill(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.open(game) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open page") { model.open(game) }
    }

    @ViewBuilder private var action: some View {
        if model.state(of: game) != nil {
            HStack(spacing: 5) { GrapeMark(filled: 6).frame(width: 11, height: 11); Text("In game") }
                .font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Theme.wine, in: Capsule())
        } else if let install = model.installState(of: game) {
            if let fraction = install.fraction {
                Text("\(Int(fraction * 100))%").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.onDarkSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if game.isInstalled {
            Button { Task { await model.play(game) } } label: { Label("Play", systemImage: "play.fill").labelStyle(PillLabelStyle()) }
                .buttonStyle(QuickPlayButtonStyle())
                .accessibilityLabel("Play \(game.title)")
        } else if model.compatibility(of: game).verdict == .wontRun {
            if let score = model.info[game.id]?.metacritic { MetacriticBadge(score: score, compact: true) }
        } else {
            Button { Task { await model.install(game) } } label: { Label("Install", systemImage: "arrow.down").labelStyle(PillLabelStyle()) }
                .buttonStyle(QuickPlayButtonStyle(ghost: true))
                .accessibilityLabel("Install \(game.title)")
        }
    }

    /// "Studio · 2016", when the store page has been read.
    private var subtitle: String {
        let info = model.info[game.id]
        return [info?.developers.first, info?.year].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The list's column names, lined up with GameRow.
struct GameRowHeader: View {
    var statusWidth: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 34, height: 1)
            Text("Game").frame(maxWidth: .infinity, alignment: .leading)
            Text("Compatibility").frame(width: statusWidth, alignment: .leading)
            Text("Stores").frame(width: GameRow.Column.stores, alignment: .leading)
            Text("Size").frame(width: GameRow.Column.size, alignment: .leading)
            Text("Played").frame(width: GameRow.Column.played, alignment: .leading)
            Color.clear.frame(width: GameRow.Column.action, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold)).tracking(0.7).textCase(.uppercase)
        .foregroundStyle(Theme.onDarkTertiary).lineLimit(1)
        .padding(.horizontal, Theme.Space.s).padding(.top, 2).padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.fill(0.08)).frame(height: 1) }
        .accessibilityHidden(true)
    }
}

/// A Metacritic score in its colours: green from 75, yellow below.
struct MetacriticBadge: View {
    let score: Int
    var compact = false

    var body: some View {
        Text("\(score)")
            .font(.system(size: compact ? 11 : 12.5, weight: .heavy)).monospacedDigit()
            .foregroundStyle(Theme.ink)
            .frame(minWidth: compact ? 24 : 26).frame(height: compact ? 20 : 22).padding(.horizontal, compact ? 4 : 0)
            .background(score >= 75 ? Color(red: 0x66 / 255, green: 0xcc / 255, blue: 0x33 / 255)
                                    : Color(red: 1, green: 0xcc / 255, blue: 0x33 / 255),
                        in: RoundedRectangle(cornerRadius: compact ? 4 : 5, style: .continuous))
            .accessibilityLabel(String(localized: "Metacritic \(score)"))
    }
}

/// A rounded filter chip: light when off, cream with dark text when on.
struct FilterChip<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) { label() }
                .lineLimit(1).fixedSize()
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(selected ? Theme.ink : Theme.onDarkSecondary)
                .padding(.horizontal, 8).frame(height: 28)
                .background(selected ? AnyShapeStyle(Theme.cream) : AnyShapeStyle(Theme.fill(0.07)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
