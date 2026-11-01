// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The Stardew Valley profile for the Mac version of the game: SMAPI unpacked out of its installer zip into
/// `Stardew Valley.app/Contents/MacOS` without the installer ever running, mods as `manifest.json` folders under
/// `Mods/` with a dot in front when off, no load order (SMAPI sorts by dependencies), content packs that need
/// their host mod, the loader's log after a failed launch, and the deployment put back after Steam has replaced
/// the whole `.app`. The Windows copy under Wine shows no mods section at all.
struct StardewValleyModsTests {
    /// Hands out archives made for the test by the asset name the profile names.
    private struct StubDownloader: ModDownloader {
        var archives: [String: URL]

        func download(_ download: ModDownload, into folder: URL) async throws -> URL {
            guard let source = archives[download.asset ?? ""] else { throw FrameworkInstallError.downloadFailed("no stub for \(download)") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }

    /// The Steam install with the Mac version's `.app`, Sommelier's folders and a Mac home, all temporary. The
    /// roots are made the way the app makes them for a Mac version, so `game:` is `Contents/MacOS` and the
    /// Windows roots are absent.
    private struct Bench {
        let root: URL, install: URL, app: URL, game: URL, home: URL
        let store: ModStore, deployer: ModDeployer, profile: ModProfile
        var launch = LaunchProfile()

        static let gameFiles = ["Stardew Valley": "#!/bin/sh\nlauncher", "Stardew Valley.dll": "MZ game 1.6.15", "Stardew Valley.deps.json": "{\"deps\": 1}",
                                "Content/Data/Achievements.xnb": "xnb"]

        init(_ profile: ModProfile) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-stardew-\(UUID().uuidString)", isDirectory: true)
            install = root.appendingPathComponent("steamapps/common/Stardew Valley", isDirectory: true)
            app = install.appendingPathComponent("Stardew Valley.app", isDirectory: true)
            game = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            try StardewValleyModsTests.layout(Self.gameFiles, in: game)
            let steamCopy = Game(store: .steam, storeID: "413150", title: "Stardew Valley", isInstalled: true, installPath: install, native: true)
            let roots = ModRoots(game: steamCopy, bottle: nil, paths: Paths(home: root.appendingPathComponent("Support", isDirectory: true)), home: home)
            store = ModStore(folder: roots.store)
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        /// A mod in the store, made from a layout planned against the profile with its manifests read.
        func stored(_ name: String, _ files: [String: String]) throws -> StoredMod {
            let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
            try StardewValleyModsTests.layout(files, in: unpacked)
            let manifests = store.manifests(in: unpacked, entries: Array(files.keys), profile: profile)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name, manifests: manifests)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }

        /// A zip of the layout (text or bytes), made with `tar`, as `name` in a scratch folder of the bench.
        func archive(_ name: String, _ files: [String: Data]) async throws -> URL {
            let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
            try StardewValleyModsTests.layout(files, in: source)
            let folder = root.appendingPathComponent("archives-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = folder.appendingPathComponent(name)
            let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", archive.path, "--format", "zip", "-C", source.path, "."])
            try #require(made.succeeded, Comment(rawValue: made.output))
            return archive
        }

        func archive(_ name: String, _ files: [String: String]) async throws -> URL {
            try await archive(name, files.mapValues { Data($0.utf8) })
        }
    }

    static func layout(_ files: [String: Data], in root: URL) throws {
        for (path, bytes) in files {
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
    }

    static func layout(_ files: [String: String], in root: URL) throws {
        try layout(files.mapValues { Data($0.utf8) }, in: root)
    }

    /// The fixture's Stardew entry, with SMAPI's hash pointed at a stub archive when a test installs it.
    private func profile(smapiHash: String? = nil) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var games = try #require(json["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["game"] as? String == "steam:413150" })
        if let smapiHash {
            var frameworks = try #require(games[index]["frameworks"] as? [[String: Any]])
            for i in frameworks.indices where frameworks[i]["id"] as? String == "smapi" {
                var download = try #require(frameworks[i]["download"] as? [String: Any])
                download["sha256"] = smapiHash
                frameworks[i]["download"] = download
            }
            games[index]["frameworks"] = frameworks
        }
        json["games"] = games
        let list = try JSONDecoder().decode(ModsList.self, from: try JSONSerialization.data(withJSONObject: json))
        return try #require(list.profile(covering: "steam:413150"))
    }

    private func game(_ id: String, store: StoreKind = .steam, native: Bool) -> Game {
        Game(store: store, storeID: id, title: id, isInstalled: true, installPath: nil, native: native)
    }

    /// Every file and folder below `root` with the files' bytes.
    private func snapshot(_ root: URL) -> [String: Data] {
        var tree: [String: Data] = [:]
        let top = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return tree }
        for case let item as URL in walker {
            let relative = String(item.resolvingSymlinksInPath().path.dropFirst(top.count + 1))
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { tree[relative + "/"] = Data() } else { tree[relative] = (try? Data(contentsOf: item)) ?? Data() }
        }
        return tree
    }

