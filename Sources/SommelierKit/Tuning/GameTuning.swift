// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Graphics settings matched to the Mac, written into a game's own settings before its first launch (as "Optimise"
/// in Nvidia's app). On by default; off for every game in Settings, or for one game on its page, where the player
/// can also put their own settings back: every file Sommelier changes is copied first.
public enum TuningLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case low, medium, high, ultra
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public func lowered() -> Self { Self(rawValue: max(rawValue - 1, 0)) ?? .low }
}

/// What a level is chosen from: how strong the Mac is, and how heavy the game.
public struct MacPower: Equatable, Sendable {
    public var appleSilicon: Bool
    public var gpuCores: Int
    public var ramGB: Int
    /// The main display, in points (what a game sees without Retina mode) and in pixels.
    public var displayPoints: (width: Int, height: Int)
    public var displayPixels: (width: Int, height: Int)

    public init(appleSilicon: Bool, gpuCores: Int, ramGB: Int, displayPoints: (Int, Int), displayPixels: (Int, Int)) {
        self.appleSilicon = appleSilicon; self.gpuCores = gpuCores; self.ramGB = ramGB
        self.displayPoints = displayPoints; self.displayPixels = displayPixels
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.appleSilicon == b.appleSilicon && a.gpuCores == b.gpuCores && a.ramGB == b.ramGB
            && a.displayPoints == b.displayPoints && a.displayPixels == b.displayPixels
    }

    /// The Mac's own level, before the game is considered. Base chips (8–10 GPU cores) are medium, Pro high, Max
    /// and Ultra ultra; 8 GB of memory or an Intel Mac takes it to low.
    public var level: TuningLevel {
        guard appleSilicon else { return .low }
        if ramGB <= 8 { return .low }
        switch gpuCores {
        case ..<14: return .medium
        case ..<30: return .high
        default: return .ultra
        }
    }

    /// The level for a game: one lower for a game Valve found too heavy for the Steam Deck.
    public func level(demanding: Bool) -> TuningLevel { demanding ? level.lowered() : level }

    /// The resolution a game should draw at: the display in points (a quarter of a Retina display's pixels; MetalFX
    /// or macOS scales it up), the full pixels only at ultra.
    public func resolution(for level: TuningLevel) -> (width: Int, height: Int) {
        level == .ultra ? displayPixels : displayPoints
    }
}

/// One file a tuning wrote, and what was there before (nil: it didn't exist).
public struct TunedFile: Codable, Equatable, Sendable {
    public var path: String
    /// File name of the copy in Sommelier's own folder, or nil when the game had no such file yet.
    public var backup: String?
    public init(path: String, backup: String?) { self.path = path; self.backup = backup }
}

/// One value the tuning set: a key of an ini section (with `field`, a field of the struct the key holds), or an
/// int of a struct in an Unreal save.
public struct WatchedValue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case ini, save }
    public var path: String
    public var kind: Kind
    public var section: String
    public var key: String
    public var field: String?
    public var value: String
    public init(path: String, kind: Kind, section: String, key: String, field: String? = nil, value: String) {
        self.path = path; self.kind = kind; self.section = section; self.key = key; self.field = field; self.value = value
    }
}

/// After a session: did the player change what the tuning set?
public enum TuningWatch {
    public enum Verdict: Equatable, Sendable {
        /// Nothing to compare yet, or all as set.
        case kept
        /// The first session: the game kept these values (some may differ from what was set: `notKept`).
        case settled(values: [WatchedValue], notKept: Bool)
        /// Values moved since the game settled: the player chose their own settings.
        case changedByPlayer
    }

    /// The value now, or nil when the file or entry is gone.
    public static func current(_ w: WatchedValue) -> String? {
        let url = URL(fileURLWithPath: w.path)
        switch w.kind {
        case .ini:
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return w.field.map { IniFile.fieldValue(section: w.section, key: w.key, field: $0, in: text) } ?? IniFile.value(section: w.section, key: w.key, in: text)
        case .save:
            guard let data = try? Data(contentsOf: url), let v = UnrealSave.ints(data, inStruct: w.section)?[w.key] else { return nil }
            return String(v)
        }
    }

    /// When the last of the watched files was written, or nil when none can be read.
    public static func lastWrite(of tuning: GameTuning) -> Date? {
        (tuning.watched ?? []).compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
        }.max()
    }

    public static func check(_ tuning: GameTuning) -> Verdict {
        guard let watched = tuning.watched, !watched.isEmpty else { return .kept }
        let now = watched.map { w -> WatchedValue in var c = w; c.value = current(w) ?? w.value; return c }
        if tuning.settled != true {
            return .settled(values: now, notKept: zip(watched, now).contains { $0.value != $1.value })
        }
        return zip(watched, now).contains { $0.value != $1.value } ? .changedByPlayer : .kept
    }

    /// The entries `new` sets differently from `old`, as watched values of `path`.
    public static func changes(from old: String?, to new: String, path: String) -> [WatchedValue] {
        let before = Dictionary(IniFile.entries(old ?? "").map { ("\($0.section.lowercased())\u{1}\($0.key.lowercased())", $0.value) },
                                uniquingKeysWith: { a, _ in a })
        return IniFile.entries(new).compactMap { e in
            before["\(e.section.lowercased())\u{1}\(e.key.lowercased())"] == e.value ? nil
                : WatchedValue(path: path, kind: .ini, section: e.section, key: e.key, value: e.value)
        }
    }
}

