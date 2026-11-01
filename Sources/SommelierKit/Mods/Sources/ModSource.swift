// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a source couldn't answer. Reasons only; the app words them.
public enum ModSourceError: Error, Equatable {
    /// The service has no key for this source yet (the Worker answered 503).
    case notConfigured
    /// No such game, mod or file at the source.
    case notFound
    /// The source's limit for today is used up (429).
    case rateLimited
    /// The link the source gave has run out; ask for a fresh one.
    case linkExpired
    /// Anything else, with what went wrong.
    case failed(String)
    /// The answer wasn't what the source promises.
    case badAnswer
}

/// A mod as a source lists it: enough for its card and for the install, nothing the page would need.
public struct ModCard: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var summary: String
    public var author: String?
    public var version: String?
    public var updated: Date?
    public var thumbnail: URL?
    /// The mod's own page at the source, kept with the mod for its card.
    public var page: URL?
    public var downloads: Int?
    /// The file to install when the source names one with the mod (its current release).
    public var file: ModFileRef?
    /// The id of the file to install when the source keeps one per platform and it isn't `file`.
    public var installFileID: Int?
    public var tags: [String]

    public init(id: Int, name: String, summary: String = "", author: String? = nil, version: String? = nil, updated: Date? = nil,
                thumbnail: URL? = nil, page: URL? = nil, downloads: Int? = nil, file: ModFileRef? = nil, installFileID: Int? = nil,
                tags: [String] = []) {
        self.id = id; self.name = name; self.summary = summary; self.author = author; self.version = version; self.updated = updated
        self.thumbnail = thumbnail; self.page = page; self.downloads = downloads; self.file = file; self.installFileID = installFileID
        self.tags = tags
    }

    /// The file an install takes: the platform's live one, else the mod's current release.
    public var fileToInstall: Int? { installFileID ?? file?.id }
}

/// One of a mod's files at the source.
public struct ModFileRef: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var version: String?
    public var bytes: Int64
    public var added: Date?

    public init(id: Int, name: String, version: String? = nil, bytes: Int64 = 0, added: Date? = nil) {
        self.id = id; self.name = name; self.version = version; self.bytes = bytes; self.added = added
    }
}

/// One page of a search: the cards and how many there are in all.
public struct ModPage: Equatable, Sendable {
    public var cards: [ModCard]
    public var total: Int
    public var offset: Int

    public init(cards: [ModCard], total: Int, offset: Int = 0) { self.cards = cards; self.total = total; self.offset = offset }
}

/// Where a file can be fetched from, for a while.
public struct ModDownloadLink: Equatable, Sendable {
    public var url: URL
    public var fileName: String
    public var expires: Date?

    public init(url: URL, fileName: String, expires: Date? = nil) { self.url = url; self.fileName = fileName; self.expires = expires }

    public func isValid(now: Date = Date()) -> Bool { expires.map { $0 > now } ?? true }
}

/// Where a game's mods come from, seen the same way whatever it is: a catalogue (mod.io through our Worker) or
/// the player's own archives. Search, a mod's card and files, a link to fetch a file and the fetch itself.
/// Nexus has no such face: it is a browser session the app owns, and what comes out of it is a local file.
public protocol ModSource: Sendable {
    /// How a mod from here is recorded in the store.
    var kind: StoredMod.Origin.Kind { get }
    /// Mods matching `query` (every mod when it is empty), a page at a time.
    func search(_ query: String, offset: Int, limit: Int) async throws -> ModPage
    func card(_ id: Int) async throws -> ModCard
    func files(of modID: Int) async throws -> [ModFileRef]
    /// A link for one of a mod's files; a source's links can be short-lived.
    func link(for fileID: Int, of modID: Int) async throws -> ModDownloadLink
    /// The file as a local archive inside `folder` (a fresh folder the caller removes afterwards).
    func download(_ link: ModDownloadLink, into folder: URL) async throws -> URL
}

extension ModSource {
    /// The record a mod from this source keeps of where it came from.
    public func origin(for card: ModCard, file: ModFileRef?) -> StoredMod.Origin {
        StoredMod.Origin(kind: kind, url: card.page?.absoluteString, modID: card.id, fileID: file?.id ?? card.fileToInstall)
    }

    /// The mods from this source whose current file at the source is newer than the one installed, by store key.
    /// A mod the source no longer lists, or one that came from elsewhere, is left out.
    public func updates(for mods: [StoredMod]) async -> [String: ModFileRef] {
        var found: [String: ModFileRef] = [:]
        for mod in mods where mod.origin.kind == kind {
            guard let modID = mod.origin.modID, let card = try? await card(modID), let current = card.fileToInstall,
                  current != mod.origin.fileID else { continue }
            found[mod.key] = card.file?.id == current ? card.file : (try? await files(of: modID))?.first { $0.id == current }
        }
        return found
    }
}

/// The player's own archives, as a source: the ones in a folder the player chose, newest first. Knows what a mod
/// archive is for everyone who needs to (the open panel, a drop, the Nexus tab). Never a folder of its own
/// choosing: reading Downloads unasked would make macOS ask the player for it.
public struct LocalFileSource: ModSource {
    public let folder: URL

    /// The archives `tar` unpacks for the store.
    public static let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz"]

    public init(folder: URL) { self.folder = folder }

    public var kind: StoredMod.Origin.Kind { .file }

    /// Whether a file's name is an archive the store can take.
    public static func isArchive(_ name: String) -> Bool {
        archiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A card for an archive on disk: the file's inode is its id, so the same file keeps its card. Nil for
    /// anything that isn't an archive file.
    public static func card(for file: URL) -> ModCard? {
        guard isArchive(file.lastPathComponent), let attributes = FileScan.attributes(file),
              (attributes[.type] as? FileAttributeType) == .typeRegular, let inode = attributes[.systemFileNumber] as? Int else { return nil }
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let added = attributes[.creationDate] as? Date
        let ref = ModFileRef(id: inode, name: file.lastPathComponent, bytes: bytes, added: added)
        return ModCard(id: inode, name: file.deletingPathExtension().lastPathComponent, updated: added, page: file, file: ref)
    }

    private func cards() -> [ModCard] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { Self.card(for: folder.appendingPathComponent($0)) }
            .sorted { ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast) }
    }

    public func search(_ query: String, offset: Int = 0, limit: Int = 50) async throws -> ModPage {
        let all = cards().filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        return ModPage(cards: Array(all.dropFirst(offset).prefix(limit)), total: all.count, offset: offset)
    }

    public func card(_ id: Int) async throws -> ModCard {
        guard let card = cards().first(where: { $0.id == id }) else { throw ModSourceError.notFound }
        return card
    }

    public func files(of modID: Int) async throws -> [ModFileRef] { try await card(modID).file.map { [$0] } ?? [] }

    public func link(for fileID: Int, of modID: Int) async throws -> ModDownloadLink {
        let card = try await card(modID)
        guard let file = card.file, file.id == fileID, let url = card.page else { throw ModSourceError.notFound }
        return ModDownloadLink(url: url, fileName: file.name)
    }

    /// The file is already here: it is handed back as it is, never copied or moved.
    public func download(_ link: ModDownloadLink, into folder: URL) async throws -> URL {
        guard link.url.isFileURL, FileScan.attributes(link.url) != nil else { throw ModSourceError.notFound }
        return link.url
    }
}
