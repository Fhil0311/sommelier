// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Tells which Steam game is running by reading the bottle's registry. Steam stores the running app's id in
/// `RunningAppID` (zero when idle) and Wine flushes `user.reg` to disk every few seconds, which is a more
/// reliable signal than watching Steam's processes.
public enum SteamRunningApp: Sendable {
    /// The registry text right before the value: `"RunningAppID"=dword:`, followed by 8 hex digits.
    private static let key = Data(#""RunningAppID"=dword:"#.utf8)

    /// The running game's Steam app id in decimal, or nil when nothing runs or the value isn't there.
    public static func parse(
        registry data: Data
    ) -> String? {
        guard let hit = data.range(of: key) else { return nil }
        let digits = data[hit.upperBound...].prefix(8)
        guard digits.count == 8,
              let text = String(data: digits, encoding: .ascii),
              let appID = UInt32(text, radix: 16), appID > 0 else { return nil }
        return String(appID)
    }

    /// Reads `user.reg` from the bottle; nil if it can't be read.
    public static func read(
        bottle: Bottle
    ) -> String? {
        let file = bottle.url.appendingPathComponent("user.reg")
        return (try? Data(contentsOf: file, options: .mappedIfSafe)).flatMap(parse(registry:))
    }
}
