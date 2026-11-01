// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Why the store couldn't take or hand back a mod. Reasons only; the app words them.
public enum ModStoreError: Error, Equatable {
    /// An archive entry that could leave the folder it is unpacked into.
    case unsafeArchive(String)
    /// `tar` couldn't read the archive, with what it said.
    case extractFailed(String)
    /// No mod of that key in the store.
    case notFound(String)
    /// The plan still has a question or a refusal, or holds nothing to place.
    case planNotReady
}

/// A mod as the store keeps it: `mod.json` next to its unpacked files. The units are the plan the archive was
/// taken in with, so the deployer places the very same files again after a game update or when the mod is
/// turned back on. `enabled` is what the player wants; whether the files are in the game is `deployed.json`'s.
public struct StoredMod: Codable, Equatable, Identifiable, Sendable {
    /// Where the archive came from, for the mod's card and update checks later on.
    public struct Origin: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case file, nexus, modio, github, url }
        public var kind: Kind
        public var url: String?
        public var modID: Int?, fileID: Int?

        public init(kind: Kind = .file, url: String? = nil, modID: Int? = nil, fileID: Int? = nil) {
            self.kind = kind; self.url = url; self.modID = modID; self.fileID = fileID
        }
    }

    /// The archive as it was added: its name, hash and size. The archive itself isn't kept.
    public struct Archive: Codable, Equatable, Sendable {
        public var name: String
        public var sha256: String?
        public var bytes: Int64

        public init(name: String, sha256: String? = nil, bytes: Int64 = 0) {
            self.name = name; self.sha256 = sha256; self.bytes = bytes
        }
    }

    /// Version of this layout.
    public var format = 1
    /// The mod's folder name in the store, unique in the game's store and never changing.
    public var key: String
    public var name: String
    public var version: String?
    public var author: String?
    public var origin: Origin
    public var archive: Archive
    public var added: Date
    public var enabled: Bool
    /// The "This mod contains code" sheet was accepted for this mod.
    public var codeAccepted: Bool
    public var units: [ModPlan.Unit]
    /// Files no kind took, kept with the mod and never placed.
    public var leftovers: [String]

    public var id: String { key }
    public var containsCode: Bool { units.contains { $0.code } }
    /// The frameworks the mod needs, in the order its units name them.
    public var frameworks: [String] {
        var seen: [String] = []
        for unit in units { if let framework = unit.framework, !seen.contains(framework) { seen.append(framework) } }
        return seen
    }
    /// Every archive path the deployer places (skipped ones left out).
    public var placedSources: [String] { units.flatMap { $0.files.filter { !$0.skipped }.map(\.source) } }
}

/// `index.json` in a game's store: the mods in the order they were added. Rebuilt from the folders when it is
/// missing or out of step with them.
struct ModIndex: Codable, Equatable {
    var format = 1
    var keys: [String] = []
}

/// A game's mods on disk: `<Sommelier>/Mods/<game>/<key>/` holding `mod.json` and the unpacked archive under
/// `files/`, plus `index.json`. The deployer links the files from here into the game and keeps its own
/// `deployed.json` and the originals it replaced next to them, so everything about one game's mods sits in
/// one folder. Archives are unpacked with `/usr/bin/tar` (zip, 7z, rar) into a temporary folder here after
/// their entries have been checked for paths that could leave it; links inside an archive are dropped.
public struct ModStore: Sendable {
    public let folder: URL

    static let indexName = "index.json"
    static let deployedName = "deployed.json"
    static let originalsName = ".originals"
    static let temporaryName = ".tmp"
    static let modFile = "mod.json"
    static let filesFolder = "files"
    /// Markers and other small files are read whole; anything bigger isn't a manifest.
    static let manifestLimit = 256 << 10

    public init(folder: URL) { self.folder = folder }
    public init(paths: Paths, gameID: String) { self.init(folder: paths.mods(gameID)) }

    // MARK: Places

    public func folder(of key: String) -> URL { folder.appendingPathComponent(key, isDirectory: true) }
    /// The unpacked archive of a mod.
    public func files(of key: String) -> URL { folder(of: key).appendingPathComponent(Self.filesFolder, isDirectory: true) }
    /// One of a mod's files, by its archive path.
    public func file(of key: String, at source: String) -> URL {
        URL(fileURLWithPath: ([files(of: key).path] + source.split(separator: "/").map(String.init)).joined(separator: "/"))
    }
    /// `deployed.json` and the originals the deployer replaced, for `ModDeployer`.
    var deployedFile: URL { folder.appendingPathComponent(Self.deployedName) }
    var originals: URL { folder.appendingPathComponent(Self.originalsName, isDirectory: true) }

