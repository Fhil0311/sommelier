// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Compression
import CryptoKit
import Foundation
import SQLite3

/// What DXMT learned about a game on one Mac, as exchanged with Sommelier's sharing service ("decanting"): the
/// Direct3D-to-Metal shader translations it keeps in `shaders_<metal>.db`, and the pipelines it built from them,
/// recorded in `pipelines_<metal>.bin` (Sommelier's DXMT build). Both are the same on every Mac. With them a
/// game's first run skips the slow half of shader compilation, and the rest is built before the game draws.
///
/// Wire format: `SMLR`, format version (u8), kind (u8), Metal version (u32), table version (u32), entry count
/// (u32), then a zlib (raw deflate) stream of entries: key length (u16), key, value length (u32), value. Little
/// endian. A pipelines pack's keys are the SHA-1 of each record's data and its values are kind (u32) + data, as
/// DXMT's file lays them out.
public struct ShaderPack: Equatable, Sendable {
    public enum Kind: UInt8, Sendable, CaseIterable {
        case shaders = 1
        case pipelines = 2
        /// The service's path segment and DXMT's file name prefix.
        public var name: String { self == .shaders ? "shaders" : "pipelines" }
        public init?(name: String) {
            guard let kind = Kind.allCases.first(where: { $0.name == name }) else { return nil }
            self = kind
        }
    }

    public static let magic = Data("SMLR".utf8)
    public static let formatVersion: UInt8 = 2
    public static let headerSize = 18
    /// Every shader value DXMT stores is a Metal library; anything else is refused.
    public static let valueMagic = Data("MTLB".utf8)
    public static let maxValueSize = 4 * 1024 * 1024
    public static let maxRecordSize = 8192
    public static let maxKeySize = 64

    public let kind: Kind
    /// The `<metal>` in `shaders_<metal>.db` (DXMT's Metal shader language version, e.g. 320).
    public let metalVersion: Int
    /// The `<n>` in the database's `cache_<n>` table (DXMT's translator version); the file version for records.
    public let tableVersion: Int
    public var entries: [Data: Data]

    public init(kind: Kind = .shaders, metalVersion: Int, tableVersion: Int, entries: [Data: Data] = [:]) {
        self.kind = kind
        self.metalVersion = metalVersion
        self.tableVersion = tableVersion
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Whether an entry is one DXMT could have written.
    public static func isValid(kind: Kind, key: Data, value: Data) -> Bool {
        switch kind {
        case .shaders:
            return !key.isEmpty && key.count <= maxKeySize && value.count <= maxValueSize && value.starts(with: valueMagic)
        case .pipelines:
            guard key.count == 20, value.count >= 8, value.count <= maxRecordSize else { return false }
            let recordKind = value.u32(at: 0)
            return recordKind == 1 || recordKind == 2
        }
    }

    // MARK: Wire format

    public func encoded() -> Data {
        var body = Data()
        for (key, value) in entries.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            body.append(UInt16(key.count).littleEndianData)
            body.append(key)
            body.append(UInt32(value.count).littleEndianData)
            body.append(value)
        }
        var out = Self.magic
        out.append(Self.formatVersion)
        out.append(kind.rawValue)
        out.append(UInt32(metalVersion).littleEndianData)
        out.append(UInt32(tableVersion).littleEndianData)
        out.append(UInt32(entries.count).littleEndianData)
        out.append(Self.deflate(body))
        return out
    }

    public init?(encoded data: Data) {
        guard data.count >= Self.headerSize, data.prefix(4) == Self.magic, data[4] == Self.formatVersion,
              let kind = Kind(rawValue: data[5]) else { return nil }
        self.kind = kind
        metalVersion = Int(data.u32(at: 6))
        tableVersion = Int(data.u32(at: 10))
        let count = Int(data.u32(at: 14))
        guard let body = Self.inflate(data.suffix(from: Self.headerSize)) else { return nil }
        var entries: [Data: Data] = [:]
        var p = 0
        for _ in 0..<count {
            guard p + 2 <= body.count else { return nil }
            let keyLength = Int(body.u16(at: p)); p += 2
            guard p + keyLength + 4 <= body.count else { return nil }
            let key = body.subdata(in: p..<p + keyLength); p += keyLength
            let valueLength = Int(body.u32(at: p)); p += 4
            guard p + valueLength <= body.count else { return nil }
            let value = body.subdata(in: p..<p + valueLength); p += valueLength
            if Self.isValid(kind: kind, key: key, value: value) { entries[key] = value }
        }
        self.entries = entries
    }

