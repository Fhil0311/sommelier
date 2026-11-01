// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct GameConfigTests {
    @Test func fileSpecsStayInsideTheGamesFolders() {
        #expect(GameConfigFile("unreal:GameUserSettings.ini")?.root == .unreal)
        #expect(GameConfigFile("appdata:Sandfall/Saved/Config/Windows/GameUserSettings.ini")?.path == "Sandfall/Saved/Config/Windows/GameUserSettings.ini")
        #expect(GameConfigFile("game:Engine\\Config\\settings.cfg") != nil)
        #expect(GameConfigFile("game:../../windows/system32/x.ini") == nil)
        #expect(GameConfigFile("game:C:\\x.ini") == nil)
        #expect(GameConfigFile("game:/etc/passwd") == nil)
        #expect(GameConfigFile("game:game.exe") == nil)
        #expect(GameConfigFile("steam:x.ini") == nil)
        #expect(GameConfigFile("appdata:") == nil)
    }

    @Test func aFieldInsideAStructIsSet() {
        let text = """
        [ScalabilityGroups]
        sg.ShadowQuality=2

        [/Script/SandFall.ConfigurableGameUserSettings]
        SettingsData=(bEnableSubtitles=True,MenuUltrawideConstrain=(X=0,Y=0),ConsoleGraphicPreset=0)
        NotSharedSettingsData=(ApplicationScale=2.000000)
        """
        let edited = IniFile.settingField(section: "/Script/SandFall.ConfigurableGameUserSettings", key: "SettingsData", field: "ConsoleGraphicPreset", value: "2", in: text)
        #expect(edited?.contains("MenuUltrawideConstrain=(X=0,Y=0),ConsoleGraphicPreset=2)") == true)
        #expect(edited?.contains("ApplicationScale=2.000000") == true && edited?.contains("sg.ShadowQuality=2") == true)
        #expect(IniFile.settingField(section: "/Script/Other", key: "SettingsData", field: "ConsoleGraphicPreset", value: "2", in: text) == nil)
        #expect(IniFile.settingField(section: "/Script/SandFall.ConfigurableGameUserSettings", key: "SettingsData", field: "Missing", value: "2", in: text) == nil)
        #expect(GameConfigEditor.value("${level}", level: .high) == "2" && GameConfigEditor.value("50", level: .low) == "50")
    }

    @Test func editsAreBackedUpAndPutBack() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.createDirectories()
        let bottle = Bottle(kind: .steam, paths: paths)
        let user = bottle.driveC.appendingPathComponent("users/crossover")
        let ini = user.appendingPathComponent("AppData/Local/G/settings.ini")
        try FileManager.default.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[Video]\nQuality=0\n".write(to: ini, atomically: true, encoding: .utf8)
        let game = Game(store: .steam, storeID: "1", title: "G", isInstalled: true, installPath: home)
        let editor = GameConfigEditor(paths: paths)
        let files = try editor.edit(GameConfigFile("appdata:G/settings.ini")!, section: "Video", key: "Quality", field: nil, value: "3", game: game, bottle: bottle)
        #expect(files.count == 1 && files[0].backup != nil)
        #expect(try String(contentsOf: ini, encoding: .utf8) == "[Video]\nQuality=3\n")
        editor.restore(files, game: game)
        #expect(try String(contentsOf: ini, encoding: .utf8) == "[Video]\nQuality=0\n")
        #expect(!FileManager.default.fileExists(atPath: editor.backupFolder(for: game).path))
        // A file the game didn't have is made, and removed again on undo.
        let made = try editor.edit(GameConfigFile("documents:G/new.ini")!, section: "A", key: "b", field: nil, value: "1", game: game, bottle: bottle)
        #expect(made.count == 1 && made[0].backup == nil)
        editor.restore(made, game: game)
        #expect(!FileManager.default.fileExists(atPath: user.appendingPathComponent("Documents/G/new.ini").path))
    }

    @Test func theActionRoundTrips() throws {
        let action = FixAction.editConfig(file: "unreal:GameUserSettings.ini", section: "/Script/SandFall.ConfigurableGameUserSettings",
                                          key: "SettingsData", field: "ConsoleGraphicPreset", value: "${level}")
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(FixAction.self, from: data) == action)
        #expect(action.summary == "Game settings: ConsoleGraphicPreset = ${level}")
    }

    /// A save laid out as Expedition 33's `SharedGameUserSettings.sav` (Unreal 5.5 tags), made from parts.
    static func save(engineInts: [(String, Int32)] = [], extraHeader: Data = Data()) -> Data {
        let S = UnrealSave.string, I = UnrealSave.int32
        func str(_ name: String, _ value: String) -> Data { S(name) + S("StrProperty") + I(0) + I(Int32(value.utf8.count + 5)) + Data([0]) + S(value) }
        func float(_ name: String, _ value: Float) -> Data { S(name) + S("FloatProperty") + I(0) + I(4) + Data([0]) + withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) } }
        func bool(_ name: String, _ value: Bool) -> Data { S(name) + S("BoolProperty") + I(0) + I(0) + Data([value ? 16 : 0]) }
        func structTag(_ name: String, _ type: String, _ body: Data) -> Data {
            S(name) + S("StructProperty") + I(1) + S(type) + I(1) + S("/Script/SandFall") + I(0) + I(Int32(body.count)) + Data([0]) + body
        }
        let game = structTag("GameSettingsData", "SF_SettingsData", S("SubtitlesSize") + S("IntProperty") + I(0) + I(4) + Data([0]) + I(1)
                             + bool("bEnableHoldInputToSprint", false) + float("MasterVolume", 0.15) + UnrealSave.noneTag)
        var engineBody = str("GameCulture", "ru") + str("AudioGameCulture", "fr-FR")
        for (name, value) in engineInts { engineBody += UnrealSave.intTag(name: name, value: value) }
        engineBody += float("ResolutionScaleNormalized", 0.5) + UnrealSave.noneTag
        let engine = structTag("EngineSettingsData", "SF_EngineSettingsData", engineBody)
        return Data("GVAS".utf8) + extraHeader + Data(repeating: 0, count: 40) + S("/Script/SandFall.SharedGameUserSettings") + Data([0])
            + game + engine + UnrealSave.noneTag + I(0)
    }

    @Test func intsGoIntoAnUnrealSavesStruct() throws {
        let before = Self.save()
        #expect(UnrealSave.ints(before, inStruct: "EngineSettingsData") == [:])
        #expect(UnrealSave.ints(before, inStruct: "GameSettingsData") == ["SubtitlesSize": 1])
        let values: [String: Int32] = ["OverallScalabilityLevel": 2, "ShadowQuality": 2, "TextureQuality": 2]
        let after = try #require(UnrealSave.settingInts(before, inStruct: "EngineSettingsData", values: values))
        #expect(UnrealSave.ints(after, inStruct: "EngineSettingsData") == values)
        #expect(UnrealSave.ints(after, inStruct: "GameSettingsData") == ["SubtitlesSize": 1])          // untouched
        #expect(after.count == before.count + 3 * UnrealSave.intTag(name: "x", value: 0).count - 3 * 1 + ("OverallScalabilityLevel".count + "ShadowQuality".count + "TextureQuality".count))
        // A value already there is replaced in place; the same value changes nothing.
        let again = try #require(UnrealSave.settingInts(after, inStruct: "EngineSettingsData", values: ["ShadowQuality": 1]))
        #expect(again.count == after.count && UnrealSave.ints(again, inStruct: "EngineSettingsData")?["ShadowQuality"] == 1)
        #expect(UnrealSave.settingInts(again, inStruct: "EngineSettingsData", values: ["ShadowQuality": 1]) == again)
        // Not a save, no such struct, or a struct that doesn't read cleanly: nothing.
        #expect(UnrealSave.settingInts(Data("not a save".utf8), inStruct: "EngineSettingsData", values: values) == nil)
        #expect(UnrealSave.settingInts(before, inStruct: "Nowhere", values: values) == nil)
        var broken = before; broken[broken.count - 22 + 4] = 0xFF            // the struct's own "None" terminator
        #expect(UnrealSave.settingInts(broken, inStruct: "EngineSettingsData", values: values) == nil)
        // What the game writes itself, read back: the same layout.
        let theirs = Self.save(engineInts: [("OverallScalabilityLevel", 2), ("ViewDistanceQuality", 2)])
        #expect(UnrealSave.ints(theirs, inStruct: "EngineSettingsData") == ["OverallScalabilityLevel": 2, "ViewDistanceQuality": 2])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_SAVE_BEFORE"] != nil))
    func realSaveMatchesWhatTheGameWrote() throws {
        let env = ProcessInfo.processInfo.environment
        let before = try Data(contentsOf: URL(fileURLWithPath: env["SOMMELIER_SAVE_BEFORE"]!))
        let after = try Data(contentsOf: URL(fileURLWithPath: env["SOMMELIER_SAVE_AFTER"]!))
        let theirs = try #require(UnrealSave.ints(after, inStruct: "EngineSettingsData"))
        #expect(theirs.count == 11 && theirs.values.allSatisfy { $0 == 2 })
        let ours = try #require(UnrealSave.settingInts(before, inStruct: "EngineSettingsData", values: theirs))
        #expect(ours.count == after.count)
        #expect(UnrealSave.ints(ours, inStruct: "EngineSettingsData") == theirs)
        #expect(UnrealSave.ints(ours, inStruct: "GameSettingsData") == UnrealSave.ints(after, inStruct: "GameSettingsData"))
    }

    @Test func saveSpecsAllowOnePlayerFolderWildcard() {
        #expect(GameConfigFile("appdata:Sandfall/Saved/SaveGames/*/SharedGameUserSettings.sav", save: true) != nil)
        #expect(GameConfigFile("appdata:Sandfall/Saved/SaveGames/*/SharedGameUserSettings.sav") == nil)      // not for ini edits
        #expect(GameConfigFile("appdata:G/*/*/x.sav", save: true) == nil)
        #expect(GameConfigFile("appdata:G/x*/s.sav", save: true) == nil)
        #expect(GameConfigFile("appdata:G/s.ini", save: true) == nil)
        #expect(FixAction.listing(["OverallScalabilityLevel": "2", "ShadowQuality": "2"]) == "OverallScalabilityLevel +1 = 2")
        #expect(FixAction.listing(["A": "1", "B": "2"]) == "A +1" && FixAction.listing(["A": "1"]) == "A = 1")
    }
}

