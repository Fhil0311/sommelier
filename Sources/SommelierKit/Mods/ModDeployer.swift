// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a file couldn't be placed or taken out. Reasons only; the app words them.
public enum ModDeployError: Error, Equatable {
    /// The destination's root isn't there for this copy of the game (a Windows folder of a Mac version, a game
    /// that isn't installed), by its spec.
    case rootUnavailable(String)
    /// A destination that isn't a file path: a folder spec, or one with a placeholder still in it.
    case badDestination(String)
    /// The store no longer has the file to place.
    case sourceMissing(String)
    /// A folder sits where a file should go.
    case destinationBusy(String)
    /// Nothing of that owner is in the game.
    case notDeployed(String)
    /// `deployed.json` is there but can't be read: nothing is touched until it can.
    case recordUnreadable
}

/// `deployed.json` in the game's store: every file placed in the game, whose it is and where it came from, the
/// folders made on the way and the originals moved aside. The record is what makes the uninstall exact: only
/// what is listed here is ever removed, and only when it is still the file that was placed.
struct DeployedRecord: Codable, Equatable {
    /// One placed file. Two owners may claim one destination: the later entry is the one on disk, the earlier
    /// one comes back when it goes (the deploy order of RE4's loose files).
    struct Entry: Codable, Equatable {
        var owner: String
        /// The destination as a `ModPath` spec with its placeholders filled.
        var destination: String
        /// The file placed, relative to the game's store folder (`<key>/files/<path>`), or absolute when it
        /// came from elsewhere; nil for a copy of one of the game's files.
        var source: String?
        /// The game file this is a copy of (`copyAs`), as a spec.
        var copyOf: String?
        /// A hard link to the source (verified by identity) or a copy (verified by size and hash).
        var linked: Bool
        var size: Int64
        var sha256: String?
        /// The destination with `{next}` still in it, for a file placed at the next free number: it gets a new
        /// number when the game takes its own, and moves down when a number below it comes free.
        var numbered: String? = nil
    }

    /// What an owner did besides placing files.
    struct State: Codable, Equatable {
        /// Folder specs renamed with a leading dot to turn the mod off without unlinking (SMAPI).
        var dotted: [String] = []
    }

    var format = 1
    var entries: [Entry] = []
    var owners: [String: State] = [:]
    /// Folder specs made on the way to a destination, in the order they were made. Not an owner's: a folder one
    /// mod made and another still uses stays until it is empty, whoever leaves first.
    var created: [String] = []
    /// Destination spec → path under `.originals/` holding the file that was there before any mod's.
    var backups: [String: String] = [:]

    /// Whether two destination specs name one file. The Mac's disks ignore letter case (and Unicode
    /// normalisation), so `Movies/Intro.bk2` and `movies/intro.bk2` are the same file and must be one entry.
    static func same(_ a: String, _ b: String) -> Bool { a == b || a.lowercased() == b.lowercased() }

    func top(for destination: String) -> Entry? { entries.last { Self.same($0.destination, destination) } }
    func indexOfTop(for destination: String) -> Int? { entries.lastIndex { Self.same($0.destination, destination) } }
    func entries(of owner: String) -> [Entry] { entries.filter { $0.owner == owner } }
    /// The key `backups` keeps a destination's original under, however its letters were cased then.
    func backupKey(for destination: String) -> String? {
        backups[destination] != nil ? destination : backups.keys.sorted().first { Self.same($0, destination) }
    }
}

/// Places a stored mod's files into the game and takes them out again, exactly. Files are hard links to the
/// store (a copy when the game sits on another volume), so a mod costs no space twice and the game's own files
/// are never edited: one of them in the way is moved to `.originals/` in the store and comes back when the mod
/// goes. `verify` finds what a game update replaced or removed; `repair` places it again. A mod with an `enable`
/// format is turned off without unlinking: a dot in front of its folder, or a `: 0` line in `mods.txt`.
///
/// Owners are mod keys; a framework's files are recorded under `framework:<id>` by the installer, so taking a
/// framework out is the same operation.
public struct ModDeployer: Sendable {
    public let roots: ModRoots
    public let store: ModStore

    public init(roots: ModRoots, store: ModStore) { self.roots = roots; self.store = store }

    /// A file to place that isn't a stored mod's (a framework's), with where it comes from and the spec it
    /// goes to.
    public struct Placement: Equatable, Sendable {
        public var from: URL
        public var to: String
        /// The kind says the game's own file is overwritten here; otherwise a file in the way is reported.
        public var expectedOverwrite: Bool

        public init(from: URL, to: String, expectedOverwrite: Bool = false) {
            self.from = from; self.to = to; self.expectedOverwrite = expectedOverwrite
        }
    }

    /// What a deploy did.
    public struct Outcome: Equatable, Sendable {
        /// Destination specs placed this time (ones already in place are left out).
        public var placed: [String] = []
        public var linked = 0, copied = 0
        /// Files that were there, not the game's by the kind's account, moved aside all the same.
        public var overwroteForeign: [String] = []

