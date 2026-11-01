// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a framework couldn't be installed or taken out. Reasons only; the app words them.
public enum FrameworkInstallError: Error, Equatable {
    /// The profile has no framework of that id.
    case unknownFramework(String)
    /// The profile gives no SHA-256 for the download: nothing without a hash is ever unpacked.
    case noHash(String)
    /// The file fetched isn't the one the profile pins. The install stops here; no other copy is looked for.
    case hashMismatch(framework: String, expected: String, actual: String)
    /// The download has to go through the app's embedded browser (an author's page, a Nexus mod): the kit's
    /// downloader can't take it, the app does and calls `install` with the archive it got.
    case needsBrowser(String)
    /// The download failed, with what went wrong.
    case downloadFailed(String)
    /// The inner file another framework's archive was supposed to hold isn't there.
    case innerMissing(String)
    /// No file of the archive matched the profile's picks: the wrong archive, or a release laid out anew.
    case nothingPicked(String)
    /// The framework isn't installed.
    case notInstalled(String)
}

/// Fetches a framework's archive. The kit's own downloader takes direct links (a GitHub release asset, a plain
/// URL); the app's takes the rest through its embedded browser with the same interception it uses for Nexus.
/// The installer checks the hash afterwards whoever fetched the file, so a downloader need not.
public protocol ModDownloader: Sendable {
    /// The archive as a file inside `folder` (a fresh temporary folder the installer deletes afterwards).
    func download(_ download: ModDownload, into folder: URL) async throws -> URL
}

/// Direct downloads over `URLSession`. GitHub assets come from the release the profile names, or the latest.
public struct URLModDownloader: ModDownloader {
    public let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// The URL a download can be fetched from without a browser, or nil when it can't.
    public static func directURL(of download: ModDownload) -> URL? {
        switch download.kind {
        case .github:
            guard let repo = download.repo, let asset = download.asset, !repo.contains(".."), !asset.contains("/") else { return nil }
            let release = download.tag.map { "download/\($0)" } ?? "latest/download"
            return URL(string: "https://github.com/\(repo)/releases/\(release)/\(asset)")
        case .url:
            guard !download.viaBrowser, let text = download.url, let url = URL(string: text), url.scheme == "https" else { return nil }
            // A page with a file pattern needs the browser; a link that is the file itself doesn't.
            if let pattern = download.file, !ModGlob.matchesName(pattern, url.lastPathComponent) { return nil }
            return url
        case .nexus, .inner:
            return nil
        }
    }

    public func download(_ download: ModDownload, into folder: URL) async throws -> URL {
        guard let url = Self.directURL(of: download) else { throw FrameworkInstallError.needsBrowser(download.url ?? download.repo ?? "") }
        let (fetched, response) = try await session.download(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            try? FileManager.default.removeItem(at: fetched)
            throw FrameworkInstallError.downloadFailed("HTTP \(status) for \(url.absoluteString)")
        }
        let name = download.asset ?? response.suggestedFilename ?? url.lastPathComponent
        let target = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileScan.attributes(target) != nil { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: fetched, to: target)
        return target
    }
}

/// Installs a game's frameworks (loaders) as the profile describes them and takes them out again. The archive is
/// fetched by a `ModDownloader`, checked against the profile's SHA-256 before anything is unpacked, and the picked
/// files are kept under the game's store (`frameworks/<id>/files/`) and placed into the game by the deployer under
/// the owner `framework:<id>`, so removing the framework is the deployer's exact uninstall. Settings edits happen
/// on the staged copy before it is placed (a hard link must not be rewritten in the game), or in place with a
/// backup when the file is the game's. The launch changes (DLL overrides, a redirect, arguments) go into the
/// game's `LaunchProfile` as applied fixes under `framework:<id>`, so Fix Launch lists them and the uninstall
/// undoes them; the component installs are returned for the app, which owns the bottle.
public struct FrameworkInstaller: Sendable {
    public let profile: ModProfile
    public let deployer: ModDeployer
    public let downloader: any ModDownloader

    static let folderName = "frameworks"
    static let recordName = "framework.json"
    static let filesFolder = "files"
    static let removedFolder = "removed"
    static let settingsFolder = "settings"

    public init(profile: ModProfile, deployer: ModDeployer, downloader: any ModDownloader = URLModDownloader()) {
        self.profile = profile; self.deployer = deployer; self.downloader = downloader
    }

