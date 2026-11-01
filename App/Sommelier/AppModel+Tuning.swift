// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit

/// Graphics matched to the Mac (SommelierKit GameTuning): written into a game's settings before its first launch, on by
/// default. The first time, Sommelier says so once and lets the player turn it off for every game.
extension AppModel {
    var tunesGames: Bool { settings.tuneGames != false }

    /// The Mac as tuning sees it: chip, GPU cores, memory, and the main display in points and pixels.
    var macPower: MacPower {
        let system = MacSystem.current
        let screen = NSScreen.screens.first
        let points = screen.map { (Int($0.frame.width), Int($0.frame.height)) } ?? (1440, 900)
        let scale = screen?.backingScaleFactor ?? 2
        return MacPower(appleSilicon: system.chip.hasPrefix("Apple"), gpuCores: system.gpuCores ?? 8,
                        ramGB: system.ramGB ?? 8, displayPoints: points,
                        displayPixels: (Int(Double(points.0) * scale), Int(Double(points.1) * scale)))
    }

    func tuningLevel(for game: Game) -> TuningLevel {
        macPower.level(demanding: compatibility(of: game).notes.contains(.demanding))
    }

    /// The Mac as the game sees it: full pixels only with Retina mode, otherwise the display's size in points.
    func tuningPower(for game: Game) -> MacPower {
        var power = macPower
        if !profile(for: game).retina { power.displayPixels = power.displayPoints }
        return power
    }

    /// The resolution a recipe's `${width}`/`${height}` stand for.
    func tuningResolution(for game: Game) -> (width: Int, height: Int) {
        tuningPower(for: game).resolution(for: tuningLevel(for: game))
    }

    /// Wine's Retina mode for a launch: a setting of the whole environment (the Mac driver reads it as each program
    /// starts, so the game about to start gets it), written when it differs from what the environment last got.
    func applyRetina(_ retina: Bool, bottleKind: BottleKind, engine: Engine) async {
        let bottle = Bottle(kind: bottleKind, paths: paths)
        // Remembered for this run of the app only: a saved note can outlive the environment it was about (reset,
        // or an older version that noted it without writing it).
        guard bottle.exists, retinaWritten[bottleKind.rawValue] != retina else { return }
        await WineRunner(paths: paths).applyMacDriver(["RetinaMode": retina], engine: engine, bottle: bottle)
        retinaWritten[bottleKind.rawValue] = retina
    }

    /// Whether Sommelier can match this game's settings: a settings format it knows applies, or the game's recipe
    /// sets its settings by level.
    func canTune(_ game: Game) -> Bool {
        guard !game.isNative, game.isInstalled else { return false }
        if recipe(for: game)?.actions.contains(where: \.followsTuning) == true { return true }
        return GameTuner(paths: paths).canTune(game, bottle: Bottle(kind: game.store.bottleKind, paths: paths))
    }

    /// Right after an install: the settings are matched then, not at the first Play (once the one-time note has
    /// been seen; until then the first Play shows it).
    func tuneAfterInstall(_ game: Game) async {
        guard tunesGames, settings.tuningNoticeShown == true, !game.isNative, game.isInstalled,
              library.userData[game.id]?.tuningOff != true, library.userData[game.id]?.tuning == nil, canTune(game) else { return }
        await applyTuning(game)
    }

    /// Before a launch. False when the launch waits for the one-time note (it continues from there).
    func tuneBeforePlay(_ game: Game) async -> Bool {
        guard tunesGames, !game.isNative, library.userData[game.id]?.tuningOff != true else { return true }
        let existing = library.userData[game.id]?.tuning
        // Done before, with the game's own settings: the player may have changed them since; leave them be.
        if let existing, existing.parts.contains(where: { $0 != "retina" }) { return true }
        // Played before without matching (it was off, or couldn't be done then): its settings are the player's now.
        // Matching it later is the game page's switch.
        if existing == nil, library.userData[game.id]?.lastPlayed != nil { return true }
        if settings.tuningNoticeShown != true {
            tuningNotice = game
            return false
        }
        await applyTuning(game, keepingRetinaFrom: existing)
        return true
    }

