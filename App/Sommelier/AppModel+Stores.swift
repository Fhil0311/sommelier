// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os
import SommelierKit

/// An Epic or GOG download that Sommelier runs itself.
enum DirectInstall: Equatable {
    /// Waiting for another download from the same store to finish.
    case queued
    /// The store's helper is reading the game's file list.
    case preparing
    case downloading(Double)
    /// Stopped by the player, with what it had downloaded kept: resuming carries on from there.
    case paused(Double?)

    var fraction: Double? {
        switch self {
        case .downloading(let f): f
        case .paused(let f): f
        case .queued, .preparing: nil
        }
    }
}

extension AppModel.InstallState {
    /// How far along the install is, when that is known.
    var fraction: Double? {
        switch self {
        case .confirmInSteam: nil
        case .steam(let d): d.phase == .queued ? nil : d.fraction
        case .direct(let d): d.fraction
        case .launcher(_, let d): d.phase == .queued ? nil : d.fraction
        }
    }
}

/// Epic Games and GOG: stores Sommelier talks to itself through Legendary and gogdl, separate programs downloaded on
/// first use and checked against a pinned SHA-256. No Windows launcher is involved: games download straight to the
/// Mac and start in the store's own environment, which the first Play creates.
extension AppModel {
    static let directStores: [StoreKind] = [.epic, .gog]

    var epic: EpicProvider { EpicProvider(paths: paths, gamesFolder: chosenGamesFolder) }
    var gog: GOGProvider { GOGProvider(paths: paths, gamesFolder: chosenGamesFolder) }

    /// The "folder for new games" setting. Off until after the beta (decided 22.10): Steam only half follows it
    /// (its install window keeps its own choice) and the EA app, Ubisoft Connect and Battle.net not at all. While
    /// off, a folder chosen earlier is ignored and nothing is added to Steam.
    static let gamesFolderSetting = false
    var chosenGamesFolder: URL? { Self.gamesFolderSetting ? settings.gamesFolder : nil }

    /// Where new games go: the player's folder (an external drive, say) or `~/Games/Sommelier`.
    var gamesFolder: URL { chosenGamesFolder ?? paths.defaultGamesFolder }
    /// The chosen folder's Steam library.
    var steamLibraryFolder: URL { gamesFolder.appendingPathComponent("Steam", isDirectory: true) }
    /// False when the chosen folder is gone (its drive unplugged): nothing may be created in its place.
    var gamesFolderAvailable: Bool {
        guard let chosen = chosenGamesFolder else { return true }
        return FileManager.default.fileExists(atPath: chosen.path)
    }

    func chooseGamesFolder(_ folder: URL?) {
        settings.gamesFolder = folder
        Task { await addSteamLibraryIfStopped() }
    }

    /// Adds the chosen games folder to Steam's libraries, so Steam's install window offers it. Only while Steam
    /// is stopped: it rewrites its list as it quits. Called again before Steam starts, so a choice made while it
    /// ran is added then.
    func addSteamLibraryIfStopped() async {
        guard Self.gamesFolderSetting, gamesFolderAvailable, let engine = engine(for: .steam), isSteamInstalled else { return }
        if await WineRunner(paths: paths).isBottleActive(engine: engine, bottle: steam.bottle) { return }
        guard chosenGamesFolder != nil else {                    // back to the default: Steam's own library
            SteamLibraryFolders.preselect(steam.bottle.steamDirectory, in: steam.bottle)
            return
        }
        do { try SteamLibraryFolders.add(steamLibraryFolder, to: steam.bottle) }
        catch { Logger(subsystem: "gg.sommelier", category: "steam").error("Steam library not added: \(error.localizedDescription, privacy: .public)") }
        SteamLibraryFolders.preselect(steamLibraryFolder, in: steam.bottle)   // no choosing in Steam's install window
    }

    func isSignedIn(_ kind: StoreKind) -> Bool {
        switch kind {
        case .steam: isSteamInstalled
        case .epic: epic.isLegendaryInstalled && epic.isSignedIn
        case .gog: gog.isHelperInstalled && gog.isSignedIn
        default: isLauncherInstalled(kind)
        }
    }

