// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's mod.io catalogue, read through our Worker (`GET /v1/mods/modio/{gameID}/mods…`) so mod.io's key never
/// leaves the server; the files themselves come straight from mod.io's CDN by the signed link the catalogue
/// gives for a file. The Worker answers with mod.io's own JSON, so this reads mod.io's shapes: a list is
/// `{ data: [...], result_total, result_offset }`, dates are seconds since 1970, and a mod carries its current
/// release as `modfile` with, per platform, the file that is live there.
public struct ModIOClient: ModSource {
    public let gameID: Int
    public let baseURL: URL
    public let session: URLSession

    public static let defaultSort = "-popular"

    public init(gameID: Int, baseURL: URL? = nil, session: URLSession = .shared) {
        self.gameID = gameID
        let override = ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:))
        self.baseURL = baseURL ?? override ?? CompatibilityReporter.defaultURL
        self.session = session
    }

    public var kind: StoredMod.Origin.Kind { .modio }

    // MARK: Reading

    public func search(_ query: String, offset: Int = 0, limit: Int = 20) async throws -> ModPage {
        var items = [URLQueryItem(name: "_limit", value: String(max(1, min(limit, 100)))), URLQueryItem(name: "_offset", value: String(max(0, offset))),
                     URLQueryItem(name: "_sort", value: Self.defaultSort)]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "_q", value: String(trimmed.prefix(200)))) }
        let list: Listing<Mod> = try await get("mods", query: items)
        return ModPage(cards: list.data.map(\.card), total: list.resultTotal ?? list.data.count, offset: list.resultOffset ?? offset)
    }

    public func card(_ id: Int) async throws -> ModCard {
        let mod: Mod = try await get("mods/\(id)")
        return mod.card
    }

    public func files(of modID: Int) async throws -> [ModFileRef] {
        let list: Listing<File> = try await get("mods/\(modID)/files", query: [URLQueryItem(name: "_sort", value: "-date_added")])
        return list.data.map(\.ref)
    }

    public func link(for fileID: Int, of modID: Int) async throws -> ModDownloadLink {
        let file: File = try await get("mods/\(modID)/files/\(fileID)")
        guard let text = file.download?.binaryURL, let url = URL(string: text), url.scheme == "https" else { throw ModSourceError.badAnswer }
        return ModDownloadLink(url: url, fileName: file.filename ?? url.lastPathComponent, expires: file.download?.dateExpires.map(Self.date))
    }

    /// Fetches the file from mod.io's CDN into `folder`, under the name the catalogue gives it.
    public func download(_ link: ModDownloadLink, into folder: URL) async throws -> URL {
        guard link.isValid() else { throw ModSourceError.linkExpired }
        let (fetched, response) = try await session.download(from: link.url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            try? FileManager.default.removeItem(at: fetched)
            throw ModSourceError.failed("HTTP \(status)")
        }
        let name = ModArchive.basename(link.fileName)
        let target = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileScan.attributes(target) != nil { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: fetched, to: target)
        return target
    }

    // MARK: The Worker

    /// The Worker's address for a catalogue path.
    public func url(_ rest: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/mods/modio/\(gameID)/\(rest)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func get<T: Decodable>(_ rest: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: url(rest, query: query))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw ModSourceError.failed(error.localizedDescription) }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 404: throw ModSourceError.notFound
        case 429: throw ModSourceError.rateLimited
        case 503: throw ModSourceError.notConfigured
        case let status: throw ModSourceError.failed("HTTP \(status)")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ModSourceError.badAnswer }
    }

    static func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }

    // MARK: mod.io's shapes

    struct Listing<Item: Decodable>: Decodable {
        var data: [Item]
        var resultTotal: Int?
        var resultOffset: Int?
        enum CodingKeys: String, CodingKey { case data, resultTotal = "result_total", resultOffset = "result_offset" }
    }

    struct Mod: Decodable {
        struct Author: Decodable { var username: String? }
        struct Logo: Decodable {
            var thumb320x180: String?
            enum CodingKeys: String, CodingKey { case thumb320x180 = "thumb_320x180" }
        }
        struct Stats: Decodable {
            var downloadsTotal: Int?
            enum CodingKeys: String, CodingKey { case downloadsTotal = "downloads_total" }
        }
        struct Tag: Decodable { var name: String? }
        struct Platform: Decodable {
            var platform: String?
            var modfileLive: Int?
            enum CodingKeys: String, CodingKey { case platform, modfileLive = "modfile_live" }
        }
        var id: Int
        var name: String?
        var summary: String?
        var submittedBy: Author?
        var dateUpdated: Int?
        var logo: Logo?
        var profileURL: String?
        var modfile: File?
        var stats: Stats?
        var tags: [Tag]?
        var platforms: [Platform]?
        enum CodingKeys: String, CodingKey {
            case id, name, summary, logo, modfile, stats, tags, platforms
            case submittedBy = "submitted_by", dateUpdated = "date_updated", profileURL = "profile_url"
        }

        /// The card, with the Windows file as the one to install when mod.io keeps one per platform.
        var card: ModCard {
            let windows = platforms?.first { $0.platform == "windows" }?.modfileLive
            return ModCard(id: id, name: name ?? "#\(id)", summary: summary ?? "", author: submittedBy?.username, version: modfile?.version,
                           updated: dateUpdated.map(ModIOClient.date), thumbnail: logo?.thumb320x180.flatMap(URL.init(string:)),
                           page: profileURL.flatMap(URL.init(string:)), downloads: stats?.downloadsTotal, file: modfile?.ref,
                           installFileID: windows.flatMap { $0 == modfile?.id ? nil : $0 }, tags: (tags ?? []).compactMap(\.name))
        }
    }

    struct File: Decodable {
        struct Download: Decodable {
            var binaryURL: String?
            var dateExpires: Int?
            enum CodingKeys: String, CodingKey { case binaryURL = "binary_url", dateExpires = "date_expires" }
        }
        var id: Int
        var filename: String?
        var version: String?
        var filesize: Int64?
        var dateAdded: Int?
        var download: Download?
        enum CodingKeys: String, CodingKey { case id, filename, version, filesize, download, dateAdded = "date_added" }

        var ref: ModFileRef { ModFileRef(id: id, name: filename ?? "", version: version, bytes: filesize ?? 0, added: dateAdded.map(ModIOClient.date)) }
    }
}
