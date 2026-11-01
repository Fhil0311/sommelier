// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A throwaway folder laid out like a bottle (Windows profile `users/me`, Steam `steam/userdata`, game folder
/// `game`) with room for a backup destination. Deleted when the owning suite goes away.
final class SaveSandbox {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-saves-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    var roots: SaveRoots {
        SaveRoots(profile: url("users/me"), steamUserdata: url("steam/userdata"), install: url("game"))
    }

    func url(_ relative: String) -> URL { base.appendingPathComponent(relative) }

    /// Writes a small text file, creating folders on the way, optionally backdating it.
    @discardableResult func put(_ text: String, at relative: String, modified: Date? = nil) throws -> URL {
        let file = url(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return file
    }

    @discardableResult func folder(_ relative: String) throws -> URL {
        let made = url(relative)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    func read(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
}

@Suite struct SaveBackupStoreTests {
    let box: SaveSandbox
    let game = SaveSource(root: .roaming, path: "Cuphead")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws { box = try SaveSandbox() }

    func store(_ destination: String = "Backups") throws -> SaveBackupStore {
        SaveBackupStore(destination: try box.folder(destination))
    }

    @Test func roundTripRestoresContentAndKeepsExtraFiles() throws {
        let slot = try box.put("first", at: "users/me/AppData/Roaming/Cuphead/slot1.sav")
        try box.put("nested", at: "users/me/AppData/Roaming/Cuphead/Profiles/a/b.dat")
        try box.put("finder junk", at: "users/me/AppData/Roaming/Cuphead/.DS_Store")
        try FileManager.default.createSymbolicLink(at: box.url("users/me/AppData/Roaming/Cuphead/escape"), withDestinationURL: box.base)

        let backups = try store()
        let made = try backups.create(gameID: "steam:268910", title: "Cuphead", sources: [game], roots: box.roots, now: t0)
        #expect(made.files == 2)
        #expect(made.kind == .manual)
        #expect(made.sources == [game])
        #expect(made.folder.path.hasSuffix("Backups/Sommelier Saves/Cuphead (steam-268910)/" + made.id))
        #expect(!FileManager.default.fileExists(atPath: made.folder.appendingPathComponent("data/0/escape").path))
        #expect(!FileManager.default.fileExists(atPath: made.folder.appendingPathComponent("data/0/.DS_Store").path))
        #expect(backups.list(gameID: "steam:268910", title: "Cuphead") == [made])

        try Data("later".utf8).write(to: slot)
        try box.put("new slot", at: "users/me/AppData/Roaming/Cuphead/slot2.sav")
        try FileManager.default.removeItem(at: box.url("users/me/AppData/Roaming/Cuphead/Profiles"))

        let outcome = try backups.restore(made, roots: box.roots, now: t0 + 60)
        #expect(outcome.files == 2)
        #expect(try box.read(slot) == "first")
        #expect(try box.read(box.url("users/me/AppData/Roaming/Cuphead/Profiles/a/b.dat")) == "nested")
        #expect(box.exists("users/me/AppData/Roaming/Cuphead/slot2.sav"))

        let before = try #require(outcome.safetyBackup)
        #expect(before.kind == .beforeRestore)
        #expect(try box.read(before.folder.appendingPathComponent("data/0/slot1.sav")) == "later")
        #expect(backups.list(gameID: "steam:268910", title: "Cuphead").map(\.id) == [before.id, made.id])
    }

    @Test func copiesKeepModificationDates() throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try box.put("x", at: "users/me/AppData/Roaming/Cuphead/a.sav", modified: old)
        let made = try store().create(gameID: "steam:1", title: "Cuphead", sources: [game], roots: box.roots, now: t0)
        let copy = made.folder.appendingPathComponent("data/0/a.sav")
        let stamp = try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date
        #expect(stamp == old)
    }

    @Test func manifestKeepsItsOnDiskShape() throws {
        try box.put("12345", at: "users/me/AppData/Roaming/Cuphead/a.sav")
        let made = try store().create(gameID: "gog:42", title: "Cuphead", sources: [game], roots: box.roots,
                                      kind: .automatic, now: t0)
        let raw = try Data(contentsOf: made.folder.appendingPathComponent("manifest.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(Set(json.keys) == ["format", "gameID", "gameTitle", "created", "kind", "entries"])
        #expect(json["format"] as? Int == 1)
        #expect(json["gameID"] as? String == "gog:42")
        #expect(json["kind"] as? String == "automatic")
        #expect(json["created"] as? String == "2027-01-15T08:00:00Z")
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["root"] as? String == "roaming")
        #expect(entries[0]["path"] as? String == "Cuphead")
        #expect(entries[0]["folder"] as? String == "0")
        #expect(entries[0]["files"] as? Int == 1)
        #expect(entries[0]["bytes"] as? Int == 5)
        // Pretty-printed with sorted keys, like every manifest written so far.
        let text = String(decoding: raw, as: UTF8.self)
        #expect(text.contains("\"created\" : "))
        #expect(text.range(of: "\"created\"")!.lowerBound < text.range(of: "\"entries\"")!.lowerBound)
    }

    @Test func refusesWhenThereIsNothingToDo() throws {
        let wanted = SaveSource(root: .roaming, path: "Missing")
        let offline = SaveBackupStore(destination: box.url("unplugged"))
        #expect(throws: SaveBackupError.noSources) {
            try offline.create(gameID: "steam:1", title: "T", sources: [], roots: box.roots)
        }
        #expect(throws: SaveBackupError.destinationUnavailable) {
            try offline.create(gameID: "steam:1", title: "T", sources: [wanted], roots: box.roots)
        }
        #expect(throws: SaveBackupError.nothingToBackUp) {
            try store().create(gameID: "steam:1", title: "T", sources: [wanted], roots: box.roots)
        }
    }

