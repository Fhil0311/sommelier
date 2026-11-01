// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a GOG action didn't happen. The descriptions are shown to the player as they are.
public enum GOGError: LocalizedError {
    case helperMissing, notSignedIn
    /// Anything else, with the sentence to show.
    case failed(_ message: String)

    public var errorDescription: String? { message }

    private var message: String {
        switch self {
        case .helperMissing: return "The GOG helper isn't installed yet."
        case .notSignedIn: return "You're not signed in to GOG."
        case .failed(let text): return text
        }
    }
}

/// The sentences GOG actions show when they fail.
private enum GOGMessage {
    static let signInFailed = "GOG sign-in failed. Please try again."
    static let signInAgain = "GOG asked to sign in again."
    static let libraryUnreadable = "Couldn't read your GOG library."
    static let installUnfinished = "The install didn't finish. You can resume it."
    static func noPlayTask(_ title: String) -> String { "Couldn't find how to start \(title). Try reinstalling it." }
}

/// GOG games, handled by gogdl (the command-line GOG client from the Heroic project, GPL-3.0), which Sommelier runs
/// as a separate program. GOG Galaxy is never involved: GOG games are DRM-free, so they start straight from their
/// own files in the GOG environment.
public struct GOGProvider: Sendable, StoreProvider {
    // MARK: Pinned helper

    /// The gogdl build Sommelier uses (Heroic's Apple Silicon release). Its SHA-256 is checked before first use.
    public static let gogdlVersion: String = "1.3.0"
    public static let gogdlURL = URL(string: "https://github.com/Heroic-Games-Launcher/heroic-gogdl/releases/download/v\(gogdlVersion)/gogdl_macos_arm64")!
    public static let gogdlSHA256: String = "a85ae9ef80a3e7840b19a416dd4b3c5db2054508c6147315f1c22faa63a29b38"

    /// GOG's sign-in page. After signing in it redirects to a page whose address carries a one-time code, which
    /// gogdl trades for tokens.
    public static let loginURL: URL = URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=client2")!

    /// How many library pages are read at most (GOG pages hold 100 games, so this is far beyond any real library).
    static let maxLibraryPages = 50
    /// How many artwork requests run at once.
    static let artworkRequestsInFlight = 8

    public let kind: StoreKind = .gog
    public let paths: Paths   // Sommelier's data folders
    let wine: WineRunner
    private let customGamesFolder: URL?

    /// `folder`: the user's chosen games folder; nil uses the default one.
    public init(paths: Paths, gamesFolder folder: URL? = nil) {
        (self.paths, wine, customGamesFolder) = (paths, WineRunner(paths: paths), folder)
    }

    // MARK: Locations

    public var gogdl: URL { paths.tools.appending(path: "gogdl") }
    public var bottle: Bottle { .init(kind: .gog, paths: paths) }
    public var gamesFolder: URL {
        (customGamesFolder ?? paths.defaultGamesFolder).appendingPathComponent("GOG", isDirectory: true)
    }

    /// gogdl's tokens. Their presence is what "signed in" means.
    var tokensFile: URL { paths.gogConfig.appendingPathComponent("auth.json") }
    /// `GOGInstalled`, our own record of installs.
    var installsFile: URL { paths.gogConfig.appendingPathComponent("installed.json") }
    /// Cached `GOGParser.Artwork` by product id.
    var artworkCacheFile: URL { paths.gogConfig.appendingPathComponent("artwork.json") }
    /// When each save location was last synced, as gogdl's timestamps, keyed `<id>.<location name>`.
    var saveStampsFile: URL { paths.gogConfig.appendingPathComponent("saves.json") }

    public var isHelperInstalled: Bool { FileManager.default.isExecutableFile(atPath: self.gogdl.path) }
    public var isSignedIn: Bool { FileManager.default.fileExists(atPath: tokensFile.path) }

    /// A minimal environment for gogdl: its config folder, a home, and system tools only.
    private var helperEnvironment: [String: String] {
        [
            "GOGDL_CONFIG_PATH": paths.gogConfig.path,
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
        ]
    }

    /// Every gogdl call names the token file explicitly.
    private func gogdlArguments(_ command: [String]) -> [String] {
        ["--auth-config-path", tokensFile.path] + command
    }

    // MARK: Setup

    public func installHelper() async throws {   // only once the download matches the pinned hash
        try await PinnedHelperDownload.install(from: Self.gogdlURL, sha256: Self.gogdlSHA256, to: gogdl, paths: paths,
                                               name: "GOG helper", failure: { GOGError.failed($0) })
    }

