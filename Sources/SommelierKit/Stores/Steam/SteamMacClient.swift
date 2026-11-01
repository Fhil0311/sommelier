// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Valve's own Steam for Mac, for players who have it. Its games are Mac apps; Sommelier lists them and starts them
/// through it so the library is complete, but never installs Steam for Mac or signs in to it: that stays the
/// player's business.
public enum SteamMacClient {
    public static let appURL = URL(fileURLWithPath: "/Applications/Steam.app")

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: appURL.path) }

    /// Where Steam for Mac keeps its data and its main library.
    public static var home: URL {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Application Support/Steam", isDirectory: true)
    }

    /// All of Steam for Mac's `steamapps` folders: the main one and any libraries on other disks. Those are listed
    /// with ordinary Mac paths, so nothing needs translating.
    public static func libraryDirectories(home: URL = home) -> [URL] {
        SteamLibrary.steamappsFolders(main: home.appendingPathComponent("steamapps")) { listed in
            URL(fileURLWithPath: listed)
        }
    }

    /// Games Steam for Mac has installed or is installing, marked native. Nothing when Steam for Mac isn't there
    /// (a `home` other than the real one is always read, which is how tests use it).
    public static func scan(home: URL = home) -> [Game] {
        if home == Self.home && !isInstalled { return [] }
        return SteamLibrary.games(in: libraryDirectories(home: home), native: true)
    }

    /// Whether any library still holds the game's manifest. Steam removes it on uninstall.
    public static func hasManifest(appID: String, home: URL = home) -> Bool {
        let name = "appmanifest_" + appID + ".acf"
        return libraryDirectories(home: home).contains { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
    }

    // MARK: Signed-in check

    /// How much of the end of the connection log is read; the last log-on is always near the end.
    static let logTailBytes: UInt64 = 64 * 1024

    /// When Steam for Mac last finished logging on, from the end of its connection log. Until then it answers
    /// `steam://` links with "Steam is offline", so links wait for this.
    public static func lastLogOn(home: URL = home) -> Date? {
        let logFile = home.appendingPathComponent("logs/connection_log.txt")
        guard let reader = try? FileHandle(forReadingFrom: logFile) else { return nil }
        defer { try? reader.close() }
        let length = (try? reader.seekToEnd()) ?? 0
        try? reader.seek(toOffset: length > logTailBytes ? length - logTailBytes : 0)
        let tail = (try? reader.readToEnd()) ?? Data()
        return lastLogOn(in: String(decoding: tail, as: UTF8.self))
    }

    /// The time stamp of the last line reporting a completed log-on, such as
    /// `[2026-10-20 11:13:30] [Logged On, 4, 75] [U:1:1] RecvMsgClientLogOnResponse() : processing complete`.
    /// Stamps are local time.
    static func lastLogOn(in log: String) -> Date? {
        let completion = "RecvMsgClientLogOnResponse() : processing complete"
        guard let hit = log.range(of: completion, options: .backwards) else { return nil }
        let head = log[..<hit.lowerBound]
        let lineStart = head.lastIndex(where: { $0.isNewline }).map(head.index(after:)) ?? head.startIndex
        let line = head[lineStart...]
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let stamp = line[line.index(after: open)..<close]

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone.current
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return parser.date(from: String(stamp))
    }

    /// A `steam://<action>/<app id>` link. Steam for Mac opens these; the Windows Steam in Wine registers no URL
    /// scheme with macOS, so they always reach the Mac client.
    public static func url(_ action: String, appID: String) -> URL {
        // Both parts are plain words and digits, which always make a valid URL.
        URL(string: "steam://" + action + "/" + appID)!
    }
}
