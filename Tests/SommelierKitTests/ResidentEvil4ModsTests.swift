// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The Resident Evil 4 (2023) profile against the archive layouts Fluffy-format mods really come in, the
/// REFramework release zip, the loose files placed bottom-up with the top mod's file on disk, PAK mods numbered
/// after the game's own patches and pinned at the bottom, the loader's log and crash dump, and the game's
/// version stamp. The game's folder has two spaces in its name, as Steam writes it.
struct ResidentEvil4ModsTests {
    static let gameFolder = "RESIDENT EVIL 4  BIOHAZARD RE4"

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

    /// The Steam install with its chunk and three patches, a store and the deployer, all in temporary folders.
    private struct Bench {
        let root: URL, game: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile
        var launch = LaunchProfile()

        init(_ profile: ModProfile) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-re4-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("steamapps/common/\(ResidentEvil4ModsTests.gameFolder)", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/steam:2050650", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: support,
                                 appdata: root.appendingPathComponent("users/steamuser/AppData/Local", isDirectory: true),
                                 roaming: root.appendingPathComponent("users/steamuser/AppData/Roaming", isDirectory: true),
                                 documents: root.appendingPathComponent("users/steamuser/Documents", isDirectory: true))
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
            try ResidentEvil4ModsTests.layout(["re4.exe": "MZ\0\u{90}game 1.0", "re_chunk_000.pak": "chunk", "re_chunk_000.pak.patch_001.pak": "patch 1",
                                               "re_chunk_000.pak.patch_002.pak": "patch 2", "re_chunk_000.pak.patch_003.pak": "patch 3"], in: game)
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        /// A mod in the store, made from a layout planned against the profile.
        func stored(_ name: String, _ files: [String: String], answers: ModArchive.Answers = .init()) throws -> StoredMod {
            let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
            try ResidentEvil4ModsTests.layout(files, in: unpacked)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name, answers: answers)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }

        /// A zip of the layout, made with `tar`, as `name` in a scratch folder of the bench.
        func archive(_ name: String, _ files: [String: String]) async throws -> URL {
            let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
            try ResidentEvil4ModsTests.layout(files, in: source)
            let folder = root.appendingPathComponent("archives-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = folder.appendingPathComponent(name)
            let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", archive.path, "--format", "zip", "-C", source.path, "."])
            try #require(made.succeeded, Comment(rawValue: made.output))
            return archive
        }
    }

