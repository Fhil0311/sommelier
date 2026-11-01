// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit

/// A launch that failed, with what Sommelier found out and what it offers to do.
struct LaunchFailure: Identifiable {
    let id = UUID()
    let game: Game
    let diagnostics: LaunchDiagnostics
    /// Matching rules, the first one being what the user is offered.
    let rules: [FixRule]
    /// The line that made each matched rule, by rule id (for the sheet to show why).
    var evidence: [String: String] = [:]
    var applying = false
    enum ReportState: Equatable { case notSent, sending, sent, failed }
    var reportState = ReportState.notSent

    var rule: FixRule? { rules.first }
}

/// One-click fixes: when a game doesn't start, its logs are matched against known problems, and the user gets one
/// button that applies the known fix and tries again. Every fix is one of `FixAction`'s few actions, recorded with
/// what it takes to undo it, so nothing runs that the code doesn't know and nothing is lost.
extension AppModel {
    func appliedFixes(of game: Game) -> [AppliedFix] { library.userData[game.id]?.appliedFixes ?? [] }

    /// Collects diagnostics for a failed launch and shows what can be done: a known problem from the logs, or the
    /// next thing worth trying (`LaunchRetry`: Turbo off, the other graphics). The game never restarts by itself;
    /// the sheet offers one button and the player presses it.
    func reportLaunchFailure(_ game: Game, started: Date, exitCode: Int32? = nil, secondsRunning: Int? = nil) async {
        reportSession(game, outcome: secondsRunning == nil ? .didNotStart : .crashed, seconds: secondsRunning.map(TimeInterval.init), since: started)
        // A Mac version runs without Wine: no engine and no graphics layer to name in the report.
        let engine = game.isNative ? nil : engine(for: game.store.bottleKind)
        let backend = lastLaunchBackend[game.id] ?? profile(for: game).backend.resolved()
        let logURL = lastLog[game.id]
        let launcherLogURL = launcherLog(for: game, own: logURL)
        let steamHome: SteamHome? = game.store == .steam ? (game.isNative ? .mac : SteamHome(bottle: steam.bottle)) : nil
        let folder = game.installPath
        let mark = launchLogMarks.removeValue(forKey: game.id)
        let (collected, probe, facts) = await Task.detached {
            var d = DiagnosticsCollector.collect(game: game, engine: engine, backend: game.isNative ? nil : backend, logURL: logURL, launcherLogURL: launcherLogURL,
                                                 steamHome: steamHome, started: started, exitCode: exitCode, secondsRunning: secondsRunning)
            var facts = folder.map { GameFacts.scan($0, store: game.store) }
            // Steam games: Steam's session log and its own logs hold every game's lines. Only this game's are
            // evidence: its processes' Wine lines, and Steam's lines about its app id since the click.
            if game.store == .steam, !game.isNative, let steamHome {
                let console = DiagnosticsCollector.tail(of: steamHome.log("console_log.txt"), bytes: 256 * 1024)
                let processes = DiagnosticsCollector.tail(of: steamHome.log("gameprocess_log.txt"), bytes: 128 * 1024)
                let content = DiagnosticsCollector.tail(of: steamHome.log("content_log.txt"), bytes: 128 * 1024)
                let pids = LaunchEvidence.steamProcessIDs(appID: game.storeID, logs: [console, processes], since: started)
                d.logTail = LaunchEvidence.ownLines(d.logTail, processIDs: pids)
                if let url = mark?.url ?? launcherLogURL {
                    let session = mark.map { CrashSigns.appended(to: url, after: $0.size) } ?? (d.launcherLogTail ?? "")
                    d.launcherLogTail = LaunchEvidence.ownLines(DiagnosticsCollector.scrub(session), processIDs: pids)
                }
                let steamLines = (LaunchEvidence.appLines(content, appID: game.storeID, since: started)
                                  + LaunchEvidence.appLines(console, appID: game.storeID, since: started)).joined(separator: "\n")
                d.steamLogTail = DiagnosticsCollector.scrub(steamLines)
                if steamLines.contains("steam2ea://") { facts?.launcher = .ea }       // Steam hands it to the EA app
            }
            return (d, folder.map { GraphicsProbe.scan($0) }, facts)
        }.value
        var diagnostics = collected
        // The mods profile's logs (the loader's, SMAPI's) read the same way; their fixes rank in by weight, and
        // every mod's name leaves the texts before they go anywhere (AppModel+Mods).
        let fromMods = attachModDiagnostics(to: &diagnostics, for: game, started: started)
        let applied = Set(appliedFixes(of: game).map(\.ruleID))
        let context = FixContext(gameID: game.id, backend: backend, store: game.store, native: game.isNative, d3dMetalReady: isD3DMetalReady,
                                 appliedRuleIDs: applied, facts: facts)
        let fromRules = FixRules.ranked(diagnostics, context: context, rules: fixRules)
        let ranked = (fromRules + fromMods).enumerated().sorted { ($0.element.weight, -$0.offset) > ($1.element.weight, -$1.offset) }.map(\.element)
        let matched = ranked.map(\.rule)
        var retries: [FixRule] = []
        if !game.isNative, let engine {
            let retry = LaunchRetry.Context(backend: backend, automatic: profile(for: game).backend == .auto, turbo: lastLaunchTurbo[game.id] == true,
                                            alternatives: graphicsAlternatives(to: backend, probe: probe, engine: engine),
                                            appliedRuleIDs: applied, turboFailedBefore: library.userData[game.id]?.turboFailed == true)
            retries = LaunchRetry.rules(diagnostics, context: retry, matched: matched)
        }
        lastLaunchTurbo[game.id] = nil
        lastFailureActions[game.id] = (retries + matched).compactMap(\.action)
        launchFailure = LaunchFailure(game: game, diagnostics: diagnostics, rules: retries + matched,
                                      evidence: Dictionary(ranked.map { ($0.rule.id, $0.evidence) }, uniquingKeysWith: { a, _ in a }))
    }

