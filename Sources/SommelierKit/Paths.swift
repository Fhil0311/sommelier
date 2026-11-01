// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where everything Sommelier keeps on disk lives. All of it hangs off one root, `~/Library/Application Support/
/// Sommelier` (`Sommelier Dev` for the development build, see `BuildFlavor`) unless `SOMMELIER_HOME` (or an explicit
/// `home`, for tests) points somewhere else. Sommelier only ever
/// uses its own folders, so other Wine-based apps can sit next to it untouched.
public struct Paths: Sendable {
    /// The root folder.
    public let home: URL

    public init(home root: URL? = nil) {
        home = root ?? Self.environmentHome ?? Self.applicationSupportHome
    }

    private static var environmentHome: URL? {
        guard let value = ProcessInfo.processInfo.environment["SOMMELIER_HOME"], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static var applicationSupportHome: URL {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(BuildFlavor.isDevelopment ? "Sommelier Dev" : "Sommelier", isDirectory: true)
    }

    private func folder(_ name: String) -> URL { home.appendingPathComponent(name, isDirectory: true) }
    private func file(_ name: String) -> URL { home.appendingPathComponent(name) }

    // MARK: Folders

    public var engines: URL { folder("Engines") }
    public var tools: URL { folder("Tools") }
    /// Apple's D3DMetal, copied in from the player's own Game Porting Toolkit download; Sommelier never ships it.
    public var d3dMetal: URL { folder("D3DMetal") }
    public var bottles: URL { folder("Bottles") }
    public var artwork: URL { folder("Artwork") }
    /// The mod store: every game's mods unpacked, one folder per game (`mods(_:)`), linked into the game from here.
    public var mods: URL { folder("Mods") }
    public var logs: URL { folder("Logs") }
    /// Legendary's config, Epic login tokens included.
    public var legendaryConfig: URL { folder("legendary") }
    /// gogdl's config: GOG tokens and manifests.
    public var gogConfig: URL { folder("gog") }

    // MARK: Files

    public var libraryFile: URL { file("Library.json") }
    public var settingsFile: URL { file("Settings.json") }
    /// Every play session's start and length, for the playtime stats.
    public var sessionsFile: URL { file("Sessions.json") }

    // MARK: Per item

    /// An installed engine's folder, named by its version.
    public func engine(version: String) -> URL {
        engines.appendingPathComponent(version, isDirectory: true)
    }
    /// A bottle (Wine prefix), named after its store.
    public func bottle(_ store: String) -> URL { bottles.appendingPathComponent(store, isDirectory: true) }

    /// A game's log folder. Game ids look like `steam:570`; the colon becomes a dash to keep the name plain.
    public func gameLogs(_ game: String) -> URL {
        logs.appendingPathComponent(Self.plainName(game), isDirectory: true)
    }

    /// A game's mod store (`Mods/steam-1245620/`), named like its log folder.
    public func mods(_ game: String) -> URL {
        mods.appendingPathComponent(Self.plainName(game), isDirectory: true)
    }

    private static func plainName(_ game: String) -> String {
        game.split(separator: ":", omittingEmptySubsequences: false).joined(separator: "-")
    }

    /// Where new games install unless the player picks another folder: `~/Games/Sommelier`.
    public var defaultGamesFolder: URL { Self.userFolder.appendingPathComponent("Games/Sommelier", isDirectory: true) }

    private static var userFolder: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Makes the folders Sommelier writes into. The two store configs hold login tokens, so they are locked to
    /// the owner whatever the umask is.
    public func createDirectories() throws {
        let manager = FileManager.default
        let all = [engines, tools, bottles, artwork, logs, legendaryConfig, gogConfig]
        try all.forEach { try manager.createDirectory(at: $0, withIntermediateDirectories: true) }
        for secret in [legendaryConfig, gogConfig] {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secret.path)
        }
    }
}
