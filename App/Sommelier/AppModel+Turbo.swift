// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit

/// Turbo: a DirectX 10 or 11 game draws at the display's size in points (a quarter of a Retina display's pixels)
/// and MetalFX, Apple's upscaler, scales each frame up to the display's pixels. In Raft on an M4 Pro: 140 frames a
/// second against 53 at the full resolution, for a slightly softer picture. On by default on Apple silicon; off for
/// every game in Settings or for one on its page; turned off by itself for a game that fails to start with it.
extension AppModel {
    /// Off until the next version (decided 23.10): drawing at the display's points saves the frames whether
    /// MetalFX or macOS scales the picture up, so Turbo only sharpened it, and barely visibly. It comes back as real
    /// upscaling from fewer pixels (the game's DLSS answered by MetalFX). Until then its switches say "Soon".
    static let turboReady = false

    var turboOn: Bool { settings.turboGames != false }

    /// MetalFX's spatial scaler needs an Apple GPU.
    var turboAvailable: Bool { Self.turboReady && turboOn && macPower.appleSilicon }

    /// For this launch: DXMT (DirectX 10 and 11) on Apple silicon, not off for the game, not failed before, and
    /// the game not in Retina mode (Turbo is drawing at the display's points and scaling up to its pixels; with
    /// Retina on the game already draws every pixel, and scaling up from there would only cost).
    func turboApplies(to game: Game, backend: GraphicsBackend) -> Bool {
        let data = library.userData[game.id]
        return Self.turboReady && macPower.appleSilicon && !game.isNative && backend == .dxmt && data?.turboFailed != true
            && turboWanted(for: game) && !profile(for: game).retina
    }

    /// The player's choice for the game: its own switch when set, else the switch for all games in Settings.
    func turboWanted(for game: Game) -> Bool {
        let data = library.userData[game.id]
        if data?.turboOn == true { return true }
        return turboOn && data?.turboOff != true
    }

    /// The game page's switch: only this game changes, whatever the switch for all games says. Turbo draws at the
    /// display's points, Retina at every pixel, so turning Turbo on turns the game's Retina mode off.
    func setTurbo(_ on: Bool, for game: Game) {
        var data = library.userData[game.id] ?? UserGameData()
        data.turboOff = on ? nil : true
        data.turboOn = on && !turboOn ? true : nil
        if on { data.turboFailed = nil; data.profile.retina = false }
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    /// The game menu's Retina switch: Retina on turns the game's Turbo off (they can't both apply).
    func setRetina(_ on: Bool, for game: Game) {
        var data = library.userData[game.id] ?? UserGameData()
        data.profile.retina = on
        if on, turboWanted(for: game) { data.turboOff = true; data.turboOn = nil }
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    func turboFailed(_ game: Game) {
        var data = library.userData[game.id] ?? UserGameData()
        data.turboFailed = true
        library.userData[game.id] = data
        libraryStore.save(library)
    }
}