    /// The other ways this engine could run the game's graphics, best first. D3DMetal needs a 64-bit game and
    /// its set-up; DXMT and Wine's own Direct3D have no DirectX 12.
    func graphicsAlternatives(to backend: GraphicsBackend, probe: GraphicsProbe?, engine: Engine) -> [GraphicsBackend] {
        guard let probe else { return [] }
        var out: [GraphicsBackend] = []
        if backend != .d3dMetal, engine.supports(.d3dMetal), isD3DMetalReady, probe.has64BitExecutable { out.append(.d3dMetal) }
        if backend != .dxmt, engine.supports(.dxmt), !probe.usesDirectX12 { out.append(.dxmt) }
        if backend != .wined3d, !probe.usesDirectX12 { out.append(.wined3d) }
        return out
    }

    /// The game's recipe: its own, or for a copy from another store (Ubisoft, EA, Epic, GOG) the one for the same
    /// game on Steam, where most recipes are known (protonfixes keys its fixes by Steam app).
    func recipe(for game: Game) -> Recipe? {
        if let own = recipes[game.id] { return own }
        guard game.store != .steam, let appID = info[game.id]?.steamAppID else { return nil }
        return recipes["steam:\(appID)"]
    }

    /// The recipe applied to a game (the recipes list online), when one was.
    func recipe(appliedTo game: Game) -> Recipe? {
        guard appliedFixes(of: game).contains(where: { $0.ruleID == Recipe.ruleID }) else { return nil }
        return recipe(for: game)
    }

    /// A recipe the game has but never got (it was played before the recipe came, or its graphics were set by
    /// hand): Fix Launch offers its actions first, as recommended.
    func pendingRecipe(for game: Game) -> Recipe? {
        guard !game.isNative, let recipe = recipe(for: game),
              !appliedFixes(of: game).contains(where: { $0.ruleID == Recipe.ruleID }) else { return nil }
        let applied = appliedFixes(of: game).map(\.action)
        return recipe.actions.contains(where: { !applied.contains($0) && !$0.followsTuning && !$0.isBeforeEachLaunch }) ? recipe : nil
    }

