// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A folder suggested as a game's save location, with the clue that led to it and its current size.
public struct SaveCandidate: Hashable, Identifiable, Sendable {
    /// Why the folder was suggested, from strongest to weakest clue: the game's folder under Steam's
    /// userdata (Steam Cloud), a folder named like the game, a save-like folder inside the game's install
    /// folder, and a folder with files written after the game was last started.
    public enum Reason: String, Sendable, CaseIterable {
        case steamCloud, nameMatch, installFolder, recentlyChanged

        /// Lower is a stronger clue.
        var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
    }

    public var source: SaveSource, reason: Reason
    /// Current size of the folder and the newest file's date.
    public var bytes: Int64, files: Int, modified: Date?

    public var id: String { self.source.id }
}

/// Guesses where a game keeps its saves inside a bottle. Windows has no registry of save folders, so the
/// guesses come from folder names and from what the last play session touched; the user confirms them.
/// The Mac's own Documents folder (linked into every bottle) is only looked at shallowly.
public enum SaveLocator: Sendable {
    /// Folder names that belong to launchers, runtimes, drivers and caches, never to a game's saves.
    static let noise = Set<String>([
        "amd", "applications", "cache", "caches", "cef", "chromium", "crashdumps", "crashpad", "d3dscache",
        "discord", "dxvk", "eadesktop", "epicgameslauncher", "fontconfig", "galaxy", "gog galaxy", "gog.com",
        "gogcom", "google", "history", "installer", "intel", "legendary", "logs", "mesa_shader_cache",
        "microsoft", "mozilla", "nvidia", "nvidiacorporation", "origin", "packages", "programs", "qtwebengine",
        "redist", "steam", "temp", "tmp", "ubisoft", "ubisoft game launcher", "unrealengine",
        "unrealenginelauncher", "vulkan", "windows", "wine",
        // Launcher and service folders games write to while they run (seen in shared environments).
        "electronicarts", "epiconlineservices", "epicgames", "modio", "reportqueue", "crashreportclient",
        "easyanticheat", "battleye", "ubisoftgamelauncher", "rockstarlauncher", "socialclub", "ea", "battlenet",
    ].map(normalize))

    /// Names (lowercased) that a save folder inside the game's own folder usually has.
    static let installSaveNames: Set<String> = [
        "profiles", "save", "savedata", "savedgames", "savegame", "savegames", "saves", "userdata",
    ]

    /// Entry budget per folder measured, so a stray huge folder can't slow the search down.
    private static let measureLimit = 5_000

    /// Suggested save folders, strongest clue first, then by path. `changedSince` (normally when the game
    /// was last started) enables the "recently changed" clue.
    /// `otherGames`: titles of the other games in the same environment. A folder only "recently changed" that is
    /// named like one of them (it ran too, or its launcher did) is left out.
    public static func candidates(
        title: String, steamAppID: String?, roots: SaveRoots, changedSince: Date? = nil, otherGames: [String] = []
    ) -> [SaveCandidate] {
        let own = nameKeys(title)
        let others = otherGames.map(nameKeys).filter { !$0.isEmpty && Set($0).isDisjoint(with: own) }
        return allCandidates(title: title, steamAppID: steamAppID, roots: roots, changedSince: changedSince).filter { candidate in
            guard candidate.reason == .recentlyChanged else { return true }
            let parts = candidate.source.path.split(separator: "/").map(String.init)
            return !parts.contains { part in others.contains { matches(part, keys: $0) } && !matches(part, keys: own) }
        }
    }

    private static func allCandidates(
        title: String, steamAppID: String?, roots: SaveRoots, changedSince: Date?
    ) -> [SaveCandidate] {
        var search = Search(keys: nameKeys(title), since: changedSince)

        if let appID = steamAppID, let userdata = roots.steamUserdata {
            for account in sortedNames(in: userdata) ?? [] where account != "0" {
                let folder = userdata.appendingPathComponent(account).appendingPathComponent(appID)
                guard FileScan.isDirectory(folder) else { continue }
                search.offer(SaveSource(root: .steamUserdata, path: account + "/" + appID), .steamCloud, folder)
            }
        }

        // Many games use AppData/<Company>/<Game>, hence two levels.
        for root: SaveRoot in [.roaming, .local, .localLow] {
            if let top = roots.resolvedBase(root) { search.walk(root, top, under: "", levels: 2) }
        }
        if let top = roots.resolvedBase(.savedGames) { search.walk(.savedGames, top, under: "", levels: 1) }

        if let documents = roots.resolvedBase(.documents) { search.walkDocuments(documents) }

        if let gameDir = roots.install, FileScan.isDirectory(gameDir) {
            search.walkInstall(gameDir, under: "", levels: 2)
        }

        return search.found.values.sorted { lhs, rhs in
            if lhs.reason.rank != rhs.reason.rank { return lhs.reason.rank < rhs.reason.rank }
            return lhs.source.path.localizedCaseInsensitiveCompare(rhs.source.path) == .orderedAscending
        }
    }

    /// State of one search: the clues to look for and what has been found so far (keyed by source id).
    private struct Search {
        let keys: [String]
        let since: Date?
        var found = [String: SaveCandidate]()

