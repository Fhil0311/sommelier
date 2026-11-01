// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct CrashSignsTests {
    @Test func winesOwnWordsForACrash() {
        #expect(CrashSigns.inLog("wine: Unhandled page fault on read access to 0000000000000000 at address 00000001400A1B2C (thread 0024), starting debugger..."))
        #expect(CrashSigns.inLog("Unhandled exception: page fault on read access to 0x0 in 64-bit code (0x00000001400a1b2c).\nBacktrace:\n=>0 0x00000001400a1b2c"))
        #expect(CrashSigns.inLog("0024:err:seh:call_stack_handlers invalid frame"))
        #expect(!CrashSigns.inLog("0024:err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems\n[Sommelier] Exit status=0"))
        #expect(!CrashSigns.inLog("info: Turbo: MetalFX swap chain 1440x900 -> 2880x1800"))
        // A crash in Steam's log is the game's only when the backtrace names the game's folder.
        let steamHelper = "wine: Unhandled page fault on read access\nBacktrace:\n=>0 0x1 in steamwebhelper (+0x1)\nModules:\n  PE 0x1 C:\\Program Files (x86)\\Steam\\bin\\cef\\steamwebhelper.exe"
        #expect(!CrashSigns.inLog(steamHelper, naming: "The Witcher 3"))
        let game = "wine: Unhandled page fault on read access\nBacktrace:\n=>0 0x1 in witcher3 (+0x1)\nModules:\n  PE 0x1 C:\\…\\steamapps\\common\\The Witcher 3\\bin\\x64_dx12\\witcher3.exe"
        #expect(CrashSigns.inLog(game, naming: "The Witcher 3"))
        #expect(CrashSigns.inLog(steamHelper, naming: nil))
    }

    @Test func aHungGameIsOneThatDrewNothingForAWhile() {
        let dead = [FrameStats.Sample(exe: "C:\\g\\game.exe", frames: 0, seconds: 0, average: 0, low1: 0, width: 0, height: 0, presented: 0)]
        let alive = [FrameStats.Sample(exe: "C:\\g\\game.exe", frames: 1200, seconds: 20, average: 60, low1: 40, width: 1920, height: 1080, presented: 3600)]
        // Loading for the first 40 seconds, then a menu: measured frames can be zero while frames were presented.
        let loading = [FrameStats.Sample(exe: "C:\\g\\game.exe", frames: 0, seconds: 0, average: 0, low1: 0, width: 0, height: 0, presented: 400)]
        #expect(!CrashSigns.hung(frames: loading, windowSeen: true, secondsRunning: 120))
        #expect(FrameStats.parse("exe=C:\\g\\game.exe\nframes=10\nseconds=1\naverage=10\nlow1=5\n")?.presented == 10)
        #expect(FrameStats.parse("exe=C:\\g\\game.exe\nframes=0\nseconds=0\naverage=0\nlow1=0\nwidth=0\nheight=0\npresented=0\n")?.presented == 0)
        #expect(FrameStats.parse("exe=g.exe\nframes=0\nseconds=0\naverage=0\nlow1=0\npresented=5\nhdr=3\n")?.hdr == 3)
        #expect(FrameStats.parse("exe=g.exe\nframes=0\nseconds=0\naverage=0\nlow1=0\n")?.hdr == 0)
        #expect(CrashSigns.hung(frames: dead, windowSeen: true, secondsRunning: 120))
        #expect(!CrashSigns.hung(frames: dead, windowSeen: true, secondsRunning: 60))          // not yet
        #expect(!CrashSigns.hung(frames: dead, windowSeen: false, secondsRunning: 120))        // no window: the other rule's business
        #expect(!CrashSigns.hung(frames: alive, windowSeen: true, secondsRunning: 120))
        #expect(!CrashSigns.hung(frames: [], windowSeen: true, secondsRunning: 600))           // nothing measured: nothing known
        #expect(!CrashSigns.hung(frames: dead + alive, windowSeen: true, secondsRunning: 120))
    }

    @Test func readsOnlyWhatASessionAppended() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        try "old session: Unhandled exception: page fault\n".write(to: file, atomically: true, encoding: .utf8)
        let mark = CrashSigns.size(of: file)
        #expect(!CrashSigns.inLog(CrashSigns.appended(to: file, after: mark)))
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        handle.write(Data("new session: all fine\nwine: Unhandled page fault\n".utf8)); try handle.close()
        let added = CrashSigns.appended(to: file, after: mark)
        #expect(added.hasPrefix("new session") && CrashSigns.inLog(added))
        #expect(CrashSigns.size(of: nil) == 0)
    }

    @Test func steamsLaunchSteps() {
        let log = """
        [2026-10-22 18:18:59] GameAction [AppID 1903340, ActionID 7] : LaunchApp waiting for user response to ShowInterstitials ""
        [2026-10-22 18:18:59] GameAction [AppID 1903340, ActionID 7] : LaunchApp continues with user response "ShowInterstitials"
        [2026-10-22 18:18:59] GameAction [AppID 1903340, ActionID 7] : LaunchApp changed task to SynchronizingControllerConfig with ""
        [2026-10-22 18:19:00] GameAction [AppID 292030, ActionID 8] : LaunchApp changed task to Completed with ""
        """
        let step = SteamContentLog.launchStep(appID: "1903340", in: Substring(log))
        #expect(step?.line.hasSuffix("SynchronizingControllerConfig with \"\"") == true)
        #expect(step?.done == false && step?.waitingForPlayer == false)
        #expect(SteamContentLog.launchStep(appID: "292030", in: Substring(log))?.done == true)
        let waiting = "[x] GameAction [AppID 5, ActionID 1] : LaunchApp waiting for user response to ShowEula \"\""
        #expect(SteamContentLog.launchStep(appID: "5", in: Substring(waiting))?.waitingForPlayer == true)
        #expect(SteamContentLog.launchStep(appID: "6", in: Substring(log)) == nil)
    }

    @Test func metalGameThatDrewNothingHung() {
        let isGame: (String) -> Bool = { $0 == "Game.exe" }
        #expect(CrashSigns.drewNothing(drawers: [], isGame: isGame, windowSeen: true, secondsRunning: 120))
        #expect(CrashSigns.drewNothing(drawers: ["steamwebhelper.exe"], isGame: isGame, windowSeen: true, secondsRunning: 120))   // the launcher drew, not the game
        #expect(!CrashSigns.drewNothing(drawers: ["Game.exe"], isGame: isGame, windowSeen: true, secondsRunning: 120))
        #expect(!CrashSigns.drewNothing(drawers: [], isGame: isGame, windowSeen: true, secondsRunning: 60))       // too early to say
        #expect(!CrashSigns.drewNothing(drawers: [], isGame: isGame, windowSeen: false, secondsRunning: 300))     // no window: another rule
    }

    @Test func driverRecordsNameWhoDrewAndOutliveTheirSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date()
        let fresh = folder.appendingPathComponent("Expedition33-Win64-Shipping.exe-999999-live.bin")
        let old = folder.appendingPathComponent("Old.exe-999998-live.bin")
        for url in [fresh, old] { try Data(count: 64).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: old.path)
        #expect(LiveFrameRate.drawers(in: folder, since: start.addingTimeInterval(-5)) == ["Expedition33-Win64-Shipping.exe"])
        LiveFrameRate.cleanUp(in: folder)                          // both processes are gone; only the hour-old record goes
        #expect(FileManager.default.fileExists(atPath: fresh.path) && !FileManager.default.fileExists(atPath: old.path))
    }
}