    /// Before a game's first launch here: what the recipes list knows about it goes in, as applied fixes the player
    /// can see and undo. Only when the player left the graphics on Automatic; never twice. An action that can't be
    /// done (a backend the engine lacks, D3DMetal not set up) is skipped; the rest still go in.
    func applyRecipe(before game: Game, engine: Engine) async {
        guard !game.isNative, let recipe = recipe(for: game) else { return }
        let data = library.userData[game.id] ?? UserGameData()
        var firstTime = data.playTime == 0 && data.lastPlayed == nil && data.profile.backend == .auto
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_RECIPE"] == game.id { firstTime = true }   // a played game, for checking a recipe
        #endif
        let applied = (data.appliedFixes ?? []).filter { $0.ruleID == Recipe.ruleID }.map(\.action)
        // Applied before: only what the recipe gained since (a launcher to skip, a runtime), never a change of graphics
        // the player may have settled on, nor what they undid. A game played without the recipe stays as it is.
        let topUp = !applied.isEmpty
        guard firstTime || topUp else { return }
        var fixes: [AppliedFix] = []
        for action in recipe.actions {
            if action.followsTuning { continue }          // the game's settings by level go with "matched to this Mac" (AppModel+Tuning)
            if action.isBeforeEachLaunch { continue }      // by the controller in hand, before each launch (AppModel+Controllers)
            if topUp {
                if applied.contains(action) || (data.undoneRecipeActions ?? []).contains(action) { continue }
                if case .switchGraphics = action { continue }
            }
            if case .switchGraphics(let backend) = action, !engine.supports(backend) || (backend == .d3dMetal && !isD3DMetalReady) { continue }
            if action == .setUpDirectX12 || action == .setUpEAApp { continue }          // flows of their own, not for a recipe
            guard let undo = try? await perform(action, on: game) else { continue }
            fixes.append(AppliedFix(ruleID: Recipe.ruleID, action: action, undo: undo))
        }
        guard !fixes.isEmpty else { return }
        var updated = library.userData[game.id] ?? UserGameData()
        updated.appliedFixes = (updated.appliedFixes ?? []) + fixes
        library.userData[game.id] = updated
        libraryStore.save(library)
    }

    /// The engine's table of launchers to skip (`ExecutableRedirects`): the installed Steam games whose profile has
    /// a redirect. Steam starts their programs; Epic and GOG games are started by Sommelier, which reads the profile.
    func updateRedirects() async {
        let bottle = steam.bottle
        let entries: [(folder: String, redirect: ExecutableRedirect)] = library.games.compactMap { game in
            guard game.store == .steam, game.isInstalled, !game.isNative, let folder = game.installPath,
                  let redirect = library.userData[game.id]?.profile.redirect else { return nil }
            return (bottle.windowsPath(of: folder), redirect)
        }
        let table = ExecutableRedirects(paths: paths)
        await Task.detached(priority: .utility) { table.update(entries) }.value
    }

    /// What to remember when a launch starts: the launcher's log that will take the game's output, and how big it
    /// is now, so only this session's part is read afterwards (`sessionCrashed`).
    func logMark(for game: Game) -> (url: URL?, size: UInt64) {
        let url = launcherLog(for: game, own: nil)
        return (url, CrashSigns.size(of: url))
    }