    /// Everything in both; where they differ, `self` wins.
    public func merged(with other: ShaderPack) -> ShaderPack {
        var result = self
        for (key, value) in other.entries where result.entries[key] == nil { result.entries[key] = value }
        return result
    }

    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        return (try? (data as NSData).compressed(using: .zlib) as Data) ?? Data()
    }

    static func inflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return try? (data as NSData).decompressed(using: .zlib) as Data
    }
}

extension FixedWidthInteger {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}

extension Data {
    func u16(at offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8 }
    func u32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}

/// DXMT's `pipelines_<metal>.bin`: "DXPL", file version (u32), then records of kind (u32), size (u32), data.
/// Append-only, so a game that quit mid-write leaves a short tail, which is dropped.
public enum PipelineRecordsFile {
    public static let magic = Data("DXPL".utf8)
    public static let version: UInt32 = 1

    /// Each record as kind + data, the shape a pipelines pack keeps as its value.
    public static func records(in data: Data) -> [Data] {
        guard data.count >= 8, data.prefix(4) == magic, data.u32(at: 4) == version else { return [] }
        var records: [Data] = []
        var p = 8
        while p + 8 <= data.count {
            let size = Int(data.u32(at: p + 4))
            guard size <= data.count - p - 8 else { break }
            records.append(data.subdata(in: p..<p + 4) + data.subdata(in: p + 8..<p + 8 + size))
            p += 8 + size
        }
        return records
    }

    public static func encode(records: [Data]) -> Data {
        var out = magic
        out.append(version.littleEndianData)
        for record in records where record.count >= 4 {
            out.append(record.prefix(4))
            out.append(UInt32(record.count - 4).littleEndianData)
            out.append(record.suffix(from: 4))
        }
        return out
    }

    /// A record's key in a pack: the SHA-1 of its data, as DXMT dedupes them.
    public static func key(of record: Data) -> Data {
        Data(Insecure.SHA1.hash(data: record.suffix(from: 4)))
    }
}

// MARK: - In and out of DXMT's databases

extension ShaderCache {
    /// The newest table of each shader database in an executable's cache folder, and its pipeline records, as packs.
    public func export(exe: String) -> [ShaderPack] {
        let folder = directory.appendingPathComponent(exe, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard let (kind, metal) = Self.kindAndMetalVersion(of: file) else { return nil }
            switch kind {
            case .shaders: return Self.read(database: file, metalVersion: metal)
            case .pipelines:
                guard let data = try? Data(contentsOf: file) else { return nil }
                var pack = ShaderPack(kind: .pipelines, metalVersion: metal, tableVersion: Int(PipelineRecordsFile.version))
                for record in PipelineRecordsFile.records(in: data) { pack.entries[PipelineRecordsFile.key(of: record)] = record }
                return pack
            }
        }
    }

    /// Adds a pack's shaders to the executable's database (creating it as DXMT would), keeping what is there.
    /// Returns how many were new.
    @discardableResult
    public func `import`(_ pack: ShaderPack, exe: String) throws -> Int {
        let folder = directory.appendingPathComponent(exe, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if pack.kind == .pipelines { return try importRecords(pack, into: folder.appendingPathComponent("pipelines_\(pack.metalVersion).bin")) }
        let file = folder.appendingPathComponent("shaders_\(pack.metalVersion).db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db else {
            throw ShaderCacheError.database(file.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        let table = "cache_\(pack.tableVersion)"
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS \(table) (key BLOB PRIMARY KEY, value BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ShaderCacheError.database(file.lastPathComponent) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO \(table) (key, value) VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else {
            throw ShaderCacheError.database(file.lastPathComponent)
        }
        defer { sqlite3_finalize(statement) }
        var added = 0
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (key, value) in pack.entries where ShaderPack.isValid(kind: .shaders, key: key, value: value) {
            key.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(key.count), transient) }
            value.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(value.count), transient) }
            if sqlite3_step(statement) == SQLITE_DONE { added += Int(sqlite3_changes(db)) }
            sqlite3_reset(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return added
    }

    /// Executables with shaders not yet shared: their database changed since it was last sent (or was never
    /// sent). What a play session added, and, the first time, everything cached before sharing was turned on.
    public func executablesToShare() -> [String] {
        let shared = sharedDates()
        return databaseDates().filter { exe, date in (shared[exe] ?? .distantPast) < date }.keys.sorted()
    }

    /// Notes that the executable's shaders, as they stand now, went up.
    public func markShared(_ exe: String) {
        var shared = sharedDates()
        shared[exe] = databaseDates()[exe] ?? Date()
        if let data = try? JSONEncoder().encode(shared) { try? data.write(to: sharedFile, options: .atomic) }
    }

    /// Whether an executable of that name is in the game's folder (a few levels deep): the shaders DXMT cached
    /// under that name are this game's, not another's that happens to share the environment.
    public static func executable(_ exe: String, isIn folder: URL) -> Bool {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let file as URL in files {
            if files.level > 4 { files.skipDescendants(); continue }
            if file.lastPathComponent.caseInsensitiveCompare(exe) == .orderedSame { return true }
        }
        return false
    }

    var sharedFile: URL { directory.appendingPathComponent("shared.json") }

    func sharedDates() -> [String: Date] {
        (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: sharedFile))) ?? [:]
    }

