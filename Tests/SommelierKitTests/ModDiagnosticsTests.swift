// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The logs a game's mods profile names, read after a failed launch: which mod or loader each sample blames,
/// what SMAPI's summary says, how a loader goes off and comes back, and that a report carries a flag about
/// mods but never their names.
struct ModDiagnosticsTests {
    private struct Bench {
        let root: URL, game: URL, home: URL, store: ModStore, roots: ModRoots

        init() {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-moddiag-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("Game", isDirectory: true)
            home = root.appendingPathComponent("Home", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/test", isDirectory: true))
            roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: home,
                             appdata: root.appendingPathComponent("AppData/Local", isDirectory: true),
                             roaming: root.appendingPathComponent("AppData/Roaming", isDirectory: true))
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    private static func profile(_ id: String) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
        return try #require(list.profile(covering: id))
    }

    /// A mod as the store keeps it, with one unit of the profile's first kind placing the files given
    /// (archive path → destination spec).
    private static func mod(_ name: String, key: String, kind: ModKind, unit: String, files: [(String, String)],
                            added: TimeInterval = 0, enabled: Bool = true) -> StoredMod {
        let placed = files.map { ModPlan.File(source: $0.0, destination: $0.1, skipped: false) }
        return StoredMod(key: key, name: name, version: nil, author: nil, origin: .init(), archive: .init(name: name + ".zip"),
                         added: Date(timeIntervalSince1970: added), enabled: enabled, codeAccepted: true,
                         units: [ModPlan.Unit(kind: kind, name: unit, root: "", code: true, framework: nil, files: placed)], leftovers: [])
    }

    private static func actions(_ matches: [FixRules.Match]) -> [FixAction?] { matches.map(\.rule.action) }

    @Test func ue4ssLogBlamesTheModOrTheLoader() throws {
        let hogwarts = try Self.profile("steam:990080")
        let kind = try #require(hogwarts.kinds.first)
        let log = try #require(hogwarts.logs.first)
        let better = Self.mod("Better Hogwarts v2", key: "better-hogwarts-v2", kind: kind, unit: "BetterHogwarts",
                              files: [("BetterHogwarts/Scripts/main.lua", "game:Phoenix/Binaries/Win64/Mods/BetterHogwarts/Scripts/main.lua")])
        let travel = Self.mod("Fast Travel", key: "fast-travel", kind: kind, unit: "FastTravel",
                              files: [("FastTravel/Scripts/main.lua", "game:Phoenix/Binaries/Win64/Mods/FastTravel/Scripts/main.lua")], added: 10)
        let state = ModDiagnostics.State(mods: [better, travel], installedFrameworks: ["ue4ss"])
        let broken = """
        [2026-11-01 10:00:00] Starting Lua mod 'BetterHogwarts'
        [2026-11-01 10:00:01] [Lua] C:\\Games\\Hogwarts Legacy\\Phoenix\\Binaries\\Win64\\Mods\\BetterHogwarts\\Scripts\\main.lua:12: attempt to index a nil value (error)
        [2026-11-01 10:00:01] [Lua] C:\\Games\\Hogwarts Legacy\\Phoenix\\Binaries\\Win64\\Mods\\BetterHogwarts\\Scripts\\main.lua:30: stack traceback error
        [2026-11-01 10:00:02] Starting Lua mod 'FastTravel'
        """
        var unresolved: [String] = []
        let matches = ModDiagnostics.matches(in: broken, log: log, profile: hogwarts, state: state, unresolved: &unresolved)
        #expect(Self.actions(matches) == [.disableMod("better-hogwarts-v2")], "two lines about one mod are one fix")
        #expect(matches.first?.rule.id == ModDiagnostics.brokenModRule && matches.first?.weight == 2)
        #expect(unresolved.isEmpty)

        // A mod the loader names that isn't in the store (put in by hand): nothing to turn off, the name noted.
        let stranger = broken.replacingOccurrences(of: "BetterHogwarts", with: "HandMade")
        #expect(ModDiagnostics.matches(in: stranger, log: log, profile: hogwarts, state: state, unresolved: &unresolved).isEmpty)
        #expect(unresolved == ["HandMade"])

        // Turned off already: not offered again.
        var done = state
        done.applied = [AppliedFix(ruleID: ModDiagnostics.brokenModRule, action: .disableMod("better-hogwarts-v2"), undo: .enableMod("better-hogwarts-v2"))]
        #expect(ModDiagnostics.matches(in: broken, log: log, profile: hogwarts, state: done, unresolved: &unresolved).isEmpty)

        // The loader can't find its addresses in a new game version: the loader goes off, not a mod.
        let outdated = "[2026-11-01 10:00:00] [Error] AOB scans could not be completed: 3 signatures failed\n"
        let loader = ModDiagnostics.matches(in: outdated, log: log, profile: hogwarts, state: state, unresolved: &unresolved)
        #expect(Self.actions(loader) == [.disableFramework("ue4ss")] && loader.first?.rule.id == ModDiagnostics.loaderOutdatedRule)
        let bare = ModDiagnostics.State(mods: [], installedFrameworks: [])
        #expect(ModDiagnostics.matches(in: outdated, log: log, profile: hogwarts, state: bare, unresolved: &unresolved).isEmpty, "not installed: nothing to turn off")
    }