    @Test func onlyExistingSourcesAreCopied() throws {
        try box.put("x", at: "users/me/AppData/Local/Game/a.sav")
        let present = SaveSource(root: .local, path: "Game")
        let made = try store().create(gameID: "epic:g", title: "G", sources: [SaveSource(root: .roaming, path: "Gone"), present],
                                      roots: box.roots, now: t0)
        #expect(made.sources == [present])
        #expect(made.files == 1)
    }

    @Test func backupsInTheSameSecondGetDistinctNames() throws {
        try box.put("x", at: "users/me/AppData/Roaming/Cuphead/a.sav")
        let backups = try store()
        let first = try backups.create(gameID: "steam:1", title: "Cuphead", sources: [game], roots: box.roots, now: t0)
        let second = try backups.create(gameID: "steam:1", title: "Cuphead", sources: [game], roots: box.roots, now: t0)
        #expect(second.id == first.id + "-2")
        #expect(backups.list(gameID: "steam:1", title: "Cuphead").count == 2)
    }

    @Test func gameFolderIsFoundByIDAfterARename() throws {
        try box.put("x", at: "users/me/AppData/Roaming/Cuphead/a.sav")
        let backups = try store()
        let made = try backups.create(gameID: "steam:7", title: "Old Name", sources: [game], roots: box.roots, now: t0)
        #expect(backups.list(gameID: "steam:7", title: "New Name").map(\.id) == [made.id])
        #expect(backups.list(gameID: "steam:77", title: "Old Name").isEmpty)
    }

    @Test func unfinishedCopiesAreNotListed() throws {
        try box.put("x", at: "users/me/AppData/Roaming/Cuphead/a.sav")
        let backups = try store()
        let made = try backups.create(gameID: "steam:1", title: "Cuphead", sources: [game], roots: box.roots, now: t0)
        let partial = made.folder.deletingLastPathComponent().appendingPathComponent(".partial-20990101-000000")
        try FileManager.default.copyItem(at: made.folder, to: partial)
        #expect(backups.list(gameID: "steam:1", title: "Cuphead").map(\.id) == [made.id])
    }

    @Test func oldestBackupsArePruned() throws {
        try box.put("x", at: "users/me/AppData/Roaming/Cuphead/a.sav")
        var backups = try store()
        backups.maximumBackups = 3
        var made: [SaveBackupInfo] = []
        for step in 0..<5 {
            made.append(try backups.create(gameID: "epic:g", title: "G", sources: [game], roots: box.roots, now: t0 + Double(step) * 100))
        }
        #expect(backups.list(gameID: "epic:g", title: "G").map(\.id) == made.suffix(3).reversed().map(\.id))
        #expect(!FileManager.default.fileExists(atPath: made[0].folder.path))
    }

    @Test func noticesChangesAfterADate() throws {
        try box.put("x", at: "users/me/AppData/Roaming/Cuphead/a.sav", modified: Date(timeIntervalSinceNow: -1_000))
        let sources = [game, SaveSource(root: .roaming, path: "Absent")]
        #expect(!SaveBackupStore.hasChanges(sources: sources, roots: box.roots, since: Date(timeIntervalSinceNow: -500)))
        #expect(SaveBackupStore.hasChanges(sources: sources, roots: box.roots, since: Date(timeIntervalSinceNow: -2_000)))
        #expect(!SaveBackupStore.hasChanges(sources: [], roots: box.roots, since: .distantPast))
    }

    @Test func namesAreSafeForTheFileSystem() {
        #expect(SaveBackupStore.safeTitle("Hades: Edition/1") == "Hades- Edition-1")
        #expect(SaveBackupStore.safeTitle("  a*b?c\"d<e>f|g\\h\u{7}  ") == "a-b-c-d-e-f-g-h-")
        #expect(SaveBackupStore.safeTitle("   ") == "Game")
        #expect(SaveBackupStore.safeTitle(String(repeating: "é", count: 80)).count == 60)
        #expect(SaveBackupStore.safeID("steam:268910") == "steam-268910")
        #expect(SaveBackupStore.safeID("epic:Sugar_1.x/y z") == "epic-Sugar_1.x-y-z")
    }
}
