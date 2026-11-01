// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A single play of a game: when it began and how long it lasted. `gameID` is "<store>:<id>", e.g.
/// "steam:268910". The property names are the JSON keys in `Sessions.json`.
public struct PlaySession: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID, gameID: String
    public var start: Date, duration: TimeInterval

    public init(
        id: UUID = UUID(), gameID: String, start: Date, duration: TimeInterval
    ) {
        (self.id, self.gameID) = (id, gameID)
        (self.start, self.duration) = (start, duration)
    }

    /// The store this session's game belongs to.
    public var store: StoreKind? { Self.store(of: gameID) }

    /// The store named before the first ":" of a game id, if it is one Sommelier knows.
    public static func store(
        of gameID: String
    ) -> StoreKind? {
        let prefix = gameID.firstIndex(of: ":").map { gameID[..<$0] } ?? gameID[...]
        return StoreKind(rawValue: String(prefix))
    }
}

/// The shape of `Sessions.json`: `{"sessions": [...]}`.
public struct SessionFile: Equatable, Codable, Sendable {
    public var sessions = [PlaySession]()
    public init() {}
}

/// Reads and writes the play history in `Sessions.json`.
public struct SessionStore: Sendable {
    /// Plays shorter than this don't count; usually the game failed to start.
    public static let minimumDuration = TimeInterval(10)
    /// Upper bound on stored sessions. The oldest are dropped first so the file stays small.
    public static let maximumCount: Int = 20_000

    let store: JSONStore<SessionFile> // Sessions.json

    public init(paths folders: Paths) {
        store = JSONStore(url: folders.sessionsFile)
    }

    public func load() -> [PlaySession] {
        store.load(default: SessionFile()).sessions
    }

    /// Saves the newest `maximumCount` sessions. Failing to write the history is not worth an error.
    public func save(_ history: [PlaySession]) {
        var contents = SessionFile()
        contents.sessions = Array(history.suffix(Self.maximumCount))
        try? store.save(contents)
    }
}

/// Playtime totals for the stats screen, computed from sessions without touching disk.
public enum PlaytimeStats: Sendable {
    /// The time range a total covers: the current calendar week or month, or everything.
    public enum Period: String, Identifiable, CaseIterable, Sendable {
        case week, month
        case allTime

        public var id: String { self.rawValue }

        public var title: String { Self.titles[self] ?? rawValue }

        private static let titles: [Period: String] = [.week: "This week", .month: "This month", .allTime: "All time"]
    }

    /// Seconds played of one game.
    public struct GameTotal: Identifiable, Equatable, Sendable {
        public var gameID: String, seconds: TimeInterval
        public var id: String { self.gameID }
        public var store: StoreKind? { PlaySession.store(of: self.gameID) }
    }

    /// Seconds played across one store's games.
    public struct StoreTotal: Identifiable, Equatable, Sendable {
        public var store: StoreKind, seconds: TimeInterval
        public var id: StoreKind { self.store }
    }

    /// Seconds played in one calendar week.
    public struct WeekTotal: Identifiable, Equatable, Sendable {
        public var weekStart: Date, seconds: TimeInterval
        public var id: Date { self.weekStart }
    }

    /// Time per game in `period`, most played first (ties by id). For all time, a game's total is the larger
    /// of its recorded sessions and `allTime`, the library's own counter that predates session tracking.
    public static func perGame(
        sessions: [PlaySession], allTime: [String: TimeInterval], period: Period,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [GameTotal] {
        let from = periodStart(period, now: now, calendar: calendar)
        var played: [String: TimeInterval] = [:]
        for session in sessions {
            if let from, session.start < from || session.start > now { continue }
            played[session.gameID, default: 0] += session.duration
        }
        if from == nil {
            for (game, total) in allTime { played[game] = max(played[game] ?? 0, total) }
        }
        return played.compactMap { game, total in total > 0 ? GameTotal(gameID: game, seconds: total) : nil }
            .sorted { ($1.seconds, $0.gameID) < ($0.seconds, $1.gameID) }
    }

    /// Game totals summed per store, biggest first (ties by store name). Games of unknown stores are left out.
    public static func perStore(
        _ games: [GameTotal]
    ) -> [StoreTotal] {
        var sums: [StoreKind: TimeInterval] = [:]
        for game in games {
            guard let kind = game.store else { continue }
            sums[kind, default: 0] += game.seconds
        }
        return sums.map { StoreTotal(store: $0.key, seconds: $0.value) }
            .sorted { ($1.seconds, $0.store.rawValue) < ($0.seconds, $1.store.rawValue) }
    }

    /// One total per calendar week for the last `weeks` weeks, oldest first, including weeks with no play.
    /// A session counts toward the week it started in.
    public static func weekly(
        sessions: [PlaySession], weeks: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> [WeekTotal] {
        guard weeks > 0, let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let starts = stride(from: weeks - 1, through: 0, by: -1).compactMap {
            calendar.date(byAdding: .weekOfYear, value: -$0, to: current)
        }
        var byWeek = [Date: TimeInterval](uniqueKeysWithValues: starts.map { ($0, 0) })
        for session in sessions {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: session.start)?.start,
                  let sum = byWeek[week] else { continue }
            byWeek[week] = sum + session.duration
        }
        return starts.map { WeekTotal(weekStart: $0, seconds: byWeek[$0, default: 0]) }
    }

    /// When the current calendar week or month began; nil for all time.
    static func periodStart(
        _ period: Period, now: Date, calendar: Calendar
    ) -> Date? {
        let unit: Calendar.Component
        switch period {
        case .week: unit = .weekOfYear
        case .month: unit = .month
        case .allTime: return nil
        }
        return calendar.dateInterval(of: unit, for: now)?.start
    }
}
