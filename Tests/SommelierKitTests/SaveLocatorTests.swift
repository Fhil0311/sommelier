// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SaveLocationTests {
    let box: SaveSandbox

    init() throws { box = try SaveSandbox() }

    @Test func relativePathSafety() {
        for good in ["Cuphead", "My Games/Foo", "a.b/c d", "..hidden"] {
            #expect(SaveSource.isSafe(good), "\(good)")
        }
        for bad in ["", "/etc", "../x", "a/../b", "a/./b", "a//b", "a/", ".", "nul\0byte"] {
            #expect(!SaveSource.isSafe(bad), "\(bad)")
        }
    }

    @Test func titlesAndDisplayPaths() {
        #expect(SaveRoot.roaming.title == "AppData\\Roaming")
        #expect(SaveRoot.savedGames.title == "Saved Games")
        #expect(SaveRoot.steamUserdata.title == "Steam Cloud")
        #expect(SaveRoot.install.title == "Game folder")
        #expect(SaveSource(root: .localLow, path: "Studio/Game").displayPath == "AppData\\LocalLow\\Studio\\Game")
        #expect(SaveSource(root: .documents, path: "x").id == "documents/x")
    }

    @Test func basesForEachRoot() {
        let roots = box.roots
        #expect(roots.base(.documents)?.path == box.url("users/me/Documents").path)
        #expect(roots.base(.local)?.path == box.url("users/me/AppData/Local").path)
        #expect(roots.base(.steamUserdata) == box.url("steam/userdata"))
        #expect(roots.base(.install) == box.url("game"))
        #expect(SaveRoots(profile: box.base).base(.install) == nil)
    }

    @Test func bottleRootsPreferTheUnifiedProfile() throws {
        let bottle = Bottle(kind: .steam, paths: Paths(home: box.base))
        let fallback = SaveRoots(bottle: bottle, installPath: nil, userName: "anna")
        #expect(fallback.profile.lastPathComponent == UserProfiles.crossOverName)
        try FileManager.default.createDirectory(at: bottle.driveC.appendingPathComponent("users/anna"), withIntermediateDirectories: true)
        let unified = SaveRoots(bottle: bottle, installPath: nil, userName: "anna")
        #expect(unified.profile.lastPathComponent == "anna")
        #expect(unified.steamUserdata == bottle.steamDirectory.appendingPathComponent("userdata", isDirectory: true))
    }

    @Test func resolveStaysInsideAndRefusesLinks() throws {
        try box.folder("users/me/AppData/Roaming/Cuphead")
        let roaming = box.url("users/me/AppData/Roaming")
        try FileManager.default.createSymbolicLink(at: roaming.appendingPathComponent("Evil"), withDestinationURL: try box.folder("outside"))
        let roots = box.roots

        #expect(roots.resolve(SaveSource(root: .roaming, path: "Cuphead"))?.lastPathComponent == "Cuphead")
        #expect(roots.resolve(SaveSource(root: .roaming, path: "Evil")) == nil)
        #expect(roots.resolve(SaveSource(root: .roaming, path: "Evil/inner")) == nil)
        #expect(roots.resolve(SaveSource(root: .roaming, path: "../Local")) == nil)
        // Not there yet is fine: a restore into a fresh bottle creates it.
        #expect(roots.resolve(SaveSource(root: .roaming, path: "New/Folder"))?.path.hasSuffix("Roaming/New/Folder") == true)
        #expect(SaveRoots(profile: box.base).resolve(SaveSource(root: .install, path: "x")) == nil)
    }

    @Test func resolveFollowsALinkedDocumentsFolder() throws {
        let macDocuments = try box.folder("MacDocuments")
        try FileManager.default.createDirectory(at: box.url("users/me"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.url("users/me/Documents"), withDestinationURL: macDocuments)
        let found = box.roots.resolve(SaveSource(root: .documents, path: "My Games/X"))
        #expect(found?.path == macDocuments.resolvingSymlinksInPath().appendingPathComponent("My Games/X").path)
    }

    @Test func pickedFolderBecomesASource() throws {
        let picked = try box.folder("users/me/AppData/LocalLow/Studio/Game")
        let roots = box.roots
        #expect(roots.source(for: picked) == SaveSource(root: .localLow, path: "Studio/Game"))
        #expect(roots.source(for: try box.folder("steam/userdata/5/70")) == SaveSource(root: .steamUserdata, path: "5/70"))
        #expect(roots.source(for: box.url("elsewhere")) == nil)
        #expect(roots.source(for: box.url("users/me/AppData/Roaming")) == nil)   // a root itself isn't a save folder
    }

    @Test func measureCountsFilesAndStopsAtTheLimit() throws {
        let newest = Date(timeIntervalSince1970: 1_750_000_000)
        try box.put("abc", at: "m/a.txt", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try box.put("de", at: "m/sub/b.txt", modified: newest)
        try FileManager.default.createSymbolicLink(at: box.url("m/link"), withDestinationURL: box.base)
        let full = FileScan.measure(box.url("m"))
        #expect(full == FileScan.Measure(bytes: 5, files: 2, newest: newest, truncated: false))
        #expect(FileScan.measure(box.url("m"), limit: 2).truncated)
        #expect(FileScan.measure(box.url("absent")) == FileScan.Measure())
    }

    @Test func titleKeysAndFolderMatching() {
        #expect(Set(SaveLocator.nameKeys("The Witcher 3: Wild Hunt")) == ["thewitcher3wildhunt", "thewitcher3"])
        #expect(SaveLocator.nameKeys("Hades") == ["hades"])
        #expect(SaveLocator.nameKeys("Ys").isEmpty)
        #expect(SaveLocator.normalize("Studio_MDHR 2!") == "studiomdhr2")
        #expect(SaveLocator.matches("The Witcher 3", keys: ["thewitcher3"]))
        #expect(SaveLocator.matches("Hades II", keys: ["hadesii", "hades"]))
        #expect(SaveLocator.matches("CupheadSaves", keys: ["cuphead"]))
        #expect(!SaveLocator.matches("Hadesx", keys: ["hade"]))    // containment needs five characters
        #expect(!SaveLocator.matches("---", keys: ["game"]))
        #expect(SaveLocator.isNoise(".cache") && SaveLocator.isNoise("Microsoft") && !SaveLocator.isNoise("Cuphead"))
    }

    @Test func findsByNameByLocationAndByRecentChange() throws {
        let old = Date(timeIntervalSinceNow: -86_400 * 30)
        let recent = Date(timeIntervalSinceNow: -60)
        try box.put("a", at: "users/me/AppData/Roaming/The Witcher 3/user.settings", modified: old)
        try box.put("b", at: "users/me/AppData/LocalLow/Studio MDHR/Cuphead/save.dat", modified: old)
        try box.put("c", at: "users/me/AppData/Local/Mystery Dev/Mystery Game/slot1.sav", modified: recent)
        try box.put("n", at: "users/me/AppData/Local/Microsoft/cache.bin", modified: recent)
        try box.put("t", at: "users/me/AppData/Local/Temp/x.tmp", modified: recent)
        try box.put("d", at: "users/me/Documents/My Games/Some Game/profile.sav", modified: recent)
        try box.put("e", at: "steam/userdata/12345/268910/remote/save.bin", modified: old)
        try box.put("z", at: "steam/userdata/0/268910/remote/save.bin", modified: old)
        try box.put("f", at: "game/Saves/slot.sav", modified: old)
        try box.folder("users/me/AppData/Roaming/The Witcher 3 Empty")
        let roots = box.roots

        let witcher = SaveLocator.candidates(title: "The Witcher 3: Wild Hunt", steamAppID: nil, roots: roots)
        #expect(witcher.map(\.source) == [SaveSource(root: .roaming, path: "The Witcher 3"), SaveSource(root: .install, path: "Saves")])
        #expect(witcher.map(\.reason) == [.nameMatch, .installFolder])
        #expect(witcher[0].files == 1 && witcher[0].bytes == 1)

        let cuphead = SaveLocator.candidates(title: "Cuphead", steamAppID: "268910", roots: roots)
        #expect(cuphead.first?.source == SaveSource(root: .steamUserdata, path: "12345/268910"))
        #expect(cuphead.map(\.reason).first == .steamCloud)
        #expect(!cuphead.contains { $0.source.path.hasPrefix("0/") })
        #expect(cuphead.contains { $0.source == SaveSource(root: .localLow, path: "Studio MDHR/Cuphead") && $0.reason == .nameMatch })

        let recentOnly = SaveLocator.candidates(title: "Unrelated Title", steamAppID: nil, roots: roots,
                                                changedSince: Date(timeIntervalSinceNow: -3_600))
        let sources = Set(recentOnly.map(\.source))
        #expect(sources.contains(SaveSource(root: .local, path: "Mystery Dev/Mystery Game")))
        #expect(sources.contains(SaveSource(root: .documents, path: "My Games/Some Game")))
        #expect(!sources.contains { $0.path.lowercased().contains("microsoft") || $0.path.lowercased().contains("temp") })
        #expect(recentOnly.allSatisfy { $0.reason == .recentlyChanged || $0.reason == .installFolder })
    }

    @Test func strongestClueWinsForTheSameFolder() throws {
        try box.put("x", at: "users/me/AppData/Roaming/Hades/a.sav", modified: Date())
        let found = SaveLocator.candidates(title: "Hades", steamAppID: nil, roots: box.roots, changedSince: .distantPast)
        #expect(found.filter { $0.source.path == "Hades" }.map(\.reason) == [.nameMatch])
    }
}
