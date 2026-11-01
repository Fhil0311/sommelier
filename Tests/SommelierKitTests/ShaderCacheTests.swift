// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Testing
@testable import SommelierKit

@Suite struct ShaderCacheTests {
    func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shadercache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func linksDXMTsFolderIntoSommeliers() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ShaderCache(paths: Paths(home: root.appendingPathComponent("home")))
        let dxmt = root.appendingPathComponent("Caches/dxmt")
        try cache.prepare(dxmtDirectory: dxmt)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dxmt.path) == cache.directory.path)
        try cache.prepare(dxmtDirectory: dxmt)                                          // again: nothing changes
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dxmt.path) == cache.directory.path)
        // What DXMT writes through the link lands in Sommelier's folder.
        try FileManager.default.createDirectory(at: dxmt.appendingPathComponent("Game.exe"), withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: cache.directory.appendingPathComponent("Game.exe").path))
    }

    @Test func movesWhatDXMTAlreadyCached() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ShaderCache(paths: Paths(home: root.appendingPathComponent("home")))
        let dxmt = root.appendingPathComponent("Caches/dxmt")
        try FileManager.default.createDirectory(at: dxmt.appendingPathComponent("NFS13.exe"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: dxmt.appendingPathComponent("NFS13.exe/shaders_320.db"))
        try cache.prepare(dxmtDirectory: dxmt)
        #expect(try Data(contentsOf: cache.directory.appendingPathComponent("NFS13.exe/shaders_320.db")) == Data("db".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dxmt.path) == cache.directory.path)
        #expect(cache.sizeOnDisk == 2)
    }

    @Test func dropsTablesOfOlderTranslators() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ShaderCache(paths: Paths(home: root))
        let game = cache.directory.appendingPathComponent("Raft.exe")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let file = game.appendingPathComponent("shaders_320.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        for sql in ["CREATE TABLE cache_17 (key BLOB PRIMARY KEY, value BLOB NOT NULL)",
                    "CREATE TABLE cache_18 (key BLOB PRIMARY KEY, value BLOB NOT NULL)",
                    "INSERT INTO cache_18 VALUES (x'01', x'02')"] {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)
        cache.prune()
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", -1, &statement, nil)
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { names.append(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        sqlite3_close(db)
        #expect(names == ["cache_18"])
    }
}