/// What Sommelier changed for a game, to show it and to put it back.
public struct GameTuning: Codable, Equatable, Sendable {
    public var level: TuningLevel
    public var applied: Date
    /// The kinds of settings changed: "retina" (the resolution the game sees), and the settings formats ("unreal",
    /// "witcher3", …).
    public var parts: [String]
    public var files: [TunedFile]
    /// Retina mode before, when Sommelier changed it.
    public var previousRetina: Bool?
    /// A changed file lies in a folder Steam Cloud syncs: the settings may reach the player's other computers.
    public var cloudSynced: Bool
    /// Edits from the game's recipe that follow the level (`${level}`), done with the tuning and put back with it
    /// (`GameConfigEditor` copies).
    public var edits: [TunedFile]?
    /// The values the tuning set, watched after each session (`TuningWatch`): the player changing them in the
    /// game turns the tuning off. After the first session they become what the game settled on.
    public var watched: [WatchedValue]?
    /// The first session after the tuning has been checked (the baseline is what the game kept).
    public var settled: Bool?
    /// When the values the game kept were noted (`settled`): a change after that, before the session's end, is the
    /// player's; the game's own rewrite as it quits is not.
    public var settledAt: Date?
    /// The game didn't keep what the tuning set (it applied settings of its own at start): a recipe is needed.
    public var notKept: Bool?

    public init(level: TuningLevel, applied: Date = Date(), parts: [String] = [], files: [TunedFile] = [],
                previousRetina: Bool? = nil, cloudSynced: Bool = false) {
        self.level = level; self.applied = applied; self.parts = parts; self.files = files
        self.previousRetina = previousRetina; self.cloudSynced = cloudSynced
    }
}

/// Knows one way games keep their settings: finds a game's file and writes a level into it.
public protocol TuningAdapter: Sendable {
    var id: String { get }
    /// The settings files to write for this game (existing or to be made), or empty when it isn't this kind.
    func files(for game: Game, bottle: Bottle) -> [URL]
    /// The file's new text for a level. `text` is the current one (nil when there is no file yet).
    func tuned(_ text: String?, file: URL, level: TuningLevel, power: MacPower) -> String?
    /// The same, knowing the game (for adapters that read the game's own files).
    func tuned(_ text: String?, file: URL, game: Game, level: TuningLevel, power: MacPower) -> String?
}

extension TuningAdapter {
    public func tuned(_ text: String?, file: URL, game: Game, level: TuningLevel, power: MacPower) -> String? {
        tuned(text, file: file, level: level, power: power)
    }
}

/// Applies and undoes tunings. Copies live in `<Sommelier>/Tuning/<game>/`.
public struct GameTuner: Sendable {
    public let paths: Paths
    public let adapters: [TuningAdapter]

    public init(paths: Paths, adapters: [TuningAdapter] = GameTuner.builtIn) {
        self.paths = paths; self.adapters = adapters
    }

    /// Engines' formats only: what one game needs comes as its recipe (editConfig, editSave with `${level}`).
    public static let builtIn: [TuningAdapter] = [UnrealSettings()]

    public func backupFolder(for game: Game) -> URL {
        paths.home.appendingPathComponent("Tuning/\(game.id.replacingOccurrences(of: ":", with: "-"))", isDirectory: true)
    }

    /// Whether a settings format this version knows applies to the game (its files can be written now).
    public func canTune(_ game: Game, bottle: Bottle) -> Bool {
        adapters.contains { !$0.files(for: game, bottle: bottle).isEmpty }
    }

    /// Writes the level into every settings file an adapter knows for the game. Returns what was done (no files:
    /// an empty list of parts, for the caller to add its own levers to).
    public func apply(_ game: Game, bottle: Bottle, level: TuningLevel, power: MacPower) throws -> GameTuning {
        var tuning = GameTuning(level: level)
        let folder = backupFolder(for: game)
        let fm = FileManager.default
        for adapter in adapters {
            let files = adapter.files(for: game, bottle: bottle)
            guard !files.isEmpty else { continue }
            var changed = false
            for file in files {
                let old = try? String(contentsOf: file, encoding: .utf8)
                guard let new = adapter.tuned(old, file: file, game: game, level: level, power: power), new != old else { continue }
                var backup: String?
                if old != nil {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    backup = "\(tuning.files.count)-\(file.lastPathComponent)"
                    let copy = folder.appendingPathComponent(backup!)
                    try? fm.removeItem(at: copy)
                    try fm.copyItem(at: file, to: copy)
                }
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try new.write(to: file, atomically: true, encoding: .utf8)
                tuning.files.append(TunedFile(path: file.path, backup: backup))
                tuning.watched = (tuning.watched ?? []) + TuningWatch.changes(from: old, to: new, path: file.path)
                if Self.syncedByCloud(file) { tuning.cloudSynced = true }
                changed = true
            }
            if changed { tuning.parts.append(adapter.id) }
            break                                           // one format per game
        }
        return tuning
    }

