// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Conflicts between stored mods, against the fixture profiles.
struct ModConflictsTests {
    private func profile(_ id: String) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
        return try #require(list.profile(covering: id))
    }

    /// A store in a temporary folder.
    private func store() -> ModStore {
        ModStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-conflicts-\(UUID().uuidString)/Mods/test", isDirectory: true))
    }

    /// A mod in the store, made from a layout planned against the profile.
    private func stored(_ name: String, _ files: [String: String], profile: ModProfile, store: ModStore, enabled: Bool = true) throws -> StoredMod {
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-unpacked-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = URL(fileURLWithPath: unpacked.path + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name)
        try #require(plan.isReady, "\(plan)")
        var mod = try store.add(name: name, plan: plan, unpacked: unpacked)
        mod.enabled = enabled
        return mod
    }

    @Test func twoRegulationFilesBlock() throws {
        let eldenRing = try profile("steam:1245620"), store = store()
        let a = try stored("A", ["A/regulation.bin": "a"], profile: eldenRing, store: store)
        let b = try stored("B", ["B/regulation.bin": "b", "B/parts/x.dcx": "x"], profile: eldenRing, store: store)
        let report = ModConflicts.check([a, b], profile: eldenRing, order: [a.key, b.key], installedFrameworks: ["me3"])
        #expect(report.findings == [.init(cause: .rule(reason: "regulation", hint: nil, matched: "**/regulation.bin"), severity: .block, mods: [a.key, b.key])])
        #expect(report.isBlocked(a.key) && report.isBlocked(b.key) && report.blocked == [a.key, b.key])
        #expect(report.findings(for: b.key).count == 1)

        // One of them off: nothing. Both on but the framework missing: each needs it.
        var off = b
        off.enabled = false
        #expect(ModConflicts.check([a, off], profile: eldenRing, installedFrameworks: ["me3"]).isEmpty)
        let missing = ModConflicts.check([a, off], profile: eldenRing)
        #expect(missing.findings == [.init(cause: .needsFramework("me3"), severity: .block, mods: [a.key])])
    }

    @Test func contentPackWithoutItsHostNeedsIt() throws {
        let stardew = try profile("steam:413150"), store = store()
        let pack = try stored("[CP] Foo", ["[CP] Foo/manifest.json": #"{"Name": "Foo", "UniqueID": "me.Foo", "ContentPackFor": {"UniqueID": "Pathoschild.ContentPatcher"}}"#, "[CP] Foo/content.json": "{}"],
                              profile: stardew, store: store)
        let fields = ModConflicts.manifestFields(of: pack, store: store)
        #expect(fields == ["name": "Foo", "uniqueid": "me.Foo", "contentpackfor.uniqueid": "Pathoschild.ContentPatcher"])
        let alone = ModConflicts.check([pack], profile: stardew, installedFrameworks: ["smapi"], manifests: [pack.key: fields])
        #expect(alone.findings == [.init(cause: .needsMod("Pathoschild.ContentPatcher", label: "needsFramework"), severity: .block, mods: [pack.key])])

        // The host installed and on: satisfied. Off: not.
        let host = try stored("Content Patcher", ["ContentPatcher/manifest.json": #"{"UniqueID": "pathoschild.contentpatcher", "EntryDll": "ContentPatcher.dll"}"#, "ContentPatcher/ContentPatcher.dll": "MZ"],
                              profile: stardew, store: store)
        let manifests = [pack.key: fields, host.key: ModConflicts.manifestFields(of: host, store: store)]
        #expect(ModConflicts.check([pack, host], profile: stardew, installedFrameworks: ["smapi"], manifests: manifests).isEmpty)
        var hostOff = host
        hostOff.enabled = false
        #expect(ModConflicts.check([pack, hostOff], profile: stardew, installedFrameworks: ["smapi"], manifests: manifests).findings.count == 1)

        // Two copies of one mod by UniqueID: a block with the id named. Same folder twice: a block too, since
        // SMAPI's order is nobody's to say.
        let copy = try stored("Content Patcher 2", ["ContentPatcher2/manifest.json": #"{"UniqueID": "Pathoschild.ContentPatcher"}"#], profile: stardew, store: store)
        let duplicated = ModConflicts.check([host, copy], profile: stardew, installedFrameworks: ["smapi"],
                                            manifests: [host.key: manifests[host.key]!, copy.key: ModConflicts.manifestFields(of: copy, store: store)])
        #expect(duplicated.findings == [.init(cause: .rule(reason: "duplicateMod", hint: nil, matched: "pathoschild.contentpatcher"), severity: .block, mods: [host.key, copy.key])])
        let twin = try stored("Content Patcher again", ["ContentPatcher/manifest.json": "{}"], profile: stardew, store: store)
        let same = ModConflicts.check([host, twin], profile: stardew, order: [twin.key, host.key], installedFrameworks: ["smapi"])
        #expect(same.findings == [.init(cause: .samePath("game:Mods/ContentPatcher/manifest.json", winner: nil), severity: .block, mods: [twin.key, host.key])])
    }

    @Test func samePathWarnsWithTheUpperModWinning() throws {
        let re4 = try profile("steam:2050650"), store = store()
        let path = "natives/STM/_Chainsaw/Item.user.2"
        let a = try stored("A", [path: "a", "natives/STM/_Chainsaw/OnlyA.user.2": "a"], profile: re4, store: store)
        let b = try stored("B", [path: "b"], profile: re4, store: store)
        let report = ModConflicts.check([a, b], profile: re4, order: [b.key, a.key], installedFrameworks: ["reframework"])
        #expect(report.findings == [.init(cause: .samePath("game:" + path, winner: b.key), severity: .warn, mods: [b.key, a.key])])
        #expect(!report.isBlocked(a.key) && report.blocked.isEmpty && report.findings(for: a.key).count == 1)
        // Without an order nobody is named the winner.
        #expect(ModConflicts.check([a, b], profile: re4, installedFrameworks: ["reframework"]).findings.first?.cause == .samePath("game:" + path, winner: nil))
        // Two pak mods take different numbers: no conflict between them.
        let p = try stored("P", ["P.pak": "p"], profile: re4, store: store), q = try stored("Q", ["Q.pak": "q"], profile: re4, store: store)
        #expect(ModConflicts.check([p, q], profile: re4, installedFrameworks: ["reframework"]).isEmpty)
    }

    @Test func pakChunksOfOneNameWarnWithAHint() throws {
        let hogwarts = try profile("steam:990080"), store = store()
        let triple = { (folder: String) in ["\(folder)/pakchunk1311_P.pak": "p", "\(folder)/pakchunk1311_P.ucas": "u", "\(folder)/pakchunk1311_P.utoc": "t"] }
        let a = try stored("Shrek Broom", triple("Shrek"), profile: hogwarts, store: store)
        let b = try stored("Elder Wand", triple("Wand"), profile: hogwarts, store: store)
        let c = try stored("Fog", ["zFog_P.pak": "p", "zFog_P.ucas": "u", "zFog_P.utoc": "t"], profile: hogwarts, store: store)
        let report = ModConflicts.check([a, b, c], profile: hogwarts, order: [c.key, b.key, a.key])
        #expect(report.findings == [.init(cause: .rule(reason: "pakchunk", hint: nil, matched: "pakchunk1311_p"), severity: .warn, mods: [b.key, a.key])])
        #expect(report.blocked.isEmpty, "each mod has its own slot folder, so the paths themselves don't clash")
        #expect(ModConflicts.placedPaths(of: c) == ["game:Phoenix/Content/Paks/~mods/\(c.key)/zFog_P.pak", "game:Phoenix/Content/Paks/~mods/\(c.key)/zFog_P.ucas",
                                                    "game:Phoenix/Content/Paks/~mods/\(c.key)/zFog_P.utoc"])
    }
}
