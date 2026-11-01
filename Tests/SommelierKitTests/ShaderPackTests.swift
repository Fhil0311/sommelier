// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct ShaderPackTests {
    static func library(_ seed: UInt8) -> Data { Data("MTLB".utf8) + Data(repeating: seed, count: 300) }
    static func key(_ n: UInt8) -> Data { Data(repeating: n, count: 40) }

    @Test func roundTripsThroughTheWireFormat() throws {
        var pack = ShaderPack(metalVersion: 320, tableVersion: 18)
        pack.entries[Self.key(1)] = Self.library(1)
        pack.entries[Self.key(2)] = Self.library(2)
        let encoded = pack.encoded()
        #expect(encoded.prefix(4) == Data("SMLR".utf8))
        #expect(encoded.count < 2 * 300)                                              // the repeats compress
        let decoded = try #require(ShaderPack(encoded: encoded))
        #expect(decoded == pack)
        #expect(ShaderPack(encoded: Data("nope".utf8)) == nil)
        #expect(ShaderPack(encoded: encoded.prefix(30)) == nil)                        // truncated
        #expect(decoded.kind == .shaders)
    }

    @Test func carriesPipelineRecords() throws {
        let record1 = UInt32(1).littleEndianData + Data(repeating: 7, count: 300)      // kind + data, as DXMT writes it
        let record2 = UInt32(2).littleEndianData + Data(repeating: 8, count: 100)
        let file = PipelineRecordsFile.encode(records: [record1, record2])
        #expect(file.prefix(4) == Data("DXPL".utf8))
        #expect(PipelineRecordsFile.records(in: file) == [record1, record2])
        #expect(PipelineRecordsFile.records(in: file.prefix(file.count - 10)) == [record1])   // a torn tail is dropped
        var pack = ShaderPack(kind: .pipelines, metalVersion: 320, tableVersion: 1)
        pack.entries[PipelineRecordsFile.key(of: record1)] = record1
        pack.entries[Self.key(1)] = record2                                             // a 40-byte key: no record key
        let decoded = try #require(ShaderPack(encoded: pack.encoded()))
        #expect(decoded.kind == .pipelines && decoded.entries.count == 1)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ShaderCache(paths: Paths(home: root))
        try FileManager.default.createDirectory(at: cache.directory.appendingPathComponent("Game.exe"), withIntermediateDirectories: true)
        try PipelineRecordsFile.encode(records: [record2]).write(to: cache.directory.appendingPathComponent("Game.exe/pipelines_320.bin"))
        #expect(try cache.import(decoded, exe: "Game.exe") == 1)                        // record1 joins record2
        #expect(try cache.import(decoded, exe: "Game.exe") == 0)
        let exported = cache.export(exe: "Game.exe").first { $0.kind == .pipelines }
        #expect(exported?.entries.count == 2)
        #expect(PipelineRecordsFile.records(in: try Data(contentsOf: cache.directory.appendingPathComponent("Game.exe/pipelines_320.bin"))) == [record2, record1])
    }

    @Test func refusesWhatDXMTWouldNotWrite() throws {
        var pack = ShaderPack(metalVersion: 320, tableVersion: 18)
        pack.entries[Self.key(1)] = Data("not a metal library".utf8)
        pack.entries[Data()] = Self.library(1)
        let decoded = try #require(ShaderPack(encoded: pack.encoded()))
        #expect(decoded.isEmpty)
        #expect(!ShaderPack.isValid(kind: .shaders, key: Self.key(1), value: Data("MTLB".utf8) + Data(count: ShaderPack.maxValueSize)))
    }

    @Test func mergesKeepingWhatIsThere() {
        var a = ShaderPack(metalVersion: 320, tableVersion: 18, entries: [Self.key(1): Self.library(1)])
        let b = ShaderPack(metalVersion: 320, tableVersion: 18, entries: [Self.key(1): Self.library(9), Self.key(2): Self.library(2)])
        a = a.merged(with: b)
        #expect(a.entries.count == 2 && a.entries[Self.key(1)] == Self.library(1))
    }

    @Test func importsIntoAndExportsFromDXMTsDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ShaderCache(paths: Paths(home: root))
        let pack = ShaderPack(metalVersion: 320, tableVersion: 18, entries: [Self.key(1): Self.library(1), Self.key(2): Self.library(2)])
        #expect(try cache.import(pack, exe: "Game.exe") == 2)
        #expect(try cache.import(pack, exe: "Game.exe") == 0)                          // already there
        let more = ShaderPack(metalVersion: 320, tableVersion: 18, entries: [Self.key(3): Self.library(3)])
        #expect(try cache.import(more, exe: "Game.exe") == 1)
        let exported = cache.export(exe: "Game.exe")
        #expect(exported.count == 1 && exported[0].entries.count == 3 && exported[0].tableVersion == 18 && exported[0].metalVersion == 320)
        #expect(exported[0].kind == .shaders)
        #expect(cache.executablesToShare() == ["Game.exe"])                         // never shared yet
        cache.markShared("Game.exe")
        #expect(cache.executablesToShare().isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)],
                                              ofItemAtPath: cache.directory.appendingPathComponent("Game.exe/shaders_320.db").path)
        #expect(cache.executablesToShare() == ["Game.exe"])                         // changed since
        let install = root.appendingPathComponent("Games/Some Game/Binaries/Win64")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        try Data().write(to: install.appendingPathComponent("Game.exe"))
        #expect(ShaderCache.executable("game.exe", isIn: root.appendingPathComponent("Games/Some Game")))
        #expect(!ShaderCache.executable("Other.exe", isIn: root.appendingPathComponent("Games/Some Game")))
        // DXMT's own reader opens the file read-only and expects the table by name: both still hold.
        #expect(ShaderCache.dropOldTables(in: cache.directory.appendingPathComponent("Game.exe/shaders_320.db")).isEmpty)
    }
}