    static func layout(_ files: [String: String], in root: URL) throws {
        for (path, text) in files {
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The fixture's RE4 entry, with the proxy's hash pointed at a stub archive when a test installs it.
    private func profile(reframeworkHash: String? = nil) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var games = try #require(json["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["game"] as? String == "steam:2050650" })
        if let reframeworkHash {
            var frameworks = try #require(games[index]["frameworks"] as? [[String: Any]])
            for i in frameworks.indices where frameworks[i]["id"] as? String == "reframework" {
                var download = try #require(frameworks[i]["download"] as? [String: Any])
                download["sha256"] = reframeworkHash
                frameworks[i]["download"] = download
            }
            games[index]["frameworks"] = frameworks
        }
        json["games"] = games
        let list = try JSONDecoder().decode(ModsList.self, from: try JSONSerialization.data(withJSONObject: json))
        return try #require(list.profile(covering: "steam:2050650"))
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

    private func destinations(_ plan: ModPlan) -> [String] { plan.units.flatMap { $0.files.map(\.destination) }.sorted() }

    /// A stored mod as the diagnostics see it, without a store.
    private func mod(_ name: String, key: String, kind: ModKind, unit: String, files: [(String, String)], added: TimeInterval) -> StoredMod {
        StoredMod(key: key, name: name, version: nil, author: nil, origin: .init(), archive: .init(name: name + ".zip"),
                  added: Date(timeIntervalSince1970: added), enabled: true, codeAccepted: true,
                  units: [ModPlan.Unit(kind: kind, name: unit, root: "", code: kind.code, framework: kind.framework,
                                       files: files.map { .init(source: $0.0, destination: $0.1, skipped: false) })], leftovers: [])
    }

    /// The release zip for RE4: the proxy and the two VR runtimes next to it.
    private let reframeworkZip = ["dinput8.dll": "proxy", "openvr_api.dll": "openvr", "openxr_loader.dll": "openxr", "LICENSE": "MIT"]

    private let item = "natives/STM/_Chainsaw/Item/ItemDefine.user.2"

    // MARK: The profile

    @Test func profileKeepsTheLaunchAndNeedsTheProxyForLooseFiles() throws {
        let re4 = try profile()
        #expect(re4.status == .ready && re4.runtime == .wine && re4.sources.nexus?.domain == "residentevil42023" && re4.sources.modio == nil)
        #expect(re4.kinds.map(\.id) == ["pak", "loose", "script", "lua"])
        let pak = try #require(re4.kind("pak"))
        #expect(pak.framework == nil && pak.pinned == .last && pak.to == "game:re_chunk_000.pak.patch_{next}.pak" && pak.order == .deploy, "a PAK patch needs no loader and always wins")
        #expect(re4.kind("loose")?.framework == "reframework" && re4.kind("loose")?.code == false, "the game reads `natives/` only with the proxy's loose-file loading")
        #expect(re4.kind("script")?.code == true && re4.kind("lua")?.code == true && re4.kind("lua")?.to == "game:reframework/autorun/")
        #expect(re4.loadOrder.format == .deployOrder && !re4.loadOrder.reverse && re4.loadOrder.pinLastGroups == ["pak"] && re4.loadOrder.isReorderable)

        let reframework = try #require(re4.framework("reframework"))
        #expect(reframework.code && !reframework.optional && reframework.dllOverrides == ["dinput8": "n,b"] && reframework.disableArgument == nil)
        #expect(reframework.launch == nil && reframework.components.isEmpty && reframework.remove.isEmpty, "the same re4.exe starts; the proxy is picked up from the game folder")
        #expect(reframework.pick.map(\.match) == ["dinput8.dll"] && reframework.pick.first?.to == "game:", "the VR runtimes in the zip stay out")
        #expect(reframework.skip == ["reframework/plugins/reframework-d2d.dll", "reframework/autorun/reframework-d2d.lua"], "Direct2D must not be installed under Wine")
        #expect(reframework.settings.map(\.file) == ["game:re2_fw_config.txt"] && reframework.settings.first?.format == .keyValue)
        #expect(re4.framework("firstnatives") == nil, "no plugin without a known author, source and licence")

        #expect(re4.online.policy == .allowed && re4.online.moddedLaunch == .same && re4.online.antiCheat == nil && re4.online.noticeKey == nil)
        let guardian = LaunchGuard(profile: re4, roots: ModRoots(game: nil, store: URL(fileURLWithPath: "/tmp/s"), tools: URL(fileURLWithPath: "/tmp/t"), home: URL(fileURLWithPath: "/tmp/h")))
        #expect(guardian.allowsPlainLaunch(modsEnabled: true) && guardian.loaderFramework == nil)
        #expect(try guardian.decide(modsEnabled: true, installed: ["reframework"]) == .plain(leftovers: []))
        #expect(re4.saves.isEmpty, "Steam Cloud keeps the saves under an account folder the profile can't name; the app backs up the folder it found")
        #expect(re4.notes.gameVersionFile == "game:re4.exe" && re4.notes.cleanupOnLastCodeMod && re4.notes.untouched.isEmpty)
        #expect(re4.conflicts.samePath == .warn && re4.conflicts.rules.isEmpty)
        #expect(re4.archive.variants == "modinfo.ini" && re4.archive.wrappers && re4.archive.deny == ["dinput8.dll", "dxgi.dll", "d3d12.dll"])
        #expect(re4.archive.reject.map(\.reason) == ["executable", "loader", "reshade"])
        #expect(re4.logs.map(\.file) == ["game:re2_framework_log.txt", "game:reframework_crash.dmp"] && re4.logs.last?.exists?.action == .disableNewestMod)
    }

    // MARK: Archives

    @Test func fluffyArchivesLooseAndPak() throws {
        let re4 = try profile()
        // The usual Fluffy layout: the mod's folder with `modinfo.ini`, a screenshot and `natives/` inside.
        let headgear = ModArchive.plan(paths: ["Invisible Headgear/modinfo.ini", "Invisible Headgear/screenshot.png",
                                               "Invisible Headgear/natives/STM/_Chainsaw/Character/ch/cha0/cha000/00/cha000_00.mesh.221108797",
                                               "Invisible Headgear/natives/STM/_Chainsaw/Character/ch/cha0/cha000/00/cha000_00.mdf2.32"],
                                       profile: re4, archiveName: "Invisible Headgear-289-1-2")
        let unit = try #require(headgear.units.first)
        #expect(headgear.isReady && headgear.units.count == 1 && headgear.notes == [.wrapperRemoved("Invisible Headgear")])
        #expect(unit.kind.id == "loose" && unit.name == "Invisible Headgear" && !unit.code && unit.framework == "reframework" && unit.root.isEmpty)
        #expect(unit.files.map(\.destination) == ["game:natives/STM/_Chainsaw/Character/ch/cha0/cha000/00/cha000_00.mdf2.32",
                                                  "game:natives/STM/_Chainsaw/Character/ch/cha0/cha000/00/cha000_00.mesh.221108797"])
        #expect(headgear.leftovers == ["modinfo.ini", "screenshot.png"] && headgear.frameworks == ["reframework"] && !headgear.containsCode)

        // Max Stack Sizes: five variants, each a folder with its own `modinfo.ini`. The player picks one.
        var stacks: [String] = ["Max Stack Sizes/screenshot.png"]
        for variant in ["999", "9999", "x2", "x5", "x10"] {
            stacks += ["Max Stack Sizes/\(variant)/modinfo.ini", "Max Stack Sizes/\(variant)/\(item)"]
        }
        let asked = ModArchive.plan(paths: stacks, profile: re4)
        #expect(asked.questions == [.variant(options: ["999", "9999", "x10", "x2", "x5"])] && asked.units.isEmpty && asked.refusal == nil && !asked.isReady)
        let chosen = ModArchive.plan(paths: stacks, profile: re4, answers: .init(variant: "x5"))
        let five = try #require(chosen.units.first)
        #expect(chosen.isReady && chosen.units.count == 1 && five.kind.id == "loose" && five.name == "x5")
        #expect(five.files.map(\.destination) == ["game:" + item] && chosen.leftovers == ["modinfo.ini"] && chosen.base == "Max Stack Sizes/x5")
        #expect(chosen.notes == [.wrapperRemoved("Max Stack Sizes"), .variantChosen("x5")])
        #expect(ModArchive.plan(paths: stacks, profile: re4, answers: .init(variant: "x3")).questions.count == 1, "an answer that isn't an option asks again")

        // A PAK mod: one `.pak` with its `modinfo.ini`, placed as the next patch number, no loader needed.
        let pak = ModArchive.plan(paths: ["Better Leon/Better Leon.pak", "Better Leon/modinfo.ini"], profile: re4)
        let leon = try #require(pak.units.first)
        #expect(pak.isReady && pak.units.count == 1 && leon.kind.id == "pak" && leon.name == "Better Leon" && leon.framework == nil && !leon.code)
        #expect(leon.files.map(\.destination) == ["game:re_chunk_000.pak.patch_{next}.pak"] && leon.files.first?.needsNext == true && leon.kind.pinned == .last)
        #expect(pak.leftovers == ["modinfo.ini"] && pak.frameworks.isEmpty)
        // Two paks in one archive are two patches, each with a number of its own.
        let two = ModArchive.plan(paths: ["Voices.pak", "Music.pak"], profile: re4)
        #expect(two.units.map(\.name) == ["Music", "Voices"] && two.units.allSatisfy { $0.files.first?.needsNext == true })
    }

