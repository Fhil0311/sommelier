// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The games in the signed-in EA account, as the EA app sees them. The app keeps its library in encrypted caches,
/// but it logs one line per game it owns each time it loads the library:
///
///     IS update: set installInfo for softwareId=[Origin.SFT.50.0000848] baseSlug=[apex-legends] installedStatus=[NotInstalled]
///
/// Names and artwork for each slug come from EA's public game service (the one ea.com uses), without an account.
/// What has been seen is kept in the bottle, because the EA app rotates its logs.
public enum EALibrary {
    public struct Entry: Codable, Equatable, Sendable {
        public var slug: String
        public var softwareIDs: [String]
        public var status: String?
        public var name: String?
        public var cover: URL?
        public var hero: URL?

        public init(slug: String, softwareIDs: [String], status: String? = nil, name: String? = nil, cover: URL? = nil, hero: URL? = nil) {
            self.slug = slug; self.softwareIDs = softwareIDs; self.status = status; self.name = name; self.cover = cover; self.hero = hero
        }
    }

    /// Internal code names the EA app logs for games whose public page has another slug.
    static let publicSlugs = ["glacier": "battlefield-6"]

    /// Owned games in the order the log names them, with the latest status of each.
    static func parseLog(_ text: String) -> [Entry] {
        var order: [String] = []
        var bySlug: [String: Entry] = [:]
        for line in text.split(whereSeparator: \.isNewline) where line.contains("IS update: set installInfo for softwareId=[") {
            guard let software = field(line, "softwareId"), let slug = field(line, "baseSlug"), !slug.isEmpty else { continue }
            let status = field(line, "installedStatus")
            if bySlug[slug] == nil { order.append(slug); bySlug[slug] = Entry(slug: slug, softwareIDs: []) }
            if !bySlug[slug]!.softwareIDs.contains(software) { bySlug[slug]!.softwareIDs.append(software) }
            if let status { bySlug[slug]!.status = status }
        }
        return order.compactMap { bySlug[$0] }
    }

    private static func field(_ line: Substring, _ name: String) -> String? {
        guard let start = line.range(of: "\(name)=["), let end = line[start.upperBound...].firstIndex(of: "]") else { return nil }
        return String(line[start.upperBound..<end])
    }

    static func logsFolder(in bottle: Bottle) -> URL {
        bottle.driveC.appendingPathComponent("ProgramData/EA Desktop/Logs")
    }

    static func cacheFile(in bottle: Bottle) -> URL { bottle.url.appendingPathComponent("sommelier-ea-library.json") }