    /// Whether an account is signed in to the store now (Steam's saved login, the launcher's), not just whether
    /// the store is set up: a store signed out of shows none of its games.
    func hasAccount(_ kind: StoreKind) -> Bool {
        switch kind {
        case .steam: isSteamInstalled && steamAccountName != nil
        case .epic, .gog: isSignedIn(kind)
        default: isLauncherInstalled(kind) && launcher(kind).isSignedIn
        }
    }

    /// The store whose signed-out page is open (its art runs behind the whole window, the sidebar glass over it).
    var signedOutStore: StoreKind? {
        guard accountsChecked, case .store(let kind)? = selection, !storesWithAccount.contains(kind),
              StorePoster.of(kind) != nil, games(in: kind).isEmpty else { return nil }
        return kind
    }

    /// A store's page is open and it isn't signed in to: there is nothing of it to search, so the page has no search field.
    var onSignedOutStorePage: Bool {
        guard accountsChecked, case .store(let kind)? = selection else { return false }
        return !storesWithAccount.contains(kind)
    }

    /// Any store signed in to: until then Home, All Games, Installed and the store pages ask to sign in.
    var hasAnyAccount: Bool { !storesWithAccount.isEmpty }
    /// Known to have no store signed in to (checked, and none).
    var signedOutEverywhere: Bool { accountsChecked && storesWithAccount.isEmpty }
    /// Home is the cover wall with the store cards until a game is installed (signed in or not); after that, the
    /// carousel and the rows of games.
    var homeShowsWall: Bool { accountsChecked && !visibleGames.contains(where: \.isInstalled) }

    /// The stores in the order the sign-in screens list them.
    static let signInOrder: [StoreKind] = [.steam, .epic, .gog, .ubisoft, .ea]

    /// "Sign In" for a store: Steam's window, Epic's or GOG's sign-in page, the launcher (set up first if needed).
    func signIn(_ kind: StoreKind) async {
        switch kind {
        case .steam: await openSteam()
        case .epic, .gog: await connect(kind)
        default: await openLauncher(kind)
        }
    }

    /// A sign-in under way: setting up, starting the store, or its sign-in window open. Sign In buttons are off.
    func isSigningIn(_ kind: StoreKind) -> Bool {
        storeActivity[kind] != nil || signIn == kind || waitingForSignIn.contains(kind) || (kind == .steam && steamLaunch != .idle)
    }

    /// The sign-in window is open and waiting (Steam, the EA app, Ubisoft Connect): the Sign In button turns into
    /// "Show <store>", which brings that window back when the player lost it behind other windows.
    func showsSignInWindow(_ kind: StoreKind) -> Bool { waitingForSignIn.contains(kind) && storeActivity[kind] == nil }

    /// The Sign In button's title: "Sign In" (or "Sign In…"), or "Show <store>" while its sign-in window waits.
    func signInTitle(_ kind: StoreKind, ellipsis: Bool = false) -> String {
        if showsSignInWindow(kind) { return String(localized: "Show \(kind.displayName)") }
        return ellipsis ? String(localized: "Sign In…") : String(localized: "Sign In")
    }

    /// Off only while there is nothing to click for: setting up, starting the store, or Epic's and GOG's page open.
    func signInDisabled(_ kind: StoreKind) -> Bool { isSigningIn(kind) && !showsSignInWindow(kind) }

    /// The Sign In button's action: sign in, or bring the waiting sign-in window forward.
    func signInOrShow(_ kind: StoreKind) async {
        if showsSignInWindow(kind) { await showLauncher(kind) } else { await signIn(kind) }
    }

    /// What "Sign In" will do, in a line under the button.
    func signInHint(_ kind: StoreKind) -> String {
        switch kind {
        case .steam:
            isSteamInstalled ? String(localized: "Sommelier opens Steam's sign-in window")
                             : String(localized: "Sommelier installs Steam and opens its sign-in window")
        case .epic: String(localized: "Sign in on Epic's website. Games download without a launcher")
        case .gog: String(localized: "Sign in on GOG's website. Games download without a launcher")
        default:
            isLauncherInstalled(kind) ? String(localized: "You sign in inside \(kind.displayName)")
                                      : String(localized: "Sommelier installs \(kind.displayName); you sign in inside it")
        }
    }

