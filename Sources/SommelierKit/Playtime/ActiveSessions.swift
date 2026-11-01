// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Games being played, kept on disk while they run so a session isn't lost when Sommelier quits, crashes or
/// restarts for an update in the middle of a game. On the next start Sommelier either follows the game again (it
/// is still running) or records the session up to the last moment it saw the game.
public struct ActiveSession: Codable, Equatable, Sendable {
    public var gameID: String
    public var start: Date
    /// The last time Sommelier saw the game running (updated every half minute).
    public var lastSeen: Date

    public init(gameID: String, start: Date, lastSeen: Date) {
        self.gameID = gameID; self.start = start; self.lastSeen = lastSeen
    }

    public enum Recovery: Equatable, Sendable {
        /// Still running: follow it again from its original start.
        case resume(since: Date)
        /// Over while Sommelier wasn't watching: record it as ending when it was last seen.
        case record(start: Date, end: Date)
        /// Nothing worth keeping (the game is gone from the library, or the data makes no sense).
        case drop
    }

    /// What to do with a session found at start-up.
    public func recovery(isRunning: Bool, gameKnown: Bool, now: Date = Date()) -> Recovery {
        guard gameKnown, start <= now, lastSeen >= start else { return .drop }
        if isRunning { return .resume(since: start) }
        return .record(start: start, end: min(lastSeen, now))
    }
}

/// `ActiveSessions.json`: the sessions under way, one per game.
public struct ActiveSessionStore: Sendable {
    let store: JSONStore<[ActiveSession]>

    public init(paths: Paths) { store = JSONStore(url: paths.home.appendingPathComponent("ActiveSessions.json")) }

    public func load() -> [ActiveSession] { store.load(default: []) }

    /// Adds the game's session, or moves its last-seen time on.
    public func update(gameID: String, start: Date, seen: Date = Date()) {
        var all = load().filter { $0.gameID != gameID }
        all.append(ActiveSession(gameID: gameID, start: start, lastSeen: seen))
        try? store.save(all)
    }

    public func remove(gameID: String) {
        let all = load()
        guard all.contains(where: { $0.gameID == gameID }) else { return }
        try? store.save(all.filter { $0.gameID != gameID })
    }
}
