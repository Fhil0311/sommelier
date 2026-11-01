// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Tells whether a Mac app installed in a folder is running: a game started natively (through Legendary or Steam
/// for Mac) isn't Sommelier's child, so it's found by the path of its executable.
enum NativeProcesses {
    /// The process running from inside `folder`, if any.
    static func pid(runningFrom folder: URL) -> Int32? {
        let prefix = folder.standardizedFileURL.path + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            if String(cString: buffer).hasPrefix(prefix) { return pid }
        }
        return nil
    }
}
