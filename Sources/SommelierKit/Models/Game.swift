// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A store Sommelier can show games from. The raw value is the prefix of each game's id and the bottle's name.
public enum StoreKind: String, CaseIterable, Codable, Sendable {
    case steam, epic, gog, ubisoft, ea, battlenet

    /// The store's name as the player knows it.
    public var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        case .ubisoft: return "Ubisoft Connect"
        case .ea: return "EA app"
        case .battlenet: return "Battle.net"
        }
    }

    /// The Windows environment this store's games run in: every store has its own.
    public var bottleKind: BottleKind {
        switch self {
        case .steam: return .steam
        case .epic: return .epic
        case .gog: return .gog
        case .ubisoft: return .ubisoft
        case .ea: return .ea
        case .battlenet: return .battlenet
        }
    }

    /// True for stores whose Windows client starts the games, so games run alongside it, in its bottle and on its
    /// engine. Epic and GOG games are started directly.
    public var usesLauncher: Bool {
        switch self {
        case .steam, .ubisoft, .ea, .battlenet: return true
        case .epic, .gog: return false
        }
    }
}

/// The kind of Mac version a store has of a game. Today's macOS runs only 64-bit apps, and Intel-only ones need
/// Rosetta, which Apple drops in macOS 28.
public enum MacBuild: String, Codable, Sendable {
    case appleSilicon, intel
    /// The store has a Mac version but doesn't say which (Epic, GOG); it is looked at once downloaded.
    case unknown
    /// 32-bit only, which macOS stopped running with Catalina.
    case legacy32

    /// False only for 32-bit builds.
    public var runsHere: Bool { self != .legacy32 }

    /// Reads Steam's `oslist` and `osextended` fields; nil when the game has no Mac version.
    public static func steam(oslist platforms: String, osextended flags: String) -> MacBuild? {
        if !platforms.contains("macos") { return nil }
        switch true {
        case flags.contains("macosapplesilicon"): return .appleSilicon
        case flags.contains("macos64"): return .intel
        default: return .legacy32
        }
    }
}

/// One game from one store, owned or installed. Saved in `Library.json`; the property names are its keys.
public struct Game: Identifiable, Hashable, Codable, Sendable {
    /// `<store>:<store's id>` (for example `steam:268910`, `epic:<app_name>` or `gog:1207658924`), and the store.
    public let id: String, store: StoreKind
    /// The store's own id for the game: Steam's app id, Epic's app name, GOG's product id…
    public var storeID: String
    /// The name to show, and whether it's installed (and if so where and how big).
    public var title: String, isInstalled: Bool
    public var installPath: URL?, sizeOnDisk: Int64?
    /// Box art and wide art.
    public var coverURL, heroURL: URL?
    /// From 0 to 1 while the store installs or updates the game (nil otherwise); and the store's Mac version of the
    /// game, when the store says (Steam games instead read theirs from Steam's cache).
    public var installProgress: Double?, macBuild: MacBuild?
    /// Set when the installed copy is the Mac version, which runs without Wine. Optional so older files load.
    public var native: Bool?

    public var isNative: Bool { native ?? false }

    public init(
        store: StoreKind, storeID: String, title: String, isInstalled: Bool,
        installPath: URL? = nil, sizeOnDisk: Int64? = nil, coverURL: URL? = nil, heroURL: URL? = nil,
        installProgress: Double? = nil, macBuild: MacBuild? = nil, native: Bool? = nil
    ) {
        id = store.rawValue + ":" + storeID
        (self.store, self.storeID, self.title, self.isInstalled) = (store, storeID, title, isInstalled)
        (self.installPath, self.sizeOnDisk, self.installProgress) = (installPath, sizeOnDisk, installProgress)
        (self.coverURL, self.heroURL) = (coverURL, heroURL)
        (self.macBuild, self.native) = (macBuild, native)
    }
}
