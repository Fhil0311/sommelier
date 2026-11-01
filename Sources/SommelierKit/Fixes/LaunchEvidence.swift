// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Keeps a failed launch's evidence to the game's own: Steam writes all of a session's programs into one log, and
/// its own logs carry every game's lines. Wine marks each line with its process (`WINEDEBUG=+pid`:
/// "0554:0024:err:…", the Windows process id first), and Steam notes which processes are a game's.
public enum LaunchEvidence {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// The time at the start of a Steam log line ("[2026-10-22 20:20:04] …").
    static func time(of line: Substring) -> Date? {
        guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
        return stamp.date(from: String(line[line.index(after: line.startIndex)..<end]))
    }

    /// Lines of Steam's logs about this app (`AppID 1903340`) written since `since`.
    public static func appLines(_ text: String, appID: String, since: Date) -> [Substring] {
        let marker = "AppID \(appID)"
        return text.split(whereSeparator: \.isNewline).filter { line in
            guard line.contains(marker), let t = time(of: line) else { return false }
            return t >= since.addingTimeInterval(-2)
        }
    }

    /// The Windows process ids Steam tracked for the app since `since` ("AppID 1903340 adding PID 1364 as a
    /// tracked process", "Game process added : AppID 1903340 … ProcID 1348").
    public static func steamProcessIDs(appID: String, logs: [String], since: Date) -> Set<Int> {
        let patterns = [#"adding PID (\d+)"#, #"ProcID (\d+)"#].compactMap { try? NSRegularExpression(pattern: $0) }
        var out = Set<Int>()
        for text in logs {
            for line in appLines(text, appID: appID, since: since) {
                let s = String(line)
                for regex in patterns {
                    if let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s), let pid = Int(s[r]) {
                        out.insert(pid)
                    }
                }
            }
        }
        return out
    }

    static let wineLine = try! NSRegularExpression(pattern: #"^([0-9a-f]{4}):(?:([0-9a-f]{4}):)?(?:err|warn|fixme|trace|info):"#)

    /// The lines of `text` that are the game's: Wine lines of its processes, and lines that aren't Wine's at all
    /// (the game's own output, DXMT's, Sommelier's markers). Wine lines of other processes, or without a process
    /// (written before `+pid`), are left out.
    public static func ownLines(_ text: String, processIDs: Set<Int>) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let s = String(line)
            guard let m = wineLine.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return true }
            // "0554:0024:err:" has the process first; "0024:err:" (no +pid) can't be told apart: left out.
            guard m.range(at: 2).location != NSNotFound, let first = Range(m.range(at: 1), in: s) else { return false }
            return Int(s[first], radix: 16).map(processIDs.contains) ?? false
        }.joined(separator: "\n")
    }
}