        /// Records a folder if it holds any files, keeping only the strongest clue per folder.
        mutating func offer(_ source: SaveSource, _ reason: SaveCandidate.Reason, _ folder: URL) {
            if let known = found[source.id], known.reason.rank <= reason.rank { return }
            let size = FileScan.measure(folder, limit: SaveLocator.measureLimit)
            guard size.files > 0 else { return }
            found[source.id] = SaveCandidate(source: source, reason: reason, bytes: size.bytes,
                                             files: size.files, modified: size.newest)
        }

        /// Anything anywhere below `folder` was written since the game started.
        func touchedBelow(_ folder: URL) -> Bool {
            guard let since else { return false }
            let newest = FileScan.measure(folder, limit: SaveLocator.measureLimit).newest
            return newest.map { $0 >= since } ?? false
        }

        /// A file sitting directly in `folder` was written since the game started.
        func touchedDirectly(_ folder: URL) -> Bool {
            guard let since, let names = sortedNames(in: folder) else { return false }
            for entry in names {
                let file = folder.appendingPathComponent(entry)
                guard FileScan.isRegularFile(file), let stamp = FileScan.attributes(file)?[.modificationDate] as? Date else { continue }
                if stamp >= since { return true }
            }
            return false
        }

        /// Checks the subfolders of `parent` and, while `levels` allows, their subfolders. A folder named
        /// like the game is taken whole and not looked into further.
        mutating func walk(_ root: SaveRoot, _ parent: URL, under prefix: String, levels: Int) {
            for name in sortedNames(in: parent) ?? [] where !isNoise(name) {
                let child = parent.appendingPathComponent(name, isDirectory: true)
                guard FileScan.isDirectory(child) else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let source = SaveSource(root: root, path: relative)
                if SaveLocator.matches(name, keys: keys) {
                    offer(source, .nameMatch, child)
                } else if levels <= 1 {
                    if touchedBelow(child) { offer(source, .recentlyChanged, child) }
                } else {
                    if touchedDirectly(child) { offer(source, .recentlyChanged, child) }
                    walk(root, child, under: relative, levels: levels - 1)
                }
            }
        }

        /// Folders in Documents where games conventionally collect their saves.
        private static let collections: Set<String> = ["my games", "saved games"]

        /// Documents is the user's real Mac folder: only top-level folders named like the game, plus the
        /// conventional "My Games" and "Saved Games" collections one level in.
        mutating func walkDocuments(_ documents: URL) {
            for name in sortedNames(in: documents) ?? [] where !isNoise(name) {
                let child = documents.appendingPathComponent(name, isDirectory: true)
                guard FileScan.isDirectory(child) else { continue }
                if SaveLocator.matches(name, keys: keys) {
                    offer(SaveSource(root: .documents, path: name), .nameMatch, child)
                } else if Self.collections.contains(name.lowercased()) {
                    walk(.documents, child, under: name, levels: 1)
                }
            }
        }

        /// Save-named folders inside the game's install folder.
        mutating func walkInstall(_ folder: URL, under prefix: String, levels: Int) {
            for name in sortedNames(in: folder) ?? [] {
                let child = folder.appendingPathComponent(name, isDirectory: true)
                guard FileScan.isDirectory(child) else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let lower = name.lowercased()
                if installSaveNames.contains(lower) {
                    offer(SaveSource(root: .install, path: relative), .installFolder, child)
                } else if levels > 1 {
                    walkInstall(child, under: relative, levels: levels - 1)
                }
            }
        }
    }

    // MARK: Name matching

    /// Keeps only lowercase letters and digits, so "Studio MDHR" and "studio_mdhr" compare equal.
    static func normalize(
        _ text: String
    ) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            kept.append(scalar)
        }
        return String(kept)
    }

    /// Normalized forms of the title worth searching for: the full title and the part before any subtitle
    /// ("The Witcher 3: Wild Hunt" also gives "thewitcher3"). Very short keys are dropped as too vague.
    static func nameKeys(
        _ title: String
    ) -> [String] {
        let heads = [":", " - ", " – "].compactMap { mark in
            title.range(of: mark).map { String(title[..<$0.lowerBound]) }
        }
        return Array(Set(([title] + heads).map(normalize)).filter { $0.count >= 4 })
    }

    /// A folder matches when its normalized name equals a key, or, for names of five or more characters,
    /// when one contains the other.
    static func matches(
        _ folder: String, keys: [String]
    ) -> Bool {
        let name = normalize(folder)
        if name.isEmpty { return false }
        return keys.contains { key in
            if name == key { return true }
            guard min(name.count, key.count) >= 5 else { return false }
            return name.contains(key) || key.contains(name)
        }
    }

    /// Hidden folders and known non-game folders ("EA Desktop" and "eadesktop" alike).
    static func isNoise(_ name: String) -> Bool {
        name.hasPrefix(".") || noise.contains(normalize(name))
    }

    /// Folder contents in a stable order, or nil when the folder can't be read.
    private static func sortedNames(in folder: URL) -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.sorted()
    }
}