extension GameConfigTests {
    @Test func playStationPromptsGoInAndComeOut() throws {
        let section = "CommonInputPlatformSettings_Windows CommonInputPlatformSettings"
        let values = [(section: section, key: "DefaultGamepadName", value: "PS5"), (section: section, key: "bCanChangeGamepadType", value: "False")]
        let existing = "[/Script/Engine.GameSession]\r\nMaxPlayers=4\r\n"
        let with = IniFile.setting(values, in: existing)
        #expect(with.contains("[\(section)]\r\nDefaultGamepadName=PS5\r\nbCanChangeGamepadType=False"))
        #expect(IniFile.value(section: section, key: "DefaultGamepadName", in: with) == "PS5")
        // Taken out again: the section goes with its last key; the game's own section stays as it was.
        #expect(IniFile.removing(section: section, keys: ["DefaultGamepadName", "bCanChangeGamepadType"], from: with) == existing)
        // A file that held nothing else is left empty, so it can be removed.
        #expect(IniFile.removing(section: section, keys: ["DefaultGamepadName", "bCanChangeGamepadType"], from: IniFile.setting(values, in: nil)) == "")
        #expect(IniFile.removing(section: section, keys: ["DefaultGamepadName"], from: existing) == nil)
        // The recipe action reads and writes as the list online gives it.
        let json = #"{"playStationPrompts":{"file":"appdata:Sandfall/Saved/Config/Windows/Game.ini","section":"\#(section)","values":{"DefaultGamepadName":"PS5"}}}"#
        let action = try JSONDecoder().decode(FixAction.self, from: Data(json.utf8))
        #expect(action == .playStationPrompts(file: "appdata:Sandfall/Saved/Config/Windows/Game.ini", section: section, values: ["DefaultGamepadName": "PS5"]))
        #expect(action.summary == "Game settings: PlayStation button prompts")
        #expect(!action.followsTuning)
    }
}
