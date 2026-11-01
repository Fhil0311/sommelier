// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The mod store on temporary folders: taking plans in, the index, archives through `tar`.
struct ModStoreTests {
    private func profile(_ id: String) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
        return try #require(list.profile(covering: id))
    }

    private func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-modstore-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a layout of relative paths with their contents under `root`.
    private func layout(_ files: [String: String], in root: URL) throws {
        for (path, text) in files {
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func addKeepsFilesAndIndex() throws {
        let store = ModStore(folder: scratch("add"))
        let unpacked = scratch("unpacked")
        let files = ["zCool_P.pak": "pak", "zCool_P.ucas": "ucas", "zCool_P.utoc": "utoc", "screenshot.png": "png"]
        try layout(files, in: unpacked)
        let plan = ModArchive.plan(paths: Array(files.keys), profile: try profile("steam:990080"), archiveName: "Cool Mod")
        let archive = scratch("archive").appendingPathComponent("Cool Mod-1.2.zip")
        try Data("not really a zip".utf8).write(to: archive)

        let mod = try store.add(name: "Cool Mod", plan: plan, unpacked: unpacked, archive: archive, version: "1.2", now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mod.key.hasPrefix("cool-mod-") && mod.key.count == "cool-mod-".count + 6)
        #expect(mod.name == "Cool Mod" && mod.version == "1.2" && mod.enabled && !mod.codeAccepted && !mod.containsCode && mod.frameworks.isEmpty)
        #expect(mod.archive.name == "Cool Mod-1.2.zip" && mod.archive.bytes == 16 && mod.archive.sha256?.count == 64)
        #expect(mod.units.map(\.kind.id) == ["pak"] && mod.leftovers == ["screenshot.png"] && mod.placedSources.sorted() == ["zCool_P.pak", "zCool_P.ucas", "zCool_P.utoc"])
        #expect(exists(store.folder(of: mod.key).appendingPathComponent("mod.json")))
        #expect(try String(contentsOf: store.file(of: mod.key, at: "zCool_P.pak"), encoding: .utf8) == "pak")
        #expect(exists(store.file(of: mod.key, at: "screenshot.png")) && !exists(unpacked))

        // The index and mod.json round-trip; a change saved shows on the next read.
        #expect(store.list() == [mod] && store.mod(mod.key) == mod && store.keys() == [mod.key])
        var off = mod
        off.enabled = false; off.codeAccepted = true
        try store.save(off)
        #expect(store.mod(mod.key) == off && store.list() == [off])

        // Another mod of the same name gets its own key; removal takes the folder and the index entry.
        let again = scratch("again")
        try layout(files, in: again)
        let second = try store.add(name: "Cool Mod", plan: plan, unpacked: again)
        #expect(second.key != mod.key && store.keys() == [mod.key, second.key])
        try store.remove(mod.key)
        #expect(store.mod(mod.key) == nil && !exists(store.folder(of: mod.key)) && store.keys() == [second.key])
        #expect(throws: ModStoreError.notFound(mod.key)) { try store.remove(mod.key) }

        // A plan with a question or a refusal is not taken.
        let asked = ModArchive.plan(paths: ["A/modinfo.ini", "A/natives/x", "B/modinfo.ini", "B/natives/y"], profile: try profile("steam:2050650"))
        #expect(throws: ModStoreError.planNotReady) { try store.add(name: "x", plan: asked, unpacked: scratch("asked")) }
    }

    @Test func wrapperAndVariantFoldersAreDroppedOnTheWayIn() throws {
        let store = ModStore(folder: scratch("wrapper"))
        let wrapped = scratch("wrapped")
        let files = ["CoolMod/zCool_P.pak": "pak", "CoolMod/zCool_P.ucas": "ucas", "CoolMod/zCool_P.utoc": "utoc", "__MACOSX/CoolMod/._zCool_P.pak": "junk"]
        try layout(files, in: wrapped)
        let plan = ModArchive.plan(paths: Array(files.keys), profile: try profile("steam:990080"))
        #expect(plan.base == "CoolMod")
        let mod = try store.add(name: "Cool", plan: plan, unpacked: wrapped)
        #expect(exists(store.file(of: mod.key, at: "zCool_P.pak")) && !exists(store.files(of: mod.key).appendingPathComponent("CoolMod")))
        #expect(!exists(wrapped), "the rest of the temporary folder goes")

        let variants = scratch("variants")
        let paths = ["Max Stacks/999/modinfo.ini": "a", "Max Stacks/999/natives/STM/Item.user.2": "999",
                     "Max Stacks/9999/modinfo.ini": "b", "Max Stacks/9999/natives/STM/Item.user.2": "9999"]
        try layout(paths, in: variants)
        let chosen = ModArchive.plan(paths: Array(paths.keys), profile: try profile("steam:2050650"), answers: .init(variant: "9999"))
        #expect(chosen.base == "Max Stacks/9999")
        let stacks = try store.add(name: "Max Stacks", plan: chosen, unpacked: variants)
        #expect(try String(contentsOf: store.file(of: stacks.key, at: "natives/STM/Item.user.2"), encoding: .utf8) == "9999")
        #expect(exists(store.file(of: stacks.key, at: "modinfo.ini")) && stacks.leftovers == ["modinfo.ini"])
    }

    @Test func indexIsRebuiltFromTheFolders() throws {
        let store = ModStore(folder: scratch("index"))
        let hogwarts = try profile("steam:990080")
        var added: [StoredMod] = []
        for name in ["Beta", "Alpha"] {
            let folder = scratch(name)
            let files = ["z\(name)_P.pak": "p", "z\(name)_P.ucas": "u", "z\(name)_P.utoc": "t"]
            try layout(files, in: folder)
            added.append(try store.add(name: name, plan: ModArchive.plan(paths: Array(files.keys), profile: hogwarts), unpacked: folder))
        }
        #expect(store.keys() == added.map(\.key), "in the order they were added")

        // Without the index the folders are found, sorted; junk and hidden folders are not mods.
        try FileManager.default.removeItem(at: store.folder.appendingPathComponent("index.json"))
        try FileManager.default.createDirectory(at: store.folder.appendingPathComponent(".originals/game"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.folder.appendingPathComponent("stray"), withIntermediateDirectories: true)
        #expect(store.keys() == added.map(\.key).sorted())
        #expect(exists(store.folder.appendingPathComponent("index.json")))
        // A folder that vanished behind the index's back is dropped from it.
        try FileManager.default.removeItem(at: store.folder(of: added[0].key))
        #expect(store.list() == [added[1]])
    }

    @Test func archivesAreListedAndUnpackedWithoutLinks() async throws {
        let store = ModStore(folder: scratch("tar"))
        let source = scratch("source")
        try layout(["CoolMod/zCool_P.pak": "pak", "CoolMod/zCool_P.ucas": "ucas", "CoolMod/zCool_P.utoc": "utoc"], in: source)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("CoolMod/link"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let archive = scratch("zip").appendingPathComponent("CoolMod.zip")
        let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", archive.path, "--format", "zip", "-C", source.path, "CoolMod"])
        try #require(made.succeeded)

        let entries = try await store.entries(of: archive)
        #expect(Set(entries) == ["CoolMod/", "CoolMod/zCool_P.pak", "CoolMod/zCool_P.ucas", "CoolMod/zCool_P.utoc", "CoolMod/link"])
        let plan = ModArchive.plan(paths: entries, profile: try profile("steam:990080"))
        #expect(plan.isReady && plan.base == "CoolMod" && plan.leftovers == ["link"])

        let unpacked = try await store.unpack(archive)
        #expect(unpacked.path.hasPrefix(store.folder.appendingPathComponent(".tmp").path))
        #expect(exists(unpacked.appendingPathComponent("CoolMod/zCool_P.pak")))
        #expect(!FileScan.isSymlink(unpacked.appendingPathComponent("CoolMod/link")) && !exists(unpacked.appendingPathComponent("CoolMod/link")), "links are dropped")
        let mod = try store.add(name: "Cool", plan: plan, unpacked: unpacked, archive: archive)
        #expect(try String(contentsOf: store.file(of: mod.key, at: "zCool_P.ucas"), encoding: .utf8) == "ucas" && mod.archive.name == "CoolMod.zip")
        #expect(!exists(unpacked))

        // An entry that would climb out refuses the archive before anything is written; junk isn't an archive.
        let evilRoot = scratch("evil")
        try "evil".write(to: evilRoot.appendingPathComponent("evil.txt"), atomically: true, encoding: .utf8)
        let inside = evilRoot.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let evil = evilRoot.appendingPathComponent("evil.zip")
        let built = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cPf", evil.path, "--format", "zip", "../evil.txt"], currentDirectory: inside)
        try #require(built.succeeded)
        await #expect(throws: ModStoreError.unsafeArchive("../evil.txt")) { try await store.entries(of: evil) }
        await #expect(throws: ModStoreError.unsafeArchive("../evil.txt")) { try await store.unpack(evil) }
        let junk = evilRoot.appendingPathComponent("junk.zip")
        try Data("nothing".utf8).write(to: junk)
        await #expect(throws: ModStoreError.self) { try await store.entries(of: junk) }
        #expect(store.list() == [mod])
        store.discardTemporary()
        #expect(!exists(store.folder.appendingPathComponent(".tmp")))
    }

    @Test func manifestsAreReadForCodeIfKinds() throws {
        let store = ModStore(folder: scratch("manifests"))
        let stardew = try profile("steam:413150")
        let unpacked = scratch("smapi")
        let files = ["Wrap/CJB Cheats/manifest.json": #"{ "Name": "CJB Cheats Menu", "UniqueID": "CJBok.CheatsMenu", "EntryDll": "CJBCheatsMenu.dll" }"#,
                     "Wrap/CJB Cheats/CJBCheatsMenu.dll": "MZ",
                     "Wrap/[CP] Pack/manifest.json": #"{ "Name": "Pack", "UniqueID": "x.pack", "ContentPackFor": { "UniqueID": "Pathoschild.ContentPatcher" } }"#,
                     "Wrap/[CP] Pack/content.json": "{}", "Wrap/notes.txt": "n"]
        try layout(files, in: unpacked)
        let entries = Array(files.keys) + ["Wrap/", "Wrap/CJB Cheats/"]
        let manifests = store.manifests(in: unpacked, entries: entries, profile: stardew)
        #expect(Set(manifests.keys) == ["Wrap/CJB Cheats/manifest.json", "Wrap/[CP] Pack/manifest.json"])
        #expect(store.manifests(in: unpacked, entries: entries, profile: try profile("steam:990080")).isEmpty, "no codeIf kinds, nothing read")

        // Planned with them, the C# mod is code and the content pack isn't, through the wrapper.
        let plan = ModArchive.plan(paths: entries, profile: stardew, manifests: manifests)
        #expect(plan.isReady && plan.base == "Wrap" && plan.units.count == 2)
        #expect(Dictionary(uniqueKeysWithValues: plan.units.map { ($0.name, $0.code) }) == ["CJB Cheats": true, "[CP] Pack": false])
        let mod = try store.add(name: "Bundle", plan: plan, unpacked: unpacked)
        #expect(mod.containsCode && mod.frameworks == ["smapi"] && exists(store.file(of: mod.key, at: "[CP] Pack/content.json")))
    }

    @Test func keysArePlainAndUnique() {
        #expect(ModStore.key(for: "Clever's Mod — Übersicht!", taken: []).hasPrefix("clever-s-mod-ubersicht-"))
        #expect(ModStore.key(for: "   ", taken: []).hasPrefix("mod-"))
        let long = ModStore.key(for: String(repeating: "a", count: 100), taken: [])
        #expect(long.count == 40 + 7 && !long.hasPrefix("."))
        #expect(ModStore.isSafe(entry: "./Mod/x.pak") && ModStore.isSafe(entry: "Mod/") && !ModStore.isSafe(entry: "../x") && !ModStore.isSafe(entry: "/abs"))
    }
}
