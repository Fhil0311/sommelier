// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Exactly how much of a download Steam has fetched, from Steam's own bookkeeping.
///
/// The app manifest's byte counts are only written now and then, and the files in `downloading/<id>` are of no help
/// either: Steam reserves their full size up front (small files really take the space at once). But for each depot
/// it downloads, Steam keeps `downloading/state_<app>_<depot>.patch`, the list of chunks it already has, and
/// `depotcache/<depot>_<manifest>.manifest`, every chunk with its download size. Adding up the chunks it has gives
/// the bytes downloaded.
public enum SteamDepotProgress {
    /// Downloaded and total bytes (compressed, as Steam counts downloads) over the app's depots; nil when Steam
    /// keeps no chunk lists for it (not downloading, or a Steam that works differently).
    public static func read(appID: String, steamapps: URL, steamDirectory: URL) -> (done: Int64, total: Int64)? {
        let downloading = steamapps.appendingPathComponent("downloading")
        let prefix = "state_\(appID)_"
        let states = ((try? FileManager.default.contentsOfDirectory(atPath: downloading.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".patch") }
        guard !states.isEmpty else { return nil }
        let depotcache = steamDirectory.appendingPathComponent("depotcache")
        let manifests = (try? FileManager.default.contentsOfDirectory(atPath: depotcache.path)) ?? []

        var done: Int64 = 0, total: Int64 = 0
        for state in states {
            let depot = String(state.dropFirst(prefix.count).dropLast(".patch".count))
            guard let name = newest(manifests.filter { $0.hasPrefix(depot + "_") && $0.hasSuffix(".manifest") }, in: depotcache),
                  let chunks = cachedChunks(depotcache.appendingPathComponent(name)) else { return nil }
            total += chunks.values.reduce(0, +)
            guard let data = try? Data(contentsOf: downloading.appendingPathComponent(state)) else { continue }
            done += completed(statePatch: data).reduce(0) { $0 + (chunks[$1] ?? 0) }
        }
        return total > 0 ? (done, total) : nil
    }

    // MARK: Files

    /// Chunk ids (SHA-1) in a state patch: a 24-byte header, then 24-byte records of a chunk id and 4 bytes of flags.
    static func completed(statePatch data: Data) -> Set<Data> {
        let bytes = [UInt8](data)
        guard bytes.count >= 24, bytes.starts(with: Array("MO42".utf8)) else { return [] }
        var ids = Set<Data>()
        var i = 24
        while i + 24 <= bytes.count {
            ids.insert(Data(bytes[i..<(i + 20)]))
            i += 24
        }
        return ids
    }

    /// Each chunk's download size by id, from a depot manifest: a protobuf payload of files, each with its chunks
    /// (1: id, 4: size, 5: compressed size).
    static func chunks(manifest data: Data) -> [Data: Int64]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, u32(bytes, 0) == 0x71F6_17D0 else { return nil }
        let length = Int(u32(bytes, 4))
        guard 8 + length <= bytes.count else { return nil }
        var result: [Data: Int64] = [:]
        do {
            try Protobuf.fields(bytes, 8..<(8 + length)) { field, value in
                guard field == 1, case .bytes(let file) = value else { return }
                try Protobuf.fields(bytes, file) { field, value in
                    guard field == 6, case .bytes(let chunk) = value else { return }
                    var id: Data?, compressed: Int64 = 0
                    try Protobuf.fields(bytes, chunk) { field, value in
                        if field == 1, case .bytes(let r) = value { id = Data(bytes[r]) }
                        if field == 5, case .varint(let v) = value { compressed = Int64(v) }
                    }
                    if let id { result[id] = compressed }
                }
            }
        } catch { return nil }
        return result
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func newest(_ names: [String], in folder: URL) -> String? {
        names.max { a, b in modified(folder.appendingPathComponent(a)) < modified(folder.appendingPathComponent(b)) }
    }

    private static func modified(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // A manifest never changes once written, and the download is checked every second: parse each one once.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: [Data: Int64]] = [:]

    private static func cachedChunks(_ url: URL) -> [Data: Int64]? {
        lock.lock(); let hit = cache[url]; lock.unlock()
        if let hit { return hit }
        guard let data = try? Data(contentsOf: url), let parsed = chunks(manifest: data) else { return nil }
        lock.lock(); cache[url] = parsed; lock.unlock()
        return parsed
    }
}

/// Just enough protobuf to walk a message's fields.
enum Protobuf {
    enum Value { case varint(UInt64), bytes(Range<Int>), fixed }
    struct Malformed: Error {}

    static func fields(_ b: [UInt8], _ range: Range<Int>, _ body: (Int, Value) throws -> Void) throws {
        var i = range.lowerBound
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < range.upperBound, shift < 64 else { throw Malformed() }
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }
        while i < range.upperBound {
            let key = try varint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: try body(field, .varint(try varint()))
            case 1: i += 8; try body(field, .fixed)
            case 5: i += 4; try body(field, .fixed)
            case 2:
                let length = Int(try varint())
                guard length >= 0, i + length <= range.upperBound else { throw Malformed() }
                let r = i..<(i + length); i += length
                try body(field, .bytes(r))
            default: throw Malformed()
            }
            guard i <= range.upperBound else { throw Malformed() }
        }
    }
}