    @Test func smapiLogSkipsTheModItNamesAndSumsUpTheSession() throws {
        let stardew = try Self.profile("steam:413150")
        let kind = try #require(stardew.kinds.first)
        let log = try #require(stardew.logs.first)
        let old = Self.mod("Old Mod", key: "old-mod", kind: kind, unit: "OldMod", files: [("OldMod/OldMod.dll", "game:Mods/OldMod/OldMod.dll")])
        let patcher = Self.mod("Content Patcher", key: "content-patcher", kind: kind, unit: "ContentPatcher",
                               files: [("ContentPatcher/ContentPatcher.dll", "game:Mods/ContentPatcher/ContentPatcher.dll")])
        let state = ModDiagnostics.State(mods: [old, patcher],
                                         manifests: ["old-mod": ["name": "Old Mod", "uniqueid": "someone.OldMod"],
                                                     "content-patcher": ["name": "Content Patcher", "uniqueid": "Pathoschild.ContentPatcher"]])
        let text = """
        [10:00:00 INFO  SMAPI] SMAPI 4.1.10 with Stardew Valley 1.6.15 on macOS 26.0
        [10:00:00 INFO  SMAPI] Mods go here: /Users/someone/Library/Application Support/Steam/steamapps/common/Stardew Valley/Contents/MacOS/Mods
        [10:00:01 INFO  SMAPI] Loaded 2 mods:
        [10:00:01 INFO  SMAPI]    Content Patcher 2.5.0 by Pathoschild | Loads content packs
        [10:00:01 INFO  SMAPI]    SpaceCore 1.27.0 by spacechase0 | A framework
        [10:00:01 WARN  SMAPI] Skipped mods
        [10:00:01 WARN  SMAPI] --------------------------------------------------
        [10:00:01 WARN  SMAPI]    These mods could not be added to your game.
        [10:00:01 ERROR SMAPI]    - Old Mod 1.0.0 because it's no longer compatible. Please check for a new version at https://smapi.io/mods.
        [10:00:01 INFO  SMAPI] You can update 1 mod:
        [10:00:01 INFO  SMAPI]    Content Patcher 2.6.0: https://smapi.io/mods#Content_Patcher
        [10:00:01 INFO  SMAPI] You can update SMAPI to 4.2.0: https://smapi.io
        """
        var unresolved: [String] = []
        let matches = ModDiagnostics.matches(in: text, log: log, profile: stardew, state: state, unresolved: &unresolved)
        #expect(Self.actions(matches) == [.disableMod("old-mod")], "SMAPI names a skipped mod by its manifest name")
        #expect(unresolved.isEmpty)

        let summary = SMAPISummary.parse(text)
        #expect(summary.smapiVersion == "4.1.10" && summary.gameVersion == "1.6.15" && summary.loaded == 2)
        #expect(summary.skipped == ["Old Mod"] && summary.updates == ["Content Patcher"])
        #expect(summary.smapiUpdate == "4.2.0" && summary.errors == 1)
        #expect(SMAPISummary.parse("") == SMAPISummary())
    }

