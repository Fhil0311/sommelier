// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the player has made of a game: launch settings, play time, save backups, applied fixes and so on. Kept
/// by game id and never touched by library refreshes.
public struct UserGameData: Equatable, Codable, Sendable {
    /// Launch settings.
    public var profile: LaunchProfile = .init()
    /// When the game was last played, and for how long in total (seconds).
    public var lastPlayed: Date?, playTime: TimeInterval = 0
    /// Folders the player picked for save backups (Pro), and when the last backup ran.
    public var saveSources: [SaveSource]?, lastSaveBackup: Date?
    /// Fixes Sommelier applied to the launch, oldest first; any of them can be undone.
    public var appliedFixes: [AppliedFix]?
    /// Recipe actions the player undid: a recipe that grows later doesn't bring them back.
    public var undoneRecipeActions: [FixAction]?
    /// How the game's saves stand against the store's cloud.
    public var saveSync: SaveSyncStatus?
    /// Date of the newest shared shader pack taken in, so an unchanged one isn't downloaded again.
    public var shadersDecanted: String?
    /// The cellar: date of the newest archive downloaded for this Mac, and when its records were last built here.
    public var cellarFetched: String?, cellarCooked: Date?
    /// The graphics settings fitted to this Mac (GameTuning), and the player's switch to turn that off.
    public var tuning: GameTuning?, tuningOff: Bool?
    /// Turbo (MetalFX upscaling) turned off for this game, by the player or because the game failed to start with it;
    /// and turned on for this game alone while it is off for all games in Settings.
    public var turboOff, turboFailed, turboOn: Bool?
    /// DXMT's counter saw the game use HDR, so the game page offers the HDR switch.
    public var knowsHDR: Bool?
    /// Whether the game has really run on this Mac: true after a session of over a minute that wasn't a crash or a
    /// hang, false after a session that was one (and none ran yet). `nil` (libraries from before) goes by play time.
    public var workedHere: Bool?
    /// The player said "it doesn't really run" (`StatusDispute.Problem` raw value): the game isn't rated as working
    /// from this Mac's play or other players' word until they take it back.
    public var disputed: String?
    /// The player's choices about the game's mods (AppModel+Mods); nil until the first mod.
    public var mods: ModState?

    public init() {}

    /// Reads each field on its own: one that's missing or can't be read (an older or newer file, a hand edit)
    /// keeps its default instead of losing the player everything else about the game.
    public init(from source: Decoder) throws {
        let fields = try source.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, as _: T.Type = T.self) -> T? {
            guard let value = try? fields.decodeIfPresent(T.self, forKey: key) else { return nil }
            return value
        }
        if let saved = read(.profile, as: LaunchProfile.self) { profile = saved }
        if let saved = read(.playTime, as: TimeInterval.self) { playTime = saved }
        lastPlayed = read(.lastPlayed)
        saveSources = read(.saveSources)
        lastSaveBackup = read(.lastSaveBackup)
        appliedFixes = read(.appliedFixes)
        saveSync = read(.saveSync)
        shadersDecanted = read(.shadersDecanted)
        cellarFetched = read(.cellarFetched)
        cellarCooked = read(.cellarCooked)
        tuning = read(.tuning)
        tuningOff = read(.tuningOff)
        turboOff = read(.turboOff)
        turboFailed = read(.turboFailed)
        turboOn = read(.turboOn)
        knowsHDR = read(.knowsHDR)
        workedHere = read(.workedHere)
        disputed = read(.disputed)
        mods = read(.mods)
    }
}

/// Where a game's saves stand against its store's cloud, the way Steam reports it: in sync, waiting to upload
/// (offline, or the store was down), or failed with a reason.
public struct SaveSyncStatus: Equatable, Codable, Sendable {
    public enum State: String, Sendable, Codable { case synced, pendingUpload, failed }

    public var state: State
    /// When it got there, and why, for a failure.
    public var date: Date, message: String?

    public init(_ state: State, date: Date = .now, message: String? = nil) {
        (self.state, self.date, self.message) = (state, date, message)
    }
}

/// The contents of `Library.json`: the games last seen in each store, so the library paints at once on launch,
/// and the player's data for each game.
public struct LibraryFile: Equatable, Codable, Sendable {
    public var games = [Game]()
    public var userData = [String: UserGameData]()

    public init() {}

    /// Skips any single game or game's data that can't be read. Failing the whole file instead would start the
    /// library from scratch and throw away every game's play time and settings.
    public init(from source: Decoder) throws {
        let fields = try source.container(keyedBy: CodingKeys.self)
        if let list = try? fields.decodeIfPresent([Lenient<Game>].self, forKey: .games) {
            games = list.compactMap(\.value)
        }
        if let byID = try? fields.decodeIfPresent([String: Lenient<UserGameData>].self, forKey: .userData) {
            userData = byID.compactMapValues(\.value)
        }
    }
}

/// Wraps a value whose decoding may fail, so the failure stays local to it.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from source: Decoder) throws {
        do { value = try Value(from: source) } catch { value = nil }
    }
}

/// Loads and saves `Library.json`, and folds each store's fresh game list into what was cached.
public struct LibraryStore: Sendable {
    let file: JSONStore<LibraryFile>

    public init(paths: Paths) { file = JSONStore(url: paths.libraryFile) }

    /// The saved library, or an empty one.
    public func load() -> LibraryFile { file.load(default: .init()) }

    /// Saving is best effort: a failed write leaves the previous file in place.
    public func save(_ library: LibraryFile) { try? file.save(library) }

    /// Swaps in one store's new list, keeps the other stores' cached games, and orders everything by title.
    public static func merged(cached: [Game], replacing store: StoreKind, with fresh: [Game]) -> [Game] {
        let others = cached.filter { $0.store != store }
        return (others + fresh).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Forgets player data for games that are in no store's list any more.
    public static func pruned(_ byGame: [String: UserGameData], keeping games: [Game]) -> [String: UserGameData] {
        let known = Set(games.lazy.map(\.id))
        return byGame.filter { known.contains($0.key) }
    }
}
