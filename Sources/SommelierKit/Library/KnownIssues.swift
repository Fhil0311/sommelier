// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Short, plain notes on games that are known not to work (or need something first), shown on the game page.
public enum KnownIssues {
    /// Notes that ship with the app, by game id. The remote list can add to them or replace them.
    public static let builtIn = [
        "epic:Fortnite":
            "Fortnite uses kernel-level anti-cheat that doesn't run on macOS.",
    ]

    /// For a game `GraphicsProbe` found to use DirectX 12 while no engine with D3DMetal is installed.
    public static let needsDirectX12Engine = "This game uses DirectX 12. "
        + "DirectX 12 compatibility is an advanced option that needs Apple's D3DMetal, which you install yourself under Apple's license."

    /// The note to show for a game, if any. A listed note wins (the remote one over the built-in); otherwise the
    /// DirectX 12 note, when the game's probe asks for D3DMetal and there's none.
    public static func note(
        for game: Game, remote: [String: String]? = nil, probe: GraphicsProbe? = nil, d3dMetalAvailable: Bool = false
    ) -> String? {
        if let listed = remote?[game.id] ?? builtIn[game.id] { return listed }
        guard let probe, probe.usesDirectX12, !d3dMetalAvailable else { return nil }
        return needsDirectX12Engine
    }
}