    // MARK: Account

    /// Trades the code from GOG's login redirect for tokens. The code is passed straight to gogdl and never logged.
    /// A failed exchange leaves no token file behind; a good one is made readable by the user only.
    public func signIn(code pasted: String) async throws {
        let oneTimeCode = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = try await gogdlJSON(gogdlArguments(["auth", "--code", oneTimeCode]))
        if GOGParser.credentials(answer) == nil || !isSignedIn {
            try? FileManager.default.removeItem(at: tokensFile)
            throw GOGError.failed(GOGMessage.signInFailed)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokensFile.path)
    }

    /// Forgets the tokens. GOG itself isn't told; the session simply ends here.
    public func signOut() { try? FileManager.default.removeItem(at: tokensFile) }

    // MARK: Library

    /// Everything the account owns that runs on Windows, merged with what Sommelier installed.
    public func refresh() async throws -> [Game] { try await library() }

    private func library() async throws -> [Game] {
        try requireHelper()
        if !isSignedIn { throw GOGError.notSignedIn }
        // `gogdl auth` without a code prints the current access token, refreshing it first when it has expired.
        let tokenAnswer = try await gogdlJSON(gogdlArguments(["auth"]))
        guard let accessToken = GOGParser.credentials(tokenAnswer)?.accessToken else {
            throw GOGError.failed(GOGMessage.signInAgain)
        }
        let owned = try await ownedGames(accessToken: accessToken)
        let art = await cachedArtwork(products: owned.map(\.id))
        let records = readInstalled().games

        return owned.map { item -> Game in
            let record = records[item.id]
            let folder = record?.path
            return Game(
                store: .gog, storeID: item.id, title: record?.title ?? item.title,
                isInstalled: folder.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
                installPath: folder,
                sizeOnDisk: folder.flatMap { Self.folderSize($0) },
                coverURL: art[item.id]?.cover, heroURL: art[item.id]?.background,
                macBuild: item.mac ? .unknown : nil)
        }
        .inLibraryOrder()
    }

