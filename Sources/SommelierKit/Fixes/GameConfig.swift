// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A game's own settings file, named the way a rule or recipe may name it: a root the app knows and a relative
/// path under it. Only ini-style text files, only under the game's folders; never a path out of them.
public struct GameConfigFile: Equatable, Sendable {
    public enum Root: String, CaseIterable, Sendable {
        /// The game's install folder.
        case game
        /// The Windows user's `AppData\Local`.
        case appdata
        /// The Windows user's `AppData\Roaming`.
        case roaming
        /// The Windows user's `Documents`.
        case documents
        /// The Mac user's home folder, for the Mac version of a game (it keeps its settings there, like
        /// `~/.config/StardewValley`); never a Wine folder.
        case home
        /// Unreal Engine's `GameUserSettings.ini` (found by the Unreal tuning adapter: `unreal:GameUserSettings.ini`).
        case unreal
    }
    public let root: Root
    public let path: String

    /// "appdata:Sandfall/Saved/Config/Windows/GameUserSettings.ini". A save (`.sav`) may have one "*" component
    /// for a folder named after the player (`appdata:Sandfall/Saved/SaveGames/*/SharedGameUserSettings.sav`).
    public init?(_ spec: String, save: Bool = false) {
        guard let colon = spec.firstIndex(of: ":"), let root = Root(rawValue: String(spec[..<colon])) else { return nil }
        let path = String(spec[spec.index(after: colon)...])
        guard Self.isSafe(path, save: save) else { return nil }
        self.root = root; self.path = path
    }

    public var spec: String { "\(root.rawValue):\(path)" }

    /// A relative path with forward or back slashes, no "..", no drive, into an ini-style file (or a save).
    public static func isSafe(_ path: String, save: Bool = false) -> Bool {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard !parts.isEmpty, path.count <= 300, !path.contains(":"), !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        guard parts.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }) else { return false }
        guard parts.filter({ $0 == "*" }).count <= (save ? 1 : 0), parts.last != "*", !parts.contains(where: { $0.contains("*") && $0 != "*" }) else { return false }
        let name = parts.last!.lowercased()
        if save { return name.hasSuffix(".sav") }
        // Games name their text settings as they like (user.settings, config.NFS13Save): any file but programs,
        // libraries, scripts, archives and saves, which are never ini-style text.
        let never = [".exe", ".dll", ".sys", ".com", ".bat", ".cmd", ".ps1", ".vbs", ".js", ".msi", ".scr", ".lnk",
                     ".sav", ".pak", ".bin", ".dat", ".zip", ".7z", ".rar", ".cab", ".so", ".dylib"]
        return name.contains(".") && !never.contains { name.hasSuffix($0) }
    }

    /// The files on this Mac: one, or for `unreal` the engine's settings files (two platforms' folders), or one
    /// per folder a "*" stands for.
    public func resolve(game: Game, bottle: Bottle) -> [URL] {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        func under(_ base: URL?) -> [URL] {
            guard let base else { return [] }
            var urls = [base]
            for part in parts {
                if part == "*" {
                    urls = urls.flatMap { dir in
                        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !$0.lastPathComponent.hasPrefix(".") }
                    }
                } else {
                    urls = urls.map { $0.appendingPathComponent(part) }
                }
            }
            return urls
        }
        let user = GOGSaveLocations.userFolder(in: bottle)
        switch root {
        case .game: return under(game.installPath)
        case .appdata: return under(user?.appendingPathComponent("AppData/Local"))
        case .roaming: return under(user?.appendingPathComponent("AppData/Roaming"))
        case .documents: return under(user?.appendingPathComponent("Documents"))
        case .home: return under(FileManager.default.homeDirectoryForCurrentUser)
        case .unreal:
            guard parts == ["GameUserSettings.ini"] else { return [] }
            return UnrealSettings().files(for: game, bottle: bottle)
        }
    }
}

