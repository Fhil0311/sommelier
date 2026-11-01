// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The games Steam has on disk, read from its own files: `libraryfolders.vdf` says where the libraries are, and each
/// library's `appmanifest_<id>.acf` files describe one game each. Works for the Windows Steam in its environment and,
/// through `SteamMacClient`, for Steam for Mac.
public enum SteamLibrary: Sendable {
    /// Steam's redistributables package, listed like a game but not one.
    static let ignoredAppIDs: Set = ["228980"]
    /// Tools and runtimes Steam installs alongside games.
    static let ignoredNamePrefixes: [String] = ["Steamworks", "Proton", "Steam Linux Runtime", "SteamVR"]

    /// A picture from Steam's store CDN, e.g. `library_600x900.jpg`, `library_hero.jpg` or `logo.png`.
    public static func artworkURL(appID: String, _ name: String) -> URL? {
        URL(string: "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/" + appID + "/" + name)
    }

    // MARK: Windows Steam

    /// Every game installed or being installed in any of the bottle's Steam libraries, by title.
    public static func scan(bottle environment: Bottle) -> [Game] {
        games(in: libraryDirectories(bottle: environment), native: false).inLibraryOrder()
    }

    /// The bottle's `steamapps` folders: Steam's own first, then every library `libraryfolders.vdf` lists, with
    /// Windows paths mapped into the bottle (other drives through its `dosdevices` links). Each folder once.
    public static func libraryDirectories(bottle environment: Bottle) -> [URL] {
        steamappsFolders(main: environment.steamDirectory.appendingPathComponent("steamapps")) { listed in
            environment.unixURL(forWindowsPath: listed)
        }
    }

    // MARK: Shared with Steam for Mac

    /// `main` plus the `steamapps` folder of each library listed in its `libraryfolders.vdf`, without duplicates.
    /// `locate` turns a listed path into a folder on this Mac, or nil when it can't be reached.
    static func steamappsFolders(main: URL, locate: (String) -> URL?) -> [URL] {
        var folders = [main]
        let listFile = main.appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: listFile, encoding: .utf8),
           let libraries = (try? VDFParser.parse(text))?["libraryfolders"]?.entries {
            for (_, library) in libraries {
                guard let listed = library["path"]?.string, let root = locate(listed) else { continue }
                folders.append(root.appendingPathComponent("steamapps"))
            }
        }
        var visited: Set<String> = []
        return folders.filter { visited.insert($0.standardizedFileURL.path).inserted }
    }

    /// The games described by the app manifests in these folders, in no particular order.
    static func games(in folders: [URL], native: Bool) -> [Game] {
        var found: [Game] = []
        for folder in folders {
            for manifest in manifestFiles(in: folder) {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let game = parseManifest(text, steamapps: folder, native: native) else { continue }
                found.append(game)
            }
        }
        return found
    }

    private static func manifestFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "acf" && $0.lastPathComponent.hasPrefix("appmanifest_") }
    }

    // MARK: App manifests

    /// `StateFlags` bits used here (Steam's own values).
    private enum Flag {
        static let updateRequired = 2
        static let fullyInstalled = 4
        static let updateRunning = 256
        static let updateStarted = 1024
    }

    /// One game from an `appmanifest_<id>.acf`, or nil for tools, redistributables and files that don't parse.
    /// `native`: the manifest belongs to Steam for Mac, so the game is a Mac app. `now` decides whether a scheduled
    /// update is still in the future (tests pass a fixed time).
    ///
    /// A game shows download progress while it isn't fully installed, or while an update is pending or running,
    /// as long as there are bytes to fetch. An update Steam put off until later doesn't count: the game plays as
    /// it is until then.
    public static func parseManifest(_ text: String, steamapps: URL, native: Bool = false, now: Date = Date()) -> Game? {
        guard let state = (try? VDFParser.parse(text))?["AppState"] else { return nil }
        func field(_ key: String) -> String? { state[key]?.string }
        guard let appID = field("appid"), let title = field("name"), !ignoredAppIDs.contains(appID) else { return nil }
        if ignoredNamePrefixes.contains(where: { title.hasPrefix($0) }) { return nil }

        let flags = field("StateFlags").flatMap { Int($0) } ?? 0
        let complete = flags & Flag.fullyInstalled != 0
        let updating = flags & (Flag.updateRequired | Flag.updateStarted | Flag.updateRunning) != 0
        let total = field("BytesToDownload").flatMap { Double($0) } ?? 0
        let fetched = field("BytesDownloaded").flatMap { Double($0) } ?? 0
        var progress: Double?
        if (!complete || updating), total > 0, !SteamDownload.updateScheduledForLater(state, now: now) {
            progress = min(1, fetched / total)
        }

        return Game(
            store: .steam, storeID: appID, title: title, isInstalled: complete,
            installPath: field("installdir").map { steamapps.appendingPathComponent("common/" + $0) },
            sizeOnDisk: field("SizeOnDisk").flatMap { Int64($0) },
            coverURL: artworkURL(appID: appID, "library_600x900.jpg"), heroURL: artworkURL(appID: appID, "library_hero.jpg"),
            installProgress: progress,
            native: native ? true : nil)
    }
}
