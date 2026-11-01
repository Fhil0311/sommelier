// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A well-known Windows folder that save locations are anchored to. Saves are always remembered relative to
/// one of these, so a backup fits any bottle and an edited backup can't reach outside of it.
public enum SaveRoot: String, CaseIterable, Codable, Sendable {
    // The raw values are stored in manifests and the library; never rename them.
    case documents, roaming, local, localLow, savedGames
    case steamUserdata, install
    /// The Mac user's home folder: where the Mac version of a game keeps its saves (`~/.config/StardewValley`).
    case home

    /// The folder's place inside the Windows user profile, or nil for the roots that live elsewhere.
    var profileSubpath: String? {
        switch self {
        case .documents: return "Documents"
        case .roaming: return "AppData/Roaming"
        case .local: return "AppData/Local"
        case .localLow: return "AppData/LocalLow"
        case .savedGames: return "Saved Games"
        case .steamUserdata, .install, .home: return nil
        }
    }

    /// The name people see, written the way Windows shows it.
    public var title: String {
        if let sub = profileSubpath { return Self.windowsStyle(sub) }
        switch self {
        case .install: return "Game folder"
        case .home: return "Home folder"
        default: return "Steam Cloud"
        }
    }

    private static func windowsStyle(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "\\") }
}

/// One folder that holds saves: a root and a "/"-separated relative path below it.
public struct SaveSource: Hashable, Codable, Identifiable, Sendable {
    public var root: SaveRoot, path: String

    public init(root base: SaveRoot, path relative: String) {
        (root, path) = (base, relative)
    }

    public var id: String { root.rawValue + "/" + path }

    /// Windows-style location for the UI, e.g. `AppData\Roaming\Studio\Game`; a Mac folder keeps its slashes.
    public var displayPath: String {
        let separator = root == .home ? "/" : "\\"
        return path.split(separator: "/").reduce(root.title) { "\($0)\(separator)\($1)" }
    }

