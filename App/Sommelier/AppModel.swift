// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import Network
import Observation
import os
import SwiftUI

/// Everything the windows show, and every action they can take. All work on SommelierKit happens here.
@MainActor @Observable
final class AppModel {
    let paths: Paths
    let artwork: ArtworkStore
    private let settingsStore: JSONStore<AppSettings>
    let libraryStore: LibraryStore
    private let infoService: GameInfoService

    /// Store details per game id (summary, developer, screenshots), from Steam's public store API.
    private(set) var info: [String: GameInfo] = [:] { didSet { copiesCache = nil } }
    /// What the window shows. `tint` colours the sidebar to match the game on screen.
    var selection: SidebarItem? = .home
    /// The game the Clips page shows clips of (`nil`: all).
    var clipsGame: String?
    var path = NavigationPath()
    var tint: Color?
    var search = ""

    var settings: AppSettings { didSet { try? settingsStore.save(settings) } }
    var library: LibraryFile { didSet { copiesCache = nil } }
    private(set) var engines: [Engine] = []
    private(set) var system: SystemReport?

    /// A long task in progress (installing an engine or Steam), shown with a progress bar.
    var activity: String?
    private(set) var progress: Double?
    var errorMessage: String?

    /// Wine processes we started, by game id ("steam" for the Steam window).
    var running: [String: RunningProcess] = [:]
    var lastLog: [String: URL] = [:]

    // Epic Games and GOG (AppModel+Stores.swift).
    /// The store whose sign-in page is open.
    var signIn: StoreKind?
    /// What a store is busy with (setting up, signing in, reading the library), for its card and page.
    var storeActivity: [StoreKind: String] = [:]
    /// Epic and GOG downloads, which Sommelier runs itself, by game id.
    var directInstalls: [String: DirectInstall] = [:] { didSet { noteInstalling() } }
    /// The one-time sharing question was answered in this run (keeps a debug-forced question from coming back).
    var sharingConsentShown = false
    /// Rules from the fixes list online (`FixesService`), refreshed daily; they come before the built-in ones.
    var remoteFixes: [FixRule] = []
    /// Messages from the Sommelier team (AppModel+Announcements.swift).
    var announcements: [Announcement] = []
    var fixRules: [FixRule] { FixRules.merged(remote: remoteFixes) }
    /// How games are known to start (the recipes list online), by game id; applied before a first launch (AppModel+Fixes).
    var recipes: [String: Recipe] = [:]
    /// The mods list online (`ModsService`): which games take mods and how (AppModel+Mods).
    var modsList: ModsList?
    /// Each game's mods as last read from its store and the game (AppModel+Mods `reloadMods`), by game id.
    var modsByGame: [String: GameMods] = [:]
    /// The game the Mods page shows.
    var modsGame: String?
    /// The mods flow's sheets: the code sheet before a mod goes in, a plan's question, other tools' files found
    /// before a plain launch; and the short note on the mods page after a change.
    var modConsent: ModConsent?
    var modQuestion: ModQuestion?
    var modLeftovers: ModLeftovers?
    var modNotice: ModNotice?
    /// The Mods page's tab; a loader's page open in the Nexus tab, waiting for its archive; an archive that
    /// landed in Downloads after the game's page was opened in the player's own browser (AppModel+Mods).
    var modsTab: ModsTab = .installed
    var modBrowser: ModBrowserFetch?
    /// The Nexus browsers, one per game, kept so the page and a download in progress outlive a change of tab.
    @ObservationIgnored var nexusBrowsers: [String: NexusBrowser] = [:]
    /// A loader's command for a launch that goes through it instead of the game (`guardMods`), by game id.
    @ObservationIgnored var modLoader: [String: LaunchGuard.LoaderCommand] = [:]
    /// Downloads a store's own launcher is running (the EA app), keyed by game id; Sommelier only follows them.
    var launcherDownloads: [String: LauncherDownload] = [:] { didSet { noteInstalling() } }
    /// Games whose Install was clicked and handed to their launcher, with when: they show "Confirm in …" until
    /// the launcher's download shows up (or a quarter of an hour passes).
    var launcherInstallRequests: [String: Date] = [:] { didSet { noteInstalling() } }
    /// Whether each game's last launch had Turbo on (AppModel+Turbo), for the "didn't start" sheet's retries.
    var lastLaunchTurbo: [String: Bool] = [:]
    /// The graphics backend each game last ran with (Automatic resolved), for the fix rules and reports.
    var lastLaunchBackend: [String: GraphicsBackend] = [:]
    /// Every environment's Windows user folders become its own (`Bottle.isolateUserFolders`), except one running now.
    func isolateUserFolders() async {
        let runner = WineRunner(paths: paths)
        for kind in BottleKind.allCases {
            let bottle = Bottle(kind: kind, paths: paths)
            guard bottle.exists, let engine = engine(for: kind) else { continue }
            if await runner.isBottleActive(engine: engine, bottle: bottle) { continue }
            await Task.detached { bottle.isolateUserFolders() }.value
        }
    }

