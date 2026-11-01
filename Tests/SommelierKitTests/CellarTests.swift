// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct CellarTests {
    @Test func keepsOnlyThisMacsArchives() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cellar = Cellar(paths: Paths(home: home))
        try cellar.store(Data(repeating: 1, count: 100), exe: "Raft.exe", os: "26", arch: "applegpu_g16s")
        let folder = cellar.folder(exe: "Raft.exe")
        for name in ["sommelier-15-applegpu_g16s.metallib", "local-26-applegpu_g13g.metallib", "local-26-applegpu_g16s.metallib", "notes.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        cellar.prune(exe: "Raft.exe", os: "26", arch: "applegpu_g16s")
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["sommelier-26-applegpu_g16s.metallib", "local-26-applegpu_g16s.metallib", "notes.txt"])
        #expect(cellar.hasServiceArchive(exe: "Raft.exe", os: "26", arch: "applegpu_g16s"))
        #expect(!cellar.hasServiceArchive(exe: "Raft.exe", os: "15", arch: "applegpu_g16s"))
    }

    @Test func findsTheNewestRecordsAndTheToolsCount() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cellar = Cellar(paths: Paths(home: home))
        let folder = cellar.cache.directory.appendingPathComponent("Raft.exe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(cellar.recordsDate(exe: "Raft.exe") == nil)
        for name in ["shaders_310.db", "pipelines_310.bin", "shaders_320.db", "pipelines_320.bin"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
        #expect(cellar.inputs(exe: "Raft.exe")?.records.lastPathComponent == "pipelines_320.bin")
        #expect(cellar.recordsDate(exe: "Raft.exe") != nil)
        #expect(Cellar.built(in: "built=167 failed=0 skipped=0 libraries=244 ms=252 bytes=6230192 device=Apple M4 Pro\n") == 167)
        #expect(Cellar.built(in: "cellar: no Metal device") == nil)
        #expect(Cellar.mac?.os.count == 2)
    }
}
