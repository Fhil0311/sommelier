// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Windows Steam client, run in its own environment. Steam itself handles the account, downloads and DRM;
/// Sommelier installs it, keeps its interface drawable under Wine, reads its library from disk and asks it to start
/// games.
public struct SteamProvider: Sendable, StoreProvider {
    /// Valve's Windows installer.
    public static let setupURL: URL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Always on Steam's command line. Current clients ignore the `-cef-*` rendering switches, so the interface is
    /// made to draw by the web-helper wrapper instead (see `ensureWebHelperWrapper`); the DevTools switches still
    /// work and let Sommelier pause and resume downloads (`SteamClientBridge`).
    public static let defaultArguments: [String] = ["-no-cef-sandbox"] + SteamClientBridge.arguments

    /// Wine DLL settings for Steam: Windows' own bcrypt/ncrypt from the bottle first, and no in-game overlay.
    static let overrides: [String] = ["bcrypt=b;ncrypt=b", "gameoverlayrenderer,gameoverlayrenderer64=d"]

    /// Games inherit Steam's environment, and many publisher launchers they start (CD Projekt's REDlauncher, for
    /// one) embed Qt WebEngine. That is Chromium too, and it crashes under Wine with GPU compositing just as Steam's
    /// interface did, so it gets software rendering and no sandbox. The publisher launchers reuse this.
    static let webEngineEnvironment: [String: String] = {
        let chromiumSwitches = ["--disable-gpu", "--disable-gpu-compositing", "--in-process-gpu", "--no-sandbox"]
        return ["QTWEBENGINE_CHROMIUM_FLAGS": chromiumSwitches.joined(separator: " "), "QTWEBENGINE_DISABLE_SANDBOX": "1"]
    }()

    /// Store clients (Steam, the EA app, Ubisoft Connect…) see no microphone (the engine's Core Audio driver reads
    /// it): Steam's web helper looks at the microphone now and then, and macOS would then ask on Sommelier's behalf.
    /// Games unset it through their folder's environment (`WineRunner.programEnvironment`), so only a game that
    /// opens the microphone (voice chat) makes macOS ask.
    public static let noMicrophone: [String: String] = ["SOMMELIER_NO_MIC": "1"]

    /// A real Steam web helper is several megabytes; anything smaller is a stub or a broken download.
    static let minimumHelperSize = 500_000

    /// Log name for Steam's own runs (games log under their own id).
    private static let steamLog = "steam"

    public let kind: StoreKind = .steam
    public let paths: Paths   // Sommelier's data folders
    let wine: WineRunner

    public init(paths: Paths) { (self.paths, wine) = (paths, WineRunner(paths: paths)) }

    public var bottle: Bottle { .init(kind: .steam, paths: paths) }
    public var isSteamInstalled: Bool { FileManager.default.fileExists(atPath: self.bottle.steamExecutable.path) }

    /// Whether Steam's real client is on disk, not just the bootstrapper the installer leaves: the client library,
    /// its interface files, and a full-size web helper. Until then Steam must check and fetch its files on start;
    /// after that it may skip the check, which saves a long wait on every launch.
    public var isClientReady: Bool { hasCompleteClient() }

