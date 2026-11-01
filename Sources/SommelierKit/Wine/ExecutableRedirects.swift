// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `ExeRedirects.tsv`: "where a store starts this program, the engine starts that one instead", for games whose
/// recipe skips a launcher (`LaunchProfile.redirect`). One line per game: the game's folder (a Windows path in its
/// bottle), the launcher as the end of its path ("Launcher.exe", "bin\\Launcher.exe"), and the program to start,
/// relative to the launcher's folder ("Borderlands2.exe", "..\\bin\\Game.exe"), as protonfixes write them.
/// Sommelier's ntdll reads it whenever a process is created (`SOMMELIER_EXE_REDIRECTS`), so Steam needn't restart
/// for a change. Games Sommelier starts itself (Epic, GOG) don't need it: their providers read the profile.
public struct ExecutableRedirects: Sendable {
    public let url: URL
    public init(paths: Paths) { url = Self.url(home: paths.home) }

    public static func url(home: URL) -> URL { home.appendingPathComponent("ExeRedirects.tsv") }

    /// A relative path in Windows form.
    static func windows(_ relative: String) -> String {
        relative.split(whereSeparator: { $0 == "/" || $0 == "\\" }).joined(separator: "\\")
    }

    /// `run` resolved against the folder of `instead` (both relative to the same root), ".." taken in.
    /// Whether a redirect is about this program: the program the store starts is the one it replaces (by name; a
    /// recipe written for Steam's copy names Steam's launcher, which another store's copy may not start at all).
    public static func applies(_ redirect: ExecutableRedirect, to program: String) -> Bool {
        let name = { (path: String) in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)?.lowercased() ?? "" }
        return name(redirect.instead) == name(program)
    }

    public static func resolve(run: String, nextTo instead: String) -> String {
        var stack = instead.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init).dropLast()
        for part in run.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            if part == ".." { if !stack.isEmpty { stack.removeLast() } } else if part != "." { stack.append(part) }
        }
        return stack.joined(separator: "/")
    }

    public static func table(for games: [(folder: String, redirect: ExecutableRedirect)]) -> String {
        let lines = games.map { "\($0.folder)\t\(windows($0.redirect.instead))\t\(windows($0.redirect.run))" }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// Rewrites the table, when it changed. `games` are the installed games with a redirect: their folder as a
    /// Windows path in their bottle, and the redirect.
    public func update(_ games: [(folder: String, redirect: ExecutableRedirect)]) {
        let text = Self.table(for: games)
        if (try? String(contentsOf: url, encoding: .utf8)) != text { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}
