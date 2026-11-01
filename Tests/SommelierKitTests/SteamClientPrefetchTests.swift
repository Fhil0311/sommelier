// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SteamClientPrefetchTests {
    func manifest() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "steam_client_win32", withExtension: nil, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The list the bootstrapper itself asked for on its first start (October 2026 log): 19 packages, 241,937 KB.
    @Test func picksWhatTheBootstrapperDownloads() throws {
        let packages = try SteamClientPrefetch.packages(fromManifest: manifest())
        #expect(packages.count == 19)
        #expect(packages.reduce(0) { $0 + $1.size } / 1024 == 241_937)
        let files = Set(packages.map(\.file))
        #expect(files.contains("bins_cef_win32_win7-64.zip.vz.cd0b352c7e651dd695c51a894a3973eb2efbee4b_105972111"))
        #expect(files.contains("steam_win32_steamrow.zip.vz.bbc936b85d699fd5a58f846502da312446c5c690_1884139"))
        #expect(files.contains("strings_en_all.zip.8eef428d222948911a09e2ceb6e5e8a7225b3447"))     // no .vz form
        #expect(!files.contains { $0.contains("steamchina") })
        #expect(packages.allSatisfy { $0.sha256.count == 64 })
    }

    @Test func installCopiesOnlyCompleteCachedPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefetch = SteamClientPrefetch(cache: root.appendingPathComponent("cache"))
        try FileManager.default.createDirectory(at: prefetch.cache, withIntermediateDirectories: true)
        let good = SteamClientPrefetch.Package(file: "a.zip.vz.x_3", size: 3, sha256: "")
        let partial = SteamClientPrefetch.Package(file: "b.zip.vz.y_5", size: 5, sha256: "")
        try Data("abc".utf8).write(to: prefetch.cache.appendingPathComponent(good.file))
        try Data("ab".utf8).write(to: prefetch.cache.appendingPathComponent(partial.file))   // interrupted download
        let steam = root.appendingPathComponent("Steam")

        #expect(try prefetch.install([good, partial], into: steam) == 1)
        #expect(FileManager.default.fileExists(atPath: steam.appendingPathComponent("package/\(good.file)").path))
        #expect(!FileManager.default.fileExists(atPath: steam.appendingPathComponent("package/\(partial.file)").path))
        #expect(try prefetch.install([good], into: steam) == 0)                       // already there
    }

    @Test func checksumMatchesShasum() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(try SteamClientPrefetch.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// Real download from Valve's CDN. Off by default; run with SOMMELIER_NETWORK_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_NETWORK_TESTS"] == "1"))
    func downloadsAndVerifiesTheClient() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("somm-steam-cache")
        let packages = try await SteamClientPrefetch(cache: cache).fetch()
        #expect(packages.allSatisfy { SteamClientPrefetch(cache: cache).isCached($0) })
    }
}
