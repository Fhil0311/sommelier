// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Builds a minimal appinfo.vdf (version 29: keys index a string table) for the given apps.
private func appinfo(_ apps: [(id: UInt32, name: String, type: String, os: String)],
                     deck: [UInt32: (category: UInt32, tokens: [String])] = [:],
                     assets: [UInt32: [String: String]] = [:]) -> Data {
    var table: [String] = []
    func key(_ s: String) -> [UInt8] {
        if let i = table.firstIndex(of: s) { return le32(UInt32(i)) }
        table.append(s); return le32(UInt32(table.count - 1))
    }
    func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    func le64(_ v: Int64) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    func str(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

    var body: [UInt8] = []
    for app in apps {
        var kv: [UInt8] = [0] + key("appinfo")
        kv += [2] + key("appid") + le32(app.id)
        kv += [0] + key("common")
        kv += [1] + key("name") + str(app.name)
        kv += [1] + key("type") + str(app.type)
        kv += [1] + key("oslist") + str(app.os)
        if let result = deck[app.id] {
            kv += [0] + key("steam_deck_compatibility")
            kv += [2] + key("category") + le32(result.category)
            kv += [0] + key("tests")
            for (i, token) in result.tokens.enumerated() {
                kv += [0] + key("\(i)") + [2] + key("display") + le32(1) + [1] + key("token") + str(token) + [8]
            }
            kv += [8, 8]                            // end tests, end steam_deck_compatibility
        }
        if let paths = assets[app.id] {
            kv += [0] + key("library_assets_full")
            for (kind, path) in paths.sorted(by: { $0.key < $1.key }) {
                kv += [0] + key(kind) + [0] + key("image") + [1] + key("english") + str(path) + [8, 8]
            }
            kv += [8]                               // end library_assets_full
        }
        kv += [8]                                   // end common
        kv += [0] + key("extended") + [1] + key("developer") + str("Studio") + [8]
        kv += [8]                                   // end appinfo
        kv += [8]                                   // end root
        let header: [UInt8] = le32(2) + le32(0) + le64(0) + Array(repeating: 0, count: 20) + le32(1) + Array(repeating: 0, count: 20)
        body += le32(app.id) + le32(UInt32(header.count + kv.count)) + header + kv
    }
    body += le32(0)
    let tableOffset = Int64(16 + body.count)
    var out: [UInt8] = le32(0x0756_4429) + le32(1) + le64(tableOffset) + body
    out += le32(UInt32(table.count))
    for s in table { out += str(s) }
    return Data(out)
}

@Suite struct SteamOwnedGamesTests {
    @Test func parsesVersion29() throws {
        let apps = try AppInfo.parse(appinfo([(10, "Counter-Strike", "Game", "windows,macos,linux"),
                                              (20, "Soundtrack", "Music", "windows")]))
        #expect(apps == [AppInfo.App(appID: "10", name: "Counter-Strike", type: "Game", oslist: "windows,macos,linux"),
                         AppInfo.App(appID: "20", name: "Soundtrack", type: "Music", oslist: "windows")])
    }

    @Test func readsSteamDeckResults() throws {
        let apps = try AppInfo.parse(appinfo(
            [(1, "Verified", "Game", "windows"), (2, "Anti-cheat", "Game", "windows"), (3, "Untested", "Game", "windows")],
            deck: [1: (3, ["#SteamDeckVerified_TestResult_DefaultConfigurationIsPerformant"]),
                   2: (1, ["#SteamDeckVerified_TestResult_UnsupportedAntiCheat_Other"])]))
        #expect(apps[0].deck == DeckCompatibility(category: 3, tokens: ["#SteamDeckVerified_TestResult_DefaultConfigurationIsPerformant"]))
        #expect(apps[1].deck?.category == 1)
        #expect(Compatibility.rate(deck: apps[1].deck).notes == [.noOnline])
        #expect(apps[2].deck == nil)
        #expect(apps[0].name == "Verified")                          // the rest of common still reads
    }

    @Test func listsLibraryGamesOnlyAndSkipsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: root))
        let cache = bottle.steamDirectory.appendingPathComponent("appcache")
        for id in ["10", "20", "30", "40"] {
            try FileManager.default.createDirectory(at: cache.appendingPathComponent("librarycache/\(id)"), withIntermediateDirectories: true)
        }
        try Data().write(to: cache.appendingPathComponent("librarycache/30/library_600x900.jpg"))
        try appinfo([(10, "Installed Game", "game", "windows"), (20, "A DLC", "DLC", "windows"),
                     (30, "Mac Game", "Game", "windows,macos"), (40, "Tool", "Tool", "windows"),
                     (50, "Not In Library", "Game", "windows")])
            .write(to: cache.appendingPathComponent("appinfo.vdf"))

        let owned = SteamOwnedGames.scan(bottle: bottle)
        #expect(owned.map(\.appID) == ["10", "30"])
        #expect(owned.first { $0.appID == "30" }?.macBuild == .legacy32)      // "macos" without osextended: 32-bit
        #expect(owned.first { $0.appID == "10" }?.macBuild == nil)

        let installed = [Game(store: .steam, storeID: "10", title: "Installed Game", isInstalled: true)]
        let rest = SteamOwnedGames.notInstalledGames(bottle: bottle, installed: installed)
        #expect(rest.map(\.storeID) == ["30"])
        #expect(rest.first?.isInstalled == false)
        #expect(rest.first?.coverURL?.isFileURL == true)               // Steam's own cached art
    }

    @Test func missingOrBrokenCacheGivesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: root))
        #expect(SteamOwnedGames.scan(bottle: bottle).isEmpty)
        #expect(throws: (any Error).self) { try AppInfo.parse(Data([1, 2, 3])) }
    }

    /// Reads a real Steam cache when SOMMELIER_STEAM_DIR points at a Steam folder. Off by default.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_STEAM_DIR"] != nil))
    func readsARealCache() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMMELIER_STEAM_DIR"]!)
        let apps = try AppInfo.parse(Data(contentsOf: dir.appendingPathComponent("appcache/appinfo.vdf")))
        let games = apps.filter { $0.type.lowercased() == "game" }
        print("real cache: \(apps.count) apps, \(games.count) games, \(games.filter { $0.oslist.contains("macos") }.count) with a Mac version")
        let ratings = Dictionary(grouping: games) { Compatibility.rate(deck: $0.deck).verdict }.mapValues(\.count)
        print("real cache ratings:", Compatibility.Verdict.allCases.map { "\($0): \(ratings[$0] ?? 0)" }.joined(separator: ", "))
        #expect(!games.isEmpty)
    }
}

