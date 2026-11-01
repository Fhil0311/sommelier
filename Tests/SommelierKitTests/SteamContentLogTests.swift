// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SteamContentLogTests {
    // Lines as Steam wrote them for a real launch of Fallout Shelter (October 2026).
    let log = """
    [2026-10-19 20:18:58] AppID 588430 state changed : Fully Installed,Update Queued,
    [2026-10-19 20:18:58] AppID 588430 state changed : Fully Installed,
    [2026-10-19 20:19:05] AppID 588430 state changed : Fully Installed,App Running,
    [2026-10-19 20:19:06] AppID 620 state changed : Fully Installed,
    """

    @Test func latestLineWins() {
        #expect(SteamContentLog.isRunning(appID: "588430", in: Substring(log)) == true)
        let stopped = log + "\n[2026-10-19 20:20:31] AppID 588430 state changed : Fully Installed,\n"
        #expect(SteamContentLog.isRunning(appID: "588430", in: Substring(stopped)) == false)
    }

    @Test func otherGamesAndMissingLines() {
        #expect(SteamContentLog.isRunning(appID: "620", in: Substring(log)) == false)
        #expect(SteamContentLog.isRunning(appID: "1", in: Substring(log)) == nil)
        #expect(SteamContentLog.isRunning(appID: "58843", in: Substring(log)) == nil)   // no prefix matches
    }

    @Test func readsTheEndOfTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: root))
        let file = SteamContentLog.file(in: bottle)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (String(repeating: "noise line\n", count: 50_000) + log).write(to: file, atomically: true, encoding: .utf8)
        #expect(SteamContentLog.isRunning(appID: "588430", bottle: bottle, tailBytes: 4096) == true)
        #expect(SteamContentLog.isRunning(appID: "588430", bottle: Bottle(kind: .epic, paths: Paths(home: root))) == nil)
    }
}

@Suite struct SteamLaunchUpdateTests {
    @Test func downloadingAnUpdateBeforeTheLaunchIsNotStuck() {
        let log = """
        [2026-10-23 02:26:06] GameAction [AppID 2592160, ActionID 1] : LaunchApp changed task to CheckShaderDepotManifest with ""
        [2026-10-23 02:26:06] GameAction [AppID 2592160, ActionID 1] : LaunchApp changed task to DownloadingDepots with ""
        """
        let step = SteamContentLog.launchStep(appID: "2592160", in: Substring(log))
        #expect(step?.updating == true && step?.done == false)
        let other = SteamContentLog.launchStep(appID: "2592160", in: Substring("[x] GameAction [AppID 2592160, ActionID 1] : LaunchApp changed task to SynchronizingCloud with \"\""))
        #expect(other?.updating == false)
    }

    @Test func installScriptsOnAFirstLaunchAreNotStuck() {
        // The Witcher 3's first launch in a new environment (25.10): 34 seconds on this step, then the game started.
        let log = """
        [2026-10-25 18:04:05] GameAction [AppID 292030, ActionID 1] : LaunchApp changed task to CheckShaderDepotManifest with ""
        [2026-10-25 18:04:05] GameAction [AppID 292030, ActionID 1] : LaunchApp changed task to RunningInstallScript with ""
        """
        let step = SteamContentLog.launchStep(appID: "292030", in: Substring(log))
        #expect(step?.installing == true && step?.done == false && step?.updating == false)
        let later = SteamContentLog.launchStep(appID: "292030", in: Substring(log + "\n[2026-10-25 18:04:39] GameAction [AppID 292030, ActionID 1] : LaunchApp changed task to SynchronizingCloud with \"\""))
        #expect(later?.installing == false)
    }
}
