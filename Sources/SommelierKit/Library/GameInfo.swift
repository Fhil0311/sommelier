// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's store-page facts for the game page: description, credits, genres, media, Steam Deck result.
/// Cached on disk as JSON; the property names are its keys, and the cache keeps them in declaration order.
public struct GameInfo: Equatable, Codable, Sendable {
    /// Ways to play, from Steam's store categories.
    public enum PlayerMode: String, CaseIterable, Codable, Sendable {
        case single
        case multi
        case coop
        case online

        public var displayName: String {
            switch self {
            case .single: return "Single-player"
            case .multi: return "Multiplayer"
            case .coop: return "Co-op"
            case .online: return "Online"
            }
        }
    }

    /// The Steam app the facts came from (nil when no Steam page matched), and its short description.
    public var steamAppID, summary: String?
    public var developers = [String](), publishers = [String]()
    public var releaseDate: String?, genres = [String]()
    public var players = [PlayerMode]()
    /// Steam's word for controller support ("full" or "partial"), and the Metacritic score.
    public var controllerSupport: String?, metacritic: Int?
    public var screenshots = [URL]()

    /// The store's main trailer (HLS stream or MP4) and its still image.
    public var trailerURL, trailerThumbnail: URL?
    /// Set once the page has been read for a trailer. Older caches lack it and get refreshed, showing the old copy
    /// meanwhile; optional so they still load.
    public var trailerChecked: Bool?

    /// DirectX version from Steam's minimum requirements (12: the game needs Direct3D 12), 0 when unknown.
    /// Deliberately not optional: a cache from before it existed fails to load and is fetched again.
    public var minimumDirectX: Int = 0

    /// Steam artwork used where the game's own store has none: transparent title art (`logo.png`), wide art
    /// (`library_hero.jpg`) and box art (`library_600x900.jpg`).
    public var logoURL, heroURL, coverURL: URL?

    /// Valve's Steam Deck result for the Steam version of a game from another store (Steam games read theirs from
    /// Steam's cache). Nil when Valve hasn't rated it.
    public var deck: DeckCompatibility?
    /// Whether `deck` has been looked up; optional so caches from before it still load.
    public var deckChecked: Bool?

    /// When this was read from the store.
    public var fetched: Date = .now

    public init() {}
}

