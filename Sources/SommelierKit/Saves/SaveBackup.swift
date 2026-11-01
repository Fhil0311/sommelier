// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a save backup or restore didn't happen. The messages are shown to the user as they are.
public enum SaveBackupError: Equatable, LocalizedError {
    case noSources, nothingToBackUp, destinationUnavailable, unsafeBackup, copyFailed(String)

    public var errorDescription: String? { userMessage }

    private var userMessage: String {
        switch self {
        case .noSources:
            return "Choose which folders hold this game's saves first."
        case .nothingToBackUp:
            return "None of the save folders exist yet. Play the game and save, then try again."
        case .destinationUnavailable:
            return "The backup folder isn't available. Choose a folder in Settings > Pro."
        case .unsafeBackup:
            return "This backup isn't valid, so it wasn't restored."
        case .copyFailed(let reason):
            return "Couldn't copy the saves: " + reason
        }
    }
}

/// `manifest.json` inside each backup folder: which save folders it holds and where they came from.
/// The JSON keys and the `format` number are part of the on-disk layout and must not change.
struct SaveManifest: Equatable, Codable {
    /// One copied save folder. `folder` names its copy under `data/` and is always a number ("0", "1", ...).
    struct Entry: Equatable, Codable {
        var root: SaveRoot, path: String
        var folder: String, files: Int, bytes: Int64
    }

    /// Version of this layout. Restore only accepts 1.
    var format = 1
    var gameID: String, gameTitle: String
    var created: Date, kind: SaveBackupInfo.Kind
    var entries: [Entry] = []

    var sources: [SaveSource] { entries.map { SaveSource(root: $0.root, path: $0.path) } }
}

/// A backup as the UI lists it.
public struct SaveBackupInfo: Equatable, Identifiable, Sendable {
    /// Who made the backup. `beforeRestore` is taken automatically right before a restore replaces the saves
    /// that were there.
    public enum Kind: String, Sendable, Codable {
        case manual, automatic, beforeRestore
    }

    public var folder: URL, gameID: String, gameTitle: String
    public var created: Date, kind: Kind
    public var sources: [SaveSource], files: Int, bytes: Int64

    /// The backup folder's name (its timestamp).
    public var id: String { self.folder.lastPathComponent }
}

/// Keeps copies of a game's save folders in a folder of the user's choice (iCloud Drive by default).
///
/// On disk: `<destination>/Sommelier Saves/<title> (<store>-<id>)/<yyyyMMdd-HHmmss>/` holding `manifest.json`
/// and `data/<n>/`, one numbered folder per save source. They are ordinary folders a person can browse in
/// Finder. Symbolic links in saves are never followed or copied. A restore only adds and replaces files, never
/// deletes, and first copies the current saves into a `beforeRestore` backup.
public struct SaveBackupStore: Equatable, Sendable {
    public static let folderName = "Sommelier Saves"

    public let destination: URL // the folder that holds `Sommelier Saves`
    /// Backups kept per game; older ones are deleted after each new backup or restore.
    public var maximumBackups: Int = 20

    public init(destination folder: URL) { destination = folder }

    /// The iCloud Drive folder, or nil when iCloud Drive is off on this Mac.
    public static var iCloudDrive: URL? { FileScan.isDirectory(cloudDocs) ? cloudDocs : nil }

    private static var cloudDocs: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// `Sommelier Saves` inside the destination.
    public var root: URL { destination.appendingPathComponent(SaveBackupStore.folderName, isDirectory: true) }

    // MARK: Backing up

    /// Copies the existing save folders into a new backup and drops the oldest ones beyond the limit.
    @discardableResult public func create(
        gameID: String, title: String, sources: [SaveSource], roots: SaveRoots,
        kind: SaveBackupInfo.Kind = .manual, now: Date = Date()
    ) throws -> SaveBackupInfo {
        let made = try snapshot(gameID: gameID, title: title, sources: sources, roots: roots, kind: kind, at: now)
        prune(made.folder.deletingLastPathComponent())
        return made
    }

