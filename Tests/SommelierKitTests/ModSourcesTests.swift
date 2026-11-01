// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Plays the Worker's mod.io proxy: an answer per path (status and JSON), and every request kept for a look.
final class ModIOStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answers: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var requests: [URL] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.append(url)
        let answer = Self.answers[url.path] ?? (status: 404, body: #"{"error":"not found"}"#)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ModSourcesTests {
    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-sources-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ folder: URL, _ name: String, bytes: Int = 16, created: Date? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x50, count: bytes).write(to: url)
        if let created { try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
        return url
    }

    private func client(gameID: Int = 8254) -> ModIOClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModIOStub.self]
        return ModIOClient(gameID: gameID, baseURL: URL(string: "https://api.test")!, session: URLSession(configuration: config))
    }

    private static let lantern = """
    {"id": 101, "name": "Lantern Light", "summary": "A brighter lantern.", "submitted_by": {"username": "ada"}, "date_updated": 1730000000,
     "logo": {"thumb_320x180": "https://thumb.modcdn.io/l.png"}, "profile_url": "https://mod.io/g/witcher3/m/lantern",
     "modfile": {"id": 5001, "filename": "LanternLight_1.2.zip", "version": "1.2", "filesize": 2048, "date_added": 1729000000},
     "stats": {"downloads_total": 321}, "tags": [{"name": "Gameplay"}], "platforms": [{"platform": "windows", "modfile_live": 5002}]}
    """

    private static let quiet = """
    {"id": 102, "name": "Quiet Roach", "summary": "", "modfile": {"id": 6001, "filename": "QuietRoach.zip", "version": "1.0"},
     "platforms": [{"platform": "windows", "modfile_live": 6001}]}
    """

    // MARK: Local files

    @Test func localFileSourceListsArchivesNewestFirst() async throws {
        let folder = try scratch("local")
        defer { try? FileManager.default.removeItem(at: folder) }
        let older = try write(folder, "Alpha Mod.zip", created: Date().addingTimeInterval(-100))
        _ = try write(folder, "Beta Pack.7z", created: Date().addingTimeInterval(-10))
        _ = try write(folder, "readme.md")
        let source = LocalFileSource(folder: folder)
        #expect(source.kind == .file)
        #expect(LocalFileSource.isArchive("x.ZIP") && LocalFileSource.isArchive("y.tar.xz") && !LocalFileSource.isArchive("z.exe"))

        let page = try await source.search("")
        #expect(page.cards.map(\.name) == ["Beta Pack", "Alpha Mod"] && page.total == 2)
        let found = try await source.search("alpha")
        let card = try #require(found.cards.first)
        #expect(found.cards.count == 1 && card.page == older && card.file?.name == "Alpha Mod.zip" && card.file?.bytes == 16)
        #expect(try await source.card(card.id) == card)
        let link = try await source.link(for: card.file!.id, of: card.id)
        #expect(try await source.download(link, into: folder) == older)      // handed back, never copied
        #expect(source.origin(for: card, file: card.file).kind == .file)
        await #expect(throws: ModSourceError.notFound) { try await source.card(-1) }
    }

    // MARK: mod.io

    @Test func modIOSearchAsksTheWorkerAndReadsTheCards() async throws {
        ModIOStub.requests = []
        ModIOStub.answers = ["/v1/mods/modio/8254/mods": (200, #"{"data": [\#(Self.lantern), \#(Self.quiet)], "result_total": 2, "result_offset": 0}"#)]
        let page = try await client().search("lantern", limit: 20)
        let asked = try #require(ModIOStub.requests.first)
        #expect(asked.host == "api.test" && asked.path == "/v1/mods/modio/8254/mods")
        let items = try #require(URLComponents(url: asked, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Set(items.map { "\($0.name)=\($0.value ?? "")" }) == ["_limit=20", "_offset=0", "_sort=-popular", "_q=lantern"])
        #expect(!items.contains { $0.name == "api_key" })

        #expect(page.total == 2 && page.cards.map(\.id) == [101, 102])
        let lantern = try #require(page.cards.first)
        #expect(lantern.name == "Lantern Light" && lantern.author == "ada" && lantern.version == "1.2" && lantern.downloads == 321)
        #expect(lantern.thumbnail?.host == "thumb.modcdn.io" && lantern.page?.path == "/g/witcher3/m/lantern" && lantern.tags == ["Gameplay"])
        #expect(lantern.updated == Date(timeIntervalSince1970: 1_730_000_000))
        #expect(lantern.file?.id == 5001 && lantern.file?.name == "LanternLight_1.2.zip" && lantern.file?.bytes == 2048)
        #expect(lantern.installFileID == 5002 && lantern.fileToInstall == 5002)   // the Windows file is live, not the default
        let quiet = page.cards[1]
        #expect(quiet.installFileID == nil && quiet.fileToInstall == 6001 && quiet.summary == "" && quiet.author == nil)

        ModIOStub.requests = []
        _ = try await client().search("   ")
        #expect(ModIOStub.requests.first?.query == "_limit=20&_offset=0&_sort=-popular")   // a blank query isn't sent
    }

    @Test func modIOLinkAndErrorsComeThrough() async throws {
        ModIOStub.answers = [
            "/v1/mods/modio/8254/mods/101": (200, Self.lantern),
            "/v1/mods/modio/8254/mods/101/files": (200, #"{"data": [{"id": 5002, "filename": "LanternLight_1.2_win.zip", "version": "1.2"}, {"id": 5001, "filename": "LanternLight_1.2.zip"}]}"#),
            "/v1/mods/modio/8254/mods/101/files/5002": (200, #"{"id": 5002, "filename": "LanternLight_1.2_win.zip", "download": {"binary_url": "https://g-8254.modapi.io/v1/games/8254/mods/101/files/5002/download/abc", "date_expires": 4102444800}}"#),
            "/v1/mods/modio/8254/mods/103": (503, #"{"error": "mod.io not configured"}"#),
            "/v1/mods/modio/8254/mods/104": (429, #"{"error": "too many"}"#),
            "/v1/mods/modio/8254/mods/105": (200, "not json"),
            "/v1/mods/modio/8254/mods/106/files/1": (200, #"{"id": 1, "download": {"binary_url": "http://plain.example/file.zip"}}"#),
        ]
        let source = client()
        let card = try await source.card(101)
        #expect(card.id == 101 && card.installFileID == 5002)
        let files = try await source.files(of: 101)
        #expect(files.map(\.id) == [5002, 5001] && files[0].name == "LanternLight_1.2_win.zip")
        let link = try await source.link(for: 5002, of: 101)
        #expect(link.url.host == "g-8254.modapi.io" && link.fileName == "LanternLight_1.2_win.zip" && link.isValid())
        #expect(link.expires == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(!ModDownloadLink(url: link.url, fileName: "x", expires: Date().addingTimeInterval(-1)).isValid())
        await #expect(throws: ModSourceError.linkExpired) {
            try await source.download(ModDownloadLink(url: link.url, fileName: "x", expires: Date().addingTimeInterval(-1)), into: FileManager.default.temporaryDirectory)
        }
        #expect(source.origin(for: card, file: files[0]) == StoredMod.Origin(kind: .modio, url: "https://mod.io/g/witcher3/m/lantern", modID: 101, fileID: 5002))

        await #expect(throws: ModSourceError.notFound) { try await source.card(999) }
        await #expect(throws: ModSourceError.notConfigured) { try await source.card(103) }
        await #expect(throws: ModSourceError.rateLimited) { try await source.card(104) }
        await #expect(throws: ModSourceError.badAnswer) { try await source.card(105) }
        await #expect(throws: ModSourceError.badAnswer) { try await source.link(for: 1, of: 106) }   // not https: not a link we follow
    }

    @Test func modIOUpdatesFindNewerFilesForItsOwnMods() async throws {
        ModIOStub.answers = [
            "/v1/mods/modio/8254/mods/101": (200, Self.lantern),
            "/v1/mods/modio/8254/mods/101/files": (200, #"{"data": [{"id": 5002, "filename": "LanternLight_1.2_win.zip", "version": "1.2"}]}"#),
            "/v1/mods/modio/8254/mods/102": (200, Self.quiet),
        ]
        func stored(_ key: String, _ origin: StoredMod.Origin) -> StoredMod {
            StoredMod(key: key, name: key, origin: origin, archive: .init(name: key), added: Date(), enabled: true, codeAccepted: false, units: [], leftovers: [])
        }
        let mods = [stored("lantern", .init(kind: .modio, modID: 101, fileID: 5001)),      // 5002 is live now
                    stored("quiet", .init(kind: .modio, modID: 102, fileID: 6001)),        // current
                    stored("gone", .init(kind: .modio, modID: 999, fileID: 1)),            // not listed any more
                    stored("mine", .init(kind: .file))]                                    // not from mod.io
        let updates = await client().updates(for: mods)
        #expect(updates.keys.sorted() == ["lantern"])
        #expect(updates["lantern"]?.id == 5002 && updates["lantern"]?.name == "LanternLight_1.2_win.zip")
    }
}
