// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why an Epic action didn't happen. The descriptions are shown to the player as they are.
public enum EpicError: LocalizedError {
    case legendaryMissing, notSignedIn
    /// legendary ran but didn't do the job; the sentence says what went wrong.
    case commandFailed(_ message: String)

    public var errorDescription: String? { sentence }

    private var sentence: String {
        switch self {
        case .legendaryMissing: return "The Epic helper isn't installed yet."
        case .notSignedIn: return "You're not signed in to Epic Games."
        case .commandFailed(let text): return text
        }
    }
}

/// The sentences Epic actions show when they fail.
private enum EpicMessage {
    static let signInFailed = "Epic sign-in failed. Please try again."
    static let libraryUnreadable = "Couldn't read your Epic library."
    static let installUnfinished = "The install didn't finish. You can resume it."
    static func installStopped(_ reason: String) -> String { "The install didn't finish: " + reason }
    static func uninstallFailed(_ title: String) -> String { "Couldn't uninstall \(title)." }
}

/// Epic Games Store games through legendary, a native command-line Epic client. Sommelier never runs Epic's own
/// launcher: legendary signs in, downloads, and starts games, either in Wine or, for Mac versions, directly.
public struct EpicProvider: Sendable, StoreProvider {
    // MARK: Pinned helper

    /// The legendary build Sommelier uses (Heroic's maintained Apple Silicon build). Its SHA-256 is checked.
    public static let legendaryVersion: String = "0.20.43"
    public static let legendaryURL = URL(string: "https://github.com/Heroic-Games-Launcher/legendary/releases/download/\(legendaryVersion)/legendary_macOS_arm64")!
    public static let legendarySHA256: String = "fce325ca0c6c7edd7aaed559ed3f09772689f7f259965ca9ba5fb90f4b5108eb"
    /// Epic's sign-in page; once signed in it shows the `authorizationCode` the player pastes back.
    public static let loginURL: URL = URL(string: "https://legendary.gl/epiclogin")!

    public let kind: StoreKind = .epic
    public let paths: Paths   // Sommelier's data folders
    let wine: WineRunner
    private let customGamesFolder: URL?

    /// `folder`: the user's chosen games folder; nil uses the default one.
    public init(paths: Paths, gamesFolder folder: URL? = nil) {
        (self.paths, wine, customGamesFolder) = (paths, WineRunner(paths: paths), folder)
    }

    // MARK: Locations

    public var legendary: URL { paths.tools.appending(path: "legendary") }
    public var bottle: Bottle { .init(kind: .epic, paths: paths) }
    public var gamesFolder: URL {
        (customGamesFolder ?? paths.defaultGamesFolder).appendingPathComponent("Epic", isDirectory: true)
    }
    public var isLegendaryInstalled: Bool { FileManager.default.isExecutableFile(atPath: self.legendary.path) }
    /// legendary keeps the session in `user.json`; it exists exactly while someone is signed in.
    public var isSignedIn: Bool {
        FileManager.default.fileExists(atPath: paths.legendaryConfig.appending(path: "user.json").path)
    }

    /// The Epic environment's Wine variables (legendary passes them on to games), plus legendary's config folder.
    var environment: [String: String] {   // built fresh: the bottle's settings can change between calls
        var variables = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        variables["LEGENDARY_CONFIG_PATH"] = paths.legendaryConfig.path
        return variables
    }

    // MARK: Setup

    public func installLegendary() async throws {   // only once the download matches the pinned hash
        try await PinnedHelperDownload.install(from: Self.legendaryURL, sha256: Self.legendarySHA256, to: legendary,
                                               paths: paths, name: "Epic helper", failure: { EpicError.commandFailed($0) })
    }

    // MARK: Account

    /// Finishes signing in with the `authorizationCode` Epic showed. The code goes straight to legendary and is
    /// never logged.
    public func signIn(authorizationCode pasted: String) async throws {
        let code = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await legendaryRun(["auth", "--code", code])
        if !result.succeeded || !isSignedIn { throw EpicError.commandFailed(EpicMessage.signInFailed) }
    }

    public func signOut() async throws { try await legendaryRun(["auth", "--delete"]) }   // legendary drops its tokens

