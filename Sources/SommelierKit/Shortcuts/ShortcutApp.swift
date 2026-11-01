// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a game shortcut couldn't be made.
public enum ShortcutError: Equatable, LocalizedError {
    case invalidGame, nameTaken(String)

    public var errorDescription: String? { message }

    private var message: String {
        switch self {
        case .invalidGame:
            return "This game can't have a shortcut."
        case .nameTaken(let app):
            return "A different app called " + app + " is already in that folder."
        }
    }
}

/// A small `.app` per game that people can double-click, keep in the Dock or find with Spotlight.
///
/// The bundle contains no game code: its executable is a shell script that opens the game's `GameLink`, and
/// Sommelier does the rest. While the game runs, the engine starts it from a link inside this bundle (see
/// `AppNames`), so macOS shows the game under this app's name and icon in the Dock and the app switcher.
public enum ShortcutApp: Sendable {
    /// Info.plist key holding the game id; it marks a bundle as one of ours.
    public static let infoKey = "SommelierShortcutGameID"

    private static let executableName = "launch"

    /// `~/Applications/Sommelier Games`. The per-user Applications folder needs no admin rights and is indexed
    /// by Spotlight.
    public static var defaultFolder: URL { userApplications.appendingPathComponent(BuildFlavor.isDevelopment ? "Sommelier Dev Games" : "Sommelier Games", isDirectory: true) }

    private static var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// The bundle location `create` uses for a title.
    public static func appURL(title: String, in folder: URL) -> URL {
        folder.appendingPathComponent(SaveBackupStore.safeTitle(title) + ".app", isDirectory: true)
    }

    /// Builds the shortcut, replacing an earlier shortcut for the same game. A different app already using
    /// the name is left alone. `icon` is an optional `.icns` to include. Returns the bundle's URL.
    @discardableResult public static func create(
        title: String, gameID: String, in folder: URL, icon: URL? = nil
    ) throws -> URL {
        // The link goes inside single quotes in a shell script, so a quote in it would break out.
        guard let link = GameLink.playURL(gameID: gameID)?.absoluteString, !link.contains("'") else {
            throw ShortcutError.invalidGame
        }
        let disk = FileManager.default
        try disk.createDirectory(at: folder, withIntermediateDirectories: true)

        let destination = appURL(title: title, in: folder)
        if disk.fileExists(atPath: destination.path), existingGameID(at: destination) != gameID {
            throw ShortcutError.nameTaken(destination.lastPathComponent)
        }

        // Assemble the bundle under a hidden name, then swap it in.
        let draft = folder.appendingPathComponent(".new-" + UUID().uuidString + ".app", isDirectory: true)
        defer { try? disk.removeItem(at: draft) }
        let contents = draft.appendingPathComponent("Contents", isDirectory: true)
        let binDir = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resDir = contents.appendingPathComponent("Resources", isDirectory: true)
        for dir in [binDir, resDir] { try disk.createDirectory(at: dir, withIntermediateDirectories: true) }

        let executable = binDir.appendingPathComponent(executableName)
        let script = ["#!/bin/sh", "exec /usr/bin/open '" + link + "'", ""].joined(separator: "\n")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try disk.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var plist = bundleInfo(name: SaveBackupStore.safeTitle(title), gameID: gameID)
        if let iconFile = icon, disk.fileExists(atPath: iconFile.path) {
            try disk.copyItem(at: iconFile, to: resDir.appendingPathComponent("AppIcon.icns"))
            plist["CFBundleIconFile"] = "AppIcon"
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        if disk.fileExists(atPath: destination.path) { try disk.removeItem(at: destination) }
        try disk.moveItem(at: draft, to: destination)
        return destination
    }

    /// The Info.plist of a shortcut. It is deliberately not an agent (`LSUIElement`): the game running inside
    /// it has to appear in the Dock as a normal app.
    private static func bundleInfo(name: String, gameID: String) -> [String: Any] {
        [
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": (BuildFlavor.isDevelopment ? "gg.sommelier.dev.game." : "gg.sommelier.game.") + SaveBackupStore.safeID(gameID).lowercased(),
            "CFBundleExecutable": executableName, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": "15.0",
            "LSApplicationCategoryType": "public.app-category.games",
            microphoneKey: microphoneReason,
            infoKey: gameID,
        ]
    }

    /// A game running inside its shortcut is that app to macOS, so the shortcut must say why it may use the
    /// microphone: without the reason macOS doesn't ask, it closes the game (under Wine the game hangs instead).
    static let microphoneKey = "NSMicrophoneUsageDescription"
    /// Set by the app in the player's language, before shortcuts are made (the bundles have no translations).
    nonisolated(unsafe) public static var microphoneReason = "Games with voice chat use the microphone."

    /// Adds the microphone reason to a shortcut made before it existed (or in another language). True when the
    /// file changed, so the caller can have Launch Services read it again.
    @discardableResult public static func updateInfo(at app: URL) -> Bool {
        let plistURL = app.appendingPathComponent("Contents", isDirectory: true).appendingPathComponent("Info.plist")
        guard let raw = try? Data(contentsOf: plistURL),
              var dict = (try? PropertyListSerialization.propertyList(from: raw, format: nil)) as? [String: Any],
              dict[infoKey] != nil, dict[microphoneKey] as? String != microphoneReason else { return false }
        dict[microphoneKey] = microphoneReason
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return false }
        return (try? data.write(to: plistURL, options: .atomic)) != nil
    }

    /// The game id recorded in a shortcut bundle, or nil when the bundle isn't a Sommelier shortcut.
    public static func existingGameID(
        at app: URL
    ) -> String? {
        let plistURL = app.appendingPathComponent("Contents", isDirectory: true).appendingPathComponent("Info.plist")
        guard let raw = try? Data(contentsOf: plistURL),
              let dict = (try? PropertyListSerialization.propertyList(from: raw, format: nil)) as? [String: Any] else { return nil }
        return dict[infoKey] as? String
    }
}
