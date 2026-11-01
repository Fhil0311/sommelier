// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Adds a folder on this Mac as a Steam library of the Windows Steam, so Steam's own install window offers it
/// (an external drive, say). Steam keeps its libraries in `libraryfolders.vdf` (in `steamapps` and `config`) and
/// marks each library's root with its own `libraryfolder.vdf`. Steam rewrites these files while it runs and when
/// it quits, so this is only done while Steam isn't running.
public enum SteamLibraryFolders {
    /// The Windows path Steam sees for a Mac folder: Wine maps `/` to drive Z.
    public static func windowsPath(of folder: URL) -> String {
        "Z:" + folder.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Adds `folder` to the bottle's Steam libraries. False when it is already one (or Steam has no list yet:
    /// it makes one on its first start, and the next call adds the folder).
    @discardableResult public static func add(_ folder: URL, to bottle: Bottle,
                                              contentID: UInt64 = UInt64.random(in: 1_000_000_000_000_000...UInt64(Int64.max))) throws -> Bool {
        let lists = [bottle.steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf"),
                     bottle.steamDirectory.appendingPathComponent("config/libraryfolders.vdf")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let main = lists.first, let text = try? String(contentsOf: main, encoding: .utf8) else { return false }
        if contains(folder, in: text, bottle: bottle) { return false }

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let marker = folder.appendingPathComponent("libraryfolder.vdf")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try "\"libraryfolder\"\n{\n\t\"contentid\"\t\t\"\(contentID)\"\n\t\"label\"\t\t\"\"\n}\n"
                .write(to: marker, atomically: true, encoding: .utf8)
        }
        for list in lists {
            guard let current = try? String(contentsOf: list, encoding: .utf8),
                  let updated = adding(folder, contentID: contentID, to: current) else { continue }
            try updated.write(to: list, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// The library's number in Steam's list (Steam's folder index), or nil when it isn't one.
    public static func index(of folder: URL, in bottle: Bottle) -> Int? {
        let list = bottle.steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf")
        guard let text = try? String(contentsOf: list, encoding: .utf8) else { return nil }
        let wanted = folder.standardizedFileURL.path
        for (key, library) in (try? VDFParser.parse(text))?["libraryfolders"]?.entries ?? [] {
            guard let listed = library["path"]?.string,
                  bottle.unixURL(forWindowsPath: listed)?.standardizedFileURL.path == wanted else { continue }
            return Int(key)
        }
        return nil
    }

    /// Makes the library the one Steam's install window picks. Steam preselects the folder it last installed to,
    /// kept per Steam account as `LastInstallFolderIndex` at the top of `userdata/<account>/config/localconfig.vdf`.
    /// Steam writes that file as it quits, so this is done while Steam is stopped. False when nothing was set.
    @discardableResult
    public static func preselect(_ folder: URL, in bottle: Bottle) -> Bool {
        guard let number = index(of: folder, in: bottle) else { return false }
        let userdata = bottle.steamDirectory.appendingPathComponent("userdata")
        let accounts = (try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? []
        var changed = false
        for account in accounts where account != "0" && !account.hasPrefix(".") {
            let file = userdata.appendingPathComponent("\(account)/config/localconfig.vdf")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let updated = settingTopLevel("LastInstallFolderIndex", to: String(number), in: text) else { continue }
            if updated != text { try? updated.write(to: file, atomically: true, encoding: .utf8); changed = true }
        }
        return changed
    }

    /// The text with `key` set at the first level of its root block (replaced, or added right after the opening
    /// brace); nil when the text has no root block.
    static func settingTopLevel(_ key: String, to value: String, in text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        var depth = 0, opening: Int?
        for (n, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "{" { depth += 1; if depth == 1 { opening = n }; continue }
            if trimmed == "}" { depth -= 1; continue }
            if depth == 1, trimmed.hasPrefix("\"\(key)\""), trimmed.components(separatedBy: "\"").count >= 5 {
                lines[n] = "\t\"\(key)\"\t\t\"\(value)\""
                return lines.joined(separator: "\n")
            }
        }
        guard let opening else { return nil }
        lines.insert("\t\"\(key)\"\t\t\"\(value)\"", at: opening + 1)
        return lines.joined(separator: "\n")
    }

    /// Whether the list already names `folder` (compared as folders on this Mac).
    static func contains(_ folder: URL, in text: String, bottle: Bottle) -> Bool {
        let wanted = folder.standardizedFileURL.path
        let entries = (try? VDFParser.parse(text))?["libraryfolders"]?.entries ?? []
        return entries.contains { _, library in
            guard let listed = library["path"]?.string else { return false }
            return bottle.unixURL(forWindowsPath: listed)?.standardizedFileURL.path == wanted
        }
    }

    /// The list's text with a new library entry before its closing brace, numbered after the highest one; nil when
    /// the text isn't a library list.
    static func adding(_ folder: URL, contentID: UInt64, to text: String) -> String? {
        guard let root = (try? VDFParser.parse(text))?["libraryfolders"], let end = text.range(of: "}", options: .backwards) else {
            return nil
        }
        let next = ((root.entries ?? []).compactMap { Int($0.0) }.max() ?? -1) + 1
        let path = windowsPath(of: folder).replacingOccurrences(of: "\\", with: "\\\\")   // VDF escapes backslashes
        let entry = """
        \t"\(next)"
        \t{
        \t\t"path"\t\t"\(path)"
        \t\t"label"\t\t""
        \t\t"contentid"\t\t"\(contentID)"
        \t\t"totalsize"\t\t"0"
        \t\t"update_clean_bytes_tally"\t\t"0"
        \t\t"time_last_update_verified"\t\t"0"
        \t\t"apps"
        \t\t{
        \t\t}
        \t}

        """
        return text.replacingCharacters(in: end, with: entry + "}")
    }
}