    // MARK: Library

    /// Everything the account owns (for Windows), with what is installed. The two lists are read at the same time.
    public func refresh() async throws -> [Game] { try await library() }

    private func library() async throws -> [Game] {
        if !isLegendaryInstalled { throw EpicError.legendaryMissing }
        if !isSignedIn { throw EpicError.notSignedIn }
        async let owned = legendaryJSON(["list", "--platform", "Windows", "--json"])
        async let installed = legendaryJSON(["list-installed", "--json"])
        let (ownedData, installedData) = try await (owned, installed)
        return try LegendaryParser.games(listJSON: ownedData, installedJSON: installedData)
    }

    public func installedGames() async -> [Game] {   // the library, or nothing rather than an error
        guard isLegendaryInstalled, isSignedIn, let games = try? await library() else { return [] }
        return games
    }

    // MARK: Installing and playing

    /// Downloads and installs the game: its Windows version, or with `native` its Mac version, which then runs
    /// without Wine. Cancelling the task stops legendary; installing again resumes.
    public func install(_ game: Game, native: Bool = false,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let files = FileManager.default
        try files.createDirectory(at: gamesFolder, withIntermediateDirectories: true)
        let command = [
            "-y", "install", game.storeID,
            "--platform", native ? "Mac" : "Windows",
            "--base-path", gamesFolder.path,
            // Without this, games with optional packs (languages, HD textures) stop and ask which to take; the
            // default selection is what the game needs.
            "--skip-sdl",
        ]
        let result = try await ProcessRunner.run(legendary, command, environment: environment) { line in
            let text: String
            switch line {
            case .stdout(let s): text = s
            case .stderr(let s): text = s
            }
            if let fraction = LegendaryParser.progress(from: text) { onProgress(fraction) }
        }
        // legendary sometimes ends with 0 after only logging an error: done only when it lists the game as installed.
        if result.succeeded, await installed(game) != nil { return }
        // Pass on legendary's own last complaint, so the player (and any report) sees why.
        let complaint = result.output.split(whereSeparator: \.isNewline).reversed().first { line in
            ["ERROR", "Error", "CRITICAL"].contains { line.contains($0) }
        }
        if let complaint {
            let reason = String(complaint).replacingOccurrences(of: "[cli] ", with: "")
            throw EpicError.commandFailed(EpicMessage.installStopped(reason))
        }
        throw EpicError.commandFailed(EpicMessage.installUnfinished)
    }

    /// Removes the game's files. Its own uninstaller is skipped: it would need the Windows environment set up for
    /// it, and legendary can delete the files by itself.
    public func uninstall(_ game: Game) async throws {   // nothing runs inside Wine
        let result = try await legendaryRun(["-y", "uninstall", game.storeID, "--skip-uninstaller"])   // -y is legendary's own option: before the command
        if !result.succeeded { throw EpicError.commandFailed(EpicMessage.uninstallFailed(game.title)) }
    }

    /// The installed game's executable (inside the `.app` for a Mac version), as legendary recorded it.
    public func installedExecutable(of game: Game) async -> URL? {
        guard let install = await installed(game), let relative = install.executable else { return nil }
        return install.folder.appendingPathComponent(relative)
    }

    /// The program Epic starts for the game, relative to its folder ("Binaries/Win32/Borderlands2.exe").
    public func launchExecutable(of game: Game) async -> String? { await installed(game)?.executable }

    private func installed(_ game: Game) async -> LegendaryInstall? {
        guard let data = try? await legendaryJSON(["list-installed", "--json"]),
              let installs = try? JSONDecoder().decode([LegendaryInstall].self, from: data) else { return nil }
        return installs.first(where: { $0.appName == game.storeID })
    }