    /// Writes one backup without pruning. The copy is built in a hidden `.partial-` folder and renamed into
    /// place only when complete, so a failure never leaves a half backup that looks real.
    private func snapshot(gameID: String, title: String, sources: [SaveSource], roots: SaveRoots,
                          kind: SaveBackupInfo.Kind, at now: Date) throws -> SaveBackupInfo {
        if sources.isEmpty { throw SaveBackupError.noSources }
        if !FileScan.isDirectory(destination) { throw SaveBackupError.destinationUnavailable }
        let existing: [(source: SaveSource, folder: URL)] = sources.compactMap { source in
            guard let folder = roots.resolve(source), FileScan.isDirectory(folder) else { return nil }
            return (source, folder)
        }
        if existing.isEmpty { throw SaveBackupError.nothingToBackUp }

        let disk = FileManager.default
        var staging: URL?
        do {
            let gameDir = try folder(for: gameID, title: title, create: true)
            let name = freshName(in: gameDir, at: now)
            let work = gameDir.appendingPathComponent(".partial-" + name, isDirectory: true)
            staging = work
            try? disk.removeItem(at: work)
            let data = work.appendingPathComponent("data", isDirectory: true)
            try disk.createDirectory(at: data, withIntermediateDirectories: true)

            var copied = SaveManifest(gameID: gameID, gameTitle: title, created: now, kind: kind)
            for (number, item) in existing.enumerated() {
                let slot = String(number)
                let tally = try Self.copyTree(from: item.folder, to: data.appendingPathComponent(slot, isDirectory: true))
                copied.entries.append(.init(root: item.source.root, path: item.source.path, folder: slot,
                                            files: tally.files, bytes: tally.bytes))
            }
            try Self.jsonWriter().encode(copied).write(to: work.appendingPathComponent("manifest.json"), options: .atomic)

            let finished = gameDir.appendingPathComponent(name, isDirectory: true)
            try disk.moveItem(at: work, to: finished)
            return Self.info(copied, folder: finished)
        } catch {
            if let staging { try? disk.removeItem(at: staging) }
            throw (error as? SaveBackupError) ?? .copyFailed(error.localizedDescription)
        }
    }

    // MARK: Listing

    /// The game's backups, newest first.
    public func list(
        gameID: String, title: String
    ) -> [SaveBackupInfo] {
        guard let gameDir = try? folder(for: gameID, title: title, create: false) else { return [] }
        return Self.backups(in: gameDir)
    }