    /// Reads the library page by page until GOG says there are no more (or the page cap is hit).
    private func ownedGames(accessToken: String) async throws -> [(id: String, title: String, mac: Bool)] {
        var collected: [(id: String, title: String, mac: Bool)] = []
        var pageCount = 1
        for page in 1...Self.maxLibraryPages {
            guard page <= pageCount else { break }
            var components = URLComponents(string: "https://embed.gog.com/account/getFilteredProducts")
            components?.queryItems = [
                URLQueryItem(name: "mediaType", value: "1"),
                URLQueryItem(name: "sortBy", value: "title"),
                URLQueryItem(name: "page", value: String(page)),
            ]
            guard let url = components?.url else { break }
            var request = URLRequest(url: url)
            request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw GOGError.failed(GOGMessage.libraryUnreadable)
            }
            let parsed = try GOGParser.products(body)
            collected.append(contentsOf: parsed.games)
            pageCount = parsed.totalPages
        }
        return collected
    }

    /// Cover and background art from GOG's games database. It hardly ever changes, so what was fetched once is
    /// kept on disk and only new games are asked for, a few at a time.
    private func cachedArtwork(products ids: [String]) async -> [String: GOGParser.Artwork] {
        var known: [String: GOGParser.Artwork] = [:]
        if let saved = try? Data(contentsOf: artworkCacheFile),
           let decoded = try? JSONDecoder().decode([String: GOGParser.Artwork].self, from: saved) {
            known = decoded
        }
        let wanted = ids.filter { known[$0] == nil }
        var start = wanted.startIndex
        while start < wanted.endIndex {
            let end = min(start + Self.artworkRequestsInFlight, wanted.endIndex)
            let batch = wanted[start..<end]
            let fetched = await withTaskGroup(of: (String, GOGParser.Artwork?).self) { group in
                for id in batch {
                    group.addTask { (id, await Self.fetchArtwork(productID: id)) }
                }
                var results: [(String, GOGParser.Artwork?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for case let (id, art?) in fetched { known[id] = art }
            start = end
        }
        if let encoded = try? JSONEncoder().encode(known) {
            try? encoded.write(to: artworkCacheFile, options: .atomic)
        }
        return known
    }

    /// One game's art; nil when the request itself failed (so it is tried again next time).
    private static func fetchArtwork(productID: String) async -> GOGParser.Artwork? {
        guard let url = URL(string: "https://gamesdb.gog.com/platforms/gog/external_releases/" + productID),
              let (body, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return GOGParser.artwork(body)
    }

    // MARK: Installing and playing

    /// Downloads and installs the game's Windows version into the GOG games folder. Cancelling the task stops
    /// gogdl; installing again picks up where it stopped.
    public func install(_ game: Game,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if !isSignedIn { throw GOGError.notSignedIn }
        let files = FileManager.default
        try files.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
        let existingFolders = Set((try? files.contentsOfDirectory(atPath: gamesFolder.path)) ?? [])
        let command = gogdlArguments([
            "download", game.storeID,
            "--platform", "windows",
            "--path", gamesFolder.path,
            "--skip-dlcs",
            "--lang", "en-US",
        ])
        // gogdl reports progress on either stream, depending on its version.
        let result = try await ProcessRunner.run(gogdl, command, environment: helperEnvironment) { line in
            let text: String
            switch line {
            case .stdout(let s): text = s
            case .stderr(let s): text = s
            }
            if let fraction = GOGParser.progress(from: text) { onProgress(fraction) }
        }
        guard result.succeeded, let folder = findInstall(id: game.storeID, preferring: existingFolders) else {
            throw GOGError.failed(GOGMessage.installUnfinished)
        }
        var record = readInstalled()
        record.games[game.storeID] = GOGInstalled.Entry(title: game.title, path: folder)
        try saveInstalled(record)
    }

    /// Forgets the game and deletes its folder. Files are only ever deleted when the folder is one gogdl made for
    /// this game: it sits directly in a folder named "GOG" (Sommelier's GOG games folder, wherever the player has
    /// put it over time) and holds the game's `goggame-<id>.info`. A record pointing anywhere else is just dropped.
    public func uninstall(_ game: Game) throws {   // a no-op for games we have no record of
        var record = readInstalled()
        guard let entry = record.games[game.storeID] else { return }
        if Self.isOwnInstall(entry.path, id: game.storeID) {
            let files = FileManager.default
            try files.removeItem(at: entry.path)
        }
        record.games.removeValue(forKey: game.storeID)
        try saveInstalled(record)
    }

    /// Whether `folder` is a GOG install Sommelier may delete (see `uninstall`). Links are not followed.
    static func isOwnInstall(_ folder: URL, id: String) -> Bool {
        let path = folder.standardizedFileURL
        guard path.deletingLastPathComponent().lastPathComponent == "GOG", path.pathComponents.count > 3,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil else { return false }
        return FileManager.default.fileExists(atPath: path.appendingPathComponent("goggame-\(id).info").path)
    }

    /// Starts the game the way its `goggame-<id>.info` says, inside the GOG environment.
    @discardableResult public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                                        onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        guard let folder = installFolder(of: game),
              let info = try? Data(contentsOf: infoFile(id: game.storeID, in: folder)),
              let task = GOGParser.playTask(infoJSON: info) else {
            throw GOGError.failed(GOGMessage.noPlayTask(game.title))
        }
        // The info file uses Windows paths relative to the install folder.
        func inFolder(_ relative: String) -> URL {
            var url = folder
            for part in relative.split(whereSeparator: { $0 == "\\" || $0 == "/" }) {
                url.appendPathComponent(String(part))
            }
            return url
        }
        // A recipe can name another program next to the launcher to start instead.
        let target = profile.redirect.flatMap { ExecutableRedirects.applies($0, to: task.path)
            ? ExecutableRedirects.resolve(run: $0.run, nextTo: task.path) : nil } ?? task.path
        let executable = inFolder(target)
        let workingDirectory = task.workingDirectory.map(inFolder) ?? executable.deletingLastPathComponent()
        let arguments = task.arguments + profile.extraArguments    // the recipe's extras go last
        return try wine.run(engine: engine, bottle: bottle, executable: executable.path, arguments: arguments,
                            workingDirectory: workingDirectory, profile: profile, logID: game.id, onExit: onExit)
    }

    // MARK: Cloud saves

    /// The game's save folders, from the cloud-save configuration GOG publishes for it. Empty when the game isn't
    /// installed, has no cloud saves, or GOG can't be reached.
    public func saveLocations(of game: Game) async -> [GOGSaveLocations.Location] {
        guard let folder = installFolder(of: game),
              let info = try? Data(contentsOf: infoFile(id: game.storeID, in: folder)),
              let clientID = GOGParser.clientID(infoJSON: info) else { return [] }
        guard let (config, _) = try? await URLSession.shared.data(from: GOGSaveLocations.configURL(clientID: clientID)),
              let templates = GOGSaveLocations.templates(from: config, clientID: clientID),
              let user = GOGSaveLocations.userFolder(in: bottle) else { return [] }
        return templates.map { template in
            GOGSaveLocations.Location(name: template.name,
                                      path: GOGSaveLocations.resolve(template.template, install: folder, user: user))
        }
    }

    /// Syncs each of the game's save locations with GOG's cloud. gogdl decides what changed from the time of the
    /// previous sync, so that time is remembered per location. A conflict or failure in any location is what the
    /// whole sync reports.
    public func syncSaves(_ game: Game, _ mode: CloudSaveMode) async -> CloudSaveOutcome {
        guard isHelperInstalled, isSignedIn else { return .failed("not signed in") }
        let locations = await saveLocations(of: game)
        if locations.isEmpty { return .unsupported }

        var stamps: [String: String] = [:]
        if let saved = try? Data(contentsOf: saveStampsFile),
           let decoded = try? JSONDecoder().decode([String: String].self, from: saved) {
            stamps = decoded
        }
        let direction: String
        switch mode {
        case .download: direction = "--skip-upload"
        case .upload: direction = "--skip-download"
        case .forceDownload: direction = "--force-download"
        case .forceUpload: direction = "--force-upload"
        }

        var overall = CloudSaveOutcome.nothingToDo
        for location in locations {
            let stampKey = game.storeID + "." + location.name
            let command = gogdlArguments([
                "save-sync", location.path.path, game.storeID,
                "--os", "windows",
                "--ts", stamps[stampKey] ?? "0",
                "--name", location.name,
                direction,
            ])
            guard let run = try? await ProcessRunner.run(gogdl, command, environment: helperEnvironment) else {
                return .failed("couldn't run gogdl")
            }
            let (outcome, newStamp) = CloudSaves.parseGOG(run.output, status: run.status)
            if let newStamp { stamps[stampKey] = newStamp }
            switch outcome {
            case .conflict, .failed: overall = outcome
            case .synced where overall == .nothingToDo: overall = .synced
            default: break
            }
        }
        if let encoded = try? JSONEncoder().encode(stamps) {
            try? encoded.write(to: saveStampsFile, options: .atomic)
        }
        return overall
    }

    // MARK: Helpers

    private func installFolder(of game: Game) -> URL? { readInstalled().games[game.storeID]?.path }

    private func infoFile(id: String, in folder: URL) -> URL {
        folder.appendingPathComponent("goggame-\(id).info")
    }

    /// Which folder gogdl installed the game into: the one holding its `goggame-<id>.info`. When several do, a
    /// folder that wasn't there before the install (`before`) is the one.
    func findInstall(id: String, preferring existing: Set<String>) -> URL? {
        let files = FileManager.default
        let children = (try? files.contentsOfDirectory(at: gamesFolder, includingPropertiesForKeys: nil)) ?? []
        let candidates = children.filter { files.fileExists(atPath: infoFile(id: id, in: $0).path) }
        if let fresh = candidates.first(where: { !existing.contains($0.lastPathComponent) }) { return fresh }
        return candidates.first
    }

    /// Sommelier's record of GOG installs; empty when there is none yet or it can't be read.
    func readInstalled() -> GOGInstalled {
        guard let data = try? Data(contentsOf: installsFile),
              let record = try? JSONDecoder().decode(GOGInstalled.self, from: data) else { return GOGInstalled() }
        return record
    }

    func saveInstalled(_ record: GOGInstalled) throws {
        let configFolder = installsFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        try data.write(to: installsFile, options: .atomic)
    }

    private func requireHelper() throws {
        if !isHelperInstalled { throw GOGError.helperMissing }
    }

    /// Space a folder takes on disk (allocated, not logical size), or nil when it can't be walked. Also used for
    /// games the publisher launchers installed.
    static func folderSize(_ folder: URL) -> Int64? {
        let key = URLResourceKey.totalFileAllocatedSizeKey
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [key]) else { return nil }
        var bytes = Int64(0)
        while let item = walker.nextObject() as? URL {
            let size = (try? item.resourceValues(forKeys: [key]))?.totalFileAllocatedSize ?? 0
            bytes += Int64(size)
        }
        return bytes
    }

    /// Runs gogdl for its JSON answer. Only stdout is kept: gogdl logs on stderr, which would spoil the JSON.
    private func gogdlJSON(_ arguments: [String]) async throws -> Data {
        try requireHelper()
        return try await StoreHelperOutput.capture(gogdl, arguments, environment: helperEnvironment).data
    }
}