    private func hasCompleteClient() -> Bool {
        let files = FileManager.default
        let steam = bottle.steamDirectory
        func exists(_ relative: String) -> Bool { files.fileExists(atPath: steam.appendingPathComponent(relative).path) }
        guard exists("steamclient.dll") || exists("steamclient64.dll"), exists("clientui") else { return false }

        func isFullSize(_ file: URL) -> Bool {
            let size = (try? files.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
            return size > Self.minimumHelperSize
        }
        let cefFolders = (try? files.contentsOfDirectory(at: steam.appendingPathComponent("bin/cef"),
                                                         includingPropertiesForKeys: nil)) ?? []
        return cefFolders.contains { folder in
            isFullSize(folder.appendingPathComponent("steamwebhelper.exe"))
                || isFullSize(folder.appendingPathComponent("steamwebhelper_real.exe"))
        }
    }

    /// Steam's command line. File verification is skipped only once the client is complete, and never when
    /// `repair` asks for it.
    func arguments(verifyFiles repair: Bool = false) -> [String] {
        let skipCheck = !repair && isClientReady
        return Self.defaultArguments + (skipCheck ? ["-noverifyfiles"] : [])
    }

    /// The games in Steam's libraries, read from its files (Steam needn't be running).
    public func refresh() async throws -> [Game] { SteamLibrary.scan(bottle: self.bottle) }

    // MARK: Setup

    /// Makes the Steam environment, then downloads Valve's installer and runs it silently.
    public func installSteam(engine chosen: Engine) async throws {
        let bottles = BottleManager(paths: paths)
        try await bottles.ensure(.steam, engine: chosen)
        let (download, response) = try await URLSession.shared.download(from: Self.setupURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw WineRunnerError.launchFailed("couldn't download the Steam installer")
        }
        let files = FileManager.default
        let setup = paths.home.appendingPathComponent("SteamSetup.exe")
        try? files.removeItem(at: setup)
        try files.moveItem(at: download, to: setup)
        defer { try? files.removeItem(at: setup) }

        let variables = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        _ = try await ProcessRunner.run(chosen.wine, [setup.path, "/S"], environment: variables)
        if !isSteamInstalled { throw WineRunnerError.launchFailed("Steam did not install") }
    }

    // MARK: Starting Steam

    /// Puts Sommelier's wrapper in front of Steam's web helper (the program that draws Steam's interface) in every
    /// `bin/cef/cef.*` folder, and returns the folders that changed. Steam moves that folder between versions and
    /// its updates bring back Valve's helper, so this runs before every launch that skips file verification.
    /// Nothing is touched while only the bootstrapper is installed, and Valve's helper is never moved aside unless
    /// the engine has a wrapper to put in its place.
    @discardableResult public func ensureWebHelperWrapper(engine chosen: Engine) throws -> [String] {
        let files = FileManager.default
        let cef = bottle.steamDirectory.appendingPathComponent("bin/cef")
        let folders = ((try? files.contentsOfDirectory(at: cef, includingPropertiesForKeys: nil)) ?? [])
            .filter { folder in folder.lastPathComponent.hasPrefix("cef.") }
        if folders.isEmpty { return [] }

        let wrapper = ChromiumHelperWrapper.wrapper(in: chosen) ?? files.contents(atPath: chosen.steamWebHelperWrapper.path)
        guard let wrapper, !wrapper.isEmpty else {
            let problem = "the Steam interface helper is missing from the engine"
            throw WineRunnerError.launchFailed(problem)
        }
        var wrapped: [String] = []
        for folder in folders {
            let helper = folder.appendingPathComponent("steamwebhelper.exe")
            if try ChromiumHelperWrapper.wrap(helper, with: wrapper, legacyWrapper: true) {
                wrapped.append(folder.lastPathComponent)
            }
        }
        return wrapped
    }

    /// Opens Steam's window. `verifyFiles` makes Steam check and repair its own files first.
    @discardableResult public func launchSteam(engine chosen: Engine, profile: LaunchProfile = LaunchProfile(),
                                               verifyFiles: Bool = false, extraArguments: [String] = [],
                                               onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        try startSteam(arguments(verifyFiles: verifyFiles) + extraArguments, engine: chosen, profile: profile, logID: Self.steamLog,
                       onExit: onExit)
    }

    /// Handed to a running Steam, this makes it show its main window (the sign-in window when nobody is signed in),
    /// also after the player closed it with the cross and Steam went on in the tray, where a plain second start shows
    /// nothing.
    public static let showMainWindow = ["steam://open/main"]

    /// Has Steam start the game, starting Steam itself in the background first when it isn't running. The
    /// recipe's extra arguments follow the app id, so Steam hands them to the game.
    @discardableResult public func play(_ game: Game, engine chosen: Engine, profile: LaunchProfile,
                                        onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        let command = ["-silent"] + arguments() + ["-applaunch", game.storeID] + profile.extraArguments
        return try startSteam(command, engine: chosen, profile: profile, logID: game.id, onExit: onExit)
    }

    /// Asks the running Steam to quit cleanly. Has to use the engine Steam runs under, or it reaches nothing.
    @discardableResult public func shutdown(engine chosen: Engine) throws -> RunningProcess {
        try wine.run(engine: chosen, bottle: bottle, executable: "Steam.exe", arguments: ["-shutdown"],
                     workingDirectory: bottle.steamDirectory, logID: Self.steamLog)
    }

    /// Opens Steam's own install dialog for the app.
    @discardableResult public func install(appID: String, engine chosen: Engine) throws -> RunningProcess {
        let command = arguments() + ["steam://install/" + appID]
        return try startSteam(command, engine: chosen, profile: LaunchProfile(), logID: Self.steamLog, onExit: nil)
    }

    /// Every Steam start goes through here: the wrapper is refreshed when verification is skipped (a verifying
    /// start replaces the helper anyway), and the web-engine settings are added under the player's own.
    private func startSteam(_ command: [String], engine: Engine, profile: LaunchProfile, logID: String,
                            onExit: (@Sendable (_ status: Int32) -> Void)?) throws -> RunningProcess {
        if command.contains("-noverifyfiles") { try ensureWebHelperWrapper(engine: engine) }
        var tuned = profile
        tuned.extraEnvironment = Self.webEngineEnvironment.merging(Self.noMicrophone) { a, _ in a }
            .merging(profile.extraEnvironment) { _, mine in mine }
        return try wine.run(engine: engine, bottle: bottle, executable: "Steam.exe", arguments: command,
                            workingDirectory: bottle.steamDirectory, profile: tuned,
                            extraOverrides: Self.overrides, logID: logID, onExit: onExit)   // Steam's DLL settings
    }
}