    /// Whether a session that ran ended in a crash rather than the player quitting (`CrashSigns`): gone within
    /// half a minute without ever showing a window; Wine's record of the program dying, in this session's part of
    /// the logs; macOS's crash report for it; or a window up for a minute and a half with nothing drawn (DXMT's
    /// own count, or for D3DMetal the Mac driver's).
    func sessionCrashed(_ game: Game, started: Date, ran: TimeInterval, sawWindow: Bool) async -> Bool {
        if !sawWindow, ran < 30 { return true }
        let own = lastLog[game.id]
        let mark = launchLogMarks[game.id]
        let backend = lastLaunchBackend[game.id]
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        let folder = game.installPath
        let name = folder?.lastPathComponent
        let countsFrames = engine(for: game.store.bottleKind)?.macDriverCountsFrames == true
        return await Task.detached {
            if let own, CrashSigns.inLog(DiagnosticsCollector.tail(of: own), naming: name) { return true }
            if let url = mark?.url, url != own, CrashSigns.inLog(CrashSigns.appended(to: url, after: mark?.size ?? 0), naming: name) { return true }
            if DiagnosticsCollector.crashReport(for: game, since: started) != nil { return true }
            if backend == .dxmt, CrashSigns.hung(frames: FrameStats.samples(in: bottle, since: started, gameFolder: folder),
                                                 windowSeen: sawWindow, secondsRunning: ran) { return true }
            // D3DMetal: the engine's Mac driver counts the frames it shows (engines from 2.2.2); none at all is a hang.
            if backend == .d3dMetal, countsFrames, let folder, CrashSigns.drewNothing(
                drawers: LiveFrameRate.drawers(in: FrameStats.folder(in: bottle), since: started),
                isGame: { ShaderCache.executable($0, isIn: folder) }, windowSeen: sawWindow, secondsRunning: ran) { return true }
            return false
        }.value
    }

