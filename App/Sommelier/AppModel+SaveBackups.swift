// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import os
import SommelierKit

/// Local copies of a game's saves, made after each session of a Windows game. Windows has no list of where games
/// keep saves, so the folders are learned: the game's Steam Cloud folder, folders named like the game, save
/// folders in its install folder, and whatever it wrote while it ran. Learned folders are remembered per game, so
/// a later session that writes nothing new still backs them up when they changed. For games in the save locations
/// list (`SaveLocationsList`, from the Ludusavi manifest) its folders are taken instead, exactly; the guessing is
/// only for games it doesn't know or whose listed folders don't exist yet. A restore never deletes: it
/// copies the current saves aside first, and that copy can be restored in turn.
extension AppModel {
    var backsUpSaves: Bool { settings.backUpSaves != false }

    /// Where backups go: the folder the player chose, else Sommelier's data folder.
    var saveBackupFolder: URL { settings.backupFolder ?? paths.home }
    /// Ten copies per game: enough to step back past a broken save, small enough for big save folders.
    var saveBackupStore: SaveBackupStore {
        var store = SaveBackupStore(destination: saveBackupFolder)
        store.maximumBackups = 10
        return store
    }

    /// A learned folder bigger than this is a cache or a log folder, not saves.
    private nonisolated static let largestSaveFolder: Int64 = 512 * 1024 * 1024

    func saveRoots(of game: Game) -> SaveRoots {
        SaveRoots(bottle: Bottle(kind: game.store.bottleKind, paths: paths), installPath: game.installPath)
    }

    /// After a session: learns the game's save folders and copies them when anything in them changed since the
    /// last backup. Runs off the main thread; a failure is only logged (the next session tries again).
    func backUpSaves(after game: Game, since start: Date) {
        guard backsUpSaves, !game.isNative else { return }
        let roots = saveRoots(of: game), store = saveBackupStore
        let known = library.userData[game.id]?.saveSources ?? []
        let last = library.userData[game.id]?.lastSaveBackup ?? .distantPast
        let steamID = game.store == .steam ? game.storeID : nil
        let neighbours = library.games.filter { $0.isInstalled && $0.id != game.id && $0.store.bottleKind == game.store.bottleKind }
        let others = neighbours.map(\.title)
        let claimed = Set(neighbours.flatMap { library.userData[$0.id]?.saveSources ?? [] })   // learned by another game
        let locations = SaveLocationsService(paths: paths)
        Task {
            let result: ([SaveSource], SaveBackupInfo?)? = await Task.detached(priority: .utility) {
                let listed = (locations.cached()?.places(for: game) ?? []).flatMap { $0.folders(in: roots, largest: Self.largestSaveFolder) }
                let sources: [SaveSource]
                if !listed.isEmpty {
                    sources = listed.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
                } else {
                    let found = SaveLocator.candidates(title: game.title, steamAppID: steamID, roots: roots, changedSince: start, otherGames: others)
                        .filter { $0.bytes <= Self.largestSaveFolder && !($0.reason == .recentlyChanged && claimed.contains($0.source)) }
                        .map(\.source)
                    sources = known + found.filter { !known.contains($0) }
                }
                guard !sources.isEmpty else { return nil }
                guard SaveBackupStore.hasChanges(sources: sources, roots: roots, since: last) else { return (sources, nil) }
                do {
                    return (sources, try store.create(gameID: game.id, title: game.title, sources: sources, roots: roots, kind: .automatic))
                } catch {
                    Logger(subsystem: "gg.sommelier", category: "saves")
                        .error("Save backup failed for \(game.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return (sources, nil)
                }
            }.value
            guard let (sources, made) = result else { return }
            var data = library.userData[game.id] ?? UserGameData()
            data.saveSources = sources
            if let made { data.lastSaveBackup = made.created }
            library.userData[game.id] = data
            libraryStore.save(library)
        }
    }

    /// The game's backups, newest first.
    func saveBackups(of game: Game) -> [SaveBackupInfo] {
        saveBackupStore.list(gameID: game.id, title: game.title)
    }

    /// Puts a backup back after the player confirms. Not while the game runs: it would overwrite the copy.
    func restoreSaves(_ backup: SaveBackupInfo, of game: Game) {
        guard gameStates[game.id] == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restore the saves from \(backup.created.formatted(date: .abbreviated, time: .shortened))?")
        alert.informativeText = String(localized: "The current saves are copied aside first, so this can be undone.")
        alert.addButton(withTitle: String(localized: "Restore"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try saveBackupStore.restore(backup, roots: saveRoots(of: game)) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Opens the game's backups in Finder (the backups folder when it has none yet).
    func showSaveBackups(of game: Game) {
        let folder = saveBackups(of: game).first?.folder.deletingLastPathComponent() ?? saveBackupStore.root
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : saveBackupFolder)
    }
}
