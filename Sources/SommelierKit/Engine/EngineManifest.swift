// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The published list of downloadable engines (`engine-manifest.json`), plus a few settings that can be
/// changed on the server without an app release. Property names are the JSON keys.
public struct EngineManifest: Equatable, Codable, Sendable {
    /// One downloadable engine archive.
    public struct Entry: Equatable, Codable, Sendable {
        public var version: String          // e.g. "2.0.1"
        public var url: URL                 // the .tar.xz archive
        public var sha256: String           // hex digest of the archive, either case
        public var size: Int64              // bytes; 0 skips the size check
        public var minAppVersion: String?   // oldest app release the engine works with
        public var backends: [String]?      // `GraphicsBackend` raw values it provides
    }

    /// One D3DMetal archive: Apple's redistributable files from a Game Porting Toolkit, unchanged, with Apple's
    /// license beside them (Apple lets them be passed on for non-commercial use, and Sommelier is free).
    public struct D3DMetalEntry: Equatable, Codable, Sendable {
        public var version: String          // the framework's version, e.g. "3.0" or "4.0b3"
        public var url: URL                 // the .tar.xz archive
        public var sha256: String           // hex digest of the archive, either case
        public var size: Int64              // bytes; 0 skips the size check
        public var minMacOS: Int?           // the oldest macOS major version it is for; nil for any
    }

    public var engines: [Entry]                 // in no particular order
    public var steamArgs: [String]?             // Steam's command line
    public var knownIssues: [String: String]?   // game id -> note shown with the game
    public var d3dMetal: [D3DMetalEntry]?       // DirectX 12, one per range of macOS versions

    /// The D3DMetal for a Mac on macOS `major`: of those it is new enough for, the one meant for the newest macOS
    /// (GPTK 4 from macOS 27, GPTK 3 below), then the highest version.
    public func d3dMetal(forMacOS major: Int) -> D3DMetalEntry? {
        (d3dMetal ?? []).filter { ($0.minMacOS ?? 0) <= major }.max { a, b in
            let (lowA, lowB) = (a.minMacOS ?? 0, b.minMacOS ?? 0)
            return lowA != lowB ? lowA < lowB : a.version.compare(b.version, options: .numeric) == .orderedAscending
        }
    }

    public static func decode(_ json: Data) throws -> EngineManifest {
        try JSONDecoder().decode(Self.self, from: json)
    }

    /// The entry with the highest version, comparing versions numerically (1.10 is newer than 1.9).
    public var latest: Entry? { Self.highestVersion(of: engines) }

    /// The newest entry that lists `wanted`, e.g. the engine that can run D3DMetal for DirectX 12 games.
    public func latest(supporting wanted: GraphicsBackend) -> Entry? {
        Self.highestVersion(of: engines.filter { ($0.backends ?? []).contains(wanted.rawValue) })
    }

    /// The entries this app release can run: those without `minAppVersion`, or whose minimum it meets.
    public func runnable(byApp appVersion: String) -> EngineManifest {
        var copy = self
        copy.engines = engines.filter { entry in
            guard let minimum = entry.minAppVersion else { return true }
            return appVersion.compare(minimum, options: .numeric) != .orderedAscending
        }
        return copy
    }

    /// The engine to update to: the newest one with DXMT (Sommelier's DirectX 11 path) that this app release can
    /// run, when it is newer than every engine already installed; nil when there is nothing newer.
    public func update(over installed: [String], appVersion: String) -> Entry? {
        let usable = runnable(byApp: appVersion)
        guard let newest = usable.latest(supporting: .dxmt) ?? usable.latest else { return nil }
        let isNewer = installed.allSatisfy { newest.version.compare($0, options: .numeric) == .orderedDescending }
        return isNewer ? newest : nil
    }

    private static func highestVersion(of candidates: [Entry]) -> Entry? {
        var best: Entry?
        for candidate in candidates {
            if let current = best, candidate.version.compare(current.version, options: .numeric) != .orderedDescending {
                continue
            }
            best = candidate
        }
        return best
    }
}