    /// The stores with an account signed in, worked out again after every refresh and sign-in or sign-out (the
    /// library's lists read it many times a second).
    func noteAccounts() {
        let now = Set(StoreKind.allCases.filter { hasAccount($0) })
        if now != storesWithAccount { storesWithAccount = now }
        if !accountsChecked { accountsChecked = true }
        sendUsage()
        countInstall()
    }

    // MARK: Account

    /// Downloads the store's helper the first time, then opens the store's own sign-in page.
    func connect(_ kind: StoreKind) async {
        guard Self.directStores.contains(kind), storeActivity[kind] == nil else { return }
        storeActivity[kind] = String(localized: "Setting up…")
        defer { storeActivity[kind] = nil }
        do {
            if kind == .epic, !epic.isLegendaryInstalled { try await epic.installLegendary() }
            if kind == .gog, !gog.isHelperInstalled { try await gog.installHelper() }
            signIn = kind
        } catch { errorMessage = error.localizedDescription }
    }

    /// The sign-in page handed over its one-time code: trade it for tokens and read the library.
    func finishSignIn(_ kind: StoreKind, code: String) async {
        signIn = nil
        storeActivity[kind] = String(localized: "Signing in…")
        do {
            if kind == .epic { try await epic.signIn(authorizationCode: code) } else { try await gog.signIn(code: code) }
            storeActivity[kind] = nil
            selection = .store(kind)
            await refreshStore(kind)
        } catch {
            storeActivity[kind] = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets the account. Installed games stay on disk, and play time comes back with the next sign-in.
    func signOut(_ kind: StoreKind) async {
        defer { noteAccounts() }                                   // the signed-out screens come back when it was the last
        if kind == .epic { try? await epic.signOut() } else if kind == .gog { gog.signOut() } else { return }
        library.games.removeAll { $0.store == kind }
        libraryStore.save(library)
        if selection == .store(kind) { selection = .home }
    }

    /// Reads the account's library from the store. Offline, the games from last time stay.
    func refreshStore(_ kind: StoreKind) async {
        defer { noteAccounts() }
        guard Self.directStores.contains(kind), isSignedIn(kind), storeActivity[kind] == nil else { return }
        storeActivity[kind] = String(localized: "Loading library…")
        defer { storeActivity[kind] = nil }
        do {
            let fresh = try await (kind == .epic ? epic.refresh() : gog.refresh())
            await loadCachedInfo(for: fresh)
            prefetchInfo(for: fresh)
            guard fresh != library.games.filter({ $0.store == kind }) else { return }
            library.games = LibraryStore.merged(cached: library.games, replacing: kind, with: fresh)
            libraryStore.save(library)
        } catch {
            if !library.games.contains(where: { $0.store == kind }) { errorMessage = error.localizedDescription }
        }
    }

    /// Store details, Steam Deck results included, for games not looked up yet: one a second, in the background, so
    /// the library shows ratings without opening every page and Steam's store isn't flooded.
    func prefetchInfo(for games: [Game]) {
        let previous = infoPrefetch
        infoPrefetch = Task {
            await previous?.value                                  // two stores refreshing: one after the other
            for game in games where info[game.id]?.deckChecked != true {
                if Task.isCancelled { return }
                let wasCached = info[game.id] != nil
                await loadInfo(for: game)
                if !wasCached || info[game.id]?.deckChecked == true { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    /// The store's website, to buy or claim games: they show up here at the next refresh.
    func openStoreWebsite(_ kind: StoreKind) {
        let url = kind == .gog ? URL(string: "https://www.gog.com/")! : URL(string: "https://store.epicgames.com/")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Install

    /// Downloads the game with the store's helper. One game per store at a time; the rest wait their turn.
    func installDirect(_ game: Game) {
        let game = library.games.first { $0.id == game.id } ?? game      // the latest the store said (its Mac version)
        // `directTasks` too: a stopped download's helper may still be winding down.
        guard directInstalls[game.id] == nil, directTasks[game.id] == nil, isSignedIn(game.store) else { return }
        guard gamesFolderAvailable else {
            errorMessage = String(localized: "The folder for new games isn't available. Connect its drive, or choose another folder in Settings.")
            return
        }
        let id = game.id, kind = game.store
        let epic = self.epic, gog = self.gog
        let folder = kind == .epic ? epic.gamesFolder : gog.gamesFolder
        let previous = installQueues[kind]
        directInstalls[id] = .queued
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }                // cancelled or paused while queued: already set
            directInstalls[id] = .preparing
            // What the folder held before this run. Only one download of a store runs at a time (the queue), so
            // what appears until it stops is this game's; a resumed download adds to what its earlier runs wrote.
            let before = Self.entries(of: folder)
            directBaselines[id] = before
            let progress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    // Not once paused or cancelled: the helper's last lines may still come in.
                    switch self.directInstalls[id] {
                    case .preparing?, .downloading?: self.directInstalls[id] = .downloading(fraction)
                    default: break
                    }
                }
            }
            do {
                if kind == .epic {
                    let native = installsNatively(game)
                    try await epic.install(game, native: native, onProgress: progress)
                    if native, let exe = await epic.installedExecutable(of: game),
                       !MachO.build(for: MachO.architectures(of: exe)).runsHere {
                        // A 32-bit Mac version: hasn't run since macOS 10.15. Take it out and get the Windows one.
                        try await epic.uninstall(game)
                        var legacy = settings.legacyMacBuilds ?? []
                        legacy.append(game.id)
                        settings.legacyMacBuilds = legacy
                        try await epic.install(game, native: false, onProgress: progress)
                    }
                }
                else { try await gog.install(game, onProgress: progress) }
            } catch {
                if Task.isCancelled, directPausing.remove(id) != nil {
                    // Paused: the files stay, and installing again resumes (legendary and GOG's helper both do).
                    directOwned[id, default: []].formUnion(Self.entries(of: folder).subtracting(before))
                    directBaselines[id] = nil
                    directInstalls[id] = .paused(directInstalls[id]?.fraction)
                    directTasks[id] = nil
                    return
                }
                if Task.isCancelled {                                  // nothing of it stays
                    Self.removeEntries(of: folder, addedSince: before)
                    Self.remove(directOwned[id] ?? [], in: folder)
                }
                else { errorMessage = error.localizedDescription }
            }
            directInstalls[id] = nil
            directTasks[id] = nil
            directBaselines[id] = nil
            directOwned[id] = nil
            await refreshStore(kind)
            if !Task.isCancelled {
                noteInstallFinished(id)
                if let installed = library.games.first(where: { $0.id == id }), !installed.isNative { await prepareRuntime(for: installed) }
            }
        }
        directTasks[id] = task
        installQueues[kind] = task
    }

    /// Stops a download and deletes what it wrote.
    func cancelDirectInstall(_ game: Game) {
        if case .paused = directInstalls[game.id], directTasks[game.id] == nil {
            // Nothing runs: delete what the paused download left, as a cancelled one would.
            let folder = game.store == .epic ? epic.gamesFolder : gog.gamesFolder
            Self.remove(directOwned[game.id] ?? [], in: folder)       // only what this game's own runs wrote
            directInstalls[game.id] = nil
            directBaselines[game.id] = nil
            directOwned[game.id] = nil
            return
        }
        directPausing.remove(game.id)
        directTasks[game.id]?.cancel()
        let wasQueued = directInstalls[game.id] == .queued
        directInstalls[game.id] = nil                           // gone at once; the task deletes the files as it stops
        if wasQueued {
            directInstalls[game.id] = nil
            directTasks[game.id] = nil
            directBaselines[game.id] = nil
            directOwned[game.id] = nil
        }
    }

    /// Stops a download and keeps what it wrote, for `resumeDirectInstall`.
    func pauseDirectInstall(_ game: Game) {
        guard let state = directInstalls[game.id] else { return }
        if state == .queued {                                   // not started: just leaves the queue
            directTasks[game.id]?.cancel()
            directTasks[game.id] = nil
            directInstalls[game.id] = .paused(nil)
            return
        }
        if case .paused = state { return }
        guard directTasks[game.id] != nil else { return }
        directPausing.insert(game.id)
        directInstalls[game.id] = .paused(state.fraction)      // shown at once; the helper stops in the background
        directTasks[game.id]?.cancel()
    }

    /// Starts a paused download again; the store's helper carries on from what is on disk.
    func resumeDirectInstall(_ game: Game) {
        guard case .paused = directInstalls[game.id], directTasks[game.id] == nil else { return }
        directInstalls[game.id] = nil
        installDirect(game)
    }

    nonisolated static func entries(of folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Deletes these names from the store's games folder, and nothing outside it.
    nonisolated static func remove(_ names: Set<String>, in folder: URL) {
        for name in names where !name.isEmpty && !name.contains("/") && name != ".." && name != "." {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Deletes what appeared in the store's games folder since `before`, and nothing outside it.
    nonisolated static func removeEntries(of folder: URL, addedSince before: Set<String>) {
        for name in entries(of: folder).subtracting(before) where !name.contains("/") && name != ".." && name != "." {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Uninstall

    /// After the user confirms: the store's helper deletes the game's files.
    func confirmUninstall(_ game: Game) async {
        pendingUninstall = nil
        guard uninstalls[game.id] == nil, Self.directStores.contains(game.store) else { return }
        uninstalls[game.id] = .removing
        do {
            if game.store == .epic {
                try await epic.uninstall(game)
            } else {
                let gog = self.gog
                try await Task.detached { try gog.uninstall(game) }.value
            }
            if let i = library.games.firstIndex(where: { $0.id == game.id }) {
                library.games[i].isInstalled = false
                library.games[i].installPath = nil
                library.games[i].sizeOnDisk = nil
                libraryStore.save(library)
            }
        } catch { errorMessage = error.localizedDescription }
        uninstalls[game.id] = nil
        await refreshStore(game.store)
    }

    // MARK: Native Mac versions

    /// Starts a game installed as a Mac app: through Legendary for Epic (it fetches the sign-in token first), or
    /// through Steam for Mac. The game isn't Sommelier's child, so it's followed by its process.
    func playNative(_ game: Game) async {
        guard let folder = game.installPath else { return }
        gameStates[game.id] = .starting(since: Date())
        var epicProcess: RunningProcess?
        if game.store == .epic, !(await syncSavesBeforePlay(game)) { gameStates[game.id] = nil; return }
        do {
            switch game.store {
            case .epic:
                let process = try epic.playNative(game, arguments: profile(for: game).extraArguments)
                lastLog[game.id] = process.logURL
                epicProcess = process
            case .steam:
                // With a mod loader in place (SMAPI beside Stardew Valley) its program starts instead of the game.
                if let loader = modRedirect(for: game) { try startNativeRedirect(loader, for: game) }
                else { NSWorkspace.shared.open(SteamMacClient.url("rungameid", appID: game.storeID)) }
            default:
                gameStates[game.id] = nil
                return
            }
        } catch {
            gameStates[game.id] = nil
            errorMessage = error.localizedDescription
            return
        }
        let started = Date()
        var playingSince: Date?
        var seenPid: Int32?
        var seconds = 0
        var retries = 0
        while gameStates[game.id] != nil {
            try? await Task.sleep(for: .seconds(1))
            seconds += 1
            // Epic's sign-in token didn't come (its server answered too slowly: a poor connection, a VPN): legendary
            // ends with an error before it starts the game. Asked again up to twice, as the player would by clicking.
            if let process = epicProcess, !process.isRunning, seenPid == nil, retries < 2, game.store == .epic,
               Self.epicNetworkFailure(in: process.logURL) {
                retries += 1
                guard let again = try? epic.playNative(game, arguments: profile(for: game).extraArguments) else { break }
                lastLog[game.id] = again.logURL
                epicProcess = again
                continue
            }
            let pid = await Task.detached { NativeProcesses.pid(runningFrom: folder) }.value
            if let pid, seenPid == nil {
                seenPid = pid
                playingSince = Date()
                gameStates[game.id] = .playing(since: playingSince!)
                giveFocus(to: pid)
            }
            if pid == nil, seenPid != nil { break }                                   // the game quit
            if seenPid == nil, seconds > 120 {                                        // it never started
                gameStates[game.id] = nil
                await reportLaunchFailure(game, started: started)
                return
            }
        }
        gameStates[game.id] = nil
        if let playingSince {
            record(game, start: playingSince, end: Date())
            if game.store == .epic { await syncSavesAfterPlay(game) }
        }
    }

    /// Whether legendary's log ends in a network error before the game began (a timeout asking Epic for the token).
    nonisolated static func epicNetworkFailure(in log: URL) -> Bool {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return text.contains("Exit ") && text.contains("status=1")
            && (text.contains("ReadTimeout") || text.contains("ConnectTimeout") || text.contains("ConnectionError")
                || text.contains("Max retries exceeded") || text.contains("Connection aborted"))
    }

    /// Asks Steam for Mac to uninstall the game: it shows its own confirmation and deletes the files.
    func uninstallNativeSteam(_ game: Game) {
        guard uninstalls[game.id] == nil else { return }
        NSWorkspace.shared.open(SteamMacClient.url("uninstall", appID: game.storeID))
        uninstalls[game.id] = .confirmInSteam
        let appID = game.storeID
        Task {
            let started = Date()
            while uninstalls[game.id] != nil {
                try? await Task.sleep(for: .seconds(1))
                let present = await Task.detached { SteamMacClient.hasManifest(appID: appID) }.value
                if !present { uninstalls[game.id] = nil; await refreshLibrary(); return }
                if Date().timeIntervalSince(started) > 600 { uninstalls[game.id] = nil }
            }
        }
    }

    // MARK: Play

    func playDirect(_ game: Game, engine: Engine) async {
        let kind = game.store
        gameStates[game.id] = .starting(since: Date())
        do {
            // The store's environment is made on the first Play, and made again if it was reset.
            try await BottleManager(paths: paths).prepareForPlay(kind, engine: engine)
            if settings.bottleEngines?[kind.rawValue] == nil {
                var engines = settings.bottleEngines ?? [:]
                engines[kind.rawValue] = engine.version
                settings.bottleEngines = engines
            }
            guard await syncSavesBeforePlay(game) else { gameStates[game.id] = nil; return }   // a conflict asks first
            await prepareRuntime(for: game)                        // done after the install; here when that didn't finish
            var profile = profile(for: game)
            profile.backend = await resolvedBackend(for: game, profile: profile, engine: engine)
            await applyRetina(profile.retina, bottleKind: kind.bottleKind, engine: engine)
            lastLaunchBackend[game.id] = profile.backend
            profile.turbo = turboApplies(to: game, backend: profile.backend)
            profile.forGame = true                    // the game hears the microphone (macOS asks if it opens it)
            profile.hdr = true                    // the HDR switch is off for now (22.10): games see HDR; a recipe can hide it
            #if !DEBUG
            profile.performanceHUD = false        // Apple's Metal HUD is a debug-build tool only (22.10)
            #endif
        #if !DEBUG
        profile.performanceHUD = false        // Apple's Metal HUD is a debug-build tool only (22.10)
        #endif
        profile.hdr = true                    // the HDR switch is off for now (22.10): games see HDR; a recipe can hide it
        #if !DEBUG
        profile.performanceHUD = false        // Apple's Metal HUD is a debug-build tool only (22.10)
        #endif
            lastLaunchTurbo[game.id] = profile.turbo
            await decant(game, backend: profile.backend)
            await prepareCellar(game, backend: profile.backend)
            launchLogMarks[game.id] = logMark(for: game)
            let executable = kind == .epic ? await epic.launchExecutable(of: game) : nil
            let process = try (kind == .epic ? epic.play(game, engine: engine, profile: profile, executable: executable)
                                             : gog.play(game, engine: engine, profile: profile))
            lastLog[game.id] = process.logURL
            await followDirect(game, engine: engine, launcher: process)
        } catch {
            gameStates[game.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Playing once the game's window is up (or after 30 s: some games show none for a while). Legendary first asks
    /// Epic for a sign-in token (a few seconds), then hands the game to Wine and exits, so the game has ended when
    /// the launcher is done and the game's environment, having run, has nothing left running.
    private func followDirect(_ game: Game, engine: Engine, launcher: RunningProcess) async {
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        let engines = paths.engines.path
        let marker = game.installPath?.lastPathComponent ?? game.title
        let runner = WineRunner(paths: paths)
        let started = Date()
        var playing = false
        var sawWindow = false
        var seconds = 0
        var environmentRan = false              // the environment has run something
        var goneFor = 0
        var deadFor = 0                         // checks since the launcher ended with nothing of the game running
        while gameStates[game.id] != nil {
            try? await Task.sleep(for: .seconds(1))
            seconds += 1
            if !sawWindow {
                // Until the game's window shows (also after 30 s of a launcher or a long loading screen): then to the front.
                let owner = await Task.detached { WineWindows.gameWindowOwner(enginesFolder: engines, marker: marker) }.value
                if let owner { giveFocus(to: owner); sawWindow = true }
                if !playing, owner != nil || seconds > 30 { playing = true; gameStates[game.id] = .playing(since: started) }
            }
            // Once its window has shown, nothing left running from the game's folder for 3 seconds: it quit (the
            // environment winding down after it takes longer).
            if sawWindow {
                let alive = await Task.detached { WineWindows.gameProcess(enginesFolder: engines, folderName: marker) != nil }.value
                goneFor = alive ? 0 : goneFor + 1
                if goneFor >= 3 { break }
            }
            guard !launcher.isRunning, seconds % 3 == 0 else { continue }
            // The launcher is done and nothing from the game's folder runs: the game never started (legendary
            // failed, for one) or has quit. The environment alone (Wine's services) says nothing about the game.
            if !sawWindow {
                let alive = await Task.detached { WineWindows.gameProcess(enginesFolder: engines, folderName: marker) != nil }.value
                if alive { environmentRan = true; deadFor = 0 } else { deadFor += 1 }
                if deadFor >= 2, seconds > 6 { break }
            }
            let active = await runner.isBottleActive(engine: engine, bottle: bottle)
            if active { environmentRan = true }
            if !active, environmentRan || seconds > 90 { break }
        }
        gameStates[game.id] = nil
        if playing {
            let ran = Date().timeIntervalSince(started)
            let crashed = await sessionCrashed(game, started: started, ran: ran, sawWindow: sawWindow)
            record(game, start: started, end: Date(), crashed: crashed)
            if crashed { await reportLaunchFailure(game, started: started, secondsRunning: Int(ran)) } else { await syncSavesAfterPlay(game) }
        } else {
            await reportLaunchFailure(game, started: started, secondsRunning: seconds)
        }
    }
}

// MARK: Pause and resume

extension AppModel {
    /// Whether the download can be paused now (Epic, GOG and Steam in its environment; not Steam for Mac or the
    /// publishers' launchers, whose own windows do it).
    func canPause(_ game: Game, _ state: InstallState) -> Bool {
        switch state {
        case .direct(let d): if case .paused = d { false } else { true }
        case .steam(let d): !isSteamForMac(game) && (d.phase == .downloading || d.phase == .queued)
        case .confirmInSteam, .launcher: false
        }
    }

    func canResume(_ game: Game, _ state: InstallState) -> Bool {
        switch state {
        case .direct(let d): if case .paused = d { true } else { false }
        case .steam(let d): !isSteamForMac(game) && d.phase == .paused
        case .confirmInSteam, .launcher: false
        }
    }

    private func isSteamForMac(_ game: Game) -> Bool { nativeInstalls.contains(game.id) || game.isNative }

    func pauseDownload(_ game: Game) async {
        if Self.directStores.contains(game.store) { pauseDirectInstall(game); return }
        guard game.store == .steam else { return }
        await steamDownload(game, pause: true)
    }

    func resumeDownload(_ game: Game) async {
        if Self.directStores.contains(game.store) { resumeDirectInstall(game); return }
        guard game.store == .steam else { return }
        await steamDownload(game, pause: false)
    }

    /// Through Steam's own Downloads page functions (`SteamClientBridge`); a Steam started without the DevTools
    /// switch (by an older Sommelier) can't be reached, so its Downloads page opens for the player to click there.
    private func steamDownload(_ game: Game, pause: Bool) async {
        let bridge = SteamClientBridge()
        let done = pause ? await bridge.pause(appID: game.storeID) : await bridge.resume(appID: game.storeID)
        if done {
            steamPauseRequests[game.id] = (pause, Date())
        } else {
            await openSteamDownloads(for: game)
        }
    }

    /// Steam's state with a recent click on top, until Steam's files catch up (or 15 seconds pass).
    func asRequested(_ download: SteamDownload, _ id: String) -> SteamDownload {
        guard let request = steamPauseRequests[id], Date().timeIntervalSince(request.at) < 15 else { return download }
        if request.paused, download.phase == .downloading || download.phase == .queued {
            return SteamDownload(phase: .paused, bytesDone: download.bytesDone, bytesTotal: download.bytesTotal)
        }
        if !request.paused, download.phase == .paused {
            return SteamDownload(phase: .downloading, bytesDone: download.bytesDone, bytesTotal: download.bytesTotal)
        }
        return download
    }
}
