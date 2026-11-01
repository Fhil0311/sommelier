// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The environment programs from one folder get (`ExeEnvironment.tsv`, read by the engine's ntdll at each process
/// creation: `SOMMELIER_EXE_ENV`), so a game runs with its own graphics — DXMT or D3DMetal, Turbo, SDR — without
/// restarting the store that starts it. One line per folder: the folder's Windows path, then `NAME=value` pairs;
/// an empty value means "not set". Every program under the folder, and its children, gets them.
public struct ExecutableEnvironment: Sendable {
    public static func url(home: URL) -> URL { home.appendingPathComponent("ExeEnvironment.tsv") }

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }
    var file: URL { Self.url(home: paths.home) }

    /// Replaces the folder's line (other folders' lines stay), or removes it when `variables` is empty.
    public func set(folder: String, variables: [String: String]) {
        var lines = (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        lines.removeAll { Self.folder(of: $0)?.caseInsensitiveCompare(folder) == .orderedSame }
        if let line = Self.line(folder: folder, variables: variables) { lines.append(line) }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The line for a folder, or nil when there's nothing to set. Names and values with tabs, newlines or an
    /// `=` in the name are left out: the file is tab-separated.
    public static func line(folder: String, variables: [String: String]) -> String? {
        let pairs = variables.keys.sorted().compactMap { name -> String? in
            let value = variables[name] ?? ""
            guard !name.isEmpty, !name.contains("="), !name.contains("\t"), !name.contains("\n"),
                  !value.contains("\t"), !value.contains("\n") else { return nil }
            return "\(name)=\(value)"
        }
        guard !pairs.isEmpty, !folder.contains("\t"), !folder.contains("\n") else { return nil }
        return ([folder] + pairs).joined(separator: "\t")
    }

    static func folder(of line: String) -> String? {
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        return String(line[..<tab])
    }

    /// The file's lines, folder by folder (for tests and checks).
    public static func parse(_ text: String) -> [(folder: String, variables: [String: String])] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            var variables: [String: String] = [:]
            for pair in parts.dropFirst() {
                guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
                variables[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
            }
            return (parts[0], variables)
        }
    }
}
