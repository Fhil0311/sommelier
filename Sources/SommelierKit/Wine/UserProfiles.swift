// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keeps one Windows user profile per bottle.
///
/// Engines built from CrossOver always put the profile in `C:\users\crossover`, whatever the Mac user is called;
/// stock Wine uses the Mac user's name. A bottle run by both ends up with AppData (and saves) split in two.
/// `unify` folds `crossover` into the named profile and leaves a relative link in its place. It never deletes a
/// file: when both sides have one, the older copy goes to `<bottle>/profile-backups/<timestamp>/`.
/// Run it only while the bottle is idle.
public enum UserProfiles {
    /// The profile folder CrossOver-based engines use.
    public static let crossOverName = "crossover"

    /// What `unify` did, by path relative to the profile.
    public struct Report: Equatable, Sendable {
        /// Items moved into the real profile.
        public var moved: [String] = []
        /// Items put in `backupFolder` because the real profile already had a (newer) copy.
        public var keptAside: [String] = []
        /// `crossover` is now a link to the real profile.
        public var linked = false
        /// Set only when something was kept aside.
        public var backupFolder: URL?
    }

    /// Merges `C:\users\crossover` into `C:\users\<userName>` and links it there. Does nothing when there is no
    /// real profile folder, when `userName` is itself `crossover`, or when `crossover` is already a link (ours or
    /// anyone's).
    @discardableResult public static func unify(bottle: URL, userName: String, now: Date = Date()) throws -> Report {
        let profiles = bottle.appendingPathComponent("drive_c/users")
        let target = profiles.appendingPathComponent(userName)
        let shared = profiles.appendingPathComponent(crossOverName)
        guard !userName.isEmpty, userName != crossOverName, case .folder = Entry(target) else { return Report() }

        var merger = Merger(backup: bottle.appendingPathComponent("profile-backups/\(stamp(now))", isDirectory: true))
        switch Entry(shared) {
        case .link:
            return Report()
        case .missing:
            break
        default:
            try merger.fold(shared, into: target, at: "")
            try FileManager.default.removeItem(at: shared)        // emptied by the fold
            if !merger.report.keptAside.isEmpty { merger.report.backupFolder = merger.backup }
        }
        // A relative link keeps working if the bottle is moved.
        try FileManager.default.createSymbolicLink(atPath: shared.path, withDestinationPath: userName)
        merger.report.linked = true
        return merger.report
    }

    /// The backup folder's name: local time, second precision.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// One directory entry, looked at without following links (Wine links profile folders to the Mac's own).
    private enum Entry {
        case missing, link, folder
        case file(modified: Date)

        init(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { self = .missing; return }
            switch info.st_mode & S_IFMT {
            case S_IFLNK: self = .link
            case S_IFDIR: self = .folder
            default:
                let time = info.st_mtimespec
                self = .file(modified: Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9))
            }
        }
    }

    /// Moves a profile tree into another one item by item, recording what happened.
    private struct Merger {
        let backup: URL
        var report: Report = .init()

        mutating func fold(_ source: URL, into destination: URL, at relative: String) throws {
            let files = FileManager.default
            for name in try files.contentsOfDirectory(atPath: source.path) {
                let item = source.appendingPathComponent(name)
                let counterpart = destination.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                switch (Entry(item), Entry(counterpart)) {
                case (_, .missing):
                    try files.moveItem(at: item, to: counterpart)
                    report.moved.append(path)
                case (.link, .link) where Self.sameTarget(item, counterpart):
                    try files.removeItem(at: item)                      // the same Wine link on both sides
                case (.link, _), (_, .link):
                    try setAside(item, as: path)                     // never write through a link into Mac folders
                case (.folder, .folder):
                    try fold(item, into: counterpart, at: path)
                    try files.removeItem(at: item)
                case let (.file(incoming), .file(existing)) where incoming > existing:
                    try setAside(counterpart, as: path)                       // newer copy takes the place, older is kept
                    try files.moveItem(at: item, to: counterpart)
                    report.moved.append(path)
                default:
                    try setAside(item, as: path)
                }
            }
        }

        private mutating func setAside(_ item: URL, as path: String) throws {
            let place = backup.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: place.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: item, to: place)
            report.keptAside.append(path)
        }

        private static func sameTarget(_ a: URL, _ b: URL) -> Bool {
            func target(_ link: URL) -> String? { try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) }
            return target(a) == target(b)
        }
    }
}