    @Test func codeArchivesAndRefusals() throws {
        let re4 = try profile()
        // _ScriptCore: the `reframework/` tree with scripts and data, all of it code.
        let core = ModArchive.plan(paths: ["reframework/autorun/_ScriptCore.lua", "reframework/autorun/Hotkeys.lua", "reframework/data/_ScriptCore/defaults.json"],
                                   profile: re4, archiveName: "_ScriptCore-2484-1-5")
        let tree = try #require(core.units.first)
        #expect(core.isReady && core.units.count == 1 && tree.kind.id == "script" && tree.code && tree.framework == "reframework" && tree.name == "_ScriptCore-2484-1-5")
        #expect(tree.files.map(\.destination) == ["game:reframework/autorun/Hotkeys.lua", "game:reframework/autorun/_ScriptCore.lua", "game:reframework/data/_ScriptCore/defaults.json"])
        #expect(core.containsCode && core.leftovers.isEmpty && core.notes.isEmpty, "`reframework` is the layout, not a wrapper")

        // A single script at the archive's root goes into `autorun`.
        let dodge = ModArchive.plan(paths: ["Dodge_Roll_and_Sprint.lua", "readme.txt"], profile: re4)
        let script = try #require(dodge.units.first)
        #expect(dodge.isReady && script.kind.id == "lua" && script.code && script.name == "Dodge_Roll_and_Sprint" && dodge.leftovers.isEmpty)
        #expect(script.files.map(\.destination) == ["game:reframework/autorun/Dodge_Roll_and_Sprint.lua"])

        // Health Bars ships the Direct2D plugin it needs on Windows: the plugin stays out under Wine, with a note.
        let bars = ModArchive.plan(paths: ["reframework/autorun/Health_Bars.lua", "reframework/autorun/reframework-d2d.lua", "reframework/plugins/reframework-d2d.dll"], profile: re4)
        let health = try #require(bars.units.first)
        #expect(bars.isReady && health.files.filter(\.skipped).map(\.source) == ["reframework/autorun/reframework-d2d.lua", "reframework/plugins/reframework-d2d.dll"])
        #expect(health.files.first { $0.source == "reframework/autorun/Health_Bars.lua" }?.skipped == false)
        #expect(bars.notes == [.skipped("reframework/autorun/reframework-d2d.lua", framework: "reframework"), .skipped("reframework/plugins/reframework-d2d.dll", framework: "reframework")])

        // The release zip of REFramework dropped in as a mod (it is on Nexus too): the proxy is denied, the VR files give it away.
        let loader = ModArchive.plan(paths: Array(reframeworkZip.keys), profile: re4, archiveName: "RE4")
        #expect(loader.refusal == .init(reason: .rejected("loader"), path: "openvr_api.dll") && loader.notes == [.denied("dinput8.dll")])
        #expect(ModArchive.plan(paths: ["dinput8.dll"], profile: re4).refusal?.reason == .nothingRecognised)
        // ReShade presets and trainers are programs in the game's folder, not mods.
        let reshade = ModArchive.plan(paths: ["dxgi.dll", "ReShade.ini", "Resident 2.0.ini", "reshade-shaders/Shaders/Cinematic.fx"], profile: re4)
        #expect(reshade.refusal == .init(reason: .rejected("reshade"), path: "ReShade.ini") && reshade.notes == [.denied("dxgi.dll")])
        #expect(ModArchive.plan(paths: ["Resident Evil 4 Remake v1.0 Plus 25 Trainer.exe", "trainer.dll"], profile: re4).refusal?.reason == .rejected("executable"))
        #expect(ModArchive.plan(paths: ["Modmanager.exe", "Games/RE4R/Mods/readme.txt"], profile: re4).refusal?.reason == .rejected("executable"), "Fluffy itself isn't a mod")
    }

