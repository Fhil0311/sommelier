// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Arguments the engine adds to a program's command line (`ExeArguments.tsv`, read by the engine's ntdll at each
/// process creation: `SOMMELIER_EXE_ARGS`), for games a store starts that can't be given any: Ubisoft Connect and
/// the EA app start the game themselves. One line per program: its full Windows path, then the arguments.
public struct ExecutableArguments: Sendable {
    public static func url(home: URL) -> URL { home.appendingPathComponent("ExeArguments.tsv") }

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }
    var file: URL { Self.url(home: paths.home) }

    /// Sets the arguments for the programs (Windows paths) of one game: its earlier lines (under `folder`) go, the
    /// new ones come in; no arguments leaves the game with none.
    public func set(folder: String, programs: [String], arguments: [String]) {
        let prefix = folder.lowercased() + "\\"
        var lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        lines.removeAll { $0.lowercased().hasPrefix(prefix) }
        let joined = arguments.filter { !$0.contains("\t") && !$0.contains("\n") }.joined(separator: " ")
        if !joined.isEmpty {
            lines += programs.filter { !$0.contains("\t") && !$0.contains("\n") }.map { "\($0)\t\(joined)" }
        }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The game's own programs, the ones a store may start: every .exe up to three folders down, but not helpers
    /// (crash reporters, installers, redistributables) or anti-cheat launchers, which must stay as they are.
    public static func programs(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [URL] = []
        for case let file as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            let name = file.lastPathComponent.lowercased()
            guard name.hasSuffix(".exe"), !AppNames.isHelper(file.lastPathComponent),
                  !["eac", "easyanticheat", "battleye", "beservice", "crash", "unins", "setup", "redist", "vcredist", "dxsetup",
                    "launcher", "updater", "report"].contains(where: name.contains) else { continue }
            found.append(file)
        }
        return found.sorted { $0.path < $1.path }
    }
}