/// Edits a game's settings file for a rule or recipe (`FixAction.editConfig`): a key in a section, or a field of
/// a struct the key holds (`SettingsData=(…,ConsoleGraphicPreset=0)`). Every file changed is copied first, into
/// `<Sommelier>/Fixes/<game>/`, for the undo.
public struct GameConfigEditor: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// `${level}` in a value stands for the tuning level (0 low … 3 epic) the Mac gets.
    /// In a value: `${level}` is the Mac's level (0 low … 3 epic); `${level:a,b,c,d}` the value given for it (low,
    /// medium, high, epic; a shorter list repeats its last), for games whose own scale isn't 0…3; `${width}` and
    /// `${height}` the resolution the level runs at (the display's size in points below epic, its pixels at epic).
    public static func value(_ value: String, level: TuningLevel, resolution: (width: Int, height: Int)? = nil) -> String {
        var text = value
        while let open = text.range(of: "${level:"), let close = text[open.upperBound...].firstIndex(of: "}") {
            let choices = text[open.upperBound..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            text.replaceSubrange(open.lowerBound...close, with: choices.isEmpty ? "" : choices[min(level.rawValue, choices.count - 1)])
        }
        text = text.replacingOccurrences(of: "${level}", with: "\(level.rawValue)")
        if let resolution {
            text = text.replacingOccurrences(of: "${width}", with: "\(resolution.width)")
                .replacingOccurrences(of: "${height}", with: "\(resolution.height)")
        }
        return text
    }

    /// Whether a value follows the Mac (its level or the resolution for it): part of "matched to this Mac".
    public static func followsMac(_ value: String) -> Bool {
        value.contains("${level") || value.contains("${width}") || value.contains("${height}")
    }

    func backupFolder(for game: Game) -> URL {
        paths.home.appendingPathComponent("Fixes/\(game.id.replacingOccurrences(of: ":", with: "-"))", isDirectory: true)
    }

    /// The files changed, each with the copy made before (nil: the file didn't exist). Nothing when the file
    /// can't be placed for this game.
    public func edit(_ file: GameConfigFile, section: String, key: String, field: String?, value: String,
                     game: Game, bottle: Bottle) throws -> [(path: String, backup: String?)] {
        let fm = FileManager.default
        var out: [(path: String, backup: String?)] = []
        for url in file.resolve(game: game, bottle: bottle) {
            let old = try? String(contentsOf: url, encoding: .utf8)
            let new: String
            if let field {
                guard let old, let edited = IniFile.settingField(section: section, key: key, field: field, value: value, in: old) else { continue }
                new = edited
            } else {
                new = IniFile.setting([(section: section, key: key, value: value)], in: old)
            }
            guard new != old else { continue }
            var backup: String?
            if old != nil {
                let folder = backupFolder(for: game)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                backup = "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
                try fm.copyItem(at: url, to: folder.appendingPathComponent(backup!))
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: url, atomically: true, encoding: .utf8)
            out.append((url.path, backup))
        }
        return out
    }

    /// Sets ints in a struct of the game's save files (`UnrealSave`). A save that isn't there or can't be read
    /// is left alone; the files changed are returned with their copies, as for `edit`.
    public func editSave(_ file: GameConfigFile, structName: String, values: [String: Int32], game: Game, bottle: Bottle) throws -> [(path: String, backup: String?)] {
        let fm = FileManager.default
        var out: [(path: String, backup: String?)] = []
        for url in file.resolve(game: game, bottle: bottle) {
            guard let old = try? Data(contentsOf: url), let new = UnrealSave.settingInts(old, inStruct: structName, values: values), new != old else { continue }
            let folder = backupFolder(for: game)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let backup = "\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)"
            try fm.copyItem(at: url, to: folder.appendingPathComponent(backup))
            try new.write(to: url, options: .atomic)
            out.append((url.path, backup))
        }
        return out
    }

    /// The values an edit sets, for `TuningWatch`, in each file it would touch.
    public static func watched(_ action: FixAction, files: [String], level: TuningLevel,
                               resolution: (width: Int, height: Int)? = nil) -> [WatchedValue] {
        switch action {
        case .editConfig(_, let section, let key, let field, let value):
            return files.map { WatchedValue(path: $0, kind: .ini, section: section, key: key, field: field,
                                            value: Self.value(value, level: level, resolution: resolution)) }
        case .editSave(_, let structName, let values):
            return files.flatMap { path in values.sorted { $0.key < $1.key }.map {
                WatchedValue(path: path, kind: .save, section: structName, key: $0.key, value: Self.value($0.value, level: level, resolution: resolution)) } }
        default:
            return []
        }
    }

    /// Puts the files back (a file that didn't exist is removed).
    /// Last change first: when several edits touched one file, the copy made before the first one is what stays.
    public func restore(_ files: [(path: String, backup: String?)], game: Game) {
        let fm = FileManager.default
        let folder = backupFolder(for: game)
        for file in files.reversed() {
            let url = URL(fileURLWithPath: file.path)
            if let backup = file.backup {
                let copy = folder.appendingPathComponent(backup)
                guard fm.fileExists(atPath: copy.path) else { continue }
                try? fm.removeItem(at: url)
                try? fm.copyItem(at: copy, to: url)
                try? fm.removeItem(at: copy)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty { try? fm.removeItem(at: folder) }
    }
}

public extension IniFile {
    /// Sets `field` inside the struct value a key holds (`Key=(a=1,Field=0)`), in the section. Nil when the section,
    /// the key or the field isn't there: a struct Sommelier doesn't know isn't made up.
    static func settingField(section: String, key: String, field: String, value: String, in text: String) -> String? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let crlf = text.contains("\r\n")
        let header = "[\(section)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(header) == .orderedSame }) else { return nil }
        var i = start + 1
        while i < lines.count, !lines[i].hasPrefix("[") {
            let line = lines[i]
            if let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame {
                let pattern = #"(?<=[(,])"# + NSRegularExpression.escapedPattern(for: field) + #"=[^,)]*"#
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return nil }
                lines[i] = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line),
                                                          withTemplate: "\(field)=\(NSRegularExpression.escapedTemplate(for: value))")
                return lines.joined(separator: crlf ? "\r\n" : "\n")
            }
            i += 1
        }
        return nil
    }
}