    var store: ModStore { deployer.store }
    var roots: ModRoots { deployer.roots }

    /// The deployer's owner for a framework's files, and the rule id of the fixes it applied to the launch.
    public static func owner(_ id: String) -> String { "framework:\(id)" }
    public static func ruleID(_ id: String) -> String { "framework:\(id)" }

    /// `framework.json`: what an install did besides placing files, for the uninstall.
    public struct Record: Codable, Equatable, Sendable {
        public var format = 1
        public var id: String
        public var sha256: String
        public var installed: Date
        /// Game files the framework's `remove` list took out: destination spec → path under `removed/`.
        public var removed: [String: String] = [:]
        /// Settings files edited in the game itself: spec → path under `settings/` holding the bytes before, or
        /// nil when the file didn't exist and was made (and goes with the framework).
        public var settingsBackups: [String: String?] = [:]
    }

    /// What an install did.
    public struct Installation: Equatable, Sendable {
        public var framework: String
        /// Frameworks installed on the way because this one requires them.
        public var alsoInstalled: [String] = []
        public var placed: [String] = []
        /// Files that were in the way and were moved aside (the deployer keeps them for the uninstall).
        public var overwroteForeign: [String] = []
        /// Fixes applied to the launch profile, for the game's applied fixes.
        public var fixes: [AppliedFix] = []
        /// Component installs the app performs (they need the bottle).
        public var components: [FixAction] = []

        public init(framework: String) { self.framework = framework }
    }

    // MARK: Records

    func folder(of id: String) -> URL { store.folder.appendingPathComponent(Self.folderName, isDirectory: true).appendingPathComponent(id, isDirectory: true) }
    func files(of id: String) -> URL { folder(of: id).appendingPathComponent(Self.filesFolder, isDirectory: true) }
    private func recordFile(of id: String) -> URL { folder(of: id).appendingPathComponent(Self.recordName) }

    public func record(_ id: String) -> Record? {
        guard let bytes = try? Data(contentsOf: recordFile(of: id)) else { return nil }
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        return try? reader.decode(Record.self, from: bytes)
    }

    public func isInstalled(_ id: String) -> Bool { record(id) != nil }

    /// The installed frameworks, in the profile's order.
    public func installed() -> [String] { profile.frameworks.map(\.id).filter(isInstalled) }

    private func save(_ record: Record) throws {
        let writer = JSONEncoder()
        writer.dateEncodingStrategy = .iso8601
        writer.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(at: folder(of: record.id), withIntermediateDirectories: true)
        try writer.encode(record).write(to: recordFile(of: record.id), options: .atomic)
    }

    // MARK: Installing

    /// Installs a framework (and first whatever it requires), changing the game's launch profile as it needs.
    /// Fetches the archive through the downloader; `archive` is one the app already fetched through its browser.
    /// Installing an installed framework again does nothing. The two halves are `prepare` and `place`, for an
    /// app that runs the second where it keeps all the work on a game's records.
    public func install(_ id: String, archive: URL? = nil, launchProfile: inout LaunchProfile, now: Date = Date()) async throws -> Installation {
        guard let framework = profile.framework(id) else { throw FrameworkInstallError.unknownFramework(id) }
        var installation = Installation(framework: id)
        for required in framework.requires where !isInstalled(required) {
            let sub = try await install(required, launchProfile: &launchProfile, now: now)
            installation.alsoInstalled += sub.alsoInstalled + [required]
            installation.fixes += sub.fixes
            installation.components += sub.components
        }
        guard !isInstalled(id) else { return installation }
        let own = try place(try await prepare(id, archive: archive), launchProfile: &launchProfile, now: now)
        installation.placed = own.placed
        installation.overwroteForeign = own.overwroteForeign
        installation.fixes += own.fixes
        installation.components = own.components
        return installation
    }

    /// A framework fetched, checked and staged in its folder in the store, not yet in the game.
    public struct Prepared: Sendable {
        public let id: String
        let staged: [Staged]
    }