    private func inode(_ url: URL) -> UInt64? { (FileScan.attributes(url)?[.systemFileNumber] as? NSNumber)?.uint64Value }
    private func isExecutable(_ url: URL) -> Bool { ((FileScan.attributes(url)?[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0 }

    /// A stored mod as the diagnostics see it, without a store.
    private func mod(_ name: String, key: String, kind: ModKind, folder: String, files: [String], added: TimeInterval) -> StoredMod {
        StoredMod(key: key, name: name, version: nil, author: nil, origin: .init(), archive: .init(name: name + ".zip"),
                  added: Date(timeIntervalSince1970: added), enabled: true, codeAccepted: true,
                  units: [ModPlan.Unit(kind: kind, name: folder, root: "", code: kind.code, framework: kind.framework,
                                       files: files.map { .init(source: $0, destination: "game:Mods/\(folder)/\($0)", skipped: false) })], leftovers: [])
    }

    // MARK: Manifests and archives, as they come from Nexus

    static func manifest(_ name: String, id: String, dll: String? = nil, packFor: String? = nil, version: String = "1.0.0") -> String {
        var fields = [#""Name": "\#(name)""#, #""Author": "someone""#, #""Version": "\#(version)""#, #""Description": "A mod.""#, #""UniqueID": "\#(id)""#]
        if let dll { fields.append(#""EntryDll": "\#(dll)""#) }
        if let packFor { fields.append(#""ContentPackFor": { "UniqueID": "\#(packFor)" }"#) }
        return "{\n  " + fields.joined(separator: ",\n  ") + "\n}\n"
    }

    static let lookupAnything = ["LookupAnything/LookupAnything.dll": "MZ lookup", "LookupAnything/LookupAnything.pdb": "pdb",
                                 "LookupAnything/manifest.json": manifest("Lookup Anything", id: "Pathoschild.LookupAnything", dll: "LookupAnything.dll"),
                                 "LookupAnything/i18n/default.json": "{}", "LookupAnything/README.txt": "readme"]
    static let contentPatcher = ["ContentPatcher/ContentPatcher.dll": "MZ cp", "ContentPatcher/manifest.json": manifest("Content Patcher", id: "Pathoschild.ContentPatcher", dll: "ContentPatcher.dll", version: "2.9.1"),
                                 "ContentPatcher/i18n/default.json": "{}"]
    static let pamPack = ["[CP] Pam in Shipping Bin/manifest.json": manifest("Pam in Shipping Bin", id: "someone.PamInShippingBin", packFor: "Pathoschild.ContentPatcher"),
                          "[CP] Pam in Shipping Bin/content.json": "{\"Changes\": []}", "[CP] Pam in Shipping Bin/assets/pam.png": "png"]

    /// The installer zip as the release ships it: the three install scripts, a README, and under `internal/` one
    /// folder per platform with the installer program and its `install.dat` (a zip of the files to place).
    private func installerZip(_ bench: Bench) async throws -> URL {
        let mac = try await bench.archive("install.dat", [
            "StardewModdingAPI": "#!apphost", "StardewModdingAPI.dll": "MZ smapi", "StardewModdingAPI.runtimeconfig.json": "{}", "StardewModdingAPI.xml": "<doc/>",
            "steam_appid.txt": "413150", "unix-launcher.sh": "#!/usr/bin/env bash\n./StardewModdingAPI \"$@\"\n",
            "smapi-internal/config.json": "{\"CheckForUpdates\": true}", "smapi-internal/metadata.json": "{}", "smapi-internal/0Harmony.dll": "MZ harmony",
            "smapi-internal/i18n/default.json": "{}",
            "Mods/ConsoleCommands/ConsoleCommands.dll": "MZ console", "Mods/ConsoleCommands/manifest.json": Self.manifest("Console Commands", id: "SMAPI.ConsoleCommands", dll: "ConsoleCommands.dll"),
            "Mods/SaveBackup/SaveBackup.dll": "MZ backup", "Mods/SaveBackup/manifest.json": Self.manifest("Save Backup", id: "SMAPI.SaveBackup", dll: "SaveBackup.dll"),
        ])
        let windows = try await bench.archive("install.dat", ["StardewModdingAPI.exe": "MZ win", "StardewModdingAPI.dll": "MZ smapi", "smapi-internal/config.json": "{}"])
        let top = "SMAPI 4.5.2 installer/"
        return try await bench.archive("SMAPI-4.5.2-installer.zip", [
            top + "install on macOS.command": Data("#!/usr/bin/env bash\n".utf8), top + "install on Linux.sh": Data("#!/usr/bin/env bash\n".utf8),
            top + "install on Windows.bat": Data("@echo off\r\n".utf8), top + "README.txt": Data("Unzip and run.".utf8),
            top + "internal/macOS/install.dat": try Data(contentsOf: mac), top + "internal/macOS/SMAPI.Installer": Data("#!apphost".utf8),
            top + "internal/macOS/SMAPI.Installer.dll": Data("MZ installer".utf8),
            top + "internal/linux/install.dat": try Data(contentsOf: mac), top + "internal/linux/SMAPI.Installer": Data("#!apphost".utf8),
            top + "internal/windows/install.dat": try Data(contentsOf: windows), top + "internal/windows/SMAPI.Installer.exe": Data("MZ installer".utf8),
        ])
    }

    // MARK: The profile

    @Test func profileServesTheMacVersionAndChangesOnlyTheProgramStarted() throws {
        let stardew = try profile()
        #expect(stardew.status == .ready && stardew.runtime == .native && stardew.aliases == ["gog:1453375253"])
        #expect(stardew.sources.nexus?.domain == "stardewvalley" && stardew.sources.modio == nil && stardew.sources.other.isEmpty)
        // The Mac version shows the section, under Steam or GOG; the Windows copy under Wine never does.
        #expect(stardew.applies(to: game("413150", native: true)) && stardew.applies(to: game("1453375253", store: .gog, native: true)))
        #expect(!stardew.applies(to: game("413150", native: false)) && !stardew.applies(to: game("1453375253", store: .gog, native: false)))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))))
        #expect(list.profile(for: game("413150", native: false)) == nil && list.profile(for: game("413150", native: true))?.game == "steam:413150")

        let smapi = try #require(stardew.framework("smapi"))
        #expect(stardew.frameworks.map(\.id) == ["smapi"] && smapi.code && !smapi.optional && smapi.license == "MIT" && smapi.requires.isEmpty)
        #expect(smapi.download.kind == .github && smapi.download.repo == "Pathoschild/SMAPI" && smapi.download.asset == "SMAPI-4.5.2-installer.zip")
        #expect(smapi.download.tag == "4.5.2" && smapi.download.sha256?.count == 64 && !smapi.download.viaBrowser, "the hash pins one release, so the tag must too")
        #expect(smapi.pick.map(\.match) == ["internal/macOS/install.dat"] && smapi.pick.first?.unpack == true && smapi.pick.first?.to == "game:")
        #expect(smapi.copyAs == [.init(from: "game:Stardew Valley.deps.json", to: "game:StardewModdingAPI.deps.json")])
        #expect(smapi.launch?.redirect == .init(instead: "Stardew Valley", run: "StardewModdingAPI") && smapi.launch?.loader == nil && smapi.launch?.arguments == nil)
        #expect(smapi.dllOverrides.isEmpty && smapi.components.isEmpty && smapi.settings.isEmpty && smapi.remove.isEmpty && smapi.skip.isEmpty && smapi.disableArgument == nil,
                "a Mac program: nothing of Wine, and the game's own files are left alone")
        #expect(FrameworkInstaller.launchFixes(of: smapi) == [.runExecutable(instead: "Stardew Valley", run: "StardewModdingAPI")])

        #expect(stardew.kinds.map(\.id) == ["mod"])
        let mod = try #require(stardew.kind("mod"))
        #expect(mod.unit == .folder && mod.marker == "manifest.json" && mod.match == "**/manifest.json" && mod.framework == "smapi")
        #expect(mod.code && mod.codeIf == "manifest.EntryDll" && mod.to == "game:Mods/{name}/" && mod.order == .none && mod.pinned == nil && !mod.ask)
        #expect(mod.enable == .init(format: .dotPrefix, file: nil) && mod.keepOnUpdate == ["config.json"] && !mod.backupOriginal)
        #expect(stardew.loadOrder.format == .dependencies && !stardew.loadOrder.isReorderable && stardew.loadOrder.file == nil)
        #expect(stardew.conflicts.samePath == .block && stardew.conflicts.rules.map(\.reason) == ["duplicateMod"] && stardew.conflicts.rules.first?.field == "manifest.UniqueID" && stardew.conflicts.rules.first?.max == 1)
        #expect(stardew.conflicts.needs == .init(field: "manifest.ContentPackFor.UniqueID", label: "needsFramework"))
        #expect(stardew.archive.wrappers && stardew.archive.variants == nil && stardew.archive.deny.isEmpty)
        #expect(stardew.archive.reject.map(\.reason) == ["loader", "legacyFormat", "executable", "configOnly"])
        #expect(ModArchiveRules.defaultIgnore.allSatisfy { stardew.archive.ignore.contains($0) } && stardew.archive.ignore.contains("**/__folder_managed_by_vortex"),
                "the profile's own ignore list replaces the default one, so it must carry it")
        #expect(stardew.logs.map(\.file) == ["home:.config/StardewValley/ErrorLogs/SMAPI-latest.txt"] && stardew.logs.first?.summary == .smapi && stardew.logs.first?.exists == nil)
        #expect(stardew.logs.first?.rules.map(\.byUniqueID) == [false, true] && stardew.logs.first?.rules.allSatisfy { $0.action == .disableMod && $0.modFrom == 1 } == true)
        #expect(stardew.saves == [SaveSource(root: .home, path: ".config/StardewValley/Saves")])
        #expect(stardew.online.policy == .allowed && stardew.online.moddedLaunch == .same && stardew.online.antiCheat == nil && stardew.online.separateSave == nil)
        #expect(stardew.online.cleanBeforeVanilla.isEmpty && stardew.online.playWithoutModsRemoves.isEmpty && stardew.online.noticeKey == nil)
        #expect(stardew.notes.gameVersionFile == "game:Stardew Valley.dll" && !stardew.notes.cleanupOnLastCodeMod && stardew.notes.untouched.isEmpty,
                "SMAPI stays when the last mod goes: it is the game's loader, not a code mod's dependency")

        // The launch is the game's usual one; the redirect is the launch profile's business, not the guard's.
        let bench = try Bench(stardew)
        let guardian = LaunchGuard(profile: stardew, roots: bench.deployer.roots)
        #expect(guardian.allowsPlainLaunch(modsEnabled: true) && guardian.loaderFramework == nil)
        #expect(try guardian.decide(modsEnabled: true, installed: ["smapi"]) == .plain(leftovers: []))
        #expect(try guardian.decide(modsEnabled: true, installed: []) == .plain(leftovers: []))
        // The roots of a Mac version: the `.app` inside the Steam folder, no Windows folders, the Mac home.
        let roots = bench.deployer.roots
        #expect(roots.game == bench.game && roots.appdata == nil && roots.roaming == nil && roots.documents == bench.home.appendingPathComponent("Documents", isDirectory: true))
        #expect(roots.resolve("game:Mods/")?.path == bench.game.appendingPathComponent("Mods").path)
        #expect(roots.resolve("home:.config/StardewValley/ErrorLogs/SMAPI-latest.txt")?.path == bench.home.appendingPathComponent(".config/StardewValley/ErrorLogs/SMAPI-latest.txt").path)
        #expect(roots.resolve("roaming:StardewValley/") == nil, "the Windows log place means nothing to the Mac version")
        // The game's version is the game's library: a patch changes the stamp.
        let first = try #require(ModGameVersion.stamp(profile: stardew, roots: roots))
        try Self.layout(["Stardew Valley.dll": "MZ game 1.6.16"], in: bench.game)
        #expect(ModGameVersion.changed(since: first, profile: stardew, roots: roots))
    }

    // MARK: Archives

    @Test func archivesAreManifestFoldersAtAnyDepth() throws {
        let stardew = try profile()
        func manifests(_ files: [String: String]) -> [String: Data] {
            files.filter { $0.key.hasSuffix("manifest.json") }.mapValues { Data($0.utf8) }
        }
        // A single C# mod: the one folder is the mod, the readme stays out, and the manifest's `EntryDll` says Code.
        let lookup = ModArchive.plan(paths: Array(Self.lookupAnything.keys), profile: stardew, archiveName: "Lookup Anything 1.55.0-541-1-55-0", manifests: manifests(Self.lookupAnything))
        let unit = try #require(lookup.units.first)
        #expect(lookup.isReady && lookup.units.count == 1 && lookup.base == "LookupAnything" && lookup.notes == [.wrapperRemoved("LookupAnything")])
        #expect(unit.kind.id == "mod" && unit.name == "LookupAnything" && unit.code && unit.framework == "smapi" && unit.root.isEmpty)
        #expect(unit.files.map(\.destination) == ["game:Mods/LookupAnything/LookupAnything.dll", "game:Mods/LookupAnything/LookupAnything.pdb", "game:Mods/LookupAnything/i18n/default.json", "game:Mods/LookupAnything/manifest.json"])
        #expect(lookup.leftovers.isEmpty && lookup.frameworks == ["smapi"] && lookup.containsCode)
        // Without its manifest read, a mod is taken for code, never the other way round.
        #expect(ModArchive.plan(paths: Array(Self.lookupAnything.keys), profile: stardew).units.first?.code == true)

        // A Content Patcher pack: no `EntryDll`, so no Code chip; the pack's name keeps its `[CP]` prefix.
        let pam = ModArchive.plan(paths: Array(Self.pamPack.keys), profile: stardew, archiveName: "(CP) Pam in Shipping Bin-1849-1-0-0", manifests: manifests(Self.pamPack))
        let pack = try #require(pam.units.first)
        #expect(pam.isReady && pam.units.count == 1 && !pack.code && pack.name == "[CP] Pam in Shipping Bin" && pack.framework == "smapi")
        #expect(pack.files.map(\.destination) == ["game:Mods/[CP] Pam in Shipping Bin/assets/pam.png", "game:Mods/[CP] Pam in Shipping Bin/content.json", "game:Mods/[CP] Pam in Shipping Bin/manifest.json"])
        #expect(!pam.containsCode)

        // Nexus wraps a mod in a versioned folder: the wrapper comes off, the mod's own folder names it.
        let wrapped = ModArchive.plan(paths: Self.contentPatcher.keys.map { "Content Patcher 2.9.1/" + $0 }, profile: stardew)
        #expect(wrapped.units.map(\.name) == ["ContentPatcher"] && wrapped.base == "Content Patcher 2.9.1" && wrapped.units.first?.root == "ContentPatcher")
        #expect(wrapped.units.first?.files.map(\.destination).contains("game:Mods/ContentPatcher/manifest.json") == true)

        // Stardew Valley Expanded: one zip, one wrapper, three mods: the C# one, the CP pack and the FTM pack.
        var sve: [String: String] = [:]
        let top = "Stardew Valley Expanded/"
        sve[top + "Stardew Valley Expanded Code/manifest.json"] = Self.manifest("Stardew Valley Expanded Code", id: "FlashShifter.SVECode", dll: "StardewValleyExpanded.dll")
        sve[top + "Stardew Valley Expanded Code/StardewValleyExpanded.dll"] = "MZ sve"
        sve[top + "[CP] Stardew Valley Expanded/manifest.json"] = Self.manifest("Stardew Valley Expanded", id: "FlashShifter.StardewValleyExpandedCP", packFor: "Pathoschild.ContentPatcher")
        sve[top + "[CP] Stardew Valley Expanded/content.json"] = "{}"
        sve[top + "[CP] Stardew Valley Expanded/assets/Maps/Custom_Forest.tbin"] = "map"
        sve[top + "[CP] Stardew Valley Expanded/assets/Characters/Andy.png"] = "png"
        sve[top + "[FTM] Stardew Valley Expanded/manifest.json"] = Self.manifest("Stardew Valley Expanded FTM", id: "FlashShifter.SVE-FTM", packFor: "Esca.FarmTypeManager")
        sve[top + "[FTM] Stardew Valley Expanded/content.json"] = "{}"
        sve[top + "ReadMe.txt"] = "read me"
        let bundle = ModArchive.plan(paths: Array(sve.keys), profile: stardew, archiveName: "-Stardew Valley Expanded--3753-1-15-11", manifests: manifests(sve))
        #expect(bundle.isReady && bundle.units.map(\.name) == ["Stardew Valley Expanded Code", "[CP] Stardew Valley Expanded", "[FTM] Stardew Valley Expanded"], "\(bundle.units.map(\.name))")
        #expect(bundle.units.map(\.code) == [true, false, false] && bundle.base == "Stardew Valley Expanded" && bundle.leftovers.isEmpty && bundle.containsCode)
        #expect(bundle.units[1].files.map(\.destination) == ["game:Mods/[CP] Stardew Valley Expanded/assets/Characters/Andy.png", "game:Mods/[CP] Stardew Valley Expanded/assets/Maps/Custom_Forest.tbin",
                                                             "game:Mods/[CP] Stardew Valley Expanded/content.json", "game:Mods/[CP] Stardew Valley Expanded/manifest.json"])
        #expect(bundle.units.allSatisfy { $0.framework == "smapi" && $0.kind.id == "mod" } && bundle.frameworks == ["smapi"], "one package, installed and turned on and off as one")

        // Ridgeside Village: four mods; East Scarp Remastered: five, two of them C#.
        var ridgeside: [String: String] = [:]
        for (folder, id, dll) in [("RidgesideVillage", "Rafseazz.RidgesideVillage", "RidgesideVillage.dll"), ("[CP] Ridgeside Village", "Rafseazz.RSVCP", nil),
                                  ("[FTM] Ridgeside Village", "Rafseazz.RSVFTM", nil), ("[CC] Ridgeside Village", "Rafseazz.RSVCC", nil)] {
            ridgeside["Ridgeside Village/\(folder)/manifest.json"] = Self.manifest(folder, id: id, dll: dll, packFor: dll == nil ? "Pathoschild.ContentPatcher" : nil)
            ridgeside["Ridgeside Village/\(folder)/\(dll ?? "content.json")"] = "x"
        }
        let village = ModArchive.plan(paths: Array(ridgeside.keys), profile: stardew, archiveName: "Ridgeside Village 2.5.17-7286-2-5-17", manifests: manifests(ridgeside))
        #expect(village.isReady && village.units.count == 4 && village.units.filter(\.code).map(\.name) == ["RidgesideVillage"] && village.base == "Ridgeside Village")
        var scarp: [String: String] = [:]
        for (folder, dll) in [("East Scarp C#", "EastScarp.dll"), ("East Scarp Core", nil), ("East Scarp FTM", nil), ("East Scarp NPCs", nil), ("ESBarberShop", "ESBarberShop.dll")] {
            scarp["East Scarp REMASTERED/\(folder)/manifest.json"] = Self.manifest(folder, id: "Lemurkat.\(folder.filter(\.isLetter))", dll: dll, packFor: dll == nil ? "Pathoschild.ContentPatcher" : nil)
            scarp["East Scarp REMASTERED/\(folder)/\(dll ?? "content.json")"] = "x"
        }
        let east = ModArchive.plan(paths: Array(scarp.keys), profile: stardew, manifests: manifests(scarp))
        #expect(east.isReady && east.units.count == 5 && east.units.filter(\.code).map(\.name) == ["ESBarberShop", "East Scarp C#"])

        // A Json Assets pack comes as a rar: the archive's format is the store's business, the plan is the same.
        let axehead = ["[JA] Axehead/manifest.json": Self.manifest("Axehead", id: "someone.Axehead", packFor: "spacechase0.JsonAssets"),
                       "[JA] Axehead/BigCraftables/Axehead/big-craftable.json": "{}", "[JA] Axehead/BigCraftables/Axehead/big-craftable.png": "png"]
        let rar = ModArchive.plan(paths: Array(axehead.keys), profile: stardew, archiveName: "Axehead-5522-1-0-0.rar", manifests: manifests(axehead))
        #expect(rar.isReady && rar.units.map(\.name) == ["[JA] Axehead"] && rar.units.first?.code == false)
        #expect(rar.units.first?.files.map(\.destination) == ["game:Mods/[JA] Axehead/BigCraftables/Axehead/big-craftable.json", "game:Mods/[JA] Axehead/BigCraftables/Axehead/big-craftable.png", "game:Mods/[JA] Axehead/manifest.json"])

        // Mac leavings and Vortex's marker stay out of the plan; a mod inside a mod belongs to the outer one.
        let junk = ModArchive.plan(paths: ["__MACOSX/._manifest.json", "LookupAnything/.DS_Store", "LookupAnything/._LookupAnything.dll", "LookupAnything/manifest.json", "LookupAnything/LookupAnything.dll",
                                           "LookupAnything/__folder_managed_by_vortex"], profile: stardew)
        #expect(junk.isReady && junk.units.count == 1 && junk.units.first?.files.map(\.source) == ["LookupAnything.dll", "manifest.json"])
        let nested = ModArchive.plan(paths: ["Outer/manifest.json", "Outer/Outer.dll", "Outer/Inner/manifest.json", "Outer/Inner/content.json"], profile: stardew)
        #expect(nested.units.map(\.name) == ["Outer"] && nested.units.first?.files.count == 4)
    }

    @Test func archivesThatAreNotMods() throws {
        let stardew = try profile()
        // An XNB replacement (the same author offers both): the game's own files, not a mod.
        let xnb = ModArchive.plan(paths: ["Lizard Girl XNB/Content/Characters/Abigail.xnb", "Lizard Girl XNB/Content/Portraits/Abigail.xnb"], profile: stardew, archiveName: "Lizard Girl XNB-7449-1-0")
        #expect(xnb.refusal == .init(reason: .rejected("legacyFormat"), path: "Content/Characters/Abigail.xnb") && xnb.units.isEmpty)
        // An `.xnb` shipped inside a real mod's folder is that mod's.
        let withAsset = ModArchive.plan(paths: ["Seasonal Outfits/manifest.json", "Seasonal Outfits/content.json", "Seasonal Outfits/assets/Abigail.xnb"], profile: stardew)
        #expect(withAsset.isReady && withAsset.units.first?.files.count == 3)
        // Only a config: a mod's settings, not the mod (Chests Anywhere's "Balanced mode").
        let config = ModArchive.plan(paths: ["config.json"], profile: stardew, archiveName: "Balanced mode (config.json)-518-1-0")
        #expect(config.refusal == .init(reason: .rejected("configOnly"), path: "config.json"))
        #expect(ModArchive.plan(paths: ["ChestsAnywhere/config.json"], profile: stardew).refusal?.reason == .rejected("configOnly"), "the wrapper doesn't make it a mod")
        // A Windows tool (Farm Type Manager's Config Editor) and its files: a program, never placed.
        let editor = ModArchive.plan(paths: ["FTM Config Editor/FTMConfigEditor.exe", "FTM Config Editor/FTMConfigEditor.dll", "FTM Config Editor/Newtonsoft.Json.dll"], profile: stardew, archiveName: "Config Editor v1.23.0-3231-1-23-0")
        #expect(editor.refusal?.reason == .rejected("executable"))
        // The SMAPI installer zip dropped in as a mod: it is the loader, which Sommelier installs itself.
        let installer = ModArchive.plan(paths: ["SMAPI 4.5.2 installer/install on macOS.command", "SMAPI 4.5.2 installer/install on Windows.bat", "SMAPI 4.5.2 installer/README.txt",
                                                "SMAPI 4.5.2 installer/internal/macOS/install.dat", "SMAPI 4.5.2 installer/internal/macOS/SMAPI.Installer",
                                                "SMAPI 4.5.2 installer/internal/windows/install.dat", "SMAPI 4.5.2 installer/internal/windows/SMAPI.Installer.exe"],
                                        profile: stardew, archiveName: "SMAPI 4.5.2-2400-4-5-2")
        #expect(installer.refusal?.reason == .rejected("loader") && installer.refusal?.path?.hasSuffix("install.dat") == true, "\(String(describing: installer.refusal))")
        // A patch of loose assets without a manifest (East Scarp's Android map fix): nothing a kind knows.
        let patch = ModArchive.plan(paths: ["assets/Locations/Interiors/Clinic.tbin", "assets/Locations/Interiors/Saloon.tbin"], profile: stardew)
        #expect(patch.refusal?.reason == .nothingRecognised && patch.units.isEmpty)
        #expect(ModArchive.plan(paths: ["__MACOSX/._x", "readme.md"], profile: stardew).refusal?.reason == .empty)
    }

    // MARK: SMAPI

    @Test func smapiIsUnpackedOutOfTheInstallerWithoutRunningIt() async throws {
        var bench = try Bench(try profile())
        let before = snapshot(bench.game)
        let zip = try await installerZip(bench)
        let hash = try #require(ModStore.sha256(of: zip))
        let profile = try profile(smapiHash: hash)
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["SMAPI-4.5.2-installer.zip": zip]))
        let installation = try await installer.install("smapi", launchProfile: &bench.launch)

        // Only the Mac `install.dat`'s contents, flat in `Contents/MacOS`, plus the copy of the game's deps.json.
        #expect(installation.alsoInstalled.isEmpty && installation.overwroteForeign.isEmpty && installation.components.isEmpty)
        #expect(installation.placed.contains("game:StardewModdingAPI") && installation.placed.contains("game:StardewModdingAPI.dll"))
        #expect(installation.placed.contains("game:smapi-internal/0Harmony.dll") && installation.placed.contains("game:Mods/ConsoleCommands/manifest.json") && installation.placed.contains("game:Mods/SaveBackup/SaveBackup.dll"))
        #expect(installation.placed.last == "game:StardewModdingAPI.deps.json" && installation.placed.count == 15, "\(installation.placed)")
        #expect(bench.text("StardewModdingAPI.deps.json") == "{\"deps\": 1}" && bench.text("steam_appid.txt") == "413150" && bench.text("smapi-internal/config.json") == "{\"CheckForUpdates\": true}")
        #expect(inode(bench.url("StardewModdingAPI.deps.json")) != inode(bench.url("Stardew Valley.deps.json")), "a copy of the game's file, never a link to it")
        #expect(isExecutable(bench.url("StardewModdingAPI")), "the zip lost the mode bits; the program must run")
        #expect(!bench.exists("install on macOS.command") && !bench.exists("SMAPI.Installer") && !bench.exists("SMAPI.Installer.dll") && !bench.exists("README.txt") && !bench.exists("StardewModdingAPI.exe"),
                "the installer, its runtime and the other platforms stay out")
        #expect(bench.text("Stardew Valley") == "#!/bin/sh\nlauncher" && bench.text("Stardew Valley.dll") == "MZ game 1.6.15", "the game's launcher is not replaced: the redirect starts SMAPI")
        // The launch: SMAPI's program instead of the game's, nothing else.
        #expect(bench.launch.redirect == ExecutableRedirect(instead: "Stardew Valley", run: "StardewModdingAPI") && bench.launch.dllOverrides.isEmpty && bench.launch.extraArguments.isEmpty)
        #expect(installation.fixes.map(\.ruleID) == ["framework:smapi"] && installation.fixes.map(\.action) == [.runExecutable(instead: "Stardew Valley", run: "StardewModdingAPI")])
        #expect(installer.installed() == ["smapi"] && bench.deployer.verify().isEmpty && bench.deployer.owners() == ["framework:smapi"])
        #expect(installer.unneeded(mods: []).isEmpty, "SMAPI stays without mods")
        // Installing again changes nothing.
        let again = try await installer.install("smapi", launchProfile: &bench.launch)
        #expect(again.placed.isEmpty && again.fixes.isEmpty && bench.deployer.verify().isEmpty)

        // Out again: the `.app` as Steam left it, the launch as it was.
        try installer.uninstall("smapi", fixes: installation.fixes, launchProfile: &bench.launch)
        #expect(snapshot(bench.game) == before && bench.launch == LaunchProfile() && bench.deployer.owners().isEmpty && installer.installed().isEmpty)
        #expect(!bench.exists("Mods"), "the Mods folder was SMAPI's")

        // The wrong file (another release, a tampered download): nothing is unpacked, nothing changes.
        let wrong = FrameworkInstaller(profile: try self.profile(smapiHash: String(repeating: "0", count: 64)), deployer: bench.deployer,
                                       downloader: StubDownloader(archives: ["SMAPI-4.5.2-installer.zip": zip]))
        var thrown: Error?
        do { _ = try await wrong.install("smapi", launchProfile: &bench.launch) } catch { thrown = error }
        #expect(thrown as? FrameworkInstallError == .hashMismatch(framework: "smapi", expected: String(repeating: "0", count: 64), actual: hash))
        #expect(snapshot(bench.game) == before && bench.launch == LaunchProfile() && !wrong.isInstalled("smapi"))
        // And the real list can't install it without a hash at all.
        #expect(try self.profile().framework("smapi")?.download.sha256 != nil, "the published entry pins the release")
    }

