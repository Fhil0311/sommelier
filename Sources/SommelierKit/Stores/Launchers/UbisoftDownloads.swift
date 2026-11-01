// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Compression
import Foundation

/// Downloads Ubisoft Connect is running, followed from the files it keeps in each game's folder:
///
/// - `uplay_install.manifest`: a header (version, signature length, size), the signature, then a zlib-compressed
///   protobuf listing the game's chunks (field 4: id = 1, files = 3 with name = 1 and size = 2). It covers every
///   language and add-on.
/// - `uplay_install.state`: a protobuf with the product id (field 28) and one entry per chunk (field 6: id = 1,
///   wanted for this install = 3).
///
/// The download's size is what the wanted chunks hold; its progress is how much of their files is on disk.
///
/// While the download runs, those files don't exist yet: the state has no chunk list, the manifest is in the
/// launcher's `data/<product>/manifests/<build>`, and the files fill up in `uplay_download/<product>/` (made full
/// length up front, so only their written blocks count). The wanted chunks then follow Ubisoft's rule: chunks for
/// no particular language or add-on, plus the install language's (field 3 of the state).
public enum UbisoftDownloads {
    public struct Progress: Equatable, Sendable {
        public var productID: Int
        public var total: Int64
        public var done: Int64
        public var fraction: Double { total > 0 ? min(Double(done) / Double(total), 1) : 0 }
        public var isComplete: Bool { total > 0 && done >= total }
    }

    struct Chunk {
        var files: [(path: String, size: Int64)] = []
        /// The language a chunk is for (field 5, "en-US"), and whether it needs another product (field 8: add-ons).
        var language: String?
        var needsProduct = false
        /// Wanted by an install in `language` when the state doesn't say.
        func wanted(language installLanguage: String) -> Bool {
            if let language { return language.caseInsensitiveCompare(installLanguage) == .orderedSame }
            return !needsProduct
        }
    }
    /// Chunks by id.
    typealias Manifest = [Int: Chunk]

    /// `InstallState` Ubisoft Connect writes under `HKCU\Software\Ubisoft\Launcher\Installs\<product>` when a
    /// download is cancelled. The files stay on disk (nothing else changes), so this is what tells it from a pause.
    public static let cancelledState = 3

