// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `AppNames.tsv`: each installed game's programs with the game's name and its shortcut app
/// ("witcher3.exe<TAB>The Witcher 3<TAB>/Users/…/Sommelier Games/The Witcher 3.app"). The engine names a program's
/// process after it and runs it from inside the shortcut (see `WineRunner.environment`, `ShortcutApp`), so the Dock
/// and Cmd-Tab show the game with its cover.
public struct AppNames: Sendable {
    public let url: URL
    public init(paths: Paths) { url = Self.url(home: paths.home) }

    static func url(home: URL) -> URL { home.appendingPathComponent("AppNames.tsv") }

    /// Programs that come with games but aren't the game.
    public static func isHelper(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["unins", "redist", "vcredist", "dxsetup", "dotnet", "crash", "uninstall", "setup", "easyanticheat", "be_service",
                "battleye", "installer", "cleanup", "touchup", "dxwebsetup", "physx", "oalinst", "prereq"].contains { n.contains($0) }
    }

    /// How deep a game's programs may lie: Unreal games keep theirs in `<Project>/Binaries/Win64/` (the fourth
    /// level), and some put the project in a folder of its own.
    static let depth = 5
    /// Folders that hold the game's data, never its programs: not walked (they can hold many thousands of files).
    static let dataFolders: Set<String> = ["content", "paks", "movies", "streamingassets", "_commonredist",
                                           "redist", "localization", "shaders", "sound", "audio"]

    /// The table for these games: their `.exe` files up to `depth` folders deep, helpers and data folders left
    /// out. A program name two games share keeps the first game's name.
    public static func table(for games: [(title: String, folder: URL, app: URL?)]) -> String {
        var seen = Set<String>(), lines: [String] = []
        for game in games {
            // A colon reads as a slash in a Mac file name (the engine names a link after it): a dash instead.
            let title = game.title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: ": ", with: " – ").replacingOccurrences(of: ":", with: "-")
            guard let walker = FileManager.default.enumerator(at: game.folder, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker {
                if walker.level > Self.depth || Self.dataFolders.contains(file.lastPathComponent.lowercased()) { walker.skipDescendants(); continue }
                let name = file.lastPathComponent
                guard name.lowercased().hasSuffix(".exe"), !isHelper(name), seen.insert(name.lowercased()).inserted else { continue }
                lines.append("\(name)\t\(title)" + (game.app.map { "\t\($0.path)" } ?? ""))
            }
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// Rewrites the table for the installed Windows games, when it changed. `apps` are their shortcut apps by game id.
    public func update(_ games: [Game], apps: [String: URL] = [:]) {
        let installed = games.filter { $0.isInstalled && !$0.isNative }.compactMap { g in g.installPath.map { (g.title, $0, apps[g.id]) } }
        let text = Self.table(for: installed)
        if (try? String(contentsOf: url, encoding: .utf8)) != text { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
