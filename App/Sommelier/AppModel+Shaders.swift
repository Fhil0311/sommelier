// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit
import OSLog

/// Shader sharing ("decanting"): before a game's first run through DXMT, the shader translations other players
/// made come down and go into its cache (with ready-made shaders, `usesCellar`); after a session, what DXMT
/// translated here goes up (opt-in). Only the shaders themselves travel.
extension AppModel {
    var sharesShaders: Bool { settings.shareShaders == true }

    var shaderShare: ShaderShare {
        ShaderShare(clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    /// Launchers and helpers that run in the same environment: their shaders aren't the game's.
    nonisolated static let notGameExecutables: Set<String> = [
        "Steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe", "GameOverlayUI.exe", "start.exe",
        "EADesktop.exe", "EACefSubProcess.exe", "EABackgroundService.exe", "IGOProxy32.exe", "IGOProxy64.exe",
        "upc.exe", "UplayWebCore.exe", "UbisoftGameLauncher.exe", "Battle.net.exe", "Agent.exe",
    ]

    /// Takes in what others shared for the game, unless nothing changed since the last time. Quick when the
    /// service has nothing; a few seconds when a game's packs come down for the first time.
    func decant(_ game: Game, backend: GraphicsBackend) async {
        let log = Logger(subsystem: "gg.sommelier", category: "shaders")
        guard usesCellar, backend == .dxmt, online else {
            log.info("Decant skipped: ready-made \(self.usesCellar) backend \(backend.rawValue, privacy: .public) online \(self.online)")
            return
        }
        let share = shaderShare
        let store = game.store.rawValue, id = game.storeID
        let manifest: ShaderShare.Manifest
        do { manifest = try await share.manifest(store: store, gameID: id) } catch {
            log.info("Decant: no manifest for \(game.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !manifest.packs.isEmpty else { return }
        let newest = manifest.packs.map(\.updated).max()
        guard newest != library.userData[game.id]?.shadersDecanted else { return }
        activity = String(localized: "Preparing shaders for \(game.title)…")
        defer { activity = nil }
        let cache = ShaderCache(paths: paths)
        var added = 0
        for pack in manifest.packs where !Self.notGameExecutables.contains(pack.exe) && ShaderPack.Kind(name: pack.kind) != nil {
            guard let downloaded = try? await share.download(store: store, gameID: id, pack: pack) else { continue }
            added += (try? await Task.detached { try cache.import(downloaded, exe: pack.exe) }.value) ?? 0
        }
        var data = library.userData[game.id] ?? UserGameData()
        data.shadersDecanted = newest
        library.userData[game.id] = data
        libraryStore.save(library)
        if added > 0 { Logger(subsystem: "gg.sommelier", category: "shaders").info("Decanted \(added) shaders for \(game.title, privacy: .public)") }
    }

    /// Sends what DXMT translated and hasn't been shared: what the session added, and the first time, what
    /// was cached before sharing was turned on. Only databases that changed during the session (or were never
    /// sent) go, and they go under this game.
    func shareShaders(after game: Game, since start: Date) {
        guard sharesShaders, online else { return }
        let share = shaderShare, cache = ShaderCache(paths: paths)
        let store = game.store.rawValue, id = game.storeID
        let folder = game.installPath
        Task.detached(priority: .utility) {
            for exe in cache.executablesToShare() where !Self.notGameExecutables.contains(exe) {
                // Only this game's own executables go under its name; another game's wait for its own session.
                guard let folder, ShaderCache.executable(exe, isIn: folder) else { continue }
                var sent = true
                for pack in cache.export(exe: exe) where !pack.isEmpty {
                    if (try? await share.upload(store: store, gameID: id, exe: exe, pack: pack)) == nil { sent = false }
                }
                if sent { cache.markShared(exe) }
            }
        }
    }
}
