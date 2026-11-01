// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Downloads the Steam client's packages with the Mac's own networking, before Steam first starts.
///
/// Valve's installer only lays down a bootstrapper. On its first start it reads the client manifest
/// (`steam_client_win32`) and downloads about 240 MB of packages into `Steam/package`, one at a time, from
/// inside Wine (about 1.3 MB/s in testing). The bootstrapper skips any package already there with the right
/// size, so fetching them natively and in parallel, while the engine installs, makes Steam's first start
/// mostly unpacking. Every file is checked against the manifest's SHA-256 before Steam sees it.
/// The 32-bit client it installs then moves to the 64-bit one (`steam_client_win64`, another 240 MB from a
/// different host), so both sets are fetched.
public struct SteamClientPrefetch: Sendable {
    /// A client manifest: where it is, its root key, and where its packages are.
    struct Manifest: Sendable { let url: URL, root: String, base: URL }
    static let manifests = [
        Manifest(url: URL(string: "https://cdn.steamstatic.com/client/steam_client_win32")!, root: "win32",
                 base: URL(string: "https://cdn.steamstatic.com/client/")!),
        Manifest(url: URL(string: "https://client-update.steamstatic.com/steam_client_win64")!, root: "win64",
                 base: URL(string: "https://client-update.steamstatic.com/")!),
    ]
    /// Variant blocks the bootstrapper picks on 64-bit Windows outside China (checked against its own log).
    static let preferredVariants = ["win7-64", "steamrow"]

    public struct Package: Equatable, Sendable {
        /// The file name in `Steam/package` and on the CDN (the compressed `.zip.vz` form when the manifest has one).
        public let file: String
        public let size: Int64
        public let sha256: String
        /// The CDN folder it comes from.
        public var base = URL(string: "https://cdn.steamstatic.com/client/")!
    }

    public let cache: URL
    public init(cache: URL) { self.cache = cache }

    // MARK: Manifest

    public static func packages(fromManifest text: String, root key: String = "win32") throws -> [Package] {
        guard let root = try VDFParser.parse(text)[key]?.entries else { return [] }
        var result: [Package] = []
        for (_, block) in root {
            guard block.entries != nil else { continue }          // "version", "ostype"
            let chosen = preferredVariants.lazy.compactMap { block[$0] }.first ?? block
            if let package = package(in: chosen) { result.append(package) }
        }
        return result
    }

    static func package(in block: VDFValue) -> Package? {
        if let vz = block["zipvz"]?.string, let sha = block["sha2vz"]?.string,
           let size = vz.split(separator: "_").last.flatMap({ Int64($0) }) {
            return Package(file: vz, size: size, sha256: sha.lowercased())
        }
        guard let file = block["file"]?.string, let sha = block["sha2"]?.string,
              let size = block["size"]?.string.flatMap({ Int64($0) }) else { return nil }
        return Package(file: file, size: size, sha256: sha.lowercased())
    }

    // MARK: Download

    /// Downloads every package not already in the cache. Returns the packages, all verified.
    @discardableResult
    public func fetch(parallel: Int = 6, session: URLSession = .shared,
                      progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void = { _, _ in }) async throws -> [Package] {
        var packages: [Package] = []
        for (index, manifest) in Self.manifests.enumerated() {
            // Only the first is required: if Valve moves or changes the 64-bit one, Steam fetches it itself as before.
            guard let (data, response) = try? await session.data(from: manifest.url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, let text = String(data: data, encoding: .utf8),
                  let listed = try? Self.packages(fromManifest: text, root: manifest.root) else {
                if index == 0 { throw WineRunnerError.launchFailed("couldn't read Steam's client manifest") }
                continue
            }
            for var package in listed
            where !packages.contains(where: { $0.file == package.file }) {
                package.base = manifest.base
                packages.append(package)
            }
        }
        guard !packages.isEmpty else { throw WineRunnerError.launchFailed("Steam's client manifest lists no packages") }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let total = packages.reduce(0) { $0 + $1.size }
        let counter = ByteCounter()
        let missing = packages.filter { !isCached($0) }
        await counter.add(total - missing.reduce(0) { $0 + $1.size })
        progress(await counter.value, total)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = missing[...]
            func next() {
                guard let package = queue.popFirst() else { return }
                group.addTask {
                    try await self.download(package, session: session)
                    progress(await counter.add(package.size), total)
                }
            }
            for _ in 0..<max(1, parallel) { next() }
            while try await group.next() != nil { next() }
        }
        return packages
    }

    func isCached(_ package: Package) -> Bool {
        let url = cache.appendingPathComponent(package.file)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        return size == package.size
    }

    private func download(_ package: Package, session: URLSession) async throws {
        let (tmp, response) = try await session.download(from: package.base.appendingPathComponent(package.file))
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else {
            throw WineRunnerError.launchFailed("couldn't download \(package.file)")
        }
        guard try Self.sha256(of: tmp) == package.sha256 else {
            throw WineRunnerError.launchFailed("\(package.file) failed its checksum")
        }
        let target = cache.appendingPathComponent(package.file)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Hand-over

    /// Copies cached packages into Steam's `package` folder (clones on APFS, so no extra space), skipping those
    /// already there with the right size. Returns how many were placed.
    @discardableResult
    public func install(_ packages: [Package], into steamDirectory: URL) throws -> Int {
        let fm = FileManager.default
        let folder = steamDirectory.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var placed = 0
        for package in packages where isCached(package) {
            let target = folder.appendingPathComponent(package.file)
            if ((try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? -1) == package.size { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: cache.appendingPathComponent(package.file), to: target)
            placed += 1
        }
        return placed
    }
}

private actor ByteCounter {
    private(set) var value: Int64 = 0
    @discardableResult func add(_ bytes: Int64) -> Int64 { value += bytes; return value }
}
