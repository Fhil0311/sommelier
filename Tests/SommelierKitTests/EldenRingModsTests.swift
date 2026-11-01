// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The Elden Ring profile (offline only) against the archive layouts from `eldenring.md`: packages in
/// FromSoftware's layout and DLL mods kept in the store, Mod Engine 2 bundles read from their config without
/// their launchers ever running, me3 installed under `Tools/` with nothing in `Game/`, the `.me3` profile
/// generated from the list, the plain Steam launch refused while mods are on, other loaders' leftovers found
/// before a launch without them, and the modded save file in the backup set. Easy Anti-Cheat never meets a mod.
struct EldenRingModsTests {
    static let gameFolder = "ELDEN RING"

    /// me3 comes from GitHub with the profile's hash; a test hands the archive over itself.
    private struct NoDownloader: ModDownloader {
        func download(_ download: ModDownload, into folder: URL) async throws -> URL {
            throw FrameworkInstallError.needsBrowser(download.url ?? "")
        }
    }

    /// The Steam install with its bottle's user folders, a store and the deployer, all in temporary folders.
    private struct Bench {
        let root: URL, game: URL, tools: URL, windowsHome: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile
        var launch = LaunchProfile()

        init(_ profile: ModProfile) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-eldenring-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("steamapps/common/\(EldenRingModsTests.gameFolder)", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            tools = support.appendingPathComponent("Tools", isDirectory: true)
            windowsHome = root.appendingPathComponent("users/steamuser", isDirectory: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/steam-1245620", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: tools, home: support,
                                 appdata: windowsHome.appendingPathComponent("AppData/Local", isDirectory: true),
                                 roaming: windowsHome.appendingPathComponent("AppData/Roaming", isDirectory: true),
                                 documents: windowsHome.appendingPathComponent("Documents", isDirectory: true))
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
            try EldenRingModsTests.layout(["Game/eldenring.exe": "MZ\0\u{90}game 1.16.0", "Game/start_protected_game.exe": "MZ\0\u{90}eac wrapper",
                                           "Game/EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe": "MZ", "Game/steam_api64.dll": "MZ",
                                           "Game/regulation.bin": "vanilla params", "Game/Data0.bhd": "bhd"], in: game)
        }

        var saveRoots: SaveRoots { SaveRoots(profile: windowsHome, install: game) }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
        func stored(_ relative: String) -> String? { try? String(contentsOf: store.folder.appendingPathComponent(relative), encoding: .utf8) }

        /// A mod in the store, made from a layout planned against the profile.
        func stored(_ name: String, _ files: [String: String], answers: ModArchive.Answers = .init()) throws -> StoredMod {
            let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
            try EldenRingModsTests.layout(files, in: unpacked)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name, answers: answers)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }

        /// A zip of the layout, made with `tar`, as `name` in a scratch folder of the bench.
        func archive(_ name: String, _ files: [String: String]) async throws -> URL {
            let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
            try EldenRingModsTests.layout(files, in: source)
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

    /// The fixture's Elden Ring entry, with me3's hash pointed at a stub archive when a test installs it.
    private func profile(me3Hash: String? = nil) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var games = try #require(json["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["game"] as? String == "steam:1245620" })
        if let me3Hash {
            var frameworks = try #require(games[index]["frameworks"] as? [[String: Any]])
            var download = try #require(frameworks[0]["download"] as? [String: Any])
            download["sha256"] = me3Hash
            frameworks[0]["download"] = download
            games[index]["frameworks"] = frameworks
        }
        json["games"] = games
        let list = try JSONDecoder().decode(ModsList.self, from: try JSONSerialization.data(withJSONObject: json))
        return try #require(list.profile(covering: "steam:1245620"))
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

    /// me3's Windows zip as release v0.13.0 ships it: the programs in `bin/`, the licences, a changelog, the
    /// default profiles and the batch files next to them.
    private let me3Zip = ["bin/me3.exe": "me3", "bin/me3-launcher.exe": "launcher", "bin/me3_mod_host.dll": "host", "LICENSE-APACHE": "apache", "LICENSE-MIT": "mit",
                          "CHANGELOG.pdf": "%PDF", "eldenring-default.me3": "profileVersion = \"v1\"\n", "launch-eldenring-mods.bat": "me3 launch", "eldenring-mods/.keep": ""]

    /// Clever's Moveset: parameters and animations in FromSoftware's layout, in the mod's own folder.
    private let clevers = ["Clevers Moveset/regulation.bin": "clever params", "Clevers Moveset/chr/c0000.anibnd.dcx": "anims",
                           "Clevers Moveset/parts/am_m_1000.partsbnd.dcx": "parts", "Clevers Moveset/README.md": "r"]
    /// Glorious Merchant: a DLL with its settings next to it.
    private let merchant = ["ermerchant.dll": "MZ merchant", "ermerchant.ini": "[settings]\r\nhotkey=F5\r\n"]

    /// Mod Engine 2's config as a bundle ships it: the mod folder enabled, an old one switched off, Seamless
    /// Co-op as an external DLL.
    private let me2Config = """
    [modengine]
    debug = false
    external_dlls = [ "SeamlessCoop\\\\ersc.dll" ]

    [extension.mod_loader]
    enabled = true
    loose_params = false
    mods = [
        { enabled = true, name = "convergence", path = "mod" },
        { enabled = false, name = "old", path = "mod_old" }
    ]
    """

    // MARK: The profile

    @Test func profileStartsModdedPlayOnlyThroughMe3AndLeavesTheGameFolderAlone() throws {
        let elden = try profile()
        #expect(elden.status == .ready && elden.runtime == .wine && elden.aliases.isEmpty)
        #expect(elden.sources.nexus?.domain == "eldenring" && elden.sources.modio == nil && elden.sources.other == ["https://me3.help/"])

        #expect(elden.frameworks.map(\.id) == ["me3"])
        let me3 = try #require(elden.framework("me3"))
        #expect(me3.code && !me3.optional && me3.requires.isEmpty && me3.license == "Apache-2.0 OR MIT")
        #expect(me3.download.kind == .github && me3.download.repo == "garyttierney/me3" && me3.download.asset == "me3-windows-amd64.zip" && me3.download.tag == "v0.13.0")
        #expect(me3.download.sha256?.count == 64 && !me3.download.viaBrowser, "the hash pins the release, so does the tag")
        #expect(URLModDownloader.directURL(of: me3.download)?.absoluteString == "https://github.com/garyttierney/me3/releases/download/v0.13.0/me3-windows-amd64.zip")
        #expect(me3.pick.map(\.to) == ["tools:me3/"] && me3.pick[0].match == "bin/**|LICENSE-*" && me3.remove.isEmpty && me3.skip.isEmpty && me3.copyAs.isEmpty && me3.settings.isEmpty,
                "the loader lives under Tools/, never in the game: a plain Steam launch stays vanilla")
        #expect(me3.dllOverrides.isEmpty && me3.disableArgument == nil && me3.components == ["installVCRuntime"] && me3.componentActions == [.installVCRuntime],
                "no proxy DLL: me3 injects its host itself")
        let loader = try #require(me3.launch?.loader)
        #expect(me3.launch?.redirect == nil && me3.launch?.arguments == nil)
        #expect(loader.exe == "tools:me3/bin/me3.exe" && loader.config == "me3" && loader.steamInBottle)
        #expect(loader.args == ["launch", "--skip-steam-init", "--exe-path", "{gameExe:Game/eldenring.exe}", "-p", "{config}"],
                "eldenring.exe itself, never start_protected_game.exe: the anti-cheat is never started with mods")
        #expect(FrameworkInstaller.launchFixes(of: me3).isEmpty, "a loader is no fix on the launch profile")

        #expect(elden.kinds.map(\.id) == ["me2import", "native", "package"], "a bundle's config first, then DLLs, then everything in FromSoftware's layout")
        for kind in elden.kinds {
            let note = Comment(rawValue: kind.id)
            #expect(kind.framework == "me3" && kind.to == "store:{name}/" && kind.order == .config && kind.pinned == nil && kind.enable == nil && !kind.ask, note)
        }
        let me2 = try #require(elden.kind("me2import"))
        #expect(!me2.code && me2.unit == .folder && me2.marker == "config_eldenring.toml" && me2.importer == "modengine2")
        let native = try #require(elden.kind("native"))
        #expect(native.code && native.unit == .file && native.match == "**/*.dll" && native.siblings)
        let package = try #require(elden.kind("package"))
        #expect(!package.code && package.unit == .tree && package.stripToParentOf?.hasPrefix("regulation.bin|parts|chr|") == true && package.stripTo == nil)

        #expect(elden.archive.variants == "regulation.bin" && elden.archive.wrappers && elden.archive.ignore == ModArchiveRules.defaultIgnore)
        #expect(elden.archive.deny == ["dinput8.dll", "winhttp.dll", "dxgi.dll", "modengine2.dll", "modengine2_launcher.exe", "ersc_launcher.exe", "**/SeamlessCoop/**"])
        #expect(elden.archive.reject.map(\.reason) == ["eacToggler", "executable", "reshade", "saveFile"])
        #expect(elden.archive.reject[1].unlessNearby == "config_eldenring.toml", "a bundle's launcher is stored with it, never run")

        #expect(elden.loadOrder.format == .loaderConfig && elden.loadOrder.config == "me3" && elden.loadOrder.file == "store:sommelier.me3" && elden.loadOrder.isReorderable)
        #expect(!elden.loadOrder.reverse && elden.loadOrder.pinFirst.isEmpty && elden.loadOrder.pinLast.isEmpty && elden.loadOrder.pinLastGroups.isEmpty)
        #expect(elden.conflicts.samePath == .warn && elden.conflicts.needs == nil)
        #expect(elden.conflicts.rules.map(\.reason) == ["regulation"] && elden.conflicts.rules[0].max == 1 && elden.conflicts.rules[0].match == "**/regulation.bin")
        #expect(elden.logs.map(\.file) == ["appdata:garyttierney/me3/data/logs/sommelier/*.log", "game:Game/crashdumps/*.dmp"])
        #expect(elden.logs[0].rules.isEmpty && elden.logs[0].exists == nil && elden.logs[1].exists?.action == .disableNewestMod && elden.logs.allSatisfy { $0.summary == nil })
        #expect(elden.saves == [SaveSource(root: .roaming, path: "EldenRing")])
        #expect(elden.notes.gameVersionFile == "game:Game/eldenring.exe" && elden.notes.cleanupOnLastCodeMod && elden.notes.untouched.isEmpty)

        let online = elden.online
        #expect(online.policy == .offlineOnly && online.antiCheat == "eac" && online.moddedLaunch == .loader && online.noticeKey == "offline")
        #expect(online.forbidsPlainLaunchWithMods, "with any mod on, the Steam launch through the anti-cheat is refused")
        #expect(online.separateSave?.enabled == true && online.separateSave?.via == "loaderConfig" && online.separateSave?.file == "ER0000_sommelier.sl2")
        #expect(online.cleanBeforeVanilla == ["game:Game/dinput8.dll", "game:Game/winhttp.dll", "game:Game/SeamlessCoop/", "game:Game/steam_appid.txt",
                                              "game:Game/modengine2_launcher.exe", "game:Game/mods/"])
        #expect(online.playWithoutModsRemoves.isEmpty, "nothing of ours is in the game folder to take out")

        let guardian = LaunchGuard(profile: elden, roots: ModRoots(game: nil, store: URL(fileURLWithPath: "/tmp/s"), tools: URL(fileURLWithPath: "/tmp/t"), home: URL(fileURLWithPath: "/tmp/h")))
        #expect(!guardian.allowsPlainLaunch(modsEnabled: true) && guardian.allowsPlainLaunch(modsEnabled: false) && guardian.loaderFramework?.id == "me3")
        #expect(guardian.usesSeparateSave() && !guardian.usesSeparateSave(playerChoice: false) && guardian.separateSaveFile == "ER0000_sommelier.sl2")
        #expect(throws: LaunchGuard.Refusal.loaderRequired(framework: "me3")) { try guardian.decide(modsEnabled: true, installed: []) }
        #expect(try guardian.decide(modsEnabled: false, installed: []) == .plain(leftovers: []))
    }

    // MARK: Archives

    @Test func packagesKeepFromSoftwaresLayoutAndDLLsTheirSettings() throws {
        let elden = try profile()
        // Easy Mode: one regulation.bin per variant folder is a question; the answer names the mod.
        let easy = ["Easy/regulation.bin": "easy", "Easier/regulation.bin": "easier", "Easiest/regulation.bin": "easiest"]
        let asked = ModArchive.plan(paths: Array(easy.keys), profile: elden, archiveName: "Easy Mode for Elden Ring-1234-2-0")
        #expect(asked.questions == [.variant(options: ["Easier", "Easiest", "Easy"])] && asked.units.isEmpty && asked.refusal == nil && !asked.isReady)
        let easier = ModArchive.plan(paths: Array(easy.keys), profile: elden, archiveName: "Easy Mode for Elden Ring-1234-2-0", answers: .init(variant: "Easier"))
        #expect(easier.isReady && easier.units.map(\.name) == ["Easier"] && easier.units[0].kind.id == "package" && !easier.units[0].code)
        #expect(easier.units.first.map(destinations) == ["store:Easier/regulation.bin"] && easier.notes == [.variantChosen("Easier")] && easier.base == "Easier")
        // A single regulation.bin at the root is the whole mod, named after the archive.
        let grand = ModArchive.plan(paths: ["regulation.bin", "README.txt"], profile: elden, archiveName: "Grand Merchant-631-1-10")
        #expect(grand.isReady && grand.units.map(\.name) == ["Grand Merchant-631-1-10"] && grand.units.first.map(destinations) == ["store:Grand Merchant-631-1-10/regulation.bin"])

        // Clever's Moveset: parameters, animations and parts from the folder they share, the readme left out.
        let plan = ModArchive.plan(paths: Array(clevers.keys), profile: elden, archiveName: "Clevers Moveset Modpack-3296-5-1")
        let unit = try #require(plan.units.first)
        #expect(plan.isReady && plan.units.count == 1 && unit.kind.id == "package" && unit.name == "Clevers Moveset" && !unit.code && unit.framework == "me3")
        #expect(destinations(unit) == ["store:Clevers Moveset/chr/c0000.anibnd.dcx", "store:Clevers Moveset/parts/am_m_1000.partsbnd.dcx", "store:Clevers Moveset/regulation.bin"])
        #expect(plan.leftovers.isEmpty && plan.notes == [.wrapperRemoved("Clevers Moveset")] && !plan.containsCode && plan.frameworks == ["me3"])
        // Detailed Item Descriptions: only messages, from the folder above `msg/`.
        let msg = ModArchive.plan(paths: ["Detailed Item Descriptions/msg/engus/item.msgbnd.dcx", "Detailed Item Descriptions/msg/engus/menu.msgbnd.dcx"], profile: elden)
        #expect(msg.isReady && msg.units.map(\.name) == ["Detailed Item Descriptions"] && msg.units.first.map(destinations)?.allSatisfy { $0.hasPrefix("store:Detailed Item Descriptions/msg/engus/") } == true)

        // TechieW's DLL mods come as `mods/<name>.dll` with their ini, often with Elden Mod Loader's proxy: the proxy is denied, the DLL runs as a native.
        let fps = ModArchive.plan(paths: ["mods/erfps.dll", "mods/erfps.ini", "dinput8.dll"], profile: elden, archiveName: "Unlock the framerate-2120-1-2")
        let native = try #require(fps.units.first)
        #expect(fps.isReady && fps.units.count == 1 && native.kind.id == "native" && native.name == "erfps" && native.code && native.framework == "me3")
        #expect(destinations(native) == ["store:erfps/erfps.dll", "store:erfps/erfps.ini"] && fps.notes == [.denied("dinput8.dll")] && fps.leftovers.isEmpty && fps.containsCode)
        // The same without the proxy: the `mods/` folder is a wrapper, nothing more.
        let bare = ModArchive.plan(paths: ["mods/PauseTheGame.dll", "mods/PauseTheGame.ini"], profile: elden)
        #expect(bare.isReady && bare.units.map(\.name) == ["PauseTheGame"] && bare.units.first.map(destinations) == ["store:PauseTheGame/PauseTheGame.dll", "store:PauseTheGame/PauseTheGame.ini"] && bare.notes == [.wrapperRemoved("mods")])
        // Glorious Merchant at the archive's root, with its ini.
        let glorious = ModArchive.plan(paths: Array(merchant.keys), profile: elden, archiveName: "Glorious Merchant-2808-1-3")
        #expect(glorious.isReady && glorious.units.map(\.name) == ["ermerchant"] && glorious.units.first.map(destinations) == ["store:ermerchant/ermerchant.dll", "store:ermerchant/ermerchant.ini"] && glorious.containsCode)
        // UnlockTheFps already made for me3: the DLL in `natives/` is the mod, the author's `.me3` stays in the store unused (ours is generated).
        let unlock = ModArchive.plan(paths: ["UnlockTheFps.me3", "natives/UnlockTheFps.dll", "natives/UnlockTheFps.ini", "natives/README.txt"], profile: elden, archiveName: "UnlockTheFps-10437-1-0")
        #expect(unlock.isReady && unlock.units.map(\.name) == ["UnlockTheFps"] && unlock.units[0].kind.id == "native")
        #expect(unlock.units.first.map(destinations) == ["store:UnlockTheFps/UnlockTheFps.dll", "store:UnlockTheFps/UnlockTheFps.ini"] && unlock.leftovers == ["UnlockTheFps.me3"])
        // A DLL and a package in one archive are two mods: the DLL never counts as an asset.
        let both = ModArchive.plan(paths: ["Reforged Lite/regulation.bin", "Reforged Lite/parts/x.partsbnd.dcx", "Reforged Lite/ReforgedLite.dll", "Reforged Lite/ReforgedLite.ini"], profile: elden)
        #expect(both.isReady && both.units.map(\.kind.id) == ["native", "package"] && both.units.map(\.name) == ["ReforgedLite", "Reforged Lite"])
        #expect(both.units[1].files.map(\.destination) == ["store:Reforged Lite/parts/x.partsbnd.dcx", "store:Reforged Lite/regulation.bin"] && both.containsCode)
    }

    @Test func bundlesAreReadFromTheirConfigAndTheToolsThatBypassTheAntiCheatAreRefused() throws {
        let elden = try profile()
        // The Convergence brings its own Mod Engine 2: the config says which folders load; its launchers are
        // stored with it and never run, the engine's files are denied, the second regulation.bin is no variant.
        let convergence = ["ConvergenceER/config_eldenring.toml": me2Config, "ConvergenceER/modengine2_launcher.exe": "MZ", "ConvergenceER/modengine2/bin/modengine2.dll": "MZ",
                           "ConvergenceER/launchmod_eldenring.bat": "launch", "ConvergenceER/Convergence Launcher.exe": "MZ launcher",
                           "ConvergenceER/mod/regulation.bin": "convergence params", "ConvergenceER/mod/parts/am_m_1100.partsbnd.dcx": "p", "ConvergenceER/mod/chr/c3000.anibnd.dcx": "c",
                           "ConvergenceER/mod_old/regulation.bin": "old params", "ConvergenceER/SeamlessCoop/ersc.dll": "coop"]
        let plan = ModArchive.plan(paths: Array(convergence.keys), profile: elden, archiveName: "The Convergence-3419-3-0-1")
        let unit = try #require(plan.units.first)
        #expect(plan.isReady && plan.questions.isEmpty && plan.units.count == 1 && unit.kind.id == "me2import" && unit.name == "ConvergenceER" && !unit.code && unit.framework == "me3")
        #expect(plan.notes == [.wrapperRemoved("ConvergenceER"), .denied("SeamlessCoop/ersc.dll"), .denied("modengine2/bin/modengine2.dll"), .denied("modengine2_launcher.exe")])
        #expect(destinations(unit) == ["store:ConvergenceER/Convergence Launcher.exe", "store:ConvergenceER/config_eldenring.toml", "store:ConvergenceER/launchmod_eldenring.bat",
                                       "store:ConvergenceER/mod/chr/c3000.anibnd.dcx", "store:ConvergenceER/mod/parts/am_m_1100.partsbnd.dcx", "store:ConvergenceER/mod/regulation.bin",
                                       "store:ConvergenceER/mod_old/regulation.bin"], "everything but the engine stays together, so the config's paths hold")
        #expect(plan.leftovers.isEmpty && !plan.containsCode)
        // The same program outside a bundle is a trainer: refused.
        #expect(ModArchive.plan(paths: ["Elden Ring Trainer.exe", "trainer.dll"], profile: elden).refusal == .init(reason: .rejected("executable"), path: "Elden Ring Trainer.exe"))

        // Seamless Co-op: its launcher and its folder are denied whole; nothing is left to install.
        let coop = ["ersc_launcher.exe": "MZ", "SeamlessCoop/ersc.dll": "coop", "SeamlessCoop/ersc_settings.ini": "[GAMEPLAY]", "SeamlessCoop/locale/english.json": "{}"]
        let seamless = ModArchive.plan(paths: Array(coop.keys), profile: elden, archiveName: "Seamless Co-op-510-1-9-1")
        #expect(seamless.refusal == .init(reason: .nothingRecognised, path: nil) && seamless.units.isEmpty)
        #expect(seamless.notes == [.denied("SeamlessCoop/ersc.dll"), .denied("SeamlessCoop/ersc_settings.ini"), .denied("SeamlessCoop/locale/english.json"), .denied("ersc_launcher.exe")])
        let wrapped = ModArchive.plan(paths: coop.keys.map { "Seamless Co-op 1.9.1/" + $0 }, profile: elden)
        #expect(wrapped.refusal?.reason == .nothingRecognised && wrapped.notes.filter { if case .denied = $0 { true } else { false } }.count == 4)

        // The Anti-Cheat Toggler is a switch Sommelier doesn't need: refused by name, its dummy proxy denied.
        let toggler = ModArchive.plan(paths: ["toggle_anti_cheat.exe", "start_game_in_offline_mode.exe", "winhttp.dll", "README.txt"], profile: elden, archiveName: "Anti-Cheat Toggler-90-1-3")
        #expect(toggler.refusal == .init(reason: .rejected("eacToggler"), path: "start_game_in_offline_mode.exe") && toggler.notes == [.denied("winhttp.dll")])
        // Elden Mod Loader on its own: the proxy is denied, and a config with an empty `mods/` is no mod.
        let loader = ModArchive.plan(paths: ["dinput8.dll", "mod_loader_config.ini", "mods/"], profile: elden, archiveName: "Elden Mod Loader-117-1-4")
        #expect(loader.refusal?.reason == .nothingRecognised && loader.notes == [.denied("dinput8.dll")])
        // ReShade presets and save files are not mods either.
        #expect(ModArchive.plan(paths: ["dxgi.dll", "ReShade.ini", "Cinematic.ini", "reshade-shaders/Shaders/LUT.fx"], profile: elden).refusal?.reason == .rejected("reshade"))
        #expect(ModArchive.plan(paths: ["ER0000.sl2"], profile: elden).refusal == .init(reason: .rejected("saveFile"), path: "ER0000.sl2"))
        #expect(ModArchive.plan(paths: ["ER0000.co2"], profile: elden).refusal?.reason == .rejected("saveFile"))
    }

    // MARK: The loader

    @Test func me3InstallsUnderToolsAndStartsTheGameItselfInsteadOfSteam() async throws {
        var bench = try Bench(try profile())
        let before = snapshot(bench.game)
        let zip = try await bench.archive("me3-windows-amd64.zip", me3Zip)
        let profile = try profile(me3Hash: try #require(ModStore.sha256(of: zip)))
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: NoDownloader())
        let guardian = LaunchGuard(profile: profile, roots: bench.deployer.roots)

        // Another file than the one the profile pins: nothing is unpacked.
        let other = try await bench.archive("something-else.zip", ["bin/me3.exe": "not me3"])
        await #expect(throws: FrameworkInstallError.self) { _ = try await installer.install("me3", archive: other, launchProfile: &bench.launch) }
        #expect(installer.installed().isEmpty && !FileManager.default.fileExists(atPath: bench.tools.appendingPathComponent("me3").path))

        // The programs and the licences under Tools/me3/; the batch files and the default profiles stay in the zip; the game folder is as it was.
        let installed = try await installer.install("me3", archive: zip, launchProfile: &bench.launch)
        #expect(installed.placed.sorted() == ["tools:me3/LICENSE-APACHE", "tools:me3/LICENSE-MIT", "tools:me3/bin/me3-launcher.exe", "tools:me3/bin/me3.exe", "tools:me3/bin/me3_mod_host.dll"])
        #expect(try String(contentsOf: bench.tools.appendingPathComponent("me3/bin/me3.exe"), encoding: .utf8) == "me3")
        #expect(!FileManager.default.fileExists(atPath: bench.tools.appendingPathComponent("me3/launch-eldenring-mods.bat").path))
        #expect(!FileManager.default.fileExists(atPath: bench.tools.appendingPathComponent("me3/eldenring-default.me3").path))
        #expect(snapshot(bench.game) == before, "nothing in the game folder: Steam's own launch is still the vanilla one")
        #expect(installed.components == [.installVCRuntime] && installed.fixes.isEmpty && installed.alsoInstalled.isEmpty && bench.launch == LaunchProfile())
        #expect(installer.installed() == ["me3"] && bench.deployer.verify().isEmpty)

        // With mods on, the launch is me3's command: eldenring.exe by its bottle path and our profile, Steam running in the bottle.
        guard case .loader(let command) = try guardian.decide(modsEnabled: true, installed: ["me3"]) else { Issue.record("not the loader"); return }
        #expect(command.framework == "me3" && command.executable == bench.tools.appendingPathComponent("me3/bin/me3.exe") && command.workingDirectory == bench.tools.appendingPathComponent("me3/bin"))
        #expect(command.steamInBottle && command.config == bench.store.folder.appendingPathComponent("sommelier.me3"))
        #expect(command.arguments == ["launch", "--skip-steam-init", "--exe-path", LaunchGuard.winePath(bench.game) + "\\Game\\eldenring.exe", "-p", LaunchGuard.winePath(bench.store.folder) + "\\sommelier.me3"])
        #expect(!command.arguments.contains { $0.contains("start_protected_game") })
        // Without mods, the usual launch; with the loader's program gone, no launch with mods at all.
        #expect(try guardian.decide(modsEnabled: false, installed: ["me3"]) == .plain(leftovers: []))
        try FileManager.default.removeItem(at: bench.tools.appendingPathComponent("me3/bin/me3.exe"))
        #expect(throws: LaunchGuard.Refusal.loaderMissing("me3")) { try guardian.decide(modsEnabled: true, installed: ["me3"]) }
        #expect(bench.deployer.verify().map(\.problem) == [.missing])
        try bench.deployer.repair(bench.deployer.verify())
        #expect(bench.deployer.verify().isEmpty && (try? guardian.decide(modsEnabled: true, installed: ["me3"])) != nil)

        // Nothing needs the loader any more: it goes, and Tools/ holds nothing of it.
        #expect(installer.unneeded(mods: []) == ["me3"])
        try installer.uninstall("me3", fixes: installed.fixes, launchProfile: &bench.launch)
        #expect(installer.installed().isEmpty && bench.deployer.owners().isEmpty && snapshot(bench.tools).keys.filter { !$0.hasSuffix("/") }.isEmpty && snapshot(bench.game) == before)
    }

    // MARK: Order and conflicts

    @Test func me3ProfileIsGeneratedFromTheListAndReadBack() throws {
        let bench = try Bench(try profile())
        let before = snapshot(bench.game)
        let files = LoadOrderFiles(profile: bench.profile, deployer: bench.deployer)
        let clevers = try bench.stored("Clever's Moveset", clevers)
        let merchant = try bench.stored("Glorious Merchant", merchant)
        // A Mod Engine 2 + Seamless Co-op bundle: the config names a DLL the archive rules denied; it can't be in the profile.
        let bundle = try bench.stored("ME2 + Seamless", ["ME2/config_eldenring.toml": me2Config, "ME2/modengine2_launcher.exe": "MZ", "ME2/launchmod_eldenring.bat": "launch",
                                                         "ME2/mod/regulation.bin": "bundle params", "ME2/mod/parts/am_m_1000.partsbnd.dcx": "bundle parts",
                                                         "ME2/mod_old/regulation.bin": "old", "ME2/SeamlessCoop/ersc.dll": "coop"])
        let mods = [clevers, merchant, bundle]
        for mod in mods { try bench.deployer.deploy(mod) }
        #expect(bench.stored("Clevers Moveset/regulation.bin") == "clever params" && bench.stored("ermerchant/ermerchant.ini") == "[settings]\r\nhotkey=F5\r\n" && bench.stored("ME2/mod/regulation.bin") == "bundle params")
        #expect(bench.stored("ME2/SeamlessCoop/ersc.dll") == nil && bench.stored("ME2/modengine2_launcher.exe") == nil && snapshot(bench.game) == before, "the mods live in the store; the game folder is untouched")

        #expect(files.me3Entries(clevers) == [.init(kind: .package, id: "Clevers Moveset", path: "Clevers Moveset/")])
        #expect(files.me3Entries(merchant) == [.init(kind: .native, path: "ermerchant/ermerchant.dll")], "the ini sits next to the DLL, where it looks for it")
        #expect(files.me3Entries(bundle) == [.init(kind: .package, id: "convergence", path: "ME2/mod/")], "the disabled folder and the denied DLL are left out")

        // The profile, top first, with the modded save and online off.
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        #expect(order.keys == [clevers.key, merchant.key, bundle.key] && order.canReorder && order.items.allSatisfy { $0.pin == nil })
        try files.apply(order, mods: mods)
        let written = try #require(bench.stored("sommelier.me3"))
        let parsed = LoadOrder.Me3.read(written)
        #expect(parsed.values["profileVersion"] == "v1" && parsed.values["savefile"] == "ER0000_sommelier.sl2" && parsed.values["start_online"] == "false")
        #expect(written.contains("[[supports]]\ngame = \"eldenring\"") && !written.contains("ersc"))
        #expect(parsed.entries == [.init(kind: .package, id: "Clevers Moveset", path: "Clevers Moveset/"), .init(kind: .native, path: "ermerchant/ermerchant.dll"),
                                   .init(kind: .package, id: "convergence", path: "ME2/mod/")])
        #expect(files.read(mods: mods).keys == [clevers.key, merchant.key, bundle.key])
        for entry in parsed.entries {
            #expect(FileManager.default.fileExists(atPath: bench.store.folder.appendingPathComponent(entry.path).path), "every path in the profile is there next to it: \(entry.path)")
        }

        // The bundle on top and the merchant off: the profile follows, the list remembers the mod it doesn't name.
        let moved = try #require(order.moving(bundle.key, to: 0)).setting(merchant.key, enabled: false)
        try bench.deployer.setEnabled(merchant, false)
        var off = merchant; off.enabled = false
        try files.apply(moved, mods: [clevers, off, bundle], separateSave: false)
        let again = LoadOrder.Me3.read(try #require(bench.stored("sommelier.me3")))
        #expect(again.entries.map(\.path) == ["ME2/mod/", "Clevers Moveset/"] && again.values["savefile"] == nil && again.values["start_online"] == "false",
                "the player turned the separate save off; online stays off whatever they do")
        #expect(files.read(mods: [clevers, off, bundle]).keys == [bundle.key, clevers.key, merchant.key] && bench.stored("ermerchant/ermerchant.dll") == nil)
        // A profile written by hand, me3's own way (single quotes, a Windows path), reads back in its order; the
        // mod it doesn't name comes after, from the store's memory of the list.
        let byHand = "profileVersion = \"v1\"\n[[supports]]\ngame = \"eldenring\"\n[[packages]]\nid = 'conv'\npath = 'ME2\\mod\\'\n[[packages]]\nid = \"clever\"\npath = \"Clevers Moveset/\"\n"
        try Self.layout(["sommelier.me3": byHand], in: bench.store.folder)
        #expect(files.read(mods: mods).keys == [bundle.key, clevers.key, merchant.key])

        // Everything out: the store holds no mod folders, the game folder was never touched.
        try bench.deployer.setEnabled(merchant, true)
        #expect(bench.stored("ermerchant/ermerchant.dll") == "MZ merchant")
        for mod in mods { try bench.deployer.remove(owner: mod.key) }
        #expect(bench.deployer.owners().isEmpty && !FileManager.default.fileExists(atPath: bench.store.folder.appendingPathComponent("Clevers Moveset").path))
        #expect(!FileManager.default.fileExists(atPath: bench.store.folder.appendingPathComponent("ME2").path) && snapshot(bench.game) == before)
    }

    @Test func oneRegulationFileAtATimeAndTheUpperPackageWins() throws {
        let bench = try Bench(try profile())
        let clevers = try bench.stored("Clever's Moveset", clevers)
        let easy = try bench.stored("Easy Mode", ["Easy/regulation.bin": "easy", "Easier/regulation.bin": "easier"], answers: .init(variant: "Easier"))
        let parts = try bench.stored("Better Parts", ["Better Parts/parts/am_m_1000.partsbnd.dcx": "better", "Better Parts/parts/am_m_2000.partsbnd.dcx": "new"])
        let merchant = try bench.stored("Glorious Merchant", merchant)
        let all = [clevers, easy, parts, merchant]
        let order = [clevers.key, easy.key, parts.key, merchant.key]

        // Two regulation.bin files can't both be on: the game takes one, so the pair is blocked, the others aren't.
        let report = ModConflicts.check(all, profile: bench.profile, order: order, installedFrameworks: ["me3"])
        let regulation = ModConflicts.Finding(cause: .rule(reason: "regulation", hint: nil, matched: "**/regulation.bin"), severity: .block, mods: [clevers.key, easy.key])
        #expect(report.findings.contains(regulation) && report.isBlocked(clevers.key) && report.isBlocked(easy.key) && !report.isBlocked(parts.key) && !report.isBlocked(merchant.key))
        // The same part in two packages is a warning with the upper one winning: me3 takes the first package that has it.
        let samePart = ModConflicts.Finding(cause: .samePath("parts/am_m_1000.partsbnd.dcx", winner: clevers.key), severity: .warn, mods: [clevers.key, parts.key])
        #expect(report.findings.contains(samePart) && report.findings.count == 2, "the two regulation files are the rule's finding alone, not a same-path warning as well")
        let swapped = ModConflicts.check(all, profile: bench.profile, order: [parts.key, clevers.key, easy.key, merchant.key], installedFrameworks: ["me3"])
        #expect(swapped.findings.contains(.init(cause: .samePath("parts/am_m_1000.partsbnd.dcx", winner: parts.key), severity: .warn, mods: [parts.key, clevers.key])))

        // Easy Mode off: nothing blocks. Without me3 every mod needs it.
        var off = easy; off.enabled = false
        let settled = ModConflicts.check([clevers, off, parts, merchant], profile: bench.profile, order: order, installedFrameworks: ["me3"])
        #expect(settled.findings == [samePart] && settled.blocked.isEmpty)
        let bare = ModConflicts.check([clevers, off, parts, merchant], profile: bench.profile, order: order, installedFrameworks: [])
        #expect(bare.findings.filter { $0.cause == .needsFramework("me3") }.count == 3 && bare.isBlocked(merchant.key))
    }

    // MARK: Launching

    @Test func plainLaunchIsRefusedWithModsOnAndOtherLoadersLeftoversAreFoundWithThemOff() async throws {
        var bench = try Bench(try profile())
        let zip = try await bench.archive("me3-windows-amd64.zip", me3Zip)
        let profile = try profile(me3Hash: try #require(ModStore.sha256(of: zip)))
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: NoDownloader())
        let guardian = LaunchGuard(profile: profile, roots: bench.deployer.roots)
        let files = LoadOrderFiles(profile: profile, deployer: bench.deployer)
        _ = try await installer.install("me3", archive: zip, launchProfile: &bench.launch)
        let clevers = try bench.stored("Clever's Moveset", clevers)
        try bench.deployer.deploy(clevers)
        try files.apply(LoadOrder(spec: profile.loadOrder, mods: [clevers]), mods: [clevers])
        let vanilla = snapshot(bench.game)

        // A mod is on: the Steam launch (start_protected_game.exe, the anti-cheat) is refused; only me3 starts the game.
        #expect(!guardian.allowsPlainLaunch(modsEnabled: true))
        guard case .loader = try guardian.decide(modsEnabled: true, installed: ["me3"]) else { Issue.record("not the loader"); return }
        #expect(throws: LaunchGuard.Refusal.loaderRequired(framework: "me3")) { try guardian.decide(modsEnabled: true, installed: []) }
        #expect(guardian.leftovers().isEmpty, "our mods aren't in the game folder, so there is nothing to find")

        // Mods off, but someone set the game up by hand before: Mod Engine 2 in `Game/`, the toggler's proxy, Seamless
        // Co-op, Elden Mod Loader's `mods/`, the `steam_appid.txt` trick. Each is found, in the profile's order.
        try Self.layout(["Game/dinput8.dll": "elden mod loader", "Game/winhttp.dll": "toggler dummy", "Game/SeamlessCoop/ersc.dll": "coop", "Game/SeamlessCoop/ersc_settings.ini": "[GAMEPLAY]",
                         "Game/steam_appid.txt": "1245620", "Game/modengine2_launcher.exe": "MZ", "Game/mods/erfps.dll": "MZ", "Game/mods/erfps.ini": "[fps]"], in: bench.game)
        let found = ["game:Game/dinput8.dll", "game:Game/winhttp.dll", "game:Game/SeamlessCoop/", "game:Game/steam_appid.txt", "game:Game/modengine2_launcher.exe", "game:Game/mods/"]
        #expect(try guardian.decide(modsEnabled: false, installed: ["me3"]) == .plain(leftovers: found))
        #expect(guardian.leftovers(deployer: bench.deployer) == found)
        let fix = FixAction.removeModLeftovers(found)
        #expect(!fix.isUndoable && fix.summary == "Remove leftover mod files")

        // Set aside, never deleted: the game folder is the vanilla one again, the strangers' files wait in the store.
        let moved = try LaunchGuard.removeLeftovers(found, roots: bench.deployer.roots, store: bench.store, deployer: bench.deployer, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(moved == found && snapshot(bench.game) == vanilla && bench.exists("Game/start_protected_game.exe") && bench.exists("Game/eldenring.exe"))
        #expect(try guardian.decide(modsEnabled: false, installed: ["me3"]) == .plain(leftovers: []))
        let bin = bench.store.folder.appendingPathComponent(".leftovers")
        let stamps = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        #expect(stamps.count == 1)
        let kept = bin.appendingPathComponent(stamps[0]).appendingPathComponent("game/Game")
        #expect(try String(contentsOf: kept.appendingPathComponent("SeamlessCoop/ersc.dll"), encoding: .utf8) == "coop")
        #expect(try String(contentsOf: kept.appendingPathComponent("mods/erfps.ini"), encoding: .utf8) == "[fps]")
        #expect(bench.stored("Clevers Moveset/regulation.bin") == "clever params" && installer.installed() == ["me3"], "the mod and the loader stay, for the next modded launch")
    }

    // MARK: Saves

    @Test func moddedSaveFileIsInTheBackupSet() throws {
        let bench = try Bench(try profile())
        let guardian = LaunchGuard(profile: bench.profile, roots: bench.deployer.roots)
        let modded = try #require(guardian.separateSaveFile)
        // The game's save folder in the bottle: the vanilla save, its backup, me3's copy for modded play, the graphics settings.
        let saves = "AppData/Roaming/EldenRing/76561198000000001/"
        try Self.layout([saves + "ER0000.sl2": "vanilla progress", saves + "ER0000.sl2.bak": "vanilla progress (older)", saves + modded: "modded progress",
                         "AppData/Roaming/EldenRing/GraphicsConfig.xml": "<Config/>"], in: bench.windowsHome)
        let backups = SaveBackupStore(destination: bench.root.appendingPathComponent("Backups", isDirectory: true))
        try FileManager.default.createDirectory(at: backups.destination, withIntermediateDirectories: true)

        // The backup the app takes before the first mod, from the profile's save folder: the modded file is in it like the others.
        let made = try backups.create(gameID: "steam:1245620", title: "ELDEN RING", sources: bench.profile.saves, roots: bench.saveRoots, kind: .automatic, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(made.sources == [SaveSource(root: .roaming, path: "EldenRing")] && made.files == 4 && made.kind == .automatic)
        let copy = made.folder.appendingPathComponent("data/0/76561198000000001/" + modded)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "modded progress")
        #expect(try String(contentsOf: made.folder.appendingPathComponent("data/0/76561198000000001/ER0000.sl2"), encoding: .utf8) == "vanilla progress")
        #expect(backups.list(gameID: "steam:1245620", title: "ELDEN RING").map(\.id) == [made.id])

        // Restore Saves brings the modded file back with the vanilla one, and the vanilla one is never overwritten by it.
        let folder = try #require(bench.saveRoots.resolve(bench.profile.saves[0]))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("76561198000000001/" + modded))
        try Data("newer vanilla progress".utf8).write(to: folder.appendingPathComponent("76561198000000001/ER0000.sl2"))
        let restored = try backups.restore(made, roots: bench.saveRoots, now: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(restored.files == 4 && restored.safetyBackup?.kind == .beforeRestore)
        #expect(try String(contentsOf: folder.appendingPathComponent("76561198000000001/" + modded), encoding: .utf8) == "modded progress")
        #expect(try String(contentsOf: folder.appendingPathComponent("76561198000000001/ER0000.sl2"), encoding: .utf8) == "vanilla progress")
        #expect(try String(contentsOf: try #require(restored.safetyBackup).folder.appendingPathComponent("data/0/76561198000000001/ER0000.sl2"), encoding: .utf8) == "newer vanilla progress",
                "what was there before the restore is kept too")
    }

    // MARK: After a failed launch

    @Test func crashDumpsPointAtTheNewestModAndThePatchChangesTheStamp() throws {
        let elden = try profile()
        let bench = try Bench(elden)
        let package = try #require(elden.kind("package")), native = try #require(elden.kind("native"))
        let clevers = mod("Clever's Moveset", key: "clevers-moveset", kind: package, unit: "Clevers Moveset", files: [("regulation.bin", "store:Clevers Moveset/regulation.bin")], added: 100)
        let merchant = mod("Glorious Merchant", key: "glorious-merchant", kind: native, unit: "ermerchant", files: [("ermerchant.dll", "store:ermerchant/ermerchant.dll")], added: 200)
        let state = ModDiagnostics.State(mods: [clevers, merchant], installedFrameworks: ["me3"])
        let diagnostics = ModDiagnostics(profile: elden, roots: bench.deployer.roots)
        #expect(diagnostics.collect(state).matches.isEmpty && diagnostics.collect(state).tail == nil)

        // me3's log for our profile is read for the report, scrubbed of mod names; it names no rule yet.
        let log = "2026-11-01T10:00:00Z  INFO me3_launcher: launching eldenring.exe\n2026-11-01T10:00:01Z ERROR me3_mod_host: failed to load native ermerchant/ermerchant.dll\n"
        try Self.layout(["AppData/Local/garyttierney/me3/data/logs/sommelier/2026-11-01_10-00-00.log": log], in: bench.windowsHome)
        let logged = diagnostics.collect(state)
        #expect(logged.matches.isEmpty && logged.tail?.contains("failed to load native") == true && logged.tail?.contains("ermerchant") == false)

        // A crash dump from this launch: the newest mod is the suspect; an old dump isn't.
        try Self.layout(["Game/crashdumps/eldenring.exe.1234.dmp": "MDMP"], in: bench.game)
        let crashed = diagnostics.collect(state)
        #expect(crashed.matches.map(\.rule.action) == [.disableMod("glorious-merchant")] && crashed.matches.first?.rule.id == ModDiagnostics.newestModRule)
        #expect(diagnostics.collect(state, since: Date().addingTimeInterval(60)).matches.isEmpty)

        // The game's version stamp: a patch changes it, which is when a regulation.bin or a DLL stops matching the game.
        let roots = bench.deployer.roots
        let first = try #require(ModGameVersion.stamp(profile: elden, roots: roots))
        #expect(!ModGameVersion.changed(since: first, profile: elden, roots: roots))
        try Self.layout(["Game/eldenring.exe": "MZ\0\u{90}game 1.16.1"], in: bench.game)
        #expect(ModGameVersion.changed(since: first, profile: elden, roots: roots))
        var modState = ModState()
        modState.gameVersion = first
        #expect(try JSONDecoder().decode(ModState.self, from: try JSONEncoder().encode(modState)).gameVersion == first)
    }
}