    /// Where a game that a running launcher started wrote its output: the log of whichever launch started that
    /// launcher (Steam's own, or an earlier game's), the most recently written one for the store.
    func launcherLog(for game: Game, own: URL?) -> URL? {
        let prefix: String
        switch game.store {
        case .steam: prefix = "steam"
        case .ubisoft, .ea, .battlenet: prefix = game.store.rawValue
        default: return nil
        }
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: paths.logs.path)) ?? []).filter { $0 == prefix || $0.hasPrefix(prefix + "-") }
        var newest: (url: URL, date: Date)?
        for folder in folders {
            let dir = paths.logs.appendingPathComponent(folder)
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "log" && file != own {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if newest.map({ date > $0.date }) ?? true { newest = (file, date) }
            }
        }
        return newest?.url
    }

    /// What "Send Report" sends: the scrubbed diagnostics, the matched problems and the app's version.
    func failureReport(_ failure: LaunchFailure) -> FailureReport {
        let client: String
        if let id = settings.reportClientID { client = id } else { client = UUID().uuidString.lowercased(); settings.reportClientID = client }
        let game = failure.game
        return FailureReport(client: client,
                             game: .init(store: game.store.rawValue, id: game.storeID, title: game.title,
                                         steamAppID: game.store == .steam ? nil : info[game.id]?.steamAppID),
                             diagnostics: failure.diagnostics, matched: failure.rules.map(\.id),
                             sommelier: .init(app: reporter.clientVersion, engine: failure.diagnostics.engineVersion, backend: failure.diagnostics.backend))
    }

    /// Sends the open failure's report; the player saw it in the preview and chose to.
    func sendFailureReport() async {
        guard let failure = launchFailure, failure.reportState != .sending, failure.reportState != .sent else { return }
        let report = failureReport(failure)
        let version = reporter.clientVersion
        launchFailure?.reportState = .sending
        do {
            try await report.send(clientVersion: version)
            if launchFailure?.id == failure.id { launchFailure?.reportState = .sent }
        } catch {
            if launchFailure?.id == failure.id { launchFailure?.reportState = .failed }
        }
    }

    /// Applies the rule's fix, remembers how to undo it, and starts the game again.
    func applyFix(_ rule: FixRule, to game: Game, thenPlay: Bool = true) async {
        guard let action = rule.action else { return }
        launchFailure?.applying = true
        do {
            let undo = try await perform(action, on: game)
            var data = library.userData[game.id] ?? UserGameData()
            data.appliedFixes = (data.appliedFixes ?? []) + [AppliedFix(ruleID: rule.id, action: action, undo: undo)]
            library.userData[game.id] = data
            libraryStore.save(library)
        } catch {
            launchFailure = nil
            errorMessage = error.localizedDescription
            return
        }
        launchFailure = nil
        if thenPlay, action != .setUpDirectX12 { await play(game) }          // the DirectX 12 set-up is its own flow
    }

    // MARK: Fixing a launch by hand

    /// What the game's files say, read once per run (`GameFacts`), for the game page's "Fix Launch" menu.
    func loadFacts(for game: Game) async {
        guard gameFacts[game.id] == nil, !game.isNative, let folder = game.installPath else { return }
        let store = game.store
        let (facts, probe) = await Task.detached { (GameFacts.scan(folder, store: store), GraphicsProbe.scan(folder)) }.value
        gameFacts[game.id] = facts
        gameProbes[game.id] = probe
        if lastLaunchBackend[game.id] == nil, let engine = engine(for: game.store.bottleKind) {
            lastLaunchBackend[game.id] = await resolvedBackend(for: game, profile: profile(for: game), engine: engine)
        }
    }

    /// The fixes that can apply to this game, by what its files say, without the ones already applied. Each says
    /// whether the game's last failure pointed at it.
    func manualFixes(for game: Game) -> [(action: FixAction, recommended: Bool)] {
        guard game.isInstalled, !game.isNative, let facts = gameFacts[game.id], let engine = engine(for: game.store.bottleKind) else { return [] }
        let applied = appliedFixes(of: game).map(\.action)
        var actions: [FixAction] = []
        if facts.launcher == .ea { actions.append(.disableEAOverlay) }
        if facts.dotNet { actions.append(.installDotNet) }
        if facts.visualCpp { actions.append(.installVCRuntime) }
        if facts.directXRuntime { actions.append(.installComponent(.directx)) }
        if facts.physX { actions.append(.installComponent(.physx)) }
        let backend = lastLaunchBackend[game.id]
        if let backend, turboApplies(to: game, backend: backend) { actions.append(.turnOffTurbo) }
        if let backend, let probe = gameProbes[game.id] {
            actions += graphicsAlternatives(to: backend, probe: probe, engine: engine).filter { $0 != .wined3d }.map { .switchGraphics($0) }
        }
        let suggested = Set((lastFailureActions[game.id] ?? []).map(\.summary))
        // The game's recipe, when it never got it: other players' known way, recommended.
        let fromRecipe = pendingRecipe(for: game)?.actions.filter { !$0.followsTuning && !$0.isBeforeEachLaunch && !applied.contains($0) } ?? []
        return fromRecipe.map { ($0, true) }
            + actions.filter { !applied.contains($0) && !fromRecipe.contains($0) }.map { ($0, suggested.contains($0.summary)) }
    }


    /// Puts back what a fix changed.
    func undoFix(_ fix: AppliedFix, for game: Game) async {
        switch fix.undo {
        case .previousBackend(let backend):
            var p = profile(for: game); p.backend = backend; setProfile(p, for: game)
        case .previousEnvironment(let env):
            var p = profile(for: game); p.extraEnvironment = env; setProfile(p, for: game)
        case .removeFiles(let files):
            let windows = Bottle(kind: game.store.bottleKind, paths: paths).driveC.appendingPathComponent("windows")
            for file in files { try? FileManager.default.removeItem(at: windows.appendingPathComponent(file)) }
        case .enableEAOverlay:
            let bottle = steam.bottle
            await Task.detached { EAAppSetup.enableOverlay(in: bottle) }.value
        case .turnOnTurbo:
            setTurbo(true, for: game)
        case .previousDLLOverride(let dll, let mode):
            var p = profile(for: game); p.dllOverrides[dll] = mode; setProfile(p, for: game)
        case .previousExecutable(let instead, let run):
            var p = profile(for: game)
            p.redirect = if let instead, let run { ExecutableRedirect(instead: instead, run: run) } else { nil }
            setProfile(p, for: game)
            await updateRedirects()
        case .removeWindowsVersion(let exe):
            if let engine = engine(for: game.store.bottleKind) {
                await WindowsVersion(paths: paths).set(nil, for: exe, in: Bottle(kind: game.store.bottleKind, paths: paths), engine: engine)
            }
        case .previousArguments(let args):
            var p = profile(for: game); p.extraArguments = args; setProfile(p, for: game)
        case .restoreConfig(let files, let backups):
            GameConfigEditor(paths: paths).restore(Array(zip(files, backups)).map { (path: $0.0, backup: $0.1) }, game: game)
        case .uninstallComponent(let files, let previousOverrides):
            var p = profile(for: game)
            for (dll, mode) in previousOverrides { p.dllOverrides[dll] = mode }
            setProfile(p, for: game)
            let windows = Bottle(kind: game.store.bottleKind, paths: paths).driveC.appendingPathComponent("windows")
            for file in files { try? FileManager.default.removeItem(at: windows.appendingPathComponent(file)) }
        case .enableMod(let key):
            // Back on the way the Mods page turns it on: in its own slot, with the order written again.
            let store = ModStore(paths: paths, gameID: game.id)
            let switched = (try? await switchModForFix(key, on: true, in: game)) == true
            if !switched, var mod = store.mod(key) {
                let roots = ModRoots(game: game, bottle: game.isNative ? nil : Bottle(kind: game.store.bottleKind, paths: paths), paths: paths)
                try? ModDeployer(roots: roots, store: store).setEnabled(mod, true)
                mod.enabled = true
                try? store.save(mod)
            }
        case .restoreFrameworkLaunch:
            var p = profile(for: game)
            ModDiagnostics.restore(fix.undo, in: &p)
            setProfile(p, for: game)
            await updateRedirects()
        case .none:
            break
        }
        var data = library.userData[game.id] ?? UserGameData()
        data.appliedFixes?.removeAll { $0.id == fix.id }
        if fix.ruleID == Recipe.ruleID { data.undoneRecipeActions = (data.undoneRecipeActions ?? []) + [fix.action] }
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    private func perform(_ action: FixAction, on game: Game) async throws -> AppliedFix.Undo {
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        switch action {
        case .switchGraphics(let backend):
            var p = profile(for: game)
            let previous = p.backend
            p.backend = backend
            setProfile(p, for: game)
            return .previousBackend(previous)
        case .setEnvironment(let env):
            var p = profile(for: game)
            let previous = p.extraEnvironment
            p.extraEnvironment.merge(env.filter { FixAction.allowsEnvironment($0.key) }) { _, new in new }
            setProfile(p, for: game)
            return .previousEnvironment(previous)
        case .installDotNet:
            guard let engine = engine(for: game.store.bottleKind) else { throw WineRunnerError.launchFailed("no engine") }
            if !bottle.exists { try await BottleManager(paths: paths).ensure(game.store.bottleKind, engine: engine) }
            try await WineMono(paths: paths).ensureInstalled(in: bottle, engine: engine)
            return .none
        case .installVCRuntime:
            let copied = BottleManager(paths: paths).provisionRuntime(in: game.store.bottleKind)
            return .removeFiles(copied)
        case .disableEAOverlay:
            let steamBottle = steam.bottle
            await Task.detached { EAAppSetup.disableOverlay(in: steamBottle) }.value
            return .enableEAOverlay
        case .setUpDirectX12:
            beginD3DMetalSetup()
            return .none
        case .turnOffTurbo:
            turboFailed(game)
            return .turnOnTurbo
        case .overrideDLL(let dll, let mode):
            var p = profile(for: game)
            let previous = p.dllOverrides[dll]
            p.dllOverrides[dll] = mode
            setProfile(p, for: game)
            return .previousDLLOverride(dll, previous)
        case .runExecutable(let instead, let run):
            var p = profile(for: game)
            let previous = p.redirect
            p.redirect = ExecutableRedirect(instead: instead, run: run)
            setProfile(p, for: game)
            await updateRedirects()
            return .previousExecutable(instead: previous?.instead, run: previous?.run)
        case .setWindowsVersion(let version, let exe):
            guard let engine = engine(for: game.store.bottleKind) else { throw WineRunnerError.launchFailed("no engine") }
            if !bottle.exists { try await BottleManager(paths: paths).ensure(game.store.bottleKind, engine: engine) }
            guard await WindowsVersion(paths: paths).set(version, for: exe, in: bottle, engine: engine) else {
                throw WineRunnerError.launchFailed("couldn't set the Windows version")
            }
            return .removeWindowsVersion(exe: exe)
        case .addArguments(let args):
            var p = profile(for: game)
            let previous = p.extraArguments
            p.extraArguments += args.filter { !previous.contains($0) }
            setProfile(p, for: game)
            return .previousArguments(previous)
        case .editConfig(let spec, let section, let key, let field, let value):
            guard let file = GameConfigFile(spec) else { throw WineRunnerError.launchFailed("bad settings file") }
            let resolved = GameConfigEditor.value(value, level: tuningLevel(for: game), resolution: tuningResolution(for: game))
            let editor = GameConfigEditor(paths: paths)
            let files = try editor.edit(file, section: section, key: key, field: field, value: resolved, game: game, bottle: bottle)
            return .restoreConfig(files: files.map(\.path), backups: files.map(\.backup))
        case .playStationPrompts:
            throw WineRunnerError.launchFailed("not a fix")           // done before each launch instead (applyControllerPrompts)
        case .removeModLeftovers(let specs):
            // Other loaders' files out of the game folder, into the game's mod store; nothing is deleted.
            let roots = ModRoots(game: game, bottle: game.isNative ? nil : bottle, paths: paths)
            _ = try LaunchGuard.removeLeftovers(specs, roots: roots, store: ModStore(paths: paths, gameID: game.id))
            return .none
        case .disableMod(let key):
            // The mod stays in the store, marked off; where its loader allows it, its files stay in the game too.
            let store = ModStore(paths: paths, gameID: game.id)
            guard var mod = store.mod(key) else { throw WineRunnerError.launchFailed("no such mod") }
            // The Mods page's switch when the game's profile applies: the order is written again (a numbered pak
            // above it moves down, UE4SS's line goes to 0); the store alone otherwise.
            if try await switchModForFix(key, on: false, in: game) { return .enableMod(key) }
            let roots = ModRoots(game: game, bottle: game.isNative ? nil : bottle, paths: paths)
            try ModDeployer(roots: roots, store: store).setEnabled(mod, false)
            mod.enabled = false
            try store.save(mod)
            return .enableMod(key)
        case .disableFramework(let id):
            // The loader's files stay for when it updates; only the launch profile changes.
            guard let framework = ModsService(paths: paths).cached()?.profile(for: game)?.frameworks.first(where: { $0.id == id }) else {
                throw WineRunnerError.launchFailed("no such framework")
            }
            var p = profile(for: game)
            let fix = ModDiagnostics.disable(framework, in: &p)
            setProfile(p, for: game)
            await updateRedirects()
            return fix.undo
        case .editSave(let spec, let structName, let values):
            guard let file = GameConfigFile(spec, save: true) else { throw WineRunnerError.launchFailed("bad save file") }
            let level = tuningLevel(for: game), resolution = tuningResolution(for: game)
            var ints: [String: Int32] = [:]
            for (name, value) in values { guard let v = Int32(GameConfigEditor.value(value, level: level, resolution: resolution)) else { continue }; ints[name] = v }
            let files = try GameConfigEditor(paths: paths).editSave(file, structName: structName, values: ints, game: game, bottle: bottle)
            return .restoreConfig(files: files.map(\.path), backups: files.map(\.backup))
        case .installComponent(let component):
            guard let engine = engine(for: game.store.bottleKind) else { throw WineRunnerError.launchFailed("no engine") }
            if !bottle.exists { try await BottleManager(paths: paths).ensure(game.store.bottleKind, engine: engine) }
            let installer = ComponentInstaller(paths: paths)
            activity = String(localized: "Installing \(component.localizedName)…")
            defer { activity = nil }
            let files = installer.isInstalled(component, in: bottle) ? [] : try await installer.install(component, in: bottle, engine: engine)
            var p = profile(for: game)
            var previous: [String: String?] = [:]
            for (dll, mode) in component.overrides { previous[dll] = .some(p.dllOverrides[dll]); p.dllOverrides[dll] = mode }
            setProfile(p, for: game)
            return .uninstallComponent(files: files, previousOverrides: previous)
        case .setUpEAApp:
            guard let folder = game.installPath, let engine = engine(for: .steam) else { throw WineRunnerError.launchFailed("no engine") }
            try await EAAppSetup(paths: paths).ensure(gameFolder: folder, bottle: steam.bottle, engine: engine)
            return .none
        }
    }
}