@Suite struct SteamArtworkTests {
    @Test func readsArtworkPathsFromAppInfo() throws {
        let paths = ["library_capsule": "c694b5ec/library_600x900.jpg", "library_logo": "logo.png"]
        let apps = try AppInfo.parse(appinfo([(10, "Game", "game", "windows")], assets: [10: paths]))
        #expect(apps.first?.assets == paths)
    }

    @Test func prefersSteamsCacheThenItsCDN() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("librarycache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("10")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("c694b5ec"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("c694b5ec/library_600x900.jpg"))   // a hashed asset: in its hash folder
        try Data().write(to: folder.appendingPathComponent("library_hero.jpg"))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("logo.png"), withIntermediateDirectories: true)   // a folder is no image
        let art = SteamArtwork(appID: "10", assets: ["library_capsule": "c694b5ec/library_600x900.jpg"], cacheDirectory: dir)
        #expect(art.cover == folder.appendingPathComponent("c694b5ec/library_600x900.jpg"))
        #expect(art.hero == folder.appendingPathComponent("library_hero.jpg"))
        #expect(art.logo?.absoluteString == "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/10/logo.png")
    }

    @Test func hashedPathsReachTheCDN() {
        let art = SteamArtwork(appID: "1538550", assets: ["library_capsule": "c694b5ec/library_600x900.jpg", "header_image": "db718ae2/header.jpg"],
                               cacheDirectory: nil)
        #expect(art.cover?.absoluteString.hasSuffix("/apps/1538550/c694b5ec/library_600x900.jpg") == true)
        #expect(art.header?.absoluteString.hasSuffix("/apps/1538550/db718ae2/header.jpg") == true)
        let plain = SteamArtwork.plain(appID: "20")
        #expect(plain.cover?.lastPathComponent == "library_600x900.jpg")
        #expect(plain.header?.lastPathComponent == "header.jpg")
    }
}
