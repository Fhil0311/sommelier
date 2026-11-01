// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import os
import SommelierKit
import SwiftUI
import UniformTypeIdentifiers

/// A game's mods as the Mods page shows them: what the store holds, the load order (top wins), the conflicts
/// among the mods that are on, the loaders in place, and what "Check mod files" found.
struct GameMods: Equatable {
    var profile: ModProfile
    var mods: [StoredMod]
    var order: LoadOrder
    var conflicts: ModConflicts.Report
    var installedFrameworks: Set<String>
    /// Files out of place per owner (a mod's key, or `framework:<id>`), after "Check mod files".
    var findings: [String: [ModDeployer.Finding]] = [:]
    var checked = false
    /// A destination's root isn't there for this copy of the game: said once for the page, not per mod.
    var rootUnavailable = false

    var enabledCount: Int { mods.filter(\.enabled).count }
    func mod(_ key: String) -> StoredMod? { mods.first { $0.key == key } }
    /// Problems with a mod's own files, for its Repair line.
    func problems(of key: String) -> Int { (findings[key] ?? []).filter { $0.problem == .missing || $0.problem == .replaced }.count }
}

/// The sheet before a mod with code goes in: "This mod contains code", once per mod; with the profile's line
/// about the online policy when it has one. With no names it is the one-time notice alone, with OK.
struct ModConsent: Identifiable {
    let id = UUID()
    let game: Game
    /// The names of the mods with code from this archive.
    let names: [String]
    let noticeKey: String?
    /// Whether any of them has code of its own; without, they only bring in a loader that has (the sheet's
    /// sibling: "This mod needs a loader that runs code").
    var hasCode = true
    let answer: @MainActor (Bool) -> Void

    var noticeOnly: Bool { names.isEmpty }
}

/// A question the plan asks before the archive can be placed: which variant, or whether some files are a mod
/// of an uncertain kind. `nil` is the player's Cancel.
struct ModQuestion: Identifiable {
    let id = UUID()
    let game: Game
    let question: ModPlan.Question
    let answer: @MainActor (ModArchive.Answers?) -> Void
}

/// Other tools' loader files found in the game folder before a launch without mods: set them aside and play,
/// or don't play.
struct ModLeftovers: Identifiable {
    let id = UUID()
    let game: Game
    let specs: [String]
}

/// A short note on the mods page after a change: a mod turned off for a conflict (with Undo), files left in
/// the game after a removal (with Show in Finder), a clean check.
struct ModNotice: Equatable {
    enum Follow: Equatable { case undo([String]), reveal(URL) }
    let gameID: String
    let text: String
    var follow: Follow?
    let shown = Date()
}

/// The Mods page's tabs: the installed mods, the mod.io catalogue (for a game with one), the Nexus browser.
enum ModsTab: String, CaseIterable { case installed, catalog, nexus }

/// A loader whose archive comes through the Nexus tab: its page is open there, and the download that lands
/// and fits the profile's pattern goes to the install waiting on it. `nil` is the player's Cancel.
struct ModBrowserFetch: Identifiable {
    let id = UUID()
    let gameID: String
    let frameworkID: String
    let name: String
    let url: URL
    /// The file's pattern from the profile, when it has one.
    let filePattern: String?
    let answer: @MainActor (URL?) -> Void

    func accepts(_ fileName: String) -> Bool { filePattern.map { ModGlob.matchesName($0, fileName) } ?? true }
}

/// The mods' disk work, one job at a time and off the main thread: hashing an archive, linking or copying a
/// mod's files into a game on another disk, checking them before a launch. One queue, so two jobs never write
/// one game's `deployed.json` at once.
actor ModDiskWork {
    func run<T: Sendable>(_ job: @Sendable () throws -> T) throws -> T { try job() }
}

private let modDiskWork = ModDiskWork()

/// Mods in the app: the profiles list online says which games take mods and how; the kit's store, deployer,
/// load order, conflicts, framework installer, launch guard and diagnostics do the work; this is the flow
/// between them and the windows. Every name shown is a mod's display name, never a store key or a loader's id.
extension AppModel {
    // MARK: Profiles

    /// The game's mods profile, when the list has one for this copy (its runtime: a Mac version shows no mods
    /// section for a Windows profile and the other way round). Experimental entries stay hidden in release
    /// builds; a debug build shows them with SOMMELIER_DEBUG_EXPERIMENTAL_MODS=1.
    func modProfile(for game: Game) -> ModProfile? {
        guard game.isInstalled, let profile = modsList?.profile(for: game) else { return nil }
        if profile.status == .experimental {
            #if DEBUG
            guard ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_EXPERIMENTAL_MODS"] == "1" else { return nil }
            #else
            return nil
            #endif
        }
        return profile
    }

    func supportsMods(_ game: Game) -> Bool { modProfile(for: game) != nil }

