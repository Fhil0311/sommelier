// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@preconcurrency import GameController
import SommelierKit

/// PlayStation pads as Xbox controllers (Settings › Controllers): written into each environment's registry when
/// the choice differs from what it last got, at start and when the player switches it. Wine reads the keys when an
/// environment starts, so one running now picks the change up after it restarts.
extension AppModel {
    var playStationAsXbox: Bool { settings.playStationAsXbox ?? true }
    var playStationPrompts: Bool { settings.playStationPrompts ?? true }

    /// A PlayStation controller is connected right now.
    var playStationControllerConnected: Bool {
        GCController.controllers().contains { ControllerInput.kind(of: $0) == .playStation }
    }

    /// Games that ship PlayStation button prompts but only show them when told (their recipe's
    /// `playStationPrompts` action): before each launch the setting goes into the game's file while a PlayStation
    /// controller is in hand and the player wants it, and comes out again otherwise, so an Xbox pad gets Xbox
    /// buttons. Needed each time: such games write their settings file afresh when they quit.
    func applyControllerPrompts(before game: Game) {
        guard !game.isNative, let recipe = recipe(for: game) else { return }
        let bottle = Bottle(kind: game.store.bottleKind, paths: paths)
        let wanted = playStationPrompts && playStationControllerConnected
        for case .playStationPrompts(let spec, let section, let values) in recipe.actions {
            guard let file = GameConfigFile(spec) else { continue }
            for url in file.resolve(game: game, bottle: bottle) {
                let old = try? String(contentsOf: url, encoding: .utf8)
                if wanted {
                    let new = IniFile.setting(values.sorted { $0.key < $1.key }.map { (section: section, key: $0.key, value: $0.value) }, in: old)
                    guard new != old else { continue }
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? new.write(to: url, atomically: true, encoding: .utf8)
                } else if let old, let new = IniFile.removing(section: section, keys: Array(values.keys), from: old) {
                    if new.isEmpty { try? FileManager.default.removeItem(at: url) } else { try? new.write(to: url, atomically: true, encoding: .utf8) }
                }
            }
        }
    }

    func applyControllerChoice() {
        let wanted = playStationAsXbox
        let applied = settings.controllerKeysApplied ?? [:]
        let pending = BottleKind.allCases.filter { kind in
            Bottle(kind: kind, paths: paths).exists && applied[kind.rawValue] != wanted && engine(for: kind) != nil
        }
        guard !pending.isEmpty else { return }
        let runner = WineRunner(paths: paths)
        let paths = self.paths
        Task {
            for kind in pending {
                guard let engine = engine(for: kind) else { continue }
                await runner.applyControllerCompatibility(playStationAsXbox: wanted, engine: engine, bottle: Bottle(kind: kind, paths: paths))
                var done = settings.controllerKeysApplied ?? [:]
                done[kind.rawValue] = wanted
                settings.controllerKeysApplied = done
            }
        }
    }
}
