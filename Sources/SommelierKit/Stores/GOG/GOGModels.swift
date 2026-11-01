// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads what GOG hands us: its web API, the answers gogdl prints, and the `goggame-<id>.info` file every GOG game
/// ships with.
public enum GOGParser: Sendable {
    // MARK: Library

    /// One owned item on a page of `embed.gog.com/account/getFilteredProducts`.
    struct Product: Decodable, Sendable {
        struct Platforms: Decodable {
            let windows: Bool?
            let mac: Bool?
            enum CodingKeys: String, CodingKey { case windows = "Windows", mac = "Mac" }
        }
        let id: Int
        let title: String
        let isGame: Bool?
        let worksOn: Platforms?
    }

    struct LibraryPage: Decodable {
        let products: [Product]   // this page's items only
        let totalPages: Int?   // absent on single-page libraries
    }

    /// The Windows games on one library page, and how many pages there are. Films, soundtracks and titles GOG
    /// marks as not running on Windows are left out; `mac` says whether GOG also sells a Mac version.
    static func products(_ data: Data) throws -> (games: [(id: String, title: String, mac: Bool)], totalPages: Int) {
        let page = try JSONDecoder().decode(LibraryPage.self, from: data)
        var games: [(id: String, title: String, mac: Bool)] = []
        for product in page.products {
            if product.isGame == false || product.worksOn?.windows == false { continue }
            games.append((id: String(product.id), title: product.title, mac: product.worksOn?.mac ?? false))
        }
        return (games: games, totalPages: page.totalPages ?? 1)
    }

    // MARK: Artwork

    /// Pictures for one game. Cached in `gog/artwork.json`, so the property names are the file's keys.
    public struct Artwork: Sendable, Equatable, Codable {
        public var cover, background, logo: URL?
    }

    /// Reads a `gamesdb.gog.com/platforms/gog/external_releases/<id>` answer. Its image links are templates with
    /// `{formatter}` (a size suffix we don't need) and `{ext}` placeholders. Anything unreadable gives no art.
    static func artwork(_ json: Data) -> Artwork {
        struct Picture: Decodable { let url_format: String? }
        struct Pictures: Decodable { let vertical_cover, background, logo: Picture? }
        struct Release: Decodable { let game: Pictures? }

        func link(_ picture: Picture?) -> URL? {
            guard var text = picture?.url_format else { return nil }
            text = text.replacingOccurrences(of: "{formatter}", with: "")
            text = text.replacingOccurrences(of: "{ext}", with: "jpg")
            return URL(string: text)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: json), let pictures = release.game else {
            return Artwork()
        }
        return Artwork(cover: link(pictures.vertical_cover), background: link(pictures.background), logo: link(pictures.logo))
    }

    // MARK: gogdl

    /// What `gogdl auth` prints: a fresh access token, or `{"error": true}` when GOG wants a new sign-in.
    struct Token: Decodable {
        let accessToken: String?
        let userID: String?
        let error: Bool?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", userID = "user_id", error }
    }

    /// A usable token, or nil when gogdl reported an error or printed something else.
    static func credentials(_ data: Data) -> Token? {
        guard let token = try? JSONDecoder().decode(Token.self, from: data) else { return nil }
        if token.error == true || token.accessToken == nil { return nil }
        return token
    }

    /// The fraction done from a gogdl download line such as
    /// `[PROGRESS] INFO: = Progress: 12.34 1048576/8388608, Running for 00:00:10, ETA: ...`.
    public static func progress(from output: String) -> Double? {
        let marker = "= Progress: "
        guard let found = output.range(of: marker) else { return nil }
        let digits = output[found.upperBound...].prefix { "0123456789.".contains($0) }
        guard let percent = Double(digits) else { return nil }
        return max(0, min(percent / 100, 1))
    }

    // MARK: goggame-<id>.info

    /// How to start the game: an executable (a Windows path relative to the install folder) with its arguments.
    public struct PlayTask: Sendable, Equatable {
        public var path: String                 // relative to the install folder, Windows separators
        public var arguments: [String]          // already split like a Windows command line
        public var workingDirectory: String?    // relative too; nil means the executable's folder
    }

    private struct PlayTasks: Decodable {
        struct Entry: Decodable {
            let isPrimary: Bool?, category: String?
            let type, path, arguments, workingDir: String?
        }
        let playTasks: [Entry]?   // missing in some DLC info files
    }

    /// The Galaxy client id, which GOG files the game's cloud-save configuration under.
    public static func clientID(infoJSON: Data) -> String? {
        struct Client: Decodable { let clientId: String? }
        return (try? JSONDecoder().decode(Client.self, from: infoJSON))?.clientId
    }

    /// The task GOG marks primary (or the first runnable one). Some games make that a launcher the game can do
    /// without, such as Mafia: Definitive Edition's .NET launcher, which needs Mono the environment doesn't have; the
    /// task in the `game` category then starts the game directly. Link tasks (web pages) never count.
    public static func playTask(infoJSON info: Data) -> PlayTask? {
        guard let all = (try? JSONDecoder().decode(PlayTasks.self, from: info))?.playTasks else { return nil }
        let runnable = all.filter { $0.path != nil && ($0.type == nil || $0.type == "FileTask") }
        guard var chosen = runnable.first(where: { $0.isPrimary == true }) ?? runnable.first else { return nil }
        if chosen.category == "launcher", let direct = runnable.first(where: { $0.category == "game" }) {
            chosen = direct
        }
        guard let path = chosen.path else { return nil }
        let folder = chosen.workingDir ?? ""
        return PlayTask(path: path,
                        arguments: LaunchProfile.parseArguments(chosen.arguments ?? ""),
                        workingDirectory: folder.isEmpty ? nil : folder)
    }
}

/// The GOG games Sommelier installed, by product id. gogdl keeps no such list itself, so this is saved as
/// `gog/installed.json` (the property names are its keys).
public struct GOGInstalled: Sendable, Equatable, Codable {
    /// One installed game: the title at install time and its folder.
    public struct Entry: Sendable, Equatable, Codable {
        public var title: String   // shown until the next library refresh renames it
        public var path: URL       // the folder holding goggame-<id>.info
    }

    public var games = [String: Entry]()

    public init() {}
}