    /// The installed games with a mods profile, by title, for the Mods page.
    var gamesWithMods: [Game] {
        visibleGames.filter(supportsMods).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The game the Mods page shows: the one chosen, else the first with mods.
    var modsPageGame: Game? {
        let games = gamesWithMods
        return games.first { $0.id == modsGame } ?? games.first
    }

    /// Opens the Mods page on this game (the game page's row).
    func showMods(for game: Game) {
        modsGame = game.id
        path = NavigationPath()
        selection = .mods
    }

    // MARK: The kit's pieces

    /// Everything the kit needs for a game's mods, built from its profile and paths. Nil without a profile.
    struct ModPieces: Sendable {
        let profile: ModProfile
        let roots: ModRoots
        let store: ModStore
        let deployer: ModDeployer
        let files: LoadOrderFiles
        let installer: FrameworkInstaller
        let guardian: LaunchGuard
    }

    func modPieces(for game: Game) -> ModPieces? {
        guard let profile = modProfile(for: game) else { return nil }
        let roots = ModRoots(game: game, bottle: game.isNative ? nil : Bottle(kind: game.store.bottleKind, paths: paths), paths: paths)
        let store = ModStore(paths: paths, gameID: game.id)
        let deployer = ModDeployer(roots: roots, store: store)
        return ModPieces(profile: profile, roots: roots, store: store, deployer: deployer,
                         files: LoadOrderFiles(profile: profile, deployer: deployer),
                         installer: FrameworkInstaller(profile: profile, deployer: deployer),
                         guardian: LaunchGuard(profile: profile, roots: roots))
    }

    private func modState(of game: Game) -> ModState { library.userData[game.id]?.mods ?? ModState() }

    private func setModState(_ state: ModState, for game: Game) {
        var data = library.userData[game.id] ?? UserGameData()
        data.mods = state
        library.userData[game.id] = data
        libraryStore.save(library)
    }

    /// The player's choice for a loader's own save file, or the profile's default.
    func separateSave(for game: Game) -> Bool {
        guard let pieces = modPieces(for: game) else { return false }
        return pieces.guardian.usesSeparateSave(playerChoice: modState(of: game).separateSave)
    }

    func setSeparateSave(_ on: Bool, for game: Game) {
        var state = modState(of: game)
        state.separateSave = on
        setModState(state, for: game)
    }

    /// The loader's one-line summary of the last session, for the mods page.
    func modsSummary(of game: Game) -> String? { modState(of: game).lastSummary }

    // MARK: Reading

    /// Reads the game's mods from its store and the game's files into `modsByGame`, keeping what a check found.
    func reloadMods(for game: Game) {
        guard let pieces = modPieces(for: game) else { modsByGame[game.id] = nil; return }
        let mods = pieces.store.list()
        let order = pieces.files.read(mods: mods)
        let installed = Set(pieces.installer.installed())
        let manifests = Dictionary(uniqueKeysWithValues: mods.map { ($0.key, ModConflicts.manifestFields(of: $0, store: pieces.store)) })
        let conflicts = ModConflicts.check(mods, profile: pieces.profile, order: order.keys, installedFrameworks: installed, manifests: manifests)
        var fresh = GameMods(profile: pieces.profile, mods: mods, order: order, conflicts: conflicts, installedFrameworks: installed)
        if let previous = modsByGame[game.id] {
            fresh.findings = previous.findings; fresh.checked = previous.checked; fresh.rootUnavailable = previous.rootUnavailable
        }
        modsByGame[game.id] = fresh
    }

    func mods(of game: Game) -> GameMods? { modsByGame[game.id] }

    /// How many of the game's mods are on, for the game page's row.
    func modsOnCount(of game: Game) -> Int { modsByGame[game.id]?.enabledCount ?? 0 }

    /// A mod's name for a fix that carries its key. The key is never shown.
    func modName(_ key: String, in game: Game) -> String {
        modsByGame[game.id]?.mod(key)?.name ?? ModStore(paths: paths, gameID: game.id).mod(key)?.name ?? String(localized: "a mod")
    }

    // MARK: Adding

    /// The archives the store can unpack (`tar` reads these).
    static let modArchiveTypes: [UTType] = [.zip, .gzip, .bz2, UTType("org.7-zip.7-zip-archive"), UTType("com.rarlab.rar-archive"),
                                            UTType("public.tar-archive"), UTType("org.tukaani.xz-archive")].compactMap { $0 }

    /// "Add from file…": the player picks an archive.
    func chooseModFile(for game: Game) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.modArchiveTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a mod archive for \(game.title)")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { for url in urls { await addMod(from: url, to: game) } }
    }

