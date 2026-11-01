// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Placing mods into made-up game folders and taking them out again, against the fixture profiles.
struct ModDeployerTests {
    /// A game folder, a store and the deployer joining them, all in temporary folders.
    private struct Bench {
        let game: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile

        init(_ profile: ModProfile, appdata: Bool = false) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-deploy-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("Game", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: support.appendingPathComponent("AppData/Local"), withIntermediateDirectories: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/test", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: support,
                                 appdata: appdata ? support.appendingPathComponent("AppData/Local", isDirectory: true) : nil)
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        /// A mod in the store, made from a layout planned against the profile.
        func stored(_ name: String, _ files: [String: String], manifests: [String: Data] = [:]) throws -> StoredMod {
            let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-unpacked-\(UUID().uuidString)", isDirectory: true)
            try ModDeployerTests.layout(files, in: unpacked)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name, manifests: manifests)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }
    }

    private func profile(_ id: String) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
        return try #require(list.profile(covering: id))
    }

    static func layout(_ files: [String: String], in root: URL) throws {
        for (path, text) in files {
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Every file and folder below `root` with the files' bytes: the tree as it is, byte for byte.
    private func snapshot(_ root: URL) -> [String: Data] {
        var tree: [String: Data] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let top = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return tree }
        for case let item as URL in walker {
            let relative = String(item.resolvingSymlinksInPath().path.dropFirst(top.count + 1))
            if (try? item.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
                tree[relative + "/"] = Data()
            } else {
                tree[relative] = (try? Data(contentsOf: item)) ?? Data()
            }
        }
        return tree
    }

    private func inode(_ url: URL) -> UInt64? { (FileScan.attributes(url)?[.systemFileNumber] as? NSNumber)?.uint64Value }

    private let pakTriple = ["zCool_P.pak": "pak bytes", "zCool_P.ucas": "ucas bytes", "zCool_P.utoc": "utoc bytes"]

    @Test func deployThenUninstallRestoresTheTree() throws {
        let bench = Bench(try profile("steam:990080"))
        try Self.layout(["Phoenix/Binaries/Win64/HogwartsLegacy.exe": "MZ", "Phoenix/Content/Paks/pakchunk0-WindowsNoEditor.pak": "game pak"], in: bench.game)
        let before = snapshot(bench.game)
        let mod = try bench.stored("Cool", pakTriple)

        let outcome = try bench.deployer.deploy(mod, slot: "010_cool")
        #expect(outcome.placed == ["game:Phoenix/Content/Paks/~mods/010_cool/zCool_P.pak", "game:Phoenix/Content/Paks/~mods/010_cool/zCool_P.ucas",
                                   "game:Phoenix/Content/Paks/~mods/010_cool/zCool_P.utoc"])
        #expect(outcome.linked == 3 && outcome.copied == 0 && outcome.overwroteForeign.isEmpty)
        #expect(bench.text("Phoenix/Content/Paks/~mods/010_cool/zCool_P.pak") == "pak bytes")
        #expect(inode(bench.url("Phoenix/Content/Paks/~mods/010_cool/zCool_P.pak")) == inode(bench.store.file(of: mod.key, at: "zCool_P.pak")), "a hard link, not a copy")
        #expect(try bench.deployer.isDeployed(mod.key) && bench.deployer.deployed(mod.key).count == 3 && bench.deployer.owners() == [mod.key])
        #expect(bench.deployer.verify().isEmpty)
        // Deploying again changes nothing.
        #expect(try bench.deployer.deploy(mod, slot: "010_cool") == ModDeployer.Outcome())

        let removal = try bench.deployer.remove(owner: mod.key)
        #expect(removal.removed.count == 3 && removal.restored.isEmpty && removal.kept.isEmpty)
        #expect(snapshot(bench.game) == before, "the game folder is as it was, the ~mods folder included")
        #expect(try !bench.deployer.isDeployed(mod.key) && bench.deployer.owners().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bench.store.deployedFile.path))
        #expect(bench.store.mod(mod.key) == mod, "the store still has the mod")
        #expect(throws: ModDeployError.notDeployed(mod.key)) { try bench.deployer.remove(owner: mod.key) }
    }

    @Test func overwrittenOriginalIsBackedUpAndRestored() throws {
        let bench = Bench(try profile("steam:990080"))
        try Self.layout(["Phoenix/Content/Movies/Intro.bk2": "original intro", "Phoenix/Content/Movies/Logo.bk2": "logo"], in: bench.game)
        let before = snapshot(bench.game)
        let mod = try bench.stored("No Intro", ["Movies/Intro.bk2": "modded intro"])
        #expect(mod.units.first?.kind.id == "movie" && mod.units.first?.kind.backupOriginal == true)

        let outcome = try bench.deployer.deploy(mod)
        #expect(outcome.placed == ["game:Phoenix/Content/Movies/Intro.bk2"] && outcome.overwroteForeign.isEmpty, "the kind expects to overwrite")
        #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == "modded intro" && bench.text("Phoenix/Content/Movies/Logo.bk2") == "logo")
        let kept = bench.store.originals.appendingPathComponent("game/Phoenix/Content/Movies/Intro.bk2")
        #expect(try String(contentsOf: kept, encoding: .utf8) == "original intro")

        let removal = try bench.deployer.remove(owner: mod.key)
        #expect(removal.removed == ["game:Phoenix/Content/Movies/Intro.bk2"] && removal.restored == ["game:Phoenix/Content/Movies/Intro.bk2"])
        #expect(snapshot(bench.game) == before)
        #expect(!FileManager.default.fileExists(atPath: bench.store.originals.path), "nothing left to keep")

        // A file in the way the kind didn't expect is kept all the same, and reported.
        let re4 = Bench(try profile("steam:2050650"))
        try Self.layout(["natives/STM/_Chainsaw/Item.user.2": "someone's"], in: re4.game)
        let loose = try re4.stored("Stacks", ["natives/STM/_Chainsaw/Item.user.2": "stacks"])
        let placed = try re4.deployer.deploy(loose)
        #expect(placed.overwroteForeign == ["game:natives/STM/_Chainsaw/Item.user.2"] && re4.text("natives/STM/_Chainsaw/Item.user.2") == "stacks")
        try re4.deployer.remove(owner: loose.key)
        #expect(re4.text("natives/STM/_Chainsaw/Item.user.2") == "someone's")
    }

    @Test func verifyFindsWhatAGameUpdateChangedAndRepairs() throws {
        let bench = Bench(try profile("steam:990080"))
        let mod = try bench.stored("Cool", pakTriple)
        try bench.deployer.deploy(mod, slot: "010_cool")
        let pak = "Phoenix/Content/Paks/~mods/010_cool/zCool_P.pak", utoc = "Phoenix/Content/Paks/~mods/010_cool/zCool_P.utoc"

        // The game's update replaces one file (a new file, not our link) and drops another.
        try FileManager.default.removeItem(at: bench.url(pak))
        try "patched by the game".write(to: bench.url(pak), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: bench.url(utoc))
        let findings = bench.deployer.verify()
        #expect(findings == [.init(owner: mod.key, destination: "game:" + pak, problem: .replaced), .init(owner: mod.key, destination: "game:" + utoc, problem: .missing)])

        let repaired = try bench.deployer.repair(findings)
        #expect(repaired.placed == ["game:" + pak, "game:" + utoc] && repaired.linked == 2)
        #expect(bench.text(pak) == "pak bytes" && bench.text(utoc) == "utoc bytes")
        #expect(inode(bench.url(pak)) == inode(bench.store.file(of: mod.key, at: "zCool_P.pak")))
        #expect(bench.deployer.verify().isEmpty)
        #expect(try String(contentsOf: bench.store.originals.appendingPathComponent("game/" + pak), encoding: .utf8) == "patched by the game", "the game's newer file is the original now")

        // The uninstall gives the game back as the update left it.
        let removal = try bench.deployer.remove(owner: mod.key)
        #expect(removal.removed.count == 3 && removal.restored == ["game:" + pak])
        #expect(bench.text(pak) == "patched by the game" && !bench.exists(utoc) && !bench.exists("Phoenix/Content/Paks/~mods/010_cool/zCool_P.ucas"))

        // A file the game wrote into (new content under our path, no link) is not ours to delete.
        let again = try bench.deployer.deploy(mod, slot: "010_cool")
        #expect(again.placed.count == 3 && again.overwroteForeign == ["game:" + pak], "the patched file was in the way")
        try FileManager.default.removeItem(at: bench.url(utoc))
        try "the game's own".write(to: bench.url(utoc), atomically: true, encoding: .utf8)
        let careful = try bench.deployer.remove(owner: mod.key)
        #expect(careful.kept == ["game:" + utoc] && bench.text(utoc) == "the game's own" && bench.text(pak) == "patched by the game")

        // A store file gone is reported, never "repaired" from nothing.
        let other = try bench.stored("Other", ["zOther_P.pak": "p", "zOther_P.ucas": "u", "zOther_P.utoc": "t"])
        try bench.deployer.deploy(other, slot: "020_other")
        try FileManager.default.removeItem(at: bench.store.file(of: other.key, at: "zOther_P.ucas"))
        #expect(bench.deployer.verify() == [.init(owner: other.key, destination: "game:Phoenix/Content/Paks/~mods/020_other/zOther_P.ucas", problem: .storeMissing)])
    }

    @Test func foreignFilesInTheSameFolderStay() throws {
        let bench = Bench(try profile("steam:413150"))
        try Self.layout(["Mods/ConsoleCommands/manifest.json": "smapi's", "Mods/SaveBackup/manifest.json": "smapi's too", "Stardew Valley.dll": "game"], in: bench.game)
        let before = snapshot(bench.game)
        let mod = try bench.stored("CJB Cheats Menu", ["CJB Cheats Menu/manifest.json": "{}", "CJB Cheats Menu/CJBCheatsMenu.dll": "MZ", "CJB Cheats Menu/i18n/default.json": "{}"])

        let outcome = try bench.deployer.deploy(mod)
        #expect(outcome.placed.count == 3 && outcome.overwroteForeign.isEmpty)
        #expect(bench.text("Mods/CJB Cheats Menu/i18n/default.json") == "{}" && bench.text("Mods/ConsoleCommands/manifest.json") == "smapi's")

        try bench.deployer.remove(owner: mod.key)
        #expect(snapshot(bench.game) == before, "SMAPI's own mods and the Mods folder stay")
    }

    @Test func dotPrefixTurnsAModOffWithoutUnlinking() throws {
        let bench = Bench(try profile("steam:413150"))
        try Self.layout(["Mods/ConsoleCommands/manifest.json": "smapi's"], in: bench.game)
        let before = snapshot(bench.game)
        let mod = try bench.stored("CJB Cheats Menu", ["CJB Cheats Menu/manifest.json": "{}", "CJB Cheats Menu/CJBCheatsMenu.dll": "MZ"])
        try bench.deployer.deploy(mod)

        try bench.deployer.setEnabled(mod, false)
        #expect(!bench.exists("Mods/CJB Cheats Menu") && bench.text("Mods/.CJB Cheats Menu/manifest.json") == "{}" && bench.exists("Mods/.CJB Cheats Menu/CJBCheatsMenu.dll"))
        #expect(try bench.deployer.verify().isEmpty && bench.deployer.isDeployed(mod.key), "the files are still there, just hidden")
        #expect(inode(bench.url("Mods/.CJB Cheats Menu/CJBCheatsMenu.dll")) == inode(bench.store.file(of: mod.key, at: "CJBCheatsMenu.dll")), "the folder was the wrapper")
        try bench.deployer.setEnabled(mod, false)
        #expect(bench.exists("Mods/.CJB Cheats Menu/manifest.json"), "off twice is still off")

        try bench.deployer.setEnabled(mod, true)
        #expect(bench.text("Mods/CJB Cheats Menu/manifest.json") == "{}" && !bench.exists("Mods/.CJB Cheats Menu"))
        #expect(bench.deployer.verify().isEmpty)

        // Removed while off: the hidden folder goes too.
        try bench.deployer.setEnabled(mod, false)
        try bench.deployer.remove(owner: mod.key)
        #expect(snapshot(bench.game) == before)
    }

    @Test func modsTxtLineTurnsALuaModOff() throws {
        let bench = Bench(try profile("steam:990080"))
        let modsTxt = "Phoenix/Binaries/Win64/Mods/mods.txt"
        try Self.layout([modsTxt: "CheatManagerEnablerMod : 1\r\nKeybinds : 1\r\n"], in: bench.game)
        let mod = try bench.stored("MyMod", ["MyMod/Scripts/main.lua": "print()", "MyMod/enabled.txt": ""])
        #expect(mod.units.first?.kind.enable?.format == .ue4ssModsTxt)
        try bench.deployer.deploy(mod)
        #expect(bench.text("Phoenix/Binaries/Win64/Mods/MyMod/Scripts/main.lua") == "print()")

        try bench.deployer.setEnabled(mod, false)
        #expect(bench.text(modsTxt) == "CheatManagerEnablerMod : 1\r\nKeybinds : 1\r\nMyMod : 0\r\n", "other lines and line endings untouched")
        #expect(bench.text("Phoenix/Binaries/Win64/Mods/MyMod/Scripts/main.lua") == "print()" && bench.deployer.verify().isEmpty)
        try bench.deployer.setEnabled(mod, true)
        #expect(bench.text(modsTxt) == "CheatManagerEnablerMod : 1\r\nKeybinds : 1\r\nMyMod : 1\r\n")

        // A mod without an enable format is unlinked when off and placed again when on.
        let pak = try bench.stored("Cool", pakTriple)
        try bench.deployer.deploy(pak, slot: "010_cool")
        try bench.deployer.setEnabled(pak, false, slot: "010_cool")
        #expect(try !bench.exists("Phoenix/Content/Paks/~mods") && !bench.deployer.isDeployed(pak.key) && bench.store.mod(pak.key) != nil)
        try bench.deployer.setEnabled(pak, false, slot: "010_cool")
        try bench.deployer.setEnabled(pak, true, slot: "010_cool")
        #expect(bench.text("Phoenix/Content/Paks/~mods/010_cool/zCool_P.pak") == "pak bytes")
    }

    @Test func aLaterModShadowsAnEarlierOneAndItComesBack() throws {
        let bench = Bench(try profile("steam:2050650"))
        try Self.layout(["re4.exe": "MZ"], in: bench.game)
        let before = snapshot(bench.game)
        let path = "natives/STM/_Chainsaw/Item.user.2"
        let a = try bench.stored("A", [path: "aaa", "natives/STM/_Chainsaw/OnlyA.user.2": "a only"])
        let b = try bench.stored("B", [path: "bbb"])
        try bench.deployer.deploy(a)
        try bench.deployer.deploy(b)
        #expect(bench.text(path) == "bbb" && bench.deployer.verify().isEmpty)
        #expect(bench.deployer.deployed(a.key).count == 2 && bench.deployer.deployed(b.key) == ["game:" + path])

        let removal = try bench.deployer.remove(owner: b.key)
        #expect(removal.removed == ["game:" + path] && removal.restored == ["game:" + path])
        #expect(bench.text(path) == "aaa" && inode(bench.url(path)) == inode(bench.store.file(of: a.key, at: path)))
        #expect(bench.deployer.verify().isEmpty && bench.text("natives/STM/_Chainsaw/OnlyA.user.2") == "a only")

        // Taking the lower one out while shadowed only drops its record; the upper file stays.
        try bench.deployer.deploy(b)
        let lower = try bench.deployer.remove(owner: a.key)
        #expect(lower.removed == ["game:natives/STM/_Chainsaw/OnlyA.user.2"] && bench.text(path) == "bbb")
        try bench.deployer.remove(owner: b.key)
        #expect(snapshot(bench.game) == before)
    }

    @Test func aFileChangedSinceItWasPlacedIsKeptWhenAnotherModCovers() throws {
        let bench = Bench(try profile("steam:2050650"))
        try Self.layout(["re4.exe": "MZ"], in: bench.game)
        let path = "natives/STM/_Chainsaw/Item.user.2"
        let a = try bench.stored("A", [path: "aaa"])
        let b = try bench.stored("B", [path: "bbb"])
        try bench.deployer.deploy(a)
        // The player edits A's file in an editor that saves a new file in its place.
        try FileManager.default.removeItem(at: bench.url(path))
        try "edited".write(to: bench.url(path), atomically: true, encoding: .utf8)

        try bench.deployer.deploy(b)
        #expect(bench.text(path) == "bbb")
        try bench.deployer.remove(owner: b.key)
        #expect(bench.text(path) == "aaa", "the mod underneath comes back as it was placed")
        try bench.deployer.remove(owner: a.key)
        #expect(bench.text(path) == "edited", "the player's edit was kept aside, not deleted")
        let record = try bench.deployer.load()
        #expect(record.entries.isEmpty && record.backups.isEmpty, "nothing left behind in .originals")
    }

    @Test func anUnreadableRecordStopsTheRemoval() throws {
        let bench = Bench(try profile("steam:2050650"))
        try Self.layout(["re4.exe": "MZ"], in: bench.game)
        let a = try bench.stored("A", ["natives/STM/_Chainsaw/Item.user.2": "aaa"])
        try bench.deployer.deploy(a)
        try Data("{ not a record".utf8).write(to: bench.store.deployedFile)
        #expect(throws: ModDeployError.recordUnreadable) { try bench.deployer.isDeployed(a.key) }
        #expect(throws: ModDeployError.recordUnreadable) { try bench.deployer.remove(owner: a.key) }
        #expect(bench.text("natives/STM/_Chainsaw/Item.user.2") == "aaa")
    }

    @Test func nextNumberFollowsTheExistingPatches() throws {
        let bench = Bench(try profile("steam:2050650"))
        try Self.layout(["re_chunk_000.pak": "game", "re_chunk_000.pak.patch_001.pak": "p1", "re_chunk_000.pak.patch_002.pak": "p2", "re_chunk_000.pak.patch_003.pak": "p3"], in: bench.game)
        let before = snapshot(bench.game)
        let first = try bench.stored("First", ["Cool.pak": "cool"])
        #expect(first.units.first?.files.first?.needsNext == true)
        let second = try bench.stored("Second", ["Nice.pak": "nice"])

        #expect(try bench.deployer.deploy(first).placed == ["game:re_chunk_000.pak.patch_004.pak"])
        #expect(try bench.deployer.deploy(second).placed == ["game:re_chunk_000.pak.patch_005.pak"])
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "cool" && bench.text("re_chunk_000.pak.patch_005.pak") == "nice")
        try bench.deployer.remove(owner: first.key)
        // The game stops at the first missing number: the one above moves down into the hole it left.
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "nice" && !bench.exists("re_chunk_000.pak.patch_005.pak"))
        // A new one goes after the highest.
        let third = try bench.stored("Third", ["Third.pak": "third"])
        #expect(try bench.deployer.deploy(third).placed == ["game:re_chunk_000.pak.patch_005.pak"])
        try bench.deployer.remove(owner: second.key)
        try bench.deployer.remove(owner: third.key)
        #expect(snapshot(bench.game) == before)
        #expect(try bench.deployer.deploy(first).placed == ["game:re_chunk_000.pak.patch_004.pak"])
    }

    @Test func frameworkFilesAndCopiesAreRecordedLikeMods() throws {
        let bench = Bench(try profile("steam:413150"))
        try Self.layout(["Stardew Valley.deps.json": "deps v1", "Stardew Valley.dll": "game"], in: bench.game)
        let before = snapshot(bench.game)
        let owner = "framework:smapi"
        let dropped = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-smapi-\(UUID().uuidString)", isDirectory: true)
        try Self.layout(["StardewModdingAPI.dll": "MZ smapi", "smapi-internal/x.dll": "MZ x"], in: dropped)

        let placed = try bench.deployer.deploy(owner: owner, [.init(from: dropped.appendingPathComponent("StardewModdingAPI.dll"), to: "game:StardewModdingAPI.dll"),
                                                             .init(from: dropped.appendingPathComponent("smapi-internal/x.dll"), to: "game:smapi-internal/x.dll")])
        #expect(placed.placed == ["game:StardewModdingAPI.dll", "game:smapi-internal/x.dll"])
        let copied = try bench.deployer.copy(owner: owner, from: "game:Stardew Valley.deps.json", to: "game:StardewModdingAPI.deps.json")
        #expect(copied.copied == 1 && copied.linked == 0 && bench.text("StardewModdingAPI.deps.json") == "deps v1")
        #expect(inode(bench.url("StardewModdingAPI.deps.json")) != inode(bench.url("Stardew Valley.deps.json")), "a copy, never a link")
        #expect(bench.deployer.verify().isEmpty && bench.deployer.deployed(owner).count == 3)

        // The game updates its deps.json: the copy is stale until repaired.
        try "deps v2".write(to: bench.url("Stardew Valley.deps.json"), atomically: true, encoding: .utf8)
        let findings = bench.deployer.verify()
        #expect(findings == [.init(owner: owner, destination: "game:StardewModdingAPI.deps.json", problem: .replaced)])
        try bench.deployer.repair(findings)
        #expect(bench.text("StardewModdingAPI.deps.json") == "deps v2" && bench.deployer.verify().isEmpty)

        try bench.deployer.remove(owner: owner)
        var expected = before
        expected["Stardew Valley.deps.json"] = Data("deps v2".utf8)
        #expect(snapshot(bench.game) == expected, "the game's own file is left as the game made it")

        // Placing into a root this copy doesn't have, or a bad spec, is refused before anything is written.
        #expect(throws: ModDeployError.rootUnavailable("appdata:x/y.ini")) {
            try bench.deployer.deploy(owner: owner, [.init(from: dropped.appendingPathComponent("StardewModdingAPI.dll"), to: "appdata:x/y.ini")])
        }
        #expect(throws: ModDeployError.badDestination("game:Mods/")) {
            try bench.deployer.deploy(owner: owner, [.init(from: dropped.appendingPathComponent("StardewModdingAPI.dll"), to: "game:Mods/")])
        }
        #expect(throws: ModDeployError.sourceMissing(dropped.appendingPathComponent("gone.dll").path)) {
            try bench.deployer.deploy(owner: owner, [.init(from: dropped.appendingPathComponent("gone.dll"), to: "game:gone.dll")])
        }
        #expect(try !bench.deployer.isDeployed(owner) && snapshot(bench.game) == expected)
    }
}