        public init() {}
    }

    /// What an uninstall did.
    public struct Removal: Equatable, Sendable {
        public var removed: [String] = []
        /// Destinations where an original, or another mod's file, came back.
        public var restored: [String] = []
        /// Files that changed since they were placed (a game update, the game writing them): not ours to delete,
        /// left where they are.
        public var kept: [String] = []

        public init() {}
    }

    /// Something `verify` found wrong with a placed file.
    public struct Finding: Equatable, Sendable {
        public enum Problem: Equatable, Sendable {
            /// The file isn't there any more.
            case missing
            /// Another file sits there (a game update): ours is gone.
            case replaced
            /// The store no longer has the file.
            case storeMissing
            /// The destination's root isn't there for this copy.
            case rootUnavailable
        }
        public var owner: String
        public var destination: String
        public var problem: Problem
    }

    // MARK: Placing

    /// Places every file of a stored mod the plan didn't skip, filling `{slot}` with `slot` (the load order's
    /// `NNN_<slug>`; `000_<key>` until it says) and `{next}` with the next free number at the destination.
    /// Files already recorded for the mod are left as they are, so calling this again is harmless. A file that
    /// can't be placed takes back the ones this call placed: the game is as it was, and the record says so. A
    /// unit turned on through UE4SS's `mods.txt` gets its `: 1` line there when it has none yet.
    @discardableResult
    public func deploy(_ mod: StoredMod, slot: String? = nil) throws -> Outcome {
        var record = try load()
        var outcome = Outcome()
        let slotName = slot ?? "000_" + mod.key
        do {
            for unit in mod.units {
                var next: String?
                for file in unit.files where !file.skipped {
                    var spec = file.destination
                    if file.needsSlot { spec = spec.replacingOccurrences(of: "{slot}", with: slotName) }
                    let numbered = file.needsNext ? spec : nil
                    if file.needsNext {
                        if next == nil { next = try nextFree(for: spec, in: record) }
                        spec = spec.replacingOccurrences(of: "{next}", with: next ?? "")
                    }
                    try place(owner: mod.key, from: store.file(of: mod.key, at: file.source),
                              source: "\(mod.key)/\(ModStore.filesFolder)/\(file.source)", copyOf: nil, to: spec,
                              expectedOverwrite: unit.kind.backupOriginal, numbered: numbered, record: &record, outcome: &outcome)
                }
            }
        } catch {
            rollBack(owner: mod.key, placed: outcome.placed, record: &record)
            throw error
        }
        try save(record)
        try addModsTxtLines(of: mod)
        return outcome
    }

    /// Places files for an owner that isn't a stored mod (a framework's picks), all or none as `deploy` does.
    @discardableResult
    public func deploy(owner: String, _ placements: [Placement]) throws -> Outcome {
        var record = try load()
        var outcome = Outcome()
        do {
            for placement in placements {
                let under = store.folder.path + "/"
                let source = placement.from.path.hasPrefix(under) ? String(placement.from.path.dropFirst(under.count)) : placement.from.path
                try place(owner: owner, from: placement.from, source: source, copyOf: nil, to: placement.to,
                          expectedOverwrite: placement.expectedOverwrite, numbered: nil, record: &record, outcome: &outcome)
            }
        } catch {
            rollBack(owner: owner, placed: outcome.placed, record: &record)
            throw error
        }
        try save(record)
        return outcome
    }

    /// Copies one of the game's files under another name for an owner (`copyAs`: SMAPI's `deps.json`). Always a
    /// copy, never a link, and recorded like a placed file.
    @discardableResult
    public func copy(owner: String, from: String, to: String) throws -> Outcome {
        var record = try load()
        var outcome = Outcome()
        guard let origin = ModPath(from), let originURL = roots.resolve(origin) else { throw ModDeployError.rootUnavailable(from) }
        do {
            try place(owner: owner, from: originURL, source: nil, copyOf: origin.spec, to: to, expectedOverwrite: false, numbered: nil,
                      record: &record, outcome: &outcome)
        } catch {
            rollBack(owner: owner, placed: outcome.placed, record: &record)
            throw error
        }
        try save(record)
        return outcome
    }

    /// Takes out what a failed deploy placed so far and writes the record down, so nothing it moved is left
    /// outside it: the originals come back, the folders made go.
    private func rollBack(owner: String, placed: [String], record: inout DeployedRecord) {
        let placed = Set(placed)
        _ = try? takeOut(owner: owner, from: &record) { placed.contains($0.destination) }
        try? pruneCreated(&record)
        try? save(record)
    }

