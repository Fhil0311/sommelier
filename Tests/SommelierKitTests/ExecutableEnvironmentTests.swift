// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct ExecutableEnvironmentTests {
    @Test func linesHoldAFolderAndItsVariables() throws {
        let line = try #require(ExecutableEnvironment.line(folder: #"C:\Games\Raft"#, variables: ["DXMT_CONFIG": "d3d11.x=2", "SOMMELIER_FORCE_SDR": "", "bad\tname": "1"]))
        #expect(line == "C:\\Games\\Raft\tDXMT_CONFIG=d3d11.x=2\tSOMMELIER_FORCE_SDR=")
        let parsed = ExecutableEnvironment.parse(line + "\n")
        #expect(parsed.count == 1 && parsed[0].folder == #"C:\Games\Raft"# && parsed[0].variables == ["DXMT_CONFIG": "d3d11.x=2", "SOMMELIER_FORCE_SDR": ""])
        #expect(ExecutableEnvironment.line(folder: "C:\\x", variables: [:]) == nil)
    }

    @Test func aFolderLineIsReplacedAndOthersStay() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-exeenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let table = ExecutableEnvironment(paths: Paths(home: home))
        table.set(folder: #"C:\Games\Raft"#, variables: ["A": "1"])
        table.set(folder: #"C:\Games\Dispatch"#, variables: ["B": "2"])
        table.set(folder: #"c:\games\raft"#, variables: ["A": "3"])                 // the same folder, whatever the case
        let rows = ExecutableEnvironment.parse(try String(contentsOf: ExecutableEnvironment.url(home: home), encoding: .utf8))
        #expect(rows.map(\.folder) == [#"C:\Games\Dispatch"#, #"c:\games\raft"#])
        #expect(rows[1].variables == ["A": "3"])
        table.set(folder: #"C:\Games\Dispatch"#, variables: [:])                    // taken out
        #expect(ExecutableEnvironment.parse(try String(contentsOf: ExecutableEnvironment.url(home: home), encoding: .utf8)).count == 1)
    }

    @Test func programEnvironmentNamesEveryGraphicsVariable() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/sommelier-exeenv")))
        var turbo = LaunchProfile(); turbo.backend = .dxmt; turbo.turbo = true
        let vars = WineRunner.programEnvironment(bottle: bottle, profile: turbo)
        #expect(vars["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "1")
        #expect(vars["WINEDLLOVERRIDES"]?.contains("dxgi,d3d11,d3d10core=b") == true)
        #expect(vars["CX_ACTIVE_GRAPHICS_BACKEND"] == "")                         // D3DMetal's, unset for a DXMT game
        #expect(vars["SOMMELIER_FORCE_SDR"] == "")
        #expect(vars["SOMMELIER_NO_MIC"] == "1")                                 // not a game's launch: no microphone
        #expect(SteamProvider.noMicrophone == ["SOMMELIER_NO_MIC": "1"])
        var plain = LaunchProfile(); plain.backend = .dxmt
        #expect(WineRunner.programEnvironment(bottle: bottle, profile: plain)["DXMT_METALFX_SPATIAL_SWAPCHAIN"] == "")
    }
}

@Suite struct ExecutableArgumentsTests {
    @Test func aGamesProgramsGetItsArgumentsAndHelpersDont() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-exeargs-\(UUID().uuidString)")
        let game = home.appendingPathComponent("Watch Dogs 2")
        for name in ["bin/WatchDogs2.exe", "EasyAntiCheat/EasyAntiCheat_Setup.exe", "bin/EAC.exe", "bin/CrashReporter.exe", "Uninstall.exe"] {
            let file = game.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: file)
        }
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ExecutableArguments.programs(in: game).map(\.lastPathComponent) == ["WatchDogs2.exe"])

        let table = ExecutableArguments(paths: Paths(home: home))
        table.set(folder: #"C:\Games\Watch Dogs 2"#, programs: [#"C:\Games\Watch Dogs 2\bin\WatchDogs2.exe"#], arguments: ["-eac_launcher", "-nosplash"])
        table.set(folder: #"C:\Games\Raft"#, programs: [#"C:\Games\Raft\Raft.exe"#], arguments: ["-x"])
        var text = try String(contentsOf: ExecutableArguments.url(home: home), encoding: .utf8)
        #expect(text == "C:\\Games\\Watch Dogs 2\\bin\\WatchDogs2.exe\t-eac_launcher -nosplash\nC:\\Games\\Raft\\Raft.exe\t-x\n")
        table.set(folder: #"c:\games\watch dogs 2"#, programs: [#"C:\Games\Watch Dogs 2\bin\WatchDogs2.exe"#], arguments: [])  // undone
        text = try String(contentsOf: ExecutableArguments.url(home: home), encoding: .utf8)
        #expect(text == "C:\\Games\\Raft\\Raft.exe\t-x\n")
    }
}
