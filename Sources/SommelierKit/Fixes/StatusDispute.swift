// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The player saying a game rated "works" doesn't really run on their Mac: it doesn't start, a black screen that draws black frames,
/// a crash Sommelier didn't catch, too slow to play. Sommelier can't see these by itself.
public enum StatusDispute {
    public enum Problem: String, CaseIterable, Codable, Sendable {
        case doesNotStart, blackScreen, crashes, tooSlow, other

        /// The report's problem id, as the service's rule ids are written (`player-black-screen`).
        public var ruleID: String {
            switch self {
            case .doesNotStart: "player-does-not-start"
            case .blackScreen: "player-black-screen"
            case .crashes: "player-crashes"
            case .tooSlow: "player-too-slow"
            case .other: "player-other"
            }
        }
    }

    /// The longest note sent.
    public static let noteLimit = 500

    /// The note as it is sent: trimmed, cut to `noteLimit`, scrubbed of the Mac user's name and paths; nil when empty.
    public static func note(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return DiagnosticsCollector.scrub(String(trimmed.prefix(noteLimit)))
    }
}
