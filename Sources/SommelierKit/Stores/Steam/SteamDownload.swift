// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A Steam install or update in progress, read from Steam's own files.
///
/// `appmanifest_<id>.acf` says what Steam is doing (`StateFlags`) and how much it has to download and stage, but
/// Steam rewrites it only now and then. While downloading, Steam writes the unpacked files into
/// `steamapps/downloading/<id>`. It creates them at full length first ("preallocated 59 files (1094 MB)" in its
/// log), so their length means nothing; under Wine on APFS they are sparse, so the disk space they take grows with
/// the data written. That space against `BytesToStage` (the unpacked size) gives live progress.
public struct SteamDownload: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Waiting in Steam's download queue.
        case queued
        case downloading
        /// Paused by the user in Steam.
        case paused
        /// Download done; Steam is unpacking, verifying or writing files.
        case installing
        /// Fully installed, nothing left to do.
        case done
    }

    public let phase: Phase
    public let bytesDone: Int64
    public let bytesTotal: Int64

    public init(phase: Phase, bytesDone: Int64, bytesTotal: Int64) {
        self.phase = phase; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
    }

    public var fraction: Double? { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : nil }

    // Steam's EAppState bits.
    static let fullyInstalled = 4, updateRequired = 2, updateRunning = 256, updatePaused = 512, updateStarted = 1024
    static let downloading = 1 << 20, staging = 1 << 21, committing = 1 << 22, validating = 1 << 17, preallocating = 1 << 19

    /// The state of `appID`'s install, or nil when Steam has no manifest for it yet (its install dialog is still open).
    public static func read(appID: String, bottle: Bottle) -> SteamDownload? { read(appID: appID, home: SteamHome(bottle: bottle)) }

    public static func read(appID: String, home: SteamHome) -> SteamDownload? {
        for steamapps in home.libraryDirectories {
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            // Exact, from Steam's chunk lists; else estimated from the space the files take.
            let fetched = SteamDepotProgress.read(appID: appID, steamapps: steamapps, steamDirectory: home.steamDirectory)
            let written = fetched == nil ? allocatedSize(steamapps.appendingPathComponent("downloading/\(appID)")) : 0
            return parse(manifest: text, writtenSoFar: written, fetched: fetched)?
                .adjusted(for: SteamContentLog.updateActivity(appID: appID, home: home))
        }
        return nil
    }

    /// The manifest says "downloading" for a paused download too; Steam's log knows better.
    func adjusted(for activity: SteamContentLog.UpdateActivity?) -> SteamDownload {
        guard phase == .downloading, let activity, activity != .active else { return self }
        return SteamDownload(phase: activity == .paused ? .paused : .queued, bytesDone: bytesDone, bytesTotal: bytesTotal)
    }

    /// `writtenSoFar`: disk space taken by the files in `downloading/<id>` (unpacked data written so far).
    /// `fetched`: the chunks Steam's lists mark as had, and all of them (`SteamDepotProgress`); when known,
    /// `writtenSoFar` is ignored. For an update the lists mark the chunks still on disk as had from the start: those
    /// are all the chunks beyond `BytesToDownload`, so they're taken off before the share is worked out.
    static func parse(manifest text: String, writtenSoFar written: Int64 = 0, fetched: (done: Int64, total: Int64)? = nil,
                      now: Date = Date()) -> SteamDownload? {
        guard let state = try? VDFParser.parse(text)["AppState"] else { return nil }
        func number(_ key: String) -> Int64 { Int64(state[key]?.string ?? "") ?? 0 }
        let flags = Int(number("StateFlags"))
        let toDownload = number("BytesToDownload"), downloaded = number("BytesDownloaded")
        let toStage = number("BytesToStage"), staged = number("BytesStaged")
        let busy = flags & (updateRequired | updateRunning | updatePaused | updateStarted | downloading | staging
                            | committing | validating | preallocating) != 0

        // A just-started install can show "fully installed" for a moment before Steam marks it busy; with no files
        // on disk yet, it isn't.
        let empty = number("SizeOnDisk") == 0 && toDownload > 0 && downloaded < toDownload
        if flags & fullyInstalled != 0 && !busy && !empty {
            return SteamDownload(phase: .done, bytesDone: toDownload, bytesTotal: toDownload)
        }
        // Progress as a share of the unpacked size, shown in download bytes (what Steam's own window shows).
        let share = toStage > 0 ? min(1, Double(max(written, staged)) / Double(toStage)) : 0
        let done = fetched.map { max(downloaded, min(max(0, $0.done - max(0, $0.total - toDownload)), toDownload)) }
            ?? max(downloaded, Int64(share * Double(toDownload)))
        if flags & updatePaused != 0 {
            return SteamDownload(phase: .paused, bytesDone: done, bytesTotal: toDownload)
        }
        // Verifying and committing come after the download; "Staging" alone is set during it.
        if flags & (committing | validating) != 0 || (toDownload > 0 && downloaded >= toDownload) {
            return SteamDownload(phase: .installing, bytesDone: staged, bytesTotal: toStage)
        }
        // Steam keeps the manifest at 1026 (update required + update started) for the whole download: it doesn't
        // write its live Downloading/UpdateRunning bits there. Started means downloading; required alone, queued.
        if flags & (updateStarted | updateRunning | downloading | preallocating) != 0 {
            return SteamDownload(phase: .downloading, bytesDone: done, bytesTotal: toDownload)
        }
        if updateScheduledForLater(state, now: now) {
            return SteamDownload(phase: .done, bytesDone: toDownload, bytesTotal: toDownload)
        }
        return SteamDownload(phase: .queued, bytesDone: done, bytesTotal: toDownload)
    }

    /// An installed game whose update Steam put off until later ("ScheduledAutoUpdate", a time in the future, with
    /// nothing downloaded yet) isn't downloading or waiting in the queue: it plays as it is until then.
    public static func updateScheduledForLater(_ state: VDFValue, now: Date = Date()) -> Bool {
        func number(_ key: String) -> Int64 { Int64(state[key]?.string ?? "") ?? 0 }
        let flags = Int(number("StateFlags"))
        let live = flags & (updateRunning | updatePaused | updateStarted | downloading | staging | committing | validating | preallocating) != 0
        return flags & fullyInstalled != 0 && !live && number("BytesDownloaded") == 0
            && number("ScheduledAutoUpdate") > Int64(now.timeIntervalSince1970)
    }

    /// Steam's state bits for an app (`StateFlags` in its manifest), or nil when it has no manifest (not installed).
    public static func stateFlags(appID: String, bottle: Bottle) -> Int? { stateFlags(appID: appID, home: SteamHome(bottle: bottle)) }

    public static func stateFlags(appID: String, home: SteamHome) -> Int? {
        for steamapps in home.libraryDirectories {
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                  let flags = (try? VDFParser.parse(text))?["AppState"]?["StateFlags"]?.string else { continue }
            return Int(flags) ?? 0
        }
        return nil
    }

    /// Steam sets this bit while it deletes an app's files.
    public static let uninstalling = 2048

    /// Disk space the folder's files take (not their length, which preallocation sets to full size at once).
    static func allocatedSize(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