/// Gets `GameInfo` from Steam's public store API and keeps it on disk, one file per game and language.
/// Games from other stores borrow the Steam page whose title matches theirs exactly; without a match they show
/// only what their own store provides. Requests carry game titles and Steam app ids, nothing about the player.
public actor GameInfoService {
    /// How long a cache entry is trusted.
    private static let freshFor: TimeInterval = 30 * 86_400
    /// How soon a game from another store that found no Steam match (or met no answer) tries again.
    private static let emptyRetryAfter: TimeInterval = 6 * 3_600

    /// Steam's name for the store language descriptions and genres come in.
    let language: String
    private let folder: URL, network: URLSession
    private var loaded: [String: GameInfo] = [:]

    public init(
        paths: Paths, session: URLSession = .shared,
        language: String = steamLanguage(for: Bundle.main.preferredLocalizations.first ?? "en")
    ) {
        (self.language, network) = (language, session)
        folder = paths.home.appendingPathComponent("GameInfo", isDirectory: true)
    }

    /// What's cached for the game, however old, without going to the network.
    public func cached(for item: Game) -> GameInfo? {
        if let known = loaded[item.id] { return known }
        guard let bytes = try? Data(contentsOf: cacheFile(for: item)),
              let known = try? Self.cacheDecoder.decode(GameInfo.self, from: bytes) else { return nil }
        loaded[item.id] = known
        return known
    }

    /// The game's info: the cache while it's fresh, otherwise fetched again. When the store can't be reached the
    /// cache is kept, however old.
    public func info(for item: Game) async -> GameInfo? {
        if let known = cached(for: item), isFresh(known, for: item) {
            return await withDeckResult(known, for: item)
        }
        let fetched: GameInfo?
        do {
            fetched = try await fetch(for: item)
        } catch {
            return cached(for: item)
        }
        var fresh = fetched ?? GameInfo()
        fresh.fetched = .now
        store(fresh, for: item)
        return fresh
    }

    /// A cache entry is fresh within its age limit and once it's been checked for a trailer. An empty entry for a
    /// game from another store has a much shorter limit than a month.
    private func isFresh(_ info: GameInfo, for game: Game) -> Bool {
        let foundNothing = game.store != .steam && info.steamAppID == nil && info.summary == nil
        let limit = foundNothing ? Self.emptyRetryAfter : Self.freshFor
        guard Date().timeIntervalSince(info.fetched) < limit else { return false }
        return info.steamAppID == nil || info.trailerChecked == true
    }

    /// Adds the Steam Deck result to a fresh cache entry that predates it (games from other stores only).
    /// Failing to get it now just leaves the entry as it was.
    private func withDeckResult(_ info: GameInfo, for game: Game) async -> GameInfo {
        guard game.store != .steam, info.deckChecked != true, let appID = info.steamAppID,
              let report = try? await deckReport(appID: appID) else { return info }
        var updated = info
        updated.deck = report.category > 0 ? report : nil
        updated.deckChecked = true
        store(updated, for: game)
        return updated
    }

    /// Fresh info from Steam; nil when there's no matching Steam page or the store has no details for it.
    private func fetch(for game: Game) async throws -> GameInfo? {
        let isSteam = game.store == .steam
        guard let appID = isSteam ? game.storeID : try await steamAppID(matching: game.title),
              var info = try await details(appID: appID) else { return isSteam ? nil : Self.builtIn(for: game) }
        if !isSteam {
            let report = try await deckReport(appID: appID)
            info.deck = report.category > 0 ? report : nil
            info.deckChecked = true
        }
        return info
    }

    /// Facts for Blizzard games Steam has no page for (Hearthstone, World of Warcraft, StarCraft…), by Battle.net's
    /// product code.
    static func builtIn(for game: Game) -> GameInfo? {
        guard game.store == .battlenet, let facts = blizzardFacts[game.storeID] else { return nil }
        var info = GameInfo()
        info.summary = facts.summary
        info.developers = ["Blizzard Entertainment"]
        info.publishers = ["Blizzard Entertainment"]
        info.releaseDate = facts.released
        info.genres = facts.genres
        info.players = facts.players
        return info
    }

    private static let blizzardFacts: [String: (summary: String, released: String, genres: [String], players: [GameInfo.PlayerMode])] = [
        "WTCG": ("A fast collectible card game set in the Warcraft universe. Pick a hero, build a deck and duel players from around the world.",
                 "Mar 11, 2014", ["Card Game", "Strategy", "Free to Play"], [.multi, .online]),
        "WoW": ("The long-running online role-playing game of Azeroth: quest, explore, raid dungeons and team up with other players.",
                "Nov 23, 2004", ["RPG", "MMO"], [.multi, .coop, .online]),
        "D3": ("Slay demons and collect loot in a dark action role-playing game, alone or with up to three friends.",
               "May 15, 2012", ["Action", "RPG"], [.single, .multi, .coop, .online]),
        "OSI": ("The classic action role-playing game rebuilt with modern graphics: fight through Sanctuary and take down Diablo.",
                "Sep 23, 2021", ["Action", "RPG"], [.single, .multi, .coop, .online]),
        "ANBS": ("A free action role-playing game between Diablo II and Diablo III: hunt demons and collect gear in Sanctuary.",
                 "Jun 2, 2022", ["Action", "RPG", "Free to Play"], [.multi, .coop, .online]),
        "Fen": ("The return of Sanctuary's darkest chapter: an action role-playing game with a shared open world.",
                "Jun 5, 2023", ["Action", "RPG"], [.single, .multi, .coop, .online]),
        "S2": ("The real-time strategy classic: lead the Terran, Zerg or Protoss in campaign missions and online matches.",
               "Jul 27, 2010", ["Strategy"], [.single, .multi, .online]),
        "S1": ("The original real-time strategy game, restored for modern screens with its campaigns and online play.",
               "Aug 14, 2017", ["Strategy"], [.single, .multi, .online]),
        "Hero": ("A team brawler where heroes from Blizzard's games fight across different battlegrounds.",
                 "Jun 2, 2015", ["Action", "Strategy", "Free to Play"], [.multi, .online]),
        "W3": ("The real-time strategy classic with its campaigns and custom games, rebuilt for modern screens.",
               "Jan 28, 2020", ["Strategy"], [.single, .multi, .online]),
        "Pro": ("A team shooter of heroes with unique abilities: pick a role and fight for the objective.",
                "Oct 4, 2022", ["Action", "Shooter", "Free to Play"], [.multi, .online]),
    ]

    private func store(_ info: GameInfo, for game: Game) {
        loaded[game.id] = info
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? Self.cacheEncoder.encode(info) else { return }
        try? data.write(to: cacheFile(for: game), options: .atomic)
    }

    /// `GameInfo/<store>-<id>.json` for English, `…-<language>.json` for others, so changing the app's language
    /// fetches descriptions in the new one.
    private func cacheFile(for game: Game) -> URL {
        var name = game.id.replacingOccurrences(of: ":", with: "-")
        if language != "english" { name += "-" + language }
        return folder.appendingPathComponent(name + ".json")
    }

    // MARK: Steam store

    private static func storeURL(_ path: String, _ query: [(String, String)]) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "store.steampowered.com"
        parts.path = path
        parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = parts.url else { throw URLError(.badURL) }
        return url
    }

    /// The Steam Deck result the store shows on a game's page.
    func deckReport(appID: String) async throws -> DeckCompatibility {
        let url = try Self.storeURL("/saleaction/ajaxgetdeckappcompatibilityreport", [("nAppID", appID)])
        return try Self.parseDeckReport(try await network.data(from: url).0)
    }

    /// The Steam app whose name matches `title` exactly (after `normalized`), from the store's search.
    func steamAppID(matching name: String) async throws -> String? {
        struct Results: Decodable {
            struct Hit: Decodable { let id: Int; let name: String }
            let items: [Hit]
        }
        let url = try Self.storeURL("/api/storesearch/", [("term", name), ("cc", "us"), ("l", "en")])
        let hits = try JSONDecoder().decode(Results.self, from: try await network.data(from: url).0).items
        let key = Self.normalized(name)
        guard let hit = hits.first(where: { Self.normalized($0.name) == key }) else { return nil }
        return String(hit.id)
    }

    /// The app's store details in the player's language. Where the store doesn't sell a game it answers
    /// `success: false`, so the US store is asked next; it still answers in the player's language.
    func details(appID id: String) async throws -> GameInfo? {
        let regions: [[(String, String)]] = [[], [("cc", "us")]]
        for region in regions {
            let url = try Self.storeURL("/api/appdetails", [("appids", id), ("l", language)] + region)
            if let found = try Self.parseDetails(try await network.data(from: url).0, appID: id) { return found }
        }
        return nil
    }

    /// Reads the deck report: `{"results": {"resolved_category": 3, "resolved_items": [{"loc_token": "…"}]}}`.
    /// Category 0 means Valve hasn't tested the game.
    static func parseDeckReport(_ data: Data) throws -> DeckCompatibility {
        struct Answer: Decodable {
            struct Body: Decodable {
                struct Note: Decodable {
                    let token: String?
                    enum CodingKeys: String, CodingKey { case token = "loc_token" }
                }
                let category: Int?
                let notes: [Note]?
                enum CodingKeys: String, CodingKey { case category = "resolved_category", notes = "resolved_items" }
            }
            let results: Body?
        }
        let body = try JSONDecoder().decode(Answer.self, from: data).results
        let tokens = body?.notes?.compactMap(\.token) ?? []
        return DeckCompatibility(category: body?.category ?? 0, tokens: tokens)
    }

    /// The shape of an `appdetails` answer, as far as Sommelier reads it.
    private struct AppDetails: Decodable {
        struct Label: Decodable {
            let id: NumericID?
            let description: String
        }
        struct Release: Decodable { var date: String? }
        struct Score: Decodable { let score: Int? }
        struct Screenshot: Decodable {
            let url: String
            enum CodingKeys: String, CodingKey { case url = "path_full" }
        }
        /// Newer answers carry an HLS stream (`hls_h264`), older ones MP4 files (`mp4.max`).
        struct Movie: Decodable {
            struct Files: Decodable { let max: String? }
            let thumbnail: String?
            let highlight: Bool?
            let stream: String?
            let mp4: Files?
            enum CodingKeys: String, CodingKey { case thumbnail, highlight, mp4, stream = "hls_h264" }
        }
        /// An object with `minimum` and `recommended` HTML, or an empty array when the game lists none.
        struct Requirements: Decodable {
            let minimum: String?
            init(from source: Decoder) throws {
                enum Field: String, CodingKey { case minimum }
                let fields = try? source.container(keyedBy: Field.self)
                minimum = (try? fields?.decodeIfPresent(String.self, forKey: .minimum)) ?? nil
            }
        }

        let summary: String?
        let developers, publishers: [String]?
        let release: Release?
        let genres, categories: [Label]?
        let controller: String?
        let metacritic: Score?
        let screenshots: [Screenshot]?
        let movies: [Movie]?
        let requirements: Requirements?

        private enum CodingKeys: String, CodingKey {
            case developers, publishers, genres, categories, metacritic, screenshots, movies
            case summary = "short_description", release = "release_date", controller = "controller_support"
            case requirements = "pc_requirements"
        }
    }

    /// Turns an `appdetails` answer into `GameInfo`; nil when the store says it has nothing for the app.
    static func parseDetails(_ answer: Data, appID id: String) throws -> GameInfo? {
        struct Wrapper: Decodable { let success: Bool; let data: AppDetails? }
        let byApp = try JSONDecoder().decode([String: Wrapper].self, from: answer)
        guard let wrapper = byApp[id], wrapper.success, let app = wrapper.data else { return nil }

        var facts = GameInfo()
        facts.steamAppID = id
        facts.summary = app.summary.map(plainText).flatMap(nonEmpty)
        facts.developers = app.developers ?? []
        facts.publishers = app.publishers ?? []
        facts.releaseDate = app.release?.date.flatMap(nonEmpty)
        facts.genres = app.genres?.map(\.description) ?? []
        facts.players = playerModes(categories: Set(app.categories?.compactMap { $0.id?.value } ?? []))
        facts.controllerSupport = app.controller
        facts.metacritic = app.metacritic?.score
        facts.screenshots = app.screenshots?.prefix(8).compactMap { URL(string: $0.url) } ?? []
        facts.trailerChecked = true
        if let movie = app.movies?.first(where: { $0.highlight == true }) ?? app.movies?.first {
            facts.trailerURL = (movie.stream ?? movie.mp4?.max).flatMap { URL(string: $0) }
            facts.trailerThumbnail = movie.thumbnail.flatMap { URL(string: $0) }
        }
        facts.minimumDirectX = app.requirements?.minimum.map { directXVersion(in: $0) } ?? 0
        facts.logoURL = SteamLibrary.artworkURL(appID: id, "logo.png")
        facts.heroURL = SteamLibrary.artworkURL(appID: id, "library_hero.jpg")
        facts.coverURL = SteamLibrary.artworkURL(appID: id, "library_600x900.jpg")
        return facts
    }

    /// Steam category ids → ways to play. 2 is single-player; 1 and 49 multiplayer (49: PvP); 9, 38 and 39 co-op
    /// (38: online co-op, 39: shared screen); 36 and 38 online.
    private static func playerModes(categories ids: Set<Int>) -> [GameInfo.PlayerMode] {
        let rules: [(GameInfo.PlayerMode, Set<Int>)] = [
            (.single, [2]), (.multi, [1, 49]), (.coop, [9, 38, 39]), (.online, [36, 38]),
        ]
        return rules.filter { !$0.1.isDisjoint(with: ids) }.map(\.0)
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// Category and genre ids come as numbers (categories) or as numeric strings (genres); anything else is -1.
    struct NumericID: Decodable {
        let value: Int
        init(from source: Decoder) throws {
            let single = try source.singleValueContainer()
            if let number = try? single.decode(Int.self) {
                value = number
            } else {
                value = Int(try single.decode(String.self)) ?? -1
            }
        }
    }

    // MARK: Text

    /// "DirectX", an optional colon (either width), then up to 24 non-digits in whatever language, then the number.
    private static let directXPattern = try? NSRegularExpression(pattern: #"DirectX\s*[:：]?\s*[^0-9\n]{0,24}?(\d{1,2})"#)

    /// The DirectX version named in a requirements block in any store language ("DirectX: Version 12",
    /// "DirectX: версии 12", "DirectX 版本： 12"); 0 when there's none.
    static func directXVersion(in html: String) -> Int {
        let text = plainText(html)
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let found = directXPattern?.firstMatch(in: text, range: whole),
              let digits = Range(found.range(at: 1), in: text) else { return 0 }
        return Int(text[digits]) ?? 0
    }

    /// A title boiled down for matching across stores: lower case, "&" read as "and", and only ASCII letters and
    /// digits kept, so punctuation and ™-style marks don't stop a match.
    static func normalized(_ name: String) -> String {
        let spelled = name.lowercased().replacingOccurrences(of: "&", with: "and")
        var kept = String.UnicodeScalarView()
        for scalar in spelled.unicodeScalars where scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
            kept.append(scalar)
        }
        return String(kept)
    }

    /// Store HTML as plain text: tags dropped, the common entities decoded, ends trimmed. `&amp;` is decoded last
    /// so an escaped entity such as `&amp;lt;` comes out as the text `&lt;`.
    static func plainText(_ markup: String) -> String {
        let entities = [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")]
        let untagged = markup.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = entities.reduce(untagged) { text, entity in
            text.replacingOccurrences(of: entity.0, with: entity.1)
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Steam's name for a language ("russian", "english"…), from the app's localization code.
    public nonisolated static func steamLanguage(for code: String) -> String {
        let steamNames = [
            ("zh-Hans", "schinese"), ("zh-Hant", "tchinese"), ("ru", "russian"), ("de", "german"), ("fr", "french"),
            ("es", "spanish"), ("it", "italian"), ("ja", "japanese"), ("ko", "koreana"), ("pl", "polish"),
            ("pt", "brazilian"), ("tr", "turkish"), ("uk", "ukrainian"),
        ]
        return steamNames.first { code.hasPrefix($0.0) }?.1 ?? "english"
    }

    // Cache files: compact JSON with ISO 8601 dates.
    private static let cacheEncoder: JSONEncoder = {
        let writer = JSONEncoder()
        writer.dateEncodingStrategy = .iso8601
        return writer
    }()

    private static let cacheDecoder: JSONDecoder = {
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        return reader
    }()
}
