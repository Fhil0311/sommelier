// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The deployer and the planner where a mistake costs the player a game file or runs code they weren't told
/// about: one file under two spellings, a deploy that fails half way, a mod folder named like Sommelier's own,
/// numbered paks around the game's own patches, DLLs a Mod Engine 2 config names, SMAPI manifests with comments,
/// and UE4SS's `mods.txt` line for a new Lua mod.
struct ModSafetyTests {
    private struct Bench {
        let game: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile

        init(_ profile: ModProfile) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-safety-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("Game", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/test", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: support)
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
        func names(in relative: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url(relative).path)) ?? []).sorted() }

        func stored(_ name: String, _ files: [String: String], manifests: [String: Data] = [:]) throws -> StoredMod {
            let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-unpacked-\(UUID().uuidString)", isDirectory: true)
            try ModSafetyTests.layout(files, in: unpacked)
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

    // MARK: One file, two spellings

    @Test func twoSpellingsOfOneFileKeepTheOriginal() throws {
        for removeFirst in ["A", "B"] {
            let bench = Bench(try profile("steam:990080"))
            try Self.layout(["Phoenix/Content/Movies/Intro.bk2": "original"], in: bench.game)
            let a = try bench.stored("A", ["Movies/Intro.bk2": "mod A"])
            let b = try bench.stored("B", ["movies/intro.bk2": "mod B"])
            #expect(b.units.first?.files.first?.destination == "game:Phoenix/Content/movies/intro.bk2")

            try bench.deployer.deploy(a)
            try bench.deployer.deploy(b)
            #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == "mod B", "the later mod is on top")
            #expect(bench.deployer.shadowed(a.key) == ["game:Phoenix/Content/Movies/Intro.bk2"], "B's file sits on A's, one file")

            let first = removeFirst == "A" ? a : b, second = removeFirst == "A" ? b : a
            try bench.deployer.remove(owner: first.key)
            #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == (removeFirst == "A" ? "mod B" : "mod A"))
            let last = try bench.deployer.remove(owner: second.key)
            #expect(last.kept.isEmpty)
            #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == "original", "the game's file is back, whoever left first")
            #expect(bench.names(in: "Phoenix/Content/Movies") == ["Intro.bk2"], "under its own name")
            #expect(!FileManager.default.fileExists(atPath: bench.store.originals.path))
        }
    }

    // MARK: A deploy that fails half way

    @Test func aFailedDeployTakesBackWhatItPlaced() throws {
        let bench = Bench(try profile("steam:990080"))
        try Self.layout(["Phoenix/Content/Movies/Intro.bk2": "original intro", "Phoenix/Content/Movies/Logo.bk2": "original logo"], in: bench.game)
        let mod = try bench.stored("No Intro", ["Movies/Intro.bk2": "modded intro", "Movies/Logo.bk2": "modded logo"])
        try FileManager.default.removeItem(at: bench.store.file(of: mod.key, at: "Movies/Logo.bk2"))   // the second file can't be placed

        #expect(throws: ModDeployError.self) { try bench.deployer.deploy(mod) }
        #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == "original intro", "the first file's original came back")
        #expect(bench.text("Phoenix/Content/Movies/Logo.bk2") == "original logo")
        #expect(try !bench.deployer.isDeployed(mod.key))
        #expect(!FileManager.default.fileExists(atPath: bench.store.originals.path), "nothing is left in .originals")

        // Another mod coming and going afterwards still gives back the real original.
        let other = try bench.stored("Other", ["Movies/Intro.bk2": "other intro"])
        try bench.deployer.deploy(other)
        try bench.deployer.remove(owner: other.key)
        #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == "original intro")
    }

    @Test func aFailedFrameworkDeployLeavesNoFolders() throws {
        let bench = Bench(try profile("steam:990080"))
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-staged-\(UUID().uuidString)", isDirectory: true)
        try Self.layout(["dwmapi.dll": "proxy"], in: staged)
        let placements = [ModDeployer.Placement(from: staged.appendingPathComponent("dwmapi.dll"), to: "game:Phoenix/Binaries/Win64/dwmapi.dll"),
                          ModDeployer.Placement(from: staged.appendingPathComponent("missing.dll"), to: "game:Phoenix/Binaries/Win64/ue4ss/UE4SS.dll")]
        #expect(throws: ModDeployError.self) { try bench.deployer.deploy(owner: "framework:ue4ss", placements) }
        #expect(!bench.exists("Phoenix"), "the folders made on the way went too")
        #expect(bench.deployer.owners().isEmpty)
    }

    @Test func aKeptOriginalIsNeverReplaced() throws {
        let bench = Bench(try profile("steam:990080"))
        try Self.layout(["Phoenix/Content/Movies/Intro.bk2": "original"], in: bench.game)
        // A record left with an original but no file of a mod's over it (an older version's leftovers).
        let kept = bench.store.originals.appendingPathComponent("game/Phoenix/Content/Movies/Intro.bk2")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "the real original".write(to: kept, atomically: true, encoding: .utf8)
        let record = #"{"backups":{"game:Phoenix/Content/Movies/Intro.bk2":"game/Phoenix/Content/Movies/Intro.bk2"},"created":[],"entries":[],"format":1,"owners":{}}"#
        try FileManager.default.createDirectory(at: bench.store.folder, withIntermediateDirectories: true)
        try record.write(to: bench.store.deployedFile, atomically: true, encoding: .utf8)

        let mod = try bench.stored("No Intro", ["Movies/Intro.bk2": "modded"])
        try bench.deployer.deploy(mod)
        #expect(try String(contentsOf: kept, encoding: .utf8) == "the real original")
        try bench.deployer.remove(owner: mod.key)
        #expect(bench.text("Phoenix/Content/Movies/Intro.bk2") == "the real original")
    }

    // MARK: Sommelier's own files in the store

    @Test func aModFolderNamedLikeSommeliersOwnIsRefused() throws {
        let elden = try profile("steam:1245620")
        for name in ["frameworks", "deployed.json", "order.json", "sommelier.me3", "index.json"] {
            let plan = ModArchive.plan(paths: ["\(name)/config_eldenring.toml", "\(name)/me3/files/tools/me3/bin/me3.exe"], profile: elden, manifests: [:])
            #expect(plan.refusal?.reason == .unsafePath, "\(name): \(plan)")
        }
        // A mod.json in a mod's folder would make it look like a stored mod.
        let fake = ModArchive.plan(paths: ["Fake/regulation.bin", "Fake/mod.json"], profile: elden)
        #expect(fake.refusal?.reason == .unsafePath, "\(fake)")
        #expect(ModStore.isOwnPath(["Frameworks", "me3"]) && ModStore.isOwnPath([".originals", "x"]) && ModStore.isOwnPath(["X", "MOD.json"]))
        #expect(!ModStore.isOwnPath(["Convergence", "regulation.bin"]))
    }

    @Test func theDeployerWontPlaceIntoSommeliersOwnFiles() throws {
        let bench = Bench(try profile("steam:1245620"))
        let other = try bench.stored("Alpha", ["Alpha/regulation.bin": "params"])
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-staged-\(UUID().uuidString)", isDirectory: true)
        try Self.layout(["x.exe": "MZ"], in: staged)
        let from = staged.appendingPathComponent("x.exe")
        for spec in ["store:frameworks/me3/files/tools/me3/bin/me3.exe", "store:\(other.key)/files/regulation.bin", "store:deployed.json"] {
            #expect(throws: ModDeployError.badDestination(spec)) { try bench.deployer.deploy(owner: "x", [.init(from: from, to: spec)]) }
        }
        #expect(try String(contentsOf: bench.store.file(of: other.key, at: "regulation.bin"), encoding: .utf8) == "params")
    }

    // MARK: Numbered paks

    @Test func numberedPaksCloseTheGapAndStepAsideForTheGamesOwn() throws {
        let bench = Bench(try profile("steam:2050650"))
        try Self.layout(["re_chunk_000.pak": "game", "re_chunk_000.pak.patch_001.pak": "p1", "re_chunk_000.pak.patch_002.pak": "p2",
                         "re_chunk_000.pak.patch_003.pak": "p3"], in: bench.game)
        let a = try bench.stored("A", ["A/a.pak": "mod A"])
        let b = try bench.stored("B", ["B/b.pak": "mod B"])
        try bench.deployer.deploy(a)
        try bench.deployer.deploy(b)
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "mod A" && bench.text("re_chunk_000.pak.patch_005.pak") == "mod B")

        // A goes: B moves down into 004, so the game still reaches it.
        try bench.deployer.remove(owner: a.key)
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "mod B")
        #expect(!bench.exists("re_chunk_000.pak.patch_005.pak"))
        #expect(bench.deployer.deployed(b.key) == ["game:re_chunk_000.pak.patch_004.pak"])
        #expect(bench.deployer.verify().isEmpty)

        // An update ships its own patch_004: it stays, and B steps up to the next free number.
        try FileManager.default.removeItem(at: bench.url("re_chunk_000.pak.patch_004.pak"))
        try "official 4".write(to: bench.url("re_chunk_000.pak.patch_004.pak"), atomically: true, encoding: .utf8)
        let findings = bench.deployer.verify()
        #expect(findings.map(\.problem) == [.replaced])
        try bench.deployer.repair(findings)
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "official 4", "the game's patch is never moved out")
        #expect(bench.text("re_chunk_000.pak.patch_005.pak") == "mod B")
        #expect(bench.deployer.verify().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bench.store.originals.path))

        try bench.deployer.remove(owner: b.key)
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "official 4" && !bench.exists("re_chunk_000.pak.patch_005.pak"))
    }

    // MARK: Code

    @Test func aModEngine2BundleWithADLLIsCode() throws {
        let bench = Bench(try profile("steam:1245620"))
        let config = "external_dlls = [\"mod/Tool.dll\"]\nmods = [ { enabled = true, name = \"x\", path = \"mod\" } ]\n"
        let files = ["MyMod/config_eldenring.toml": config, "MyMod/mod/Tool.dll": "MZ", "MyMod/mod/regulation.bin": "params"]
        let plan = ModArchive.plan(paths: Array(files.keys), profile: bench.profile)
        let unit = try #require(plan.units.first)
        #expect(plan.isReady && unit.kind.id == "me2import" && unit.code && plan.containsCode, "the config loads the DLL")

        var mod = try bench.stored("MyMod", files)
        let natives = { (mod: StoredMod) in LoadOrder.Me3.entries(of: mod, configFile: "store:sommelier.me3", store: bench.store).filter { $0.kind == .native } }
        #expect(natives(mod).map(\.path) == ["MyMod/mod/Tool.dll"])
        mod.units[0].code = false                                     // a record from before: never loaded
        #expect(natives(mod).isEmpty)

        // Without a DLL the bundle is no code, as before.
        let plain = ModArchive.plan(paths: ["Pack/config_eldenring.toml", "Pack/mod/regulation.bin"], profile: bench.profile)
        #expect(plain.isReady && !plain.containsCode)
    }

    @Test func aSMAPIManifestWithCommentsStillSaysCode() throws {
        let stardew = try profile("steam:413150")
        func plan(_ manifest: String) -> ModPlan {
            ModArchive.plan(paths: ["Mod/manifest.json", "Mod/Mod.dll"], profile: stardew, manifests: ["Mod/manifest.json": Data(manifest.utf8)])
        }
        let commented = "{\n  // the mod's own notes\n  \"Name\": \"Mod\",\n  /* block */ \"EntryDll\": \"Mod.dll\",\n}\n"
        #expect(plan(commented).containsCode)
        let contentPack = "{\n  // a content pack\n  \"Name\": \"Pack\", \"ContentPackFor\": { \"UniqueID\": \"Pathoschild.ContentPatcher\" },\n}\n"
        #expect(!plan(contentPack).containsCode, "comments read the way SMAPI reads them")
        #expect(plan("{ not json at all").containsCode, "a manifest that can't be read can't say there is no code")
        #expect(ModArchive.manifestHasField("EntryDll", in: Data("{\"url\": \"http://x//y\", \"EntryDll\": \"a\"}".utf8)) == true)
    }

    // MARK: UE4SS's mods.txt

    @Test func aNewLuaModGetsItsLineInModsTxt() throws {
        let bench = Bench(try profile("steam:990080"))
        try Self.layout(["Phoenix/Binaries/Win64/Mods/mods.txt": "Keybinds : 1\nOldMod : 0\n"], in: bench.game)
        let lua = try bench.stored("GamePauser", ["GamePauser/Scripts/main.lua": "print('hi')"])
        try bench.deployer.deploy(lua)
        #expect(bench.text("Phoenix/Binaries/Win64/Mods/mods.txt") == "Keybinds : 1\nOldMod : 0\nGamePauser : 1\n")

        // A line the player set stays as it is.
        let old = try bench.stored("OldMod", ["OldMod/Scripts/main.lua": "print('old')"])
        try bench.deployer.deploy(old)
        #expect(bench.text("Phoenix/Binaries/Win64/Mods/mods.txt") == "Keybinds : 1\nOldMod : 0\nGamePauser : 1\n")
    }
}