    @Test func asiLoaderAndREFrameworkLogsPointAtTheFile() throws {
        let rdr2 = try Self.profile("steam:1174180")
        let kind = try #require(rdr2.kinds.first)
        let rampage = Self.mod("Rampage Trainer", key: "rampage-trainer", kind: kind, unit: "Rampage",
                               files: [("Rampage.asi", "game:Rampage.asi"), ("RampageFiles/menu.dat", "game:RampageFiles/menu.dat")])
        let state = ModDiagnostics.State(mods: [rampage], installedFrameworks: ["scripthookrdr2", "asiloader-version"])
        let asi = try #require(rdr2.logs.first { $0.file == "game:asiloader.log" })
        var unresolved: [String] = []
        for sample in ["// ASI loading\n\"C:\\Games\\RDR2\\Rampage.asi\" failed to load\n", "\"Rampage.asi\" failed to load"] {
            let matches = ModDiagnostics.matches(in: sample, log: asi, profile: rdr2, state: state, unresolved: &unresolved)
            #expect(Self.actions(matches) == [.disableMod("rampage-trainer")], "by the whole path or the file's name")
        }
        let hook = try #require(rdr2.logs.first { $0.file == "game:ScriptHookRDR2.log" })
        let version = "FATAL: unknown game version, check http://dev-c.com for updates\n"
        #expect(Self.actions(ModDiagnostics.matches(in: version, log: hook, profile: rdr2, state: state, unresolved: &unresolved)) == [.disableFramework("scripthookrdr2")])

        // RE4 through the files on disk: REFramework's log names the script; its crash dump blames the newest mod.
        let bench = Bench()
        defer { try? FileManager.default.removeItem(at: bench.root) }
        let re4 = try Self.profile("steam:2050650")
        let reKind = try #require(re4.kinds.first)
        let camera = Self.mod("Better Camera", key: "better-camera", kind: reKind, unit: "better_camera",
                              files: [("reframework/autorun/better_camera.lua", "game:reframework/autorun/better_camera.lua")], added: 100)
        let hud = Self.mod("Clean HUD", key: "clean-hud", kind: reKind, unit: "clean_hud",
                           files: [("reframework/autorun/clean_hud.lua", "game:reframework/autorun/clean_hud.lua")], added: 200)
        let reState = ModDiagnostics.State(mods: [camera, hud], installedFrameworks: ["reframework"])
        try bench.write("""
        [2026-11-01 10:00:00.000] [info] [reframework] Loading autorun\\better_camera.lua
        [2026-11-01 10:00:00.100] [error] [reframework] autorun\\better_camera.lua:40: attempt to index a nil value (error)
        [2026-11-01 10:00:00.200] [info] [reframework] Loading autorun\\clean_hud.lua

        """, to: bench.game.appendingPathComponent("re2_framework_log.txt"))
        let diagnostics = ModDiagnostics(profile: re4, roots: bench.roots)
        var result = diagnostics.collect(reState)
        #expect(Self.actions(result.matches) == [.disableMod("better-camera")])
        let tail = try #require(result.tail)
        #expect(tail.hasPrefix("== game:re2_framework_log.txt ==\n"))
        #expect(!tail.contains("better_camera") && !tail.contains("clean_hud") && tail.contains("Loading autorun\\….lua"), "the tail kept for a report has the mods' names taken out")
        #expect(result.summary == nil)

        try bench.write("MDMP", to: bench.game.appendingPathComponent("reframework_crash.dmp"))
        result = diagnostics.collect(reState)
        #expect(Self.actions(result.matches) == [.disableMod("better-camera"), .disableMod("clean-hud")], "the dump blames the mod added last")
        #expect(result.matches.last?.rule.id == ModDiagnostics.newestModRule && result.matches.last?.weight == 3)
        #expect(diagnostics.collect(reState, since: Date().addingTimeInterval(60)).matches.count == 1, "a dump from before the launch blames nobody")
        // The newest mod turned off already: the dump has nothing left to say.
        var done = reState
        done.applied = [AppliedFix(ruleID: ModDiagnostics.newestModRule, action: .disableMod("clean-hud"), undo: .enableMod("clean-hud"))]
        #expect(Self.actions(diagnostics.collect(done).matches) == [.disableMod("better-camera")])
    }