    /// The first half of an install: fetches the archive (or takes `archive`), checks it against the profile's
    /// hash, unpacks it and stages the picked files in the framework's folder. Nothing in the game changes and
    /// no record is written; what it requires isn't looked at.
    public func prepare(_ id: String, archive: URL? = nil) async throws -> Prepared {
        guard let framework = profile.framework(id) else { throw FrameworkInstallError.unknownFramework(id) }
        let scratch = store.folder.appendingPathComponent(ModStore.temporaryName, isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fetched: URL
        if let archive {
            fetched = try Self.verified(archive, against: framework.download, framework: id)
        } else {
            fetched = try await fetch(framework, into: scratch)
        }
        let unpacked = try await store.unpack(fetched)
        defer { try? FileManager.default.removeItem(at: unpacked) }

        let staged = try await stage(framework, from: unpacked)
        guard !staged.isEmpty else { throw FrameworkInstallError.nothingPicked(id) }
        if profile.runtime == .native { Self.markExecutables(staged.map(\.from)) }
        return Prepared(id: id, staged: staged)
    }

    /// The second half: places what `prepare` staged into the game, edits the settings, writes the record and
    /// applies the launch changes to `launchProfile`. All or none: a failure takes out whatever got in. Placing a
    /// framework installed meanwhile does nothing.
    public func place(_ prepared: Prepared, launchProfile: inout LaunchProfile, now: Date = Date()) throws -> Installation {
        let id = prepared.id, staged = prepared.staged
        guard let framework = profile.framework(id) else { throw FrameworkInstallError.unknownFramework(id) }
        var installation = Installation(framework: id)
        guard !isInstalled(id) else { return installation }

        var record = Record(id: id, sha256: framework.download.sha256 ?? "", installed: now)
        do {
            // Settings in the framework's own files go into the staged copies, before they are linked in; the
            // game's files are edited once the deployer has made the folders (so it owns them to the end).
            try applySettings(framework, staged: staged, record: &record, inGame: false)
            try removeStale(framework, record: &record)
            // Sommelier's own roots may not be there yet (a first loader in `Tools/`); the game's is never made.
            for root in [ModPath.Root.tools, .store] where staged.contains(where: { ModPath($0.to)?.root == root }) {
                if let base = roots.base(root) { try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true) }
            }
            let outcome = try deployer.deploy(owner: Self.owner(id), staged.map { ModDeployer.Placement(from: $0.from, to: $0.to) })
            installation.placed = outcome.placed
            installation.overwroteForeign = outcome.overwroteForeign
            for copy in framework.copyAs {
                installation.placed += try deployer.copy(owner: Self.owner(id), from: copy.from, to: copy.to).placed
            }
            try applySettings(framework, staged: staged, record: &record, inGame: true)
            try save(record)
        } catch {
            // Half an install is worse than none: whatever got in comes out again.
            try? restoreSettings(record)
            try? deployer.remove(owner: Self.owner(id))
            try? restoreRemoved(record)
            try? FileManager.default.removeItem(at: folder(of: id))
            throw error
        }

        installation.fixes += Self.launchFixes(of: framework).compactMap { Self.apply($0, to: &launchProfile, ruleID: Self.ruleID(id), now: now) }
        installation.components = framework.componentActions
        return installation
    }

