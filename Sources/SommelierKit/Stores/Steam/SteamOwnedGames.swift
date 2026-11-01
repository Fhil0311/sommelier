// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The games in the signed-in Steam account, read from Steam's own cache after sign-in. Nothing is sent anywhere.
///
/// `appcache/appinfo.vdf` holds name, type and supported systems for every app Steam knows for the account
/// (games, DLC, tools, soundtracks). `appcache/librarycache/<appid>` exists for each app in the user's library,
/// with its artwork. A game is listed when it is in both and its type is "game".
public enum SteamOwnedGames {
    public struct Entry: Equatable, Sendable {
        public let appID: String
        public let name: String
        /// The Mac version Steam sells, if any (see `MacBuild`).
        public let macBuild: MacBuild?
        /// Valve's Steam Deck test result, when the game has one.
        public let deck: DeckCompatibility?
        /// Where the game's cover, hero, logo and header are.
        public var artwork = SteamArtwork()
    }

    public static func scan(bottle: Bottle) -> [Entry] {
        let cache = bottle.steamDirectory.appendingPathComponent("appcache")
        guard let data = try? Data(contentsOf: cache.appendingPathComponent("appinfo.vdf")),
              let apps = try? AppInfo.parse(data) else { return [] }
        let library = Set(((try? FileManager.default.contentsOfDirectory(atPath: cache.appendingPathComponent("librarycache").path)) ?? [])
            .filter { $0.allSatisfy(\.isNumber) })
        return apps.filter { $0.type.lowercased() == "game" && library.contains($0.appID) && !$0.name.isEmpty }
            .map { Entry(appID: $0.appID, name: $0.name, macBuild: MacBuild.steam(oslist: $0.oslist, osextended: $0.osextended), deck: $0.deck,
                         artwork: SteamArtwork(appID: $0.appID, assets: $0.assets, cacheDirectory: cache.appendingPathComponent("librarycache"),
                                               clientIcon: $0.clientIcon)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Artwork Steam already downloaded for its library: no network needed.
    public static func cachedArtwork(appID: String, file: String, bottle: Bottle) -> URL? {
        let url = bottle.steamDirectory.appendingPathComponent("appcache/librarycache/\(appID)/\(file)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Games in the account that aren't installed, as library entries.
    public static func notInstalledGames(bottle: Bottle, installed: [Game]) -> [Game] {
        let installedIDs = Set(installed.map(\.storeID))
        return scan(bottle: bottle).filter { !installedIDs.contains($0.appID) }.map { entry in
            Game(store: .steam, storeID: entry.appID, title: entry.name, isInstalled: false,
                 coverURL: cachedArtwork(appID: entry.appID, file: "library_600x900.jpg", bottle: bottle)
                    ?? SteamLibrary.artworkURL(appID: entry.appID, "library_600x900.jpg"),
                 heroURL: cachedArtwork(appID: entry.appID, file: "library_hero.jpg", bottle: bottle)
                    ?? SteamLibrary.artworkURL(appID: entry.appID, "library_hero.jpg"))
        }
    }
}

/// Where a Steam game's artwork is. Steam's own cache has the file once Steam has shown the game; otherwise it is
/// on Steam's CDN under the app's folder. Newer games keep their files under a hash folder named in appinfo's
/// `library_assets_full` (`c694…/library_600x900.jpg`), so the fixed names alone miss them, as they miss the
/// games whose cover is `library_capsule.jpg`. This reads the same table Steam's own library does.
public struct SteamArtwork: Equatable, Sendable {
    public var cover: URL?
    public var hero: URL?
    public var logo: URL?
    /// The wide capsule (460×215): the stand-in for games without a cover, as in Steam's library.
    public var header: URL?
    /// The game's own Windows icon (`.ico`, often up to 256 pixels), as its Steam shortcut has it: Steam keeps the
    /// file in `steam/games` once it has used it, and the community CDN serves it by the same name.
    public var icon: URL?

    public init() {}

    public init(appID: String, assets: [String: String], cacheDirectory: URL?, clientIcon: String = "") {
        func url(_ kind: String, or fallback: String) -> URL? {
            let path = assets[kind] ?? fallback
            if let cacheDirectory {
                // Steam's cache mirrors the CDN layout: `<appid>/<hash>/library_600x900.jpg`.
                let local = cacheDirectory.appendingPathComponent(appID).appendingPathComponent(path)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory), !isDirectory.boolValue { return local }
            }
            return SteamLibrary.artworkURL(appID: appID, path)
        }
        cover = url("library_capsule", or: "library_600x900.jpg")
        hero = url("library_hero", or: "library_hero.jpg")
        logo = url("library_logo", or: "logo.png")
        header = url(assets["library_header"] != nil ? "library_header" : "header_image", or: "header.jpg")
        if !clientIcon.isEmpty, clientIcon.allSatisfy({ $0.isHexDigit }) {
            // cacheDirectory is <Steam>/appcache/librarycache.
            let local = cacheDirectory?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("steam/games/\(clientIcon).ico")
            icon = local.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? URL(string: "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/\(appID)/\(clientIcon).ico")
        }
    }

    /// The fixed names alone, for a game Steam's cache doesn't know.
    public static func plain(appID: String) -> SteamArtwork { SteamArtwork(appID: appID, assets: [:], cacheDirectory: nil) }
}

/// Reader for Steam's binary `appinfo.vdf` (versions 28 and 29), keeping only what the library needs.
enum AppInfo {
    struct App: Equatable {
        let appID: String; let name: String; let type: String; let oslist: String
        var osextended: String = ""
        var deck: DeckCompatibility? = nil
        /// `library_assets_full`: each artwork file's path under the app's CDN folder (see `SteamArtwork`).
        var assets: [String: String] = [:]
        /// `common/clienticon`: the hash naming the game's Windows icon (`<hash>.ico`).
        var clientIcon: String = ""
    }

    enum ParseError: Error { case badMagic, truncated, unknownType(UInt8) }

    static func parse(_ data: Data) throws -> [App] {
        var reader = Reader(bytes: [UInt8](data))
        let magic = try reader.u32()
        _ = try reader.u32()                                            // universe
        var strings: [String]? = nil
        switch magic {
        case 0x0756_4429:                                               // v29: keys index a string table
            let offset = Int(try reader.i64())
            var table = Reader(bytes: reader.bytes, at: offset)
            let count = Int(try table.u32())
            strings = try (0..<count).map { _ in try table.cString() }
        case 0x0756_4428: break                                         // v28: keys are inline strings
        default: throw ParseError.badMagic
        }
        var apps: [App] = []
        while true {
            let appID = try reader.u32()
            if appID == 0 { break }
            let size = Int(try reader.u32())
            let end = reader.position + size
            reader.position += 4 + 4 + 8 + 20 + 4 + 20                 // state, updated, token, hash, change, hash
            if let (common, deck, assets) = try? readCommon(&reader, strings: strings) {
                apps.append(App(appID: String(appID), name: common["name"] ?? "", type: common["type"] ?? "",
                                oslist: common["oslist"] ?? "", osextended: common["osextended"] ?? "", deck: deck, assets: assets,
                                clientIcon: common["clienticon"] ?? ""))
            }
            reader.position = end
        }
        return apps
    }

    /// Walks the binary key-values of one app: the string values of `appinfo/common`, the Steam Deck result in
    /// `appinfo/common/steam_deck_compatibility` (its `category` and the `token` of each `tests` entry), and the
    /// artwork paths in `appinfo/common/library_assets_full/<kind>/image/<language>` (English when there is one).
    private static func readCommon(_ r: inout Reader, strings: [String]?) throws -> ([String: String], DeckCompatibility?, [String: String]) {
        var path: [String] = []
        var common: [String: String] = [:]
        var deckCategory: Int32?
        var deckTokens: [String] = []
        var assets: [String: String] = [:]
        let deckPath = ["appinfo", "common", "steam_deck_compatibility"]
        let assetsPath = ["appinfo", "common", "library_assets_full"]
        while true {
            let type = try r.u8()
            if type == 8 {                                              // end of map
                if path.isEmpty {
                    return (common, deckCategory.map { DeckCompatibility(category: Int($0), tokens: deckTokens) }, assets)
                }
                path.removeLast(); continue
            }
            let key = try strings.map { table in table[Int(try r.u32())] } ?? r.cString()
            switch type {
            case 0: path.append(key)
            case 1:
                let value = try r.cString()
                if path == ["appinfo", "common"] { common[key] = value }
                if key == "token", path.count == 5, Array(path.prefix(4)) == deckPath + ["tests"] { deckTokens.append(value) }
                if path.count == 5, path[4] == "image", Array(path.prefix(3)) == assetsPath, key == "english" || assets[path[3]] == nil {
                    assets[path[3]] = value
                }
                if path == ["appinfo", "common", "header_image"], key == "english" || assets["header_image"] == nil { assets["header_image"] = value }
            case 2:
                let value = try r.i32()
                if key == "category", path == deckPath { deckCategory = value }
            case 3, 4, 6: r.position += 4
            case 7, 10: r.position += 8
            case 5: _ = try r.cString(); _ = try r.cString()             // wide string; not used
            default: throw ParseError.unknownType(type)
            }
        }
    }

    struct Reader {
        let bytes: [UInt8]
        var position: Int
        init(bytes: [UInt8], at position: Int = 0) { self.bytes = bytes; self.position = position }

        mutating func u8() throws -> UInt8 {
            guard position < bytes.count else { throw ParseError.truncated }
            defer { position += 1 }
            return bytes[position]
        }
        mutating func u32() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw ParseError.truncated }
            defer { position += 4 }
            return bytes[position..<position + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func i64() throws -> Int64 {
            guard position + 8 <= bytes.count else { throw ParseError.truncated }
            defer { position += 8 }
            return Int64(bitPattern: bytes[position..<position + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) })
        }
        mutating func cString() throws -> String {
            guard let end = bytes[position...].firstIndex(of: 0) else { throw ParseError.truncated }
            defer { position = end + 1 }
            return String(decoding: bytes[position..<end], as: UTF8.self)
        }
    }
}
