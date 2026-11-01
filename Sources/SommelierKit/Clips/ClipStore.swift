// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One saved clip: an ordinary MP4 with a small JSON note beside it (`<name>.json`) saying where it came from.
/// The list is the folder itself, so clips can be moved or deleted in Finder.
public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable { case key, controller, crash }

    /// The file's name without the extension, unique in its folder.
    public var id: String
    public var gameID: String
    public var gameTitle: String
    public var date: Date
    public var seconds: Double
    public var origin: Origin
    public var hasSound: Bool
    public var favorite: Bool
    /// "Normal · 1440p, 60 fps": what it was recorded at.
    public var quality: String
    public var name: String?
    /// The file's size in bytes, read from the disk (not stored in the note).
    public var bytes: Int = 0
    /// The file, set when the clip is read from a folder.
    public var url: URL?

    public init(id: String, gameID: String, gameTitle: String, date: Date, seconds: Double, origin: Origin, hasSound: Bool,
                favorite: Bool = false, quality: String, name: String? = nil) {
        self.id = id; self.gameID = gameID; self.gameTitle = gameTitle; self.date = date; self.seconds = seconds
        self.origin = origin; self.hasSound = hasSound; self.favorite = favorite; self.quality = quality; self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, gameID, gameTitle, date, seconds, origin, hasSound, favorite, quality, name }

    /// Clips the player saved by hand stay until deleted; automatic ones make room for new ones.
    public var isAutomatic: Bool { origin == .crash }
}

/// The folder of clips (`~/Movies/Sommelier Clips`, `Sommelier Dev Clips` for the development build).
public struct ClipStore: Sendable {
    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    public static func standardFolder(development: Bool = BuildFlavor.isDevelopment) -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent(development ? "Sommelier Dev Clips" : "Sommelier Clips", isDirectory: true)
    }

    // MARK: Names

    /// A clip's place: `<folder>/<game>/<game> 2026-10-26 19.12.04.mp4` (the game's name made safe for a file name).
    public func newURL(game title: String, at date: Date, calendar: Calendar = .current) -> URL {
        let safe = Self.safeName(title)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let directory = folder.appendingPathComponent(safe, isDirectory: true)
        var url = directory.appendingPathComponent("\(safe) \(stamp).mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(safe) \(stamp) \(n).mp4"); n += 1
        }
        return url
    }

    public static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters)
        var name = title.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        name = String(name.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? "Game" : name
    }

    static func noteURL(for video: URL) -> URL { video.deletingPathExtension().appendingPathExtension("json") }

    // MARK: Reading and writing

    public func save(_ clip: Clip, for video: URL) {
        var note = clip
        note.url = nil
        let writer = JSONEncoder()
        writer.dateEncodingStrategy = .iso8601
        writer.outputFormatting = [.sortedKeys]
        if let data = try? writer.encode(note) { try? data.write(to: Self.noteURL(for: video), options: .atomic) }
    }

    /// Every clip in the folder, newest first. A video without a note (put there by hand) is listed with what the
    /// file itself says: the game's folder name and the modification date.
    public func clips() -> [Clip] {
        let manager = FileManager.default
        guard let games = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        var found: [Clip] = []
        for directory in games {
            guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for video in files where video.pathExtension.lowercased() == "mp4" {
                let values = try? video.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                var clip: Clip
                if let data = try? Data(contentsOf: Self.noteURL(for: video)), let note = try? reader.decode(Clip.self, from: data) {
                    clip = note
                } else {
                    clip = Clip(id: video.deletingPathExtension().lastPathComponent, gameID: "", gameTitle: directory.lastPathComponent,
                                date: values?.contentModificationDate ?? Date(), seconds: 0, origin: .key, hasSound: true, quality: "")
                }
                clip.id = video.deletingPathExtension().lastPathComponent
                clip.bytes = values?.fileSize ?? 0
                clip.url = video
                found.append(clip)
            }
        }
        return found.sorted { $0.date > $1.date }
    }

    public func setFavorite(_ on: Bool, for clip: Clip) {
        guard let url = clip.url else { return }
        var note = clip; note.favorite = on
        save(note, for: url)
    }

    public func rename(_ clip: Clip, to name: String) {
        guard let url = clip.url else { return }
        var note = clip
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        note.name = trimmed.isEmpty || trimmed == clip.gameTitle ? nil : trimmed
        save(note, for: url)
    }

    /// Removes the video and its note.
    public func delete(_ clip: Clip) {
        guard let url = clip.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.noteURL(for: url))
    }

    // MARK: Room

    public static func totalBytes(_ clips: [Clip]) -> Int { clips.reduce(0) { $0 + $1.bytes } }

    /// The automatic clips to remove so the rest fit in `limitBytes`, oldest first. Favorites and clips saved by
    /// hand are never in it.
    public static func clipsToRemove(from clips: [Clip], limitBytes: Int) -> [Clip] {
        let automatic = clips.filter { $0.isAutomatic }.sorted { $0.date < $1.date }
        var total = automatic.reduce(0) { $0 + $1.bytes }
        var removing: [Clip] = []
        for clip in automatic where total > limitBytes {
            if clip.favorite { continue }
            removing.append(clip); total -= clip.bytes
        }
        return removing
    }

    /// What a clip needs free on the disk before it is written: the least the player is told ("at least 2 GB").
    public static let freeSpaceNeeded: Int64 = 2_000_000_000

    public func freeSpace() -> Int64? {
        let probe = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The video sizes a clip is trimmed to: cut points on whole key-frame steps of two seconds.
    public static func snapped(_ time: Double, step: Double = 2, duration: Double) -> Double {
        min(max((time / step).rounded() * step, 0), duration)
    }
}
