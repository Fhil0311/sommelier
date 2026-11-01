// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Whether a session ended in a crash, from what it left behind rather than from how long it lasted: a game that
/// shows its window and dies in the menu, or hangs on a black screen until the player gives up, is a failed launch
/// too. The signs are Wine's own record of a program dying, macOS's crash report, and DXMT's frame counter.
public enum CrashSigns {
    /// What Wine writes when a Windows program dies: the exception it caught and the backtrace that follows.
    static let pattern = try! NSRegularExpression(pattern: #"wine: Unhandled |Unhandled exception: |^Backtrace:|err:seh:|exception code 0xc0000005|exception code 0xc000001d|wine: terminating on signal"#,
                                                  options: [.anchorsMatchLines])

    /// Wine's marks of a crash in this text (the part of the log written during the session). With `naming`, the
    /// crash must be the game's: Wine's backtrace lists the modules with their paths, so the game's folder name
    /// shows up after the mark, while a crash of Steam's own helper (sharing the log) names Steam's folders.
    public static func inLog(_ text: String, naming folderName: String? = nil) -> Bool {
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return false }
        guard let folderName, !folderName.isEmpty else { return true }
        let rest = text[range.lowerBound...].prefix(64 * 1024)
        return rest.lowercased().contains(folderName.lowercased())
    }

    /// A game that has run for a while with its window up and never presented a frame hung: DXMT's counter wrote
    /// its files from the swap chain's creation, and every one says nothing was presented. No files means nothing
    /// is known (D3DMetal and OpenGL games aren't counted).
    public static func hung(frames samples: [FrameStats.Sample], windowSeen: Bool, secondsRunning: TimeInterval, after: TimeInterval = 90) -> Bool {
        guard windowSeen, secondsRunning >= after, !samples.isEmpty else { return false }
        return samples.allSatisfy { $0.presented == 0 }
    }

    /// A Metal game (D3DMetal) that has run for a while with its window up and had the Mac driver show not one frame
    /// hung: `drawers` are the executables that drew since it started (`LiveFrameRate.drawers`), `isGame` tells
    /// the game's own apart from a launcher's.
    public static func drewNothing(drawers: [String], isGame: (String) -> Bool, windowSeen: Bool, secondsRunning: TimeInterval,
                                   after: TimeInterval = 90) -> Bool {
        guard windowSeen, secondsRunning >= after else { return false }
        return !drawers.contains(where: isGame)
    }

    /// The part of a log file written after `offset` (what the session added to a log a launcher keeps across
    /// sessions), up to `bytes`.
    public static func appended(to url: URL, after offset: UInt64, bytes: Int = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return "" }
        let start = size - offset > UInt64(bytes) ? size - UInt64(bytes) : offset
        try? handle.seek(toOffset: start)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// A file's size now, for `appended(to:after:)` later.
    public static func size(of url: URL?) -> UInt64 {
        guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? UInt64) ?? UInt64((attributes[.size] as? Int) ?? 0)
    }
}