    /// Whether a path under the store (its components) lands on Sommelier's own files there rather than in a
    /// folder of a mod's: the records, the loaders' staging (`frameworks/`), the remembered order, the loader's
    /// generated profile, a dot folder (originals, downloads, temporary unpacks), or a `mod.json` that would
    /// make a mod's folder look like a stored mod. Letter case doesn't matter, as on the Mac's disks.
    public static func isOwnPath(_ components: [String], loaderFiles: [String] = ["sommelier.me3"]) -> Bool {
        guard let first = components.first?.lowercased() else { return true }
        let own = [indexName, deployedName, LoadOrder.fileName, FrameworkInstaller.folderName, modFile] + loaderFiles
        if first.hasPrefix(".") || own.contains(where: { $0.lowercased() == first }) { return true }
        return components.count == 2 && components[1].lowercased() == modFile
    }

    private var index: JSONStore<ModIndex> { JSONStore(url: folder.appendingPathComponent(Self.indexName)) }
    private func modFile(of key: String) -> URL { folder(of: key).appendingPathComponent(Self.modFile) }

    // MARK: Listing

    /// The mods in the store, in the order they were added. Folders the index doesn't know are taken in at the
    /// end; keys whose folder is gone are dropped.
    public func list() -> [StoredMod] {
        var stored = index.load(default: ModIndex())
        let disk = FileManager.default
        let present = ((try? disk.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && disk.fileExists(atPath: modFile(of: $0).path) }
        var keys = stored.keys.filter { present.contains($0) }
        keys += present.filter { !keys.contains($0) }.sorted()
        if keys != stored.keys {
            stored.keys = keys
            try? index.save(stored)
        }
        return keys.compactMap(mod)
    }

    public func keys() -> [String] { list().map(\.key) }

    /// One mod by its key, or nil when it isn't there or its `mod.json` can't be read.
    public func mod(_ key: String) -> StoredMod? {
        guard let bytes = try? Data(contentsOf: modFile(of: key)) else { return nil }
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        return try? reader.decode(StoredMod.self, from: bytes)
    }

    /// Writes a mod's `mod.json` (after `enabled` or `codeAccepted` changed).
    public func save(_ mod: StoredMod) throws {
        let writer = JSONEncoder()
        writer.dateEncodingStrategy = .iso8601
        writer.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: folder(of: mod.key), withIntermediateDirectories: true)
        try writer.encode(mod).write(to: modFile(of: mod.key), options: .atomic)
    }

    // MARK: Adding

    /// Takes an unpacked archive (`unpacked`, from `unpack`) into the store under a fresh key as the plan read
    /// it: the folder the plan's paths are relative to becomes the mod's `files/`, the rest of the temporary
    /// folder goes. `archive` is hashed for the record when given.
    @discardableResult
    public func add(name: String, plan: ModPlan, unpacked: URL, archive: URL? = nil, origin: StoredMod.Origin = .init(),
                    version: String? = nil, author: String? = nil, now: Date = Date()) throws -> StoredMod {
        guard plan.isReady else { throw ModStoreError.planNotReady }
        let disk = FileManager.default
        try disk.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = Self.key(for: name, taken: Set(((try? disk.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() }))
        let home = folder(of: key)
        let source = plan.base.isEmpty ? unpacked : URL(fileURLWithPath: ([unpacked.path] + plan.base.split(separator: "/").map(String.init)).joined(separator: "/"), isDirectory: true)
        do {
            try disk.createDirectory(at: home, withIntermediateDirectories: true)
            try disk.moveItem(at: source, to: files(of: key))
            let record = archive.map { url in
                let size = (FileScan.attributes(url)?[.size] as? NSNumber)?.int64Value ?? 0
                return StoredMod.Archive(name: url.lastPathComponent, sha256: Self.sha256(of: url), bytes: size)
            } ?? StoredMod.Archive(name: name)
            // Whole seconds, as the file keeps them, so what is returned equals what is read back.
            let added = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            let mod = StoredMod(key: key, name: name, version: version, author: author, origin: origin, archive: record, added: added,
                                enabled: true, codeAccepted: false, units: plan.units, leftovers: plan.leftovers)
            try save(mod)
            var stored = index.load(default: ModIndex())
            stored.keys.removeAll { $0 == key }
            stored.keys.append(key)
            try index.save(stored)
            if source != unpacked { try? disk.removeItem(at: unpacked) }
            return mod
        } catch {
            try? disk.removeItem(at: home)
            throw error
        }
    }

    /// Deletes a mod's folder and its index entry. The deployer must have taken its files out of the game first.
    public func remove(_ key: String) throws {
        let disk = FileManager.default
        guard disk.fileExists(atPath: modFile(of: key).path) else { throw ModStoreError.notFound(key) }
        try disk.removeItem(at: folder(of: key))
        var stored = index.load(default: ModIndex())
        stored.keys.removeAll { $0 == key }
        try index.save(stored)
    }

    /// A folder name for a mod: the name as plain ASCII, with a short random tail so two mods of one name (or a
    /// mod and a folder a profile places in the store, Elden Ring's `store:{name}/`) never share a folder.
    static func key(for name: String, taken: Set<String>) -> String {
        var slug = ""
        var lastWasDash = true
        for scalar in name.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if scalar.properties.generalCategory == .nonspacingMark {
                // The accent taken off a letter above; the letter stays.
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "mod" }
        slug = String(slug.prefix(40))
        while true {
            let tail = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(6))
            let candidate = slug + "-" + tail
            if !taken.contains(candidate) { return candidate }
        }
    }