    // MARK: The proxy

    @Test func reframeworkInstallsOnlyTheProxyAndTurnsLooseLoadingOn() async throws {
        for (label, config) in [("no config yet", nil), ("the game's config", "FOV_Enabled=false\r\nMenuKey=45\r\n")] {
            let note = Comment(rawValue: label)
            var bench = try Bench(try profile())
            if let config { try Self.layout(["re2_fw_config.txt": config], in: bench.game) }
            let before = snapshot(bench.game)
            let zip = try await bench.archive("RE4.zip", reframeworkZip)
            let hash = try #require(ModStore.sha256(of: zip))
            let profile = try profile(reframeworkHash: hash)
            let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["RE4.zip": zip]))
            let installation = try await installer.install("reframework", launchProfile: &bench.launch)

            #expect(installation.placed == ["game:dinput8.dll"] && installation.overwroteForeign.isEmpty && installation.alsoInstalled.isEmpty, note)
            #expect(bench.text("dinput8.dll") == "proxy" && !bench.exists("openvr_api.dll") && !bench.exists("openxr_loader.dll") && !bench.exists("LICENSE"), note)
            #expect(bench.text("re2_fw_config.txt") == (config ?? "") + "LooseFileLoader_Enabled=true" + (config == nil ? "\n" : "\r\n"), "\(label): the game's own keys and line endings stay")
            #expect(bench.launch.dllOverrides == ["dinput8": "n,b"] && bench.launch.extraArguments.isEmpty && bench.launch.redirect == nil, note)
            #expect(installation.fixes.map(\.ruleID) == ["framework:reframework"] && installation.components.isEmpty, note)
            #expect(installer.installed() == ["reframework"] && bench.deployer.verify().isEmpty, note)
            #expect(bench.url("dinput8.dll").path.contains(Self.gameFolder + "/dinput8.dll"), "the double space in the folder's name survives the paths")

