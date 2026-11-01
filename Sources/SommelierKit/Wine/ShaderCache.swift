// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

/// Where DXMT keeps what it has already compiled for each game: the Direct3D shaders translated to Metal
/// (`shaders_<metal>.db`, a SQLite key-value store, the same on every Mac) and Metal's own cache of the GPU
/// binaries built from them (`com.apple.metal`, specific to this chip and macOS build). DXMT writes both under the
/// user's purgeable cache folder, `dxmt/<exe name>/`; macOS empties that folder when disk runs low, and a game
/// then stutters again as on its first run. Sommelier points that folder at its own, so the caches last.
public struct ShaderCache: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    /// Sommelier's folder for DXMT's caches, one subfolder per executable, as DXMT lays them out.
    public var directory: URL { paths.home.appendingPathComponent("ShaderCache/dxmt", isDirectory: true) }

    /// The folder DXMT writes to: `dxmt` under the user's Darwin cache directory.
    public static var dxmtDefaultDirectory: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).appendingPathComponent("dxmt", isDirectory: true)
    }

    /// Makes DXMT's cache folder a link into Sommelier's. Anything DXMT already cached there moves over first.
    /// Done before every DXMT launch: macOS may have purged the link along with the rest of the cache folder.
    ///
    /// DXMT then logs "Failed to set Metal cache path, fallback to system default" once per process: it compares
    /// the path it set with the one Metal reports, and Metal reports it with the link resolved. Metal does write
    /// the game's GPU binaries under the linked folder all the same (seen with NFS Most Wanted, 2026-10-20).
    public func prepare(dxmtDirectory: URL? = dxmtDefaultDirectory) throws {
        guard let dxmtDirectory else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = dxmtDirectory.path
        if let attributes = try? fm.attributesOfItem(atPath: link), let type = attributes[.type] as? FileAttributeType {
            if type == .typeSymbolicLink {
                if (try? fm.destinationOfSymbolicLink(atPath: link)) == directory.path { return }
                try fm.removeItem(atPath: link)
            } else if type == .typeDirectory {
                try migrate(from: dxmtDirectory)
                try fm.removeItem(atPath: link)
            } else {
                try fm.removeItem(atPath: link)
            }
        }
        try fm.createDirectory(at: dxmtDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: directory.path)
    }

    /// Moves each game's cache folder into Sommelier's; a game already there keeps what it has.
    private func migrate(from old: URL) throws {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
            let target = directory.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: item); continue }
            try fm.moveItem(at: item, to: target)
        }
    }

    /// Bytes on disk, for Settings.
    public var sizeOnDisk: Int64 {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    /// Drops what older DXMT builds left: each database keeps one table per translator version (`cache_18`,
    /// `cache_19`, …), and a game's file would otherwise grow with every engine update.
    public func prune() {
        let fm = FileManager.default
        guard let games = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for game in games {
            for file in (try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("shaders_") && file.pathExtension == "db" {
                Self.dropOldTables(in: file)
            }
        }
    }

    /// Keeps only the newest `cache_<n>` table in a DXMT shader database. Returns the tables dropped.
    @discardableResult
    static func dropOldTables(in database: URL) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        var tables: [(name: String, version: Int)] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'cache_%'", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(statement, 0))
                if let version = Int(name.dropFirst("cache_".count)) { tables.append((name, version)) }
            }
        }
        sqlite3_finalize(statement)
        guard let newest = tables.map(\.version).max() else { return [] }
        let old = tables.filter { $0.version < newest }.map(\.name)
        for name in old { sqlite3_exec(db, "DROP TABLE \"\(name)\"", nil, nil, nil) }
        if !old.isEmpty { sqlite3_exec(db, "VACUUM", nil, nil, nil) }
        return old
    }
}