    /// Fetches the framework's archive and checks it. An `inner` download fetches the archive it sits in (checked
    /// by that framework's hash), unpacks it and takes the file out.
    private func fetch(_ framework: ModFramework, into scratch: URL) async throws -> URL {
        let download = framework.download
        guard download.kind == .inner else {
            let fetched = try await downloader.download(download, into: scratch.appendingPathComponent("download", isDirectory: true))
            return try Self.verified(fetched, against: download, framework: framework.id)
        }
        guard let outerID = download.of, let outer = profile.framework(outerID), let path = download.path else {
            throw FrameworkInstallError.innerMissing(download.path ?? framework.id)
        }
        let fetched = try await downloader.download(outer.download, into: scratch.appendingPathComponent("outer", isDirectory: true))
        _ = try Self.verified(fetched, against: outer.download, framework: outerID)
        let unpacked = try await store.unpack(fetched)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let wanted = ModStore.normalised(path).lowercased()
        guard let inner = Self.relativePaths(in: unpacked).first(where: { $0.lowercased() == wanted }) else {
            throw FrameworkInstallError.innerMissing(path)
        }
        let kept = scratch.appendingPathComponent("inner", isDirectory: true).appendingPathComponent(ModArchive.basename(inner))
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: Self.url(unpacked, inner), to: kept)
        return try Self.verified(kept, against: download, framework: framework.id)
    }

    /// Whether the profile pins the framework's download with a SHA-256 (an `inner` file, and the archive it
    /// sits in). One that isn't can't be installed, so nothing is fetched for it, not even through the browser.
    public static func isPinned(_ framework: ModFramework, in profile: ModProfile) -> Bool {
        func pinned(_ download: ModDownload) -> Bool { download.sha256.map { $0.count == 64 && $0.allSatisfy(\.isHexDigit) } ?? false }
        guard pinned(framework.download) else { return false }
        guard framework.download.kind == .inner else { return true }
        return framework.download.of.flatMap(profile.framework).map { pinned($0.download) } ?? false
    }

    /// The file when its SHA-256 is the one the profile pins; an error otherwise, before anything is unpacked.
    /// The file itself is left alone: a fetched one goes with its scratch folder, a player's stays theirs.
    static func verified(_ file: URL, against download: ModDownload, framework: String) throws -> URL {
        guard let expected = download.sha256?.lowercased(), expected.count == 64 else { throw FrameworkInstallError.noHash(framework) }
        let actual = ModStore.sha256(of: file) ?? ""
        guard actual == expected else { throw FrameworkInstallError.hashMismatch(framework: framework, expected: expected, actual: actual) }
        return file
    }

    /// A staged file: a copy under `frameworks/<id>/files/` and the spec it goes to.
    struct Staged: Equatable, Sendable { var from: URL; var to: String }

    /// Copies the picked files out of the unpacked archive into the framework's folder, each under the path of its
    /// destination. One wrapper folder comes off when every file sits in it and no pick names it. A literal pick
    /// (no wildcards) places the file by its name; a pattern keeps the archive path; `stripTo` keeps the path from
    /// that folder on; a `to` that names a file renames the one file. A picked archive (`unpack`) is unpacked and
    /// its contents placed under `to`.
    private func stage(_ framework: ModFramework, from unpacked: URL) async throws -> [Staged] {
        var paths = Self.relativePaths(in: unpacked)
        var base = unpacked
        if profile.archive.wrappers, let top = ModArchive.wrapperFolder(of: paths, significant: Self.significantNames(of: framework)) {
            paths = paths.map { String($0.dropFirst(top.count + 1)) }
            base = unpacked.appendingPathComponent(top, isDirectory: true)
        }
        var staged: [Staged] = []
        var taken: Set<String> = []
        for pick in framework.pick {
            let literal = Self.isLiteral(pick.match)
            for path in paths where !taken.contains(path) && ModGlob.matches(pick.match, path) {
                taken.insert(path)
                let source = Self.url(base, path)
                if pick.unpack {
                    let inner = try await store.unpack(source)
                    defer { try? FileManager.default.removeItem(at: inner) }
                    for innerPath in Self.relativePaths(in: inner) {
                        let relative = pick.stripTo.flatMap { ModArchive.fromSegment($0, in: innerPath) } ?? innerPath
                        guard let spec = Self.destination(pick.to, relative: relative, framework: framework) else { continue }
                        staged.append(try copyIn(Self.url(inner, innerPath), to: spec, framework: framework.id))
                    }
                    continue
                }
                let relative: String
                if let strip = pick.stripTo, let from = ModArchive.fromSegment(strip, in: path) { relative = from }
                else if literal { relative = ModArchive.basename(path) }
                else { relative = path }
                guard let spec = Self.destination(pick.to, relative: relative, framework: framework) else { continue }
                staged.append(try copyIn(source, to: spec, framework: framework.id))
            }
        }
        return staged
    }

    /// The spec a picked file goes to: under a folder spec by its relative path, or the file spec itself. Nil for
    /// a file the framework says is never placed under Wine, or a destination that isn't safe.
    static func destination(_ to: String, relative: String, framework: ModFramework) -> String? {
        let spec = to.hasSuffix("/") || to.hasSuffix(":") ? to + relative : to
        guard let path = ModPath(spec), !path.path.isEmpty, !path.path.hasSuffix("/") else { return nil }
        if framework.skip.contains(where: { ModArchive.normalised($0) == ModArchive.normalised(path.path) }) { return nil }
        return path.spec
    }

    private func copyIn(_ source: URL, to spec: String, framework id: String) throws -> Staged {
        guard let path = ModPath(spec) else { throw ModDeployError.badDestination(spec) }
        let target = URL(fileURLWithPath: ([files(of: id).path, path.root.rawValue] + path.components).joined(separator: "/"))
        let disk = FileManager.default
        try disk.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileScan.attributes(target) != nil { try disk.removeItem(at: target) }
        try disk.copyItem(at: source, to: target)
        return Staged(from: target, to: path.spec)
    }

    /// Every literal name a framework's picks mention, lowercased: a top folder of that name is the layout, not a
    /// wrapper.
    static func significantNames(of framework: ModFramework) -> Set<String> {
        var names: Set<String> = []
        for pick in framework.pick {
            for alternative in ModGlob.alternatives(pick.match) {
                for part in alternative.split(separator: "/") where !part.contains(where: { "*?[{".contains($0) }) { names.insert(part.lowercased()) }
            }
            pick.stripTo.map { names.insert($0.lowercased()) }
        }
        return names
    }

    static func isLiteral(_ pattern: String) -> Bool { !pattern.contains(where: { "*?{[".contains($0) }) }

    /// A Mac program in the Mac version's folder has no extension: the archive may have lost its mode bits.
    static func markExecutables(_ files: [URL]) {
        for file in files where file.pathExtension.isEmpty {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
    }

    // MARK: Settings

    /// Writes the framework's settings: into the staged copy when the file is one the framework places
    /// (`inGame` false), else into the game's file with its bytes kept first, or a new file recorded as the
    /// framework's (`inGame` true).
    private func applySettings(_ framework: ModFramework, staged: [Staged], record: inout Record, inGame: Bool) throws {
        for (index, edit) in framework.settings.enumerated() {
            guard let path = ModPath(edit.file) else { continue }
            let stagedFile = staged.first { $0.to == path.spec }
            guard (stagedFile == nil) == inGame else { continue }
            if let stagedFile {
                try ModSettings.write(edit, to: stagedFile.from)
                continue
            }
            guard let url = roots.resolve(path) else { continue }
            if FileScan.isRegularFile(url) {
                let backup = "\(index)-" + url.lastPathComponent
                let kept = folder(of: framework.id).appendingPathComponent(Self.settingsFolder, isDirectory: true).appendingPathComponent(backup)
                try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: kept)
                record.settingsBackups[path.spec] = .some(backup)
            } else {
                record.settingsBackups[path.spec] = .some(nil)
            }
            try ModSettings.write(edit, to: url)
        }
    }

    private func restoreSettings(_ record: Record) throws {
        let disk = FileManager.default
        for (spec, backup) in record.settingsBackups {
            guard let url = ModPath(spec).flatMap(roots.resolve) else { continue }
            if let backup {
                let kept = folder(of: record.id).appendingPathComponent(Self.settingsFolder, isDirectory: true).appendingPathComponent(backup)
                guard FileScan.isRegularFile(kept) else { continue }
                if FileScan.attributes(url) != nil { try disk.removeItem(at: url) }
                try disk.moveItem(at: kept, to: url)
            } else if FileScan.isRegularFile(url) {
                try disk.removeItem(at: url)
            }
        }
    }

    // MARK: The game's stale files

    /// Moves the files the framework's `remove` list names out of the game, into `removed/`, to come back with
    /// the uninstall.
    private func removeStale(_ framework: ModFramework, record: inout Record) throws {
        for spec in framework.remove {
            guard let path = ModPath(spec), let url = roots.resolve(path), FileScan.isRegularFile(url) else { continue }
            let relative = ([path.root.rawValue] + path.components).joined(separator: "/")
            let kept = URL(fileURLWithPath: ([folder(of: framework.id).path, Self.removedFolder, relative]).joined(separator: "/"))
            try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileScan.attributes(kept) != nil { try FileManager.default.removeItem(at: kept) }
            try FileManager.default.moveItem(at: url, to: kept)
            record.removed[path.spec] = relative
        }
    }

    private func restoreRemoved(_ record: Record) throws {
        for (spec, relative) in record.removed {
            guard let url = ModPath(spec).flatMap(roots.resolve) else { continue }
            let kept = URL(fileURLWithPath: ([folder(of: record.id).path, Self.removedFolder, relative]).joined(separator: "/"))
            guard FileScan.isRegularFile(kept), FileScan.attributes(url) == nil else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: kept, to: url)
        }
    }

    // MARK: Removing

    /// Takes a framework out: its files leave the game (the deployer's exact uninstall), the game's files it moved
    /// aside come back, its settings edits are undone, and the fixes it applied to the launch (`fixes`, the game's
    /// applied fixes with its rule id) are undone in the profile. The ones undone are returned for the app to drop.
    @discardableResult
    public func uninstall(_ id: String, fixes: [AppliedFix], launchProfile: inout LaunchProfile) throws -> (removal: ModDeployer.Removal, undone: [AppliedFix]) {
        guard let record = record(id) else { throw FrameworkInstallError.notInstalled(id) }
        // Settings first: a file the framework made leaves before the deployer prunes the folder it stands in.
        try restoreSettings(record)
        var removal = ModDeployer.Removal()
        // An unreadable record stops it here, before the framework's folder (the files the game's links share) goes.
        if try deployer.isDeployed(Self.owner(id)) { removal = try deployer.remove(owner: Self.owner(id)) }
        try restoreRemoved(record)
        let mine = fixes.filter { $0.ruleID == Self.ruleID(id) }
        Self.undo(mine, in: &launchProfile)
        try FileManager.default.removeItem(at: folder(of: id))
        let frameworks = store.folder.appendingPathComponent(Self.folderName, isDirectory: true)
        if ((try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []).allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: frameworks)
        }
        return (removal, mine)
    }

    /// The installed frameworks no enabled mod needs any more, when the profile wants them gone with the last mod
    /// (`cleanupOnLastCodeMod`): a framework is needed by a mod's units or by another needed framework.
    public func unneeded(mods: [StoredMod]) -> [String] {
        guard profile.notes.cleanupOnLastCodeMod else { return [] }
        var needed: Set<String> = []
        var queue = mods.filter(\.enabled).flatMap(\.frameworks)
        while let next = queue.popLast() {
            guard needed.insert(next).inserted else { continue }
            queue += profile.framework(next)?.requires ?? []
        }
        return installed().filter { !needed.contains($0) }
    }

    // MARK: The launch profile

    /// The fix actions a framework needs while it is on: its DLL overrides, its redirect and its arguments. A
    /// loader isn't one: `LaunchGuard` starts it.
    public static func launchFixes(of framework: ModFramework) -> [FixAction] {
        var actions: [FixAction] = framework.dllOverrides.keys.sorted().map { .overrideDLL($0, framework.dllOverrides[$0] ?? "") }
        if let redirect = framework.launch?.redirect { actions.append(.runExecutable(instead: redirect.instead, run: redirect.run)) }
        if let arguments = framework.launch?.arguments, !arguments.isEmpty { actions.append(.addArguments(arguments)) }
        return actions
    }

    /// Applies a profile-only fix action (an override, a redirect, arguments) to a launch profile, the way the
    /// app's Fix Launch does, and returns the applied fix with its undo. Nil for an action that needs the app.
    public static func apply(_ action: FixAction, to profile: inout LaunchProfile, ruleID: String, now: Date = Date()) -> AppliedFix? {
        switch action {
        case .overrideDLL(let dll, let mode):
            guard FixAction.overrideModes.contains(mode) else { return nil }
            let previous = profile.dllOverrides[dll]
            profile.dllOverrides[dll] = mode
            return AppliedFix(ruleID: ruleID, action: action, undo: .previousDLLOverride(dll, previous), date: now)
        case .runExecutable(let instead, let run):
            let previous = profile.redirect
            profile.redirect = ExecutableRedirect(instead: instead, run: run)
            return AppliedFix(ruleID: ruleID, action: action, undo: .previousExecutable(instead: previous?.instead, run: previous?.run), date: now)
        case .addArguments(let arguments):
            let previous = profile.extraArguments
            profile.extraArguments += arguments.filter { !previous.contains($0) }
            return AppliedFix(ruleID: ruleID, action: action, undo: .previousArguments(previous), date: now)
        default:
            return nil
        }
    }

    /// Puts back what `apply` changed, newest first.
    public static func undo(_ fixes: [AppliedFix], in profile: inout LaunchProfile) {
        for fix in fixes.sorted(by: { $0.date > $1.date }) {
            switch fix.undo {
            case .previousDLLOverride(let dll, let mode): profile.dllOverrides[dll] = mode
            case .previousExecutable(let instead, let run):
                profile.redirect = if let instead, let run { ExecutableRedirect(instead: instead, run: run) } else { nil }
            case .previousArguments(let arguments): profile.extraArguments = arguments
            default: break
            }
        }
    }

    // MARK: Files

    /// Every file below `top`, relative with forward slashes, sorted.
    static func relativePaths(in top: URL) -> [String] {
        let base = top.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: top, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var paths: [String] = []
        for case let item as URL in walker where (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = item.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            paths.append(String(path.dropFirst(base.count)))
        }
        return paths.sorted()
    }

    static func url(_ base: URL, _ relative: String) -> URL {
        URL(fileURLWithPath: ([base.path] + relative.split(separator: "/").map(String.init)).joined(separator: "/"))
    }
}

