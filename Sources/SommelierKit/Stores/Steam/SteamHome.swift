// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One Steam client's folder: the Windows Steam inside the Steam environment, or Valve's Steam for Mac. Both keep
/// the same layout (`steamapps`, `depotcache`, `logs`, `config`), so what reads one reads the other.
public struct SteamHome: Sendable, Equatable {
    /// The Steam folder itself (`Program Files (x86)/Steam` in the environment, `~/Library/Application Support/Steam`).
    public let steamDirectory: URL
    /// Every `steamapps` folder, the main one first.
    public let libraryDirectories: [URL]

    public init(bottle: Bottle) {
        steamDirectory = bottle.steamDirectory
        libraryDirectories = SteamLibrary.libraryDirectories(bottle: bottle)
    }

    init(steamDirectory: URL, libraryDirectories: [URL]) {
        self.steamDirectory = steamDirectory
        self.libraryDirectories = libraryDirectories
    }

    /// Steam for Mac's folder.
    public static var mac: SteamHome {
        SteamHome(steamDirectory: SteamMacClient.home, libraryDirectories: SteamMacClient.libraryDirectories())
    }

    public func log(_ name: String) -> URL { steamDirectory.appendingPathComponent("logs/\(name)") }
}
