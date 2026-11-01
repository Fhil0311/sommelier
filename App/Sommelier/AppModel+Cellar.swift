// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit
import OSLog

/// The cellar (see SommelierKit's Cellar): before a game runs through DXMT, the service's archive of its pipelines
/// for this Mac comes down, so Metal takes them ready-made instead of compiling; after a session, the pipelines
/// recorded here are built into a local archive in the background, for the next run, when the service has none.
/// Archives come down as soon as an install ends and, for games installed before, quietly after the app starts,
/// with the launch itself as the last chance.
extension AppModel {
    private var cellarLog: Logger { Logger(subsystem: "gg.sommelier", category: "cellar") }

    /// Ready-made shaders: on unless the player turns them off. Taking them sends nothing of the player's, so it
    /// doesn't depend on sharing their own.
    var usesCellar: Bool { settings.readyMadeShaders ?? true }

    /// Before a launch: the service's archives for this Mac, with the activity bar up while they come down.
    func prepareCellar(_ game: Game, backend: GraphicsBackend) async {
        await fetchCellar(game, backend: backend, quiet: false)
    }

    /// Right after an install: the archives come down in the background, and the "is poured" note says so.
    func fetchCellarAfterInstall(_ game: Game) async {
        guard usesCellar, online, let engine = engine(for: game.store.bottleKind) else { return }
        let backend = await resolvedBackend(for: game, profile: profile(for: game), engine: engine)
        if await fetchCellar(game, backend: backend, quiet: true) { shadersReady.insert(game.id) }
    }

    /// Games installed before there were archives (or before this Mac had them): one quiet pass, a game at a
    /// time, so the first launch of each is fast too.
    func fetchCellarForLibrary() async {
        guard usesCellar else { return }
        let games = library.games.filter { $0.isInstalled && !$0.isNative && library.userData[$0.id]?.cellarFetched == nil }
        for game in games {
            guard online, usesCellar, let engine = engine(for: game.store.bottleKind) else { return }
            let backend = await resolvedBackend(for: game, profile: profile(for: game), engine: engine)
            await fetchCellar(game, backend: backend, quiet: true)
        }
    }

    /// The service's archives for this Mac for the game's executables, when newer than what came down before.
    /// True when the game has them all afterwards (now or from before).
    @discardableResult
    func fetchCellar(_ game: Game, backend: GraphicsBackend, quiet: Bool) async -> Bool {
        guard backend == .dxmt, usesCellar, online, let mac = Cellar.mac else { return false }
        let share = shaderShare, cellar = Cellar(paths: paths)
        let store = game.store.rawValue, id = game.storeID
        guard let manifest = try? await share.cellarManifest(store: store, gameID: id) else { return false }
        let mine = manifest.archives.filter { $0.os == mac.os && $0.arch == mac.arch && !Self.notGameExecutables.contains($0.exe) }
        guard let newest = mine.map(\.updated).max() else { return false }
        guard newest != library.userData[game.id]?.cellarFetched else { return true }
        if !quiet { activity = String(localized: "Preparing shaders for \(game.title)…") }
        defer { if !quiet { activity = nil } }
        var complete = true
        for archive in mine {
            guard let data = try? await share.downloadArchive(store: store, gameID: id, exe: archive.exe, os: mac.os, arch: mac.arch),
                  (try? cellar.store(data, exe: archive.exe, os: mac.os, arch: mac.arch)) != nil else { complete = false; continue }
            cellarLog.info("Cellar: \(archive.pipelines) pipelines for \(archive.exe, privacy: .public) (\(game.title, privacy: .public))")
        }
        if complete {
            var data = library.userData[game.id] ?? UserGameData()
            data.cellarFetched = newest
            library.userData[game.id] = data
            libraryStore.save(library)
        }
        return complete
    }

    /// After a session: the game's executables whose records changed since they were last cooked, and which
    /// have no archive from the service, are built into a local archive in the background.
    func cookCellar(after game: Game) {
        guard let mac = Cellar.mac, let engine = engine(for: game.store.bottleKind), engine.cellarTool != nil,
              !cooking.contains(game.id), let folder = game.installPath else { return }
        let cellar = Cellar(paths: paths)
        let since = library.userData[game.id]?.cellarCooked ?? .distantPast
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: cellar.cache.directory.path)) ?? [])
            .filter { !Self.notGameExecutables.contains($0) && !cellar.hasServiceArchive(exe: $0, os: mac.os, arch: mac.arch) }
            .filter { (cellar.recordsDate(exe: $0) ?? .distantPast) > since }
        guard !candidates.isEmpty else { return }
        cooking.insert(game.id)
        let log = cellarLog, title = game.title
        Task.detached(priority: .utility) {
            var built = 0
            for exe in candidates where ShaderCache.executable(exe, isIn: folder) {
                do {
                    if let count = try await cellar.cook(exe: exe, engine: engine, os: mac.os, arch: mac.arch) { built += count }
                } catch {
                    log.error("Cellar: cooking \(exe, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if built > 0 { log.info("Cellar: \(built) pipelines cooked for \(title, privacy: .public)") }
            await MainActor.run {
                self.cooking.remove(game.id)
                var data = self.library.userData[game.id] ?? UserGameData()
                data.cellarCooked = Date()
                self.library.userData[game.id] = data
                self.libraryStore.save(self.library)
            }
        }
    }
}
