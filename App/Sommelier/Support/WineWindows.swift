// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Darwin
import SommelierKit

/// Tells when a Windows program started by Sommelier has put a real window on screen.
///
/// Wine's windows belong to processes whose executable lives in the engine folder, so they are told apart from
/// other apps (including other Wine-based launchers) by that path. Window titles need Screen Recording permission, so this only
/// looks at size: Wine keeps a few small helper windows around, a real one is bigger.
enum WineWindows {
    /// Layers a game's window can be on: the normal one, or the captured-display and status levels the Mac driver
    /// gives full-screen windows (`CGShieldingWindowLevel + 1`, `NSStatusWindowLevel + 1`). Menus, tooltips and the
    /// like sit on the levels in between (and are small anyway).
    static func isGameLayer(_ window: [String: Any]) -> Bool {
        guard let layer = window[kCGWindowLayer as String] as? Int else { return false }
        return layer == 0 || layer >= 25
    }

    static func hasVisibleWindow(enginesFolder: String, bottle: URL? = nil) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        var checked: [Int32: Bool] = [:]
        for window in list where isGameLayer(window) {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 300, (bounds["Height"] ?? 0) >= 200 else { continue }
            let ours = checked[pid] ?? (isEngineProcess(pid, enginesFolder: enginesFolder) && runs(pid, in: bottle))
            checked[pid] = ours
            if ours { return true }
        }
        return false
    }

    /// Whether the process runs in the environment (Wine prefix) `bottle`; any when nil. The process's arguments
    /// block carries its environment too, `WINEPREFIX` among it: Steam's windows aren't Ubisoft Connect's.
    static func runs(_ pid: Int32, in bottle: URL?) -> Bool {
        guard let bottle else { return true }
        let prefix = "WINEPREFIX=" + bottle.path               // as WineRunner.environment sets it
        let line = commandLine(of: pid)
        guard let range = line.range(of: prefix) else { return false }
        return range.upperBound == line.endIndex || line[range.upperBound] == " " || line[range.upperBound] == "/"
    }

    /// A game's window is up: a real window of an engine process whose command line contains `marker`. Steam games
    /// run from `steamapps` (Steam's own windows run from the Steam folder itself); Epic and GOG games from their
    /// install folder.
    static func hasGameWindow(enginesFolder: String, marker: String = "steamapps") -> Bool {
        gameWindowOwner(enginesFolder: enginesFolder, marker: marker) != nil
    }

    /// The process that owns the game's window (see `hasGameWindow`).
    static func gameWindowOwner(enginesFolder: String, marker: String = "steamapps") -> Int32? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in list where isGameLayer(window) {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 300, (bounds["Height"] ?? 0) >= 200,
                  isEngineProcess(pid, enginesFolder: enginesFolder) else { continue }
            if commandLine(of: pid).lowercased().contains(marker.lowercased()) { return pid }
        }
        return nil
    }

    /// A running Windows process of a game, found without its window: an engine process whose command line runs
    /// something from the game's folder (`folderName`, the last part of its install path).
    static func gameProcess(enginesFolder: String, folderName: String) -> Int32? {
        let name = folderName.lowercased()
        guard !name.isEmpty else { return nil }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(filled)) where pid > 0 && isEngineProcess(pid, enginesFolder: enginesFolder) {
            let line = commandLine(of: pid).lowercased()
            if line.contains("\\\(name)\\") || line.contains("/\(name)/") { return pid }
        }
        return nil
    }

    /// Every running engine process with its command line.
    static func programs(enginesFolder: String) -> [(pid: Int32, commandLine: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        return pids.prefix(Int(filled)).filter { $0 > 0 && isEngineProcess($0, enginesFolder: enginesFolder) }
            .map { ($0, commandLine(of: $0)) }
    }

    /// The engine process owning a real on-screen window whose command line passes `matches`.
    static func windowOwner(enginesFolder: String, where matches: (String) -> Bool) -> Int32? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in list where isGameLayer(window) {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 300, (bounds["Height"] ?? 0) >= 150,
                  isEngineProcess(pid, enginesFolder: enginesFolder), matches(commandLine(of: pid)) else { continue }
            return pid
        }
        return nil
    }

    /// Whether a window still exists, on screen or not (a minimised window counts).
    static func windowExists(_ number: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }

    /// The process's command line as `ps` shows it (Wine sets it to the Windows program's path).
    static func commandLine(of pid: Int32) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer[4..<size].map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
    }

    /// The newest real window of an engine process: (owner, window number). Window numbers only grow, so a
    /// number above one taken earlier means a window that appeared since.
    static func newestWindow(enginesFolder: String, bottle: URL? = nil) -> (pid: Int32, number: Int)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: (pid: Int32, number: Int)?
        var checked: [Int32: Bool] = [:]
        for window in list where isGameLayer(window) {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) >= 300, (bounds["Height"] ?? 0) >= 150 else { continue }
            let ours = checked[pid] ?? (isEngineProcess(pid, enginesFolder: enginesFolder) && runs(pid, in: bottle))
            checked[pid] = ours
            if ours, number > (best?.number ?? -1) { best = (pid, number) }
        }
        return best
    }

    /// Whether a window (by number) is still on screen.
    static func isOnScreen(_ number: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
    }

    /// A process the engine runs. Its executable is the engine's loader, either in the engine folder or, since the
    /// engine names each program's process after it, a link to it in `$TMPDIR/winetemp-…` or in the game's
    /// shortcut app (that folder also holds a link to the engine's ntdll.so, which tells which engine it is).
    static func isEngineProcess(_ pid: Int32, enginesFolder: String) -> Bool {
        let path = executable(of: pid)
        if path.hasPrefix(enginesFolder) { return true }
        // The engine also starts programs through a link to its loader, with an `ntdll.so` link beside it: in a
        // temporary folder (for the Dock name), or inside the game's shortcut app in ~/Applications/Sommelier Games
        // (so the Dock shows its icon). A game running from its shortcut is still ours; missing it made a running
        // game look closed as soon as some other window of the launch (a redistributable's installer) went away.
        guard path.contains("/winetemp-") || path.contains("/\(ShortcutApp.defaultFolder.lastPathComponent)/") else { return false }
        let folder = (path as NSString).deletingLastPathComponent
        linkLock.lock(); defer { linkLock.unlock() }
        if let known = linkFolders[folder] { return known }
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: folder + "/ntdll.so")) ?? ""
        let ours = target.hasPrefix(enginesFolder)
        linkFolders[folder] = ours
        return ours
    }

    /// Link folders already looked at (they only ever point at one engine); asked from background tasks too.
    nonisolated(unsafe) private static var linkFolders: [String: Bool] = [:]
    private static let linkLock = NSLock()

    static func executable(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }
}
