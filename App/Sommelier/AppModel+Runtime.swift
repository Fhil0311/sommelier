// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit
import OSLog

/// What a game needs around it before its first run, for stores whose client doesn't provide it (Epic, GOG): the
/// runtime set (`RuntimeSetup`: Visual C++, DirectX, Mono) once per environment, and the game's own prerequisite
/// installer (`GamePrerequisites`) once per game. Done right after the install, so Play is instant; a Play that
/// comes first waits for it.
extension AppModel {
    func prepareRuntime(for game: Game) async {
        let kind = game.store.bottleKind
        guard RuntimeSetup.needsRuntime(kind), !game.isNative, let engine = engine(for: game.store.bottleKind) else { return }
        if let running = runtimeTasks[kind.rawValue] { await running.value }
        else {
            let task = Task { await installRuntime(kind, engine: engine) }
            runtimeTasks[kind.rawValue] = task
            await task.value
            runtimeTasks[kind.rawValue] = nil
        }
        await installPrerequisites(of: game, engine: engine)
    }

    private func installRuntime(_ kind: BottleKind, engine: Engine) async {
        let bottle: Bottle
        do { bottle = try await BottleManager(paths: paths).ensure(kind, engine: engine) } catch { return }
        guard !RuntimeSetup.isInstalled(in: bottle) else { return }
        let previous = activity
        activity = String(localized: "Setting up…")
        await RuntimeSetup(paths: paths).ensureInstalled(in: bottle, engine: engine)
        activity = previous
    }

    private func installPrerequisites(of game: Game, engine: Engine) async {
        guard game.store == .epic, let folder = game.installPath, !GamePrerequisites.isDone(in: folder),
              let json = try? Data(contentsOf: paths.legendaryConfig.appendingPathComponent("installed.json")),
              let installer = GamePrerequisites.epicInstaller(for: game.storeID, installedJSON: json) else { return }
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        let previous = activity
        activity = String(localized: "Setting up…")
        do { try await GamePrerequisites.run(installer, in: folder, bottle: bottle, engine: engine) } catch {
            Logger(subsystem: "gg.sommelier", category: "runtime")
                .error("Prerequisites of \(game.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        activity = previous
    }
}