            // The last code mod gone, the proxy goes too, and the game folder is as it was.
            #expect(installer.unneeded(mods: []) == ["reframework"], note)
            try installer.uninstall("reframework", fixes: installation.fixes, launchProfile: &bench.launch)
            #expect(snapshot(bench.game) == before && bench.launch == LaunchProfile() && bench.deployer.owners().isEmpty, note)
        }
    }

    // MARK: Order

    @Test func looseModsPlaceBottomUpAndPaksStayLast() throws {
        let bench = try Bench(try profile())
        let before = snapshot(bench.game)
        let files = LoadOrderFiles(profile: bench.profile, deployer: bench.deployer)
        let stacks = try bench.stored("Max Stack Sizes", [item: "stacks", "natives/STM/_Chainsaw/Item/ItemCraft.user.2": "craft"])
        let keys = try bench.stored("Small Keys", [item: "keys"])
        let leon = try bench.stored("Better Leon", ["Better Leon.pak": "leon"])
        let mods = [stacks, keys, leon]

        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        #expect(order.keys == [stacks.key, keys.key, leon.key] && order.canReorder && order.item(leon.key)?.pin == .last)
        #expect(order.moving(leon.key, to: 0) == nil && order.moving(stacks.key, to: 2) == nil, "the PAK group has no handle and nothing goes below it")
        try files.apply(order, mods: mods)
        // Bottom first: the pak takes the number after the game's patches, the lower loose mod goes in, the upper one covers it.
        #expect(bench.deployer.owners() == [leon.key, keys.key, stacks.key])
        #expect(bench.text("re_chunk_000.pak.patch_004.pak") == "leon" && !bench.exists("re_chunk_000.pak.patch_005.pak"))
        #expect(bench.text(item) == "stacks" && bench.text("natives/STM/_Chainsaw/Item/ItemCraft.user.2") == "craft")
        #expect(bench.deployer.shadowed(keys.key) == ["game:" + item] && bench.deployer.shadowed(stacks.key).isEmpty, "what the upper mod covered is on record")
        #expect(files.read(mods: mods).keys == [stacks.key, keys.key, leon.key] && bench.deployer.verify().isEmpty)
        let report = ModConflicts.check(mods, profile: bench.profile, order: files.read(mods: mods).keys, installedFrameworks: ["reframework"])
        #expect(report.findings == [.init(cause: .samePath("game:" + item, winner: stacks.key), severity: .warn, mods: [stacks.key, keys.key])])
        #expect(!report.isBlocked(keys.key) && report.findings(for: leon.key).isEmpty)

        // Small Keys to the top: the two loose mods are placed again the other way round, the pak stays put.
        let moved = try #require(order.moving(keys.key, to: 0))
        #expect(moved.keys == [keys.key, stacks.key, leon.key])
        try files.apply(moved, mods: mods)
        #expect(bench.text(item) == "keys" && bench.deployer.shadowed(stacks.key) == ["game:" + item] && bench.deployer.shadowed(keys.key).isEmpty)
        #expect(bench.text("natives/STM/_Chainsaw/Item/ItemCraft.user.2") == "craft" && bench.text("re_chunk_000.pak.patch_004.pak") == "leon")
        #expect(bench.deployer.owners() == [leon.key, stacks.key, keys.key] && files.read(mods: mods).keys == [keys.key, stacks.key, leon.key] && bench.deployer.verify().isEmpty)

        // The upper mod out: the lower one's file comes back from the store; everything out: the game as it was.
        try bench.deployer.remove(owner: keys.key)
        #expect(bench.text(item) == "stacks" && bench.deployer.shadowed(stacks.key).isEmpty)
        try bench.deployer.remove(owner: stacks.key)
        try bench.deployer.remove(owner: leon.key)
        #expect(snapshot(bench.game) == before && bench.deployer.owners().isEmpty)
    }

    // MARK: After a failed launch

    @Test func loaderLogNamesTheScriptAndTheDumpBlamesTheNewest() throws {
        let re4 = try profile()
        let bench = try Bench(re4)
        let lua = try #require(re4.kind("lua")), script = try #require(re4.kind("script"))
        let dodge = mod("Dodge Roll and Sprint", key: "dodge-roll", kind: lua, unit: "Dodge_Roll_and_Sprint",
                        files: [("Dodge_Roll_and_Sprint.lua", "game:reframework/autorun/Dodge_Roll_and_Sprint.lua")], added: 100)
        let core = mod("_ScriptCore", key: "scriptcore", kind: script, unit: "_ScriptCore",
                       files: [("reframework/autorun/_ScriptCore.lua", "game:reframework/autorun/_ScriptCore.lua"), ("reframework/autorun/Hotkeys.lua", "game:reframework/autorun/Hotkeys.lua")], added: 200)
        let state = ModDiagnostics.State(mods: [dodge, core], installedFrameworks: ["reframework"])
        let diagnostics = ModDiagnostics(profile: re4, roots: bench.deployer.roots)
        #expect(diagnostics.collect(state).matches.isEmpty && diagnostics.collect(state).tail == nil)

        // The loader writes its level before the message, so the script's path comes after `[error]`.
        let log = """
        [2026-11-01 10:00:00.000] [info] [REFramework] Loading script: reframework/autorun/_ScriptCore.lua
        [2026-11-01 10:00:00.050] [info] [REFramework] Loading script: reframework/autorun/Dodge_Roll_and_Sprint.lua
        [2026-11-01 10:00:00.100] [error] [ScriptRunner] reframework/autorun/Dodge_Roll_and_Sprint.lua:42: attempt to call a nil value (field 'get_managed_singleton')

        """
        try Data(log.utf8).write(to: bench.url("re2_framework_log.txt"))
        let result = diagnostics.collect(state)
        #expect(result.matches.map(\.rule.action) == [.disableMod("dodge-roll")] && result.matches.first?.rule.id == ModDiagnostics.brokenModRule)
        #expect(result.unresolved.isEmpty && result.summary == nil)
        #expect(result.tail?.contains("attempt to call a nil value") == true && result.tail?.contains("Dodge_Roll") == false, "the tail kept for a report has no mod names")
        // And a message that names the script first and the error after, as the first rule expects.
        var unresolved: [String] = []
        let reversed = "[2026-11-01 10:00:01.000] [warning] [REFramework] autorun\\Hotkeys.lua:10: runtime error in hook\n"
        let matches = ModDiagnostics.matches(in: reversed, log: try #require(re4.logs.first), profile: re4, state: state, unresolved: &unresolved)
        #expect(matches.map(\.rule.action) == [.disableMod("scriptcore")] && unresolved.isEmpty)
        // A script nobody installed through Sommelier is reported, not acted on.
        let foreign = "[2026-11-01 10:00:02.000] [error] [ScriptRunner] reframework/autorun/Infinite_Ammo.lua:1: unexpected symbol\n"
        #expect(ModDiagnostics.matches(in: foreign, log: try #require(re4.logs.first), profile: re4, state: state, unresolved: &unresolved).isEmpty && unresolved == ["Infinite_Ammo.lua"])

        // A crash dump next to the game: the mod added last is the suspect, unless the dump is older than the launch.
        try FileManager.default.removeItem(at: bench.url("re2_framework_log.txt"))
        try Data("MDMP".utf8).write(to: bench.url("reframework_crash.dmp"))
        let crashed = diagnostics.collect(state)
        #expect(crashed.matches.map(\.rule.action) == [.disableMod("scriptcore")] && crashed.matches.first?.rule.id == ModDiagnostics.newestModRule && crashed.matches.first?.weight == 3)
        #expect(diagnostics.collect(state, since: Date().addingTimeInterval(60)).matches.isEmpty)
        // The proxy itself off: its override goes, nothing else about the launch changes.
        var launch = LaunchProfile()
        launch.dllOverrides = ["dinput8": "n,b"]
        let fix = ModDiagnostics.disable(try #require(re4.framework("reframework")), in: &launch)
        #expect(launch == LaunchProfile() && fix.action == .disableFramework("reframework"))
        ModDiagnostics.restore(fix.undo, in: &launch)
        #expect(launch.dllOverrides == ["dinput8": "n,b"])
    }

    @Test func gameVersionIsStampedFromTheProgram() throws {
        let re4 = try profile()
        let bench = try Bench(re4)
        let roots = bench.deployer.roots
        #expect(roots.resolve(try #require(ModPath("game:re4.exe")))?.path.hasSuffix(Self.gameFolder + "/re4.exe") == true)
        let first = try #require(ModGameVersion.stamp(profile: re4, roots: roots))
        #expect(first.hasPrefix("13:") && first.count == 3 + 16, "a program is its size and the start of its hash, not its bytes: \(first)")
        #expect(ModGameVersion.stamp(profile: re4, roots: roots) == first && !ModGameVersion.changed(since: first, profile: re4, roots: roots))
        #expect(!ModGameVersion.changed(since: nil, profile: re4, roots: roots), "nothing known yet means nothing changed")

        // A patch of the same size still reads differently; a text version file is the text itself.
        try Self.layout(["re4.exe": "MZ\0\u{90}game 1.1"], in: bench.game)
        let second = try #require(ModGameVersion.stamp(profile: re4, roots: roots))
        #expect(second != first && second.hasPrefix("13:") && ModGameVersion.changed(since: first, profile: re4, roots: roots))
        try Self.layout(["DA_Version.txt": "1.1.2.0\r\n"], in: bench.game)
        #expect(ModGameVersion.stamp(of: bench.url("DA_Version.txt")) == "1.1.2.0")
        try FileManager.default.removeItem(at: bench.url("re4.exe"))
        #expect(ModGameVersion.stamp(profile: re4, roots: roots) == nil && !ModGameVersion.changed(since: second, profile: re4, roots: roots))
        var state = ModState()
        state.gameVersion = second
        let decoded = try JSONDecoder().decode(ModState.self, from: try JSONEncoder().encode(state))
        let empty = try JSONDecoder().decode(ModState.self, from: Data("{}".utf8))
        #expect(decoded == state && empty.gameVersion == nil)
    }
}