    private func place(owner: String, from: URL, source: String?, copyOf: String?, to spec: String, expectedOverwrite: Bool,
                       numbered: String?, record: inout DeployedRecord, outcome: inout Outcome) throws {
        guard let path = ModPath(spec), !path.path.isEmpty, !path.path.hasSuffix("/"), !spec.contains("{") else { throw ModDeployError.badDestination(spec) }
        try checkOwnFiles(path)
        guard let destination = roots.resolve(path) else { throw ModDeployError.rootUnavailable(spec) }
        guard FileScan.isRegularFile(from) else { throw ModDeployError.sourceMissing(from.path) }
        if record.entries.contains(where: { $0.owner == owner && DeployedRecord.same($0.destination, path.spec) }) { return }

        let disk = FileManager.default
        try makeFolders(for: path, created: &record.created)
        let onDisk = actual(destination, spec: path.spec, state: record.owners[owner] ?? .init())
        // What was in the way, to put back if this file can't be placed after all.
        var movedAside: String?, recordedBackup: String?, covered: Int?
        if FileScan.attributes(onDisk) != nil {
            if FileScan.isDirectory(onDisk) { throw ModDeployError.destinationBusy(path.spec) }
            if let below = record.indexOfTop(for: path.spec), isOurs(record.entries[below], at: onDisk) {
                try disk.removeItem(at: onDisk)
                covered = below
            } else {
                // The game's file, or someone else's, or one placed here that changed since (the player edited a
                // mod's .ini): kept for the day the mod goes. An original already kept for this file stays the
                // one that comes back; this one is only set aside.
                movedAside = try backUp(onDisk, path: path)
                if record.backupKey(for: path.spec) == nil {
                    record.backups[path.spec] = movedAside
                    recordedBackup = path.spec
                }
                // Written down before anything else happens, so the original is never outside the record.
                try save(record)
                if !expectedOverwrite { outcome.overwroteForeign.append(path.spec) }
            }
        }
        let linked: Bool
        do {
            linked = copyOf == nil && Self.link(from, to: onDisk)
            if !linked { try disk.copyItem(at: from, to: onDisk) }
        } catch {
            if FileScan.attributes(onDisk) != nil { try? disk.removeItem(at: onDisk) }
            if let movedAside {
                if let recordedBackup { record.backups[recordedBackup] = nil }
                try? restoreOriginal(movedAside, to: onDisk)
            } else if let covered {
                try? bringBack(&record.entries[covered], at: onDisk)
            }
            throw error
        }
        let size = (FileScan.attributes(onDisk)?[.size] as? NSNumber)?.int64Value ?? 0
        record.entries.append(.init(owner: owner, destination: path.spec, source: source, copyOf: copyOf, linked: linked, size: size,
                                    sha256: linked ? nil : ModStore.sha256(of: onDisk), numbered: numbered))
        outcome.placed.append(path.spec)
        if linked { outcome.linked += 1 } else { outcome.copied += 1 }
    }

    /// A destination in Sommelier's own store that is Sommelier's, not a mod's: the records, the loaders'
    /// staging, another mod's folder. A mod's folder of the same name would take their place.
    private func checkOwnFiles(_ path: ModPath) throws {
        guard path.root == .store, let first = path.components.first else { return }
        let home = store.folder(of: first).appendingPathComponent(ModStore.modFile)
        if ModStore.isOwnPath(path.components) || FileScan.attributes(home) != nil { throw ModDeployError.badDestination(path.spec) }
    }

    /// A hard link when the volume allows one.
    private static func link(_ from: URL, to destination: URL) -> Bool {
        (try? FileManager.default.linkItem(at: from, to: destination)) != nil
    }

    /// Makes the folders above a destination that aren't there, recording each as the owner's.
    private func makeFolders(for path: ModPath, created: inout [String]) throws {
        guard let top = roots.base(path.root) else { throw ModDeployError.rootUnavailable(path.spec) }
        let disk = FileManager.default
        var url = top
        var relative = ""
        for part in path.components.dropLast() {
            url = url.appendingPathComponent(part, isDirectory: true)
            relative += part + "/"
            if FileScan.attributes(url) == nil {
                try disk.createDirectory(at: url, withIntermediateDirectories: false)
                let spec = "\(path.root.rawValue):\(relative)"
                if !created.contains(spec) { created.append(spec) }
            } else if !FileScan.isDirectory(url) {
                throw ModDeployError.destinationBusy(path.spec)
            }
        }
    }

    /// Moves the file at a destination into `.originals/<root>/<path>` and returns that relative path. A file
    /// already kept there is never replaced: this one gets a free name beside it.
    private func backUp(_ file: URL, path: ModPath) throws -> String {
        let disk = FileManager.default
        let base = ([path.root.rawValue] + path.components).joined(separator: "/")
        var relative = base, n = 2
        while FileScan.attributes(URL(fileURLWithPath: store.originals.path + "/" + relative)) != nil {
            relative = base + ".\(n)"
            n += 1
        }
        let target = URL(fileURLWithPath: store.originals.path + "/" + relative)
        try disk.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try disk.moveItem(at: file, to: target)
        return relative
    }

    /// The next free number for a `{next}` destination: one more than the highest among the files at the
    /// destination's folder and the entries recorded there, with the width they use (three digits at least).
    func nextFree(for spec: String, in record: DeployedRecord) throws -> String {
        let numbers = try taken(for: spec, in: record)
        return String(format: "%0\(numbers.width)d", (numbers.taken.max() ?? 0) + 1)
    }

