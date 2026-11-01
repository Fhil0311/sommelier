// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Valve's Steam Deck test result for a game, as Steam caches it in `appinfo.vdf`.
public struct DeckCompatibility: Codable, Equatable, Sendable {
    /// 0 unknown, 1 unsupported, 2 playable, 3 verified.
    public let category: Int
    /// Test notes, e.g. `#SteamDeckVerified_TestResult_UnsupportedAntiCheat_Other`.
    public let tokens: [String]

    public init(category: Int, tokens: [String]) { self.category = category; self.tokens = tokens }
}

/// How well a game is likely to run in Sommelier: one answer to "will it run?", up to two notes that change what to
/// expect, and the reason behind the answer (which also says where it comes from).
///
/// Steam Deck runs Windows games through Wine (Proton), as Sommelier does, so Valve's Deck tests are a good first
/// guess. They're not the same setup (Linux and Vulkan there, macOS and Metal here), so they only make a game
/// "should work". What happened on this Mac, or a Mac version, makes it "works". Setting up DirectX 12 is an action,
/// not a rating, and isn't part of this.
public struct Compatibility: Equatable, Sendable {
    public enum Verdict: Int, Codable, Sendable, CaseIterable, Comparable {
        case works, likely, unknown, wontRun
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Note: String, Codable, Sendable, CaseIterable {
        /// Anti-cheat keeps online play closed on a Mac; single-player can still run.
        case noOnline
        /// A Mac version runs here, without Wine.
        case macVersion
        /// Too demanding for Steam Deck: a fast Mac may run it, a basic one may struggle.
        case demanding
    }

    public enum Reason: String, Codable, Sendable {
        case macVersion, playedHere, deckVerified, deckPlayable, deckTooDemanding, deckFails
        /// Other players' reports (or the team's own test) say it runs on a Mac, or that it doesn't.
        case players, playersFail
        /// Online-only, and its anti-cheat keeps Wine out.
        case onlineOnlyBlocked
        /// Anti-cheat closes online play; nothing is known about single-player.
        case offlineUnknown
        case noData

        public var fromSteamDeck: Bool { [.deckVerified, .deckPlayable, .deckTooDemanding, .deckFails].contains(self) }
    }

    public let verdict: Verdict
    public let notes: [Note]
    public let reason: Reason

    public init(_ verdict: Verdict, _ reason: Reason, notes: [Note] = []) {
        self.verdict = verdict; self.reason = reason; self.notes = notes
    }

    /// Whether to ask before installing.
    public var warnsBeforeInstall: Bool { verdict == .wontRun }

    /// - Parameters:
    ///   - deck: Valve's Steam Deck result.
    ///   - blocksOnlinePlay: the game's anti-cheat keeps Wine out on a Mac (`AntiCheat`).
    ///   - singlePlayer: whether the game has single-player (Steam's categories); nil when unknown.
    ///   - playedHere: play time on this Mac.
    ///   - macVersion: a Mac version that runs here exists or is installed.
    ///   - community: players' word from the service (`CommunityVerdictsService`), "works" or "wontRun" when it
    ///     decides. It beats every guess, but not what happened on this Mac.
    public static func rate(deck: DeckCompatibility?, blocksOnlinePlay: Bool = false, singlePlayer: Bool? = nil,
                            playedHere: TimeInterval = 0, macVersion: Bool = false, community: Verdict? = nil) -> Self {
        let tokens = deck?.tokens.joined(separator: " ") ?? ""
        // One answer for anti-cheat whichever source says so, so a game rates the same in every store.
        let antiCheat = tokens.contains("UnsupportedAntiCheat") || blocksOnlinePlay
        let demanding = deck?.category == 1 && tokens.contains("UnsupportedGraphicsPerformance")
        var notes: [Note] = []
        if antiCheat { notes.append(.noOnline) }
        if demanding { notes.append(.demanding) }

        if macVersion { return Self(.works, .macVersion, notes: [.macVersion]) }
        if playedHere > 60 { return Self(.works, .playedHere, notes: notes) }       // offline modes run past anti-cheat
        switch community {
        case .works?: return Self(.works, .players, notes: notes)
        case .wontRun?: return Self(.wontRun, .playersFail, notes: notes.filter { $0 != .noOnline })
        default: break
        }
        if antiCheat {
            if singlePlayer == false { return Self(.wontRun, .onlineOnlyBlocked) }
            switch deck?.category {
            case 3: return Self(.likely, .deckVerified, notes: notes)                 // the Deck result isn't the anti-cheat's
            case 2: return Self(.likely, .deckPlayable, notes: notes)
            default: return Self(.unknown, .offlineUnknown, notes: notes)
            }
        }
        switch deck?.category {
        case 3: return Self(.likely, .deckVerified)
        case 2: return Self(.likely, .deckPlayable)
        case 1: return demanding ? Self(.unknown, .deckTooDemanding, notes: notes) : Self(.wontRun, .deckFails)
        default: return Self(.unknown, .noData)
        }
    }
}
