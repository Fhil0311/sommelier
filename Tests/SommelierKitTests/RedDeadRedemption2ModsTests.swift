// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The Red Dead Redemption 2 profile (experimental) against the archive layouts from `rdr2.md`: Script Hook's
/// `bin/` and Lenny's Mod Loader's `ModLoader/` fetched from the authors' pages only, `.asi` scripts with their
/// files next to the game's program, LML mods as `lml/<name>/` folders ordered through `mods.xml` the other way
/// round, "Play without mods" leaving the game folder as it was, and the two loaders' logs after a failed launch.
/// The Rockstar launcher chain is never changed: the proxies are picked up from the game folder.
struct RedDeadRedemption2ModsTests {
    static let gameFolder = "Red Dead Redemption 2"

    /// The frameworks come from the authors' pages through the app's browser: a downloader is never asked.
    private struct NoDownloader: ModDownloader {
        func download(_ download: ModDownload, into folder: URL) async throws -> URL {
            throw FrameworkInstallError.needsBrowser(download.url ?? "")
        }
    }

    /// The Steam install, a store and the deployer, all in temporary folders.
    private struct Bench {
        let root: URL, game: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile
        var launch = LaunchProfile()

        init(_ profile: ModProfile) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-rdr2-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("steamapps/common/\(RedDeadRedemption2ModsTests.gameFolder)", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/steam:1174180", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: support,
                                 appdata: root.appendingPathComponent("users/steamuser/AppData/Local", isDirectory: true),
                                 roaming: root.appendingPathComponent("users/steamuser/AppData/Roaming", isDirectory: true),
                                 documents: root.appendingPathComponent("users/steamuser/Documents", isDirectory: true))
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
            try RedDeadRedemption2ModsTests.layout(["RDR2.exe": "MZ\0\u{90}game 1.0.1491.50", "PlayRDR2.exe": "MZ\0\u{90}steam stub",
                                                    "x64/data/startup.rpf": "rpf", "update/update.rpf": "rpf"], in: game)
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        /// A mod in the store, made from a layout planned against the profile.
        func stored(_ name: String, _ files: [String: String], answers: ModArchive.Answers = .init()) throws -> StoredMod {
            let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
            try RedDeadRedemption2ModsTests.layout(files, in: unpacked)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name, answers: answers)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }

        /// A zip of the layout, made with `tar`, as `name` in a scratch folder of the bench.
        func archive(_ name: String, _ files: [String: String]) async throws -> URL {
            let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
            try RedDeadRedemption2ModsTests.layout(files, in: source)
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

    /// The fixture's RDR2 entry, with the frameworks' hashes pointed at stub archives when a test installs them.
    private func profile(hashes: [String: String] = [:]) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var games = try #require(json["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["game"] as? String == "steam:1174180" })
        if !hashes.isEmpty {
            var frameworks = try #require(games[index]["frameworks"] as? [[String: Any]])
            for i in frameworks.indices {
                guard let id = frameworks[i]["id"] as? String, let hash = hashes[id] else { continue }
                var download = try #require(frameworks[i]["download"] as? [String: Any])
                download["sha256"] = hash
                frameworks[i]["download"] = download
            }
            games[index]["frameworks"] = frameworks
        }
        json["games"] = games
        let list = try JSONDecoder().decode(ModsList.self, from: try JSONSerialization.data(withJSONObject: json))
        return try #require(list.profile(covering: "steam:1174180"))
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

    private func destinations(_ unit: ModPlan.Unit) -> [String] { unit.files.map(\.destination) }

    /// A stored mod as the diagnostics see it, without a store.
    private func mod(_ name: String, key: String, kind: ModKind, unit: String, files: [(String, String)], added: TimeInterval) -> StoredMod {
        StoredMod(key: key, name: name, version: nil, author: nil, origin: .init(), archive: .init(name: name + ".zip"),
                  added: Date(timeIntervalSince1970: added), enabled: true, codeAccepted: true,
                  units: [ModPlan.Unit(kind: kind, name: unit, root: "", code: kind.code, framework: kind.framework,
                                       files: files.map { .init(source: $0.0, destination: $0.1, skipped: false) })], leftovers: [])
    }

    /// Script Hook's zip from dev-c.com: the hook, Blade's ASI loader and the sample trainer in `bin/`.
    private let scriptHookZip = ["bin/ScriptHookRDR2.dll": "hook", "bin/dinput8.dll": "blade's loader", "bin/NativeTrainer.asi": "trainer", "readme.txt": "r"]
    /// LML's zip from rdr2mods.com: `ModLoader/` for the game folder and the WPF manager beside it. Whether the
    /// zip ships a blank `mods.xml` is for the spike; here it does, so the loader owns the file Sommelier rewrites.
    private let lmlZip = ["ModLoader/vfs.asi": "vfs", "ModLoader/lml.ini": "[Log]\r\nLevel=Info\r\n", "ModLoader/ModManager.Core.dll": "core",
                          "ModLoader/ModManager.NativeInterop.dll": "interop", "ModLoader/NLog.dll": "nlog", "ModLoader/lml/mods.xml": "<ModsManager/>",
                          "ModManager/ModManager.UI.exe": "ui", "ModManager/ModManager.UI.exe.config": "cfg", "ModManager/Newtonsoft.Json.dll": "json"]
    private let versionZip = ["version.dll": "lms loader", "readme.txt": "r"]

    private let rampage = ["Rampage.asi": "rampage", "RampageFiles/Config/Settings.json": "{}", "RampageFiles/Vehicles/vehicles.json": "[]"]

    // MARK: The profile

    @Test func profileIsExperimentalAndLeavesTheRockstarLaunchAlone() throws {
        let rdr2 = try profile()
        #expect(rdr2.status == .experimental && rdr2.runtime == .wine && rdr2.aliases.isEmpty, "shown only with the experimental flag, and the release decision waits for the spike")
        #expect(rdr2.sources.nexus?.domain == "reddeadredemption2" && rdr2.sources.modio == nil)
        #expect(rdr2.sources.other == ["https://www.dev-c.com/rdr2/scripthookrdr2/", "https://www.rdr2mods.com/"])

        #expect(rdr2.frameworks.map(\.id) == ["scripthookrdr2", "lml", "asiloader-version"])
        for framework in rdr2.frameworks {
            let note = Comment(rawValue: framework.id)
            #expect(framework.code && framework.download.kind == .url && framework.download.viaBrowser && framework.download.sha256 == nil, note)
            #expect(framework.launch == nil && framework.components.isEmpty && framework.remove.isEmpty && framework.disableArgument == nil,
                    "the Steam → Rockstar Launcher → RDR2.exe chain stays; the proxies are picked up from the game folder")
            #expect(framework.license == "none", "no licence text: never bundled, fetched from the author's page")
        }
        let hook = try #require(rdr2.framework("scripthookrdr2"))
        #expect(!hook.optional && hook.requires.isEmpty && hook.dllOverrides == ["dinput8": "n,b"])
        #expect(hook.pick.map(\.match) == ["bin/ScriptHookRDR2.dll|bin/dinput8.dll"] && hook.pick.first?.to == "game:", "the sample trainer stays out")
        let lml = try #require(rdr2.framework("lml"))
        #expect(!lml.optional && lml.requires == ["scripthookrdr2"] && lml.dllOverrides.isEmpty, "vfs.asi is an .asi: Blade's loader picks it up")
        #expect(lml.pick.count == 2 && lml.pick[0].to == "game:" && lml.pick[1].match == "ModLoader/lml/**" && lml.pick[1].stripTo == "lml")
        #expect(!lml.pick[0].match.contains("UI.exe") && !lml.pick[0].match.contains("*"), "the loader's files by name, next to RDR2.exe; the manager never")
        let version = try #require(rdr2.framework("asiloader-version"))
        #expect(version.optional && version.dllOverrides == ["version": "n,b"] && version.pick.map(\.match) == ["version.dll"] && !rdr2.kinds.contains { $0.framework == "asiloader-version" },
                "only when a mod asks for it; no kind does by itself")