    /// What the account owns: the saved list updated from the EA app's current logs.
    public static func owned(in bottle: Bottle) -> [Entry] {
        var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: cacheFile(in: bottle)))) ?? []
        if let text = try? String(contentsOf: logsFolder(in: bottle).appendingPathComponent("EADesktop.log"), encoding: .utf8) {
            entries = merged(entries, with: parseLog(text))
        }
        return entries
    }

    static func merged(_ saved: [Entry], with fresh: [Entry]) -> [Entry] {
        var result = saved
        for entry in fresh {
            if let i = result.firstIndex(where: { $0.slug == entry.slug }) {
                result[i].softwareIDs = Array(Set(result[i].softwareIDs + entry.softwareIDs)).sorted()
                if entry.status != nil { result[i].status = entry.status }
            } else {
                result.append(entry)
            }
        }
        return result
    }

    /// Fills in names and artwork that are still missing, then saves the list.
    public static func resolve(_ entries: [Entry], in bottle: Bottle, session: URLSession = .shared) async -> [Entry] {
        var result = entries
        for i in result.indices where result[i].name == nil {
            guard let info = await publicInfo(slug: result[i].slug, session: session) else { continue }
            result[i].name = info.name
            result[i].cover = info.cover
            result[i].hero = info.hero
        }
        // Saved only when something changed: the bottle is watched, and a write would start another refresh.
        let file = cacheFile(in: bottle)
        if let data = try? JSONEncoder().encode(result), data != (try? Data(contentsOf: file)) {
            try? data.write(to: file, options: .atomic)
        }
        return result
    }

    struct PublicInfo: Equatable { var name: String; var cover: URL?; var hero: URL? }

    static func publicInfo(slug: String, session: URLSession) async -> PublicInfo? {
        let slug = publicSlugs[slug] ?? slug
        guard let url = URL(string: "https://drop-api.ea.com/game/\(slug)?locale=en"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parsePublicInfo(data)
    }

    static func parsePublicInfo(_ data: Data) -> PublicInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else { return nil }
        func image(_ key: String, _ ratio: String) -> URL? {
            ((json[key] as? [String: Any])?[ratio] as? String).flatMap(URL.init(string:))
        }
        return PublicInfo(name: name, cover: image("packArt", "ar2X3") ?? image("packArt", "ar3X4"),
                          hero: image("heroImage", "ar16X9") ?? image("packArt", "ar16X9"))
    }

    /// Statuses the EA app logs while a game is on its way (its folder exists long before it can be played).
    static let downloadStatuses: Set<String> = ["Queued", "Active", "Paused", "Canceling", "Pending", "Preparing",
                                                "Downloading", "Installing", "Verifying"]

    /// The download the EA app is running or holding for each game, keyed by slug. The EA app downloads one game at
    /// a time and shows its progress on the taskbar; that percentage belongs to the active or paused game.
    public static func downloads(owned: [Entry], taskbar: (percent: Int, paused: Bool)?) -> [String: LauncherDownload] {
        var result: [String: LauncherDownload] = [:]
        for entry in owned {
            let fraction = taskbar.map { Double(min(max($0.percent, 0), 100)) / 100 }
            switch entry.status {
            case "Queued", "Pending": result[entry.slug] = LauncherDownload(phase: .queued)
            case "Paused": result[entry.slug] = LauncherDownload(phase: .paused, fraction: fraction)
            case "Active", "Preparing", "Downloading", "Installing", "Verifying":
                result[entry.slug] = LauncherDownload(phase: taskbar?.paused == true ? .paused : .downloading, fraction: fraction)
            default: break
            }
        }
        return result
    }

    /// The last taskbar progress the EA app logged (`progress: value=2, range=[0, 100], paused=false, visible=true`),
    /// read from the end of its verbose log; nil when the bar is hidden.
    public static func taskbarProgress(in bottle: Bottle) -> (percent: Int, paused: Bool)? {
        let log = logsFolder(in: bottle).appendingPathComponent("EADesktopVerbose.log")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        return parseTaskbarProgress(String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self))
    }

    static func parseTaskbarProgress(_ text: String) -> (percent: Int, paused: Bool)? {
        guard let range = text.range(of: "updateTaskbar)\tprogress: value=", options: .backwards) else { return nil }
        let line = text[range.upperBound...].prefix { !$0.isNewline }
        guard !line.contains("visible=false"), let value = Int(line.prefix { $0.isNumber }) else { return nil }
        return (value, line.contains("paused=true"))
    }

    /// Installed games (from their folders) plus the rest of what the account owns. An installed game takes the
    /// owned entry's name and artwork when its content ID is one of the entry's software IDs or the names match.
    public static func library(installed: [Game], owned: [Entry]) -> [Game] {
        var remaining = owned
        var games = installed.map { game -> Game in
            guard let i = remaining.firstIndex(where: { $0.softwareIDs.contains(game.storeID) || simplified($0.name ?? $0.slug) == simplified(game.title) })
            else { return game }
            let entry = remaining.remove(at: i)
            if let status = entry.status, downloadStatuses.contains(status) {
                return Game(store: .ea, storeID: entry.slug, title: entry.name ?? game.title, isInstalled: false,
                            coverURL: entry.cover, heroURL: entry.hero)        // still downloading: not playable yet
            }
            var game = game
            if let name = entry.name { game.title = name }
            game.coverURL = entry.cover ?? game.coverURL
            game.heroURL = entry.hero ?? game.heroURL
            return game
        }
        for entry in remaining {
            games.append(Game(store: .ea, storeID: entry.slug, title: entry.name ?? entry.slug, isInstalled: false,
                              coverURL: entry.cover, heroURL: entry.hero))
        }
        return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func simplified(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