    @Test func aFrameworkGoesOffWithoutLeavingAndComesBack() throws {
        // UE4SS has an argument for it: the override stays, so the loader's files stay in place for the next update.
        let hogwarts = try Self.profile("steam:990080")
        let ue4ss = try #require(hogwarts.frameworks.first { $0.id == "ue4ss" })
        var profile = LaunchProfile()
        profile.dllOverrides = ["dwmapi": "n,b"]
        let argument = ModDiagnostics.disable(ue4ss, in: &profile)
        #expect(profile.extraArguments == ["--disable-ue4ss"] && profile.dllOverrides == ["dwmapi": "n,b"])
        #expect(argument.action == .disableFramework("ue4ss") && argument.ruleID == ModDiagnostics.loaderOutdatedRule && argument.concernsMods)
        #expect(argument.action.isUndoable)
        ModDiagnostics.restore(argument.undo, in: &profile)
        #expect(profile.extraArguments.isEmpty && profile.dllOverrides == ["dwmapi": "n,b"])

        // REFramework has none: its proxy DLL's override goes, every other override stays.
        let re4 = try Self.profile("steam:2050650")
        let reframework = try #require(re4.frameworks.first { $0.id == "reframework" })
        profile = LaunchProfile()
        profile.dllOverrides = ["dinput8": "n,b", "d3d12": "b"]
        let override = ModDiagnostics.disable(reframework, in: &profile)
        #expect(profile.dllOverrides == ["d3d12": "b"] && profile.extraArguments.isEmpty)
        ModDiagnostics.restore(override.undo, in: &profile)
        #expect(profile.dllOverrides == ["dinput8": "n,b", "d3d12": "b"])

        // SMAPI starts instead of the game: the redirect goes, and comes back with the undo.
        let stardew = try Self.profile("steam:413150")
        let smapi = try #require(stardew.frameworks.first { $0.id == "smapi" })
        profile = LaunchProfile()
        profile.redirect = ExecutableRedirect(instead: "Stardew Valley", run: "StardewModdingAPI")
        let redirect = ModDiagnostics.disable(smapi, in: &profile)
        #expect(profile.redirect == nil)
        ModDiagnostics.restore(redirect.undo, in: &profile)
        #expect(profile.redirect == ExecutableRedirect(instead: "Stardew Valley", run: "StardewModdingAPI"))
        // Someone else's redirect isn't the loader's: left alone.
        profile.redirect = ExecutableRedirect(instead: "Stardew Valley", run: "Other")
        _ = ModDiagnostics.disable(smapi, in: &profile)
        #expect(profile.redirect == ExecutableRedirect(instead: "Stardew Valley", run: "Other"))
    }

