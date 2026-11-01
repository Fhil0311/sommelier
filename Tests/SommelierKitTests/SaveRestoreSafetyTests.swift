// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A restore overwrites the player's progress, so every way it can go wrong must leave that progress intact.
@Suite struct SaveRestoreSafetyTests {
    let box: SaveSandbox
    let game = SaveSource(root: .roaming, path: "Game")
    let slotPath = "users/me/AppData/Roaming/Game/slot.sav"
    var slot: URL { box.url(slotPath) }

    init() throws {
        box = try SaveSandbox()
        try box.put("backed up", at: slotPath)
    }

    func backupNow(_ store: SaveBackupStore, at time: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> SaveBackupInfo {
        try store.create(gameID: "steam:1", title: "Game", sources: [game], roots: box.roots, now: time)
    }

    /// Rewrites the backup's manifest through a closure on its JSON text.
    func tamper(_ backup: SaveBackupInfo, _ edit: (String) -> String) throws -> SaveBackupInfo {
        let file = backup.folder.appendingPathComponent("manifest.json")
        try Data(edit(try box.read(file)).utf8).write(to: file)
        return try #require(SaveBackupStore.read(backup.folder))
    }

    @Test func missingBackupDiskStopsBeforeOverwriting() throws {
        let made = try backupNow(SaveBackupStore(destination: try box.folder("disk")))
        try Data("progress".utf8).write(to: slot)
        let gone = SaveBackupStore(destination: box.url("ejected"))
        #expect(throws: SaveBackupError.destinationUnavailable) { try gone.restore(made, roots: box.roots) }
        #expect(try box.read(slot) == "progress")
    }

    @Test func emptyBottleNeedsNoSafetyCopy() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let made = try backupNow(store)
        try FileManager.default.removeItem(at: box.url("users"))
        let report = try store.restore(made, roots: box.roots)
        #expect(report.safetyBackup == nil)
        #expect(try box.read(slot) == "backed up")
    }

    @Test func restoringTheOnlyKeptBackupDoesNotPruneItFirst() throws {
        var vault = SaveBackupStore(destination: try box.folder("disk"))
        vault.maximumBackups = 1
        let made = try backupNow(vault)
        try Data("progress".utf8).write(to: slot)
        let outcome = try vault.restore(made, roots: box.roots, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(try box.read(slot) == "backed up")
        let previous = try #require(outcome.safetyBackup)
        #expect(try box.read(previous.folder.appendingPathComponent("data/0/slot.sav")) == "progress")
        // Pruning still happens afterwards: only the newest backup is left.
        #expect(vault.list(gameID: "steam:1", title: "Game").map(\.id) == [previous.id])
    }

    @Test func manifestPathOutsideTheRootIsRefused() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let edited = try tamper(try backupNow(store)) {
            $0.replacingOccurrences(of: "\"path\" : \"Game\"", with: "\"path\" : \"..\\/..\\/escape\"")
        }
        #expect(edited.sources.first?.path == "../../escape")
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(edited, roots: box.roots) }
        #expect(!box.exists("users/escape"))
        #expect(store.list(gameID: "steam:1", title: "Game").count == 1)   // no safety copy was made either
    }

    @Test func manifestDataFolderMustBeANumber() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let made = try backupNow(store)
        try FileManager.default.createDirectory(at: made.folder.appendingPathComponent("data/x"), withIntermediateDirectories: true)
        let edited = try tamper(made) { $0.replacingOccurrences(of: "\"folder\" : \"0\"", with: "\"folder\" : \"x\"") }
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(edited, roots: box.roots) }
    }

    @Test func missingOrLinkedDataFolderIsRefused() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let made = try backupNow(store)
        let data = made.folder.appendingPathComponent("data/0")
        try FileManager.default.removeItem(at: data)
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(made, roots: box.roots) }
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: try box.folder("elsewhere"))
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(made, roots: box.roots) }
    }

    @Test func unknownManifestFormatIsRefused() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let edited = try tamper(try backupNow(store)) { $0.replacingOccurrences(of: "\"format\" : 1", with: "\"format\" : 2") }
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(edited, roots: box.roots) }
    }

    @Test func linkPlantedInTheSaveFolderIsNotWrittenThrough() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let made = try backupNow(store)
        let victim = try box.put("not a save", at: "victim.txt")
        try FileManager.default.removeItem(at: slot)
        try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: victim)
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(made, roots: box.roots) }
        #expect(try box.read(victim) == "not a save")
    }

    @Test func linkedSaveFolderIsNotARestoreTarget() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let made = try backupNow(store)
        let outside = try box.folder("outside")
        try FileManager.default.removeItem(at: box.url("users/me/AppData/Roaming/Game"))
        try FileManager.default.createSymbolicLink(at: box.url("users/me/AppData/Roaming/Game"), withDestinationURL: outside)
        #expect(throws: SaveBackupError.unsafeBackup) { try store.restore(made, roots: box.roots) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func folderInTheWayOfAFileIsNotDeleted() throws {
        let store = SaveBackupStore(destination: try box.folder("disk"))
        let made = try backupNow(store)
        try FileManager.default.removeItem(at: slot)
        try box.put("keep me", at: slotPath + "/inner.txt")
        #expect(throws: SaveBackupError.copyFailed("slot.sav")) { try store.restore(made, roots: box.roots) }
        #expect(try box.read(slot.appendingPathComponent("inner.txt")) == "keep me")
    }
}
