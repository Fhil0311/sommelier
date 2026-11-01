// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads app states from Steam's `logs/content_log.txt`, where Steam writes a line each time a game's state
/// changes, e.g. `[2026-10-19 20:19:05] AppID 588430 state changed : Fully Installed,App Running,`.
/// A Play click only hands the game to the running Steam and exits at once, so this is how a launch is followed.
/// Steam writes the line as the game starts, sooner than the registry value in `SteamRunningApp`.
public enum SteamContentLog {
    public static func file(in bottle: Bottle) -> URL { SteamHome(bottle: bottle).log("content_log.txt") }

    /// Whether the game was running at its latest state line in `text`; nil when the text has no line for it.
    public static func isRunning(appID: String, in text: Substring) -> Bool? {
        let marker = "AppID \(appID) state changed : "
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let rest = text[range.upperBound...]
        let line = rest[..<(rest.firstIndex(where: \.isNewline) ?? rest.endIndex)]
        return line.contains("App Running")
    }

    /// The log's current length: pass it as `since` to ignore lines written before a launch.
    public static func length(bottle: Bottle) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: file(in: bottle).path)[.size]) as? UInt64) ?? 0
    }

    /// Reads the end of the log (it only grows during a session) and answers `isRunning` for the game.
    /// With `since`, only lines written after that offset count (Steam starts a new log when it restarts).
    public static func isRunning(appID: String, bottle: Bottle, since: UInt64? = nil, tailBytes: Int = 256 * 1024) -> Bool? {
        tail(file: file(in: bottle), since: since, bytes: tailBytes).flatMap { isRunning(appID: appID, in: $0) }
    }

    /// What Steam is doing with a game's download. The app manifest can't tell: Steam leaves it at "update started"
    /// when the user pauses, and only the log says the update stopped.
    public enum UpdateActivity: Equatable, Sendable { case active, paused, idle }

    /// From the latest `App update changed : …` line: anything running is active; `None` is paused when Steam
    /// suspended the update (the user paused it), else idle (waiting in Steam's queue).
    public static func updateActivity(appID: String, in text: Substring) -> UpdateActivity? {
        guard let update = lastLine(containing: "AppID \(appID) App update changed : ", in: text) else { return nil }
        if update.line.trimmingCharacters(in: .whitespacesAndNewlines) != "None" { return .active }
        // Steam writes the state line right after: "Update Required,Update Queued,Update Started, (Suspended)".
        let state = lastLine(containing: "AppID \(appID) state changed : ", in: text[update.end...])
        return state?.line.contains("(Suspended)") == true ? .paused : .idle
    }

    public static func updateActivity(appID: String, bottle: Bottle) -> UpdateActivity? {
        updateActivity(appID: appID, home: SteamHome(bottle: bottle))
    }

    public static func updateActivity(appID: String, home: SteamHome) -> UpdateActivity? {
        tail(file: home.log("content_log.txt"), since: nil, bytes: 512 * 1024).flatMap { updateActivity(appID: appID, in: $0) }
    }

    /// The text after the last `marker` up to the end of its line, and where that line ends.
    private static func lastLine(containing marker: String, in text: Substring) -> (line: Substring, end: Substring.Index)? {
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let rest = text[range.upperBound...]
        let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
        return (rest[..<end], end)
    }

    // MARK: Launch steps (console_log.txt)

    /// Steam's `logs/console_log.txt`, where it writes each step of a launch:
    /// `[…] GameAction [AppID 1903340, ActionID 7] : LaunchApp changed task to SynchronizingControllerConfig with ""`.
    public static func consoleFile(in bottle: Bottle) -> URL { SteamHome(bottle: bottle).log("console_log.txt") }

    public static func consoleLength(bottle: Bottle) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: consoleFile(in: bottle).path)[.size]) as? UInt64) ?? 0
    }

    /// Where Steam is with a game's launch: the last launch-step line for the game.
    public struct LaunchStep: Equatable, Sendable {
        /// The whole line after the timestamp, to tell when it changes.
        public var line: String
        /// Steam waits for the player (a dialog: an agreement, a cloud conflict): not stuck.
        public var waitingForPlayer: Bool
        /// The launch has handed the game over (or finished): Steam is done with it.
        public var done: Bool
        /// Steam downloads the game's update before starting it ("DownloadingDepots"): long, and not stuck.
        public var updating: Bool = false
        /// Steam runs the game's install scripts ("RunningInstallScript": first-time setup such as runtimes or the
        /// game's own launcher). Can take minutes on a game's first launch in a new environment: not stuck.
        public var installing: Bool = false
    }

    public static func launchStep(appID: String, in text: Substring) -> LaunchStep? {
        guard let found = lastLine(containing: "GameAction [AppID \(appID), ", in: text) else { return nil }
        let line = String(found.line)
        let waiting = line.contains("waiting for user response")
        let done = line.contains("task to Completed") || line.contains("task to WaitingGameWindow") || line.contains("task to None")
        let updating = line.contains("task to DownloadingDepots") || line.contains("task to UpdatingApp")
        let installing = line.contains("task to RunningInstallScript")
        return LaunchStep(line: line, waitingForPlayer: waiting, done: done, updating: updating, installing: installing)
    }

    public static func launchStep(appID: String, bottle: Bottle, since: UInt64) -> LaunchStep? {
        tail(file: consoleFile(in: bottle), since: since, bytes: 128 * 1024).flatMap { launchStep(appID: appID, in: $0) }
    }

    private static func tail(file: URL, since: UInt64?, bytes: Int) -> Substring? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        if let since, since <= size { start = max(start, since) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return Substring(String(decoding: data, as: UTF8.self))
    }
}
