// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct FrameStatsTests {
    @Test func readsTheCounterFile() {
        let sample = FrameStats.parse("exe=Game.exe\nframes=12345\nseconds=210.5\naverage=58.64\nlow1=31.2\nwidth=2560\nheight=1440\n")
        #expect(sample == FrameStats.Sample(exe: "Game.exe", frames: 12345, seconds: 210.5, average: 58.64, low1: 31.2, width: 2560, height: 1440))
        #expect(FrameStats.parse("exe=Game.exe\n") == nil)
    }

    @Test func picksTheGamesOwnProcess() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("framestats-\(UUID().uuidString)")
        let bottle = Bottle(kind: .epic, paths: Paths(home: home))
        let folder = FrameStats.folder(in: bottle)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let game = home.appendingPathComponent("Games/Overcooked/Bin", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: game.appendingPathComponent("Overcooked.exe").path, contents: Data())
        let since = Date().addingTimeInterval(-5)
        try "exe=Overcooked.exe\nframes=7000\nseconds=120\naverage=58.33\nlow1=40\nwidth=1920\nheight=1080\n"
            .write(to: folder.appendingPathComponent("Overcooked.exe-42.txt"), atomically: true, encoding: .utf8)
        try "exe=EADesktop.exe\nframes=9000\nseconds=600\naverage=15\nlow1=10\nwidth=520\nheight=867\n"      // a launcher, longer
            .write(to: folder.appendingPathComponent("EADesktop.exe-7.txt"), atomically: true, encoding: .utf8)

        let fps = FrameStats.session(in: bottle, since: since, gameFolder: home.appendingPathComponent("Games/Overcooked"))
        #expect(fps == CompatibilityReport.FrameRate(average: 58.3, low: 40, resolution: "1920x1080"))
        #expect(FrameStats.session(in: bottle, since: Date().addingTimeInterval(60), gameFolder: nil) == nil)   // nothing since then
        #expect(FrameStats.windowsPath(URL(fileURLWithPath: "/Users/me/x")) == #"Z:\Users\me\x"#)
    }

    @Test func everyProcessGetsTheFolder() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/somm")))
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), base: [:])
        #expect(env["SOMMELIER_FRAME_STATS_DIR"] == #"Z:\tmp\somm\Bottles\steam\FrameStats"#)
    }
}