    /// Every readable backup in a game folder, newest first. Hidden entries (unfinished copies) are ignored.
    private static func backups(in gameDir: URL) -> [SaveBackupInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: gameDir.path)) ?? []
        let found = names.filter { !$0.hasPrefix(".") }.compactMap { read(gameDir.appendingPathComponent($0, isDirectory: true)) }
        return found.sorted { lhs, rhs in lhs.created > rhs.created }
    }

    /// Deletes all but the newest `maximumBackups` backups.
    private func prune(_ gameDir: URL) {
        for stale in Self.backups(in: gameDir).dropFirst(maximumBackups) {
            try? FileManager.default.removeItem(at: stale.folder)
        }
    }

    // MARK: Restoring

    /// What a restore did: how many files were written, and the backup of the saves that were there before
    /// (nil when there were none).
    public struct RestoreReport: Sendable, Equatable {
        public var files: Int, safetyBackup: SaveBackupInfo?
    }

    /// Copies a backup back over the game's save folders.
    ///
    /// The manifest is checked in full before anything is written: every target must resolve to a safe place
    /// inside its root and every copy must be a real folder. If the current saves can't be backed up first
    /// (disk gone, disk full), the restore stops without touching them.
    @discardableResult public func restore(
        _ backup: SaveBackupInfo, roots: SaveRoots, now: Date = Date()
    ) throws -> RestoreReport {
        guard let manifest = Self.readManifest(backup.folder), manifest.format == 1 else {
            throw SaveBackupError.unsafeBackup
        }
        let data = backup.folder.appendingPathComponent("data", isDirectory: true)
        let steps: [(copy: URL, target: URL)] = try manifest.entries.map { entry in
            let copy = data.appendingPathComponent(entry.folder, isDirectory: true)
            let numbered = Int(entry.folder) != nil
            guard numbered, let target = roots.resolve(SaveSource(root: entry.root, path: entry.path)),
                  FileScan.isDirectory(copy) else { throw SaveBackupError.unsafeBackup }
            return (copy, target)
        }

        let sources = manifest.sources
        let hasSavesNow = sources.contains { roots.resolve($0).map(FileScan.isDirectory) == true }
        // Pruning waits until the copy is done: otherwise restoring the oldest kept backup could delete it
        // to make room for its own safety copy.
        let safety = hasSavesNow
            ? try snapshot(gameID: manifest.gameID, title: manifest.gameTitle, sources: sources, roots: roots,
                           kind: .beforeRestore, at: now)
            : nil

        var restored = 0
        do {
            for step in steps {
                restored += try Self.copyTree(from: step.copy, to: step.target, overwrite: true).files
            }
        } catch {
            throw (error as? SaveBackupError) ?? .copyFailed(error.localizedDescription)
        }

        if let gameDir = try? folder(for: manifest.gameID, title: manifest.gameTitle, create: false) { prune(gameDir) }
        return RestoreReport(files: restored, safetyBackup: safety)
    }

    // MARK: Change check

    /// Whether any save file was modified after `date`, so an automatic backup can be skipped when not.
    public static func hasChanges(
        sources: [SaveSource], roots: SaveRoots, since date: Date
    ) -> Bool {
        sources.contains { item in
            guard let folder = roots.resolve(item), FileScan.isDirectory(folder),
                  let newest = FileScan.measure(folder).newest else { return false }
            return newest > date
        }
    }

    // MARK: Naming

    /// The game's folder under `Sommelier Saves`. An existing folder is found by the id in brackets, so
    /// renaming a game (or the folder) keeps its backups together.
    func folder(
        for gameID: String, title: String, create: Bool
    ) throws -> URL {
        let tag = "(" + Self.safeID(gameID) + ")"
        let present = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if let match = present.first(where: { $0.hasSuffix(tag) }) {
            return root.appendingPathComponent(match, isDirectory: true)
        }
        let fresh = root.appendingPathComponent(Self.safeTitle(title) + " " + tag, isDirectory: true)
        if create { try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true) }
        return fresh
    }

    /// A game id usable in a file name: letters, digits, `-`, `_` and `.` stay, anything else becomes `-`.
    static func safeID(
        _ id: String
    ) -> String {
        String(id.map { char -> Character in
            char.isLetter || char.isNumber || "-_.".contains(char) ? char : "-"
        })
    }

    /// A title usable as a file name on macOS and Windows: reserved characters and control characters become
    /// `-`, surrounding spaces go, and it is cut to 60 characters. An empty result becomes "Game".
    static func safeTitle(
        _ title: String
    ) -> String {
        let reserved = Set(#"/\:*?"<>|"#.unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            scalars.append(reserved.contains(scalar) || scalar.value < 32 ? "-" : scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        return String((trimmed.isEmpty ? "Game" : trimmed).prefix(60))
    }

    /// A timestamp name for a new backup, with `-2`, `-3`, ... added if one already exists.
    private func freshName(in gameDir: URL, at now: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = stamp.string(from: now)
        var candidate = base
        var counter = 1
        while FileManager.default.fileExists(atPath: gameDir.appendingPathComponent(candidate).path) {
            counter += 1
            candidate = base + "-" + String(counter)
        }
        return candidate
    }

    // MARK: Manifest

    /// Pretty-printed with sorted keys and ISO 8601 dates, the format existing manifests are in.
    private static func jsonWriter() -> JSONEncoder {
        let writer = JSONEncoder()
        writer.outputFormatting = [.sortedKeys, .prettyPrinted]
        writer.dateEncodingStrategy = .iso8601
        return writer
    }

    /// The manifest in a backup folder, or nil if it is missing or unreadable.
    static func readManifest(
        _ folder: URL
    ) -> SaveManifest? {
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            .flatMap { try? reader.decode(SaveManifest.self, from: $0) }
    }

    /// A backup folder as `SaveBackupInfo`, or nil if it isn't one.
    static func read(
        _ folder: URL
    ) -> SaveBackupInfo? {
        guard let manifest = readManifest(folder) else { return nil }
        return info(manifest, folder: folder)
    }

    static func info(
        _ manifest: SaveManifest, folder: URL
    ) -> SaveBackupInfo {
        SaveBackupInfo(folder: folder, gameID: manifest.gameID, gameTitle: manifest.gameTitle,
                       created: manifest.created, kind: manifest.kind, sources: manifest.sources,
                       files: manifest.entries.map(\.files).reduce(0, +),
                       bytes: manifest.entries.map(\.bytes).reduce(0, +))
    }

    // MARK: Copying

    /// Copies the regular files of a folder tree, keeping their modification dates. Links and `.DS_Store`
    /// are left out. Writing through a link at the target is refused. Without `overwrite` an existing file
    /// is an error; with it, an existing regular file is replaced. A folder is never deleted to make room
    /// for a file.
    @discardableResult static func copyTree(
        from source: URL, to target: URL, overwrite: Bool = false
    ) throws -> (files: Int, bytes: Int64) {
        var tally: (files: Int, bytes: Int64) = (0, 0)
        try copyFolder(source, into: target, overwrite: overwrite, tally: &tally)
        return tally
    }

    private static func copyFolder(_ origin: URL, into dest: URL, overwrite: Bool,
                                   tally: inout (files: Int, bytes: Int64)) throws {
        let disk = FileManager.default
        try disk.createDirectory(at: dest, withIntermediateDirectories: true)
        for entry in try disk.contentsOfDirectory(atPath: origin.path) where entry != ".DS_Store" {
            let src = origin.appendingPathComponent(entry)
            let dst = dest.appendingPathComponent(entry)
            guard let info = FileScan.attributes(src) else { continue }
            let type = info[.type] as? FileAttributeType
            let isFolder = type == .typeDirectory
            guard isFolder || type == .typeRegular else { continue }
            if FileScan.isSymlink(dst) { throw SaveBackupError.unsafeBackup }

            if isFolder {
                try copyFolder(src, into: dst, overwrite: overwrite, tally: &tally)
                continue
            }
            if disk.fileExists(atPath: dst.path) {
                guard overwrite, FileScan.isRegularFile(dst) else { throw SaveBackupError.copyFailed(entry) }
                try disk.removeItem(at: dst)
            }
            try disk.copyItem(at: src, to: dst)
            if let stamp = info[.modificationDate] as? Date {
                try? disk.setAttributes([.modificationDate: stamp], ofItemAtPath: dst.path)
            }
            tally.files += 1
            tally.bytes += (info[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}