    /// When each executable's shader database (or its write-ahead log) last changed.
    func databaseDates() -> [String: Date] {
        let fm = FileManager.default
        var dates: [String: Date] = [:]
        for game in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? game.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            for file in (try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where (file.lastPathComponent.hasPrefix("shaders_") && (file.pathExtension == "db" || file.pathExtension == "db-wal"))
                || (file.lastPathComponent.hasPrefix("pipelines_") && file.pathExtension == "bin") {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                dates[game.lastPathComponent] = max(dates[game.lastPathComponent] ?? .distantPast, date)
            }
        }
        return dates
    }

    /// Adds a pack's records to DXMT's pipelines file, keeping what is there; the file is rewritten whole.
    private func importRecords(_ pack: ShaderPack, into file: URL) throws -> Int {
        guard pack.tableVersion == Int(PipelineRecordsFile.version) else { return 0 }
        var records = PipelineRecordsFile.records(in: (try? Data(contentsOf: file)) ?? Data())
        var keys = Set(records.map(PipelineRecordsFile.key(of:)))
        var added = 0
        for (key, value) in pack.entries.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) })
        where ShaderPack.isValid(kind: .pipelines, key: key, value: value) && !keys.contains(key) {
            keys.insert(key)
            records.append(value)
            added += 1
        }
        if added > 0 { try PipelineRecordsFile.encode(records: records).write(to: file, options: .atomic) }
        return added
    }

    static func metalVersion(of file: URL) -> Int? {
        guard let (kind, metal) = kindAndMetalVersion(of: file), kind == .shaders else { return nil }
        return metal
    }

    /// `shaders_320.db` → (.shaders, 320); `pipelines_320.bin` → (.pipelines, 320).
    static func kindAndMetalVersion(of file: URL) -> (ShaderPack.Kind, Int)? {
        let name = file.lastPathComponent
        if name.hasPrefix("shaders_"), name.hasSuffix(".db"), let v = Int(name.dropFirst("shaders_".count).dropLast(".db".count)) { return (.shaders, v) }
        if name.hasPrefix("pipelines_"), name.hasSuffix(".bin"), let v = Int(name.dropFirst("pipelines_".count).dropLast(".bin".count)) { return (.pipelines, v) }
        return nil
    }

    static func read(database: URL, metalVersion: Int) -> ShaderPack? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        var newest: Int?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'cache_%'", -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let version = Int(String(cString: sqlite3_column_text(statement, 0)).dropFirst("cache_".count)) { newest = max(newest ?? 0, version) }
            }
        }
        sqlite3_finalize(statement)
        guard let newest else { return nil }
        var pack = ShaderPack(metalVersion: metalVersion, tableVersion: newest)
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM cache_\(newest)", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyPointer = sqlite3_column_blob(statement, 0), let valuePointer = sqlite3_column_blob(statement, 1) else { continue }
            let key = Data(bytes: keyPointer, count: Int(sqlite3_column_bytes(statement, 0)))
            let value = Data(bytes: valuePointer, count: Int(sqlite3_column_bytes(statement, 1)))
            if ShaderPack.isValid(kind: .shaders, key: key, value: value) { pack.entries[key] = value }
        }
        return pack
    }
}

public enum ShaderCacheError: Error, LocalizedError {
    case database(String)
    public var errorDescription: String? {
        switch self { case .database(let name): "Couldn't open the shader database \(name)." }
    }
}