    @Test func aReplacedAppGetsSmapiAndTheDepsCopyBack() async throws {
        var bench = try Bench(try profile())
        let zip = try await installerZip(bench)
        let profile = try profile(smapiHash: ModStore.sha256(of: zip))
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["SMAPI-4.5.2-installer.zip": zip]))
        _ = try await installer.install("smapi", launchProfile: &bench.launch)
        let lookup = try bench.stored("Lookup Anything", Self.lookupAnything)
        try bench.deployer.deploy(lookup)
        #expect(bench.deployer.verify().isEmpty && bench.exists("Mods/LookupAnything/LookupAnything.dll"))

        // Steam updates the game: the whole `.app` is written anew, without SMAPI, with a new deps.json.
        try FileManager.default.removeItem(at: bench.app)
        var updated = Bench.gameFiles
        updated["Stardew Valley.dll"] = "MZ game 1.6.16"
        updated["Stardew Valley.deps.json"] = "{\"deps\": 2}"
        try Self.layout(updated, in: bench.game)
        let findings = bench.deployer.verify()
        #expect(!findings.isEmpty && findings.allSatisfy { $0.problem == .missing } && Set(findings.map(\.owner)) == ["framework:smapi", lookup.key])
        #expect(findings.contains { $0.destination == "game:StardewModdingAPI.deps.json" } && findings.contains { $0.destination == "game:StardewModdingAPI" })

