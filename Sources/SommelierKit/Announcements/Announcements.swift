// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A message from the Sommelier team to players (server/api/README.md, `GET /v1/announcements.json`): shown as a
/// banner in the app until the player closes it, and, when `notify` is set, once as a macOS notification.
public struct Announcement: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable { case info, important }

    public struct Link: Codable, Equatable, Sendable {
        public var url: URL
        public var label: [String: String]?
    }

    public var id: String
    public var level: Level
    /// Texts by language code ("en" is always there).
    public var title: [String: String]
    public var body: [String: String]?
    public var link: Link?
    public var from: Date?
    public var until: Date?
    /// Only for app versions at or above `minApp`, and below `belowApp`.
    public var minApp: String?
    public var belowApp: String?
    /// Only for players who have one of these games ("steam:271590").
    public var games: [String]?
    public var notify: Bool?

    public init(id: String, level: Level = .info, title: [String: String], body: [String: String]? = nil, link: Link? = nil,
                from: Date? = nil, until: Date? = nil, minApp: String? = nil, belowApp: String? = nil, games: [String]? = nil,
                notify: Bool? = nil) {
        self.id = id; self.level = level; self.title = title; self.body = body; self.link = link; self.from = from
        self.until = until; self.minApp = minApp; self.belowApp = belowApp; self.games = games; self.notify = notify
    }

    /// The text in the first of `languages` it has (each tried whole, then without its region), else English.
    public static func text(_ texts: [String: String]?, languages: [String]) -> String? {
        guard let texts else { return nil }
        for language in languages {
            if let t = texts[language] { return t }
            if let base = language.split(separator: "-").first, let t = texts[String(base)] { return t }
        }
        return texts["en"] ?? texts.values.first
    }

    /// Whether this Sommelier should show it now.
    public func applies(now: Date, appVersion: String, games owned: Set<String>) -> Bool {
        if let from, now < from { return false }
        if let until, now >= until { return false }
        if let minApp, Self.compare(appVersion, minApp) == .orderedAscending { return false }
        if let belowApp, Self.compare(appVersion, belowApp) != .orderedAscending { return false }
        if let games, !games.isEmpty, owned.isDisjoint(with: games) { return false }
        return true
    }

    /// Compares dotted versions number by number ("0.10" is after "0.9"; missing parts count as 0).
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// The list as the service serves it. Announcements the app can't read (a newer shape) are skipped, not fatal.
public struct AnnouncementList: Decodable, Sendable {
    public var version: Int
    public var announcements: [Announcement]

    private struct Lenient: Decodable {
        let value: Announcement?
        init(from decoder: Decoder) throws { value = try? Announcement(from: decoder) }
    }

    enum CodingKeys: String, CodingKey { case version, announcements }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        announcements = try c.decode([Lenient].self, forKey: .announcements).compactMap(\.value)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let full = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = full.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a date: \(text)"))
        }
        return d
    }()
}

/// Fetches the announcements, keeping the last list for when the service can't be reached.
public struct AnnouncementsService: Sendable {
    public let file: URL
    public let url: URL
    public let session: URLSession

    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        let override = ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:))
        self.url = (baseURL ?? override ?? CompatibilityReporter.defaultURL).appendingPathComponent("v1/announcements.json")
        self.file = paths.home.appendingPathComponent("Announcements.json")
        self.session = session
    }

    public func cached() -> [Announcement] {
        guard let data = try? Data(contentsOf: file), let list = try? AnnouncementList.decoder.decode(AnnouncementList.self, from: data),
              list.version == 1 else { return [] }
        return list.announcements
    }

    public func refresh() async -> [Announcement] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? AnnouncementList.decoder.decode(AnnouncementList.self, from: data), list.version == 1 else { return cached() }
        try? data.write(to: file, options: .atomic)
        return list.announcements
    }
}