    /// Puts every changed file back as it was (a file the game didn't have is removed again).
    /// Whether the record missed the game's real settings: a settings file of a format it changed exists now and
    /// isn't one it wrote (it wrote where the game doesn't look, as for Unreal games keeping settings next to the
    /// game before Sommelier knew that place). Such a record changed nothing the game reads.
    public func isStale(_ tuning: GameTuning, for game: Game, bottle: Bottle) -> Bool {
        // Compared without symlinks: the same file may be named through /var or /private/var.
        let canonical = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let written = Set(tuning.files.map { canonical($0.path) })
        return adapters.contains { adapter in
            tuning.parts.contains(adapter.id) && adapter.files(for: game, bottle: bottle).contains { file in
                !written.contains(canonical(file.path)) && FileManager.default.fileExists(atPath: file.path)
            }
        }
    }

    public func restore(_ tuning: GameTuning, for game: Game) {
        let fm = FileManager.default
        let folder = backupFolder(for: game)
        for file in tuning.files {
            let url = URL(fileURLWithPath: file.path)
            if let backup = file.backup {
                let copy = folder.appendingPathComponent(backup)
                guard fm.fileExists(atPath: copy.path) else { continue }
                try? fm.removeItem(at: url)
                try? fm.copyItem(at: copy, to: url)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        try? fm.removeItem(at: folder)
    }

    /// Steam's Auto-Cloud leaves `steam_autocloud.vdf` in the folders it syncs.
    static func syncedByCloud(_ file: URL) -> Bool {
        var folder = file.deletingLastPathComponent()
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("steam_autocloud.vdf").path) { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }
}

/// Minimal editing of INI-style files (`[Section]` then `Key=Value`), keeping everything else as it was.
public enum IniFile {
    public static func setting(_ values: [(section: String, key: String, value: String)], in text: String?) -> String {
        var lines = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let crlf = text?.contains("\r\n") ?? false
        for (section, key, value) in values {
            let header = "[\(section)]"
            var start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(header) == .orderedSame }
            if start == nil {
                if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
                lines.append(header)
                start = lines.count - 1
            }
            var end = start! + 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
            let entry = "\(key)=\(value)"
            if let i = (start! + 1 ..< end).first(where: {
                let parts = lines[$0].split(separator: "=", maxSplits: 1)
                return parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(key) == .orderedSame
            }) {
                lines[i] = entry
            } else {
                var at = end
                while at > start! + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                lines.insert(entry, at: at)
            }
        }
        return lines.joined(separator: crlf ? "\r\n" : "\n") + (crlf ? "\r\n" : "\n")
    }

    /// The text without these keys of the section; the section's header goes too when nothing is left under it.
    /// Nil when none of them is there.
    public static func removing(section: String, keys: [String], from text: String) -> String? {
        let crlf = text.contains("\r\n")
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let header = "[\(section)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(header) == .orderedSame }) else { return nil }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
        let drop = (start + 1 ..< end).filter { i in
            let parts = lines[i].split(separator: "=", maxSplits: 1)
            return parts.count == 2 && keys.contains { $0.caseInsensitiveCompare(parts[0].trimmingCharacters(in: .whitespaces)) == .orderedSame }
        }
        guard !drop.isEmpty else { return nil }
        for i in drop.reversed() { lines.remove(at: i) }
        end -= drop.count
        if (start + 1 ..< end).allSatisfy({ lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }) { lines.removeSubrange(start ..< end) }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: crlf ? "\r\n" : "\n") + (crlf ? "\r\n" : "\n")
    }

    /// Every `key=value` of the text with its section (keys before any section have "").
    public static func entries(_ text: String) -> [(section: String, key: String, value: String)] {
        var section = "", out: [(section: String, key: String, value: String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            guard !line.hasPrefix(";"), !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out.append((section, line[..<eq].trimmingCharacters(in: .whitespaces), String(line[line.index(after: eq)...])))
        }
        return out
    }

    public static func value(section: String, key: String, in text: String) -> String? {
        entries(text).last { $0.section.caseInsensitiveCompare(section) == .orderedSame && $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// A field of the struct value a key holds (`Key=(a=1,Field=0)` → "0").
    public static func fieldValue(section: String, key: String, field: String, in text: String) -> String? {
        guard let value = value(section: section, key: key, in: text),
              let regex = try? NSRegularExpression(pattern: #"(?<=[(,])"# + NSRegularExpression.escapedPattern(for: field) + #"=([^,)]*)"#, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let r = Range(m.range(at: 1), in: value) else { return nil }
        return String(value[r])
    }
}