    /// Every game folder under `gamesFolder` with a download that isn't finished (or cancelled), by product id.
    public static func inProgress(gamesFolder: URL, installStates: [Int: Int] = [:]) -> [Int: Progress] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: gamesFolder, includingPropertiesForKeys: nil)) ?? []
        var result: [Int: Progress] = [:]
        for folder in folders {
            guard let progress = progress(in: folder), !progress.isComplete,
                  installStates[progress.productID] != cancelledState else { continue }
            result[progress.productID] = progress
        }
        return result
    }

    /// `InstallState` values by product, from the user's registry file (`user.reg`).
    public static func installStates(userReg: String) -> [Int: Int] {
        var states: [Int: Int] = [:]
        var product: Int?
        let header = #"[software\\ubisoft\\launcher\\installs\\"#
        for raw in userReg.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                product = nil
                if line.lowercased().hasPrefix(header) { product = Int(line.dropFirst(header.count).prefix { $0.isNumber }) }
            } else if let id = product, line.lowercased().hasPrefix(#""installstate"=dword:"#),
                      let value = Int(line.split(separator: ":").last ?? "", radix: 16) {
                states[id] = value
            }
        }
        return states
    }

    public static func progress(in folder: URL) -> Progress? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("uplay_install.state")),
              let state = parseState(data) else { return nil }
        let installed = folder.appendingPathComponent("uplay_install.manifest")
        let staging = folder.appendingPathComponent("uplay_download/\(state.product)")
        let manifest: Manifest?
        if FileManager.default.fileExists(atPath: installed.path) {
            manifest = cachedManifest(installed)
        } else if let build = state.build {
            let launcher = folder.deletingLastPathComponent().deletingLastPathComponent()
            manifest = cachedManifest(launcher.appendingPathComponent("data/\(state.product)/manifests/\(build)"))
        } else { manifest = nil }
        guard let manifest else { return nil }
        let wanted = state.wanted ?? manifest.filter { $0.value.wanted(language: state.language ?? "en-US") }.map(\.key)
        var total: Int64 = 0, done: Int64 = 0
        for chunk in wanted {
            for file in manifest[chunk]?.files ?? [] {
                let path = file.path.replacingOccurrences(of: "\\", with: "/")
                total += file.size
                done += min(max(onDisk(folder.appendingPathComponent(path)), onDisk(staging.appendingPathComponent(path))), file.size)
            }
        }
        return Progress(productID: state.product, total: total, done: done)
    }

    struct State {
        var product: Int
        var build: String?
        var language: String?
        /// The chunks wanted, once the launcher has written them (after the download); nil while it runs.
        var wanted: [Int]?
    }

    static func parseState(_ data: Data) -> State? {
        let bytes = [UInt8](data)
        var product = 0
        var build: String?, language: String?
        var wanted: [Int] = []
        var listed = false
        do {
            try Protobuf.fields(bytes, 0..<bytes.count) { field, value in
                switch (field, value) {
                case (28, .varint(let v)): product = Int(v)
                case (1, .bytes(let r)), (10, .bytes(let r)): build = build ?? String(decoding: bytes[r], as: UTF8.self)
                case (3, .bytes(let r)): language = language ?? String(decoding: bytes[r], as: UTF8.self)
                case (6, .bytes(let range)):
                    listed = true
                    var id: Int?, want = false
                    try Protobuf.fields(bytes, range) { f, v in
                        if f == 1, case .varint(let x) = v { id = Int(x) }
                        if f == 3, case .varint(let x) = v { want = x != 0 }
                    }
                    if let id, want { wanted.append(id) }
                default: break
                }
            }
        } catch { return nil }
        guard product > 0 else { return nil }
        return State(product: product, build: build.flatMap { $0.isEmpty ? nil : $0 }, language: language, wanted: listed ? wanted : nil)
    }

    static func parseManifest(_ data: Data) -> Manifest? {
        guard data.count > 14 else { return nil }
        let signature = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        let size = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        let start = 12 + signature
        guard start + 2 < data.count, size > 0, size < 256 << 20,
              let body = inflate(data.subdata(in: (start + 2)..<data.count), capacity: size * 2) else { return nil }   // skip zlib's 2-byte header
        let bytes = [UInt8](body)
        var manifest: Manifest = [:]
        do {
            try Protobuf.fields(bytes, 0..<bytes.count) { field, value in
                guard field == 4, case .bytes(let chunk) = value else { return }
                var id: Int?
                var entry = Chunk()
                try Protobuf.fields(bytes, chunk) { f, v in
                    switch (f, v) {
                    case (1, .varint(let x)): id = Int(x)
                    case (5, .bytes(let r)): entry.language = String(decoding: bytes[r], as: UTF8.self)
                    case (8, _): entry.needsProduct = true
                    case (3, .bytes(let file)):
                        var path = "", size: Int64 = 0
                        try Protobuf.fields(bytes, file) { ff, vv in
                            if ff == 1, case .bytes(let r) = vv { path = String(decoding: bytes[r], as: UTF8.self) }
                            if ff == 2, case .varint(let x) = vv { size = Int64(x) }
                        }
                        if !path.isEmpty { entry.files.append((path, size)) }
                    default: break
                    }
                }
                if let id { manifest[id] = entry }
            }
        } catch { return nil }
        return manifest.isEmpty ? nil : manifest
    }

    /// Raw deflate (the zlib stream without its header), grown until it fits.
    static func inflate(_ data: Data, capacity: Int) -> Data? {
        var capacity = max(capacity, 1 << 16)
        for _ in 0..<4 {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0, written < capacity { out.count = written; return out }
            capacity *= 2
        }
        return nil
    }

    /// Bytes a file really holds: the smaller of its length and its allocated blocks (a file made full-size before
    /// it is filled counts only what has been written).
    static func onDisk(_ url: URL) -> Int64 {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return 0 }
        return min(Int64(info.st_size), Int64(info.st_blocks) * 512)
    }

    // The manifest is a few megabytes and doesn't change during a download: parsed once per file version.
    nonisolated(unsafe) private static var manifests: [String: (Date, Manifest)] = [:]
    private static let lock = NSLock()

    static func cachedManifest(_ url: URL) -> Manifest? {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        lock.lock()
        if let hit = manifests[url.path], hit.0 == modified { lock.unlock(); return hit.1 }
        lock.unlock()
        guard let data = try? Data(contentsOf: url), let manifest = parseManifest(data) else { return nil }
        lock.lock(); manifests[url.path] = (modified, manifest); lock.unlock()
        return manifest
    }
}