/// Writes a framework's settings into its file in the file's format, keeping everything else in it.
public enum ModSettings {
    /// Reads the file (none: an empty one), applies the edit and writes it back.
    public static func write(_ edit: ModFramework.SettingsEdit, to url: URL) throws {
        let disk = FileManager.default
        try disk.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: url)
        let output: Data
        switch edit.format {
        case .ini:
            output = Data(ini(String(decoding: existing ?? Data(), as: UTF8.self), set: edit.set).utf8)
        case .keyValue:
            output = Data(keyValue(String(decoding: existing ?? Data(), as: UTF8.self), set: edit.set).utf8)
        case .json:
            output = try json(existing, set: edit.set)
        }
        try output.write(to: url, options: .atomic)
    }

    /// `[Section]` blocks of `Key = Value` lines. Each value of `set` is a section (an object) whose keys are set
    /// in it; a plain value goes before the first section. Lines are matched by key, case-insensitive, and keep
    /// their own spacing around `=`; missing keys are added at the section's end, missing sections at the file's.
    public static func ini(_ text: String, set: [String: ModSettingValue]) -> String {
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: ending)
        if lines.last == "" { lines.removeLast() }
        for name in set.keys.sorted() {
            let section: String?, values: [String: ModSettingValue]
            if case .object(let fields) = set[name]! { section = name; values = fields } else { section = nil; values = [name: set[name]!] }
            var start = 0, end = lines.count
            if let section {
                if let header = lines.firstIndex(where: { isHeader($0, named: section) }) {
                    start = header + 1
                    end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
                } else {
                    if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false { lines.append("") }
                    lines.append("[\(section)]")
                    start = lines.count; end = lines.count
                }
            } else {
                end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.count
            }
            for key in values.keys.sorted() {
                let rendered = render(values[key]!)
                if let index = lines[start..<end].firstIndex(where: { keyOf($0)?.lowercased() == key.lowercased() }) {
                    lines[index] = replaceValue(in: lines[index], with: rendered)
                } else {
                    var insert = end
                    while insert > start, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
                    lines.insert("\(key) = \(rendered)", at: insert)
                    end += 1
                }
            }
        }
        return lines.joined(separator: ending) + ending
    }

    /// `Key=Value` lines without sections, matched by key; new ones go at the end.
    public static func keyValue(_ text: String, set: [String: ModSettingValue]) -> String {
        let ending = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: ending)
        if lines.last == "" { lines.removeLast() }
        for key in set.keys.sorted() {
            let rendered = render(set[key]!)
            if let index = lines.firstIndex(where: { keyOf($0)?.lowercased() == key.lowercased() }) {
                lines[index] = replaceValue(in: lines[index], with: rendered)
            } else {
                lines.append("\(key)=\(rendered)")
            }
        }
        return lines.joined(separator: ending) + ending
    }

    /// A JSON object with `set` merged in (objects deep, everything else replaced). A file that isn't an object
    /// becomes one.
    public static func json(_ data: Data?, set: [String: ModSettingValue]) throws -> Data {
        var object = data.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) as? [String: Any] } ?? [:]
        object = merge(object, set.mapValues(plain))
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in over {
            if let inner = value as? [String: Any], let existing = out[key] as? [String: Any] { out[key] = merge(existing, inner) } else { out[key] = value }
        }
        return out
    }

    private static func plain(_ value: ModSettingValue) -> Any {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? Int(number) as Any : number
        case .object(let fields): fields.mapValues(plain)
        }
    }

    static func render(_ value: ModSettingValue) -> String {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .object: ""
        }
    }

    static func isHeader(_ line: String, named section: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased() == section.lowercased()
    }

    static func keyOf(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// The line with a new value after its `=`, its spacing kept (`Key = old` → `Key = new`).
    static func replaceValue(in line: String, with value: String) -> String {
        guard let equals = line.firstIndex(of: "=") else { return line }
        let after = line[line.index(after: equals)...]
        let spaces = after.prefix(while: { $0 == " " || $0 == "\t" })
        return String(line[...equals]) + spaces + value
    }
}