    /// A relative path is acceptable only if every part is a real name: nothing empty, no `.` or `..`,
    /// no leading slash and no NUL byte.
    public static func isSafe(_ candidate: String) -> Bool {
        if candidate.isEmpty || candidate.hasPrefix("/") || candidate.contains("\0") { return false }
        return !candidate.components(separatedBy: "/").contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

/// The actual folders behind each `SaveRoot` for one bottle and game.
public struct SaveRoots: Equatable, Sendable {
    /// The Windows user profile (`drive_c/users/<name>`), Steam's `userdata` folder and the game's own folder.
    public let profile: URL, steamUserdata: URL?, install: URL?
    /// The Mac user's home folder, for the Mac version of a game.
    public let home: URL

    /// After `UserProfiles.unify` the Windows profile is the folder named after the Mac user, and `crossover`
    /// only points at it. Bottles that were never unified have just `crossover`, so that is the fallback.
    public init(
        bottle: Bottle, installPath: URL?, userName: String = NSUserName()
    ) {
        let usersDir = bottle.driveC.appendingPathComponent("users", isDirectory: true)
        let ownProfile = usersDir.appendingPathComponent(userName, isDirectory: true)
        var folder: ObjCBool = false
        let unified = FileManager.default.fileExists(atPath: ownProfile.path, isDirectory: &folder) && folder.boolValue
        self.init(profile: unified ? ownProfile : usersDir.appendingPathComponent(UserProfiles.crossOverName, isDirectory: true),
                  steamUserdata: bottle.steamDirectory.appendingPathComponent("userdata", isDirectory: true),
                  install: installPath)
    }

    /// Direct form, handy in tests. `home` is the Mac user's home folder unless a test gives another.
    public init(profile windowsHome: URL, steamUserdata cloud: URL? = nil, install game: URL? = nil,
                home macHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        (profile, steamUserdata, install, home) = (windowsHome, cloud, game, macHome)
    }

    /// The folder a root stands for, as written (links not resolved).
    public func base(_ which: SaveRoot) -> URL? {
        if let sub = which.profileSubpath { return profile.appendingPathComponent(sub, isDirectory: true) }
        switch which {
        case .install: return install
        case .home: return home
        default: return steamUserdata
        }
    }

    /// Like `base`, with links followed. Wine points Documents at the Mac's real Documents folder, which is
    /// where those files actually live.
    func resolvedBase(_ which: SaveRoot) -> URL? {
        base(which).map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Where a save source lives on disk. Returns nil when the path is unsafe or any step below the base is a
    /// link, so a backup can never be written through one. The folder itself need not exist yet.
    public func resolve(_ wanted: SaveSource) -> URL? {
        guard SaveSource.isSafe(wanted.path), let top = resolvedBase(wanted.root) else { return nil }
        var cursor = top
        for component in wanted.path.split(separator: "/") {
            cursor = cursor.appendingPathComponent(String(component), isDirectory: true)
            guard !FileScan.isSymlink(cursor) else { return nil }
        }
        let result = cursor.standardizedFileURL
        return result.path.hasPrefix(top.path + "/") ? result : nil
    }

    /// Turns a folder the user picked into a source, anchored to the most specific root that contains it.
    public func source(for picked: URL) -> SaveSource? {
        let target = picked.resolvingSymlinksInPath().standardizedFileURL.path
        // The home folder holds everything else too, so a folder is never anchored to it by guessing: only a
        // profile from the service names a `home` source.
        let containing = SaveRoot.allCases.filter { $0 != .home }.compactMap { root -> (root: SaveRoot, prefix: String)? in
            guard let prefix = resolvedBase(root)?.path, target.hasPrefix(prefix + "/") else { return nil }
            return (root, prefix)
        }
        // On equal length the earlier root wins, because `max(by:)` keeps the first of equal elements.
        guard let deepest = containing.max(by: { $0.prefix.count < $1.prefix.count }) else { return nil }
        let rest = String(target.dropFirst(deepest.prefix.count + 1))
        guard SaveSource.isSafe(rest) else { return nil }
        return SaveSource(root: deepest.root, path: rest)
    }
}

/// File-system helpers for save folders. Nothing here follows symbolic links.
enum FileScan {
    /// Totals for a folder tree. `truncated` means the entry budget ran out before the walk finished.
    struct Measure: Equatable, Sendable {
        var bytes: Int64 = 0, files = 0
        var newest: Date?, truncated = false
    }

    /// Attributes of the item itself (a link is reported as a link).
    static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func kind(_ url: URL) -> FileAttributeType? { attributes(url)?[.type] as? FileAttributeType }
    static func isSymlink(_ url: URL) -> Bool { kind(url) == .typeSymbolicLink }
    static func isDirectory(_ url: URL) -> Bool { kind(url) == .typeDirectory }
    static func isRegularFile(_ url: URL) -> Bool { kind(url) == .typeRegular }

    /// Adds up regular files below `top`. At most `limit` entries are looked at, so a huge folder (or the
    /// Mac's Documents) can't stall the app.
    static func measure(_ top: URL, limit: Int = 20_000) -> Measure {
        var total = Measure()
        var visited = 0
        var pending = [top]
        while let dir = pending.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                visited += 1
                guard visited <= limit else {
                    total.truncated = true
                    return total
                }
                let item = dir.appendingPathComponent(name)
                guard let info = attributes(item) else { continue }
                switch info[.type] as? FileAttributeType {
                case FileAttributeType.typeDirectory?:
                    pending.append(item)
                case FileAttributeType.typeRegular?:
                    total.files += 1
                    total.bytes += (info[.size] as? NSNumber)?.int64Value ?? 0
                    if let stamp = info[.modificationDate] as? Date { total.newest = max(total.newest ?? stamp, stamp) }
                default:
                    break
                }
            }
        }
        return total
    }
}