    // MARK: Archives

    private static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    /// The archive's entries as `tar` lists them (folders with a trailing slash), for `ModArchive.plan`. An
    /// entry that could leave the unpack folder refuses the whole archive before anything is written.
    public func entries(of archive: URL) async throws -> [String] {
        let lines = Lines()
        let result = try await ProcessRunner.run(Self.tar, ["-t", "-f", archive.path]) { line in
            if case .stdout(let text) = line { lines.add(text) }
        }
        guard result.succeeded else { throw ModStoreError.extractFailed(result.output) }
        let entries = lines.all.filter { !$0.isEmpty }
        for entry in entries where !Self.isSafe(entry: entry) { throw ModStoreError.unsafeArchive(entry) }
        return entries
    }

    /// Unpacks the archive into a fresh temporary folder inside the store (so `add` can move it into place on
    /// the same volume) and returns that folder. Entries are checked first; afterwards anything that isn't a
    /// file or a folder (links above all) is dropped. The caller passes the folder to `add` or deletes it.
    public func unpack(_ archive: URL) async throws -> URL {
        _ = try await entries(of: archive)
        let disk = FileManager.default
        let temporary = folder.appendingPathComponent(Self.temporaryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try disk.createDirectory(at: temporary, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(Self.tar, ["-x", "-f", archive.path, "-C", temporary.path])
        guard result.succeeded else {
            try? disk.removeItem(at: temporary)
            throw ModStoreError.extractFailed(result.output)
        }
        try Self.keepFilesAndFolders(in: temporary)
        return temporary
    }

    /// Deletes the temporary folders left by unpacks that were never added.
    public func discardTemporary() {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.temporaryName, isDirectory: true))
    }

    /// The marker files a `codeIf` kind reads, from an unpacked archive, keyed by their entry path as `entries`
    /// lists them, for `ModArchive.plan(manifests:)`.
    public func manifests(in unpacked: URL, entries: [String], profile: ModProfile) -> [String: Data] {
        let markers = Set(profile.kinds.filter { $0.codeIf != nil }.compactMap { kind in
            (kind.marker ?? ModArchive.basename(kind.match)).split(whereSeparator: { $0 == "/" || $0 == "\\" }).last?.lowercased()
        })
        guard !markers.isEmpty else { return [:] }
        var found: [String: Data] = [:]
        for entry in entries {
            let path = Self.normalised(entry)
            guard !path.hasSuffix("/"), markers.contains(ModArchive.basename(path).lowercased()) else { continue }
            let url = URL(fileURLWithPath: ([unpacked.path] + path.split(separator: "/").map(String.init)).joined(separator: "/"))
            guard FileScan.isRegularFile(url), let size = FileScan.attributes(url)?[.size] as? NSNumber, size.intValue <= Self.manifestLimit,
                  let data = try? Data(contentsOf: url) else { continue }
            found[path] = data
        }
        return found
    }

    /// Relative, no `..`, no drive: the same rule the plan applies, after the `./` tar likes to add.
    static func isSafe(entry: String) -> Bool {
        let path = normalised(entry)
        return path.isEmpty || ModPath.isSafe(path)
    }

    static func normalised(_ entry: String) -> String {
        var path = entry.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path
    }

    /// Removes every item below `top` that isn't a plain file or folder: links, sockets, whatever an archive
    /// may carry. A link to somewhere else must never be followed when the files are placed.
    static func keepFilesAndFolders(in top: URL) throws {
        let disk = FileManager.default
        guard let walker = disk.enumerator(at: top, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: []) else { return }
        var doomed: [URL] = []
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            if values.isSymbolicLink == true || (values.isRegularFile != true && values.isDirectory != true) {
                doomed.append(item)
                walker.skipDescendants()
            }
        }
        for item in doomed { try disk.removeItem(at: item) }
    }

    /// Hex SHA-256 of a file, read in chunks.
    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Collects `tar`'s listing as it arrives.
private final class Lines: @unchecked Sendable {
    private let mutex = NSLock()
    private var collected: [String] = []

    func add(_ line: String) { mutex.withLock { collected.append(line) } }
    var all: [String] { mutex.withLock { collected } }
}
