// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Everything the player sets app-wide, saved as `Settings.json`. The property names are the file's keys.
/// Settings added over time are optional, so files written before them still load; for most of those `nil` means
/// "the default", spelled out beside each.
public struct AppSettings: Equatable, Codable, Sendable {
    // MARK: Setup and engines

    /// Whether first-run setup is done, and whether launches log in detail.
    public var onboardingCompleted = false, verboseLogs = false
    /// The engine games run on.
    public var activeEngineVersion: String?
    /// Where the engine list is fetched from, where new games install (`nil` is `Paths.defaultGamesFolder`), and
    /// where save backups go.
    public var engineManifestURL, gamesFolder, backupFolder: URL?

    // MARK: Per bottle
    // What was last written into each bottle's registry is remembered, so the registry is only touched when a
    // setting actually changes.

    /// Which engine version last ran each bottle (a bottle's wineserver belongs to one engine, so a different
    /// engine has to wait until it has stopped), and the `playStationAsXbox` choice written into each.
    public var bottleEngines: [String: String]?, appliedControllerCompat: [String: Bool]?
    /// Retina mode by bottle, and Mac driver options by bottle and then by value name.
    public var appliedRetina = [String: Bool](), appliedMacDriver: [String: [String: Bool]]?

    // MARK: Stores

    /// Stores taken off the home screen, and stores put on it that start hidden (GOG, Ubisoft, EA); both hold
    /// `StoreKind` raw values.
    public var hiddenStores, shownStores: [String]?
    /// Epic and GOG games whose Mac version turned out to be 32-bit after download; their Windows version is used.
    public var legacyMacBuilds: [String]?
    /// For Steam games that also come for Mac: "native" installs through Steam for Mac, "windows" through the Steam
    /// inside Sommelier. `nil` uses Steam for Mac when it's installed and otherwise asks once.
    public var steamMacVersions: String?
    /// Epic and GOG cloud saves (Steam syncs its own). `nil` is on.
    public var cloudSaves: Bool?
    /// A copy of a game's saves after each session, kept in `backupFolder` (`nil`: Sommelier's data folder). `nil` is on.
    public var backUpSaves: Bool?

    // MARK: Looks

    /// The app's appearance: "light" or "dark"; `nil` follows macOS.
    public var appearance: String?
    /// The menu bar item (`nil` is on), and the card with the last game at the bottom of the sidebar (`nil` is off).
    public var showInMenuBar, showContinueCard: Bool?

    // MARK: Play

    /// Fit each game's graphics settings to this Mac before it first runs; MetalFX upscaling ("Turbo") for
    /// DirectX 10 and 11 games on Apple silicon; and DualShock 4, DualSense and other PlayStation-style pads
    /// showing up in games as Xbox controllers. `nil` is on for all three.
    public var tuneGames, turboGames, playStationAsXbox: Bool?
    /// Games that have PlayStation button prompts show them while a PlayStation controller is connected (default on).
    public var playStationPrompts: Bool?
    /// Whether the one-time note about tuning has been shown.
    public var tuningNoticeShown: Bool?
    /// The overlay Sommelier draws over a game (frame rate, GPU, memory…). `nil` is off with default contents.
    public var inGameCounter: InGameCounter?
    /// Clips: keeping the last minute of a game in memory, saved on a key (`nil` is off with default choices).
    public var clips: ClipSettings?
    /// Controller Mode (the full-screen library for a controller and a TV). `nil` is the defaults.
    public var controllerMode: ControllerModeSettings?
    /// What each bottle's PlayStation-as-Xbox keys were last set to, so they're written only when that changes.
    public var controllerKeysApplied: [String: Bool]?
    /// Whether this Mac's new install has been counted (`POST /v1/installs` once, only the version, no id).
    public var installCounted: Bool?
    /// Whether a player who agreed to share before usage was added has been told about it (once).
    public var usageNoticeShown: Bool?
    /// With sharing on: this install's own random id, for nothing but telling installed from uninstalled
    /// (`POST /v1/installs` once a day). Not the reports' id, so the two can't be tied together.
    public var installID: String?
    public var installSentDay: String?
    /// The first start of Sommelier on this Mac, and minutes from it to the first game (for the daily usage note).
    public var installedAt: Date?
    public var firstGameMinutes: Int?
    public var firstGameSent: Bool?
    /// The daily usage note (`POST /v1/usage`, only when sharing how games run): the last day it went, and what
    /// was used since then.
    public var usageSentDay: String?
    public var usageControllerMode: Bool?
    public var usagePads: [String]?

    // MARK: Shaders

    /// Share the shaders DXMT builds during play. Opt-in: `nil` until the player decides.
    public var shareShaders: Bool?
    /// Download others' shaders and a game's ready-built pipelines for this Mac before it runs. `nil` is on.
    public var readyMadeShaders: Bool?
    /// macOS Game Mode for games (the loader's games category, `LoaderGameLabel`). `nil` is on.
    public var gameMode: Bool?

    // MARK: Reports and announcements

    /// Send how each session went (started or not, crashes, play time, frame rate) to the compatibility database.
    /// `nil` until the player has been asked, which happens once; after that it's a switch in Settings.
    public var shareReports: Bool?
    /// Add the Mac's chip, GPU cores, memory and macOS version to reports. Asked separately; without it a report's
    /// frame rate can't be counted for a Mac model.
    public var shareHardware: Bool?
    /// The random id reports carry, made with the first one. The server keeps only a salted hash of it.
    public var reportClientID: String?
    /// Announcement ids the player closed, and those already posted as a macOS notification.
    public var dismissedAnnouncements, notifiedAnnouncements: [String]?

    public init() {}
}

/// A value kept as a JSON file (settings, the library, sessions…). Writes are atomic; dates are ISO 8601.
public struct JSONStore<Value: Codable & Sendable>: Sendable {
    /// The file.
    public let url: URL

    public init(url file: URL) { url = file }

    /// The stored value, or `fallback` when there's no file yet. A file that exists but can't be decoded is moved
    /// aside to `<name>.corrupt` first, so the next save doesn't destroy what might still be recovered by hand.
    public func load(default empty: Value) -> Value {
        guard let bytes = try? Data(contentsOf: url) else { return empty }
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        if let stored = try? reader.decode(Value.self, from: bytes) { return stored }
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return empty
    }

    /// Writes the value with sorted keys, so the file changes only where the value did.
    public func save(_ contents: Value) throws {
        let writer = JSONEncoder()
        writer.dateEncodingStrategy = .iso8601
        writer.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try writer.encode(contents)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}
