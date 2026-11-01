// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct RecipesTests {
    static let list = #"""
    { "version": 1, "recipes": [
      { "game": "steam:1903340", "actions": [ { "switchGraphics": { "_0": "d3dMetal" } } ], "players": 4, "note": "Crashes in DXMT", "source": "reports" },
      { "game": "epic:Sage", "actions": [ { "turnOffTurbo": {} }, { "rebootTheMoon": {} } ] },
      { "game": "steam:49520", "actions": [ { "runExecutable": { "instead": "Launcher.exe", "run": "Borderlands2.exe" } },
                                            { "overrideDLL": { "_0": "ddraw", "_1": "n,b" } },
                                            { "setWindowsVersion": { "version": "win7", "exe": "Borderlands2.exe" } },
                                            { "addArguments": { "_0": ["-nosplash"] } } ], "source": "protonfixes" },
      { "game": "steam:2", "actions": [ { "rebootTheMoon": {} } ] }
    ] }
    """#

    @Test func readsTheListAndSkipsWhatItDoesntKnow() throws {
        let list = try JSONDecoder().decode(RecipesList.self, from: Data(Self.list.utf8))
        #expect(list.recipes.map(\.game) == ["steam:1903340", "epic:Sage", "steam:49520"])
        #expect(list.byGame["steam:1903340"]?.backend == .d3dMetal)
        #expect(list.byGame["steam:1903340"]?.players == 4)
        #expect(list.byGame["epic:Sage"]?.actions == [.turnOffTurbo])           // the unknown action dropped, the recipe kept
        #expect(list.byGame["epic:Sage"]?.backend == nil)
        #expect(list.byGame["steam:49520"]?.actions == [.runExecutable(instead: "Launcher.exe", run: "Borderlands2.exe"), .overrideDLL("ddraw", "n,b"),
                                                        .setWindowsVersion(version: "win7", exe: "Borderlands2.exe"), .addArguments(["-nosplash"])])
    }

    @Test func actionsRoundTripAsTheServerChecksThem() throws {
        let actions: [FixAction] = [.overrideDLL("dinput", ""), .runExecutable(instead: "a/Launcher.exe", run: "b/Game.exe"),
                                    .setWindowsVersion(version: "win10", exe: "Game.exe"), .addArguments(["-dx11", "-nosplash"])]
        let data = try JSONEncoder().encode(actions)
        #expect(try JSONDecoder().decode([FixAction].self, from: data) == actions)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"instead\"") && text.contains("\"version\"") && text.contains("\"_1\""))
        #expect(FixAction.setWindowsVersion(version: "win7", exe: "x.exe").summary == "Have the game see Windows 7")
    }

    @Test func componentsKnowTheirOverridesAndPackages() throws {
        #expect(Component.directx.overrides["d3dx9_43"] == "n,b")
        #expect(Component.directx.overrides["xactengine3_7"] == "n,b")
        #expect(Component.directx.overrides["d3dx10_33"] == nil)
        #expect(Component.d3dcompiler47.overrides == ["d3dcompiler_47": "n"])
        #expect(Component.physx.overrides.isEmpty && !Component.physx.isUndoable && Component.directx.isUndoable)
        #expect(ComponentInstaller.packages(for: .d3dcompiler47).count == 2)
        let data = try JSONEncoder().encode(FixAction.installComponent(.physx))
        #expect(String(decoding: data, as: UTF8.self) == #"{"installComponent":{"_0":"physx"}}"#)
        #expect(try JSONDecoder().decode(FixAction.self, from: data) == .installComponent(.physx))
        #expect((try? JSONDecoder().decode(FixAction.self, from: Data(#"{"installComponent":{"_0":"winetricks"}}"#.utf8))) == nil)
    }

    @Test func redirectsResolveNextToTheLauncher() {
        #expect(ExecutableRedirects.resolve(run: "Borderlands2.exe", nextTo: "Launcher.exe") == "Borderlands2.exe")
        #expect(ExecutableRedirects.resolve(run: "../bin/evilgenius_vulkan.exe", nextTo: "bin/eg2.exe") == "bin/evilgenius_vulkan.exe")
        #expect(ExecutableRedirects.resolve(run: "binaries\\Darktide.exe", nextTo: "launcher/Launcher.exe") == "launcher/binaries/Darktide.exe")
        let table = ExecutableRedirects.table(for: [("C:\\Games\\BL2", ExecutableRedirect(instead: "Launcher.exe", run: "Borderlands2.exe")),
                                                    ("C:\\Games\\EG2", ExecutableRedirect(instead: "bin/eg2.exe", run: "../bin/evilgenius_vulkan.exe"))])
        #expect(table == "C:\\Games\\BL2\tLauncher.exe\tBorderlands2.exe\nC:\\Games\\EG2\tbin\\eg2.exe\t..\\bin\\evilgenius_vulkan.exe\n")
    }

    @Test func keepsTheListOnDiskForADay() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("recipes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let service = RecipesService(paths: paths, baseURL: URL(string: "https://api.test")!)
        #expect(service.cached().isEmpty)
        try Data(Self.list.utf8).write(to: home.appendingPathComponent("Recipes.json"))
        #expect(service.cached().count == 3)
        #expect(await service.refresh().count == 3)                 // fresh on disk: not fetched
    }

    @Test func theReportSaysTheChoiceWasARecipe() {
        var profile = LaunchProfile(); profile.backend = .d3dMetal
        #expect(CompatibilityReport.Settings(profile: profile, applied: ["recipe"].map { AppliedFix(ruleID: $0, action: .installVCRuntime, undo: .none) }, shadersFromOthers: false).backendChoice == "recipe")
    }
}
