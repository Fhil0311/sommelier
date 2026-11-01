// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where games keep their saves, from the service (`GET /v1/saves.json`, built by server/saves/from-ludusavi.py):
/// `{ "version": 1, "games": { "steam:292030": [{ "root": "documents", "path": "The Witcher 3/gamesaves/*.sav" }] } }`.
/// Keys are `steam:<id>`, `gog:<id>` and `title:<letters and digits of the title>`. A path may hold `*`, and may
/// end in files: `folders` turns it into the save folders that exist.
public struct SaveLocationsList: Decodable, Sendable {
    public struct Place: Decodable, Equatable, Sendable {
        public var root: SaveRoot
        public var path: String
        /// Ludusavi's store names (steam, gog, epic, ea, origin, uplay) when the place is only for some.
        public var stores: [String]?
    }
    public var version: Int
    public var games: [String: [Place]]

    private enum Keys: String, CodingKey { case version, games }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .version)
        // A root this app doesn't know drops that place, not the list.
        struct Lenient: Decodable {
            let place: Place?
            init(from decoder: Decoder) throws { place = try? Place(from: decoder) }
        }
        games = try c.decode([String: [Lenient]].self, forKey: .games).mapValues { $0.compactMap(\.place) }
    }

    /// The places for a game: by its store id, else by its title.
    public func places(for game: Game) -> [Place] {
        let store = game.store.rawValue
        let found = games["\(store):\(game.storeID)"] ?? games["title:" + SaveLocator.normalize(game.title)] ?? []
        let names: Set<String> = switch game.store {
        case .ea: ["ea", "origin"]
        case .ubisoft: ["uplay"]
        default: [store]
        }
        return found.filter { $0.stores.map { !names.isDisjoint(with: $0) } ?? true }
    }
}

extension SaveLocationsList: VersionedList {}

public extension SaveLocationsList.Place {
    /// The folders on disk this place names. A step with `*` matches names in that folder; a path that ends in
    /// files gives the folder holding them. Never the root itself or the game's whole folder, no links, and
    /// nothing bigger than `largest` (a cache, not saves).
    func folders(in roots: SaveRoots, largest: Int64 = 512 * 1024 * 1024) -> [SaveSource] {
        guard let top = roots.resolvedBase(root) else { return [] }
        let steps = path.split(separator: "/").map(String.init)
        guard !steps.isEmpty, !steps.contains(where: { $0 == "." || $0 == ".." }) else { return [] }
        var found: [[String]] = []
        func walk(_ url: URL, _ done: [String], _ rest: ArraySlice<String>) {
            guard let step = rest.first else { found.append(done); return }
            let names: [String]
            if step.contains("*") || step.contains("?") {
                let all = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                names = all.filter { fnmatch(step.lowercased(), $0.lowercased(), 0) == 0 }.sorted().prefix(50).map { $0 }
            } else { names = [step] }
            for name in names {
                let next = url.appendingPathComponent(name)
                guard !FileScan.isSymlink(next) else { continue }
                if FileScan.isDirectory(next) { walk(next, done + [name], rest.dropFirst()) }
                else if FileScan.isRegularFile(next) { found.append(done) }       // a file: its folder holds the save
            }
        }
        walk(top, [], steps[...])
        var result: [SaveSource] = []
        for parts in found where !parts.isEmpty {        // files right in the root: never the whole folder (or game)
            let source = SaveSource(root: root, path: parts.joined(separator: "/"))
            guard SaveSource.isSafe(source.path), let url = roots.resolve(source), !result.contains(source),
                  FileScan.measure(url).bytes <= largest else { continue }
            result.append(source)
        }
        return result
    }
}

/// Keeps the save locations list on disk (`SaveLocations.json`), refreshed at most once a day.
public struct SaveLocationsService: Sendable {
    let list: OnlineList<SaveLocationsList>
    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        list = OnlineList(path: "v1/saves.json", file: paths.home.appendingPathComponent("SaveLocations.json"),
                          baseURL: baseURL, session: session, signed: true)
    }
    public func cached() -> SaveLocationsList? { list.cached() }
    @discardableResult public func refresh(now: Date = Date()) async -> SaveLocationsList? { await list.refresh(now: now) }
}
