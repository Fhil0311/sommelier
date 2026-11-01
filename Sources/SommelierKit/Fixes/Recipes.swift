// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How a game is known to start, from the recipes list online (`GET /v1/recipes.json`): the actions that make it
/// run, as the fix rules' actions (`FixAction`). Applied before the game's first launch here when the player left
/// the graphics on Automatic, and recorded as applied fixes (`Recipe.ruleID`), so they show on the game's page and
/// can be undone.
public struct Recipe: Codable, Equatable, Sendable {
    public static let ruleID = "recipe"

    /// The game's id, "steam:1903340".
    public var game: String
    public var actions: [FixAction]
    /// How many players run it this way, for the game's page.
    public var players: Int?
    public var note: String?
    /// Where it comes from ("reports", "protonfixes", "team").
    public var source: String?

    public init(game: String, actions: [FixAction], players: Int? = nil, note: String? = nil, source: String? = nil) {
        self.game = game; self.actions = actions; self.players = players; self.note = note; self.source = source
    }

    /// The graphics backend the recipe sets, if it does.
    public var backend: GraphicsBackend? {
        for case .switchGraphics(let backend) in actions { return backend }
        return nil
    }

    private enum Keys: String, CodingKey { case game, actions, players, note, source }
    private struct Lenient: Decodable {
        let action: FixAction?
        init(from decoder: Decoder) throws { action = try? FixAction(from: decoder) }
    }

    /// An action this version doesn't know is left out; a recipe with none left is dropped by the list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        game = try c.decode(String.self, forKey: .game)
        actions = try c.decode([Lenient].self, forKey: .actions).compactMap(\.action)
        guard !actions.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .actions, in: c, debugDescription: "no known action") }
        players = try c.decodeIfPresent(Int.self, forKey: .players)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

/// `{ "version": 1, "recipes": [Recipe…] }`. A recipe this version can't read (a backend it doesn't know) is left out.
public struct RecipesList: Codable, Sendable {
    public var version: Int
    public var recipes: [Recipe]

    public init(version: Int = 1, recipes: [Recipe]) { self.version = version; self.recipes = recipes }

    private struct Lenient: Decodable {
        let recipe: Recipe?
        init(from decoder: Decoder) throws { recipe = try? Recipe(from: decoder) }
    }
    private enum Keys: String, CodingKey { case version, recipes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .version)
        recipes = try c.decode([Lenient].self, forKey: .recipes).compactMap(\.recipe)
    }

    /// By game id.
    public var byGame: [String: Recipe] { Dictionary(recipes.map { ($0.game, $0) }, uniquingKeysWith: { a, _ in a }) }
}

/// Keeps the recipes list online on disk (`Recipes.json`) and refreshes it at most once a day.
public struct RecipesService: Sendable {
    let list: OnlineList<RecipesList>

    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        list = OnlineList(path: "v1/recipes.json", file: paths.home.appendingPathComponent("Recipes.json"), baseURL: baseURL, session: session, signed: true)
    }

    public func cached() -> [String: Recipe] { list.cached().map(\.byGame) ?? [:] }
    public func refresh(now: Date = Date()) async -> [String: Recipe] { (await list.refresh(now: now))?.byGame ?? [:] }
}

/// A JSON list the service publishes and every app reads: kept on disk, fetched again at most once a day, and
/// the saved copy when the service can't be reached. The list's `version` must be 1.
/// The games that have HDR, from players' sessions (`GET /v1/hdr.json`): `{ "version": 1, "games": ["steam:292030", …] }`.
public struct HDRGamesList: Codable, Sendable {
    public var version: Int
    public var games: [String]
}

/// Keeps the list of games with HDR on disk (`HDRGames.json`), refreshed at most once a day.
public struct HDRGamesService: Sendable {
    let list: OnlineList<HDRGamesList>
    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        list = OnlineList(path: "v1/hdr.json", file: paths.home.appendingPathComponent("HDRGames.json"), baseURL: baseURL, session: session)
    }
    public func cached() -> Set<String> { Set(list.cached()?.games ?? []) }
    public func refresh(now: Date = Date()) async -> Set<String> { Set((await list.refresh(now: now))?.games ?? []) }
}

/// Players' word on games (`GET /v1/verdicts.json`): `{ "version": 1, "games": { "steam:292030": "works", … } }`,
/// only the games it decides ("works" or "wontRun"). Read by the app to rate its whole library.
public struct CommunityVerdictsList: Codable, Sendable {
    public var version: Int
    public var games: [String: String]

    /// By game id; values the app doesn't know are left out.
    public var byGame: [String: Compatibility.Verdict] {
        games.compactMapValues { $0 == "works" ? .works : $0 == "wontRun" ? .wontRun : nil }
    }
}

/// Keeps players' word on games on disk (`Verdicts.json`), refreshed at most once a day. Until the service answers
/// (it isn't reachable, or not online yet) the saved copy is used, and without one the app rates games by itself.
public struct CommunityVerdictsService: Sendable {
    let list: OnlineList<CommunityVerdictsList>
    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        list = OnlineList(path: "v1/verdicts.json", file: paths.home.appendingPathComponent("Verdicts.json"), baseURL: baseURL, session: session)
    }
    public func cached() -> [String: Compatibility.Verdict] { list.cached()?.byGame ?? [:] }
    public func refresh(now: Date = Date()) async -> [String: Compatibility.Verdict] { (await list.refresh(now: now))?.byGame ?? [:] }
}

protocol VersionedList: Decodable, Sendable { var version: Int { get } }
extension CommunityVerdictsList: VersionedList {}
extension HDRGamesList: VersionedList {}
extension FixesList: VersionedList {}
extension RecipesList: VersionedList {}

struct OnlineList<List: VersionedList>: Sendable {
    let file: URL
    let url: URL
    let session: URLSession
    /// Lists that change what runs (fixes, recipes) must come signed (`Signature`); a list that isn't is ignored
    /// and the saved copy kept.
    var signed = false

    init(path: String, file: URL, baseURL: URL?, session: URLSession, signed: Bool = false) {
        self.signed = signed
        let override = ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:))
        url = (baseURL ?? override ?? CompatibilityReporter.defaultURL).appendingPathComponent(path)
        self.file = file; self.session = session
    }

    func cached() -> List? {
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode(List.self, from: data), list.version == 1 else { return nil }
        return list
    }

    func refresh(now: Date) async -> List? {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, now.timeIntervalSince(modified) < 86_400 { return cached() }
        // Straight from the service: the file on disk is the cache (a day), not the system's HTTP cache (an hour
        // the service allows, which would hand back a list published since).
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              !signed || Signature.accepts(data, signature: Signature.of(response)),
              let list = try? JSONDecoder().decode(List.self, from: data), list.version == 1 else { return cached() }
        try? data.write(to: file, options: .atomic)
        return list
    }
}