    /// After a session on DXMT: whether the game asked about HDR (its counter says), so the HDR switch is offered
    /// only for games that have HDR.
    func noteHDR(after game: Game, since: Date) {
        guard library.userData[game.id]?.knowsHDR != true else { return }
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths), folder = game.installPath
        Task {
            let knows = await Task.detached { FrameStats.samples(in: bottle, since: since, gameFolder: folder).contains { $0.hdr != 0 } }.value
            guard knows else { return }
            var data = library.userData[game.id] ?? UserGameData()
            data.knowsHDR = true
            library.userData[game.id] = data
            libraryStore.save(library)
        }
    }

    /// The games that have HDR, from players' sessions (the service's list), by id ("steam:292030").
    var hdrGames: Set<String> = []

    /// The game has HDR: it asked for it here, or players' sessions say so (for a copy from another store, by its
    /// Steam id).
    func knowsHDR(_ game: Game) -> Bool {
        if library.userData[game.id]?.knowsHDR == true || hdrGames.contains(game.id) { return true }
        return info[game.id]?.steamAppID.map { hdrGames.contains("steam:\($0)") } ?? false
    }

    /// What each game's files say (AppModel+Fixes `loadFacts`), and its graphics probe, for the "Fix Launch" menu.
    var gameFacts: [String: GameFacts] = [:]
    var gameProbes: [String: GraphicsProbe] = [:]
    /// The fixes each game's last failure pointed at, marked "recommended" in that menu.
    var lastFailureActions: [String: [FixAction]] = [:]

    /// Retina mode written into each environment's registry during this run (AppModel+Tuning `applyRetina`).
    var retinaWritten: [String: Bool] = [:]
    /// Steam's console log length when each launch began, to read only that launch's steps.
    var consoleStart: [String: UInt64] = [:]
    /// A launch Steam got stuck on before starting the game: the "start again" question.
    var stuckLaunch: Game?

    /// Starts a stuck launch again: Steam is stopped (killed when it doesn't answer) and the game launched anew.
    func restartStuckLaunch(_ game: Game) async {
        stuckLaunch = nil
        guard let engine = engine(for: game.store.bottleKind) else { return }
        gameStates[game.id] = .starting(since: Date())          // the Play button shows the launch while Steam restarts
        await sampleStuckSteam()
        await stopSteam(engine: engine)
        gameStates[game.id] = nil
        await play(game)
    }

    /// Before a stuck Steam is stopped: where its threads are waiting, from macOS's `sample` (a few seconds, no
    /// permission needed for one's own processes), saved next to Steam's launch logs for the next look at why.
    func sampleStuckSteam() async {
        let engines = paths.engines.path
        let folder = paths.logs.appendingPathComponent("steam")
        await Task.detached {
            guard let pid = WineWindows.programs(enginesFolder: engines)
                .first(where: { $0.commandLine.lowercased().contains(#"\steam\steam.exe"#) })?.pid else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let file = folder.appendingPathComponent("stuck-\(stamp).txt")
            _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/sample"), ["\(pid)", "3", "-mayDie", "-file", file.path])
        }.value
    }

    /// Where each launch's output goes and how long that log was when the launch began (AppModel+Fixes `logMark`).
    var launchLogMarks: [String: (url: URL?, size: UInt64)] = [:]
    /// A launch held for the one-time note about matching graphics to the Mac (AppModel+Tuning).
    var tuningNotice: Game?
    /// "What's wrong with …?" (`DisputeSheet`), and the confirmation the game page shows for a few seconds after.
    var disputeTarget: Game?
    var disputeNotice: DisputeNotice?
    /// Of those, the ones whose launcher hasn't shown its install window yet.
    var launcherInstallOpening: Set<String> = []
    /// Ubisoft downloads: the last progress seen and when it last moved, to tell a paused download (or one that
    /// lost its connection) from a running one. Ubisoft Connect writes nothing that says "paused".
    @ObservationIgnored var launcherProgressSeen: [String: (fraction: Double, moved: Date)] = [:]
    @ObservationIgnored var launcherDownloadTicker: Task<Void, Never>?
    @ObservationIgnored var directTasks: [String: Task<Void, Never>] = [:]
    /// Direct downloads being paused: their task is cancelled, but what they downloaded stays.
    @ObservationIgnored var directPausing: Set<String> = []
    /// What each direct download's games folder held before its current run started.
    @ObservationIgnored var directBaselines: [String: Set<String>] = [:]
    /// What a paused download wrote to its store's games folder (names in that folder), so cancelling it later
    /// deletes that and nothing another install added meanwhile.
    @ObservationIgnored var directOwned: [String: Set<String>] = [:]
    /// The last install queued per store: the next one waits for it, so one store downloads one game at a time.
    @ObservationIgnored var installQueues: [StoreKind: Task<Void, Never>] = [:]
    /// An Epic or GOG game waiting for the user to confirm its uninstall (Steam asks in its own window).
    var pendingUninstall: Game?
    /// Fetches store details for a whole Epic or GOG library in the background (ratings need them).
    @ObservationIgnored var infoPrefetch: Task<Void, Never>?

    init() {
        let paths = Paths()
        self.paths = paths
        artwork = ArtworkStore(directory: paths.artwork)
        infoService = GameInfoService(paths: paths)
        settingsStore = JSONStore(url: paths.settingsFile)
        libraryStore = LibraryStore(paths: paths)
        settings = settingsStore.load(default: AppSettings())
        library = libraryStore.load()
        collections = CollectionStore(paths: paths).load()
    }

    // MARK: State

    var steam: SteamProvider { SteamProvider(paths: paths) }
    var isSteamInstalled: Bool { steam.isSteamInstalled }
    var isBusy: Bool { activity != nil }
    /// A quiet engine update is downloading (`updateEngineQuietly`).
    var engineUpdating = false
    /// Sommelier's copy of D3DMetal is downloading (`updateD3DMetalQuietly`).
    var d3dMetalUpdating = false
    /// Games whose shortcut icon was looked for this run (`syncShortcuts`).
    @ObservationIgnored var shortcutsTried: Set<String> = []
    /// `graphicsProbe(of:)`: by install folder, with the folder's modification date when scanned.
    @ObservationIgnored var graphicsProbes: [String: (modified: Date, probe: GraphicsProbe)] = [:]

    /// Progress for the bar: an engine install reports its own; the Steam download reports bytes.
    var shownProgress: Double? {
        if let progress { return progress }
        if isDownloadingSteam, let d = steamDownload, d.total > 0 { return Double(d.done) / Double(d.total) }
        return nil
    }

    /// The engine the user picked, else the newest one installed.
    var activeEngine: Engine? { engines.first { $0.version == settings.activeEngineVersion } ?? engines.first }

    /// The engine a store's environment was set up with. Another engine can't join a running environment,
    /// and switching engines on an existing one isn't supported yet.
    func engine(for kind: BottleKind) -> Engine? {
        if let recorded = settings.bottleEngines?[kind.rawValue], let engine = engines.first(where: { $0.version == recorded }) {
            return engine
        }
        return activeEngine
    }

    var needsSetup: Bool { engines.isEmpty || !isSteamInstalled }

    /// See `noteAccounts`; empty until the first look (at the start of `start`), so a store signed out of never
    /// flashes its games while the app opens.
    var storesWithAccount: Set<StoreKind> = []
    /// Whether `storesWithAccount` has been worked out: before that, no screen says "sign in".
    var accountsChecked = false

    /// The library's games of stores with an account signed in: a store signed out of keeps its files, not its list.
    var visibleGames: [Game] { library.games.filter { storesWithAccount.contains($0.store) } }

    func games(in store: StoreKind) -> [Game] {
        visibleGames.filter { $0.store == store }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func games(for item: SidebarItem) -> [Game] {
        let all = visibleGames.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        switch item {
        case .home, .allGames: return oneEach(all)
        // Installed, and those being installed: a game shows up here as soon as its install starts.
        case .installed: return oneEach(all.filter { $0.isInstalled || installingIDs.contains($0.id) })
        case .macVersions: return oneEach(all).filter { hasMacVersion($0) }
        case .collection(let id): return gamesIn(collection: id)
        case .mods, .controllerMode, .clips: return []
        case .store(let kind): return all.filter { $0.store == kind }
        }
    }

    // MARK: One game in several stores

    @ObservationIgnored private var copiesCache: [String: [Game]]?

    /// Every copy of the game in the library, in store order (Steam, Epic, GOG), this one included.
    func copies(of game: Game) -> [Game] {
        if copiesCache == nil {
            var index: [String: [Game]] = [:]
            for group in GameCopies.group(library.games, steamAppID: { self.info[$0.id]?.steamAppID }) {
                let ordered = group.sorted { (StoreKind.allCases.firstIndex(of: $0.store) ?? 0) < (StoreKind.allCases.firstIndex(of: $1.store) ?? 0) }
                for copy in group { index[copy.id] = ordered }
            }
            copiesCache = index
        }
        return copiesCache?[game.id] ?? [game]
    }

    /// The stores the game is in, for card and row captions: "Steam, Epic Games".
    func storeNames(of game: Game) -> String { copies(of: game).map(\.store.displayName).joined(separator: ", ") }

    /// One entry per game in a combined list: the copy to show of each (see `GameCopies.preferred`).
    private func oneEach(_ games: [Game]) -> [Game] {
        let listed = Set(games.map(\.id))
        var seen = Set<String>()
        return games.compactMap { game in
            let group = copies(of: game).filter { listed.contains($0.id) }
            guard let key = group.map(\.id).min(), seen.insert(key).inserted else { return nil }
            return GameCopies.preferred(group) { self.lastPlayed($0) }
        }
    }

    /// Shows another store's copy of the game on the page instead of this one.
    func switchCopy(to copy: Game) {
        if !path.isEmpty { path.removeLast() }
        path.append(copy)
    }

    /// Stores for the sidebar: Steam, Epic and GOG always (a store's page offers to sign in), others once they have games.
    var storesInUse: [StoreKind] {
        StoreKind.allCases.filter { kind in kind == .steam || Self.directStores.contains(kind) || Self.launcherStores.contains(kind) || library.games.contains { $0.store == kind } }
    }

    func lastPlayed(_ game: Game) -> Date? { library.userData[game.id]?.lastPlayed }
    func playTime(_ game: Game) -> TimeInterval { library.userData[game.id]?.playTime ?? 0 }

    /// The game for the big banner on Home: the one played last, else the first installed one.
    var continueGame: Game? {
        let installed = visibleGames.filter(\.isInstalled)
        return installed.max { (lastPlayed($0) ?? .distantPast) < (lastPlayed($1) ?? .distantPast) }
    }

    func heroURL(for game: Game) -> URL? { steamArtwork(for: game)?.hero ?? info[game.id]?.heroURL ?? game.heroURL ?? game.coverURL ?? bundledArt(for: game, hero: true) }
    /// Pictures that ship in the app (`StoreArt`) for Battle.net games Steam has no page for, so their cards aren't empty.
    func bundledArt(for game: Game, hero: Bool) -> URL? {
        let slugs = ["WTCG": "hearthstone", "Fen": "diablo4", "Pro": "overwatch2", "W3": "warcraft3"]
        guard game.store == .battlenet, let slug = slugs[game.storeID] else { return nil }
        return Bundle.main.url(forResource: slug + (hero ? "-h" : "-c"), withExtension: "jpg")
    }
    /// The game's logo: for Steam games known from the app id alone, for the others from their Steam page.
    func logoURL(for game: Game) -> URL? {
        steamArtwork(for: game)?.logo ?? (game.store == .steam ? SteamLibrary.artworkURL(appID: game.storeID, "logo.png") : info[game.id]?.logoURL)
    }
    func coverURL(for game: Game) -> URL? {
        #if DEBUG
        // SOMMELIER_DEBUG_NOCOVER=<store id>: that game has no cover, to see the stand-in built from its header.
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_NOCOVER"] == game.storeID { return URL(string: "https://example.invalid/none.jpg") }
        #endif
        return steamArtwork(for: game)?.cover ?? game.coverURL ?? info[game.id]?.coverURL ?? bundledArt(for: game, hero: false)
    }
    /// The wide image a card falls back to when the game has no cover (Steam's header capsule; the hero elsewhere).
    func headerURL(for game: Game) -> URL? {
        steamArtwork(for: game)?.header ?? (game.store == .steam ? SteamLibrary.artworkURL(appID: game.storeID, "header.jpg") : (info[game.id]?.heroURL ?? game.heroURL ?? bundledArt(for: game, hero: true)))
    }
    /// Steam's own record of where the game's artwork is (`SteamArtwork`), for Steam games and for games whose
    /// Steam page is known; nil until Steam's cache has been read.
    func steamArtwork(for game: Game) -> SteamArtwork? {
        if game.store == .steam { return steamArtwork[game.storeID] }
        return info[game.id]?.steamAppID.flatMap { steamArtwork[$0] }
    }

    /// Store details already on disk, for every game (no network): ratings need each game's DirectX minimum.
    func loadCachedInfo(for games: [Game]) async {
        for game in games where info[game.id] == nil {
            if let cached = await infoService.cached(for: game) { info[game.id] = cached }
        }
    }

    func loadInfo(for game: Game) async {
        if info[game.id] == nil, let cached = await infoService.cached(for: game) { info[game.id] = cached }
        if let fresh = await infoService.info(for: game) { info[game.id] = fresh }
    }

    func open(_ game: Game) { path.append(game) }

    func revealGame(_ game: Game) {
        if let url = game.installPath { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func profile(for game: Game) -> LaunchProfile { library.userData[game.id]?.profile ?? LaunchProfile() }

    func setProfile(_ profile: LaunchProfile, for game: Game) {
        var data = library.userData[game.id] ?? UserGameData()
        data.profile = profile
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    // MARK: Start-up

    /// Set once `start` has run: the window can close and open again without starting everything twice.
    private(set) var started = false

    func start() async {
        noteAccounts()
        guard !started else { return }
        started = true
        reloadEngines()
        d3dMetalInfo = D3DMetalStore(paths: paths).installed       // before anything is awaited: the setup screen reads it
        await resumeSessions()          // games that were running when Sommelier last quit
        await repairStaleTuning()       // "matched to this Mac" records that wrote where the game doesn't look
        await isolateUserFolders()
        system = await SystemCheck().run()
        Task { await loadAntiCheat() }
        sendPendingReports()
        let fixes = FixesService(paths: paths)
        remoteFixes = fixes.cached()
        Task { remoteFixes = await Task.detached { await fixes.refresh() }.value }
        let recipesService = RecipesService(paths: paths)
        recipes = recipesService.cached()
        Task { recipes = await Task.detached { await recipesService.refresh() }.value }
        let modsService = ModsService(paths: paths)
        // A fix that turns a mod off names it as the player knows it, from whichever game's store has it.
        FixAction.modNameLookup = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self else { return nil }
                for game in self.library.games { if let mod = self.modPieces(for: game)?.store.mod(key) { return mod.name } }
                return nil
            }
        }
        modsList = modsService.cached()
        Task { if let list = await Task.detached { await modsService.refresh() }.value { modsList = list } }
        let hdrService = HDRGamesService(paths: paths)
        hdrGames = hdrService.cached()
        Task { hdrGames = await Task.detached { await hdrService.refresh() }.value }
        let saveLocations = SaveLocationsService(paths: paths)
        Task.detached(priority: .utility) { await saveLocations.refresh() }     // read when saves are backed up
        let verdictsService = CommunityVerdictsService(paths: paths)
        communityVerdicts = verdictsService.cached()
        Task { communityVerdicts = await Task.detached { await verdictsService.refresh() }.value }
        watchAnnouncements()
        countInstall()
        Task.detached(priority: .background) { [paths] in                 // DXMT's shader caches: kept by Sommelier, pruned of old builds
            let cache = ShaderCache(paths: paths)
            try? cache.prepare()
            cache.prune()
        }
        watchNetwork()
        await continueSetup()
        if isSteamInstalled { await refreshLibrary(); watchSteam() }
        Task { await syncShortcuts() }   // games' shortcut apps, so the Dock knows them even when Steam starts them
        for kind in Self.directStores where isSignedIn(kind) { Task { await refreshStore(kind) } }
        for kind in Self.launcherStores where isLauncherInstalled(kind) { Task { await refreshLauncher(kind); watchLauncher(kind) } }
        Task { try? await Task.sleep(for: .seconds(20)); await fetchCellarForLibrary() }   // once the stores have settled
        #if DEBUG
        showDebugPage()
        #endif
    }

    #if DEBUG
    /// SOMMELIER_DEBUG_SHOW=home|all|installed|mac|mods|steam|<game id> opens that page at launch (for screenshots).
    private func showDebugPage() {
        if let query = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_SEARCH"] { search = query }
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_INSTALL_ENGINE"] == "1" { Task { await installEngine() } }   // the newest from the list
        // SOMMELIER_DEBUG_OPEN_LAUNCHER=ea|ubisoft|battlenet starts that launcher even when it isn't offered, with
        // SOMMELIER_DEBUG_LAUNCHER_ENV="K=V;K2=V2" and SOMMELIER_DEBUG_LAUNCHER_BACKEND=dxmt|dxvk|wined3d|d3dMetal: for trying fixes.
        if let kind = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_OPEN_LAUNCHER"].flatMap(StoreKind.init(rawValue:)) {
            Task { await debugOpenLauncher(kind) }
        }
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_D3D"] == "intro" { d3dSetup = .intro }
        // SOMMELIER_DEBUG_DOWNLOAD="<game id>=0.24,<game id>=0.6" shows those games downloading, rising slowly;
        // SOMMELIER_DEBUG_POURED=<game id> shows the "is poured" note.
        for item in (ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_DOWNLOAD"] ?? "").split(separator: ",") {
            let parts = item.split(separator: "=")
            guard parts.count == 2, let start = Double(parts[1]) else { continue }
            let id = String(parts[0]), total: Int64 = 15_000_000_000
            Task {
                var f = start
                while f < 1 {
                    debugDownloads[id] = SteamDownload(phase: .downloading, bytesDone: Int64(Double(total) * f), bytesTotal: total)
                    try? await Task.sleep(for: .seconds(1)); f += 0.01
                }
            }
        }
        // SOMMELIER_DEBUG_SHEET=warn:<game id> or pick:<game id> opens the install warning or the store choice.
        if let sheet = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_SHEET"], let colon = sheet.firstIndex(of: ":") {
            let id = String(sheet[sheet.index(after: colon)...])
            if let game = library.games.first(where: { $0.id == id }) {
                if sheet.hasPrefix("warn") { installWarning = game } else { storePick = game }
            }
        }
        if let id = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_POURED"] {
            Task { try? await Task.sleep(for: .seconds(2)); noteInstallFinished(id) }
        }
        guard let target = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_SHOW"] else { return }
        switch target {
        case "home": selection = .home
        case "all": selection = .allGames
        case "installed": selection = .installed
        case "mac": selection = .macVersions
        case "mods": selection = .mods
        case "collection": selection = collections.first.map { .collection($0.id) }
        case "steam": selection = .store(.steam)
        case "epic": selection = .store(.epic)
        case "gog": selection = .store(.gog)
        case "signin-epic": signIn = .epic
        case "signin-gog": signIn = .gog
        case "ea", "ubisoft", "battlenet":
            selection = .store(StoreKind(rawValue: target)!)
            if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_LAUNCHER"] == "1" { Task { await openLauncher(StoreKind(rawValue: target)!) } }
        case "open-steam": Task { await openSteam() }
        default:
            if let game = library.games.first(where: { $0.id == target }) {
                selection = .allGames
                Task {
                    await Task.yield(); open(game)                 // after the selection change has reset the path
                    if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_PLAY"] == "uninstall" { await uninstall(game) }
                    if let sample = ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_FAILURE"] {   // a pretend failure, for screenshots
                        var d = LaunchDiagnostics(gameID: game.id, title: game.title, store: game.store.rawValue, logTail: sample)
                        d.secondsRunning = 4
                        d.backend = GraphicsBackend.dxmt.rawValue
                        let context = FixContext(gameID: game.id, backend: .dxmt, store: game.store, native: game.isNative, d3dMetalReady: isD3DMetalReady)
                        let matched = FixRules.match(d, context: context, rules: fixRules)
                        let retry = LaunchRetry.Context(backend: .dxmt, automatic: true, turbo: true, alternatives: [.d3dMetal, .wined3d])
                        launchFailure = LaunchFailure(game: game, diagnostics: d, rules: LaunchRetry.rules(d, context: retry, matched: matched) + matched)
                    }
                    if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_PLAY"] == "1" {
                        if game.isInstalled { await play(game) } else { await install(game) }
                    }
                }
            }
        }
    }
    #endif

    /// Set-up steps that need no decision run by themselves: the engine, then Steam. Each runs once per launch
    /// on its own; after a failure the window offers to try again.
    private(set) var autoSetupFailed = false

    func continueSetup() async {
        guard system?.canContinue == true, !isBusy else { return }
        if !steam.isClientReady { startSteamPrefetch() }      // runs alongside the engine download
        if engines.isEmpty, engineManifestURL != nil {
            await installEngine()
            guard !engines.isEmpty else { autoSetupFailed = true; return }
        }
        Task { await updateD3DMetalQuietly() }                  // alongside Steam: DirectX 12 needs no step of its own
        if !engines.isEmpty, !isSteamInstalled {
            await installSteam()
            guard isSteamInstalled else { autoSetupFailed = true; return }
        }
        autoSetupFailed = false
        if let active = activeEngine { await moveBottles(to: active, onlyIdle: true) }   // what an update left behind
        Task { await updateEngineQuietly() }
    }

    func reloadEngines() {
        engines = EngineLocator(paths: paths).installed()
        // D3DMetal into each engine; a no-op unless the import or the way it's laid out changed since.
        let d3dMetal = D3DMetalStore(paths: paths)
        for engine in engines { try? d3dMetal.link(into: engine) }
        applyGameMode()
        applyControllerChoice()
    }

    /// macOS Game Mode for games, unless the player turned it off (Settings → Games).
    var gameModeOn: Bool { settings.gameMode != false }

    /// Marks the engines' loader as a game, or not, as the setting says: engines from before the loader patch get
    /// the label here, and turning Game Mode off takes it out of every engine.
    func applyGameMode() {
        let on = gameModeOn
        for engine in engines { LoaderGameLabel.set(on, for: engine) }
    }

    func installRosetta() async {
        await perform(String(localized: "Installing Rosetta 2")) {
            _ = try await SystemCheck().installRosetta()
        }
        system = await SystemCheck().run()
        await continueSetup()
    }

    // MARK: Engines

    /// Where engines come from: the user's choice in Settings, else the one built into the app.
    var engineManifestURL: URL? {
        #if DEBUG
        settings.engineManifestURL ?? Self.builtInManifestURL
        #else
        Self.builtInManifestURL           // a list picked in a debug build never applies to a release
        #endif
    }

    static var builtInManifestURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SommelierEngineManifestURL") as? String,
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    /// Installs the newest engine from the list. Engines with DXMT come first: it's Sommelier's DirectX 11 path.
    func installEngine() async {
        guard let url = engineManifestURL else {
            errorMessage = String(localized: "This build doesn't know where to download engines from. Choose an engine list in Settings.")
            return
        }
        await perform(String(localized: "Installing the game engine")) {
            let manager = EngineManager(paths: self.paths)
            let manifest = try await manager.fetchManifest(from: url).runnable(byApp: Self.appVersion)
            guard let entry = manifest.latest(supporting: .dxmt) ?? manifest.latest else {
                throw WineRunnerError.launchFailed("the engine list is empty")
            }
            let engine = try await manager.install(entry) { phase, fraction in
                Task { @MainActor in
                    self.activity = String(localized: "Installing engine \(entry.version): \(phase.label)")
                    self.progress = fraction
                }
            }
            self.settings.activeEngineVersion = engine.version
            try? D3DMetalStore(paths: self.paths).link(into: engine)   // a DirectX 12 setup carries over to new engines
            self.reloadEngines()
            await self.moveBottles(to: engine)
        }
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Keeps the engine current without asking. A newer engine downloads quietly while the player goes on (no
    /// activity bar, nothing blocked), becomes the active one, and takes over the environments nothing runs in; the
    /// others move at the next start. A debug build does the same from the list chosen in Settings, so an update
    /// can be tried as players get it.
    func updateEngineQuietly() async {
        guard !engines.isEmpty, !engineUpdating, let url = engineManifestURL else { return }
        engineUpdating = true
        defer { engineUpdating = false }
        let manager = EngineManager(paths: paths), log = Logger(subsystem: "gg.sommelier", category: "engine")
        do {
            let manifest = try await manager.fetchManifest(from: url)
            guard let entry = manifest.update(over: engines.map(\.version), appVersion: Self.appVersion) else { return }
            log.info("Engine update: \(entry.version, privacy: .public)")
            let engine = try await manager.install(entry) { _, _ in }
            settings.activeEngineVersion = engine.version
            try? D3DMetalStore(paths: paths).link(into: engine)
            reloadEngines()
            await moveBottles(to: engine, onlyIdle: true)
        } catch {
            log.error("Engine update failed: \(error.localizedDescription, privacy: .public)")    // tried again next start
        }
    }

    /// DirectX 12 without asking: Sommelier's copy of Apple's D3DMetal for this Mac's macOS, from the engine list. A
    /// copy the player took from their own toolkit stays as it is; Sommelier's own is replaced when the list names
    /// another version for this Mac, but not while a game runs (tried again at the next start).
    func updateD3DMetalQuietly() async {
        guard !engines.isEmpty, !d3dMetalUpdating, let url = engineManifestURL else { return }
        let store = D3DMetalStore(paths: paths), current = store.installed
        if let current, current.fromSommelier != true || !running.isEmpty { return }
        d3dMetalUpdating = true
        defer { d3dMetalUpdating = false }
        let log = Logger(subsystem: "gg.sommelier", category: "engine")
        do {
            let manifest = try await EngineManager(paths: paths).fetchManifest(from: url)
            let macOS = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            guard let entry = manifest.d3dMetal(forMacOS: macOS), entry.version != current?.version else { return }
            log.info("D3DMetal: \(entry.version, privacy: .public)")
            try await store.install(entry, engines: engines)
            reloadEngines()
            d3dMetalInfo = store.installed
        } catch {
            log.error("D3DMetal download failed: \(error.localizedDescription, privacy: .public)")   // tried again next start
        }
    }

    /// A new engine with the same Wine takes over the environments an older one made: nothing in them changes,
    /// only the engine's own libraries (DXMT, say). A different Wine leaves them pinned where they are. Whatever
    /// runs in an environment on the old engine (Steam, a launcher) is stopped first: one Wine at a time per
    /// environment, or the two Wine servers clash.
    /// `onlyIdle`: leave an environment where something runs (Steam open, a game, a launcher) on its engine.
    private func moveBottles(to engine: Engine, onlyIdle: Bool = false) async {
        let runner = WineRunner(paths: paths)
        var pinned = settings.bottleEngines ?? [:]
        for (kind, version) in pinned where version != engine.version {
            guard let old = engines.first(where: { $0.version == version }), old.info.wineVersion == engine.info.wineVersion,
                  let bottleKind = BottleKind(rawValue: kind) else { continue }
            let bottle = Bottle(kind: bottleKind, paths: paths)
            if onlyIdle, await runner.isBottleActive(engine: old, bottle: bottle) { continue }
            if bottleKind == .steam {
                await stopSteam(engine: old)
            } else if await runner.isBottleActive(engine: old, bottle: bottle) {
                await runner.killAll(engine: old, bottle: bottle)
                for key in Array(running.keys) where key == kind { running[key] = nil }
            }
            pinned[kind] = engine.version
        }
        settings.bottleEngines = pinned
    }

    func removeEngine(_ engine: Engine) {
        do {
            try EngineManager(paths: paths).remove(version: engine.version)
            if settings.activeEngineVersion == engine.version { settings.activeEngineVersion = nil }
            reloadEngines()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Steam

    func installSteam() async {
        guard let engine = activeEngine else { return }
        await perform(String(localized: "Installing Steam")) {
            try await self.steam.installSteam(engine: engine)
            var engines = self.settings.bottleEngines ?? [:]
            engines[BottleKind.steam.rawValue] = engine.version
            self.settings.bottleEngines = engines
        }
        if isSteamInstalled { await placeSteamClient(); watchSteam() }
    }

    // MARK: Steam client download

    /// The Steam client's packages, downloaded natively (much faster than Steam's own updater inside Wine).
    private var steamPrefetch: Task<[SteamClientPrefetch.Package]?, Never>?
    private(set) var steamDownload: (done: Int64, total: Int64)?
    private(set) var isDownloadingSteam = false
    private var prefetcher: SteamClientPrefetch {
        SteamClientPrefetch(cache: paths.home.appendingPathComponent("Downloads/SteamClient", isDirectory: true))
    }

    func startSteamPrefetch() {
        guard steamPrefetch == nil else { return }
        let prefetcher = self.prefetcher
        steamPrefetch = Task {
            let packages = try? await prefetcher.fetch { done, total in
                Task { @MainActor in self.steamDownload = (done, total) }
            }
            self.steamDownload = nil
            return packages
        }
    }

    /// Puts the downloaded packages where Steam's updater looks, so its first start only unpacks them.
    func placeSteamClient() async {
        guard isSteamInstalled, !steam.isClientReady else { return }
        startSteamPrefetch()
        let previous = activity
        activity = String(localized: "Downloading Steam")
        isDownloadingSteam = true
        defer { activity = previous; isDownloadingSteam = false }
        guard let packages = await steamPrefetch?.value else { steamPrefetch = nil; return }   // Steam will download itself
        do {
            try prefetcher.install(packages, into: steam.bottle.steamDirectory)
            try? FileManager.default.removeItem(at: prefetcher.cache)      // the copies in Steam's folder are clones
        } catch { steamPrefetch = nil }
    }

    /// Where Steam is between a click on Open Steam and its window: shown in the activity bar and on buttons.
    enum SteamLaunch: Equatable { case idle, preparing, starting, slow }
    private(set) var steamLaunch: SteamLaunch = .idle

    func openSteam() async {
        guard steamLaunch == .idle, let engine = engine(for: .steam) else { return }
        if steamWindowVisible { await bringSteamForward(bottle: steam.bottle.url); return }   // already open, maybe from an earlier app session
        steamLaunch = .preparing
        await placeSteamClient()
        await addSteamLibraryIfStopped()
        await WineD3DFallback(paths: paths).update(.steam, engine: engine)
        await prepareDock(.steam, engine: engine)
        do {
            // Started with the graphics most games want, so Play rarely has to restart it (see `play`).
            var profile = LaunchProfile()
            if engine.supports(.dxmt) { profile.backend = .dxmt; profile.turbo = turboAvailable }
            // Steam may run with no window: started quietly for a game, its window closed with the cross (it goes on
            // in the background), or started by an earlier Sommelier. A second Steam.exe asking for the main window
            // makes it show it (the sign-in window when nobody is signed in) and quits.
            let inBackground = await WineRunner(paths: paths).isBottleActive(engine: engine, bottle: steam.bottle)
            let alreadyRunning = running["steam"] != nil || inBackground
            if alreadyRunning {
                if !(await SteamClientBridge().showMainWindow()) {                 // instant when Steam can be asked
                    _ = try steam.launchSteam(engine: engine, profile: profile, extraArguments: SteamProvider.showMainWindow)
                }
            } else {
                let process = try steam.launchSteam(engine: engine, profile: profile) { _ in
                    Task { @MainActor in self.running["steam"] = nil }
                }
                running["steam"] = process
                lastLog["steam"] = process.logURL
                steamGraphics = Self.graphicsKey(profile)
            }
            steamLaunch = .starting
            await waitForSteamWindow(coldStart: !alreadyRunning, engine: engine, profile: profile)
            await bringSteamForward(bottle: steam.bottle.url)
            if steamAccountName == nil { awaitSteamSignIn() }
        } catch {
            steamLaunch = .idle
            errorMessage = error.localizedDescription
        }
    }

    /// Until the player signs in to Steam's window, or Steam quits (15 minutes at most).
    private func awaitSteamSignIn() {
        guard !waitingForSignIn.contains(.steam) else { return }
        waitingForSignIn.insert(.steam)
        Task {
            defer { waitingForSignIn.remove(.steam) }
            let started = Date()
            let runner = WineRunner(paths: paths)
            while Date().timeIntervalSince(started) < 900, steamAccountName == nil {
                // Steam is still there (our process, its window, or the Steam its update started): keep waiting.
                let alive: Bool
                if running["steam"] != nil || steamWindowVisible { alive = true }
                else if let engine = engine(for: .steam) { alive = await runner.isBottleActive(engine: engine, bottle: steam.bottle) }
                else { alive = false }
                if !alive { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// A window of Steam's own environment is up (another launcher's window isn't Steam).
    private var steamWindowVisible: Bool { WineWindows.hasVisibleWindow(enginesFolder: paths.engines.path, bottle: steam.bottle.url) }

    /// Polls until Steam's window is on screen. Steam under Wine can take a while on its first start, so after
    /// 45 seconds the bar says so instead of giving up; it stops if Steam exits.
    /// `coldStart`: Steam is starting from nothing (the long waits); otherwise it only has to show its window.
    /// The first start updates Steam: the program Sommelier started downloads the update, quits and starts the new
    /// Steam, which may come up without a window. So the wait goes on while anything runs in Steam's environment, and
    /// a Steam that runs with no window is asked again to show it (a second Steam.exe hands "show the window" over).
    private func waitForSteamWindow(coldStart: Bool = true, engine: Engine? = nil, profile: LaunchProfile = LaunchProfile()) async {
        let started = Date()
        let giveUp: TimeInterval = coldStart ? 300 : 20
        let runner = WineRunner(paths: paths)
        var lastNudge = Date()
        while steamLaunch != .idle {
            if steamWindowVisible { break }
            if coldStart, running["steam"] == nil, Date().timeIntervalSince(started) > 5 {
                // Our Steam.exe is gone: quit for good, or handed over to the updated Steam.
                guard let engine, await runner.isBottleActive(engine: engine, bottle: steam.bottle) else { break }
                if Date().timeIntervalSince(lastNudge) > 15 {          // running but no window yet: ask for it
                    _ = try? steam.launchSteam(engine: engine, profile: profile, extraArguments: SteamProvider.showMainWindow)
                    lastNudge = Date()
                }
            }
            if coldStart, steamLaunch == .starting, Date().timeIntervalSince(started) > 45 { steamLaunch = .slow }
            if Date().timeIntervalSince(started) > giveUp { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        steamLaunch = .idle
    }

    /// The text for the activity bar while Steam opens.
    var steamLaunchText: String? {
        switch steamLaunch {
        case .idle: nil
        case .preparing: isDownloadingSteam ? nil : String(localized: "Preparing Steam…")
        case .starting: String(localized: "Opening Steam…")
        case .slow: String(localized: "Steam is still starting. The first start takes longer.")
        }
    }

    func quitSteam() {
        guard let engine = engine(for: .steam) else { return }
        _ = try? steam.shutdown(engine: engine)
    }

    /// Hands keyboard focus to a game's window once it's up. A game started from Sommelier opens on top of it, but
    /// macOS keeps the keys with the app that was clicked, so without this the game ignores the keyboard until the
    /// user clicks into it. Handing over works while Sommelier is the active app (it is: the user just clicked Play).
    func giveFocus(to pid: Int32) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: .current, options: [.activateAllWindows])   // handed over by this app (macOS 14+ ignores a bare activate)
    }

    /// Quits Steam and waits until nothing runs in its environment (stopping it after 20 seconds).
    /// Writes the game's graphics variables for its folder (`ExecutableEnvironment`), on an engine whose ntdll
    /// reads them (`supportsProgramEnvironment`).
    func setProgramEnvironment(folder: URL, bottle: Bottle, profile: LaunchProfile, engine: Engine) async {
        let variables = WineRunner.programEnvironment(bottle: bottle, profile: profile, engine: engine)
        let table = ExecutableEnvironment(paths: paths), windowsFolder = bottle.windowsPath(of: folder)
        await Task.detached(priority: .utility) { table.set(folder: windowsFolder, variables: variables) }.value
    }

    /// `patience`: how long Steam may take to quit by itself before it is stopped by force (seconds).
    func stopSteam(engine: Engine, patience: Int = 20) async {
        let runner = WineRunner(paths: paths)
        let bottle = steam.bottle
        if await runner.isBottleActive(engine: engine, bottle: bottle) {
            _ = try? steam.shutdown(engine: engine)
            for _ in 0..<(patience * 4) {                          // Steam takes a few seconds to quit: checked often
                try? await Task.sleep(for: .milliseconds(250))
                if !(await runner.isBottleActive(engine: engine, bottle: bottle)) { break }
            }
            if await runner.isBottleActive(engine: engine, bottle: bottle) { await runner.killAll(engine: engine, bottle: bottle) }
        }
        running["steam"] = nil
        steamGraphics = nil
    }

    /// The graphics the running Steam was started with. Games started through a running Steam get its environment,
    /// not their own, so Play restarts Steam when a game needs other graphics. On disk because Steam outlives the app.
    /// ("dxmt", "dxmt+turbo", …): the backend, and Turbo, which is environment too.
    private var steamGraphics: String? {
        get { try? String(contentsOf: steamBackendFile, encoding: .utf8) }
        set {
            if let newValue { try? newValue.write(to: steamBackendFile, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: steamBackendFile) }
        }
    }

    nonisolated static func graphicsKey(_ profile: LaunchProfile) -> String {
        profile.backend.rawValue + (profile.turbo && profile.backend == .dxmt ? "+turbo" : "")
            + (!profile.hdr && profile.backend == .dxmt ? "+sdr" : "")
    }
    private var steamBackendFile: URL { steam.bottle.url.appendingPathComponent("sommelier-steam-graphics") }

    /// The name of the account signed in to Steam; nil when no one is.
    var steamAccountName: String? { SteamAccount.signedInName(bottle: steam.bottle) }

    /// Signs out of Steam: quits it, then deletes its saved login. Installed games stay, and so does the library's
    /// list of them; the account's other games leave until someone signs in again.
    func signOutSteam() async {
        guard let engine = engine(for: .steam), storeActivity[.steam] == nil else { return }
        storeActivity[.steam] = String(localized: "Signing out…")
        defer { storeActivity[.steam] = nil }
        let bottle = steam.bottle
        await stopSteam(engine: engine)
        await Task.detached { SteamAccount.forget(bottle: bottle) }.value
        // While this names the account, Steam signs it in again by itself.
        _ = try? await ProcessRunner.run(engine.wine, ["reg", "delete", #"HKCU\Software\Valve\Steam"#, "/v", "AutoLoginUser", "/f"],
                                         environment: WineRunner.environment(bottle: bottle, profile: LaunchProfile()))
        await refreshLibrary()
        noteAccounts()
    }

    /// Games that also have a Mac version on Steam ("steam:<appid>"); they run best through Steam for Mac.
    private var steamMacBuilds: [String: MacBuild] = [:]

    /// The Mac version the game's store sells, if any: Steam's cache for Steam games, the store's data otherwise.
    func macBuild(of game: Game) -> MacBuild? {
        if settings.legacyMacBuilds?.contains(game.id) == true { return .legacy32 }     // found out when downloaded
        return steamMacBuilds[game.id] ?? game.macBuild
    }

    /// The store this copy is in sells a Mac version of it that runs on today's macOS (32-bit ones don't).
    func hasMacVersion(_ game: Game) -> Bool { macBuild(of: game)?.runsHere == true }

    /// Epic games with a Mac version install as Mac apps: Legendary runs them without Wine, and no second
    /// sign-in is needed. (Steam games keep Steam for Mac's own install, which the user does there.)
    func installsNatively(_ game: Game) -> Bool { game.store == .epic && hasMacVersion(game) }
    /// Valve's Steam Deck results by game id, the first guess for how well a game runs here.
    private(set) var deckResults: [String: DeckCompatibility] = [:]

    /// Play time that shows the game runs here: none while its sessions so far were crashes or hangs.
    func provenPlayTime(_ game: Game) -> TimeInterval {
        library.userData[game.id]?.workedHere == false ? 0 : playTime(game)
    }

    /// Players' word on games from the service (`GET /v1/verdicts.json`), by game id, refreshed daily.
    var communityVerdicts: [String: Compatibility.Verdict] = [:]

    func compatibility(of game: Game) -> Compatibility {
        let players = info[game.id]?.players ?? []
        // A copy from another store also takes the word on its Steam game.
        var community = communityVerdicts[game.id] ?? info[game.id]?.steamAppID.flatMap { communityVerdicts["steam:\($0)"] }
        // The player said it doesn't really run: neither their play nor other players' "works" makes it working.
        let disputed = library.userData[game.id]?.disputed != nil
        if disputed, community == .works { community = nil }
        return Compatibility.rate(deck: deckResult(of: game), blocksOnlinePlay: antiCheatEntry(of: game)?.blocksOnlinePlayOnMac == true,
                                  singlePlayer: players.isEmpty ? nil : players.contains(.single),
                                  playedHere: disputed ? 0 : provenPlayTime(game), macVersion: game.isNative || hasMacVersion(game),
                                  community: community)
    }

    /// Games with anti-cheat (Are We Anti-Cheat Yet?), refreshed weekly.
    private(set) var antiCheat = AntiCheat.Index([])

    func antiCheatEntry(of game: Game) -> AntiCheat.Entry? {
        antiCheat.entry(steamAppID: game.store == .steam ? game.storeID : info[game.id]?.steamAppID, title: game.title)
    }

    func loadAntiCheat() async {
        let store = AntiCheatStore(paths: paths)
        antiCheat = AntiCheat.Index(await Task.detached { store.cached() }.value)
        antiCheat = AntiCheat.Index(await store.load())
    }

    /// Valve's Steam Deck result: from Steam's cache for Steam games, from the game's Steam page for the others.
    func deckResult(of game: Game) -> DeckCompatibility? {
        deckResults[game.id] ?? info[game.id]?.deck
    }

    // MARK: DirectX 12

    /// The DirectX 12 setup sheet's step; nil when the sheet is closed.
    var d3dSetup: D3DSetupStep?
    @ObservationIgnored var toolkitWatchers: [DirectoryWatcher] = []
    @ObservationIgnored var triedToolkits: Set<URL> = []
    /// The D3DMetal the user set up, if any.
    var d3dMetalInfo: D3DMetalInfo?

    var isD3DMetalReady: Bool { d3dMetalInfo != nil && (engine(for: .steam)?.supports(.d3dMetal) ?? false) }
    var isD3DSetupInstalling: Bool { if case .installing = d3dSetup { true } else { false } }

    /// Steam lists DirectX 12 as the minimum, and D3DMetal isn't set up. Games that can also run DirectX 11
    /// list 11 (or nothing) as the minimum and don't count: DXMT runs those.
    func needsD3DMetal(_ game: Game) -> Bool {
        !game.isNative && !installsNatively(game) && !isD3DMetalReady && (info[game.id]?.minimumDirectX ?? 0) >= 12
    }

    /// A game waiting for the user to confirm an install that will probably fail.
    var installWarning: Game?
    /// A game owned in several stores, while the user picks which copy to install.
    var storePick: Game?
    /// A Steam game with a Mac version, waiting for the user to pick Steam for Mac or the Windows version.
    var macVersionChoice: Game?
    /// Where each Steam game's artwork is, by app id, from Steam's cache (read with the library).
    private(set) var steamArtwork: [String: SteamArtwork] = [:]
    /// Games whose install finished while the app ran, and when: Home puts them first for a day.
    private(set) var installFinished: [String: Date] = [:]
    func justInstalled(game: Game) -> Bool { installFinished[game.id].map { Date().timeIntervalSince($0) < 86_400 } ?? false }
    /// Steam's recommendations by Steam app id, for Similar Games (see AppModel+Similar).
    var similarItems: [String: [SteamStore.Item]] = [:]

    /// The player's collections, in sidebar order (see AppModel+Collections).
    var collections: [GameCollection] = []
    /// A collection being named in the sidebar; the game to put on it once named, if any.
    var naming: NamingCollection?

    /// Screenshots open full size over the window.
    struct ScreenshotViewing: Equatable {
        let title: String
        let items: [Item]
        var index: Int

        enum Item: Equatable {
            case image(URL)
            case video(URL, still: URL?)

            var isVideo: Bool { if case .video = self { true } else { false } }
            /// What to show for it in a thumbnail.
            var still: URL? {
                switch self {
                case .image(let url): url
                case .video(_, let still): still
                }
            }
        }

        /// The trailer, when there is one, then the screenshots.
        static func items(trailer: URL?, thumbnail: URL?, shots: [URL]) -> [Item] {
            (trailer.map { [.video($0, still: thumbnail ?? shots.first)] } ?? []) + shots.map(Item.image)
        }
    }
    var viewing: ScreenshotViewing?

    #if DEBUG
    var debugDownloads: [String: SteamDownload] = [:]
    #endif
    func noteInstallFinished(_ id: String) {
        installFinished[id] = Date()
        if let game = library.games.first(where: { $0.id == id }) {
            poured = game
            Task { await fetchCellarAfterInstall(game) }
            Task { await tuneAfterInstall(game) }
        }
    }
    /// The game that just finished installing, for the "is poured" note; it clears itself.
    var poured: Game?
    /// Games whose ready-made shaders came down after their install (the note then says so).
    var shadersReady: Set<String> = []

    /// Play time and games over the last seven days, from the session log. Read once per launch and after each
    /// session, not on every redraw of Home.
    var weekStats: (time: TimeInterval, games: Int) {
        if let cachedWeekStats { return cachedWeekStats }
        let since = Date().addingTimeInterval(-7 * 86_400)
        let sessions = SessionStore(paths: paths).load().filter { $0.start > since }
        let stats = (sessions.reduce(0) { $0 + $1.duration }, Set(sessions.map(\.gameID)).count)
        cachedWeekStats = stats
        return stats
    }
    @ObservationIgnored private var cachedWeekStats: (time: TimeInterval, games: Int)?   // Home redraws after a session anyway

    /// A launch that just failed, shown with its cause and a fix when one is known (AppModel+Fixes.swift).
    var launchFailure: LaunchFailure?
    /// Saves that changed both here and in the cloud, waiting for the user's pick (AppModel+Saves.swift).
    var saveConflict: SaveConflict?
    /// Games whose save conflict was just settled: their next launch skips the pre-play sync.
    @ObservationIgnored var savesSyncedForLaunch: Set<String> = []
    /// A game whose saves couldn't be synced before playing while online: play anyway, or not.
    var saveSyncFailure: Game?
    /// Whether the Mac has a network path (NWPathMonitor); offline, saves wait.
    var online = true
    @ObservationIgnored var networkMonitor: NWPathMonitor?
    /// Watchers on launcher stores' game folders (AppModel+Launchers.swift).
    @ObservationIgnored var launcherWatchers: [StoreKind: [DirectoryWatcher]] = [:]
    /// Games whose pipelines are being cooked into a local archive (AppModel+Cellar).
    @ObservationIgnored var cooking: Set<String> = []
    /// The runtime set going into an environment (`prepareRuntime`), by bottle kind, so a Play waits for it.
    @ObservationIgnored var runtimeTasks: [String: Task<Void, Never>] = [:]
    /// Launchers Sommelier started only to run a game: they close a while after the game, unless the user opens them.
    @ObservationIgnored var launchersStartedForGames: Set<StoreKind> = []
    /// Waiting for the user to sign in inside a launcher (AppModel+Launchers.swift).
    @ObservationIgnored var signInWatchers: [StoreKind: Task<Void, Never>] = [:]
    /// Stores whose sign-in window is open and waiting for the player (their Sign In buttons are off meanwhile).
    var waitingForSignIn: Set<StoreKind> = []
    /// Steam games installing through Steam for Mac (the rest install through the Steam in the environment).
    private(set) var nativeInstalls: Set<String> = []

    /// Installed games from Steam's manifests, plus the rest of the account's library from Steam's cache.
    func refreshLibrary() async {
        defer { noteAccounts() }
        guard isSteamInstalled else { return }
        let bottle = steam.bottle
        let (wineInstalled, nativeInstalled, owned) = await Task.detached {
            (SteamLibrary.scan(bottle: bottle), SteamMacClient.scan(), SteamOwnedGames.scan(bottle: bottle))
        }.value
        // A game in both Steams: the Mac app is the one the user set up to play natively.
        let nativeIDs = Set(nativeInstalled.map(\.storeID))
        let installed = nativeInstalled.filter(\.isInstalled) + wineInstalled.filter { !nativeIDs.contains($0.storeID) }
        let installedIDs = Set(installed.map(\.storeID))
        let rest = owned.filter { !installedIDs.contains($0.appID) }.map { entry in
            Game(store: .steam, storeID: entry.appID, title: entry.name, isInstalled: false,
                 coverURL: entry.artwork.cover, heroURL: entry.artwork.hero)
        }
        // Set only when they changed: each set redraws every card that reads them.
        let artwork = Dictionary(owned.map { ($0.appID, $0.artwork) }, uniquingKeysWith: { a, _ in a })
        let macBuilds = Dictionary(owned.compactMap { e in e.macBuild.map { ("steam:\(e.appID)", $0) } }, uniquingKeysWith: { a, _ in a })
        let deck = Dictionary(owned.compactMap { e in e.deck.map { ("steam:\(e.appID)", $0) } }, uniquingKeysWith: { a, _ in a })
        if artwork != steamArtwork { steamArtwork = artwork }
        if macBuilds != steamMacBuilds { steamMacBuilds = macBuilds }
        if deck != deckResults { deckResults = deck }
        let fresh = installed + rest
        for game in wineInstalled where !game.isInstalled || game.installProgress != nil { downloads[game.id] = downloads[game.id] ?? SteamDownload(phase: .queued, bytesDone: 0, bytesTotal: 0) }
        for game in nativeInstalled where !game.isInstalled || game.installProgress != nil {
            nativeInstalls.insert(game.id)
            downloads[game.id] = downloads[game.id] ?? SteamDownload(phase: .queued, bytesDone: 0, bytesTotal: 0)
        }
        if !downloads.isEmpty { trackDownloads() }
        await loadCachedInfo(for: fresh)
        guard fresh != library.games.filter({ $0.store == .steam }) else { return }
        library.games = LibraryStore.merged(cached: library.games, replacing: .steam, with: fresh)
        library.userData = LibraryStore.pruned(library.userData, keeping: library.games)
        libraryStore.save(library)
    }

    /// Refreshes the library by itself when Steam changes its files: sign-in, an install finishing, an uninstall.
    @ObservationIgnored private var steamWatchers: [DirectoryWatcher] = []

    func watchSteam() {
        guard steamWatchers.isEmpty, isSteamInstalled else { return }
        let steamDir = steam.bottle.steamDirectory
        var folders = ["steamapps", "appcache/librarycache"].map { steamDir.appendingPathComponent($0) }
        if SteamMacClient.isInstalled { folders.append(SteamMacClient.home.appendingPathComponent("steamapps")) }
        // `steamapps` holds the games themselves (`common/`), downloads and shader caches: only its own files (the
        // install records, the library list) say the library changed. A game writing its logs, or a download
        // writing chunks, must not read the whole library again every two seconds.
        steamWatchers = folders.map { (folder: URL) -> DirectoryWatcher in
            var relevant: (@Sendable (String) -> Bool)?
            if folder.lastPathComponent == "steamapps" { relevant = { path in DirectoryWatcher.isDirectlyIn(folder, path) } }
            return DirectoryWatcher(directory: folder, latency: 2, relevant: relevant) {
                Task { @MainActor in await self.refreshLibrary() }
            }
        }
    }

    /// Opens Steam's install dialog for a game in the library. Games that will probably fail ask first.
    func install(_ game: Game, confirmed: Bool = false, storeChosen: Bool = false) async {
        // Owned in several stores and none installed: ask which copy first.
        if !confirmed, !storeChosen, copies(of: game).count > 1, !copies(of: game).contains(where: \.isInstalled) {
            storePick = game; return
        }
        if !confirmed, info[game.id] == nil { await loadInfo(for: game) }
        if !confirmed, compatibility(of: game).warnsBeforeInstall || needsD3DMetal(game) { installWarning = game; return }
        if Self.directStores.contains(game.store) { installDirect(game); return }
        if Self.launcherStores.contains(game.store) { await installThroughLauncher(game); return }   // installs happen in its launcher
        guard game.store == .steam else { return }
        // A Mac version goes through Steam for Mac: no questions when it's there, one question (once) when it isn't.
        if hasMacVersion(game), settings.steamMacVersions != "windows" {
            if SteamMacClient.isInstalled { await installNativeSteam(game); return }
            if settings.steamMacVersions == "native" { await setUpSteamForMac(then: game); return }
            macVersionChoice = game
            return
        }
        guard let engine = engine(for: .steam) else { return }
        if !steamWindowVisible { await openSteam() }
        let mark = SteamInstallDialog.mark(bottle: steam.bottle)
        do {
            try steam.install(appID: game.storeID, engine: engine)
            awaitingInstall[game.id] = Date()
            installDialogs[game.id] = (mark, nil)
            trackDownloads()
            await bringSteamForward()                       // the dialog opens inside Steam's window: show that window
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Steam for Mac

    /// Opens Steam for Mac's install dialog for the game; its download is followed like the other Steam's.
    func installNativeSteam(_ game: Game) async {
        let wasRunning = steamForMacRunning
        if !wasRunning {
            // A steam:// link handed to a Steam that is still connecting gets "Steam is offline": start it, let it
            // log on, then ask.
            storeActivity[.steam] = String(localized: "Opening Steam…")
            let launched = Date()
            NSWorkspace.shared.openApplication(at: SteamMacClient.appURL, configuration: .init()) { _, _ in }
            while Date().timeIntervalSince(launched) < 45 {
                if let logOn = SteamMacClient.lastLogOn(), logOn > launched.addingTimeInterval(-2) { break }
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .seconds(2))
            storeActivity[.steam] = nil
        }
        NSWorkspace.shared.open(SteamMacClient.url("install", appID: game.storeID))
        awaitingInstall[game.id] = Date()
        nativeInstalls.insert(game.id)
        trackDownloads()
        await bringSteamForMacForward()
        // The logs that tell when the dialog closes are marked only once Steam is up: a Steam that was starting
        // writes the same "page shown" line as a closing dialog does.
        if !wasRunning { try? await Task.sleep(for: .seconds(4)) }
        if awaitingInstall[game.id] != nil { installDialogs[game.id] = (SteamInstallDialog.mark(home: .mac), nil) }
    }

    /// The Steam window that waits on the player for this game (its install dialog, its uninstall confirmation):
    /// Steam for Mac's for a game it installs, else the Windows Steam's.
    func showSteamConfirmation(for game: Game) async {
        if nativeInstalls.contains(game.id) || game.isNative { await bringSteamForMacForward() } else { await bringSteamForward() }
    }

    /// Steam for Mac to the front once it runs (it may be starting up).
    private func bringSteamForMacForward() async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: SteamMacInstaller.bundleIdentifier).first,
               app.isFinishedLaunching {
                try? await Task.sleep(for: .milliseconds(800))              // its window follows a moment later
                NSApp.yieldActivation(to: app)
                app.activate(from: .current, options: [.activateAllWindows])   // handed over by this app (macOS 14+ ignores a bare activate)
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private var steamForMacRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SteamMacInstaller.bundleIdentifier).isEmpty
    }

    /// Installs Steam for Mac, opens it for the user to sign in, and once they have, installs the game through it.
    func setUpSteamForMac(then game: Game) async {
        guard activity == nil else { return }
        activity = String(localized: "Installing Steam for Mac…")
        progress = nil
        do { try await SteamMacInstaller().install() }
        catch { activity = nil; errorMessage = error.localizedDescription; return }
        if !SteamMacInstaller.isSignedIn {
            activity = String(localized: "Sign in to Steam for Mac to continue…")
            NSWorkspace.shared.openApplication(at: SteamMacClient.appURL, configuration: .init()) { _, _ in }
            let started = Date()
            var ran = false
            var goneSince: Date?
            while !SteamMacInstaller.isSignedIn, Date().timeIntervalSince(started) < 900 {
                try? await Task.sleep(for: .seconds(2))
                if steamForMacRunning { ran = true; goneSince = nil }
                else if ran { goneSince = goneSince ?? Date() }
                if let goneSince, Date().timeIntervalSince(goneSince) > 10 { break }    // the user quit Steam instead
            }
            guard SteamMacInstaller.isSignedIn else { activity = nil; return }
            try? await Task.sleep(for: .seconds(3))                                      // Steam finishes signing in
        }
        activity = nil
        await installNativeSteam(game)
    }

    /// Brings Steam to the front: the first of its windows that appears after `newerThan` (a dialog it is about to
    /// show), or, if none shows up within a few seconds, whichever Steam window is newest.
    /// Returns the new window's number when one appeared.
    @discardableResult
    func bringSteamForward(newerThan baseline: Int = .max, waitUpTo seconds: Double = 8, bottle: URL? = nil) async -> Int? {
        let folder = paths.engines.path
        let deadline = Date().addingTimeInterval(seconds)
        var target: Int32?
        var newWindow: Int?
        while Date() < deadline {
            if let newest = WineWindows.newestWindow(enginesFolder: folder, bottle: bottle), newest.number > baseline {
                target = newest.pid; newWindow = newest.number; break
            }
            if baseline == .max { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if target == nil { target = WineWindows.newestWindow(enginesFolder: folder, bottle: bottle)?.pid }
        if let pid = target, let app = NSRunningApplication(processIdentifier: pid) {
            NSApp.yieldActivation(to: app)                       // macOS 14+: hand focus over, then activate
            app.activate(from: .current, options: [.activateAllWindows])   // handed over by this app (macOS 14+ ignores a bare activate)
        }
        return newWindow
    }

    // MARK: Downloads

    /// Games whose Steam install dialog was opened and not yet confirmed (no manifest yet), with when.
    private(set) var awaitingInstall: [String: Date] = [:] { didSet { noteInstalling() } }
    /// For a game whose install dialog is open: where Steam's logs ended at the click, and when the dialog closed.
    @ObservationIgnored private var installDialogs: [String: (mark: SteamInstallDialog.Mark, closedAt: Date?)] = [:]
    /// Installs and updates in progress, by game id.
    private(set) var downloads: [String: SteamDownload] = [:] { didSet { noteInstalling() } }

    /// The games with an install in progress, and those of them that are Steam's: which games, not how far along.
    /// Menus read these instead of the progress, which changes every second and would rebuild an open menu (its
    /// submenus closed under the pointer).
    private(set) var installingIDs: Set<String> = []
    private(set) var steamInstallingIDs: Set<String> = []

    private func noteInstalling() {
        let steamIDs = Set(downloads.keys)
        let all = steamIDs.union(directInstalls.keys).union(launcherDownloads.keys).union(launcherInstallRequests.keys).union(awaitingInstall.keys)
        if steamIDs != steamInstallingIDs { steamInstallingIDs = steamIDs }
        if all != installingIDs { installingIDs = all }
    }
    @ObservationIgnored private var downloadTracker: Task<Void, Never>?
    /// Pause and resume clicks on Steam downloads, shown at once: Steam's files say so only a few seconds later.
    var steamPauseRequests: [String: (paused: Bool, at: Date)] = [:]
    /// Download speed per game in bytes a second, over the last ~10 seconds.
    private(set) var downloadRates: [String: Double] = [:]
    @ObservationIgnored private var rateSamples: [String: [(time: Date, bytes: Int64)]] = [:]

    /// Library games being installed or waiting for confirmation, most advanced first, for the downloads bar.
    var activeDownloads: [(game: Game, state: InstallState)] {
        library.games.compactMap { game in installState(of: game).map { (game, $0) } }
            .sorted { a, b in (a.state.fraction ?? -1) > (b.state.fraction ?? -1) }
    }

    private func sampleRate(_ id: String, _ download: SteamDownload) {
        guard download.phase == .downloading else { downloadRates[id] = nil; rateSamples[id] = nil; return }
        let now = Date()
        var samples = (rateSamples[id] ?? []).filter { now.timeIntervalSince($0.time) <= 10 }
        samples.append((now, download.bytesDone))
        rateSamples[id] = samples
        if let first = samples.first, now.timeIntervalSince(first.time) >= 2 {
            downloadRates[id] = max(0, Double(download.bytesDone - first.bytes) / now.timeIntervalSince(first.time))
        }
    }

    /// What the game's install is doing, for the UI: waiting for confirmation in Steam, or Steam's own state.
    enum InstallState: Equatable {
        case confirmInSteam; case steam(SteamDownload); case direct(DirectInstall); case launcher(StoreKind, LauncherDownload)
    }

    func installState(of game: Game) -> InstallState? {
        #if DEBUG
        if let d = debugDownloads[game.id] { return .steam(d) }
        #endif
        if let d = downloads[game.id] { return .steam(asRequested(d, game.id)) }
        if let d = directInstalls[game.id] { return .direct(d) }
        if let d = launcherDownloads[game.id] { return .launcher(game.store, d) }
        if let asked = launcherInstallRequests[game.id], !game.isInstalled, Date().timeIntervalSince(asked) < 900 {
            return .launcher(game.store, LauncherDownload(phase: launcherInstallOpening.contains(game.id) ? .opening : .confirm))
        }
        return awaitingInstall[game.id] != nil ? .confirmInSteam : nil
    }

    /// Follows every install once a second until it finishes, then refreshes the library so the game moves to
    /// Ready to Play. An install dialog nobody confirms is dropped after ten minutes.
    func trackDownloads() {
        guard downloadTracker == nil else { return }
        downloadTracker = Task {
            while !awaitingInstall.isEmpty || !downloads.isEmpty {
                let bottle = steam.bottle
                let ids = Set(awaitingInstall.keys).union(downloads.keys)
                let native = nativeInstalls
                let states = await Task.detached {
                    let wine = SteamHome(bottle: bottle), mac = SteamHome.mac
                    return Dictionary(uniqueKeysWithValues: ids.map { id in
                        (id, SteamDownload.read(appID: String(id.dropFirst("steam:".count)), home: native.contains(id) ? mac : wine))
                    })
                }.value
                var finished = false
                for id in ids {
                    guard let state = states[id] ?? nil else {
                        downloads[id] = nil
                        if let since = awaitingInstall[id] {
                            // Backed out: the dialog closed and Steam made no manifest within 3 s (on Install it
                            // makes one at once), or Steam itself is gone.
                            let home = native.contains(id) ? SteamHome.mac : SteamHome(bottle: bottle)
                            if var dialog = installDialogs[id], dialog.closedAt == nil, SteamInstallDialog.closed(since: dialog.mark, home: home) {
                                dialog.closedAt = Date(); installDialogs[id] = dialog
                            }
                            let closedFor = installDialogs[id]?.closedAt.map { Date().timeIntervalSince($0) } ?? 0
                            let steamGone = native.contains(id) ? !steamForMacRunning : !steamWindowVisible
                            if closedFor > 3 || (steamGone && Date().timeIntervalSince(since) > 5)
                                || Date().timeIntervalSince(since) > 600 {
                                awaitingInstall[id] = nil
                                installDialogs[id] = nil
                                nativeInstalls.remove(id)
                            }
                        }
                        continue
                    }
                    awaitingInstall[id] = nil
                    installDialogs[id] = nil
                    if state.phase == .done {
                        downloads[id] = nil; downloadRates[id] = nil; rateSamples[id] = nil; nativeInstalls.remove(id); finished = true
                        noteInstallFinished(id)
                    } else {
                        downloads[id] = state
                        sampleRate(id, state)
                    }
                }
                if finished { await refreshLibrary() }
                try? await Task.sleep(for: .seconds(1))
            }
            downloadTracker = nil
        }
    }

    // MARK: Uninstall

    enum UninstallState: Equatable { case confirmInSteam, removing }
    var uninstalls: [String: UninstallState] = [:]
    @ObservationIgnored private var uninstallTracker: Task<Void, Never>?

    func uninstallState(of game: Game) -> UninstallState? { uninstalls[game.id] }

    /// Asks Steam to uninstall the game (or cancel its download): Steam shows its own confirmation and deletes the
    /// files itself, so it never thinks a game is installed whose files are gone.
    func uninstall(_ game: Game) async {
        if game.store == .steam, game.isNative { uninstallNativeSteam(game); return }
        if Self.launcherStores.contains(game.store) { await openLauncher(game.store); return }    // its launcher uninstalls
        if Self.directStores.contains(game.store) {
            if directInstalls[game.id] != nil { cancelDirectInstall(game) } else { pendingUninstall = game }
            return
        }
        guard game.store == .steam, uninstalls[game.id] == nil, let engine = engine(for: .steam) else { return }
        if !steamWindowVisible { await openSteam() }
        let before = WineWindows.newestWindow(enginesFolder: paths.engines.path)?.number ?? -1
        do {
            _ = try WineRunner(paths: paths).run(engine: engine, bottle: steam.bottle, executable: "Steam.exe",
                                                 arguments: ["steam://uninstall/\(game.storeID)"],
                                                 workingDirectory: steam.bottle.steamDirectory, logID: "steam")
        } catch { errorMessage = error.localizedDescription; return }
        uninstalls[game.id] = .confirmInSteam
        awaitingInstall[game.id] = nil
        // Steam's Uninstall dialog is a window of its own: bring it forward and watch it.
        let dialog = await bringSteamForward(newerThan: before, waitUpTo: 6)
        followUninstall(game, dialog: dialog)
    }

    /// Done when the app manifest is gone. Steam sets the uninstalling bit while it deletes; if its dialog window
    /// closes and three seconds later the game is still there without that bit, the user cancelled.
    private func followUninstall(_ game: Game, dialog: Int?) {
        let bottle = steam.bottle
        let appID = game.storeID
        Task {
            var closedAt: Date?
            let started = Date()
            while uninstalls[game.id] != nil {
                try? await Task.sleep(for: .milliseconds(500))
                let flags = await Task.detached { SteamDownload.stateFlags(appID: appID, bottle: bottle) }.value
                guard let flags else {                                  // manifest gone: uninstalled
                    if uninstalls[game.id] == .confirmInSteam { bringSommelierForward() }
                    uninstalls[game.id] = nil
                    downloads[game.id] = nil
                    await refreshLibrary()
                    return
                }
                if flags & SteamDownload.uninstalling != 0 {
                    // Confirmed in Steam: back to Sommelier, which shows the rest.
                    if uninstalls[game.id] == .confirmInSteam { bringSommelierForward() }
                    uninstalls[game.id] = .removing
                    continue
                }
                if closedAt == nil, let dialog, !WineWindows.isOnScreen(dialog) { closedAt = Date() }
                if let closedAt, Date().timeIntervalSince(closedAt) > 3 { uninstalls[game.id] = nil }
                if !steamWindowVisible || Date().timeIntervalSince(started) > 600 { uninstalls[game.id] = nil }
            }
        }
    }

    /// Takes focus back from Steam once its dialog is done. macOS 14+ lets the active app hand focus over but
    /// doesn't let a background app take it; Wine's Steam never hands it over, so ask to ignore other apps.
    func bringSommelierForward() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    /// Shows Steam's Downloads page (to pause, reorder or cancel): Steam for Mac's for a game installing there.
    func openSteamDownloads(for game: Game? = nil) async {
        if let game, nativeInstalls.contains(game.id) || game.isNative {
            NSWorkspace.shared.open(URL(string: "steam://open/downloads")!)
            await bringSteamForMacForward()
            return
        }
        guard let engine = engine(for: .steam) else { return }
        if running["steam"] == nil { await openSteam() }
        let before = WineWindows.newestWindow(enginesFolder: paths.engines.path)?.number ?? -1
        _ = try? WineRunner(paths: paths).run(engine: engine, bottle: steam.bottle, executable: "Steam.exe",
                                              arguments: ["steam://open/downloads"],
                                              workingDirectory: steam.bottle.steamDirectory, logID: "steam")
        await bringSteamForward(newerThan: before, waitUpTo: 3)
    }

    // MARK: Playing

    /// Backends this game can be given on the engine its store runs on.
    func backends(for game: Game) -> [GraphicsBackend] {
        guard let engine = engine(for: game.store.bottleKind) else { return [.auto] }
        return GraphicsBackend.allCases.filter { engine.supports($0) }
    }

    /// What Automatic picks for this game. Sommelier's rule on top of SommelierKit's: when the engine has no DXVK
    /// but has DXMT, Direct3D 11 games go to DXMT instead of falling back to Wine's slower WineD3D.
    func resolvedBackend(for game: Game, profile: LaunchProfile, engine: Engine) async -> GraphicsBackend {
        let probe = await graphicsProbe(of: game)
        let backend = profile.backend.resolved(for: probe, d3dMetalAvailable: engine.supports(.d3dMetal))
        if backend == .dxvk && !engine.supports(.dxvk) && engine.supports(.dxmt) { return .dxmt }
        return backend
    }

    /// What the game's files say about its graphics, read once per folder until the folder changes (an update
    /// or a reinstall changes its modification date): the scan walks the game's programs, which takes a moment.
    func graphicsProbe(of game: Game) async -> GraphicsProbe? {
        guard let folder = game.installPath else { return nil }
        let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if let cached = graphicsProbes[folder.path], cached.modified == modified { return cached.probe }
        let probe = await Task.detached { GraphicsProbe.scan(folder) }.value
        graphicsProbes[folder.path] = (modified, probe)
        return probe
    }

    /// Where a game is between Play and quitting: drives the Play button, badges and play time.
    enum GameState: Equatable {
        /// Play was clicked; waiting for Steam to start the game and for its window.
        case starting(since: Date)
        /// The game is running.
        case playing(since: Date)
    }
    var gameStates: [String: GameState] = [:] {
        didSet {
            // A game that just began playing: what its tuned settings are a minute in is what the game kept.
            for (id, state) in gameStates {
                guard case .playing = state, oldValue[id].map({ if case .playing = $0 { false } else { true } }) ?? true else { continue }
                settleTuningSoon(id)
            }
        }
    }

    /// Games whose launch waits for the player in the store's own window (Steam's failed cloud sync, a launcher's
    /// sign-in or update), with that store: the Play button says so and brings the window forward.
    var storeDialogs: [String: StoreKind] = [:]

    func state(of game: Game) -> GameState? { gameStates[game.id] }

    /// The store window a starting game waits on, brought forward (the Play button's "Answer in …").
    func showStoreDialog(for game: Game) async {
        guard let store = storeDialogs[game.id] else { return }
        if store == .steam { await bringSteamForward(); return }
        let marker = launcher(store).launcherExecutable.lastPathComponent.lowercased()
        let engines = paths.engines.path
        if let owner = await Task.detached(operation: { WineWindows.windowOwner(enginesFolder: engines) { $0.lowercased().contains(marker) } }).value {
            giveFocus(to: owner)
        }
    }
    func isActive(_ game: Game) -> Bool { gameStates[game.id] != nil }

    /// A Steam game while Steam itself is starting ("Opening Steam…"): Play waits until it is up, as a click
    /// meanwhile would hand the game to a Steam that isn't there yet.
    func waitsForSteam(_ game: Game) -> Bool {
        game.store == .steam && !game.isNative && steamLaunch != .idle
    }

    func play(_ game: Game) async {
        guard gameStates[game.id] == nil, !waitsForSteam(game) else { return }
        noteFirstGame()
        // Signed out of Steam: a quiet start would wait on a sign-in window nobody sees. Steam's window instead.
        if game.store == .steam, !game.isNative, steamAccountName == nil { await openSteam(); return }
        guard await guardMods(before: game) else { return }          // the mods policy: the path, or a hold (AppModel+Mods)
        if game.isNative { await playNative(game); return }
        if needsD3DMetal(game) { beginD3DMetalSetup(); return }
        guard let engine = engine(for: game.store.bottleKind) else {
            errorMessage = String(localized: "Install a game engine first.")
            return
        }
        guard await tuneBeforePlay(game) else { return }          // graphics matched to the Mac, before the first launch
        await applyRecipe(before: game, engine: engine)
        applyControllerPrompts(before: game)
        if Self.directStores.contains(game.store) { await playDirect(game, engine: engine); return }
        if Self.launcherStores.contains(game.store) { await playLauncher(game, engine: engine); return }
        guard game.store == .steam else {
            errorMessage = String(localized: "\(game.store.displayName) games aren't supported in this version yet.")
            return
        }
        gameStates[game.id] = .starting(since: Date())
        if let folder = game.installPath, EAAppSetup.needsSetup(gameFolder: folder, bottle: steam.bottle) {
            // EA games start through the EA app. Steam can't install it here by itself: its installer needs .NET.
            activity = String(localized: "Setting up the EA app…")
            defer { activity = nil }
            do {
                try await EAAppSetup(paths: paths).ensure(gameFolder: folder, bottle: steam.bottle, engine: engine)
            } catch {
                gameStates[game.id] = nil
                errorMessage = String(localized: "Couldn't set up the EA app, which \(game.title) needs to start.")
                return
            }
        }
        if let folder = game.installPath, EAAppSetup.installer(inGame: folder) != nil {
            let bottle = steam.bottle
            await Task.detached { EAAppSetup.disableOverlay(in: bottle) }.value
        }
        do {   // Ubisoft games bought on Steam bring Ubisoft Connect into Steam's environment; its overlay breaks games
            let bottle = steam.bottle
            await Task.detached { UbisoftSettings.disableOverlay(in: bottle) }.value
        }
        var profile = profile(for: game)
        profile.backend = await resolvedBackend(for: game, profile: profile, engine: engine)
        await applyRetina(profile.retina, bottleKind: .steam, engine: engine)
        lastLaunchBackend[game.id] = profile.backend
        let steamRunning = await WineRunner(paths: paths).isBottleActive(engine: engine, bottle: steam.bottle)
        profile.turbo = turboApplies(to: game, backend: profile.backend)
        profile.forGame = true                    // the game hears the microphone (macOS asks if it opens it)
        profile.hdr = true                    // the HDR switch is off for now (22.10): games see HDR; a recipe can hide it
        #if !DEBUG
        profile.performanceHUD = false        // Apple's Metal HUD is a debug-build tool only (22.10)
        #endif
        lastLaunchTurbo[game.id] = profile.turbo
        if engine.supportsProgramEnvironment, let folder = game.installPath {
            // The game's own graphics, by folder: Steam keeps running as it is (no restart, no download interrupted).
            await setProgramEnvironment(folder: folder, bottle: steam.bottle, profile: profile, engine: engine)
        } else if steamRunning, steamGraphics != Self.graphicsKey(profile) {
            activity = String(localized: "Restarting Steam for this game's graphics…")
            await stopSteam(engine: engine)
            activity = nil
        }
        if !steamRunning || steamGraphics == nil { steamGraphics = Self.graphicsKey(profile) }   // this launch starts Steam
        await addSteamLibraryIfStopped()
        await WineD3DFallback(paths: paths).update(.steam, engine: engine)
        await prepareDock(.steam, engine: engine)
        await decant(game, backend: profile.backend)
        await prepareCellar(game, backend: profile.backend)
        let logStart = SteamContentLog.length(bottle: steam.bottle)
        consoleStart[game.id] = SteamContentLog.consoleLength(bottle: steam.bottle)
        launchLogMarks[game.id] = logMark(for: game)
        do {
            // The process only hands the game to Steam (or starts Steam with it); the game's state comes from Steam's log.
            // When Steam wasn't running this process is Steam itself: its end means Steam quit (from its own menu,
            // say), so it stops counting as running. Handed to a running Steam, it ends at once and isn't kept.
            let started = Holder<RunningProcess>()
            let process: RunningProcess
            if let command = modLoader.removeValue(forKey: game.id) {
                // A modded launch through the profile's loader (me3): it starts the game itself in Steam's
                // environment, with Steam running beside it (AppModel+Mods).
                process = try await startModLoader(command, for: game, engine: engine, profile: profile, steamRunning: steamRunning)
            } else {
                process = try steam.play(game, engine: engine, profile: profile) { _ in
                    Task { @MainActor in
                        if let mine = started.value, self.running["steam"] === mine { self.running["steam"] = nil }
                    }
                }
                if running["steam"] == nil { running["steam"] = process; started.value = process }
            }
            lastLog[game.id] = process.logURL
            await follow(game, logStart: logStart)
        } catch {
            gameStates[game.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Follows one launch: Steam's log says when the game runs and stops, the window list says when it is on
    /// screen. Ends by recording the session's play time.
    private func follow(_ game: Game, logStart: UInt64) async {
        let bottle = steam.bottle
        let engines = paths.engines.path
        let clicked = Date()
        /// Steam was last seen downloading the game's update, or waiting on the player, before starting it: the
        /// time limits wait for it.
        var updatedAt: Date?
        var runningSince: Date?
        var playingSince: Date?
        var sawWindow = false
        // Many games start through a pre-launcher that quits and hands over to a launcher or the game (The Witcher
        // 3 and Cyberpunk 2077: REDlauncher; Rockstar, Paradox): Steam says "not running" for a moment in between.
        var stoppedAt: Date?
        // Steam's own launch steps (console_log.txt): one that doesn't move for half a minute, with Steam waiting on
        // no dialog, means Steam itself got stuck before starting the game.
        let consoleStart = consoleStart.removeValue(forKey: game.id) ?? SteamContentLog.consoleLength(bottle: bottle)
        var lastStep: (line: String, since: Date)?
        // Steam waiting on a dialog of its own (a cloud sync that failed, an agreement): when it was last shown.
        var dialogShown: (line: String, at: Date)?
        var waitingSince: (line: String, at: Date)?     // the step Steam waits on, and since when
        var lastLaunchCheck = Date.distantPast
        // Once the game's window has shown, nothing left running from its folder for 3 seconds means it quit: no
        // need for Steam's log and the 15 seconds kept for pre-launchers (they hand over before any window shows).
        let folderName = game.installPath?.lastPathComponent ?? ""
        var goneFor = 0

        while gameStates[game.id] != nil {
            let appID = game.storeID
            let (logged, owner) = await Task.detached {
                (SteamContentLog.isRunning(appID: appID, bottle: bottle, since: logStart),
                 WineWindows.gameWindowOwner(enginesFolder: engines))
            }.value
            let window = owner != nil
            // The game's own window to the front when it first shows, even when its launcher (REDlauncher, …) kept
            // the session going before it: an inactive full-screen window stays under the menu bar and the Dock.
            if let owner, !sawWindow, playingSince != nil { giveFocus(to: owner) }
            if window { sawWindow = true }
            // Already running when Play was clicked (Steam handed the click to the game's own launcher, which
            // started it): Steam writes nothing new, but the game's window is up.
            let running = logged ?? (window ? true : nil)
            if playingSince == nil, let owner { giveFocus(to: owner) }

            if running == true, runningSince == nil { runningSince = Date() }
            if playingSince == nil, let since = runningSince,
               window || Date().timeIntervalSince(since) > 30 {             // some games show no window for a while
                playingSince = since
                gameStates[game.id] = .playing(since: since)
            }
            if sawWindow, !window, !folderName.isEmpty {
                let alive = await Task.detached { WineWindows.gameProcess(enginesFolder: engines, folderName: folderName) != nil }.value
                goneFor = alive ? 0 : goneFor + 1
                if goneFor >= 3 { stoppedAt = Date().addingTimeInterval(-3); break }
            } else { goneFor = 0 }
            if running == true { stoppedAt = nil }
            if running == false, runningSince != nil {
                if stoppedAt == nil { stoppedAt = Date() }
                if Date().timeIntervalSince(stoppedAt!) >= 15 { break }        // the game quit (no hand-over came)
            }
            if runningSince == nil {
                let step = await Task.detached { SteamContentLog.launchStep(appID: appID, bottle: bottle, since: consoleStart) }.value
                if step?.updating == true {
                    // An update first (Steam downloads it, then starts the game by itself): shown as a download, and
                    // neither stuck nor a failure, however long it takes.
                    updatedAt = Date(); lastStep = nil
                    followSteamUpdate(of: game)
                } else if let step, step.waitingForPlayer {
                    // Steam asks the player something before it starts the game. Every launch "waits" a moment on
                    // steps nobody sees (ShowInterstitials, CreatingProcess): only a wait of 2 seconds is a question.
                    // Started quietly (-silent), its dialog can open behind Sommelier, where nobody sees it: brought
                    // forward when it appears, and again every 20 seconds while Sommelier is the app in front. The
                    // wait doesn't count against the launch.
                    lastStep = nil; updatedAt = Date()
                    if waitingSince?.line != step.line { waitingSince = (step.line, Date()) }
                    if Date().timeIntervalSince(waitingSince!.at) >= 2 {
                        storeDialogs[game.id] = .steam
                        let fresh = dialogShown?.line != step.line
                        if fresh || (NSApp.isActive && Date().timeIntervalSince(dialogShown!.at) >= 20) {
                            await bringSteamForward()
                            dialogShown = (step.line, Date())
                        }
                        // Declining (Cancel) ends Steam's launch without a line in its logs: asked of Steam itself.
                        if Date().timeIntervalSince(lastLaunchCheck) >= 3 {
                            lastLaunchCheck = Date()
                            if await SteamClientBridge().isLaunching(appID: appID) == false {
                                gameStates[game.id] = nil
                                storeDialogs[game.id] = nil
                                return
                            }
                        }
                    }
                } else if let step, !step.done {
                    storeDialogs[game.id] = nil
                    // Install scripts (a game's first launch here) take minutes; any other step that long is stuck.
                    let patience: TimeInterval = step.installing ? 600 : 30
                    if step.installing { updatedAt = Date() }              // nor a launch that never came
                    if step.line != lastStep?.line { lastStep = (step.line, Date()) }
                    else if let since = lastStep?.since, Date().timeIntervalSince(since) >= patience {
                        gameStates[game.id] = nil
                        stuckLaunch = game
                        return
                    }
                } else { lastStep = nil; storeDialogs[game.id] = nil }
            } else { storeDialogs[game.id] = nil }
            if runningSince == nil, Date().timeIntervalSince(updatedAt ?? clicked) > 120 {  // Steam never started it
                gameStates[game.id] = nil
                await reportLaunchFailure(game, started: clicked)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        gameStates[game.id] = nil
        storeDialogs[game.id] = nil
        if let since = runningSince {
            let end = stoppedAt ?? Date()
            let ran = end.timeIntervalSince(since)
            // Crashed on the way up, died later, or hung: the "didn't start" sheet, not a play session that went well.
            let crashed = await sessionCrashed(game, started: clicked, ran: ran, sawWindow: sawWindow)
            record(game, start: since, end: end, crashed: crashed)
            if crashed { await reportLaunchFailure(game, started: clicked, secondsRunning: Int(ran)) }
        }
    }

    /// Shows an update Steam downloads before a launch like any download (progress on the game and in Downloads).
    private func followSteamUpdate(of game: Game) {
        guard downloads[game.id] == nil, game.store == .steam, !game.isNative else { return }
        downloads[game.id] = SteamDownload(phase: .queued, bytesDone: 0, bytesTotal: 0)
        trackDownloads()
    }

    /// `crashed`: the session is still play time, but not a report that the game ran (the failure is reported instead).
    func record(_ game: Game, start: Date, end: Date, crashed: Bool = false) {
        ClipRecorder.shared.gameEnded(game.id, title: game.title, crashed: crashed)
        ActiveSessionStore(paths: paths).remove(gameID: game.id)
        let duration = end.timeIntervalSince(start)
        guard duration > 5 else { return }
        let sessions = SessionStore(paths: paths)
        sessions.save(sessions.load() + [PlaySession(gameID: game.id, start: start, duration: duration)])
        cachedWeekStats = nil
        var data = library.userData[game.id] ?? UserGameData()
        // Play time counts every session; "runs on this Mac" only one that wasn't a crash or a black screen. A crash
        // marks the game only while nothing says it ran before (a library from before kept just the play time).
        if !crashed, duration > 60 { data.workedHere = true }
        else if crashed, data.workedHere == nil, data.playTime <= 60 { data.workedHere = false }
        data.playTime += duration
        data.lastPlayed = end
        library.userData[game.id] = data
        libraryStore.save(library)
        shareShaders(after: game, since: start)
        cookCellar(after: game)
        checkTuning(after: game)
        noteHDR(after: game, since: start)
        backUpSaves(after: game, since: start)
        summariseMods(after: game, since: start)
        if !crashed, let outcome = CompatibilityReport.outcome(playedSeconds: duration) { reportSession(game, outcome: outcome, seconds: duration, since: start) }
    }

    func showLog(for id: String) {
        if let url = lastLog[id] { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(paths.logs) }
    }

    func revealDataFolder() { NSWorkspace.shared.activateFileViewerSelecting([paths.home]) }

    // MARK: Helpers

    /// Runs one long task at a time and turns its error into a message for the window.
    private func perform(_ title: String, _ work: @escaping @MainActor () async throws -> Void) async {
        guard activity == nil else { return }
        activity = title
        progress = nil
        defer { activity = nil; progress = nil }
        do { try await work() } catch { errorMessage = error.localizedDescription }
    }
}

extension EnginePhase {
    var label: String {
        switch self {
        case .downloading: String(localized: "downloading")
        case .verifying: String(localized: "checking")
        case .extracting: String(localized: "unpacking")
        case .finishing: String(localized: "finishing")
        }
    }
}

/// A value set after a closure that reads it was made (a process's exit handler, before the process exists).
final class Holder<Value: AnyObject>: @unchecked Sendable {
    var value: Value?
}
