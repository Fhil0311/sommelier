// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit
import Network

/// Saves changed both here and in the cloud since the last sync: the user picks which to keep.
struct SaveConflict: Identifiable {
    let id = UUID()
    let game: Game
    let cloud: String
    let local: String
}

/// Cloud saves for Epic Games and GOG: newer cloud saves come down before a game starts, newer local saves go up
/// after it quits. Steam games sync through Steam itself. Offline, the game just plays, and what it saved waits
/// to upload until the network is back; the game's page says where its saves stand.
extension AppModel {
    var cloudSavesOn: Bool { settings.cloudSaves ?? true }

    func supportsCloudSaves(_ game: Game) -> Bool {
        switch game.store {
        case .epic: epic.supportsCloudSaves(game)
        case .gog: game.isInstalled              // known only from GOG's configuration, fetched when syncing
        default: false
        }
    }

    func saveSyncStatus(of game: Game) -> SaveSyncStatus? {
        guard cloudSavesOn, Self.directStores.contains(game.store), supportsCloudSaves(game) else { return nil }
        return library.userData[game.id]?.saveSync
    }

    /// Watches the network: when it comes back, saves that waited go up.
    func watchNetwork() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.online
                self.online = path.status == .satisfied
                if self.online, !wasOnline { await self.retryPendingUploads() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "sommelier.network"))
        networkMonitor = monitor
    }

    /// Before Play. False when the launch should wait for the user: a conflict, or a failure while online.
    func syncSavesBeforePlay(_ game: Game) async -> Bool {
        guard cloudSavesOn, Self.directStores.contains(game.store), supportsCloudSaves(game) else { return true }
        if savesSyncedForLaunch.remove(game.id) != nil { return true }           // the user just decided
        guard online else {
            if saveSyncStatus(of: game)?.state != .pendingUpload { setSaveSync(game, .init(.failed, message: String(localized: "No internet connection"))) }
            return true                                                           // play with what's here
        }
        if saveSyncStatus(of: game)?.state == .pendingUpload {                   // last time's saves first
            if case .conflict(let cloud, let local) = await sync(game, .upload) {
                saveConflict = SaveConflict(game: game, cloud: cloud, local: local); return false
            }
        }
        switch await sync(game, .download) {
        case .conflict(let cloud, let local):
            saveConflict = SaveConflict(game: game, cloud: cloud, local: local)
            return false
        case .failed(let why):
            setSaveSync(game, .init(.failed, message: why))
            saveSyncFailure = game
            return false
        default:
            return true
        }
    }

    /// After the game quits: upload, or remember to.
    func syncSavesAfterPlay(_ game: Game) async {
        guard cloudSavesOn, Self.directStores.contains(game.store), supportsCloudSaves(game) else { return }
        guard online else { setSaveSync(game, .init(.pendingUpload)); return }
        switch await sync(game, .upload) {
        case .conflict(let cloud, let local): saveConflict = SaveConflict(game: game, cloud: cloud, local: local)
        case .failed(let why): setSaveSync(game, .init(.pendingUpload, message: why))
        default: break
        }
    }

    /// Games whose saves waited for the network.
    func retryPendingUploads() async {
        for game in library.games where library.userData[game.id]?.saveSync?.state == .pendingUpload && supportsCloudSaves(game) && !isActive(game) {
            if case .conflict(let cloud, let local) = await sync(game, .upload) {
                saveConflict = SaveConflict(game: game, cloud: cloud, local: local)
            }
        }
    }

    /// The user's answer to a conflict: take the cloud's or push this Mac's, then start the game (if asked before it).
    func resolveSaveConflict(_ conflict: SaveConflict, useCloud: Bool, thenPlay: Bool) async {
        saveConflict = nil
        _ = await sync(conflict.game, useCloud ? .forceDownload : .forceUpload)
        if thenPlay { await playWithoutSyncing(conflict.game) }
    }

    /// Starts the game with the saves as they are (after a conflict was settled, or a failed sync accepted).
    func playWithoutSyncing(_ game: Game) async {
        saveSyncFailure = nil
        savesSyncedForLaunch.insert(game.id)
        await play(game)
    }

    private func sync(_ game: Game, _ mode: CloudSaveMode) async -> CloudSaveOutcome {
        let previous = activity
        activity = String(localized: "Syncing saves…")
        defer { activity = previous }
        let outcome = game.store == .epic ? await epic.syncSaves(game, mode) : await gog.syncSaves(game, mode)
        if outcome == .synced || outcome == .nothingToDo { setSaveSync(game, .init(.synced)) }
        return outcome
    }

    private func setSaveSync(_ game: Game, _ status: SaveSyncStatus) {
        var data = library.userData[game.id] ?? UserGameData()
        data.saveSync = status
        library.userData[game.id] = data
        libraryStore.save(library)
    }
}
