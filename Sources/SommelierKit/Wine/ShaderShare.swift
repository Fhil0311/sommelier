// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Sommelier's shader sharing service ("decanting"): the translated shaders DXMT made on one Mac, merged per
/// game and handed to the next player before the game's first run. See server/decanter.
public struct ShaderShare: Sendable {
    public struct Manifest: Codable, Equatable, Sendable {
        public struct Pack: Codable, Equatable, Sendable {
            public let exe: String
            public let kind: String
            public let metal: Int
            public let table: Int
            public let count: Int
            public let updated: String
        }
        public var packs: [Pack] = []
    }

    /// The cellar's archives held for a game (see server/decanter, cellar.js).
    public struct CellarManifest: Codable, Equatable, Sendable {
        public struct Archive: Codable, Equatable, Sendable {
            public let exe: String
            /// macOS major version ("26") and Metal's name for the GPU ("applegpu_g16s").
            public let os: String
            public let arch: String
            public let pipelines: Int
            public let bytes: Int
            public let updated: String
        }
        public var archives: [Archive] = []
    }

    public static let defaultURL = URL(string: "https://decanter.playsommelier.com")!
    public static let clientHeader = "X-Sommelier-Client"

    public let baseURL: URL
    public let session: URLSession
    public let clientVersion: String

    public init(baseURL: URL? = nil, session: URLSession = .shared, clientVersion: String = "dev") {
        // SOMMELIER_DECANTER_URL points the app at a local service while developing (`npx wrangler dev`).
        let override = ProcessInfo.processInfo.environment["SOMMELIER_DECANTER_URL"].flatMap(URL.init(string:))
        self.baseURL = baseURL ?? override ?? Self.defaultURL
        self.session = session
        self.clientVersion = clientVersion
    }

    /// The service's path segment for a game: its store and id, which are also how it is cached locally.
    static func path(store: String, gameID: String) -> String { "v1/pack/\(store)/\(gameID)" }

    public func manifest(store: String, gameID: String) async throws -> Manifest {
        let (data, response) = try await session.data(for: request("GET", Self.path(store: store, gameID: gameID)))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ShaderShareError.service((response as? HTTPURLResponse)?.statusCode ?? 0) }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    public func download(store: String, gameID: String, pack: Manifest.Pack) async throws -> ShaderPack {
        let path = Self.path(store: store, gameID: gameID) + "/\(pack.exe)/\(pack.kind)/\(pack.metal)/\(pack.table)"
        let (data, response) = try await session.data(for: request("GET", path))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ShaderShareError.service((response as? HTTPURLResponse)?.statusCode ?? 0) }
        // Packs are signed on the owner's Mac when they're merged (`Signature`): DXMT feeds them to Metal.
        guard Signature.accepts(data, signature: Signature.of(response)) else { throw ShaderShareError.badPack }
        guard let decoded = ShaderPack(encoded: data) else { throw ShaderShareError.badPack }
        return decoded
    }

    /// Sends a pack; the service merges it with what it holds. Returns how many shaders were new to it.
    @discardableResult
    public func upload(store: String, gameID: String, exe: String, pack: ShaderPack) async throws -> Int {
        let path = Self.path(store: store, gameID: gameID) + "/\(exe)/\(pack.kind.name)/\(pack.metalVersion)/\(pack.tableVersion)"
        var req = request("PUT", path)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, from: pack.encoded())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ShaderShareError.service((response as? HTTPURLResponse)?.statusCode ?? 0) }
        struct Reply: Decodable { let added: Int }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.added ?? 0
    }

    // MARK: The cellar

    static func cellarPath(store: String, gameID: String) -> String { "v1/cellar/\(store)/\(gameID)" }

    public func cellarManifest(store: String, gameID: String) async throws -> CellarManifest {
        let (data, response) = try await session.data(for: request("GET", Self.cellarPath(store: store, gameID: gameID)))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ShaderShareError.service((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(CellarManifest.self, from: data)
    }

    /// One archive, as the service holds it.
    public func downloadArchive(store: String, gameID: String, exe: String, os: String, arch: String) async throws -> Data {
        var req = request("GET", Self.cellarPath(store: store, gameID: gameID) + "/\(exe)/\(os)/\(arch)")
        req.timeoutInterval = 300
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ShaderShareError.service((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // Archives are signed by the builder on the owner's Mac (server/cellar/build.py).
        guard Signature.accepts(data, signature: Signature.of(response)) else { throw ShaderShareError.badPack }
        return data
    }

    /// The builder's upload (its token is the service's CELLAR_TOKEN secret).
    public func uploadArchive(store: String, gameID: String, exe: String, os: String, arch: String, data: Data, pipelines: Int, token: String) async throws {
        var req = request("PUT", Self.cellarPath(store: store, gameID: gameID) + "/\(exe)/\(os)/\(arch)")
        req.timeoutInterval = 600
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(String(pipelines), forHTTPHeaderField: "X-Sommelier-Pipelines")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ShaderShareError.service((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func request(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Sommelier/\(clientVersion)", forHTTPHeaderField: Self.clientHeader)
        return req
    }
}

public enum ShaderShareError: Error, LocalizedError {
    case service(Int)
    case badPack
    public var errorDescription: String? {
        switch self {
        case .service(let code): "The shader sharing service answered \(code)."
        case .badPack: "The shader pack couldn't be read."
        }
    }
}