    /// Starts a Mac version without Wine. legendary fetches the game's sign-in token, opens the app and exits.
    @discardableResult public func playNative(_ game: Game, arguments: [String] = [],
                                              onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        if !isSignedIn { throw EpicError.notSignedIn }
        if !isLegendaryInstalled { throw EpicError.legendaryMissing }
        let logURL = try LogStore(paths: paths).newLog(for: game.id)
        let log = try LogWriter(url: logURL)
        let stamp: @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
        log.note("[Sommelier] Launch \(stamp()) native Mac version\n")

        let child = Process()
        child.executableURL = legendary
        child.arguments = ["launch", game.storeID] + arguments
        child.environment = environment
        log.attach(child)
        child.terminationHandler = { finished in
            let status = finished.terminationStatus
            log.finish("\n[Sommelier] Exit \(stamp()) status=\(status)\n")
            onExit?(status)
        }
        try child.run()
        return RunningProcess(process: child, logURL: logURL)
    }

    /// Starts a Windows version: legendary launches it in the Epic environment with Sommelier's Wine. legendary
    /// handles Epic's launch tokens itself, so they never reach our logs.
    /// `executable`: the program Epic starts (`launchExecutable`), so a recipe's redirect applies only when it is
    /// the one the redirect replaces, and its replacement is found next to it.
    @discardableResult public func play(_ game: Game, engine: Engine, profile: LaunchProfile, executable: String? = nil,
                                        onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        if !isSignedIn { throw EpicError.notSignedIn }
        var arguments = ["launch", game.storeID, "--wine", engine.wine.path, "--wine-prefix", bottle.url.path]
        if let redirect = profile.redirect, let executable, ExecutableRedirects.applies(redirect, to: executable) {
            // A recipe can start another program in place of the one Epic names.
            arguments += ["--override-exe", ExecutableRedirects.resolve(run: redirect.run, nextTo: executable)]
        }
        arguments += profile.extraArguments
        let config = ["LEGENDARY_CONFIG_PATH": paths.legendaryConfig.path]
        return try wine.launch(program: legendary, arguments: arguments, engine: engine, bottle: bottle,
                               profile: profile, extraEnvironment: config, logID: game.id, onExit: onExit)
    }

    // MARK: Cloud saves

    /// Whether Epic names a cloud save folder for the game (the Mac one when the Mac version is installed), going by
    /// the metadata legendary cached.
    public func supportsCloudSaves(_ game: Game) -> Bool {
        let cached = paths.legendaryConfig.appending(path: "metadata/\(game.storeID).json")
        guard let data = try? Data(contentsOf: cached),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let attributes = metadata["customAttributes"] as? [String: Any] else { return false }
        let key = game.isNative ? "CloudSaveFolder_MAC" : "CloudSaveFolder"
        return attributes[key] != nil
    }

    /// Syncs the game's saves with Epic's cloud. legendary works out the save folder itself: inside the Epic
    /// environment (it reads `WINEPREFIX`) for a Windows version, in the user's Library for a Mac one.
    public func syncSaves(_ game: Game, _ mode: CloudSaveMode) async -> CloudSaveOutcome {
        guard isLegendaryInstalled, isSignedIn else { return .failed("not signed in") }
        let direction: String
        switch mode {
        case .download: direction = "--skip-upload"
        case .upload: direction = "--skip-download"
        case .forceDownload: direction = "--force-download"
        case .forceUpload: direction = "--force-upload"
        }
        let command = ["-y", "sync-saves", game.storeID, "--accept-path", direction]
        guard let result = try? await ProcessRunner.run(legendary, command, environment: environment) else {
            return .failed("couldn't run Legendary")
        }
        return CloudSaves.parseLegendary(result.output, status: result.status)
    }

    // MARK: Running legendary

    /// Runs legendary to completion, output collected.
    @discardableResult private func legendaryRun(_ arguments: [String]) async throws -> ProcessResult {
        if !isLegendaryInstalled { throw EpicError.legendaryMissing }
        return try await ProcessRunner.run(legendary, arguments, environment: environment)
    }

    /// Runs legendary for its JSON answer: stdout only, since legendary logs on stderr. A failed run is an error
    /// rather than half a library.
    private func legendaryJSON(_ arguments: [String]) async throws -> Data {
        if !isLegendaryInstalled { throw EpicError.legendaryMissing }
        let (status, data) = try await StoreHelperOutput.capture(legendary, arguments, environment: environment)
        guard status == 0 else { throw EpicError.commandFailed(EpicMessage.libraryUnreadable) }
        return data
    }
}