    /// Writes the level into the game's settings and, below ultra, has the game see the display in points (a
    /// quarter of the pixels on a Retina screen).
    func applyTuning(_ game: Game, keepingRetinaFrom earlier: GameTuning? = nil) async {
        let level = tuningLevel(for: game)
        let power = tuningPower(for: game)
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        let tuner = GameTuner(paths: paths)
        var tuning = (try? await Task.detached { try tuner.apply(game, bottle: bottle, level: level, power: power) }.value)
            ?? GameTuning(level: level)
        // The game's recipe may set its own settings by level (Expedition 33 keeps its quality in a save): done with
        // the tuning, so switching "matched to this Mac" on again sets them again.
        for action in recipe(for: game)?.actions ?? [] where action.followsTuning {
            let editor = GameConfigEditor(paths: paths)
            var files: [(path: String, backup: String?)] = []
            switch action {
            case .editConfig(let spec, let section, let key, let field, let value):
                if let file = GameConfigFile(spec) {
                    files = (try? editor.edit(file, section: section, key: key, field: field, value: GameConfigEditor.value(value, level: level, resolution: power.resolution(for: level)),
                                              game: game, bottle: bottle)) ?? []
                }
            case .editSave(let spec, let structName, let values):
                if let file = GameConfigFile(spec, save: true) {
                    let ints = values.compactMapValues { Int32(GameConfigEditor.value($0, level: level, resolution: power.resolution(for: level))) }
                    files = (try? editor.editSave(file, structName: structName, values: ints, game: game, bottle: bottle)) ?? []
                    // Already as wanted (nothing written): still watched.
                    if files.isEmpty { files = file.resolve(game: game, bottle: bottle).filter { FileManager.default.fileExists(atPath: $0.path) }.map { ($0.path, nil) } }
                }
            default: break
            }
            tuning.edits = (tuning.edits ?? []) + files.filter { $0.backup != nil }.map { TunedFile(path: $0.path, backup: $0.backup) }
            tuning.watched = (tuning.watched ?? []) + GameConfigEditor.watched(action, files: files.map(\.path), level: level, resolution: power.resolution(for: level))
            if !files.isEmpty, !tuning.parts.contains("recipe") { tuning.parts.append("recipe") }
        }
        if let earlier, earlier.parts.contains("retina") {
            tuning.parts.append("retina"); tuning.previousRetina = earlier.previousRetina
        } else if level < .ultra {
            var profile = profile(for: game)
            if profile.retina {
                tuning.previousRetina = true
                profile.retina = false
                setProfile(profile, for: game)
                tuning.parts.append("retina")
            }
        }
        // Nothing could be written (a format Sommelier doesn't know, or the game makes its file only when it
        // first runs): no record, so the game isn't shown as matched; the next launch tries again.
        guard !tuning.parts.isEmpty else { return }
        var data = library.userData[game.id] ?? UserGameData()
        data.tuning = tuning
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    /// "Restore My Settings": the game's files and Retina mode as they were, and no tuning for it from now on.
    func restoreTuning(_ game: Game) {
        guard !isActive(game) else { return }
        var data = library.userData[game.id] ?? UserGameData()
        if let tuning = data.tuning {
            GameTuner(paths: paths).restore(tuning, for: game)
            GameConfigEditor(paths: paths).restore((tuning.edits ?? []).map { ($0.path, $0.backup) }, game: game)
            if let retina = tuning.previousRetina {
                var profile = profile(for: game); profile.retina = retina; setProfile(profile, for: game)
            }
        }
        data = library.userData[game.id] ?? data            // setProfile saved the profile
        data.tuning = nil
        data.tuningOff = true
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    /// "Match to This Mac" for a game that was left alone: tuned now (not while it runs).
    func tuneNow(_ game: Game) async {
        guard !isActive(game) else { return }
        var data = library.userData[game.id] ?? UserGameData()
        data.tuningOff = nil
        library.userData[game.id] = data
        libraryStore.save(library)
        settings.tuningNoticeShown = true
        await applyTuning(game)
    }

    /// The one-time note's answer; the launch it held goes on either way.
    func answerTuningNotice(tune: Bool) {
        settings.tuningNoticeShown = true
        if !tune { settings.tuneGames = false }
        guard let game = tuningNotice else { return }
        tuningNotice = nil
        Task { await play(game) }
    }

    /// Records that changed nothing the game reads (`GameTuner.isStale`): the files Sommelier made are taken away
    /// and the game counts as on the player's own settings, which it was all along. At start, for every game.
    func repairStaleTuning() async {
        let tuner = GameTuner(paths: paths)
        for game in library.games where game.isInstalled {
            guard let tuning = library.userData[game.id]?.tuning else { continue }
            let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
            guard await Task.detached(operation: { tuner.isStale(tuning, for: game, bottle: bottle) }).value else { continue }
            await Task.detached { tuner.restore(tuning, for: game) }.value
            var data = library.userData[game.id] ?? UserGameData()
            data.tuning = nil
            data.tuningOff = true
            library.userData[game.id] = data
        }
        libraryStore.save(library)
    }

    /// A minute into the first session after a tuning: the values the game holds then are what it kept (games
    /// fix up some at start: a resolution the display doesn't have, an auto-detect). Anything that moves after that,
    /// in this session already, is the player's own choice (`checkTuning`).
    func settleTuningSoon(_ id: String) {
        if library.userData[id]?.tuning?.settled == true, library.userData[id]?.tuning?.watched?.isEmpty == false {
            Task { await watchTuningWhilePlaying(id) }       // later sessions: watched from the start
            return
        }
        guard let tuning = library.userData[id]?.tuning, tuning.settled != true, tuning.watched?.isEmpty == false else { return }
        Task {
            try? await Task.sleep(for: .seconds(60))
            guard case .playing = gameStates[id], let now = library.userData[id]?.tuning, now.applied == tuning.applied,
                  now.settled != true else { return }
            let verdict = await Task.detached { TuningWatch.check(now) }.value
            guard case .settled(let values, let notKept) = verdict, var data = library.userData[id],
                  data.tuning?.applied == now.applied else { return }
            data.tuning?.watched = values
            data.tuning?.settled = true
            data.tuning?.settledAt = Date()
            data.tuning?.notKept = notKept ? true : nil
            library.userData[id] = data
            libraryStore.save(library)
            await watchTuningWhilePlaying(id)
        }
    }

    /// From the settled minute to the end of the session: the watched settings are looked at every 2 seconds, and
    /// the moment they differ from what the game kept, the player has chosen their own: the preset is off for the
    /// game (nothing is put back). Caught here, not after the session, so a change followed at once by quitting
    /// (which the game answers with a rewrite of its own) still counts.
    private func watchTuningWhilePlaying(_ id: String) async {
        while case .playing = gameStates[id], let tuning = library.userData[id]?.tuning, tuning.settled == true {
            try? await Task.sleep(for: .seconds(2))
            guard case .playing = gameStates[id], let now = library.userData[id]?.tuning, now.applied == tuning.applied else { return }
            guard case .changedByPlayer = await Task.detached(operation: { TuningWatch.check(now) }).value else { continue }
            var data = library.userData[id] ?? UserGameData()
            data.tuning = nil
            data.tuningOff = true
            library.userData[id] = data
            libraryStore.save(library)
            if let game = library.games.first(where: { $0.id == id }) {
                try? FileManager.default.removeItem(at: GameTuner(paths: paths).backupFolder(for: game))
            }
            return
        }
    }

    /// After a session: when the player changed in the game what the tuning set, the tuning is off for the game,
    /// and their settings stay (nothing is put back). Settled a minute into the first session (`settleTuningSoon`),
    /// so a change made in that session counts too; a session too short for that only notes what the game kept.
    func checkTuning(after game: Game) {
        guard let tuning = library.userData[game.id]?.tuning, tuning.watched?.isEmpty == false else { return }
        Task {
            var verdict = await Task.detached { TuningWatch.check(tuning) }.value
            // Many games (Unreal's) rewrite their settings file as they quit, with values of their own. A write in
            // the last seconds of the session is that, not the player: the new values are what the game keeps.
            // A write in the middle of the session (settings applied in the game) is the player's.
            if case .changedByPlayer = verdict, let wrote = TuningWatch.lastWrite(of: tuning),
               Date().timeIntervalSince(wrote) < 20, wrote.timeIntervalSince(tuning.settledAt ?? .distantPast) > 0 {
                let now = tuning.watched?.map { w -> WatchedValue in var c = w; c.value = TuningWatch.current(w) ?? w.value; return c }
                verdict = .settled(values: now ?? [], notKept: true)
            }
            var data = library.userData[game.id] ?? UserGameData()
            guard data.tuning?.applied == tuning.applied else { return }          // changed meanwhile
            switch verdict {
            case .kept:
                return
            case .settled(let values, let notKept):
                data.tuning?.watched = values
                data.tuning?.settled = true
                data.tuning?.notKept = notKept ? true : nil
            case .changedByPlayer:
                data.tuning = nil
                data.tuningOff = true
                try? FileManager.default.removeItem(at: GameTuner(paths: paths).backupFolder(for: game))
            }
            library.userData[game.id] = data
            libraryStore.save(library)
        }
    }
}