        // The quiet repair before the launch: everything back, the deps copy from the new game.
        let repaired = try bench.deployer.repair(findings)
        #expect(repaired.placed.count == findings.count && bench.deployer.verify().isEmpty)
        #expect(bench.text("StardewModdingAPI.deps.json") == "{\"deps\": 2}" && bench.text("StardewModdingAPI.dll") == "MZ smapi" && isExecutable(bench.url("StardewModdingAPI")))
        #expect(bench.text("Mods/ConsoleCommands/manifest.json")?.contains("SMAPI.ConsoleCommands") == true && bench.text("Mods/LookupAnything/LookupAnything.dll") == "MZ lookup")
        #expect(bench.text("Stardew Valley.dll") == "MZ game 1.6.16", "the new game stays the new game")
        #expect(installer.installed() == ["smapi"] && bench.launch.redirect?.run == "StardewModdingAPI")

        // A smaller update that rewrites only the game's deps.json: the copy is stale and is made again.
        try Self.layout(["Stardew Valley.deps.json": "{\"deps\": 3}"], in: bench.game)
        let stale = bench.deployer.verify()
        #expect(stale == [.init(owner: "framework:smapi", destination: "game:StardewModdingAPI.deps.json", problem: .replaced)])
        try bench.deployer.repair(stale)
        #expect(bench.text("StardewModdingAPI.deps.json") == "{\"deps\": 3}" && bench.deployer.verify().isEmpty)
    }

    // MARK: Mods in the game

    @Test func modsHaveNoOrderAndGoOffWithADot() throws {
        let bench = try Bench(try profile())
        try Self.layout(["Mods/ConsoleCommands/manifest.json": "smapi's"], in: bench.game)
        let files = LoadOrderFiles(profile: bench.profile, deployer: bench.deployer)
        let patcher = try bench.stored("Content Patcher", Self.contentPatcher)
        let pam = try bench.stored("Pam in Shipping Bin", Self.pamPack)
        let lookup = try bench.stored("Lookup Anything", Self.lookupAnything)
        let mods = [patcher, pam, lookup]
        for mod in mods { try bench.deployer.deploy(mod) }

        // SMAPI sorts by dependencies: the list has no handles and nothing moves.
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        #expect(!order.canReorder && order.keys == mods.map(\.key) && order.items.allSatisfy { $0.pin == nil })
        #expect(order.moving(lookup.key, to: 0) == nil && order.moving(patcher.key, to: 2) == nil)
        try files.apply(order, mods: mods)
        #expect(files.read(mods: mods).keys == mods.map(\.key) && bench.deployer.verify().isEmpty)
        #expect(bench.exists("Mods/ContentPatcher/ContentPatcher.dll") && bench.exists("Mods/[CP] Pam in Shipping Bin/content.json") && bench.exists("Mods/LookupAnything/manifest.json"))
        #expect(inode(bench.url("Mods/LookupAnything/LookupAnything.dll")) == inode(bench.store.file(of: lookup.key, at: "LookupAnything.dll")), "a hard link into the store")

        // The game writes the mod's settings into its folder; off is a dot in front of the folder, files and all.
        try Self.layout(["Mods/LookupAnything/config.json": "{\"ShowAll\": true}"], in: bench.game)
        try bench.deployer.setEnabled(lookup, false)
        #expect(!bench.exists("Mods/LookupAnything") && bench.text("Mods/.LookupAnything/config.json") == "{\"ShowAll\": true}" && bench.text("Mods/.LookupAnything/LookupAnything.dll") == "MZ lookup")
        #expect(inode(bench.url("Mods/.LookupAnything/LookupAnything.dll")) == inode(bench.store.file(of: lookup.key, at: "LookupAnything.dll")), "still linked, not unlinked")
        #expect(try bench.deployer.verify().isEmpty && bench.deployer.isDeployed(lookup.key) && bench.deployer.deployed(lookup.key).count == 4)
        try bench.deployer.setEnabled(lookup, true)
        #expect(bench.text("Mods/LookupAnything/config.json") == "{\"ShowAll\": true}" && !bench.exists("Mods/.LookupAnything") && bench.deployer.verify().isEmpty)

        // Removed: exactly the files placed go; the settings the game wrote are the player's and stay.
        let removal = try bench.deployer.remove(owner: lookup.key)
        #expect(removal.removed.count == 4 && removal.kept.isEmpty && !bench.exists("Mods/LookupAnything/LookupAnything.dll"))
        #expect(bench.text("Mods/LookupAnything/config.json") == "{\"ShowAll\": true}", "left for the player to see, never deleted")
        try bench.deployer.remove(owner: pam.key)
        try bench.deployer.remove(owner: patcher.key)
        #expect(!bench.exists("Mods/ContentPatcher") && !bench.exists("Mods/[CP] Pam in Shipping Bin") && bench.text("Mods/ConsoleCommands/manifest.json") == "smapi's")
    }

    @Test func packsNeedTheirHostAndOneCopyOfAModIsEnough() throws {
        let bench = try Bench(try profile())
        var patcher = try bench.stored("Content Patcher", Self.contentPatcher)
        let pam = try bench.stored("Pam in Shipping Bin", Self.pamPack)
        let lookup = try bench.stored("Lookup Anything", Self.lookupAnything)
        // The same Content Patcher again from an older zip, in a folder of another name.
        let older = try bench.stored("Content Patcher (old)", ["Content Patcher (old)/ContentPatcher.dll": "MZ old",
                                                               "Content Patcher (old)/manifest.json": Self.manifest("Content Patcher", id: "pathoschild.contentpatcher", dll: "ContentPatcher.dll", version: "2.8.0")])
        func manifests(_ mods: [StoredMod]) -> [String: [String: String]] {
            Dictionary(uniqueKeysWithValues: mods.map { ($0.key, ModConflicts.manifestFields(of: $0, store: bench.store)) })
        }
        #expect(manifests([pam])[pam.key]?["contentpackfor.uniqueid"] == "Pathoschild.ContentPatcher" && manifests([lookup])[lookup.key]?["entrydll"] == "LookupAnything.dll")

        // With its host on and SMAPI in place, the pack is fine; the C# mods need nothing but SMAPI.
        var mods = [patcher, pam, lookup]
        #expect(ModConflicts.check(mods, profile: bench.profile, installedFrameworks: ["smapi"], manifests: manifests(mods)).isEmpty)
        // Without SMAPI every mod is blocked: the loader with its Install button.
        let noLoader = ModConflicts.check(mods, profile: bench.profile, manifests: manifests(mods))
        #expect(noLoader.findings.map(\.cause) == [.needsFramework("smapi"), .needsFramework("smapi"), .needsFramework("smapi")] && noLoader.blocked == Set(mods.map(\.key)))
        // Content Patcher off: the pack says what it needs, by the id the host is known by; the C# mod is untouched.
        patcher.enabled = false
        mods = [patcher, pam, lookup]
        let orphan = ModConflicts.check(mods, profile: bench.profile, installedFrameworks: ["smapi"], manifests: manifests(mods))
        #expect(orphan.findings == [.init(cause: .needsMod("Pathoschild.ContentPatcher", label: "needsFramework"), severity: .block, mods: [pam.key])])
        #expect(orphan.isBlocked(pam.key) && !orphan.isBlocked(lookup.key) && !orphan.isBlocked(patcher.key))
        // A second copy of one mod (SMAPI would skip both): one `UniqueID` at a time, whatever the folder's name or the id's case.
        patcher.enabled = true
        mods = [patcher, older, pam, lookup]
        let twice = ModConflicts.check(mods, profile: bench.profile, installedFrameworks: ["smapi"], manifests: manifests(mods))
        #expect(twice.findings == [.init(cause: .rule(reason: "duplicateMod", hint: nil, matched: "Pathoschild.ContentPatcher"), severity: .block, mods: [patcher.key, older.key])])
        #expect(twice.isBlocked(older.key) && twice.findings(for: pam.key).isEmpty, "the pack has its host; the copy is the problem")
        // Two mods placing one path (the same folder name from two archives): with no order to settle it, a block.
        let twin = try bench.stored("Lookup Anything 2", Self.lookupAnything)
        mods = [patcher, pam, lookup, twin]
        let clash = ModConflicts.check(mods, profile: bench.profile, installedFrameworks: ["smapi"], manifests: manifests(mods))
        #expect(clash.findings.contains { if case .samePath(let path, let winner) = $0.cause { return path == "game:Mods/LookupAnything/manifest.json" && winner == nil && $0.severity == .block } else { return false } })
        #expect(clash.findings.contains { if case .rule(let reason, _, _) = $0.cause { return reason == "duplicateMod" } else { return false } })
    }

    // MARK: After a failed launch

    @Test func smapiLogNamesTheSkippedModsAndSumsUpTheSession() throws {
        let stardew = try profile()
        let bench = try Bench(stardew)
        let kind = try #require(stardew.kind("mod"))
        let lookup = mod("Lookup Anything", key: "lookup-anything", kind: kind, folder: "LookupAnything", files: ["LookupAnything.dll", "manifest.json"], added: 100)
        let village = mod("Ridgeside Village", key: "ridgeside", kind: kind, folder: "Ridgeside Village", files: ["manifest.json"], added: 200)
        let broken = mod("Broken Pack", key: "broken-pack", kind: kind, folder: "[CP] Broken Pack", files: ["manifest.json", "content.json"], added: 300)
        let state = ModDiagnostics.State(mods: [lookup, village, broken], installedFrameworks: ["smapi"],
                                         manifests: ["lookup-anything": ["name": "Lookup Anything", "uniqueid": "Pathoschild.LookupAnything"],
                                                     "ridgeside": ["name": "Ridgeside Village", "uniqueid": "Rafseazz.RidgesideVillage"],
                                                     "broken-pack": ["name": "Broken Pack", "uniqueid": "someone.BrokenPack"]])
        let diagnostics = ModDiagnostics(profile: stardew, roots: bench.deployer.roots)
        #expect(diagnostics.collect(state).matches.isEmpty && diagnostics.collect(state).tail == nil && diagnostics.collect(state).summary == nil)

        // The log as SMAPI 4.5 writes it on a Mac: skipped mods by their names, one without a version (its
        // manifest is broken, so SMAPI calls it by its folder), one dependency missing.
        let log = """
        [10:00:00 INFO  SMAPI] SMAPI 4.5.2 with Stardew Valley 1.6.15 on macOS 26.0
        [10:00:00 INFO  SMAPI] Mods go here: /Users/someone/Library/Application Support/Steam/steamapps/common/Stardew Valley/Contents/MacOS/Mods
        [10:00:01 INFO  SMAPI] Loaded 2 mods:
        [10:00:01 INFO  SMAPI]    Content Patcher 2.9.1 by Pathoschild | Loads content packs
        [10:00:01 INFO  SMAPI]    Lookup Anything 1.55.0 by Pathoschild | Look up info about things
        [10:00:01 ERROR SMAPI]    Skipped mods
        [10:00:01 ERROR SMAPI]    --------------------------------------------------
        [10:00:01 ERROR SMAPI]       These mods could not be added to your game.

        [10:00:01 ERROR SMAPI]       - [CP] Broken Pack because its manifest is invalid.
        [10:00:01 ERROR SMAPI]         (The JSON file is invalid: Unexpected character.)
        [10:00:01 ERROR SMAPI]       - Ridgeside Village 2.5.17 because it requires mods which aren't installed (spacechase0.SpaceCore).
        [10:00:01 ERROR SMAPI]       - Tractor Mod 4.24.4 because it's no longer compatible. Please check for a new version at https://smapi.io/mods.
        [10:00:02 INFO  SMAPI] You can update 1 mod:
        [10:00:02 INFO  SMAPI]    Content Patcher 2.9.2: https://smapi.io/mods#Content_Patcher
        [10:00:02 INFO  SMAPI] You can update SMAPI to 4.6.0: https://smapi.io

        """
        let file = bench.home.appendingPathComponent(".config/StardewValley/ErrorLogs/SMAPI-latest.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(log.utf8).write(to: file)
        let result = diagnostics.collect(state)
        #expect(result.matches.map(\.rule.action) == [.disableMod("broken-pack"), .disableMod("ridgeside")], "\(result.matches.map(\.rule.action))")
        #expect(result.matches.allSatisfy { $0.rule.id == ModDiagnostics.brokenModRule && $0.weight == 2 })
        #expect(result.unresolved == ["Tractor Mod"], "a mod the player put in by hand is reported, not acted on")
        #expect(result.tail?.contains("requires mods which aren't installed") == true && result.tail?.contains("Ridgeside") == false && result.tail?.contains("Lookup Anything") == false,
                "the tail kept for a report has no mod names")
        let summary = try #require(result.summary)
        #expect(summary.smapiVersion == "4.5.2" && summary.gameVersion == "1.6.15" && summary.loaded == 2 && summary.errors == 7)
        #expect(summary.skipped == ["[CP] Broken Pack", "Ridgeside Village", "Tractor Mod"] && summary.updates == ["Content Patcher"] && summary.smapiUpdate == "4.6.0")

        // With SMAPI's technical details on, the line carries the unique id too: the second rule resolves it
        // even when the name doesn't, and the two rules never name one mod twice.
        var unresolved: [String] = []
        let technical = "[10:00:01 ERROR SMAPI]       - Ridgeside Village 2.5.17 (ID: Rafseazz.RidgesideVillage, path: Ridgeside Village) because it requires mods which aren't installed (spacechase0.SpaceCore).\n"
            + "[10:00:01 ERROR SMAPI]       - RSV_old (ID: someone.BrokenPack, path: RSV_old) because its manifest is invalid.\n"
        let matches = ModDiagnostics.matches(in: technical, log: try #require(stardew.logs.first), profile: stardew, state: state, unresolved: &unresolved)
        #expect(matches.map(\.rule.action) == [.disableMod("ridgeside"), .disableMod("broken-pack")] && unresolved == ["RSV_old"])
        // A fix already applied isn't offered again; a mod that is off isn't blamed.
        let applied = ModDiagnostics.State(mods: state.mods, installedFrameworks: ["smapi"], manifests: state.manifests,
                                           applied: [AppliedFix(ruleID: ModDiagnostics.brokenModRule, action: .disableMod("ridgeside"), undo: .enableMod("ridgeside"), date: Date())])
        #expect(diagnostics.collect(applied).matches.map(\.rule.action) == [.disableMod("broken-pack")])

        // SMAPI itself off for a launch: the redirect goes, so the game's own program starts; undone, it is back.
        var launch = LaunchProfile()
        launch.redirect = ExecutableRedirect(instead: "Stardew Valley", run: "StardewModdingAPI")
        let fix = ModDiagnostics.disable(try #require(stardew.framework("smapi")), in: &launch)
        #expect(launch == LaunchProfile() && fix.action == .disableFramework("smapi"))
        ModDiagnostics.restore(fix.undo, in: &launch)
        #expect(launch.redirect?.run == "StardewModdingAPI")
    }
}