    /// Takes an archive into the game: unpacked into the store, planned against the profile, the plan's questions
    /// asked, the code sheet shown once, the loaders it needs installed, the saves backed up before the first
    /// mod, and the files placed with the new mod on top of the load order (it wins, as a new mod does in the
    /// managers players know). Nothing from the archive is ever run. `origin` says where the archive
    /// came from (the player's file unless a source handed it over); the archive itself is left where it is.
    func addMod(from url: URL, to game: Game, origin: StoredMod.Origin = .init(kind: .file)) async {
        guard let pieces = modPieces(for: game), activity == nil else { return }
        if let fetch = modBrowser {
            // A loader the install is waiting for, downloaded in the player's own browser and handed over by a drop
            // or "Add from File…": it goes to that install. Anything else waits until the loader is in.
            if fetch.gameID == game.id, fetch.accepts(url.lastPathComponent) { modBrowser = nil; fetch.answer(url); return }
            showPendingBrowserFetch()
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        activity = String(localized: "Installing \(name)…")
        defer { activity = nil }
        let store = pieces.store, profile = pieces.profile
        var unpacked: URL?
        defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
        do {
            let entries = try await store.entries(of: url)
            let folder = try await store.unpack(url)
            unpacked = folder
            let manifests = store.manifests(in: folder, entries: entries, profile: profile)
            var answers = ModArchive.Answers()
            var plan: ModPlan
            while true {
                plan = ModArchive.plan(paths: entries, profile: profile, archiveName: name, manifests: manifests, answers: answers)
                if let refusal = plan.refusal { errorMessage = Self.refusalText(refusal, archive: url.lastPathComponent); return }
                guard let question = plan.questions.first else { break }
                guard let given = await ask(question, for: game) else { return }
                if let variant = given.variant { answers.variant = variant }
                answers.kinds.merge(given.kinds) { _, new in new }
            }
            guard plan.isReady else { errorMessage = Self.refusalText(.init(reason: .nothingRecognised, path: nil), archive: url.lastPathComponent); return }

            // The loaders the mod needs: the kit fetches them, or the Nexus tab does when only a browser can.
            let needed = plan.frameworks.filter { !pieces.installer.isInstalled($0) }

            // "This mod contains code", once per mod; the policy's line with the first mod (or with the code). A
            // mod without code of its own that brings in a loader with code gets the same sheet: the loader's
            // code goes into the game with it (plan, framework sheet = code sheet).
            let codeNames = plan.units.filter(\.code).map(\.name)
            let loaderNames = plan.units.filter { $0.framework.map { !codeLoaders([$0], pieces: pieces).isEmpty } ?? false }.map(\.name)
            let sheetNames = Array(Set(codeNames + loaderNames)).sorted()
            let noticeDue = profile.online.noticeKey != nil && modState(of: game).noticeShown != true
            if !sheetNames.isEmpty || noticeDue {
                guard await consent(for: game, names: sheetNames, hasCode: !codeNames.isEmpty,
                                    noticeKey: noticeDue || !sheetNames.isEmpty ? profile.online.noticeKey : nil) else { return }
                if noticeDue { var state = modState(of: game); state.noticeShown = true; setModState(state, for: game) }
            }
            let accepted = !codeNames.isEmpty

            if store.list().isEmpty { await backUpSavesBeforeMods(game, pieces: pieces) }
            for id in needed { guard try await installFramework(id, for: game, pieces: pieces) else { return } }

            let mods = store.list()
            let modName = Self.modName(plan: plan, archive: name), taken = folder, ready = plan
            unpacked = nil                                             // the store takes the folder, or the job deletes it
            // Hashing the archive and moving its files are disk work, kept off the main thread.
            let mod = try await modDiskWork.run {
                do {
                    var mod = try store.add(name: modName, plan: ready, unpacked: taken, archive: url, origin: origin)
                    mod.codeAccepted = accepted
                    try store.save(mod)
                    return mod
                } catch {
                    try? FileManager.default.removeItem(at: taken)
                    throw error
                }
            }
            let order = LoadOrder(spec: profile.loadOrder, mods: mods + [mod], saved: [mod.key] + pieces.files.read(mods: mods).keys)
            try await place(mod, order: order, mods: mods + [mod], pieces: pieces, game: game)
            try await settleBlocks(after: mod.key, pieces: pieces, game: game)
        } catch {
            errorMessage = Self.errorText(error) ?? error.localizedDescription
        }
        reloadMods(for: game)
    }

    /// Archives dropped on the Mods page.
    func dropMods(_ providers: [NSItemProvider], on game: Game) -> Bool {
        let urls = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !urls.isEmpty else { return false }
        Task {
            for provider in urls {
                guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                      let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { continue }
                guard Self.modArchiveTypes.contains(where: { UTType(filenameExtension: url.pathExtension)?.conforms(to: $0) == true }) else { continue }
                await addMod(from: url, to: game)
            }
        }
        return true
    }

    /// The mod's name: a single unit's own name, else the archive's.
    private static func modName(plan: ModPlan, archive: String) -> String {
        let names = Array(Set(plan.units.map(\.name)))
        return names.count == 1 ? names[0] : archive
    }

    /// Places a mod with its slot from the order and writes the order, off the main thread. A mod UE4SS turns
    /// on through `mods.txt` gets its line there as it is placed.
    private func place(_ mod: StoredMod, order: LoadOrder, mods: [StoredMod], pieces: ModPieces, game: Game) async throws {
        let slots = LoadOrder.PrefixFolder.slots(for: order, mods: mods)
        let separate = separateSave(for: game)
        try await modDiskWork.run {
            try pieces.deployer.deploy(mod, slot: slots[mod.key])
            try pieces.files.apply(order, mods: mods, separateSave: separate)
        }
    }

    /// The loaders among `ids` (and those they require) that aren't installed yet and run code in the game.
    private func codeLoaders(_ ids: [String], pieces: ModPieces) -> [String] {
        var found: [String] = [], queue = ids, seen: Set<String> = []
        while let id = queue.popLast() {
            guard seen.insert(id).inserted, let framework = pieces.profile.framework(id) else { continue }
            queue += framework.requires
            if framework.code && !pieces.installer.isInstalled(id) { found.append(id) }
        }
        return found
    }

    /// A new or newly enabled mod that is in a block (two regulation.bin, a duplicate) wins: the others go off,
    /// and the page says so with Undo.
    private func settleBlocks(after key: String, pieces: ModPieces, game: Game) async throws {
        let mods = pieces.store.list()
        let order = pieces.files.read(mods: mods)
        let installed = Set(pieces.installer.installed())
        let manifests = Dictionary(uniqueKeysWithValues: mods.map { ($0.key, ModConflicts.manifestFields(of: $0, store: pieces.store)) })
        let report = ModConflicts.check(mods, profile: pieces.profile, order: order.keys, installedFrameworks: installed, manifests: manifests)
        let losers = Set(report.findings.filter { $0.severity == .block && $0.mods.contains(key) }.flatMap(\.mods)).subtracting([key])
        guard !losers.isEmpty else { return }
        let separate = separateSave(for: game)
        try await modDiskWork.run { for loser in losers.sorted() { try Self.switchMod(loser, on: false, pieces: pieces, separateSave: separate) } }
        let names = losers.sorted().compactMap { k in mods.first { $0.key == k }?.name }.joined(separator: ", ")
        modNotice = ModNotice(gameID: game.id, text: String(localized: "\(names) turned off: it can't be on together with \(modName(key, in: game))."),
                              follow: .undo(losers.sorted()))
    }

    // MARK: Switching, ordering, removing

    /// Turns a mod on or off. A blocked mod coming on turns the other one off (with Undo); the last mod with
    /// code going off takes its loader out when the profile says so.
    func setMod(_ key: String, enabled: Bool, in game: Game) {
        Task { await switchModNow(key, enabled: enabled, in: game) }
    }

    func switchModNow(_ key: String, enabled: Bool, in game: Game) async {
        guard let pieces = modPieces(for: game) else { return }
        let separate = separateSave(for: game)
        do {
            try await modDiskWork.run { try Self.switchMod(key, on: enabled, pieces: pieces, separateSave: separate) }
            if enabled { try await settleBlocks(after: key, pieces: pieces, game: game) }
            else { try await cleanUpFrameworks(for: game, pieces: pieces) }
        } catch {
            errorMessage = Self.errorText(error) ?? error.localizedDescription
        }
        reloadMods(for: game)
    }

    /// Turns a mod on or off in the game with its slot from the order, and writes the order (closing the gap
    /// a numbered pak leaves, rewriting `mods.txt` or the loader's list). Disk work: run on `modDiskWork`.
    nonisolated static func switchMod(_ key: String, on: Bool, pieces: ModPieces, separateSave: Bool) throws {
        guard var mod = pieces.store.mod(key), mod.enabled != on else { return }
        let mods = pieces.store.list()
        var order = pieces.files.read(mods: mods).setting(key, enabled: on)
        if on, !order.keys.contains(key) { order = LoadOrder(spec: pieces.profile.loadOrder, mods: mods, saved: [key] + order.keys) }
        let slots = LoadOrder.PrefixFolder.slots(for: order, mods: mods)
        try pieces.deployer.setEnabled(mod, on, slot: slots[key])
        mod.enabled = on
        try pieces.store.save(mod)
        let updated = mods.map { $0.key == key ? mod : $0 }
        try pieces.files.apply(order, mods: updated, separateSave: separateSave)
    }

    /// Fix Launch's "Turn off <mod>" and its undo: the same switch as the Mods page's, so the mod comes back in
    /// its own slot and the order is written again. False when the game has no mods profile here (the caller
    /// then works on the store alone).
    func switchModForFix(_ key: String, on: Bool, in game: Game) async throws -> Bool {
        guard let pieces = modPieces(for: game) else { return false }
        let separate = separateSave(for: game)
        try await modDiskWork.run { try Self.switchMod(key, on: on, pieces: pieces, separateSave: separate) }
        reloadMods(for: game)
        return true
    }

    /// Undo of a conflict's settling: the mods it turned off come back on.
    func undoModNotice(_ notice: ModNotice) {
        guard let game = library.games.first(where: { $0.id == notice.gameID }), case .undo(let keys)? = notice.follow else { return }
        modNotice = nil
        Task { for key in keys { await switchModNow(key, enabled: true, in: game) } }
    }

    /// Moves a mod to a position in the list (top wins) and writes the order into the game, on the disk queue
    /// behind whatever install or switch is still running. Never while the game runs: the folders it renames
    /// (RE4's paks) are the game's open files.
    func moveMod(_ key: String, to position: Int, in game: Game) {
        guard let pieces = modPieces(for: game), !isActive(game), let shown = modsByGame[game.id]?.order, shown.moving(key, to: position) != nil else { return }
        let separate = separateSave(for: game)
        Task {
            do {
                try await modDiskWork.run {
                    // The move is made on the list the player saw; one that changed meanwhile (a mod added, switched or
                    // removed by an earlier job) is left as it is now, and the page shows it.
                    let mods = pieces.store.list()
                    guard pieces.files.read(mods: mods) == shown, let moved = shown.moving(key, to: position) else { return }
                    try pieces.files.apply(moved, mods: mods, separateSave: separate)
                }
            } catch {
                errorMessage = Self.errorText(error) ?? error.localizedDescription
            }
            reloadMods(for: game)
        }
    }

    /// Takes a mod out of the game and the store, after the player confirms. Files the game changed since are
    /// never deleted: the page says how many stayed, with a way to them.
    func removeMod(_ key: String, from game: Game) {
        guard let pieces = modPieces(for: game), let mod = pieces.store.mod(key), !isActive(game) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove \(mod.name)?")
        alert.informativeText = String(localized: "Its files leave the game, and the game's own files come back.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let separate = separateSave(for: game)
        Task {
            do {
                let kept = try await modDiskWork.run {
                    var kept: [String] = []
                    // Even a mod only partly in the game (its record says so) is taken out before its store goes.
                    // An unreadable record stops it here, before the store copies the game's links share go.
                    if try pieces.deployer.isDeployed(key) { kept = try pieces.deployer.remove(owner: key).kept }
                    try pieces.store.remove(key)
                    let mods = pieces.store.list()
                    try pieces.files.apply(pieces.files.read(mods: mods), mods: mods, separateSave: separate)
                    return kept
                }
                try await cleanUpFrameworks(for: game, pieces: pieces)
                if !kept.isEmpty, let first = kept.first.flatMap(pieces.roots.resolve) {
                    modNotice = ModNotice(gameID: game.id, text: String(localized: "\(kept.count) files the game changed were left in place."),
                                          follow: .reveal(first))
                }
            } catch {
                errorMessage = Self.errorText(error) ?? error.localizedDescription
            }
            reloadMods(for: game)
        }
    }

    /// Opens a mod's files in Finder.
    func revealMod(_ key: String, in game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([ModStore(paths: paths, gameID: game.id).files(of: key)])
    }

    // MARK: Loaders

    /// Installs a framework the way the profile says: fetched and checked by the kit, placed into the game, its
    /// launch changes applied as fixes under `framework:<id>`, its components (a runtime) installed by the app.
    func installFramework(_ id: String, for game: Game) async {
        guard let pieces = modPieces(for: game), activity == nil else { return }
        guard modBrowser == nil else { showPendingBrowserFetch(); return }
        activity = String(localized: "Installing…")
        defer { activity = nil }
        // A loader with code gets the code sheet first, naming the mods that need it.
        if !codeLoaders([id], pieces: pieces).isEmpty {
            let needing = pieces.store.list().filter { $0.frameworks.contains(id) }.map(\.name)
            let names = needing.isEmpty ? [pieces.profile.framework(id)?.name ?? game.title] : Array(Set(needing)).sorted()
            guard await consent(for: game, names: names, noticeKey: pieces.profile.online.noticeKey) else { return }
        }
        do { _ = try await installFramework(id, for: game, pieces: pieces) }
        catch { errorMessage = Self.errorText(error) ?? error.localizedDescription }
        reloadMods(for: game)
    }

    /// Installs a framework after whatever it requires. One whose archive only a browser can fetch (an author's
    /// page, a Nexus mod) is fetched through the Nexus tab, the player downloading it there; the kit checks the
    /// hash as it does for any archive. False when the player cancelled that.
    private func installFramework(_ id: String, for game: Game, pieces: ModPieces) async throws -> Bool {
        guard let framework = pieces.profile.framework(id) else { throw FrameworkInstallError.unknownFramework(id) }
        for required in framework.requires where !pieces.installer.isInstalled(required) {
            guard try await installFramework(required, for: game, pieces: pieces) else { return false }
        }
        guard !pieces.installer.isInstalled(id) else { return true }
        // Nothing is fetched for a loader the list doesn't pin with a hash: it couldn't be installed anyway.
        guard FrameworkInstaller.isPinned(framework, in: pieces.profile) else { throw FrameworkInstallError.noHash(id) }
        var archive: URL?
        if Self.needsBrowser(framework, in: pieces.profile) {
            guard let url = Self.browserURL(for: framework, in: pieces.profile) else { throw FrameworkInstallError.needsBrowser(id) }
            guard let fetched = await fetchThroughBrowser(framework, at: url, for: game) else { return false }
            archive = fetched
        }
        // A fetched archive's folder goes with it; a file the player picked or dropped is theirs and stays.
        let fetchedHere = archive.map { $0.path.hasPrefix(downloadsFolder(for: game).path + "/") } ?? false
        defer { if let archive, fetchedHere { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
        // Fetched, checked and staged here; placed into the game on the disk queue, one job at a time with the
        // mods' own.
        let prepared = try await pieces.installer.prepare(id, archive: archive)
        let start = profile(for: game)
        let (installation, launch) = try await modDiskWork.run {
            var launch = start
            let installation = try pieces.installer.place(prepared, launchProfile: &launch)
            return (installation, launch)
        }
        setProfile(launch, for: game)
        var data = library.userData[game.id] ?? UserGameData()
        data.appliedFixes = (data.appliedFixes ?? []) + installation.fixes
        library.userData[game.id] = data
        libraryStore.save(library)
        await updateRedirects()
        for component in installation.components where !appliedFixes(of: game).map(\.action).contains(component) {
            await applyFix(FixRule(id: FrameworkInstaller.ruleID(id), cause: "", patterns: [], action: component), to: game, thenPlay: false)
        }
        return true
    }

    /// A framework the kit's downloader can't fetch: an author's page, a Nexus mod. An `inner` file goes by the
    /// archive it sits in.
    private static func needsBrowser(_ framework: ModFramework, in profile: ModProfile) -> Bool {
        var download = framework.download
        if download.kind == .inner, let outer = download.of, let host = profile.framework(outer) { download = host.download }
        return URLModDownloader.directURL(of: download) == nil
    }

    /// Takes out the loaders no enabled mod needs any more, when the profile wants them gone with the last mod
    /// with code (the game must not start with code inside). The files go on the disk queue;
    /// the launch changes of each loader that went are undone in the profile as it is then, even when a later
    /// one fails.
    private func cleanUpFrameworks(for game: Game, pieces: ModPieces) async throws {
        let fixes = library.userData[game.id]?.appliedFixes ?? []
        let start = profile(for: game)
        let (undone, failure): ([AppliedFix], (any Error)?) = try await modDiskWork.run {
            var launch = start, undone: [AppliedFix] = []
            for id in pieces.installer.unneeded(mods: pieces.store.list()).reversed() {
                do { undone += try pieces.installer.uninstall(id, fixes: fixes, launchProfile: &launch).undone }
                catch { return (undone, error) }
            }
            return (undone, nil)
        }
        if !undone.isEmpty {
            var launch = profile(for: game)
            FrameworkInstaller.undo(undone, in: &launch)
            setProfile(launch, for: game)
            var data = library.userData[game.id] ?? UserGameData()
            data.appliedFixes?.removeAll { fix in undone.contains { $0.id == fix.id } }
            library.userData[game.id] = data
            libraryStore.save(library)
            Task { await updateRedirects() }
        }
        if let failure { throw failure }
    }

    // MARK: Checking

    /// "Check mod files": what a game update replaced or removed, per mod, for the Repair lines.
    func checkModFiles(for game: Game) {
        Task { await checkModFilesNow(for: game) }
    }

    /// The check itself; the files are hashed off the main thread.
    private func checkModFilesNow(for game: Game) async {
        guard let pieces = modPieces(for: game) else { return }
        let findings = (try? await modDiskWork.run { pieces.deployer.verify() }) ?? []
        reloadMods(for: game)
        guard var current = modsByGame[game.id] else { return }
        current.findings = Dictionary(grouping: findings, by: \.owner)
        current.checked = true
        current.rootUnavailable = findings.contains { $0.problem == .rootUnavailable }
        modsByGame[game.id] = current
        if findings.isEmpty { modNotice = ModNotice(gameID: game.id, text: String(localized: "All mod files are in place."), follow: nil) }
    }

    /// Places a mod's missing or replaced files again, then checks again.
    func repairMod(_ key: String, in game: Game) {
        guard let pieces = modPieces(for: game), let findings = modsByGame[game.id]?.findings[key] else { return }
        Task {
            do { try await modDiskWork.run { _ = try pieces.deployer.repair(findings) } }
            catch { errorMessage = Self.errorText(error) ?? error.localizedDescription }
            await checkModFilesNow(for: game)
        }
    }

    /// Before each launch of a Mac version: Steam rewrites the `.app` whole with an update and takes the loader
    /// with it, so what the deployer placed is put back quietly (Stardew). Only there: in a Windows
    /// game's folder a file that replaced ours is the game's own update (an official RE4 patch), which "Check
    /// mod files" shows and the player repairs, never the launch behind their back.
    private func repairQuietly(_ pieces: ModPieces) async {
        guard pieces.profile.runtime == .native else { return }
        _ = try? await modDiskWork.run {
            let findings = pieces.deployer.verify().filter { $0.problem == .missing || $0.problem == .replaced }
            if !findings.isEmpty { try pieces.deployer.repair(findings) }
        }
    }

    // MARK: Saves

    /// Before the first mod: a copy of the saves, from the profile's folders (or the learned ones), so a mod
    /// that spoils a save costs nothing.
    private func backUpSavesBeforeMods(_ game: Game, pieces: ModPieces) async {
        guard backsUpSaves, modState(of: game).savesBackedUp != true else { return }
        let roots = modSaveRoots(of: game)
        let sources = pieces.profile.saves.isEmpty ? (library.userData[game.id]?.saveSources ?? []) : pieces.profile.saves
        guard !sources.isEmpty else { return }
        let store = saveBackupStore
        let made = await Task.detached(priority: .utility) {
            try? store.create(gameID: game.id, title: game.title, sources: sources, roots: roots, kind: .automatic)
        }.value
        var state = modState(of: game)
        state.savesBackedUp = true
        setModState(state, for: game)
        if let made {
            var data = library.userData[game.id] ?? UserGameData()
            data.lastSaveBackup = made.created
            if data.saveSources == nil { data.saveSources = sources }
            library.userData[game.id] = data
            libraryStore.save(library)
        }
    }

    /// The save roots for a game with mods: the bottle's for a Windows copy; for a Mac version only the home
    /// folder means anything (the profile's `home:` saves).
    private func modSaveRoots(of game: Game) -> SaveRoots {
        if game.isNative { return SaveRoots(profile: paths.home, steamUserdata: nil, install: game.installPath) }
        return saveRoots(of: game)
    }

    // MARK: Launching

    /// Before a launch (`play`): the launch guard decides the path from the profile's policy. Returns false when
    /// the launch is held: other tools' files in the game folder before a plain launch (the sheet offers to set
    /// them aside), or mods on where the policy allows only the loader and it isn't there. The loader's command
    /// waits in `modLoader` for the Steam path to start instead of the game.
    func guardMods(before game: Game) async -> Bool {
        modLoader[game.id] = nil
        guard let pieces = modPieces(for: game) else { return true }
        let mods = pieces.store.list()
        let enabled = mods.contains(where: \.enabled)
        if enabled || !pieces.installer.installed().isEmpty { await repairQuietly(pieces) }
        do {
            if enabled, pieces.profile.loadOrder.format == .loaderConfig {       // the loader's config, fresh for this launch
                let separate = separateSave(for: game)
                try await modDiskWork.run { try pieces.files.apply(pieces.files.read(mods: mods), mods: mods, separateSave: separate) }
            }
            switch try pieces.guardian.decide(modsEnabled: enabled, installed: Set(pieces.installer.installed())) {
            case .plain(let leftovers):
                if !leftovers.isEmpty { modLeftovers = ModLeftovers(game: game, specs: leftovers); return false }
            case .loader(let command):
                modLoader[game.id] = command
            }
        } catch LaunchGuard.Refusal.loaderRequired {
            errorMessage = String(localized: "With mods on, \(game.title) starts only through its mod loader, which isn't installed. Turn the mods off to play without it.")
            return false
        } catch {
            errorMessage = Self.errorText(error) ?? error.localizedDescription
            return false
        }
        return true
    }

    /// The leftovers sheet's answer: set the files aside (an applied fix, kept in the store's `.leftovers/`) and
    /// start the game.
    func setAsideLeftoversAndPlay(_ leftovers: ModLeftovers) async {
        modLeftovers = nil
        await applyFix(FixRule(id: "mods.leftovers", cause: "", patterns: [], action: .removeModLeftovers(leftovers.specs)), to: leftovers.game)
    }

    /// "Play without mods": every mod goes off (its loader with it when the profile says so), other tools'
    /// loader files are set aside, and the game starts the usual way. The mods stay off until switched on again.
    func playWithoutMods(_ game: Game) async {
        guard let pieces = modPieces(for: game), !isActive(game) else { return }
        do {
            let separate = separateSave(for: game)
            try await modDiskWork.run {
                for mod in pieces.store.list() where mod.enabled { try Self.switchMod(mod.key, on: false, pieces: pieces, separateSave: separate) }
            }
            try await cleanUpFrameworks(for: game, pieces: pieces)
            let foreign = pieces.guardian.playWithoutModsTargets(deployer: pieces.deployer).foreign
            if !foreign.isEmpty { try LaunchGuard.removeLeftovers(foreign, roots: pieces.roots, store: pieces.store, deployer: pieces.deployer) }
        } catch {
            errorMessage = Self.errorText(error) ?? error.localizedDescription
            return
        }
        reloadMods(for: game)
        await play(game)
    }

    /// Starts the profile's loader in Steam's environment instead of the game (Elden Ring's me3). The loader
    /// wants Steam beside it: started quietly first when it isn't running.
    func startModLoader(_ command: LaunchGuard.LoaderCommand, for game: Game, engine: Engine, profile: LaunchProfile, steamRunning: Bool) async throws -> RunningProcess {
        if command.steamInBottle, !steamRunning, running["steam"] == nil {
            let process = try steam.launchSteam(engine: engine, profile: profile, extraArguments: ["-silent"]) { _ in
                Task { @MainActor in self.running["steam"] = nil }
            }
            running["steam"] = process
            lastLog["steam"] = process.logURL
            let runner = WineRunner(paths: paths), bottle = steam.bottle
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, !(await runner.isBottleActive(engine: engine, bottle: bottle)) { try? await Task.sleep(for: .seconds(1)) }
            try? await Task.sleep(for: .seconds(10))                     // Steam's own start-up before it can be asked
        }
        return try WineRunner(paths: paths).run(engine: engine, bottle: steam.bottle, executable: command.executable.path, arguments: command.arguments,
                                                workingDirectory: command.workingDirectory, profile: profile, logID: game.id)
    }

    /// For a Mac version: the program the loader's redirect names (SMAPI beside Stardew Valley), when the mods
    /// profile applies and the loader is in place; nil starts the game the usual way.
    func modRedirect(for game: Game) -> URL? {
        guard game.isNative, let pieces = modPieces(for: game), let redirect = profile(for: game).redirect,
              let folder = game.installPath, let binaries = ModRoots.nativeBinaries(in: folder) else { return nil }
        guard pieces.profile.frameworks.contains(where: { $0.launch?.redirect?.run == redirect.run && pieces.installer.isInstalled($0.id) }) else { return nil }
        let url = binaries.appendingPathComponent(redirect.run)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Starts that program itself, from its folder, the way Steam for Mac would start the game.
    func startNativeRedirect(_ executable: URL, for game: Game) throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.arguments = profile(for: game).extraArguments
        try process.run()
    }

    // MARK: After a session

    /// The loader's own summary of the session (SMAPI's: how many mods loaded, which it skipped, which have
    /// updates), as one line for the mods page.
    func summariseMods(after game: Game, since start: Date) {
        guard let pieces = modPieces(for: game), pieces.profile.logs.contains(where: { $0.summary != nil }) else { return }
        let mods = pieces.store.list()
        guard mods.contains(where: \.enabled) else { return }
        let diagnostics = ModDiagnostics(profile: pieces.profile, roots: pieces.roots)
        Task {
            let summary = await Task.detached { diagnostics.collect(.init(mods: mods), since: start).summary }.value
            guard let summary else { return }
            var parts: [String] = []
            if let loaded = summary.loaded { parts.append(String(localized: "\(loaded) mods loaded")) }
            if !summary.skipped.isEmpty { parts.append(String(localized: "\(summary.skipped.count) skipped")) }
            if !summary.updates.isEmpty { parts.append(String(localized: "\(summary.updates.count) updates available")) }
            guard !parts.isEmpty else { return }
            var state = modState(of: game)
            state.lastSummary = parts.joined(separator: " · ")
            state.lastSummaryDate = Date()
            setModState(state, for: game)
        }
    }

    /// Whether mods were in play for a session, for the report's flag (a flag only; never which mods).
    func modsInPlay(_ game: Game) -> Bool? {
        guard let pieces = modPieces(for: game) else { return nil }
        return ModDiagnostics.inPlay(store: pieces.store, roots: pieces.roots) ? true : nil
    }

    // MARK: Fix Launch

    /// After a failed launch: the profile's logs read for fixes (a broken mod off, the loader off, the newest mod
    /// off), the diagnostics' mod flag and log tails set, every mod's name scrubbed out of the texts.
    func attachModDiagnostics(to diagnostics: inout LaunchDiagnostics, for game: Game, started: Date) -> [FixRules.Match] {
        guard let pieces = modPieces(for: game) else { return [] }
        let mods = pieces.store.list()
        let inPlay = ModDiagnostics.inPlay(store: pieces.store, roots: pieces.roots)
        guard inPlay || !mods.isEmpty else { return [] }
        let manifests = Dictionary(uniqueKeysWithValues: mods.map { ($0.key, ModConflicts.manifestFields(of: $0, store: pieces.store)) })
        let state = ModDiagnostics.State(mods: mods, installedFrameworks: Set(pieces.installer.installed()), manifests: manifests, applied: appliedFixes(of: game))
        return ModDiagnostics(profile: pieces.profile, roots: pieces.roots).attach(to: &diagnostics, state: state, inPlay: inPlay, since: started).matches
    }

    /// A fix's title with the mod's name in it (a key or a loader's id is never shown).
    func fixTitle(_ action: FixAction, for game: Game) -> String {
        switch action {
        case .disableMod(let key): String(localized: "Turn off \(modName(key, in: game))")
        case .disableFramework: String(localized: "Turn off mods for this game")
        default: action.localizedSummary
        }
    }

    /// The failure sheet's button for a fix.
    func fixButton(_ action: FixAction, for game: Game) -> String {
        switch action {
        case .disableMod(let key): String(localized: "Play without \(modName(key, in: game))")
        case .disableFramework: String(localized: "Play without mods")
        default: action.localizedButton
        }
    }

    /// Why a fix is offered, for the fixes about mods; other rules keep their own.
    func fixCause(_ rule: FixRule, for game: Game) -> String {
        let name: String = if case .disableMod(let key)? = rule.action { modName(key, in: game) } else { "" }
        return switch rule.id {
        case ModDiagnostics.brokenModRule: String(localized: "\(name) has an error that stops the game from starting.")
        case ModDiagnostics.loaderOutdatedRule: String(localized: "Mods for this game don't work with its latest update yet. Play without them until they're updated.")
        case ModDiagnostics.newestModRule: String(localized: "The game closed with an error while mods were on. \(name) was added last, so it's the most likely cause.")
        default: rule.localizedCause
        }
    }

    // MARK: Sources

    /// Where a game's browser downloads land before the store takes them: a dot folder in the game's store, which
    /// the store's listing ignores.
    private func downloadsFolder(for game: Game) -> URL { paths.mods(game.id).appendingPathComponent(".downloads", isDirectory: true) }

    /// The game's Nexus browser, made on first use with the game's front page.
    func nexusBrowser(for game: Game, domain: String) -> NexusBrowser {
        if let browser = nexusBrowsers[game.id] { return browser }
        let browser = NexusBrowser(game: game, folder: downloadsFolder(for: game)) { [weak self] file, page in
            self?.receiveBrowserDownload(file, page: page, for: game)
        }
        nexusBrowsers[game.id] = browser
        if let home = NexusBrowser.home(domain: domain) { browser.load(home) }
        return browser
    }

    /// The game's mod.io catalogue through our Worker; nil for a game whose profile names none.
    func modIOClient(for game: Game) -> ModIOClient? {
        guard let gameID = modProfile(for: game)?.sources.modio?.gameID else { return nil }
        return ModIOClient(gameID: gameID)
    }

    /// Install from a catalogue card: the file's link from the catalogue, the archive from mod.io's CDN, then
    /// the usual way in, with the card recorded as where the mod came from.
    func installFromCatalog(_ card: ModCard, in game: Game) async {
        guard let client = modIOClient(for: game), activity == nil, let fileID = card.fileToInstall else { return }
        guard modBrowser == nil else { showPendingBrowserFetch(); return }
        activity = String(localized: "Downloading \(card.name)…")
        let folder = downloadsFolder(for: game).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive: URL
        do {
            let link = try await client.link(for: fileID, of: card.id)
            archive = try await client.download(link, into: folder)
        } catch {
            activity = nil
            errorMessage = Self.errorText(error) ?? error.localizedDescription
            return
        }
        activity = nil
        let file = card.file?.id == fileID ? card.file : ModFileRef(id: fileID, name: archive.lastPathComponent)
        await addMod(from: archive, to: game, origin: client.origin(for: card, file: file))
    }

    /// A file the Nexus tab took: the archive a waiting loader asked for, else a mod going in as from a file.
    /// The download's folder goes once the archive is used.
    func receiveBrowserDownload(_ file: URL, page: URL?, for game: Game) {
        if let fetch = modBrowser, fetch.gameID == game.id {
            guard fetch.accepts(file.lastPathComponent) else {
                nexusBrowsers[game.id]?.status = .wrongFile(fetch.name)
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                return
            }
            modBrowser = nil
            fetch.answer(file)
            return
        }
        Task {
            await addMod(from: file, to: game, origin: .init(kind: .nexus, url: page?.absoluteString))
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    /// Opens the loader's page in the Nexus tab and waits for the archive the player downloads there. The
    /// install's activity line steps aside meanwhile: the player is browsing, not waiting.
    private func fetchThroughBrowser(_ framework: ModFramework, at url: URL, for game: Game) async -> URL? {
        let download = framework.download
        let held = activity
        activity = nil
        defer { activity = held }
        showMods(for: game)
        modsTab = .nexus
        // Only one loader page waits at a time: one still waiting (it can't be, while installs check
        // `modBrowser`) is answered as cancelled rather than left hanging.
        if let waiting = modBrowser { waiting.answer(nil) }
        return await withCheckedContinuation { continuation in
            modBrowser = ModBrowserFetch(gameID: game.id, frameworkID: framework.id, name: framework.name, url: url,
                                         filePattern: download.kind == .url ? download.file : nil) { file in
                self.modBrowser = nil
                continuation.resume(returning: file)
            }
        }
    }

    /// The page the Nexus tab opens for a loader: its files tab on Nexus, or the author's page. Nil for one the
    /// tab can't bring (a file inside another archive that itself needs the browser).
    static func browserURL(for framework: ModFramework, in profile: ModProfile) -> URL? {
        let download = framework.download
        let url: URL? = switch download.kind {
        case .nexus: download.mod.flatMap { NexusBrowser.files(domain: download.domain ?? profile.sources.nexus?.domain ?? "", mod: $0) }
        case .url: download.url.flatMap(URL.init(string:))
        case .github, .inner: nil
        }
        return url?.scheme == "https" ? url : nil
    }

    /// Another install asked for while a loader's page waits in the Nexus tab: that tab again, with its Cancel,
    /// instead of a second wait that would leave the first one hanging.
    private func showPendingBrowserFetch() {
        guard let fetch = modBrowser, let game = library.games.first(where: { $0.id == fetch.gameID }) else { return }
        showMods(for: game)
        modsTab = .nexus
    }

    /// The Nexus tab's Cancel while a loader's page is open: the install stops, nothing was placed.
    func cancelBrowserFetch(_ fetch: ModBrowserFetch) {
        guard modBrowser?.id == fetch.id else { return }
        fetch.answer(nil)
    }

    /// The Nexus tab's way out: the page in the player's own browser. The archive comes back the way any file
    /// does, dropped on the window or picked with "Add from File…": Downloads isn't watched, as macOS would ask
    /// the player to let Sommelier into that folder.
    func openNexusInBrowser(_ game: Game, url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Questions and sheets

    private func ask(_ question: ModPlan.Question, for game: Game) async -> ModArchive.Answers? {
        await withCheckedContinuation { continuation in
            modQuestion = ModQuestion(game: game, question: question) { answers in
                self.modQuestion = nil
                continuation.resume(returning: answers)
            }
        }
    }

    private func consent(for game: Game, names: [String], hasCode: Bool = true, noticeKey: String?) async -> Bool {
        await withCheckedContinuation { continuation in
            modConsent = ModConsent(game: game, names: names, noticeKey: noticeKey, hasCode: hasCode) { answer in
                self.modConsent = nil
                continuation.resume(returning: answer)
            }
        }
    }

    // MARK: Words

    /// Why an archive can't go in, in the player's words.
    static func refusalText(_ refusal: ModPlan.Refusal, archive: String) -> String {
        switch refusal.reason {
        case .unsafePath: String(localized: "\(archive) has files that would land outside the game folder, so it can't be installed.")
        case .rejected(let reason):
            switch reason {
            case "executable": String(localized: "\(archive) contains a program. Sommelier doesn't install mods that come with programs.")
            case "saveFile": String(localized: "\(archive) is a save file, not a mod.")
            case "legacyFormat": String(localized: "\(archive) is made for an older version of the game and can't be installed.")
            case "configOnly": String(localized: "\(archive) holds only a mod's settings, not the mod itself.")
            case "reshade": String(localized: "\(archive) is a ReShade preset, which Sommelier doesn't install.")
            case "loader": String(localized: "\(archive) is the mod loader itself. Sommelier installs it when a mod needs it.")
            case "eacToggler": String(localized: "\(archive) is an anti-cheat switch. Sommelier starts the game with mods without the anti-cheat, so there is nothing to install.")
            default: String(localized: "\(archive) can't be installed as a mod for this game.")
            }
        case .incompleteTriple: String(localized: "\(archive) is missing part of its files, so it can't be installed.")
        case .nothingRecognised, .empty: String(localized: "\(archive) doesn't look like a mod for this game.")
        }
    }

    /// The kit's reasons in the player's words; nil for an error that explains itself.
    static func errorText(_ error: Error) -> String? {
        switch error {
        case FrameworkInstallError.hashMismatch, FrameworkInstallError.noHash:
            String(localized: "The mod loader's download isn't the file Sommelier expected, so nothing was installed.")
        case FrameworkInstallError.needsBrowser, FrameworkInstallError.downloadFailed:
            String(localized: "The mod loader couldn't be downloaded. Check the connection and try again.")
        case FrameworkInstallError.nothingPicked, FrameworkInstallError.innerMissing:
            String(localized: "The mod loader's download isn't the file Sommelier expected, so nothing was installed.")
        case ModStoreError.unsafeArchive, ModStoreError.extractFailed:
            String(localized: "The archive couldn't be unpacked.")
        case ModDeployError.rootUnavailable:
            String(localized: "A folder the mod needs can't be reached for this copy of the game.")
        case ModSourceError.notConfigured:
            String(localized: "The mod catalogue isn't available yet.")
        case ModSourceError.rateLimited:
            String(localized: "The mod catalogue has had enough requests from this Mac for today. Try again tomorrow.")
        case ModSourceError.notFound, ModSourceError.linkExpired, ModSourceError.badAnswer, ModSourceError.failed:
            String(localized: "The mod catalogue couldn't be reached. Check the connection and try again.")
        default:
            nil
        }
    }
}
