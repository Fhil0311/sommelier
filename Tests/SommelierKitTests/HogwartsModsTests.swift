// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The Hogwarts Legacy profile against the archive layouts its mods really come in, the loader's two release
/// layouts, the `~mods` prefix folders going up and back, the official Play Mods folder nobody touches, and the
/// loader's log after a game update.
struct HogwartsModsTests {
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

    /// A game folder laid out like the Steam install, the bottle's user folders, a store and the deployer, all
    /// in temporary folders.
    private struct Bench {
        let root: URL, game: URL, appdata: URL, documents: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile
        var launch = LaunchProfile()

        init(_ profile: ModProfile) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-hogwarts-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("Hogwarts Legacy", isDirectory: true)
            appdata = root.appendingPathComponent("users/steamuser/AppData/Local", isDirectory: true)
            documents = root.appendingPathComponent("users/steamuser/Documents", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/steam:990080", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: support,
                                 appdata: appdata, roaming: root.appendingPathComponent("users/steamuser/AppData/Roaming", isDirectory: true), documents: documents)
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
            try HogwartsModsTests.layout(["HogwartsLegacy.exe": "MZ wrapper", "Phoenix/Binaries/Win64/HogwartsLegacy.exe": "MZ game",
                                          "Phoenix/Content/Paks/pakchunk0-WindowsNoEditor.pak": "game pak",
                                          "Phoenix/Content/Data/Version/DA_Version.txt": "1.1.2.0"], in: game)
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
        func folders(_ relative: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url(relative).path)) ?? []).sorted() }

        /// A mod in the store, made from a layout planned against the profile.
        func stored(_ name: String, _ files: [String: String], answers: ModArchive.Answers = .init()) throws -> StoredMod {
            let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
            try HogwartsModsTests.layout(files, in: unpacked)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name, answers: answers)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }

        /// A zip of the layout, made with `tar`, as `name` in a scratch folder of the bench.
        func archive(_ name: String, _ files: [String: String]) async throws -> URL {
            let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
            try HogwartsModsTests.layout(files, in: source)
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

    /// The fixture's Hogwarts entry, with the loader's hash pointed at a stub archive when a test installs it.
    private func profile(ue4ssHash: String? = nil) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var games = try #require(json["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["game"] as? String == "steam:990080" })
        if let ue4ssHash {
            var frameworks = try #require(games[index]["frameworks"] as? [[String: Any]])
            for i in frameworks.indices where frameworks[i]["id"] as? String == "ue4ss" {
                var download = try #require(frameworks[i]["download"] as? [String: Any])
                download["sha256"] = ue4ssHash
                frameworks[i]["download"] = download
            }
            games[index]["frameworks"] = frameworks
        }
        json["games"] = games
        let list = try JSONDecoder().decode(ModsList.self, from: try JSONSerialization.data(withJSONObject: json))
        return try #require(list.profile(covering: "steam:990080"))
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

    private func triple(_ name: String, in folder: String = "") -> [String: String] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        return ["\(prefix)\(name).pak": "pak \(name)", "\(prefix)\(name).ucas": "ucas \(name)", "\(prefix)\(name).utoc": "utoc \(name)"]
    }

    private func destinations(_ plan: ModPlan) -> [String] { plan.units.flatMap { $0.files.map(\.destination) }.sorted() }

    /// The release zip of UE4SS 3.0.x: everything next to `dwmapi.dll`.
    private let ue4ssFlat = ["dwmapi.dll": "proxy", "UE4SS.dll": "ue4ss", "README.md": "read me", "Mods/mods.txt": "BPModLoaderMod : 1\nKeybinds : 1\n",
                             "Mods/BPModLoaderMod/Scripts/main.lua": "bp loader", "Mods/shared/Types.lua": "types",
                             "UE4SS-settings.ini": "[Overrides]\nModsFolderPath =\n\n[EngineVersionOverride]\nMajorVersion = -1\nMinorVersion = -1\n\n[Debug]\nConsoleEnabled = 1\nGuiConsoleEnabled = 1\n"]

    /// The experimental zip: only the proxy at the top, the rest in `ue4ss/`.
    private var ue4ssNested: [String: String] {
        Dictionary(uniqueKeysWithValues: ue4ssFlat.map { ($0.key == "dwmapi.dll" || $0.key == "README.md" ? $0.key : "ue4ss/" + $0.key, $0.value) })
    }

    // MARK: The profile

    @Test func profileNeverTouchesTheEngine() throws {
        let hogwarts = try profile()
        #expect(hogwarts.status == .ready && hogwarts.runtime == .wine && hogwarts.sources.nexus?.domain == "hogwartslegacy")
        #expect(hogwarts.kinds.map(\.id) == ["logic", "pak", "lua", "asi", "movie", "ini"], "LogicMods before ~mods: a `_P` triple in LogicMods is a Blueprint mod")
        #expect(hogwarts.loadOrder.format == .prefixFolder && hogwarts.loadOrder.reverse && hogwarts.loadOrder.isReorderable)
        // Denuvo counts a changed environment as a new machine: mods change nothing about Wine or the launch path.
        #expect(hogwarts.online.policy == .allowed && hogwarts.online.moddedLaunch == .same && hogwarts.online.antiCheat == nil)
        #expect(hogwarts.frameworks.allSatisfy { $0.components.isEmpty && $0.launch == nil })
        let ue4ss = try #require(hogwarts.framework("ue4ss"))
        #expect(ue4ss.dllOverrides == ["dwmapi": "n,b"] && ue4ss.disableArgument == "--disable-ue4ss" && ue4ss.code && !ue4ss.optional)
        #expect(ue4ss.remove.contains("game:Phoenix/Binaries/Win64/xinput1_3.dll"), "the old proxy crashes the game next to the new one")
        let asi = try #require(hogwarts.framework("asiloader"))
        #expect(asi.optional && asi.dllOverrides == ["version": "n,b"] && asi.pick.first?.to == "game:Phoenix/Binaries/Win64/version.dll")
        let guardian = LaunchGuard(profile: hogwarts, roots: ModRoots(game: nil, store: URL(fileURLWithPath: "/tmp/s"), tools: URL(fileURLWithPath: "/tmp/t"), home: URL(fileURLWithPath: "/tmp/h")))
        #expect(guardian.allowsPlainLaunch(modsEnabled: true))
        #expect(try guardian.decide(modsEnabled: true, installed: ["ue4ss"]) == .plain(leftovers: []))
        #expect(hogwarts.notes.untouched == ["documents:Hogwarts Legacy/Mods/**"] && hogwarts.notes.gameVersionFile == "game:Phoenix/Content/Data/Version/DA_Version.txt")
        #expect(hogwarts.notes.cleanupOnLastCodeMod)
        #expect(hogwarts.conflicts.rules.map(\.reason) == ["pakchunk"] && hogwarts.conflicts.rules.first?.sameStem == true)
        #expect(hogwarts.saves.map(\.path) == ["Hogwarts Legacy/Saved/SaveGames", "Hogwarts Legacy/Saved/Config/WindowsNoEditor"])
    }

    // MARK: Archives

    @Test func pakArchivesFromNexus() throws {
        let hogwarts = try profile()
        // The usual case: the triple at the archive's root, into a slot folder of `~mods`.
        let root = ModArchive.plan(paths: ["zBPApparate_P.pak", "zBPApparate_P.ucas", "zBPApparate_P.utoc"], profile: hogwarts, archiveName: "Blueprint Apparate Modloader-56-2-0")
        #expect(root.isReady && root.units.map(\.name) == ["zBPApparate_P"] && root.units.first?.kind.id == "pak" && !root.containsCode && root.frameworks.isEmpty)
        #expect(destinations(root) == ["game:Phoenix/Content/Paks/~mods/{slot}/zBPApparate_P.pak", "game:Phoenix/Content/Paks/~mods/{slot}/zBPApparate_P.ucas",
                                       "game:Phoenix/Content/Paks/~mods/{slot}/zBPApparate_P.utoc"])
        // Packed the way the author's instructions read, `~mods/` included: the folder is a wrapper, the slot is still ours.
        let wrapped = ModArchive.plan(paths: ["~mods/ShrekBroom_P.pak", "~mods/ShrekBroom_P.ucas", "~mods/ShrekBroom_P.utoc"], profile: hogwarts)
        #expect(wrapped.notes == [.wrapperRemoved("~mods")] && destinations(wrapped).first == "game:Phoenix/Content/Paks/~mods/{slot}/ShrekBroom_P.pak")

        // A 2023 mod: one `.pak`, no `.ucas`/`.utoc`. The game reads IO Store paks only since the 2025 update.
        let old = ModArchive.plan(paths: ["ElderWand_P.pak", "readme.txt"], profile: hogwarts)
        #expect(old.refusal == .init(reason: .incompleteTriple, path: "ElderWand_P.pak") && old.units.isEmpty)
        #expect(ModArchive.plan(paths: ["DotReticle_P.pak", "DotReticle_P.utoc"], profile: hogwarts).refusal?.reason == .incompleteTriple)

        // The Apparate loader and a UI mod that runs on it, in one archive: two pak mods, no code, no loader needed.
        let paths = Array(triple("zBPApparate_P", in: "Blueprint Apparate Modloader").keys) + Array(triple("DekUICore_P", in: "DekUICore").keys) + ["How to install.txt"]
        let pair = ModArchive.plan(paths: paths, profile: hogwarts)
        #expect(pair.isReady && pair.units.map(\.name) == ["zBPApparate_P", "DekUICore_P"] && pair.units.allSatisfy { $0.kind.id == "pak" && !$0.code })
        #expect(pair.units.map(\.root) == ["Blueprint Apparate Modloader", "DekUICore"] && pair.leftovers == ["How to install.txt"] && pair.frameworks.isEmpty)
        #expect(pair.units.allSatisfy { unit in unit.files.allSatisfy { $0.destination.hasPrefix("game:Phoenix/Content/Paks/~mods/{slot}/") } })

        // A Blueprint mod for UE4SS sits in `LogicMods`, `_P` or not, and needs the loader; a pak mod next to it doesn't.
        let logic = ModArchive.plan(paths: Array(triple("NPCSchedules_P", in: "LogicMods").keys) + Array(triple("zNPCAssets_P", in: "~mods").keys), profile: hogwarts)
        #expect(logic.units.map(\.kind.id) == ["logic", "pak"] && logic.units.map(\.name) == ["NPCSchedules_P", "zNPCAssets_P"])
        #expect(logic.units[0].files.map(\.destination) == ["game:Phoenix/Content/Paks/LogicMods/NPCSchedules_P.pak", "game:Phoenix/Content/Paks/LogicMods/NPCSchedules_P.ucas",
                                                             "game:Phoenix/Content/Paks/LogicMods/NPCSchedules_P.utoc"])
        #expect(logic.frameworks == ["ue4ss"] && !logic.containsCode && logic.units[0].framework == "ue4ss" && logic.units[1].framework == nil)
    }

    @Test func codeArchivesLuaAsiAndLoaders() throws {
        let hogwarts = try profile()
        // A Lua mod with its `enabled.txt`: the folder goes to `Mods/<Name>/`, the readme stays, the line in `mods.txt` is the switch.
        let lua = ModArchive.plan(paths: ["GamePauser/Scripts/main.lua", "GamePauser/enabled.txt", "GamePauser/README.md"], profile: hogwarts)
        let pauser = try #require(lua.units.first)
        #expect(lua.isReady && lua.units.count == 1 && pauser.kind.id == "lua" && pauser.name == "GamePauser" && pauser.code && pauser.framework == "ue4ss")
        #expect(pauser.files.map(\.destination) == ["game:Phoenix/Binaries/Win64/Mods/GamePauser/Scripts/main.lua", "game:Phoenix/Binaries/Win64/Mods/GamePauser/enabled.txt"])
        #expect(pauser.kind.enable == .init(format: .ue4ssModsTxt, file: "game:Phoenix/Binaries/Win64/Mods/mods.txt") && pauser.kind.order == .orderFile)
        #expect(lua.containsCode && lua.frameworks == ["ue4ss"] && lua.leftovers.isEmpty)
        // Packed as `Mods/<Name>/…` or `ue4ss/Mods/<Name>/…` by a careful author: the mod's folder is still the unit.
        let packed = ModArchive.plan(paths: ["ue4ss/Mods/FirstPerson/Scripts/main.lua", "ue4ss/Mods/FirstPerson/Scripts/camera.lua"], profile: hogwarts)
        #expect(packed.units.map(\.name) == ["FirstPerson"] && packed.units.first?.files.map(\.destination) == ["game:Phoenix/Binaries/Win64/Mods/FirstPerson/Scripts/camera.lua", "game:Phoenix/Binaries/Win64/Mods/FirstPerson/Scripts/main.lua"])

        // Lyall's fix: the ASI loader copy is denied (the framework places its own as `version.dll`), the .asi and its ini go next to the game's exe.
        let fix = ModArchive.plan(paths: ["version.dll", "HogwartsLegacyFix.asi", "HogwartsLegacyFix.ini", "README.md", "LICENSE"], profile: hogwarts, archiveName: "HogwartsLegacyFix_v0.9.3")
        let asi = try #require(fix.units.first)
        #expect(fix.isReady && fix.notes == [.denied("version.dll")] && fix.units.count == 1)
        #expect(asi.kind.id == "asi" && asi.name == "HogwartsLegacyFix" && asi.code && asi.framework == "asiloader")
        #expect(asi.files.map(\.destination) == ["game:Phoenix/Binaries/Win64/HogwartsLegacyFix.asi", "game:Phoenix/Binaries/Win64/HogwartsLegacyFix.ini"])
        #expect(fix.leftovers == ["LICENSE"] && fix.frameworks == ["asiloader"])

        // ReShade presets: the DLL is denied and the shaders are refused by name; the player sets ReShade up by hand.
        let reshade = ModArchive.plan(paths: ["dxgi.dll", "ReShade.ini", "Realism Overhaul.ini", "reshade-shaders/Shaders/Cinematic.fx", "reshade-shaders/Textures/lut.png"], profile: hogwarts)
        #expect(reshade.refusal == .init(reason: .rejected("reshade"), path: "ReShade.ini") && reshade.notes == [.denied("dxgi.dll")] && reshade.units.isEmpty)
        #expect(ModArchive.plan(paths: ["d3d12.dll", "reshade-shaders/Shaders/Cinematic.fx"], profile: hogwarts).refusal?.reason == .rejected("reshade"))

        // The loader itself, dropped in as a mod (it is on Nexus too): refused, Sommelier installs it when a mod needs it.
        let loader = ModArchive.plan(paths: Array(ue4ssFlat.keys), profile: hogwarts, archiveName: "UE4SS_v3.0.1")
        #expect(loader.refusal == .init(reason: .rejected("loader"), path: "UE4SS.dll") && loader.notes.contains(.denied("dwmapi.dll")))
        #expect(ModArchive.plan(paths: Array(ue4ssNested.keys), profile: hogwarts).refusal?.reason == .rejected("loader"))
        // The Mod Merger is a program; a save file isn't a mod.
        #expect(ModArchive.plan(paths: ["HogwartsModMerger.exe", "readme.txt"], profile: hogwarts).refusal?.reason == .rejected("executable"))
        #expect(ModArchive.plan(paths: ["SaveGames/76561198000000000/HL-00-00.sav"], profile: hogwarts).refusal?.reason == .rejected("saveFile"))
    }

    @Test func iniAsksAndMoviesBackUpTheOriginal() throws {
        let hogwarts = try profile()
        // Ascendio: an `Engine.ini` on its own may be a settings mod or just someone's config, so the player is asked.
        let ascendio = ["Engine.ini", "Ascendio Guide.txt"]
        let asked = ModArchive.plan(paths: ascendio, profile: hogwarts)
        #expect(asked.questions == [.kind(id: "ini", files: ["Engine.ini"])] && asked.units.isEmpty && asked.refusal == nil && !asked.isReady)
        let yes = ModArchive.plan(paths: ascendio, profile: hogwarts, answers: .init(kinds: ["ini": true]))
        let ini = try #require(yes.units.first)
        #expect(yes.isReady && ini.kind.id == "ini" && !ini.code && ini.framework == nil && ini.kind.order == .none)
        #expect(ini.files.map(\.destination) == ["appdata:Hogwarts Legacy/Saved/Config/WindowsNoEditor/Engine.ini"] && ini.kind.backupOriginal, "the player's own Engine.ini comes back with the uninstall")
        #expect(yes.leftovers == ["Ascendio Guide.txt"])
        #expect(ModArchive.plan(paths: ascendio, profile: hogwarts, answers: .init(kinds: ["ini": false])).refusal?.reason == .nothingRecognised)

        // A movie replacement lands on the game's own file: planned as an overwrite, kept in the store, restored.
        let bench = try Bench(hogwarts)
        try Self.layout(["Phoenix/Content/Movies/Intro/WB_Logo.bk2": "original logo", "Phoenix/Content/Movies/Intro/Avalanche.bk2": "avalanche"], in: bench.game)
        let before = snapshot(bench.game)
        let movie = try bench.stored("Skip Intro", ["Phoenix/Content/Movies/Intro/WB_Logo.bk2": "blank"])
        #expect(movie.units.first?.kind.id == "movie" && movie.units.first?.kind.backupOriginal == true && !movie.containsCode)
        let outcome = try bench.deployer.deploy(movie)
        #expect(outcome.placed == ["game:Phoenix/Content/Movies/Intro/WB_Logo.bk2"] && outcome.overwroteForeign.isEmpty)
        #expect(bench.text("Phoenix/Content/Movies/Intro/WB_Logo.bk2") == "blank" && bench.text("Phoenix/Content/Movies/Intro/Avalanche.bk2") == "avalanche")
        #expect(try String(contentsOf: bench.store.originals.appendingPathComponent("game/Phoenix/Content/Movies/Intro/WB_Logo.bk2"), encoding: .utf8) == "original logo")
        let removal = try bench.deployer.remove(owner: movie.key)
        #expect(removal.restored == ["game:Phoenix/Content/Movies/Intro/WB_Logo.bk2"] && snapshot(bench.game) == before)

        // The same for the Engine.ini in the bottle: the game's own is kept and comes back.
        try Self.layout(["Hogwarts Legacy/Saved/Config/WindowsNoEditor/Engine.ini": "[Core]\nmine=1\n"], in: bench.appdata)
        let tweak = try bench.stored("Ascendio", ["Engine.ini": "[SystemSettings]\nr.Streaming.PoolSize=3000\n"], answers: .init(kinds: ["ini": true]))
        #expect(try bench.deployer.deploy(tweak).overwroteForeign.isEmpty)
        #expect(try String(contentsOf: bench.appdata.appendingPathComponent("Hogwarts Legacy/Saved/Config/WindowsNoEditor/Engine.ini"), encoding: .utf8).contains("PoolSize"))
        try bench.deployer.remove(owner: tweak.key)
        #expect(try String(contentsOf: bench.appdata.appendingPathComponent("Hogwarts Legacy/Saved/Config/WindowsNoEditor/Engine.ini"), encoding: .utf8) == "[Core]\nmine=1\n")
    }

    // MARK: The loader

    @Test func ue4ssInstallsFlatFromEitherReleaseLayout() async throws {
        for (label, files) in [("flat", ue4ssFlat), ("ue4ss/", ue4ssNested)] {
            let note = Comment(rawValue: label)
            var bench = try Bench(try profile())
            try Self.layout(["Phoenix/Binaries/Win64/xinput1_3.dll": "stale 2.5 proxy"], in: bench.game)
            let zip = try await bench.archive("UE4SS_v3.0.1.zip", files)
            let hash = try #require(ModStore.sha256(of: zip))
            let profile = try profile(ue4ssHash: hash)
            let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["UE4SS_v3.0.1.zip": zip]))
            let installation = try await installer.install("ue4ss", launchProfile: &bench.launch)

            #expect(installation.placed.sorted() == ["game:Phoenix/Binaries/Win64/Mods/BPModLoaderMod/Scripts/main.lua", "game:Phoenix/Binaries/Win64/Mods/mods.txt",
                                                     "game:Phoenix/Binaries/Win64/Mods/shared/Types.lua", "game:Phoenix/Binaries/Win64/UE4SS-settings.ini",
                                                     "game:Phoenix/Binaries/Win64/UE4SS.dll", "game:Phoenix/Binaries/Win64/dwmapi.dll"], "\(label): everything flat next to the game's exe (issue #1189)")
            #expect(!bench.exists("Phoenix/Binaries/Win64/ue4ss") && !bench.exists("Phoenix/Binaries/Win64/README.md") && !bench.exists("Phoenix/Binaries/Win64/xinput1_3.dll"), note)
            #expect(bench.text("Phoenix/Binaries/Win64/dwmapi.dll") == "proxy" && bench.text("Phoenix/Binaries/Win64/UE4SS.dll") == "ue4ss", note)
            #expect(bench.text("Phoenix/Binaries/Win64/Mods/mods.txt") == "BPModLoaderMod : 1\nKeybinds : 1\n", "\(label): the Blueprint loader stays on for LogicMods")
            let ini = try #require(bench.text("Phoenix/Binaries/Win64/UE4SS-settings.ini"))
            #expect(ini.contains("[EngineVersionOverride]\nMajorVersion = 4\nMinorVersion = 27\n") && ini.contains("ConsoleEnabled = 0\nGuiConsoleEnabled = 0\n"), "\(label): the game doesn't say its engine version; no OpenGL console under Wine")
            #expect(bench.launch.dllOverrides == ["dwmapi": "n,b"] && bench.launch.extraArguments.isEmpty && bench.launch.redirect == nil, note)
            #expect(installation.components.isEmpty && installation.fixes.map(\.ruleID) == ["framework:ue4ss"], note)

            try installer.uninstall("ue4ss", fixes: installation.fixes, launchProfile: &bench.launch)
            #expect(bench.text("Phoenix/Binaries/Win64/xinput1_3.dll") == "stale 2.5 proxy" && !bench.exists("Phoenix/Binaries/Win64/dwmapi.dll") && bench.launch == LaunchProfile(), note)
        }
    }

    @Test func ue4ssLogAfterAGameUpdateTurnsTheLoaderOff() throws {
        let hogwarts = try profile()
        let bench = try Bench(hogwarts)
        let kind = try #require(hogwarts.kind("lua"))
        let pauser = StoredMod(key: "game-pauser", name: "Game Pauser", version: nil, author: nil, origin: .init(), archive: .init(name: "Game Pauser.zip"),
                               added: Date(timeIntervalSince1970: 0), enabled: true, codeAccepted: true,
                               units: [ModPlan.Unit(kind: kind, name: "GamePauser", root: "", code: true, framework: "ue4ss",
                                                    files: [.init(source: "Scripts/main.lua", destination: "game:Phoenix/Binaries/Win64/Mods/GamePauser/Scripts/main.lua", skipped: false)])],
                               leftovers: [])
        let state = ModDiagnostics.State(mods: [pauser], installedFrameworks: ["ue4ss"])
        let diagnostics = ModDiagnostics(profile: hogwarts, roots: bench.deployer.roots)
        #expect(diagnostics.collect(state).matches.isEmpty && diagnostics.collect(state).tail == nil, "no log, nothing to say")

        // The loader's signatures no longer match the patched game: the loader goes off, not the mod.
        let outdated = """
        [2026-11-01 10:00:00] [Info] UE4SS v3.0.1
        [2026-11-01 10:00:01] [Error] AOB scans could not be completed: Was unable to find address for 'StaticConstructObject_Internal'
        [2026-11-01 10:00:01] [Error] Fatal error: UE4SS could not be initialized
        """
        try Data(outdated.utf8).write(to: bench.url("Phoenix/Binaries/Win64/UE4SS.log"))
        let result = diagnostics.collect(state)
        #expect(result.matches.map(\.rule.action) == [.disableFramework("ue4ss")] && result.matches.first?.rule.id == ModDiagnostics.loaderOutdatedRule)
        #expect(result.unresolved.isEmpty && result.summary == nil)
        #expect(result.tail?.contains("AOB scans could not be completed") == true && result.tail?.contains("Game Pauser") == false)

        // The fix adds the loader's own switch, leaving the files in place; undoing it takes the argument back out.
        var launch = LaunchProfile()
        launch.dllOverrides["dwmapi"] = "n,b"
        let fix = ModDiagnostics.disable(try #require(hogwarts.framework("ue4ss")), in: &launch)
        #expect(launch.extraArguments == ["--disable-ue4ss"] && launch.dllOverrides == ["dwmapi": "n,b"], "the proxy stays, the loader is told not to start")
        #expect(fix.action == .disableFramework("ue4ss"))
        ModDiagnostics.restore(fix.undo, in: &launch)
        #expect(launch.extraArguments.isEmpty && launch.dllOverrides == ["dwmapi": "n,b"])

        // A hand-made `ue4ss/` layout writes its log there; the flat log wins when both exist.
        try FileManager.default.removeItem(at: bench.url("Phoenix/Binaries/Win64/UE4SS.log"))
        try Self.layout(["Phoenix/Binaries/Win64/ue4ss/UE4SS.log": "[2026-11-01 10:00:01] [Error] AOB scans could not be completed\n"], in: bench.game)
        #expect(diagnostics.collect(state).matches.map(\.rule.action) == [.disableFramework("ue4ss")])
        try Self.layout(["Phoenix/Binaries/Win64/UE4SS.log": "[2026-11-01 11:00:00] [Info] all fine\n"], in: bench.game)
        #expect(diagnostics.collect(state).matches.isEmpty)
    }

    // MARK: Order and the game's own folders

    @Test func threePakModsGetPrefixFoldersAndBack() throws {
        let bench = try Bench(try profile())
        let files = LoadOrderFiles(profile: bench.profile, deployer: bench.deployer)
        let apparate = try bench.stored("Apparate", triple("zBPApparate_P"))
        let dek = try bench.stored("DekUICore", triple("DekUICore_P"))
        let rackham = try bench.stored("Rackham Fix", triple("zzRackhamFix_P"))
        let mods = [apparate, dek, rackham]
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        #expect(order.keys == mods.map(\.key) && order.canReorder)

        // Top of the list wins, so it gets the highest number: Unreal mounts `~mods` alphabetically, later over earlier.
        let slots = LoadOrder.PrefixFolder.slots(for: order, mods: mods)
        #expect(slots == [apparate.key: "020_" + apparate.key, dek.key: "010_" + dek.key, rackham.key: "000_" + rackham.key])
        for mod in mods { try bench.deployer.deploy(mod, slot: slots[mod.key]) }
        #expect(bench.folders("Phoenix/Content/Paks/~mods") == ["000_" + rackham.key, "010_" + dek.key, "020_" + apparate.key])
        #expect(bench.text("Phoenix/Content/Paks/~mods/020_\(apparate.key)/zBPApparate_P.pak") == "pak zBPApparate_P", "the triple's own names are kept inside the slot")
        #expect(files.read(mods: mods).keys == mods.map(\.key))

        // The Rackham fix must load last: to the top, and the folders follow.
        let moved = try #require(order.moving(rackham.key, to: 0))
        try files.apply(moved, mods: mods)
        #expect(bench.folders("Phoenix/Content/Paks/~mods") == ["000_" + dek.key, "010_" + apparate.key, "020_" + rackham.key])
        #expect(bench.deployer.verify().isEmpty && files.read(mods: mods).keys == [rackham.key, apparate.key, dek.key])
        // And back: the original order gives the original folders, nothing left over in between.
        let back = try #require(moved.moving(rackham.key, to: 2))
        #expect(back.keys == mods.map(\.key))
        try files.apply(back, mods: mods)
        #expect(bench.folders("Phoenix/Content/Paks/~mods") == ["000_" + rackham.key, "010_" + dek.key, "020_" + apparate.key])
        #expect(bench.deployer.verify().isEmpty && files.read(mods: mods).keys == mods.map(\.key))
        #expect(bench.text("Phoenix/Content/Paks/~mods/000_\(rackham.key)/zzRackhamFix_P.utoc") == "utoc zzRackhamFix_P")

        // Two mods baked into the same pakchunk can't both work: a conflict the order doesn't settle.
        let chunkA = try bench.stored("Outfit A", triple("pakchunk1311-WindowsNoEditor_P"))
        let chunkB = try bench.stored("Outfit B", triple("pakchunk1311-WindowsNoEditor_P"))
        let all = mods + [chunkA, chunkB]
        let report = ModConflicts.check(all, profile: bench.profile, order: files.read(mods: all).keys)
        let chunk = try #require(report.findings.first { Set($0.mods) == [chunkA.key, chunkB.key] }, "\(report)")
        #expect(chunk.cause == .rule(reason: "pakchunk", hint: nil, matched: "pakchunk1311-windowsnoeditor_p") && chunk.severity == .warn)
        #expect(report.findings(for: apparate.key).isEmpty && !report.isBlocked(chunkA.key))
    }

    @Test func officialPlayModsFolderIsNeverTouched() async throws {
        var bench = try Bench(try profile())
        // The game's own mod system keeps its downloads in Documents; Sommelier never looks there.
        try Self.layout(["Hogwarts Legacy/Mods/87986/manifest.json": "{\"id\": 87986}", "Hogwarts Legacy/Mods/87986/content.pak": "curseforge",
                         "Hogwarts Legacy/Mods/87986/content.ucas": "c", "Hogwarts Legacy/Mods/87986/content.utoc": "u"], in: bench.documents)
        try Self.layout(["Hogwarts Legacy/Saved/SaveGames/76561198000000000/HL-00-00.sav": "save", "Hogwarts Legacy/Saved/Config/WindowsNoEditor/Engine.ini": "[Core]\n"], in: bench.appdata)
        try Self.layout(["Phoenix/Content/Movies/Intro/WB_Logo.bk2": "original logo", "Phoenix/Binaries/Win64/xinput1_3.dll": "stale"], in: bench.game)
        let official = bench.documents.appendingPathComponent("Hogwarts Legacy/Mods", isDirectory: true)
        let untouchedSpec = try #require(bench.profile.notes.untouched.first)
        let untouched = try #require(bench.deployer.roots.resolve(untouchedSpec))
        #expect(untouched.path.hasPrefix(official.path), "the profile's untouched path is the official folder")
        let documentsBefore = snapshot(bench.documents), gameBefore = snapshot(bench.game), appdataBefore = snapshot(bench.appdata)

        // One of each kind that the fixture's loader allows, the loader itself first.
        let zip = try await bench.archive("UE4SS_v3.0.1.zip", ue4ssFlat)
        let hash = try #require(ModStore.sha256(of: zip))
        let profile = try profile(ue4ssHash: hash)
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["UE4SS_v3.0.1.zip": zip]))
        let installation = try await installer.install("ue4ss", launchProfile: &bench.launch)
        let pak = try bench.stored("Apparate", triple("zBPApparate_P"))
        let logic = try bench.stored("Schedules", triple("NPCSchedules_P", in: "LogicMods"))
        let lua = try bench.stored("Game Pauser", ["GamePauser/Scripts/main.lua": "pause", "GamePauser/enabled.txt": ""])
        let movie = try bench.stored("Skip Intro", ["Movies/Intro/WB_Logo.bk2": "blank"])
        let tweak = try bench.stored("Ascendio", ["Engine.ini": "[SystemSettings]\n"], answers: .init(kinds: ["ini": true]))
        let mods = [pak, logic, lua, movie, tweak]
        for mod in mods { try bench.deployer.deploy(mod, slot: "000_" + mod.key) }
        try bench.deployer.setEnabled(lua, true)
        #expect(bench.exists("Phoenix/Content/Paks/~mods/000_\(pak.key)/zBPApparate_P.pak") && bench.exists("Phoenix/Content/Paks/LogicMods/NPCSchedules_P.utoc"))
        #expect(bench.exists("Phoenix/Binaries/Win64/Mods/GamePauser/Scripts/main.lua") && bench.text("Phoenix/Binaries/Win64/Mods/mods.txt")?.contains("GamePauser : 1") == true)
        #expect(bench.text("Phoenix/Content/Movies/Intro/WB_Logo.bk2") == "blank")
        #expect(snapshot(bench.documents) == documentsBefore, "placing mods leaves Documents alone")
        let placed = bench.deployer.owners().flatMap(bench.deployer.deployed)
        #expect(!placed.isEmpty && placed.allSatisfy { !$0.hasPrefix("documents:") }, "nothing of ours is recorded under Documents")
        #expect(bench.deployer.verify().isEmpty, "the edited mods.txt is still the loader's, not a game update")

        // Every mod out, then the loader (the last code mod is gone): the game, the bottle and Documents are as they were.
        for mod in mods { try bench.deployer.remove(owner: mod.key) }
        #expect(installer.unneeded(mods: []) == ["ue4ss"])
        try installer.uninstall("ue4ss", fixes: installation.fixes, launchProfile: &bench.launch)
        #expect(snapshot(bench.documents) == documentsBefore)
        #expect(snapshot(bench.game) == gameBefore, "the stale proxy back, the movie back, no ~mods or LogicMods left")
        #expect(snapshot(bench.appdata) == appdataBefore, "saves and the player's Engine.ini as before")
        #expect(bench.deployer.owners().isEmpty && bench.launch == LaunchProfile())
    }
}
