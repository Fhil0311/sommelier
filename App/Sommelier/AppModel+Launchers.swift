// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os
import SommelierKit

/// EA app, Ubisoft Connect and Battle.net: stores whose own Windows launcher runs in its environment, like Steam.
/// Sommelier sets the launcher up (its official installer into a fresh environment), opens it for the user to sign
/// in and install games there, lists what it installed, and starts games through it.
extension AppModel {
    /// Offered launchers. The EA app needs engine 2.2.1 (its Chromium draws with GDI into a child of a Qt window
    /// whose Metal view covered it; the engine's Mac driver now shows such children above the view). Battle.net's
    /// page process needs Wine to report copy-on-write pages as Windows does (`LauncherStore.battleNetEnvironment`).
    static let launcherStores: [StoreKind] = [.ubisoft, .ea, .battlenet]

    func launcher(_ kind: StoreKind) -> LauncherStore { LauncherStore(kind: kind, paths: paths) }

    func isLauncherInstalled(_ kind: StoreKind) -> Bool { Self.launcherStores.contains(kind) && launcher(kind).isLauncherInstalled }

    func isLauncherSignedIn(_ kind: StoreKind) -> Bool { isLauncherInstalled(kind) && launcher(kind).isSignedIn }

    /// Installs the launcher into its environment and opens it. The installers are the stores' own.
    func setUpLauncher(_ kind: StoreKind) async {
        guard Self.launcherStores.contains(kind), storeActivity[kind] == nil, let engine = activeEngine else { return }
        storeActivity[kind] = String(localized: "Setting up…")
        activity = String(localized: "Installing \(kind.displayName)…")
        defer { storeActivity[kind] = nil; activity = nil }
        do {
            try await launcher(kind).installLauncher(engine: engine)
            var engines = settings.bottleEngines ?? [:]
            engines[kind.bottleKind.rawValue] = engine.version
            settings.bottleEngines = engines
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        storeActivity[kind] = nil
        activity = nil
        await openLauncher(kind)
    }

    /// Opens the launcher's window (starting it if needed) and brings it to the front. A launcher can be running with
    /// no window: closed to its tray icon, or hung while starting (seen with the EA app, its UI thread stalled before
    /// any window). Starting it once more asks a running one to show its window, as it does on Windows; if that
    /// brings nothing either, it is stopped and started afresh, unless one of its games runs or downloads.
    func openLauncher(_ kind: StoreKind) async {
        guard let engine = engine(for: kind.bottleKind) else { return }
        guard isLauncherInstalled(kind) else { await setUpLauncher(kind); return }
        // Already opening: a second click while the window is on its way (Battle.net's takes ~10 s) would find no
        // window yet, take the launcher for hung and restart it, closing the window that was just coming up.
        guard storeActivity[kind] == nil else { return }
        let key = kind.rawValue, bottle = launcher(kind).bottle
        launchersStartedForGames.remove(kind)                       // opened on purpose: it stays open
        storeActivity[kind] = String(localized: "Opening…")
        defer { storeActivity[kind] = nil }
        if WineWindows.hasVisibleWindow(enginesFolder: paths.engines.path, bottle: bottle.url) {
            await bringSteamForward(bottle: bottle.url)
            return
        }
        let active = await WineRunner(paths: paths).isBottleActive(engine: engine, bottle: bottle)
        let wasRunning = running[key] != nil || active
        guard await startLauncher(kind, engine: engine) else { return }    // a running one hands over and quits
        var shown = await waitForLauncherWindow(kind, seconds: wasRunning ? 20 : 60)
        // Still no window: hung, or it was quitting when asked (Ubisoft Connect quits a few seconds after its window
        // closes). Started again from scratch.
        if !shown, !isPlaying(from: kind), !launcherDownloads.keys.contains(where: { $0.hasPrefix(key + ":") }) {
            Logger(subsystem: "gg.sommelier", category: "launcher").info("\(key, privacy: .public): no window, starting it again")
            await stopLauncher(kind, engine: engine, patience: 5)
            guard await startLauncher(kind, engine: engine) else { return }
            shown = await waitForLauncherWindow(kind, seconds: 60)
        }
        if shown { await bringSteamForward(bottle: bottle.url) }          // the launcher's window, not another store's
        watchLauncher(kind)
        if !isLauncherSignedIn(kind) { awaitLauncherSignIn(kind) }
    }

    /// Starts the launcher's program: the launcher itself when none runs, or a second copy that asks the running one
    /// to show its window. False (with the error shown) when it couldn't be started.
    private func startLauncher(_ kind: StoreKind, engine: Engine) async -> Bool {
        let key = kind.rawValue, bottle = launcher(kind).bottle
        await prepareDock(kind.bottleKind, engine: engine)
        do {
            // Started with the graphics most games want (as Steam is), so games share it; CEF draws through it too.
            var profile = LaunchProfile()
            if engine.supports(.dxmt) { profile.backend = .dxmt }
            if !(await WineRunner(paths: paths).isBottleActive(engine: engine, bottle: bottle)) {
                setLauncherGraphics(kind, Self.graphicsKey(profile))
            }
            let process = try launcher(kind).launchLauncher(engine: engine, profile: profile) { _ in
                // A second copy quits at once; the launcher it handed over to goes on.
                Task { @MainActor in if self.running[key]?.isRunning == false { self.running[key] = nil } }
            }
            if running[key] == nil {
                running[key] = process
                lastLog[key] = process.logURL
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Waits up to `seconds` for a window of the launcher's environment; true once one is on screen.
    private func waitForLauncherWindow(_ kind: StoreKind, seconds: Double) async -> Bool {
        let bottle = launcher(kind).bottle.url, deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if WineWindows.hasVisibleWindow(enginesFolder: paths.engines.path, bottle: bottle) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// The user is signing in inside the launcher: when they have, Sommelier comes back to the front with the
    /// store's page updated (as it does after Steam's dialogs), instead of leaving them in the launcher.
    private func awaitLauncherSignIn(_ kind: StoreKind) {
        guard signInWatchers[kind] == nil else { return }
        waitingForSignIn.insert(kind)
        signInWatchers[kind] = Task {
            defer { signInWatchers[kind] = nil; waitingForSignIn.remove(kind) }
            let started = Date()
            while !Task.isCancelled, Date().timeIntervalSince(started) < 900 {
                try? await Task.sleep(for: .seconds(2))
                if isLauncherSignedIn(kind) {
                    try? await Task.sleep(for: .seconds(2))           // let the launcher settle after signing in
                    await refreshLauncher(kind)
                    bringSommelierForward()
                    return
                }
                // The launcher quit: its environment has nothing running. (Its sign-in window isn't always one the
                // window check sees, so that alone would give up while the player is still signing in.)
                if running[kind.rawValue] == nil, !WineWindows.hasVisibleWindow(enginesFolder: paths.engines.path, bottle: launcher(kind).bottle.url) {
                    guard let engine = engine(for: kind.bottleKind),
                          await WineRunner(paths: paths).isBottleActive(engine: engine, bottle: launcher(kind).bottle) else { return }
                }
            }
        }
    }

    #if DEBUG
    /// Starts a launcher straight from its environment, however it is configured, for trying settings on it.
    func debugOpenLauncher(_ kind: StoreKind) async {
        guard let engine = engine(for: kind.bottleKind), launcher(kind).isLauncherInstalled else { errorMessage = "\(kind.displayName) isn't set up"; return }
        var profile = LaunchProfile()
        let env = ProcessInfo.processInfo.environment
        profile.backend = env["SOMMELIER_DEBUG_LAUNCHER_BACKEND"].flatMap(GraphicsBackend.init(rawValue:)) ?? (engine.supports(.dxmt) ? .dxmt : .auto)
        for pair in (env["SOMMELIER_DEBUG_LAUNCHER_ENV"] ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { profile.extraEnvironment[parts[0]] = parts[1] }
        }
        do {
            let arguments = (env["SOMMELIER_DEBUG_LAUNCHER_ARGS"] ?? "").split(separator: " ").map(String.init)
            let process = try launcher(kind).launchLauncher(engine: engine, profile: profile, arguments: arguments) { _ in }
            running[kind.rawValue] = process
            lastLog[kind.rawValue] = process.logURL
        } catch { errorMessage = error.localizedDescription }
    }
    #endif

    /// Install in a launcher's store: the launcher opens on the game's install page (Ubisoft Connect) or its main
    /// window, and the game's card says to confirm there until the download shows up.
    func installThroughLauncher(_ game: Game) async {
        let kind = game.store
        guard isLauncherInstalled(kind) else { await setUpLauncher(kind); return }
        guard let engine = engine(for: kind.bottleKind) else { return }
        // Bought on Steam: Ubisoft Connect would try to set up Steam inside its own environment. The Steam copy
        // installs through Sommelier's Steam instead.
        let store = launcher(kind)
        if kind == .ubisoft, let app = await Task.detached(operation: { store.ubisoftSteamActivations()[game.storeID] }).value {
            if let steamCopy = library.games.first(where: { $0.store == .steam && $0.storeID == app }) {
                await install(steamCopy, confirmed: true)
            } else {
                errorMessage = String(localized: "\(game.title) was bought on Steam. Install it from your Steam library.")
            }
            return
        }
        // Battle.net shows no download Sommelier could follow, so the card isn't held at "Confirm in…": its window
        // comes up, then the running Battle.net is asked for the game's page, which has the Install button.
        if kind == .battlenet {
            await openLauncher(kind)
            var profile = LaunchProfile()
            if engine.supports(.dxmt) { profile.backend = .dxmt }
            do { try store.openInstall(game, engine: engine, profile: profile) } catch { errorMessage = error.localizedDescription }
            watchLauncher(kind)
            return
        }
        launcherInstallRequests[game.id] = Date()
        watchLauncher(kind)
        guard kind == .ubisoft else { await openLauncher(kind); return }
        // Ubisoft Connect takes a while to show its install window, and may show it behind Sommelier: the card says
        // it's opening until a new launcher window is up, then brings that window forward.
        let baseline = await Task.detached { [engines = paths.engines.path] in WineWindows.newestWindow(enginesFolder: engines)?.number ?? -1 }.value
        launcherInstallOpening.insert(game.id)
        defer { launcherInstallOpening.remove(game.id) }
        do {
            var profile = LaunchProfile()
            if engine.supports(.dxmt) { profile.backend = .dxmt }
            let key = kind.rawValue
            let process = try launcher(kind).openInstall(game, engine: engine, profile: profile) { _ in
                Task { @MainActor in if self.running[key]?.isRunning == false { self.running[key] = nil } }
            }
            if running[key] == nil { running[key] = process }
        } catch {
            launcherInstallRequests[game.id] = nil
            errorMessage = error.localizedDescription
            return
        }
        let window = await bringSteamForward(newerThan: baseline, waitUpTo: 45)    // the install window, once it's up
        followInstallRequest(game, window: window)
    }

    /// Drops the "Confirm in …" state when it can no longer happen: the launcher quit, or its install window
    /// closed without a download starting. A started download takes over on its own (refreshLauncher).
    private func followInstallRequest(_ game: Game, window: Int?) {
        let kind = game.store
        let engines = paths.engines.path
        let launcherFolder = launcher(kind).launcherExecutable.deletingLastPathComponent().lastPathComponent
        Task {
            var goneSince: Date?
            while launcherInstallRequests[game.id] != nil {
                try? await Task.sleep(for: .seconds(2))
                let (launcherRunning, windowOpen) = await Task.detached {
                    (WineWindows.gameProcess(enginesFolder: engines, folderName: launcherFolder) != nil,
                     window.map(WineWindows.windowExists) ?? true)
                }.value
                if launcherRunning, windowOpen { goneSince = nil; continue }
                // A confirmed install may close its window just before the download shows: give it a few seconds.
                if goneSince == nil { goneSince = Date(); await refreshLauncher(kind); continue }
                if Date().timeIntervalSince(goneSince!) >= 6 {
                    await refreshLauncher(kind)
                    launcherInstallRequests[game.id] = nil
                }
            }
        }
    }

    /// Games the launcher has installed, into the library.
    func refreshLauncher(_ kind: StoreKind) async {
        defer { noteAccounts() }
        guard isLauncherInstalled(kind) else { return }
        let store = launcher(kind)
        var downloads = await Task.detached { store.downloads() }.value
        let prefix = "\(kind.rawValue):"
        if kind == .ubisoft { downloads = markStalledDownloads(downloads) }
        let others = launcherDownloads.filter { !$0.key.hasPrefix(prefix) }
        if others.merging(downloads, uniquingKeysWith: { _, new in new }) != launcherDownloads {
            launcherDownloads = others.merging(downloads, uniquingKeysWith: { _, new in new })
        }
        let fresh = (try? await Task.detached { try await store.refresh() }.value) ?? []
        // Install requests the launcher has taken up (a download of its own) or finished.
        for id in launcherInstallRequests.keys where id.hasPrefix(prefix)
            && (downloads[id] != nil || fresh.contains { $0.id == id && $0.isInstalled }) {
            launcherInstallRequests[id] = nil
        }
        await loadCachedInfo(for: fresh)
        prefetchInfo(for: fresh)
        guard fresh != library.games.filter({ $0.store == kind }) else { return }
        library.games = LibraryStore.merged(cached: library.games, replacing: kind, with: fresh)
        libraryStore.save(library)
    }

    /// A Ubisoft download whose progress hasn't moved for 15 seconds shows as paused (paused in Ubisoft Connect, or
    /// waiting for the network). While any runs, the store is checked every 5 seconds: a paused download writes
    /// nothing, so no file change would tell.
    private func markStalledDownloads(_ downloads: [String: LauncherDownload]) -> [String: LauncherDownload] {
        let now = Date()
        var result = downloads
        for (id, download) in downloads {
            let fraction = download.fraction ?? 0
            if let seen = launcherProgressSeen[id], seen.fraction == fraction {
                if now.timeIntervalSince(seen.moved) >= 15 { result[id]?.phase = .paused }
            } else {
                launcherProgressSeen[id] = (fraction, now)
            }
        }
        launcherProgressSeen = launcherProgressSeen.filter { downloads[$0.key] != nil }
        if !downloads.isEmpty, launcherDownloadTicker == nil {
            launcherDownloadTicker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await refreshLauncher(.ubisoft)
                    if !launcherDownloads.keys.contains(where: { $0.hasPrefix("ubisoft:") }) { break }
                }
                launcherDownloadTicker = nil
            }
        }
        return result
    }

    /// Refreshes when the launcher installs or removes a game.
    func watchLauncher(_ kind: StoreKind) {
        guard launcherWatchers[kind] == nil, isLauncherInstalled(kind) else { return }
        let bottle = launcher(kind).bottle
        let folders: [URL]
        switch kind {
        case .ea: folders = [bottle.driveC.appendingPathComponent("Program Files/EA Games")]
        case .ubisoft:
            folders = [bottle.driveC.appendingPathComponent("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games")]
                + (GOGSaveLocations.userFolder(in: bottle).map { [$0.appendingPathComponent("AppData/Local/Ubisoft Game Launcher/cache/configuration")] } ?? [])
        default: folders = [bottle.driveC.appendingPathComponent("Program Files (x86)")]
        }
        for folder in folders { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        // The whole environment is watched for its registry (`system.reg`, `user.reg`: installs and sign-ins) only:
        // a running launcher and its games write elsewhere in it all the time.
        let root = bottle.url
        launcherWatchers[kind] = folders.map { folder in
            DirectoryWatcher(directory: folder, latency: 3) { Task { @MainActor in await self.refreshLauncher(kind) } }
        } + [DirectoryWatcher(directory: root, latency: 3,
                              relevant: { $0.hasSuffix(".reg") && DirectoryWatcher.isDirectlyIn(root, $0) }) {
            Task { @MainActor in await self.refreshLauncher(kind) }
        }]
    }

    /// Starts a game through its launcher and follows it by its window, as Steam games are followed.
    func playLauncher(_ game: Game, engine: Engine) async {
        let kind = game.store
        guard isLauncherInstalled(kind) else { errorMessage = String(localized: "\(kind.displayName) isn't set up yet."); return }
        gameStates[game.id] = .starting(since: Date())
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
        lastLaunchTurbo[game.id] = profile.turbo
        // The launcher starts the game itself and passes it no arguments of ours: the engine adds them to the game's
        // programs (`ExecutableArguments`), and the launcher's own command line stays clean.
        if engine.supportsProgramArguments, let folder = game.installPath {
            let bottle = launcher(kind).bottle, arguments = profile.extraArguments
            let table = ExecutableArguments(paths: paths)
            await Task.detached(priority: .utility) {
                let programs = ExecutableArguments.programs(in: folder).map { bottle.windowsPath(of: $0) }
                table.set(folder: bottle.windowsPath(of: folder), programs: programs, arguments: arguments)
            }.value
            profile.extraArguments = []
        }
        if kind == .ea {                                            // the EA app's overlay breaks games under Wine
            let bottle = launcher(kind).bottle
            await Task.detached { EAAppSetup.disableOverlay(in: bottle) }.value
        }
        await WineD3DFallback(paths: paths).update(kind.bottleKind, engine: engine)
        await prepareDock(kind.bottleKind, engine: engine)
        await decant(game, backend: profile.backend)
        await prepareCellar(game, backend: profile.backend)
        let started = Date()
        let runner = WineRunner(paths: paths), bottle = launcher(kind).bottle
        // Games started through a running launcher get its environment, not their own: when the launcher runs with
        // other graphics (Turbo, HDR…) and isn't downloading anything, it restarts with this game's.
        let key = Self.graphicsKey(profile)
        if engine.supportsProgramEnvironment, let folder = game.installPath {
            // The game's own graphics by folder: the launcher keeps running as it is.
            await setProgramEnvironment(folder: folder, bottle: bottle, profile: profile, engine: engine)
        } else if await runner.isBottleActive(engine: engine, bottle: bottle), launcherGraphics(kind) != key,
           !library.games.contains(where: { $0.store == kind && $0.id != game.id && installState(of: $0) != nil }) {
            await stopLauncher(kind, engine: engine)
        }
        if !(await runner.isBottleActive(engine: engine, bottle: bottle)) {
            launchersStartedForGames.insert(kind)                   // this Play starts the launcher
            setLauncherGraphics(kind, key)
        }
        launchLogMarks[game.id] = logMark(for: game)
        do {
            let process = try launcher(kind).play(game, engine: engine, profile: profile) { _ in }
            lastLog[game.id] = process.logURL
            if running[kind.rawValue] == nil { running[kind.rawValue] = process }
        } catch {
            gameStates[game.id] = nil
            errorMessage = error.localizedDescription
            return
        }
        let marker = game.installPath?.lastPathComponent ?? game.title
        let launcherMarker = launcher(kind).launcherExecutable.lastPathComponent.lowercased()
        let engines = paths.engines.path
        var playingSince: Date?
        var sawWindow = false
        var gone = 0
        // The launcher's own window on screen while the game hasn't started (its sign-in, an update, a question):
        // after 15 seconds it is taken for the launcher waiting on the player, brought forward once and shown on
        // the Play button; the time it waits doesn't count against the launch.
        var launcherWindowSince: Date?
        var waited: TimeInterval = 0
        while gameStates[game.id] != nil {
            try? await Task.sleep(for: .seconds(1))
            let owner = await Task.detached { WineWindows.gameWindowOwner(enginesFolder: engines, marker: marker) }.value
            if let owner {
                gone = 0
                storeDialogs[game.id] = nil
                if !sawWindow { sawWindow = true; playingSince = Date(); gameStates[game.id] = .playing(since: playingSince!); giveFocus(to: owner) }
            } else if sawWindow {
                gone += 1
                if gone >= 3 { break }                                       // the game's window has been gone a while
            } else {
                let launcherWindow = await Task.detached {
                    WineWindows.windowOwner(enginesFolder: engines) { $0.lowercased().contains(launcherMarker) }
                }.value
                if let launcherWindow {
                    if launcherWindowSince == nil { launcherWindowSince = Date() }
                    if storeDialogs[game.id] == nil, Date().timeIntervalSince(launcherWindowSince!) >= 15 {
                        storeDialogs[game.id] = kind
                        giveFocus(to: launcherWindow)
                    }
                } else {
                    launcherWindowSince = nil
                    storeDialogs[game.id] = nil
                }
                if storeDialogs[game.id] != nil { waited += 1 }
                if Date().timeIntervalSince(started) - waited > 180 {        // the launcher never started it
                    gameStates[game.id] = nil
                    storeDialogs[game.id] = nil
                    await reportLaunchFailure(game, started: started)
                    return
                }
            }
        }
        gameStates[game.id] = nil
        storeDialogs[game.id] = nil
        if let playingSince {
            let ran = Date().timeIntervalSince(playingSince)
            let crashed = await sessionCrashed(game, started: started, ran: ran, sawWindow: sawWindow)
            record(game, start: playingSince, end: Date(), crashed: crashed)
            if crashed { await reportLaunchFailure(game, started: started, secondsRunning: Int(ran)) }
        }
        await refreshLauncher(kind)
        closeLauncherLater(kind, engine: engine)
    }

    /// Two minutes after a game, closes the launcher Sommelier started for it, so it doesn't linger in the background
    /// for days. Not while another of its games runs or something downloads, nor once the user opened it themselves.
    func closeLauncherLater(_ kind: StoreKind, engine: Engine) {
        guard launchersStartedForGames.contains(kind) else { return }
        Task {
            try? await Task.sleep(for: .seconds(120))
            guard launchersStartedForGames.contains(kind),
                  !library.games.contains(where: { $0.store == kind && (gameStates[$0.id] != nil || installState(of: $0) != nil) })
            else { return }
            launchersStartedForGames.remove(kind)
            await stopLauncher(kind, engine: engine)
        }
    }

    /// Signs the launcher out on this Mac: it quits, its saved login goes, its games stay installed (they show up
    /// again after the next sign-in). Not while one of its games runs: the button is off then.
    func signOutLauncher(_ kind: StoreKind) async {
        guard Self.launcherStores.contains(kind), storeActivity[kind] == nil, !isPlaying(from: kind),
              let engine = engine(for: kind.bottleKind) else { return }
        storeActivity[kind] = String(localized: "Signing out…")
        defer { storeActivity[kind] = nil }
        await stopLauncher(kind, engine: engine)
        let store = launcher(kind)
        await Task.detached { store.forgetSignIn() }.value
        _ = try? await ProcessRunner.run(engine.wine, ["reg", "delete", LauncherStore.credentialsKey, "/f"],
                                         environment: WineRunner.environment(bottle: store.bottle, profile: LaunchProfile()))
        await refreshLauncher(kind)
    }

    /// Whether a game from this store is starting or running.
    func isPlaying(from kind: StoreKind) -> Bool {
        gameStates.keys.contains { id in library.games.first { $0.id == id }?.store == kind }
    }

    /// Asks the launcher to quit, and stops what's left in its environment after 20 seconds.
    /// `patience`: how long the launcher may take to quit by itself before it is stopped by force (seconds).
    func stopLauncher(_ kind: StoreKind, engine: Engine, patience: Int = 20) async {
        let runner = WineRunner(paths: paths)
        let bottle = launcher(kind).bottle
        guard await runner.isBottleActive(engine: engine, bottle: bottle) else { running[kind.rawValue] = nil; return }
        if let exe = Self.launcherExecutable[kind] {
            let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
            _ = try? await ProcessRunner.run(engine.wine, ["taskkill", "/im", exe], environment: env)
        }
        for _ in 0..<(patience * 4) {                          // checked often: a launcher quits in a few seconds
            try? await Task.sleep(for: .milliseconds(250))
            if !(await runner.isBottleActive(engine: engine, bottle: bottle)) { break }
        }
        if await runner.isBottleActive(engine: engine, bottle: bottle) { await runner.killAll(engine: engine, bottle: bottle) }
        running[kind.rawValue] = nil
    }

    /// From the Dock menu: the launcher's window forward; when it has none on screen (closed to the tray, or
    /// minimised), the launcher is started again, which makes the running one show its window.
    func showLauncher(_ kind: StoreKind) async {
        if kind != .steam { await openLauncher(kind); return }     // forward, started again, or restarted if hung
        let engines = paths.engines.path
        // A store's window can take a few seconds to come back (a second Steam.exe, a launcher started again): the
        // button shows "Opening…" with the spinner meanwhile, so a click is never left without an answer.
        guard storeActivity[kind] == nil else { return }
        storeActivity[kind] = String(localized: "Opening…")
        defer { storeActivity[kind] = nil }
        if kind == .steam, let engine = engine(for: .steam) {
            // Whatever Steam has on screen may not be the window wanted (a hidden main window, a helper's): Steam
            // itself is asked to show its main window, then brought forward.
            if WineWindows.hasVisibleWindow(enginesFolder: engines, bottle: steam.bottle.url) {
                _ = await bringSteamForward(bottle: steam.bottle.url)        // it's there, only behind: forward at once
                return
            }
            var profile = LaunchProfile()
            if engine.supports(.dxmt) { profile.backend = .dxmt }
            // Asked through its DevTools endpoint first (instant); a second Steam.exe when that isn't open.
            if !(await SteamClientBridge().showMainWindow()) {
                _ = try? steam.launchSteam(engine: engine, profile: profile, extraArguments: SteamProvider.showMainWindow)
            }
            // Steam shows the window it hid (not a new one): forward the moment any Steam window is on screen.
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(125))
                if WineWindows.hasVisibleWindow(enginesFolder: engines, bottle: steam.bottle.url) { break }
            }
            _ = await bringSteamForward(bottle: steam.bottle.url)
            return
        }
        if let pid = WineWindows.windowOwner(enginesFolder: engines, where: { SommelierAppDelegate.isLauncher(kind, $0) }) {
            giveFocus(to: pid)
            return
        }
        guard let engine = engine(for: kind.bottleKind) else { return }
        var profile = LaunchProfile()
        if engine.supports(.dxmt) { profile.backend = .dxmt }
        if kind == .steam {
            _ = try? steam.launchSteam(engine: engine, profile: profile)
        } else {
            _ = try? launcher(kind).launchLauncher(engine: engine, profile: profile) { _ in }
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if let pid = WineWindows.windowOwner(enginesFolder: engines, where: { SommelierAppDelegate.isLauncher(kind, $0) }) {
                giveFocus(to: pid); return
            }
        }
    }

    /// From the Dock menu: the launcher quits with everything it runs in the background.
    func quitLauncher(_ kind: StoreKind) async {
        guard let engine = engine(for: kind.bottleKind) else { return }
        launchersStartedForGames.remove(kind)
        if kind == .steam { await stopSteam(engine: engine) } else { await stopLauncher(kind, engine: engine) }
    }

    /// Before a launcher or game starts: launchers stay out of the Dock, and games' programs carry their names.
    func prepareDock(_ kind: BottleKind, engine: Engine) async {
        await syncShortcuts()
        await DockVisibility(paths: paths).apply(kind, engine: engine)
    }

    /// The graphics the running launcher was started with (`graphicsKey`), on disk because it outlives the app.
    func launcherGraphics(_ kind: StoreKind) -> String? {
        try? String(contentsOf: launcher(kind).bottle.url.appendingPathComponent("sommelier-launcher-graphics"), encoding: .utf8)
    }

    func setLauncherGraphics(_ kind: StoreKind, _ key: String) {
        try? key.write(to: launcher(kind).bottle.url.appendingPathComponent("sommelier-launcher-graphics"), atomically: true, encoding: .utf8)
    }

    /// Each launcher's main program, which closes the rest when it quits.
    static let launcherExecutable: [StoreKind: String] = [.ea: "EADesktop.exe", .ubisoft: "upc.exe", .battlenet: "Battle.net.exe"]

    // MARK: Quitting

    /// The games running now.
    var runningGames: [Game] { library.games.filter { gameStates[$0.id] != nil } }

    /// The store launchers Sommelier runs games through, each with its environment.
    var launcherBottles: [(kind: StoreKind, bottle: Bottle)] {
        [(StoreKind.steam, steam.bottle)] + Self.launcherStores.map { ($0, launcher($0).bottle) }
    }

    /// A game each launcher is downloading now (Steam's and the launcher stores'), for the question on quitting.
    func launcherDownloadsOnQuit() -> [(kind: StoreKind, game: Game)] {
        launcherBottles.compactMap { entry in
            let game = library.games.first { game in
                switch installState(of: game) {
                case .steam?: entry.kind == .steam
                case .launcher(let kind, _)?: kind == entry.kind
                default: false
                }
            }
            return game.map { (entry.kind, $0) }
        }
    }

    /// On quitting: everything Sommelier runs stops, in every environment at once. Launchers are asked to close
    /// (they save what they need) and get their 20 seconds; whatever is still running after that, games included,
    /// is stopped.
    func closeEverythingOnQuit() async {
        let runner = WineRunner(paths: paths)
        var open: [(BottleKind, Engine)] = []
        for kind in BottleKind.allCases {
            let bottle = Bottle(kind: kind, paths: paths)
            guard bottle.exists, let engine = engine(for: kind), await runner.isBottleActive(engine: engine, bottle: bottle) else { continue }
            Updater.log("quitting: \(kind.rawValue) environment is active")
            open.append((kind, engine))
        }
        let closing = open.map { kind, engine in
            Task { @MainActor in
                let bottle = Bottle(kind: kind, paths: self.paths)
                // Quitting waits only a few seconds for them to close by themselves, then stops them: the app must
                // not hang on the Dock icon (a launcher or Steam in the middle of something is not worth 20 seconds).
                if kind == .steam { await self.stopSteam(engine: engine, patience: 5) }
                else if let store = Self.launcherStores.first(where: { $0.bottleKind == kind }) { await self.stopLauncher(store, engine: engine, patience: 5) }
                if await runner.isBottleActive(engine: engine, bottle: bottle) { await runner.killAll(engine: engine, bottle: bottle) }
            }
        }
        for task in closing { await task.value }
        Updater.log("quitting: closed \(open.map { $0.0.rawValue })")
    }
}