        #expect(rdr2.kinds.map(\.id) == ["asi", "lml", "stream"])
        let asi = try #require(rdr2.kind("asi"))
        #expect(asi.code && asi.framework == "scripthookrdr2" && asi.unit == .file && asi.siblings && asi.to == "game:" && asi.order == .none && asi.pinned == nil)
        let folder = try #require(rdr2.kind("lml"))
        #expect(!folder.code && folder.framework == "lml" && folder.unit == .folder && folder.marker == "install.xml" && folder.to == "game:lml/{name}/" && folder.order == .orderFile)
        let stream = try #require(rdr2.kind("stream"))
        #expect(stream.ask && !stream.code && stream.framework == "lml" && stream.unit == .file && stream.to == "game:lml/stream/" && stream.order == .none)

        #expect(rdr2.loadOrder.format == .lml && rdr2.loadOrder.reverse && rdr2.loadOrder.file == "game:lml/mods.xml" && rdr2.loadOrder.isReorderable)
        #expect(rdr2.loadOrder.pinLast == ["Online Content Unlocker", "Red Dead Offline"] && rdr2.loadOrder.pinFirst.isEmpty && rdr2.loadOrder.pinLastGroups.isEmpty)
        #expect(rdr2.conflicts.samePath == .warn && rdr2.conflicts.rules.map(\.reason) == ["sameDataFile"] && rdr2.conflicts.rules.first?.sameStem == true && rdr2.conflicts.rules.first?.max == nil,
                "two mods on `weapons.ymt` is a warning with the upper winning, not a block: LML merges data files")
        #expect(rdr2.archive.variants == nil && rdr2.archive.wrappers && rdr2.archive.ignore == ModArchiveRules.defaultIgnore)
        #expect(rdr2.archive.deny == ["dinput8.dll", "version.dll", "ScriptHookRDR2.dll", "vfs.asi", "dxgi.dll", "d3d12.dll"])
        #expect(rdr2.archive.reject.map(\.reason) == ["executable", "loader", "reshade"])
        #expect(rdr2.logs.map(\.file) == ["game:asiloader.log", "game:ScriptHookRDR2.log"] && rdr2.logs.allSatisfy { $0.exists == nil && $0.summary == nil })
        #expect(rdr2.logs[0].rules.map(\.action) == [.disableMod, .disableFramework] && rdr2.logs[1].rules.map(\.framework) == ["scripthookrdr2"])
        #expect(rdr2.saves == [SaveSource(root: .documents, path: "Rockstar Games/Red Dead Redemption 2/Profiles")])
        #expect(rdr2.notes.gameVersionFile == "game:RDR2.exe" && rdr2.notes.cleanupOnLastCodeMod && rdr2.notes.untouched.isEmpty,
                "every patch breaks the proxies: the stamp tells the player why")

        #expect(rdr2.online.policy == .storyOnly && rdr2.online.moddedLaunch == .same && rdr2.online.antiCheat == nil && rdr2.online.noticeKey == "storyOnly")
        #expect(rdr2.online.separateSave == nil && rdr2.online.cleanBeforeVanilla.isEmpty && !rdr2.online.forbidsPlainLaunchWithMods)
        #expect(rdr2.online.playWithoutModsRemoves == ["game:dinput8.dll", "game:version.dll", "game:vfs.asi", "game:*.asi", "game:lml/"])
        let guardian = LaunchGuard(profile: rdr2, roots: ModRoots(game: nil, store: URL(fileURLWithPath: "/tmp/s"), tools: URL(fileURLWithPath: "/tmp/t"), home: URL(fileURLWithPath: "/tmp/h")))
        #expect(guardian.allowsPlainLaunch(modsEnabled: true) && guardian.loaderFramework == nil && !guardian.usesSeparateSave())
        #expect(try guardian.decide(modsEnabled: true, installed: ["scripthookrdr2", "lml"]) == .plain(leftovers: []), "the usual launch, with the overrides")
        #expect(try guardian.decide(modsEnabled: false, installed: []) == .plain(leftovers: []))
    }

    // MARK: Archives

    @Test func scriptsTakeTheirFilesAndLoaderCopiesStayOut() throws {
        let rdr2 = try profile()
        // Rampage Trainer: the script with its data folder, which goes next to RDR2.exe as it is.
        let plan = ModArchive.plan(paths: Array(rampage.keys), profile: rdr2, archiveName: "Rampage Trainer-2846-1-3-4")
        let unit = try #require(plan.units.first)
        #expect(plan.isReady && plan.units.count == 1 && unit.kind.id == "asi" && unit.name == "Rampage" && unit.code && unit.framework == "scripthookrdr2")
        #expect(destinations(unit) == ["game:Rampage.asi", "game:RampageFiles/Config/Settings.json", "game:RampageFiles/Vehicles/vehicles.json"])
        #expect(plan.leftovers.isEmpty && plan.notes.isEmpty && plan.containsCode && plan.frameworks == ["scripthookrdr2"])
        // The same inside a folder named after the archive: the wrapper comes off, the name stays the script's.
        let wrapped = ModArchive.plan(paths: rampage.keys.map { "Rampage Trainer 1.3.4/" + $0 }, profile: rdr2)
        #expect(wrapped.isReady && wrapped.units.map(\.name) == ["Rampage"] && wrapped.notes == [.wrapperRemoved("Rampage Trainer 1.3.4")] && wrapped.base == "Rampage Trainer 1.3.4")
        #expect(wrapped.units.first.map(destinations) == destinations(unit))

        // Lenny's Simple Trainer ships a stale `version.dll`: the script and its ini go in, the loader copy never.
        let lst = ModArchive.plan(paths: ["LST.asi", "lst.ini", "version.dll"], profile: rdr2)
        #expect(lst.isReady && lst.units.map(\.name) == ["LST"] && lst.units.first.map(destinations) == ["game:LST.asi", "game:lst.ini"])
        #expect(lst.notes == [.denied("version.dll")] && lst.leftovers.isEmpty)
        // Two scripts in one archive are two mods, each with its own ini.
        let two = ModArchive.plan(paths: ["BankRobberies.asi", "BankRobberies.ini", "BasicNeeds.asi", "BasicNeeds.ini"], profile: rdr2)
        #expect(two.units.map(\.name) == ["BankRobberies", "BasicNeeds"] && two.units.map { destinations($0).count } == [2, 2])

        // Script Hook's own zip dropped in as a mod: the hook and the loader are denied, the sample trainer gives it away.
        let hook = ModArchive.plan(paths: Array(scriptHookZip.keys), profile: rdr2, archiveName: "ScriptHookRDR2_1.0.1491.17")
        #expect(hook.refusal == .init(reason: .rejected("loader"), path: "NativeTrainer.asi"))
        #expect(hook.notes == [.wrapperRemoved("bin"), .denied("ScriptHookRDR2.dll"), .denied("dinput8.dll")])
        #expect(ModArchive.plan(paths: ["dinput8.dll", "ScriptHookRDR2.dll"], profile: rdr2).refusal?.reason == .nothingRecognised)
        // LML's own zip: the manager is a program; the loader's files on their own are no mod.
        #expect(ModArchive.plan(paths: Array(lmlZip.keys), profile: rdr2).refusal?.reason == .rejected("executable"))
        #expect(ModArchive.plan(paths: ["ModLoader/vfs.asi", "ModLoader/lml.ini"], profile: rdr2).refusal == .init(reason: .nothingRecognised, path: nil))
        // ReShade presets and trainers are programs in the game's folder, not mods.
        let reshade = ModArchive.plan(paths: ["dxgi.dll", "ReShade.ini", "RDR2 Photorealistic.ini", "reshade-shaders/Shaders/LUT.fx"], profile: rdr2)
        #expect(reshade.refusal == .init(reason: .rejected("reshade"), path: "ReShade.ini") && reshade.notes == [.denied("dxgi.dll")])
        #expect(ModArchive.plan(paths: ["Red Dead Redemption 2 Trainer.exe", "trainer.dll"], profile: rdr2).refusal?.reason == .rejected("executable"))
    }

    @Test func lmlModsAreFoldersAndStreamFilesAreAsked() throws {
        let rdr2 = try profile()
        // WhyEm's DLC comes with `lml/` at the archive's root: the folder with `install.xml` is the mod.
        let whyem = ["lml/WhyEm's DLC/install.xml": "<EasyInstall/>", "lml/WhyEm's DLC/Item_Catelog/catalog_sp.ymt": "c",
                     "lml/WhyEm's DLC/Weapon_Refrences/weapons.ymt": "w", "lml/WhyEm's DLC/stream/whyem_hat.ydd": "h", "README - WhyEm's DLC.txt": "r"]
        let plan = ModArchive.plan(paths: Array(whyem.keys), profile: rdr2, archiveName: "WhyEms DLC-2465-3-5")
        let unit = try #require(plan.units.first)
        #expect(plan.isReady && plan.units.count == 1 && unit.kind.id == "lml" && unit.name == "WhyEm's DLC" && !unit.code && unit.framework == "lml")
        #expect(destinations(unit) == ["game:lml/WhyEm's DLC/Item_Catelog/catalog_sp.ymt", "game:lml/WhyEm's DLC/Weapon_Refrences/weapons.ymt",
                                       "game:lml/WhyEm's DLC/install.xml", "game:lml/WhyEm's DLC/stream/whyem_hat.ydd"])
        #expect(plan.leftovers.isEmpty && !plan.containsCode && plan.frameworks == ["lml"] && plan.questions.isEmpty, "stream files inside an LML mod are its own, nothing to ask")
        // Without `lml/`, and with the mod's folder as the one wrapper: the same mod.
        let bare = ModArchive.plan(paths: ["Online Content Unlocker/install.xml", "Online Content Unlocker/stream/0x1A2B3C4D.ymt"], profile: rdr2)
        #expect(bare.isReady && bare.units.map(\.name) == ["Online Content Unlocker"] && bare.units.first.map(destinations) == ["game:lml/Online Content Unlocker/install.xml", "game:lml/Online Content Unlocker/stream/0x1A2B3C4D.ymt"])
        // Two LML mods in one archive are two mods.
        let pair = ModArchive.plan(paths: ["lml/Crime Rebalance/install.xml", "lml/Crime Rebalance/data/dispatch.meta", "lml/Stutter Fix/install.xml", "lml/Stutter Fix/data/gameconfig.xml"], profile: rdr2)
        #expect(pair.units.map(\.name).sorted() == ["Crime Rebalance", "Stutter Fix"] && pair.units.allSatisfy { $0.kind.id == "lml" })

        // Enhanced Edition mixes an LML pack and a script: two mods from one archive, the script with its ini.
        let enhanced = ModArchive.plan(paths: ["lml/RDR2 Enhanced Edition/install.xml", "lml/RDR2 Enhanced Edition/stream/ee_horse.ydd", "lml/RDR2 Enhanced Edition/data/weapons.ymt",
                                               "EnhancedEdition.asi", "EnhancedEdition.ini"], profile: rdr2, archiveName: "RDR2 Enhanced Edition-1005-2-0")
        #expect(enhanced.isReady && enhanced.units.map(\.name) == ["EnhancedEdition", "RDR2 Enhanced Edition"] && enhanced.units.map(\.kind.id) == ["asi", "lml"])
        #expect(enhanced.units[0].files.map(\.destination) == ["game:EnhancedEdition.asi", "game:EnhancedEdition.ini"] && enhanced.units[0].code && !enhanced.units[1].code)
        #expect(enhanced.units[1].files.map(\.destination) == ["game:lml/RDR2 Enhanced Edition/data/weapons.ymt", "game:lml/RDR2 Enhanced Edition/install.xml", "game:lml/RDR2 Enhanced Edition/stream/ee_horse.ydd"])
        #expect(enhanced.frameworks == ["scripthookrdr2", "lml"] && enhanced.containsCode && enhanced.notes.isEmpty && enhanced.leftovers.isEmpty)

        // Raw stream files without an `install.xml`: the player says whether they go into `lml/stream/`.
        let raw = ["stream/0x5F3A1C22.ytd", "stream/a_c_horse_01.ydd"]
        let asked = ModArchive.plan(paths: raw, profile: rdr2)
        #expect(asked.questions == [.kind(id: "stream", files: ["0x5F3A1C22.ytd", "a_c_horse_01.ydd"])] && asked.units.isEmpty && asked.refusal == nil && !asked.isReady)
        let yes = ModArchive.plan(paths: raw, profile: rdr2, answers: .init(kinds: ["stream": true]))
        #expect(yes.isReady && yes.units.map(\.name) == ["0x5F3A1C22", "a_c_horse_01"] && yes.units.allSatisfy { $0.kind.id == "stream" && !$0.code && $0.framework == "lml" })
        #expect(yes.units.flatMap(destinations) == ["game:lml/stream/0x5F3A1C22.ytd", "game:lml/stream/a_c_horse_01.ydd"])
        #expect(ModArchive.plan(paths: raw, profile: rdr2, answers: .init(kinds: ["stream": false])).refusal?.reason == .nothingRecognised)
    }

    // MARK: The loaders

    @Test func loadersComeFromTheAuthorsPagesWithTheProfilesHash() async throws {
        var bench = try Bench(try profile())
        let before = snapshot(bench.game)
        let hook = try await bench.archive("ScriptHookRDR2_1.0.1491.17.zip", scriptHookZip)
        let lml = try await bench.archive("LennysModLoader_0.6.8470.31280.zip", lmlZip)
        let version = try await bench.archive("RDR2ASILoader_0.2.2.zip", versionZip)
        let profile = try profile(hashes: ["scripthookrdr2": try #require(ModStore.sha256(of: hook)), "lml": try #require(ModStore.sha256(of: lml)),
                                           "asiloader-version": try #require(ModStore.sha256(of: version))])
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: NoDownloader())

        // No archive from the browser yet: nothing is fetched behind the player's back, nothing placed.
        await #expect(throws: FrameworkInstallError.needsBrowser("https://www.dev-c.com/rdr2/scripthookrdr2/")) {
            _ = try await installer.install("lml", launchProfile: &bench.launch)
        }
        #expect(snapshot(bench.game) == before && installer.installed().isEmpty && bench.launch == LaunchProfile())
        // Another file than the one the profile pins: the install stops before anything is unpacked; no mirror is tried.
        do {
            _ = try await installer.install("scripthookrdr2", archive: lml, launchProfile: &bench.launch)
            Issue.record("a hash mismatch must stop the install")
        } catch FrameworkInstallError.hashMismatch(let framework, let expected, let actual) {
            #expect(framework == "scripthookrdr2" && expected == profile.framework("scripthookrdr2")?.download.sha256 && actual == ModStore.sha256(of: lml))
        }
        #expect(snapshot(bench.game) == before && installer.installed().isEmpty)

        // Script Hook: the hook and Blade's loader next to RDR2.exe, the sample trainer and the readme left in the zip.
        let hooked = try await installer.install("scripthookrdr2", archive: hook, launchProfile: &bench.launch)
        #expect(Set(hooked.placed) == ["game:ScriptHookRDR2.dll", "game:dinput8.dll"] && hooked.alsoInstalled.isEmpty && hooked.overwroteForeign.isEmpty)
        #expect(bench.text("ScriptHookRDR2.dll") == "hook" && bench.text("dinput8.dll") == "blade's loader")
        #expect(!bench.exists("NativeTrainer.asi") && !bench.exists("readme.txt") && !bench.exists("bin"))
        #expect(bench.launch.dllOverrides == ["dinput8": "n,b"] && bench.launch.extraArguments.isEmpty && bench.launch.redirect == nil)
        #expect(hooked.fixes.map(\.ruleID) == ["framework:scripthookrdr2"] && hooked.components.isEmpty)

        // LML: `ModLoader/`'s files go flat into the game folder, its `lml/` folder keeps its name; the manager stays out.
        let loaded = try await installer.install("lml", archive: lml, launchProfile: &bench.launch)
        #expect(loaded.alsoInstalled.isEmpty && loaded.fixes.isEmpty && loaded.components.isEmpty)
        #expect(Set(loaded.placed) == ["game:vfs.asi", "game:lml.ini", "game:ModManager.Core.dll", "game:ModManager.NativeInterop.dll", "game:NLog.dll", "game:lml/mods.xml"])
        #expect(bench.text("vfs.asi") == "vfs" && bench.text("lml.ini") == "[Log]\r\nLevel=Info\r\n" && bench.text("lml/mods.xml") == "<ModsManager/>")
        #expect(!bench.exists("ModLoader") && !bench.exists("ModManager") && !bench.exists("ModManager.UI.exe") && !bench.exists("Newtonsoft.Json.dll"))
        #expect(bench.launch.dllOverrides == ["dinput8": "n,b"], "vfs.asi needs no override of its own")

        // The optional loader, only when a mod asks for it: `version.dll` with its own override.
        let versioned = try await installer.install("asiloader-version", archive: version, launchProfile: &bench.launch)
        #expect(versioned.placed == ["game:version.dll"] && bench.text("version.dll") == "lms loader" && !bench.exists("readme.txt"))
        #expect(bench.launch.dllOverrides == ["dinput8": "n,b", "version": "n,b"] && versioned.fixes.map(\.ruleID) == ["framework:asiloader-version"])
        #expect(installer.installed() == ["scripthookrdr2", "lml", "asiloader-version"] && bench.deployer.verify().isEmpty)

        // The last code mod gone, every loader goes too, and the game folder is as it was.
        #expect(installer.unneeded(mods: []) == ["scripthookrdr2", "lml", "asiloader-version"])
        let fixes = hooked.fixes + versioned.fixes
        for id in installer.unneeded(mods: []).reversed() { try installer.uninstall(id, fixes: fixes, launchProfile: &bench.launch) }
        #expect(snapshot(bench.game) == before && bench.launch == LaunchProfile() && bench.deployer.owners().isEmpty && installer.installed().isEmpty)
    }

    // MARK: Order

    @Test func lmlOrderIsWrittenTheOtherWayRoundAroundStrangers() throws {
        let bench = try Bench(try profile())
        // Someone's mod already in `lml/`, listed in a `mods.xml` the manager wrote.
        try Self.layout(["lml/SomeoneElse/install.xml": "<EasyInstall/>", "lml/SomeoneElse/data/x.meta": "m"], in: bench.game)
        let managers = """
        <?xml version="1.0" encoding="utf-8"?>
        <ModsManager>
          <Mods>
            <Mod folder="SomeoneElse"><Name>Someone Else</Name><Enabled>true</Enabled></Mod>
          </Mods>
          <LoadOrder>
            <Mod>SomeoneElse</Mod>
          </LoadOrder>
        </ModsManager>

        """
        try Self.layout(["lml/mods.xml": managers], in: bench.game)
        let before = snapshot(bench.game)

        let files = LoadOrderFiles(profile: bench.profile, deployer: bench.deployer)
        let whyem = try bench.stored("WhyEm's DLC", ["WhyEm's DLC/install.xml": "<EasyInstall/>", "WhyEm's DLC/Weapon_Refrences/weapons.ymt": "whyem"])
        let unlocker = try bench.stored("Online Content Unlocker", ["Online Content Unlocker/install.xml": "<EasyInstall/>", "Online Content Unlocker/stream/0x1A2B3C4D.ymt": "u"])
        let bounties = try bench.stored("Bounties", ["Bounties/install.xml": "<EasyInstall/>"])
        let mods = [whyem, unlocker, bounties]
        for mod in mods { try bench.deployer.deploy(mod) }
        #expect(bench.text("lml/WhyEm's DLC/Weapon_Refrences/weapons.ymt") == "whyem" && bench.exists("lml/Online Content Unlocker/install.xml") && bench.exists("lml/Bounties/install.xml"))

        // "Goes last" in the game is the top of the list, pinned; the two others follow in the order they came.
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        #expect(order.keys == [unlocker.key, whyem.key, bounties.key] && order.canReorder && order.item(unlocker.key)?.pin == .first)
        #expect(order.moving(unlocker.key, to: 2) == nil && order.moving(bounties.key, to: 0) == nil, "the unlocker has no handle and nothing goes above it")
        try files.apply(order, mods: mods)
        func listed() throws -> [String] {
            let document = try XMLDocument(xmlString: try #require(bench.text("lml/mods.xml")), options: [])
            return document.rootElement()?.elements(forName: "LoadOrder").first?.elements(forName: "Mod").compactMap(\.stringValue) ?? []
        }
        #expect(try listed() == ["SomeoneElse", "Bounties", "WhyEm's DLC", "Online Content Unlocker"], "ours after the stranger, reversed, the unlocker last in the file")
        #expect(files.read(mods: mods).keys == [unlocker.key, whyem.key, bounties.key])
        let xml = try #require(bench.text("lml/mods.xml"))
        #expect(xml.contains("<Name>Someone Else</Name>") && LoadOrder.LML.enabled(xml, folder: "SomeoneElse") == true && LoadOrder.LML.enabled(xml, folder: "WhyEm's DLC") == true)
        #expect(bench.deployer.verify().isEmpty, "the manager's file isn't ours; rewriting it is no finding")

        // Bounties above WhyEm's: later in the file. Then the manager moves the stranger between ours: the list follows.
        let moved = try #require(order.moving(bounties.key, to: 1))
        try files.apply(moved, mods: mods)
        #expect(try listed() == ["SomeoneElse", "WhyEm's DLC", "Bounties", "Online Content Unlocker"] && files.read(mods: mods).keys == [unlocker.key, bounties.key, whyem.key])
        let byHand = try #require(bench.text("lml/mods.xml")).replacingOccurrences(of: "<Mod>SomeoneElse</Mod>", with: "").replacingOccurrences(of: "<Mod>Bounties</Mod>", with: "<Mod>Bounties</Mod><Mod>SomeoneElse</Mod>")
        try Self.layout(["lml/mods.xml": byHand], in: bench.game)
        #expect(files.read(mods: mods).keys == [unlocker.key, bounties.key, whyem.key])
        try files.apply(files.read(mods: mods), mods: mods)
        #expect(try listed() == ["WhyEm's DLC", "Bounties", "Online Content Unlocker", "SomeoneElse"],
                "ours are written as one block where the first of them stood; the stranger is kept, after it (the minimal writer until the spike)")

        // Off is a switch in the file and the folder gone from `lml/`; on brings both back.
        try bench.deployer.setEnabled(whyem, false)
        var off = whyem; off.enabled = false
        try files.apply(moved.setting(whyem.key, enabled: false), mods: [off, unlocker, bounties])
        #expect(LoadOrder.LML.enabled(try #require(bench.text("lml/mods.xml")), folder: "WhyEm's DLC") == false && !bench.exists("lml/WhyEm's DLC"))
        try bench.deployer.setEnabled(whyem, true)
        try files.apply(moved, mods: mods)
        #expect(LoadOrder.LML.enabled(try #require(bench.text("lml/mods.xml")), folder: "WhyEm's DLC") == true && bench.text("lml/WhyEm's DLC/Weapon_Refrences/weapons.ymt") == "whyem")

        // Two mods on `weapons.ymt`: a warning naming the stem, the upper one winning; nothing blocked. Without the loader, every mod needs it.
        let marston = try bench.stored("John Marston Restoration", ["JMRP/install.xml": "<EasyInstall/>", "JMRP/replace/weapons.ymt": "jmrp"])
        try bench.deployer.deploy(marston)
        let all = mods + [marston]
        let report = ModConflicts.check(all, profile: bench.profile, order: moved.keys + [marston.key], installedFrameworks: ["scripthookrdr2", "lml"])
        #expect(report.findings == [.init(cause: .rule(reason: "sameDataFile", hint: nil, matched: "weapons"), severity: .warn, mods: [whyem.key, marston.key])])
        #expect(!report.isBlocked(marston.key) && report.findings(for: bounties.key).isEmpty)
        let bare = ModConflicts.check(all, profile: bench.profile, order: moved.keys + [marston.key], installedFrameworks: [])
        #expect(bare.findings.filter { $0.cause == .needsFramework("lml") }.count == 4 && bare.isBlocked(whyem.key))

        // Everything out: the stranger's folder and the manager's entry for it untouched.
        for mod in all { try bench.deployer.remove(owner: mod.key) }
        var after = snapshot(bench.game)
        #expect(after.removeValue(forKey: "lml/mods.xml") != nil && before.filter { $0.key != "lml/mods.xml" } == after)
        #expect(try listed().contains("SomeoneElse") && bench.exists("lml/SomeoneElse/data/x.meta") && bench.deployer.owners().isEmpty)
    }

    // MARK: Play without mods

    @Test func playWithoutModsLeavesTheGameFolderAsItWas() async throws {
        var bench = try Bench(try profile())
        let before = snapshot(bench.game)
        let hook = try await bench.archive("ScriptHookRDR2_1.0.1491.17.zip", scriptHookZip)
        let lml = try await bench.archive("LennysModLoader_0.6.8470.31280.zip", lmlZip)
        let profile = try profile(hashes: ["scripthookrdr2": try #require(ModStore.sha256(of: hook)), "lml": try #require(ModStore.sha256(of: lml))])
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: NoDownloader())
        let files = LoadOrderFiles(profile: profile, deployer: bench.deployer)
        let guardian = LaunchGuard(profile: profile, roots: bench.deployer.roots)

        // The loaders, a script and an LML pack in, the order written; next to them what someone else put there.
        var fixes = try await installer.install("scripthookrdr2", archive: hook, launchProfile: &bench.launch).fixes
        fixes += try await installer.install("lml", archive: lml, launchProfile: &bench.launch).fixes
        let store = ModStore(folder: bench.store.folder)
        let rampage = try bench.stored("Rampage Trainer", self.rampage)
        let whyem = try bench.stored("WhyEm's DLC", ["lml/WhyEm's DLC/install.xml": "<EasyInstall/>", "lml/WhyEm's DLC/Weapon_Refrences/weapons.ymt": "whyem"])
        for mod in [rampage, whyem] { try bench.deployer.deploy(mod) }
        try files.apply(LoadOrder(spec: profile.loadOrder, mods: [rampage, whyem]), mods: [rampage, whyem])
        try Self.layout(["version.dll": "someone's loader", "Other.asi": "theirs", "lml/SomeoneElse/install.xml": "<EasyInstall/>"], in: bench.game)
        #expect(bench.deployer.verify().isEmpty && bench.text("lml/mods.xml")?.contains("WhyEm's DLC") == true, "the loader's `mods.xml`, rewritten by us, is still ours")
        #expect(guardian.leftovers().isEmpty, "nothing is checked before a plain launch: the policy is story mode, not offline")

        let targets = guardian.playWithoutModsTargets(deployer: bench.deployer)
        #expect(targets.foreign == ["game:version.dll", "game:Other.asi"], "a `*` names each script it matches; the stranger's LML folder sits under ours for now")
        #expect(Set(targets.ours) == ["game:dinput8.dll", "game:vfs.asi", "game:Rampage.asi", "game:lml/"], "ours come out through the deployer and the installer")

        // As the app does it: every mod off, the loaders nobody needs any more out, then the strangers' files aside.
        for var mod in store.list() where mod.enabled {
            try bench.deployer.setEnabled(mod, false)
            mod.enabled = false
            try store.save(mod)
            let mods = store.list()
            try files.apply(files.read(mods: mods).setting(mod.key, enabled: false), mods: mods)
        }
        #expect(!bench.exists("Rampage.asi") && !bench.exists("RampageFiles") && !bench.exists("lml/WhyEm's DLC") && bench.exists("vfs.asi"))
        let unneeded = installer.unneeded(mods: store.list())
        #expect(unneeded == ["scripthookrdr2", "lml"])
        for id in unneeded.reversed() { try installer.uninstall(id, fixes: fixes, launchProfile: &bench.launch) }
        #expect(!bench.exists("dinput8.dll") && !bench.exists("vfs.asi") && !bench.exists("lml/mods.xml") && bench.launch == LaunchProfile())
        let foreign = guardian.playWithoutModsTargets(deployer: bench.deployer).foreign
        #expect(foreign == ["game:version.dll", "game:Other.asi", "game:lml/"], "with ours gone, `lml/` is the stranger's alone")
        let moved = try LaunchGuard.removeLeftovers(foreign, roots: bench.deployer.roots, store: bench.store, deployer: bench.deployer, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(moved == foreign && snapshot(bench.game) == before, "the game folder is the vanilla one: Red Dead Online sees no proxy, no script, no `lml/`")

        // Nothing was deleted: the strangers' files wait in the store.
        let bin = bench.store.folder.appendingPathComponent(".leftovers")
        let stamps = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        #expect(stamps.count == 1)
        let kept = bin.appendingPathComponent(stamps[0]).appendingPathComponent("game")
        #expect(try String(contentsOf: kept.appendingPathComponent("version.dll"), encoding: .utf8) == "someone's loader")
        #expect(try String(contentsOf: kept.appendingPathComponent("lml/SomeoneElse/install.xml"), encoding: .utf8) == "<EasyInstall/>")
        #expect(store.list().map(\.enabled) == [false, false] && store.list().count == 2, "the mods stay in the store, off")
    }

    // MARK: After a failed launch

    @Test func loaderLogsNameTheScriptOrTheHook() throws {
        let rdr2 = try profile()
        let bench = try Bench(rdr2)
        let asi = try #require(rdr2.kind("asi")), lml = try #require(rdr2.kind("lml"))
        let rampage = mod("Rampage Trainer", key: "rampage-trainer", kind: asi, unit: "Rampage",
                          files: [("Rampage.asi", "game:Rampage.asi"), ("RampageFiles/Config/Settings.json", "game:RampageFiles/Config/Settings.json")], added: 100)
        let lst = mod("Lenny's Simple Trainer", key: "lennys-simple-trainer", kind: asi, unit: "LST", files: [("LST.asi", "game:LST.asi"), ("lst.ini", "game:lst.ini")], added: 200)
        let whyem = mod("WhyEm's DLC", key: "whyems-dlc", kind: lml, unit: "WhyEm's DLC", files: [("install.xml", "game:lml/WhyEm's DLC/install.xml")], added: 300)
        let state = ModDiagnostics.State(mods: [rampage, lst, whyem], installedFrameworks: ["scripthookrdr2", "lml"])
        let diagnostics = ModDiagnostics(profile: rdr2, roots: bench.deployer.roots)
        #expect(diagnostics.collect(state).matches.isEmpty && diagnostics.collect(state).tail == nil)

        // The ASI loader writes the whole path of what it couldn't load: the script's own name finds the mod.
        let asiLog = """
        // ASI Loader by Alexander Blade
        "Z:\\Games\\Red Dead Redemption 2\\Rampage.asi" loaded
        "Z:\\Games\\Red Dead Redemption 2\\LST.asi" failed to load
        "Z:\\Games\\Red Dead Redemption 2\\vfs.asi" loaded

        """
        try Data(asiLog.utf8).write(to: bench.url("asiloader.log"))
        let result = diagnostics.collect(state)
        #expect(result.matches.map(\.rule.action) == [.disableMod("lennys-simple-trainer")] && result.matches.first?.rule.id == ModDiagnostics.brokenModRule)
        #expect(result.unresolved.isEmpty && result.summary == nil)
        #expect(result.tail?.contains("failed to load") == true && result.tail?.contains("LST") == false && result.tail?.contains("Rampage") == false, "the tail kept for a report has no mod names")
        // A script nobody installed through Sommelier is reported, not acted on; a bare name does as well as a path.
        var unresolved: [String] = []
        let foreign = "\"Other.asi\" failed to load\n\"Rampage.asi\" failed to load\n"
        let matches = ModDiagnostics.matches(in: foreign, log: rdr2.logs[0], profile: rdr2, state: state, unresolved: &unresolved)
        #expect(matches.map(\.rule.action) == [.disableMod("rampage-trainer")] && unresolved == ["Other.asi"])
        // `vfs.asi` failing is the loader out of step with the game, not a mod: the proxy's override comes off, so the game starts plain.
        let stale = "\"Z:\\Games\\Red Dead Redemption 2\\vfs.asi\" failed to load\n"
        let loader = ModDiagnostics.matches(in: stale, log: rdr2.logs[0], profile: rdr2, state: state, unresolved: &unresolved)
        #expect(loader.map(\.rule.action) == [.disableFramework("scripthookrdr2")] && unresolved == ["Other.asi"], "vfs.asi is nobody's mod and isn't listed as one")

        // Script Hook after a game patch: its log says the version is unknown; the hook is turned off for the launch and back again.
        try FileManager.default.removeItem(at: bench.url("asiloader.log"))
        let hookLog = """
        // ScriptHookRDR2 by Alexander Blade
        [10:00:00] INIT: Started
        [10:00:00] FATAL: Unknown game version, update is required

        """
        try Data(hookLog.utf8).write(to: bench.url("ScriptHookRDR2.log"))
        let outdated = diagnostics.collect(state)
        #expect(outdated.matches.map(\.rule.action) == [.disableFramework("scripthookrdr2")] && outdated.matches.first?.rule.id == ModDiagnostics.loaderOutdatedRule)
        #expect(diagnostics.collect(ModDiagnostics.State(mods: state.mods, installedFrameworks: ["lml"])).matches.isEmpty, "a hook that isn't installed can't be turned off")
        let fine = "[10:00:00] INIT: Started\n[10:00:00] INIT: Success, game version is 1.0.1491.50\n"
        #expect(ModDiagnostics.matches(in: fine, log: rdr2.logs[1], profile: rdr2, state: state, unresolved: &unresolved).isEmpty)
        var launch = LaunchProfile()
        launch.dllOverrides = ["dinput8": "n,b", "version": "n,b"]
        let fix = ModDiagnostics.disable(try #require(rdr2.framework("scripthookrdr2")), in: &launch)
        #expect(launch.dllOverrides == ["version": "n,b"] && launch.extraArguments.isEmpty && fix.action == .disableFramework("scripthookrdr2"), "no disable argument: the proxy's override goes, nothing else")
        ModDiagnostics.restore(fix.undo, in: &launch)
        #expect(launch.dllOverrides == ["dinput8": "n,b", "version": "n,b"])

        // The game's version stamp: a patch changes it, which is when the proxies stop working.
        let roots = bench.deployer.roots
        let first = try #require(ModGameVersion.stamp(profile: rdr2, roots: roots))
        try Self.layout(["RDR2.exe": "MZ\0\u{90}game 1.0.1491.51"], in: bench.game)
        #expect(ModGameVersion.changed(since: first, profile: rdr2, roots: roots))
    }
}