    /// The numbers a `{next}` destination's folder has in use, on disk and in the record, and their width.
    private func taken(for spec: String, in record: DeployedRecord) throws -> (taken: [Int], width: Int) {
        guard let path = ModPath(spec.replacingOccurrences(of: "{next}", with: "0")), let probe = roots.resolve(path) else {
            throw ModDeployError.rootUnavailable(spec)
        }
        let name = ModPath(spec)?.components.last ?? ""
        let pieces = name.components(separatedBy: "{next}")
        guard pieces.count == 2 else { throw ModDeployError.badDestination(spec) }
        var taken: [Int] = [], width = 3
        func consider(_ candidate: String) {
            guard let number = Self.number(in: candidate, prefix: pieces[0], suffix: pieces[1]) else { return }
            taken.append(number.value)
            width = max(width, number.digits)
        }
        let folder = probe.deletingLastPathComponent()
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).forEach(consider)
        let parent = ModArchive.parentSpec(spec).lowercased()
        for entry in record.entries where ModArchive.parentSpec(entry.destination).lowercased() == parent {
            consider(Self.fileName(of: entry.destination))
        }
        return (taken, width)
    }

    /// The number a file name carries between a `{next}` template's two halves, any case.
    private static func number(in name: String, prefix: String, suffix: String) -> (value: Int, digits: Int)? {
        let lower = name.lowercased(), prefix = prefix.lowercased(), suffix = suffix.lowercased()
        guard lower.hasPrefix(prefix), lower.hasSuffix(suffix), lower.count > prefix.count + suffix.count else { return nil }
        let middle = lower.dropFirst(prefix.count).dropLast(suffix.count)
        guard middle.allSatisfy(\.isASCII), middle.allSatisfy(\.isNumber), let value = Int(middle) else { return nil }
        return (value, middle.count)
    }

    /// A destination spec's file name, without its root even at the root (`game:x.pak` → `x.pak`).
    private static func fileName(of spec: String) -> String { ModPath(spec)?.components.last ?? ModArchive.basename(spec) }

    /// The spec a `{next}` template gives for a number, in the width the folder uses.
    private static func numberedSpec(_ template: String, number: Int, width: Int) -> String {
        template.replacingOccurrences(of: "{next}", with: String(format: "%0\(width)d", number))
    }

    /// Moves numbered files down into the numbers that came free below them. The game reads numbered files
    /// (RE4's `patch_NNN` paks) one after another and stops at the first that isn't there, so a gap left by a
    /// mod that went would hide every mod above it. Only our own files move; the game's never do.
    private func closeGaps(_ templates: Set<String>, record: inout DeployedRecord) throws {
        let disk = FileManager.default
        for template in templates.sorted() {
            guard let name = ModPath(template)?.components.last else { continue }
            let pieces = name.components(separatedBy: "{next}")
            guard pieces.count == 2 else { continue }
            var numbers = try taken(for: template, in: record)
            let ours = record.entries.indices.filter { DeployedRecord.same(record.entries[$0].numbered ?? "", template) }
                .compactMap { index -> (index: Int, number: Int)? in
                    Self.number(in: Self.fileName(of: record.entries[index].destination), prefix: pieces[0], suffix: pieces[1]).map { (index, $0.value) }
                }
                .sorted { $0.number < $1.number }
            for (index, number) in ours {
                let used = Set(numbers.taken)
                guard let free = (1..<number).first(where: { !used.contains($0) }) else { continue }
                let entry = record.entries[index]
                let target = Self.numberedSpec(template, number: free, width: numbers.width)
                guard record.top(for: target) == nil, record.backupKey(for: entry.destination) == nil,
                      let from = ModPath(entry.destination).flatMap(roots.resolve), let to = ModPath(target).flatMap(roots.resolve),
                      isOurs(entry, at: from), FileScan.attributes(to) == nil else { continue }
                try disk.moveItem(at: from, to: to)
                record.entries[index].destination = ModPath(target)?.spec ?? target
                numbers.taken.removeAll { $0 == number }
                numbers.taken.append(free)
            }
        }
    }

    // MARK: Removing

    /// Takes an owner's files out of the game: each one that is still the file placed is deleted, the original
    /// or the mod underneath comes back, folders made on the way go once empty. A file that changed since
    /// (a game update, the game writing into it) is left alone. `sources` limits it to some of a mod's archive
    /// paths (one unit of several). Numbered files above one that went move down to close the gap.
    @discardableResult
    public func remove(owner: String, sources: Set<String>? = nil) throws -> Removal {
        var record = try load()
        let matches: (DeployedRecord.Entry) -> Bool = { entry in
            guard let sources else { return true }
            return entry.source.map { sources.contains(Self.archivePath(of: $0, owner: owner)) } ?? false
        }
        guard record.entries.contains(where: { $0.owner == owner && matches($0) }) || record.owners[owner] != nil else {
            throw ModDeployError.notDeployed(owner)
        }
        let removal = try takeOut(owner: owner, from: &record, where: matches)
        try pruneCreated(&record)
        try save(record)
        return removal
    }

    /// The removal itself, on a record the caller saves.
    private func takeOut(owner: String, from record: inout DeployedRecord, where matches: (DeployedRecord.Entry) -> Bool) throws -> Removal {
        let mine = record.entries.indices.filter { record.entries[$0].owner == owner && matches(record.entries[$0]) }
        var removal = Removal()
        let disk = FileManager.default
        let state = record.owners[owner] ?? .init()
        var templates: Set<String> = []

        for index in mine.reversed() {
            let entry = record.entries[index]
            let wasTop = record.indexOfTop(for: entry.destination) == index
            record.entries.remove(at: index)
            if let numbered = entry.numbered { templates.insert(numbered) }
            guard wasTop, let path = ModPath(entry.destination), let destination = roots.resolve(path) else { continue }
            let onDisk = actual(destination, spec: entry.destination, state: state)
            if FileScan.attributes(onDisk) != nil {
                guard isOurs(entry, at: onDisk) else {
                    // Newer than what was placed: whatever is there now is the game's to keep.
                    removal.kept.append(entry.destination)
                    if let key = record.backupKey(for: entry.destination), let backup = record.backups.removeValue(forKey: key) { discardOriginal(backup) }
                    continue
                }
                try disk.removeItem(at: onDisk)
                removal.removed.append(entry.destination)
            }
            if let below = record.indexOfTop(for: entry.destination) {
                // The file underneath goes back under its own spelling of the name, as its owner placed it.
                let lower = record.entries[below]
                let target = ModPath(lower.destination).flatMap(roots.resolve)
                    .map { actual($0, spec: lower.destination, state: record.owners[lower.owner] ?? .init()) } ?? destination
                try bringBack(&record.entries[below], at: target)
                removal.restored.append(entry.destination)
            } else if let key = record.backupKey(for: entry.destination), let backup = record.backups.removeValue(forKey: key) {
                try restoreOriginal(backup, to: ModPath(key).flatMap(roots.resolve) ?? destination)
                removal.restored.append(entry.destination)
            }
        }

        if record.entries(of: owner).isEmpty { record.owners[owner] = nil }
        if !templates.isEmpty { try closeGaps(templates, record: &record) }
        return removal
    }

    /// Takes out the folders made for destinations that are empty now, deepest first, dotted or not. A folder
    /// something else has filled stays, and stays on the list for the day it empties.
    private func pruneCreated(_ record: inout DeployedRecord) throws {
        let disk = FileManager.default
        var kept: [String] = []
        for folder in record.created.reversed() {
            guard let url = ModPath(folder).flatMap(roots.resolve) else { continue }
            var gone = true
            for candidate in [url, dotted(url)] where FileScan.isDirectory(candidate) {
                if Self.isEmptyFolder(candidate) { try disk.removeItem(at: candidate) } else { gone = false }
            }
            if !gone { kept.insert(folder, at: 0) }
        }
        record.created = kept
    }

    /// Places a shadowed entry's file again at its destination, from the store or its origin.
    private func bringBack(_ entry: inout DeployedRecord.Entry, at destination: URL) throws {
        let from: URL
        if let copyOf = entry.copyOf {
            guard let origin = ModPath(copyOf).flatMap(roots.resolve) else { throw ModDeployError.rootUnavailable(copyOf) }
            from = origin
        } else if let source = entry.source {
            from = sourceURL(source)
        } else {
            throw ModDeployError.sourceMissing(entry.destination)
        }
        guard FileScan.isRegularFile(from) else { throw ModDeployError.sourceMissing(from.path) }
        let linked = entry.copyOf == nil && Self.link(from, to: destination)
        if !linked { try FileManager.default.copyItem(at: from, to: destination) }
        entry.linked = linked
        entry.size = (FileScan.attributes(destination)?[.size] as? NSNumber)?.int64Value ?? 0
        entry.sha256 = linked ? nil : ModStore.sha256(of: destination)
    }

    private func restoreOriginal(_ backup: String, to destination: URL) throws {
        let kept = URL(fileURLWithPath: store.originals.path + "/" + backup)
        guard FileScan.attributes(kept) != nil else { return }
        try FileManager.default.moveItem(at: kept, to: destination)
        pruneOriginals(from: kept.deletingLastPathComponent())
    }

    private func discardOriginal(_ backup: String) {
        let kept = URL(fileURLWithPath: store.originals.path + "/" + backup)
        try? FileManager.default.removeItem(at: kept)
        pruneOriginals(from: kept.deletingLastPathComponent())
    }

    /// Takes empty folders out of `.originals/`, up to and including the folder itself.
    private func pruneOriginals(from folder: URL) {
        var current = folder
        let stop = store.originals.deletingLastPathComponent().standardizedFileURL.path
        while current.standardizedFileURL.path.hasPrefix(store.originals.standardizedFileURL.path), current.standardizedFileURL.path != stop,
              FileScan.isDirectory(current), Self.isEmptyFolder(current) {
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    // MARK: Checking

    /// Looks at every file on disk for the records: gone, replaced by another, or no longer in the store.
    public func verify() -> [Finding] {
        guard let record = try? load() else { return [] }
        var findings: [Finding] = []
        var seen: Set<String> = []
        for entry in record.entries.reversed() where !seen.contains(entry.destination.lowercased()) {
            seen.insert(entry.destination.lowercased())
            guard let path = ModPath(entry.destination), let destination = roots.resolve(path) else {
                findings.append(.init(owner: entry.owner, destination: entry.destination, problem: .rootUnavailable))
                continue
            }
            if let source = entry.source, !FileScan.isRegularFile(sourceURL(source)) {
                findings.append(.init(owner: entry.owner, destination: entry.destination, problem: .storeMissing))
                continue
            }
            let onDisk = actual(destination, spec: entry.destination, state: record.owners[entry.owner] ?? .init())
            if FileScan.attributes(onDisk) == nil {
                findings.append(.init(owner: entry.owner, destination: entry.destination, problem: .missing))
            } else if !isOurs(entry, at: onDisk) || copyIsStale(entry) {
                findings.append(.init(owner: entry.owner, destination: entry.destination, problem: .replaced))
            }
        }
        return findings.sorted { $0.destination < $1.destination }
    }

    /// Places the files `verify` found missing or replaced again. A file that replaced ours is the game's
    /// newer original: it takes the backup's place, so the uninstall gives back the game as it is now. A
    /// numbered file whose number the game took for its own (an official RE4 patch) isn't put back over it:
    /// it moves to the next free number and the game's file stays.
    @discardableResult
    public func repair(_ findings: [Finding]) throws -> Outcome {
        var record = try load()
        var outcome = Outcome()
        let disk = FileManager.default
        for finding in findings where finding.problem == .missing || finding.problem == .replaced {
            guard let index = record.indexOfTop(for: finding.destination), let path = ModPath(finding.destination),
                  let destination = roots.resolve(path) else { continue }
            let entry = record.entries[index]
            let state = record.owners[entry.owner] ?? .init()
            let onDisk = actual(destination, spec: entry.destination, state: state)
            if let template = entry.numbered, FileScan.attributes(onDisk) != nil, !isOurs(entry, at: onDisk) {
                let spec = template.replacingOccurrences(of: "{next}", with: try nextFree(for: template, in: record))
                guard let moved = ModPath(spec), let target = roots.resolve(moved) else { continue }
                try bringBack(&record.entries[index], at: target)
                record.entries[index].destination = moved.spec
                outcome.placed.append(moved.spec)
                if record.entries[index].linked { outcome.linked += 1 } else { outcome.copied += 1 }
                continue
            }
            if FileScan.attributes(onDisk) != nil {
                if entry.copyOf == nil && !isOurs(entry, at: onDisk) {
                    if let key = record.backupKey(for: entry.destination), let old = record.backups.removeValue(forKey: key) { discardOriginal(old) }
                    record.backups[entry.destination] = try backUp(onDisk, path: path)
                } else {
                    try disk.removeItem(at: onDisk)
                }
            } else {
                try makeFolders(for: path, created: &record.created)
            }
            try bringBack(&record.entries[index], at: onDisk)
            outcome.placed.append(entry.destination)
            if record.entries[index].linked { outcome.linked += 1 } else { outcome.copied += 1 }
        }
        try save(record)
        return outcome
    }

    /// Whether the file at `url` is still the one placed: the same file as the store's for a link, the same
    /// bytes for a copy.
    private func isOurs(_ entry: DeployedRecord.Entry, at url: URL) -> Bool {
        guard let info = FileScan.attributes(url), info[.type] as? FileAttributeType == .typeRegular else { return false }
        if entry.linked, let source = entry.source {
            guard let original = FileScan.attributes(sourceURL(source)) else { return false }
            return (info[.systemFileNumber] as? NSNumber) == (original[.systemFileNumber] as? NSNumber)
                && (info[.systemNumber] as? NSNumber) == (original[.systemNumber] as? NSNumber)
        }
        guard (info[.size] as? NSNumber)?.int64Value == entry.size else { return false }
        return entry.sha256 == nil || ModStore.sha256(of: url) == entry.sha256
    }

    /// A copy of a game file whose original changed since (the game updated its `deps.json`).
    private func copyIsStale(_ entry: DeployedRecord.Entry) -> Bool {
        guard let copyOf = entry.copyOf, let origin = ModPath(copyOf).flatMap(roots.resolve), let sha = entry.sha256 else { return false }
        return ModStore.sha256(of: origin) != sha
    }

    // MARK: Turning off without unlinking

    /// Turns a stored mod on or off in the game. A unit whose kind has an `enable` format keeps its files: its
    /// folder gets a dot in front (`dotPrefix`) or its line in the loader's list says `0` (`ue4ssModsTxt`). A
    /// unit without one is unlinked and placed again, with `slot` as for `deploy`.
    public func setEnabled(_ mod: StoredMod, _ on: Bool, slot: String? = nil) throws {
        var plain: [ModPlan.Unit] = []
        for unit in mod.units {
            switch unit.kind.enable?.format {
            case .dotPrefix?:
                guard let folder = Self.unitFolder(of: unit) else { plain.append(unit); continue }
                try setDotted(folder, owner: mod.key, off: !on)
            case .ue4ssModsTxt?:
                guard let file = unit.kind.enable?.file, let url = roots.resolve(file) else { throw ModDeployError.rootUnavailable(unit.kind.enable?.file ?? "") }
                try Self.setLine(in: url, name: unit.name, on: on)
                try noteEdited(file)
            case nil:
                plain.append(unit)
            }
        }
        guard !plain.isEmpty else { return }
        if on {
            try deploy(mod, slot: slot)
        } else {
            let sources = Set(plain.flatMap { $0.files.map(\.source) })
            let record = try load()
            if record.entries(of: mod.key).contains(where: { $0.source.map { sources.contains(Self.archivePath(of: $0, owner: mod.key)) } ?? false }) {
                try remove(owner: mod.key, sources: sources)
            }
        }
    }

    /// Records that Sommelier itself rewrote a placed file (the loader's `mods.txt` or `mods.xml` it shipped,
    /// edited for a mod's line or the order): the file is a copy of ours now, not the link the framework placed,
    /// so `verify` doesn't take it for a game update and the uninstall still deletes it. Nothing recorded at
    /// that spec: nothing to note.
    public func noteEdited(_ spec: String) throws {
        var record = try load()
        guard let path = ModPath(spec), let index = record.indexOfTop(for: path.spec), let url = roots.resolve(path),
              FileScan.isRegularFile(url) else { return }
        record.entries[index].linked = false
        record.entries[index].size = (FileScan.attributes(url)?[.size] as? NSNumber)?.int64Value ?? 0
        record.entries[index].sha256 = ModStore.sha256(of: url)
        try save(record)
    }

    /// The folder a unit's files share when its kind places it as `…/{name}/`, as a spec with its trailing
    /// slash; nil when the kind scatters the files.
    static func unitFolder(of unit: ModPlan.Unit) -> String? {
        guard unit.kind.to.hasSuffix("/"), unit.kind.to.contains("{name}") else { return nil }
        let folder = unit.kind.to.replacingOccurrences(of: "{name}", with: unit.name)
        guard !folder.contains("{"), ModPath(folder) != nil else { return nil }
        return folder
    }

    private func setDotted(_ folder: String, owner: String, off: Bool) throws {
        var record = try load()
        guard let url = ModPath(folder).flatMap(roots.resolve) else { throw ModDeployError.rootUnavailable(folder) }
        var state = record.owners[owner] ?? .init()
        let hidden = dotted(url)
        let disk = FileManager.default
        if off {
            if FileScan.isDirectory(url) && FileScan.attributes(hidden) == nil { try disk.moveItem(at: url, to: hidden) }
            if !state.dotted.contains(folder) { state.dotted.append(folder) }
        } else {
            if FileScan.isDirectory(hidden) && FileScan.attributes(url) == nil { try disk.moveItem(at: hidden, to: url) }
            state.dotted.removeAll { $0 == folder }
        }
        record.owners[owner] = state
        try save(record)
    }

    /// A mod newly placed whose units UE4SS turns on through `mods.txt`: each gets its `<Name> : 1` line, or
    /// UE4SS never loads it. A line already there is the player's choice and stays; with no `mods.txt` in the
    /// game (no UE4SS) nothing is written.
    private func addModsTxtLines(of mod: StoredMod) throws {
        for unit in mod.units where unit.kind.enable?.format == .ue4ssModsTxt && unit.files.contains(where: { !$0.skipped }) {
            guard let spec = unit.kind.enable?.file, let url = ModPath(spec).flatMap(roots.resolve), FileScan.isRegularFile(url) else { continue }
            if try Self.setLine(in: url, name: unit.name, on: true, onlyIfMissing: true) { try noteEdited(spec) }
        }
    }

    /// Sets a mod's line in UE4SS's `mods.txt` (`<Name> : 1` or `: 0`), adding one at the end when there is
    /// none; with `onlyIfMissing` a line already there is left as it is. Every other line, and the file's line
    /// endings, stay as they are. True when the file was written.
    @discardableResult
    static func setLine(in file: URL, name: String, on: Bool, onlyIfMissing: Bool = false) throws -> Bool {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: ending)
        let trailing = lines.last == ""
        if trailing { lines.removeLast() }
        let wanted = "\(name) : \(on ? 1 : 0)"
        var found = false
        lines = lines.map { line in
            let key = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard key.lowercased() == name.lowercased() else { return line }
            found = true
            return onlyIfMissing ? line : wanted
        }
        if found && onlyIfMissing { return false }
        if !found { lines.append(wanted) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: ending) + ending).write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: Folders

    /// Renames a folder the deployer filled (a `{slot}` folder getting a new number in the load order) and
    /// moves its records along: every destination, folder and dotted state under the old spec now reads under
    /// the new one. Both are folder specs under one root; the new one must be free.
    public func renameFolder(_ from: String, to: String) throws {
        guard let old = ModPath(from), let new = ModPath(to), old.root == new.root, !old.path.isEmpty, !new.path.isEmpty,
              old.path.hasSuffix("/"), new.path.hasSuffix("/"), !from.contains("{"), !to.contains("{") else { throw ModDeployError.badDestination(to) }
        guard let oldURL = roots.resolve(old), let newURL = roots.resolve(new) else { throw ModDeployError.rootUnavailable(from) }
        guard old.spec != new.spec else { return }
        var record = try load()
        if FileScan.attributes(newURL) != nil { throw ModDeployError.destinationBusy(to) }
        if FileScan.isDirectory(oldURL) { try FileManager.default.moveItem(at: oldURL, to: newURL) }
        func moved(_ spec: String) -> String { spec.hasPrefix(old.spec) ? new.spec + spec.dropFirst(old.spec.count) : spec }
        record.entries = record.entries.map { var entry = $0; entry.destination = moved(entry.destination); return entry }
        record.created = record.created.map(moved)
        record.backups = Dictionary(uniqueKeysWithValues: record.backups.map { (moved($0.key), $0.value) })
        record.owners = record.owners.mapValues { var state = $0; state.dotted = state.dotted.map(moved); return state }
        try save(record)
    }

    // MARK: Records

    /// Whether an owner has files in the game. Throws `recordUnreadable` rather than answer no: a caller about to
    /// delete the owner's store copies must not take an unreadable record for an empty one.
    public func isDeployed(_ owner: String) throws -> Bool { try !load().entries(of: owner).isEmpty }

    /// The destination specs of an owner that another owner's file sits on top of right now.
    public func shadowed(_ owner: String) -> [String] {
        guard let record = try? load() else { return [] }
        return record.entries(of: owner).map(\.destination).filter { record.top(for: $0)?.owner != owner }
    }

    /// The destination specs an owner has in the game, in the order they were placed.
    public func deployed(_ owner: String) -> [String] { ((try? load())?.entries(of: owner) ?? []).map(\.destination) }

    /// Every owner with files in the game.
    public func owners() -> [String] {
        guard let record = try? load() else { return [] }
        var seen: [String] = []
        for entry in record.entries where !seen.contains(entry.owner) { seen.append(entry.owner) }
        for owner in record.owners.keys.sorted() where !seen.contains(owner) { seen.append(owner) }
        return seen
    }

    func load() throws -> DeployedRecord {
        guard let bytes = try? Data(contentsOf: store.deployedFile) else { return DeployedRecord() }
        do {
            return try JSONDecoder().decode(DeployedRecord.self, from: bytes)
        } catch {
            throw ModDeployError.recordUnreadable
        }
    }

    private func save(_ record: DeployedRecord) throws {
        let disk = FileManager.default
        if record.entries.isEmpty && record.owners.isEmpty && record.created.isEmpty && record.backups.isEmpty {
            try? disk.removeItem(at: store.deployedFile)
            return
        }
        let writer = JSONEncoder()
        writer.outputFormatting = [.sortedKeys, .prettyPrinted]
        try disk.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try writer.encode(record).write(to: store.deployedFile, options: .atomic)
    }

    /// Where a recorded source is: under the game's store unless it was absolute.
    private func sourceURL(_ source: String) -> URL {
        source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(fileURLWithPath: store.folder.path + "/" + source)
    }

    /// The archive path of a mod's recorded source (`<key>/files/<path>` → `<path>`).
    private static func archivePath(of source: String, owner: String) -> String {
        let prefix = "\(owner)/\(ModStore.filesFolder)/"
        return source.hasPrefix(prefix) ? String(source.dropFirst(prefix.count)) : source
    }

    /// Where a destination is on disk right now: inside the dotted folder when its owner is turned off that way.
    private func actual(_ destination: URL, spec: String, state: DeployedRecord.State) -> URL {
        for folder in state.dotted where spec.hasPrefix(folder) {
            guard let folderURL = ModPath(folder).flatMap(roots.resolve) else { continue }
            let rest = spec.dropFirst(folder.count).split(separator: "/").map(String.init)
            return URL(fileURLWithPath: ([dotted(folderURL).path] + rest).joined(separator: "/"))
        }
        return destination
    }

    private func dotted(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent("." + folder.lastPathComponent, isDirectory: true)
    }

    /// Nothing inside but Finder's leavings.
    private static func isEmptyFolder(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).allSatisfy { $0 == ".DS_Store" }
    }
}
