// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Games with anti-cheat, from "Are We Anti-Cheat Yet?" (https://areweanticheatyet.com, MIT License), which
/// tracks whether each game's anti-cheat runs under Wine/Proton on Linux.
///
/// For a Mac that is an upper bound: the developers who allow Wine allow it for Linux and Steam Deck only, so
/// even a game that runs there keeps its online play closed here (Fall Guys runs on Steam Deck, not on a Mac).
/// It covers games Valve's Steam Deck results can't: those not on Steam, like Fortnite or Fall Guys.
public enum AntiCheat {
    public enum Status: String, Codable, Sendable {
        /// The developers allow it under Wine/Proton (on Linux).
        case supported = "Supported"
        /// It runs under Wine/Proton on Linux without the developers' word.
        case running = "Running"
        /// Planned for Linux.
        case planned = "Planned"
        /// It doesn't work under Wine/Proton.
        case broken = "Broken"
        /// The developers refuse Wine/Proton.
        case denied = "Denied"

        /// Doesn't even run on Linux; on a Mac then neither.
        public var blocksEverywhere: Bool { self == .broken || self == .denied || self == .planned }
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let status: Status
        public let anticheats: [String]
        public let steamAppID: String?

        /// Whether the anti-cheat keeps the game's online play closed on a Mac. The list only speaks for online play:
        /// GTA V is "Denied" for GTA Online, while its story mode runs under Wine.
        public var blocksOnlinePlayOnMac: Bool {
            if status.blocksEverywhere { return true }
            // Wine support for these two needs their Linux runtime, which Proton brings and a Mac doesn't have.
            // VAC and the like run under Wine on a Mac as on Linux.
            return anticheats.contains { $0 == "Easy Anti-Cheat" || $0 == "BattlEye" }
        }
    }

    /// The URL of the list (`games.json` in the project's repository).
    public static let sourceURL = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/master/games.json")!

    public static func parse(_ data: Data) throws -> [Entry] {
        struct Game: Decodable {
            struct StoreIDs: Decodable { let steam: String? }
            let name: String
            let status: String
            let anticheats: [String]?
            let native: Bool?
            let storeIds: StoreIDs?
        }
        return try JSONDecoder().decode([Game].self, from: data).compactMap { game in
            guard game.native != true, let status = Status(rawValue: game.status) else { return nil }
            return Entry(name: game.name, status: status, anticheats: game.anticheats ?? [], steamAppID: game.storeIds?.steam)
        }
    }

    /// Looks games up by Steam app ID. Games with none (not on Steam, like Fortnite) go by title: the whole title,
    /// or the part before a colon ("Fall Guys: Ultimate Knockout" is "Fall Guys" on Epic). A game with a Steam ID
    /// never goes by title: "Dying Light" would match "Dying Light: Bad Blood", another game.
    public struct Index: Sendable {
        let bySteamID: [String: Entry]
        let byTitle: [String: Entry]

        public init(_ entries: [Entry]) {
            bySteamID = Dictionary(entries.compactMap { e in e.steamAppID.map { ($0, e) } }, uniquingKeysWith: { a, _ in a })
            var titles: [String: Entry] = [:]
            for entry in entries {
                // Variants like "Rocket League (FACEIT)" are other services' anti-cheat, not the game's own.
                guard !entry.name.contains("(") else { continue }
                let short = entry.name.split(separator: ":").first.map(String.init) ?? entry.name
                for title in [entry.name, short] {
                    let key = GameInfoService.normalized(title)
                    if !key.isEmpty, titles[key] == nil { titles[key] = entry }
                }
            }
            byTitle = titles
        }

        public func entry(steamAppID: String?, title: String) -> Entry? {
            if let id = steamAppID { return bySteamID[id] }
            return byTitle[GameInfoService.normalized(title)]
        }
    }
}

/// The anti-cheat list, downloaded at most once a week and kept on disk. Nothing about the user is sent.
public struct AntiCheatStore: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    var file: URL { paths.home.appendingPathComponent("AntiCheat.json") }

    /// What's on disk, without the network.
    public func cached() -> [AntiCheat.Entry] {
        (try? Data(contentsOf: file)).flatMap { try? AntiCheat.parse($0) } ?? []
    }

    /// A fresh copy when the one on disk is a week old (or missing); the old one when offline.
    public func load(session: URLSession = .shared) async -> [AntiCheat.Entry] {
        let age = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 7 * 24 * 3600 else { return cached() }
        guard let (data, response) = try? await session.data(from: AntiCheat.sourceURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? AntiCheat.parse(data), !entries.isEmpty else { return cached() }
        try? FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return entries
    }
}
