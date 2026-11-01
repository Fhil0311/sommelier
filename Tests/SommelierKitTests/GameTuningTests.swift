// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct GameTuningTests {
    let base = MacPower(appleSilicon: true, gpuCores: 10, ramGB: 16, displayPoints: (1728, 1117), displayPixels: (3456, 2234))

    @Test func levelsFollowTheMac() {
        #expect(base.level == .medium)
        #expect(MacPower(appleSilicon: true, gpuCores: 10, ramGB: 8, displayPoints: (1440, 900), displayPixels: (2880, 1800)).level == .low)
        #expect(MacPower(appleSilicon: true, gpuCores: 20, ramGB: 32, displayPoints: (1728, 1117), displayPixels: (3456, 2234)).level == .high)
        #expect(MacPower(appleSilicon: true, gpuCores: 40, ramGB: 64, displayPoints: (1728, 1117), displayPixels: (3456, 2234)).level == .ultra)
        #expect(MacPower(appleSilicon: false, gpuCores: 0, ramGB: 32, displayPoints: (1440, 900), displayPixels: (2880, 1800)).level == .low)
        #expect(base.level(demanding: true) == .low)
        #expect(base.resolution(for: .medium) == (1728, 1117) && base.resolution(for: .ultra) == (3456, 2234))
    }

    @Test func iniEditsKeepTheRest() {
        let text = "[Viewport]\r\nVSync=true\r\nResolution=\"3456x2234\"\r\n[Rendering]\r\nGrassDensity=4750\r\n"
        let out = IniFile.setting([("Viewport", "Resolution", "\"1728x1117\""), ("Rendering", "HairWorksLevel", "0"),
                                   ("Rendering/RT", "EnableRT", "false")], in: text)
        #expect(out.contains("VSync=true\r\n"))
        #expect(out.contains("Resolution=\"1728x1117\"\r\n"))
        #expect(out.contains("[Rendering]\r\nGrassDensity=4750\r\nHairWorksLevel=0\r\n"))
        #expect(out.contains("[Rendering/RT]\r\nEnableRT=false\r\n"))
        #expect(!out.contains("3456x2234"))
        #expect(IniFile.setting([("A", "k", "1")], in: nil) == "[A]\nk=1\n")
    }

    /// A game folder in a fake environment.
    func environment() throws -> (Paths, Bottle, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tuning-\(UUID().uuidString)")
        let paths = Paths(home: home)
        let bottle = Bottle(kind: .steam, paths: paths)
        let user = bottle.driveC.appendingPathComponent("users/crossover")
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        return (paths, bottle, user)
    }

    @Test func unrealGamesGetScalabilityGroups() throws {
        let (paths, bottle, user) = try environment()
        let gameFolder = paths.home.appendingPathComponent("Ready Or Not")
        for sub in ["ReadyOrNot/Binaries/Win64", "ReadyOrNot/Content/Paks"] {
            try FileManager.default.createDirectory(at: gameFolder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data().write(to: gameFolder.appendingPathComponent("ReadyOrNot/Binaries/Win64/ReadyOrNot-Win64-Shipping.exe"))
        let game = Game(store: .steam, storeID: "1144200", title: "Ready or Not", isInstalled: true, installPath: gameFolder)
        let tuning = try GameTuner(paths: paths).apply(game, bottle: bottle, level: .high, power: base)
        #expect(tuning.parts == ["unreal"])
        let ini = try String(contentsOf: user.appendingPathComponent("AppData/Local/ReadyOrNot/Saved/Config/Windows/GameUserSettings.ini"), encoding: .utf8)
        #expect(ini.contains("sg.ShadowQuality=2") && ini.contains("ResolutionSizeX=1728") && ini.contains("FullscreenMode=1"))

        // Not sure of the project's settings folder (exe named otherwise) and the game never ran: nothing is written yet.
        let other = paths.home.appendingPathComponent("Hogwarts Legacy")
        for sub in ["Phoenix/Binaries/Win64", "Phoenix/Content/Paks"] {
            try FileManager.default.createDirectory(at: other.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data().write(to: other.appendingPathComponent("Phoenix/Binaries/Win64/HogwartsLegacy.exe"))
        let hogwarts = Game(store: .steam, storeID: "990080", title: "Hogwarts Legacy", isInstalled: true, installPath: other)
        #expect(UnrealSettings().files(for: hogwarts, bottle: bottle).isEmpty)
    }

    @Test func unrealSettingsNextToTheGameAreFound() throws {
        let (paths, bottle, user) = try environment()
        let fm = FileManager.default
        let gameFolder = paths.home.appendingPathComponent("Deep Rock Galactic")
        for sub in ["FSD/Binaries/Win64", "FSD/Content/Paks"] {
            try fm.createDirectory(at: gameFolder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try Data().write(to: gameFolder.appendingPathComponent("FSD/Binaries/Win64/FSD-Win64-Shipping.exe"))
        let game = Game(store: .steam, storeID: "548430", title: "Deep Rock Galactic", isInstalled: true, installPath: gameFolder)
        let tuner = GameTuner(paths: paths)

        // Before the first run both places get the settings: the game reads one of them.
        let first = try tuner.apply(game, bottle: bottle, level: .high, power: base)
        #expect(first.files.count == 4)
        tuner.restore(first, for: game)

        // An older record wrote only to AppData; the game keeps its settings next to itself.
        let appData = user.appendingPathComponent("AppData/Local/FSD/Saved/Config/Windows/GameUserSettings.ini")
        try fm.createDirectory(at: appData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ScalabilityGroups]\nsg.ShadowQuality=2\n".write(to: appData, atomically: true, encoding: .utf8)
        var old = GameTuning(level: .high)
        old.parts = ["unreal"]
        old.files = [TunedFile(path: appData.path, backup: nil)]
        #expect(!tuner.isStale(old, for: game, bottle: bottle))
        let real = gameFolder.appendingPathComponent("FSD/Saved/Config/WindowsNoEditor/GameUserSettings.ini")
        try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ScalabilityGroups]\nsg.ShadowQuality=0\n".write(to: real, atomically: true, encoding: .utf8)
        #expect(tuner.isStale(old, for: game, bottle: bottle))
        #expect(UnrealSettings().files(for: game, bottle: bottle).contains { $0.resolvingSymlinksInPath() == real.resolvingSymlinksInPath() })
    }
}

struct TurboEnvironmentTests {
    @Test func unrealResolutionGoesIntoTheGamesOwnSettingsClass() {
        let power = MacPower(appleSilicon: true, gpuCores: 20, ramGB: 24, displayPoints: (1728, 1117), displayPixels: (3456, 2234))
        let file = URL(fileURLWithPath: "/x/GameUserSettings.ini")
        let expedition = """
        [ScalabilityGroups]
        sg.ShadowQuality=3

        [/Script/SandFall.ConfigurableGameUserSettings]
        SettingsData=(bEnableSubtitles=True,MenuUltrawideConstrain=(X=0,Y=0),ConsoleGraphicPreset=0)
        ResolutionSizeX=3456
        ResolutionSizeY=2234
        FullscreenMode=1

        [/Script/Engine.GameUserSettings]
        ResolutionSizeX=3456
        """
        let tuned = UnrealSettings().tuned(expedition, file: file, level: .high, power: power)!
        #expect(UnrealSettings.settingsSections(in: expedition) == ["/Script/SandFall.ConfigurableGameUserSettings", "/Script/Engine.GameUserSettings"])
        let sandfall = tuned.components(separatedBy: "[/Script/SandFall.ConfigurableGameUserSettings]")[1].components(separatedBy: "[/Script/Engine")[0]
        #expect(sandfall.contains("ResolutionSizeX=1728") && sandfall.contains("ResolutionSizeY=1117"))
        #expect(sandfall.contains("SettingsData=(bEnableSubtitles=True,MenuUltrawideConstrain=(X=0,Y=0),ConsoleGraphicPreset=0)"))   // the game's own: a recipe's business
        #expect(!tuned.contains("ResolutionSizeX=3456"))
        #expect(tuned.contains("sg.ShadowQuality=2"))
        #expect(UnrealSettings.settingsSections(in: "[ScalabilityGroups]\nsg.ShadowQuality=1\n") == ["/Script/Engine.GameUserSettings"])
        #expect(UnrealSettings.settingsSections(in: nil) == ["/Script/Engine.GameUserSettings"])
    }

    @Test func turboAsksDXMTForMetalFX() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: FileManager.default.temporaryDirectory))
        var profile = LaunchProfile()
        profile.backend = .dxmt
        #expect(WineRunner.environment(bottle: bottle, profile: profile)["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
        profile.turbo = true
        let env = WineRunner.environment(bottle: bottle, profile: profile)
        #expect(env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
        #expect(env["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=2")
        profile.extraEnvironment = ["DXMT_CONFIG": "d3d11.preferredMaxFrameRate=60"]
        #expect(WineRunner.environment(bottle: bottle, profile: profile)["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=2;d3d11.preferredMaxFrameRate=60")
        profile.backend = .d3dMetal                                   // DXMT only
        #expect(WineRunner.environment(bottle: bottle, profile: profile)["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == nil)
    }

    @Test func hdrOffReportsAnSDRDisplay() throws {
        let bottle = Bottle(kind: .steam, paths: Paths(home: FileManager.default.temporaryDirectory))
        var profile = LaunchProfile()
        profile.backend = .dxmt
        #expect(WineRunner.environment(bottle: bottle, profile: profile)["SOMMELIER_FORCE_SDR"] == nil)   // on by default
        profile.hdr = false
        profile.turbo = true
        let env = WineRunner.environment(bottle: bottle, profile: profile)
        #expect(env["DXMT_CONFIG"] == "d3d11.metalSpatialUpscaleFactor=2;dxgi.forceSDR=True")
        #expect(env["SOMMELIER_FORCE_SDR"] == "1")
        let saved = try JSONDecoder().decode(LaunchProfile.self, from: JSONEncoder().encode(profile))
        #expect(saved.hdr == false)
        #expect(try JSONDecoder().decode(LaunchProfile.self, from: Data("{}".utf8)).hdr)   // older profiles: on
    }
}

struct TuningWatchTests {
    @Test func thePlayersOwnChoiceTurnsTheTuningOff() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ini = dir.appendingPathComponent("GameUserSettings.ini")
        let old = "[ScalabilityGroups]\nsg.ShadowQuality=0\nsg.TextureQuality=0\n\n[/Script/Engine.GameUserSettings]\nResolutionSizeX=3456\nbUseVSync=False\n"
        let new = "[ScalabilityGroups]\nsg.ShadowQuality=2\nsg.TextureQuality=2\n\n[/Script/Engine.GameUserSettings]\nResolutionSizeX=1728\nbUseVSync=False\n"
        let watched = TuningWatch.changes(from: old, to: new, path: ini.path)
        #expect(Set(watched.map(\.key)) == ["sg.ShadowQuality", "sg.TextureQuality", "ResolutionSizeX"])     // vsync wasn't ours
        var tuning = GameTuning(level: .high)
        tuning.watched = watched

        // First session: the game rewrote the file (order, a key of its own) and kept our values.
        try "[/Script/Engine.GameUserSettings]\nbUseVSync=False\nResolutionSizeX=1728\nExtra=1\n\n[ScalabilityGroups]\nsg.TextureQuality=2\nsg.ShadowQuality=2\n"
            .write(to: ini, atomically: true, encoding: .utf8)
        guard case .settled(let values, let notKept) = TuningWatch.check(tuning) else { Issue.record("not settled"); return }
        #expect(!notKept)
        tuning.watched = values; tuning.settled = true
        #expect(TuningWatch.check(tuning) == .kept)

        // A later session: the player lowered the shadows in the game's menu.
        try "[ScalabilityGroups]\nsg.ShadowQuality=1\nsg.TextureQuality=2\n[/Script/Engine.GameUserSettings]\nResolutionSizeX=1728\n"
            .write(to: ini, atomically: true, encoding: .utf8)
        #expect(TuningWatch.check(tuning) == .changedByPlayer)

        // A game that applies its own settings at start: noted on the first session, then that's the baseline.
        var other = GameTuning(level: .high); other.watched = watched
        try old.write(to: ini, atomically: true, encoding: .utf8)
        guard case .settled(let kept, let lost) = TuningWatch.check(other) else { Issue.record("not settled"); return }
        #expect(lost && kept.first { $0.key == "sg.ShadowQuality" }?.value == "0")
        other.watched = kept; other.settled = true
        #expect(TuningWatch.check(other) == .kept)
    }

    @Test func recipeValuesFollowTheMac() {
        #expect(GameConfigEditor.value("${level:1200,1800,2400,3600}", level: .medium) == "1800")
        #expect(GameConfigEditor.value("${level:false,true}", level: .ultra) == "true")      // a short list repeats its last
        #expect(GameConfigEditor.value("a${level}b", level: .high) == "a2b")
        #expect(GameConfigEditor.value("\"${width}x${height}\"", level: .low, resolution: (1728, 1117)) == "\"1728x1117\"")
        #expect(FixAction.editConfig(file: "documents:G/user.settings", section: "Viewport", key: "Resolution", field: nil, value: "${width}").followsTuning)
        #expect(GameConfigFile("documents:Criterion Games/Need For Speed(TM) Most Wanted/config.NFS13Save") != nil)
        #expect(GameConfigFile("documents:G/user.settings") != nil)
        #expect(GameConfigFile("documents:G/game.exe") == nil && GameConfigFile("documents:G/data.pak") == nil)
    }

    @Test func watchedFieldsAndSaves() {
        let text = "[/Script/SandFall.ConfigurableGameUserSettings]\nSettingsData=(a=1,ConsoleGraphicPreset=2,b=(X=0))\n"
        #expect(IniFile.fieldValue(section: "/Script/SandFall.ConfigurableGameUserSettings", key: "SettingsData", field: "ConsoleGraphicPreset", in: text) == "2")
        #expect(IniFile.fieldValue(section: "/Script/SandFall.ConfigurableGameUserSettings", key: "SettingsData", field: "X", in: text) == "0")
        #expect(IniFile.value(section: "/script/sandfall.configurablegameusersettings", key: "settingsdata", in: text)?.hasPrefix("(a=1") == true)
        let action = FixAction.editSave(file: "appdata:G/*/S.sav", structName: "EngineSettingsData", values: ["ShadowQuality": "${level}", "Other": "3"])
        #expect(action.followsTuning)
        #expect(!FixAction.editSave(file: "appdata:G/*/S.sav", structName: "E", values: ["A": "1"]).followsTuning)
        let watched = GameConfigEditor.watched(action, files: ["/x/S.sav"], level: .medium)
        #expect(watched.map(\.key) == ["Other", "ShadowQuality"] && watched.map(\.value) == ["3", "1"] && watched.allSatisfy { $0.kind == .save })
    }
}
