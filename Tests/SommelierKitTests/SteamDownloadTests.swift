// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SteamDownloadTests {
    func manifest(flags: Int, toDownload: Int64 = 1000, downloaded: Int64 = 0, toStage: Int64 = 2000, staged: Int64 = 0) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"945360"
        \t"name"\t\t"Among Us"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"Among Us"
        \t"BytesToDownload"\t\t"\(toDownload)"
        \t"BytesDownloaded"\t\t"\(downloaded)"
        \t"BytesToStage"\t\t"\(toStage)"
        \t"BytesStaged"\t\t"\(staged)"
        }
        """
    }

    @Test func phasesFromStateFlags() {
        #expect(SteamDownload.parse(manifest: manifest(flags: 2))?.phase == .queued)          // waiting in Steam's queue
        // An installed game's update Steam scheduled for later: not a download (Dispatch, flags 6, a week ahead).
        let now = Date(timeIntervalSince1970: 1_792_695_934)
        let later = manifest(flags: 6).replacingOccurrences(of: "\"StateFlags\"", with: "\"ScheduledAutoUpdate\"\t\t\"1793320658\"\n\t\"StateFlags\"")
        #expect(SteamDownload.parse(manifest: later, now: now)?.phase == .done)
        #expect(SteamDownload.parse(manifest: later, now: Date(timeIntervalSince1970: 1_793_400_000))?.phase == .queued)   // its time came
        #expect(SteamDownload.parse(manifest: manifest(flags: 6), now: now)?.phase == .queued)                         // no schedule: queued
        // The library scan agrees: no install progress for it, so it isn't picked up as a download at all.
        let scheduledManifest = later.replacingOccurrences(of: "\"StateFlags\"", with: "\"appid\"\t\t\"1\"\n\t\"name\"\t\t\"Dispatch\"\n\t\"StateFlags\"")
        let game = SteamLibrary.parseManifest(scheduledManifest, steamapps: URL(fileURLWithPath: "/tmp"), now: now)
        #expect(game?.isInstalled == true && game?.installProgress == nil)
        // What Steam actually keeps in the manifest during a download (A Way Out, October 2026): 1026.
        let real = SteamDownload.parse(manifest: manifest(flags: 1026, toDownload: 22_307_710_288, downloaded: 136_947_696,
                                                          toStage: 22_611_184_019, staged: 146_390_709),
                                       writtenSoFar: 523_432 * 1024)
        #expect(real?.phase == .downloading)
        #expect((real?.fraction ?? 0) > 0.02 && (real?.fraction ?? 1) < 0.03)
        // Downloading + staging + update running, as Steam sets them during a download: still downloading.
        let live = SteamDownload.parse(manifest: manifest(flags: 1_048_576 | 2_097_152 | 1026), writtenSoFar: 500)
        #expect(live?.phase == .downloading)
        #expect(live?.fraction == 0.25)                 // 500 of 2000 unpacked bytes written
        #expect(live?.bytesDone == 250)                 // shown in download bytes
        #expect(SteamDownload.parse(manifest: manifest(flags: 1538, downloaded: 300))?.phase == .paused)
        let committing = SteamDownload.parse(manifest: manifest(flags: 4_194_304 | 1026, downloaded: 1000, staged: 1500))
        #expect(committing?.phase == .installing)
        #expect(committing?.fraction == 0.75)
        #expect(SteamDownload.parse(manifest: manifest(flags: 4, downloaded: 1000))?.phase == .done)
        #expect(SteamDownload.parse(manifest: "nonsense") == nil)
    }

    /// Steam preallocates every file at full length when a download starts; only written data takes disk space.
    @Test func preallocatedFilesDontCountAsDownloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: root))
        let steamapps = bottle.steamDirectory.appendingPathComponent("steamapps")
        let folder = steamapps.appendingPathComponent("downloading/945360")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest(flags: 1_048_576 | 2_097_152 | 1026, toDownload: 64 << 20, toStage: 64 << 20)
            .write(to: steamapps.appendingPathComponent("appmanifest_945360.acf"), atomically: true, encoding: .utf8)
        // A 64 MB file at full length (sparse), with 16 MB of real data written.
        let file = folder.appendingPathComponent("data.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 64 << 20)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 7, count: 16 << 20))
        try handle.close()

        let d = try #require(SteamDownload.read(appID: "945360", bottle: bottle))
        #expect(d.phase == .downloading)
        let fraction = try #require(d.fraction)
        #expect(fraction > 0.2 && fraction < 0.3)       // about a quarter, not "all there"
        #expect(SteamDownload.read(appID: "1", bottle: bottle) == nil)
        #expect(SteamDownload.stateFlags(appID: "945360", bottle: bottle) == 1_048_576 | 2_097_152 | 1026)
        #expect(SteamDownload.stateFlags(appID: "1", bottle: bottle) == nil)
    }
}

/// A pause leaves the manifest at "update started"; only content_log.txt says the update stopped.
struct SteamPauseTests {
    // Real lines from pausing A Way Out in Steam's Downloads page.
    static let paused = """
    [2026-10-19 21:47:52] AppID 1222700 App update changed : Running Update,Downloading,Staging,
    [2026-10-19 22:04:34] AppID 1222700 update canceled : Disabled (Suspended)
    [2026-10-19 22:04:34] AppID 1222700 App update changed : Running Update,Downloading,Staging,Stopping,
    [2026-10-19 22:04:34] AppID 1222700 App update changed : Running Update,Stopping,
    [2026-10-19 22:04:34] AppID 1222700 App update changed : None
    [2026-10-19 22:04:34] AppID 1222700 state changed : Update Required,Update Queued,Update Started, (Suspended)
    [2026-10-19 22:09:33] stats: (SteamCache, 491) cache9-waw1.steamcontent.com: 30436624 Bytes
    """

    @Test func pausedDownloadIsPaused() {
        #expect(SteamContentLog.updateActivity(appID: "1222700", in: Substring(Self.paused)) == .paused)
        let resumed = Self.paused + "\n[2026-10-19 22:20:00] AppID 1222700 App update changed : Running Update,Downloading,Staging,\n"
        #expect(SteamContentLog.updateActivity(appID: "1222700", in: Substring(resumed)) == .active)
        #expect(SteamContentLog.updateActivity(appID: "945360", in: Substring(Self.paused)) == nil)
        // Steam is a Windows program: its log lines end in CR LF.
        let windows = Self.paused.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(SteamContentLog.updateActivity(appID: "1222700", in: Substring(windows)) == .paused)
    }

    @Test func stoppedWithoutSuspendIsQueued() {
        let text = """
        [2026-10-19 22:04:34] AppID 42 App update changed : None
        [2026-10-19 22:04:34] AppID 42 state changed : Update Required,Update Queued,
        """
        #expect(SteamContentLog.updateActivity(appID: "42", in: Substring(text)) == .idle)
    }

    @Test func logOverridesTheManifestOnlyWhileDownloading() {
        let downloading = SteamDownload(phase: .downloading, bytesDone: 5, bytesTotal: 10)
        #expect(downloading.adjusted(for: .paused).phase == .paused)
        #expect(downloading.adjusted(for: .idle).phase == .queued)
        #expect(downloading.adjusted(for: .active).phase == .downloading)
        #expect(downloading.adjusted(for: nil).phase == .downloading)
        #expect(SteamDownload(phase: .installing, bytesDone: 5, bytesTotal: 10).adjusted(for: .paused).phase == .installing)
    }
}

struct SteamContentLogLineEndingTests {
    /// With CR LF endings a game's line must not run on into the next game's "App Running".
    @Test func stateLineEndsAtCRLF() {
        let text = "[t] AppID 1 state changed : Fully Installed,\r\n[t] AppID 2 state changed : Fully Installed,App Running,\r\n"
        #expect(SteamContentLog.isRunning(appID: "1", in: Substring(text)) == false)
        #expect(SteamContentLog.isRunning(appID: "2", in: Substring(text)) == true)
    }
}