    @Test func reportsCarryAFlagAndNeverAModsName() throws {
        let game = CompatibilityReport.GameRef(store: "steam", id: "990080", title: "Hogwarts Legacy")
        #expect(CompatibilityReport(client: "c", game: game, outcome: .ran).mods == nil)
        #expect(CompatibilityReport(client: "c", game: game, outcome: .ran, mods: false).mods == nil, "no mods: no flag at all")
        #expect(CompatibilityReport(client: "c", game: game, outcome: .ran, mods: true).mods == true)

        // Fixes about mods stay out of the settings: a key would name the mod, a loader's override is no recipe.
        let profile = LaunchProfile()
        let applied = [AppliedFix(ruleID: ModDiagnostics.brokenModRule, action: .disableMod("better-hogwarts-v2"), undo: .enableMod("better-hogwarts-v2")),
                       AppliedFix(ruleID: ModDiagnostics.loaderOutdatedRule, action: .disableFramework("ue4ss"),
                                  undo: .restoreFrameworkLaunch(overrides: [:], arguments: [], instead: nil, run: nil)),
                       AppliedFix(ruleID: "framework:ue4ss", action: .installDotNet, undo: .none),
                       AppliedFix(ruleID: "dotnet", action: .installDotNet, undo: .none)]
        #expect(applied.map(\.concernsMods) == [true, true, true, false])
        let settings = CompatibilityReport.Settings(profile: profile, applied: applied, shadersFromOthers: false)
        #expect(settings.fixes == ["dotnet"])
        let report = CompatibilityReport(client: "c", game: game, outcome: .crashed, settings: settings, mods: true)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(json.contains("\"mods\":true") && !json.contains("hogwarts-v2") && !json.contains("ue4ss"))

        // A failure report with mods: the flag in, the loader's log read here but kept on the Mac (it lists mods put
        // in by hand too), the mods' names out of every text.
        let bench = Bench()
        defer { try? FileManager.default.removeItem(at: bench.root) }
        let hogwarts = try Self.profile("steam:990080")
        let kind = try #require(hogwarts.kinds.first)
        let better = Self.mod("Better Hogwarts v2", key: "better-hogwarts-v2", kind: kind, unit: "BetterHogwarts",
                              files: [("BetterHogwarts/Scripts/main.lua", "game:Phoenix/Binaries/Win64/Mods/BetterHogwarts/Scripts/main.lua")])
        try bench.write("[Lua] Mods\\BetterHogwarts\\Scripts\\main.lua:12: boom (error)\n", to: bench.game.appendingPathComponent("Phoenix/Binaries/Win64/UE4SS.log"))
        var diagnostics = LaunchDiagnostics(gameID: "steam:990080", title: "Hogwarts Legacy", store: "steam",
                                            logTail: "wine: loaded Better Hogwarts v2 from C:\\Games\\Mods\\BetterHogwarts\\main.lua",
                                            crashReport: "process: HogwartsLegacy\n  BetterHogwarts.dll +12")
        let result = ModDiagnostics(profile: hogwarts, roots: bench.roots).attach(to: &diagnostics, state: .init(mods: [better]), inPlay: true)
        #expect(Self.actions(result.matches) == [.disableMod("better-hogwarts-v2")])
        #expect(diagnostics.mods == true && diagnostics.modLogTail?.hasPrefix("== game:Phoenix/Binaries/Win64/UE4SS.log ==") == true)
        let failure = FailureReport(client: "c", game: game, diagnostics: diagnostics, matched: result.matches.map(\.rule.id),
                                    sommelier: .init(app: "1", engine: "11.0", backend: "dxmt"))
        for name in ["Better Hogwarts", "better-hogwarts", "BetterHogwarts"] { #expect(!failure.preview.contains(name), Comment(rawValue: name)) }
        #expect(failure.preview.contains("\"mods\" : true") && failure.preview.contains("mods.broken-mod"))
        #expect(failure.diagnostics.modLogTail == nil && !failure.preview.contains("modLogTail") && !failure.preview.contains("UE4SS.log"))
        #expect(diagnostics.logTail == "wine: loaded … from C:\\Games\\Mods\\…\\main.lua" && diagnostics.crashReport == "process: HogwartsLegacy\n  ….dll +12")

        // What a manifest calls a mod is a name too: SMAPI writes the manifest's name, author and unique id.
        let patcher = Self.mod("ContentPatcher", key: "contentpatcher", kind: kind, unit: "ContentPatcher", files: [])
        let fields = ["contentpatcher": ["name": "Content Patcher", "author": "Pathoschild", "uniqueid": "Pathoschild.ContentPatcher",
                                         "description": "Loads content packs to change the game's data."]]
        let smapiLine = "[10:00:01 INFO  SMAPI]    Content Patcher 2.4.4 by Pathoschild | Loads content packs to change the game's data.\n"
            + "[10:00:02 ERROR Pathoschild.ContentPatcher] boom"
        let scrubbed = ModDiagnostics.scrub(smapiLine, mods: [patcher], manifests: fields)
        for name in ["Content Patcher", "Pathoschild", "ContentPatcher", "content packs"] { #expect(!scrubbed.contains(name), Comment(rawValue: name)) }
        #expect(scrubbed.contains("2.4.4 by …"))

        // Without mods: no flag and no mods log.
        var vanilla = LaunchDiagnostics(gameID: "steam:990080", title: "Hogwarts Legacy", store: "steam", logTail: "wine: fine")
        let nothing = ModDiagnostics(profile: hogwarts, roots: Bench().roots).attach(to: &vanilla, state: .init(mods: []), inPlay: false)
        #expect(nothing == ModDiagnostics.Result() && vanilla.mods == nil && vanilla.modLogTail == nil)
        let plain = FailureReport(client: "c", game: game, diagnostics: vanilla, matched: [], sommelier: .init(app: "1")).preview
        #expect(!plain.contains("\"mods\"") && !plain.contains("modLogTail"))
    }
}
