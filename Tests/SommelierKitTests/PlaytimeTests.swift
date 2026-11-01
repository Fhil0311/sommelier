// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct PlaytimeTotalsTests {
    /// Weeks start on Monday, in UTC, so the expectations don't depend on the machine running the tests.
    let calendar: Calendar = {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        utc.firstWeekday = 2
        return utc
    }()
    /// Wednesday, 7 October 2026, 12:00 UTC.
    let now = Date(timeIntervalSinceReferenceDate: 813_067_200)

    func played(_ game: String, daysAgo: Double, hours: Double) -> PlaySession {
        PlaySession(gameID: game, start: now - daysAgo * 86_400, duration: hours * 3_600)
    }

    @Test func weekCountsOnlyTheCurrentCalendarWeek() {
        let history = [played("steam:1", daysAgo: 1, hours: 2), played("steam:1", daysAgo: 10, hours: 5),
                       played("steam:1", daysAgo: 2.6, hours: 9)]   // Sunday before: last week
        let week = PlaytimeStats.perGame(sessions: history, allTime: [:], period: .week, now: now, calendar: calendar)
        #expect(week == [PlaytimeStats.GameTotal(gameID: "steam:1", seconds: 7_200)])
    }

    @Test func monthCountsFromTheFirstOfTheMonth() {
        let history = [played("gog:2", daysAgo: 6, hours: 1), played("gog:2", daysAgo: 7, hours: 3)]   // 1 Oct, 30 Sep
        let month = PlaytimeStats.perGame(sessions: history, allTime: [:], period: .month, now: now, calendar: calendar)
        #expect(month.map(\.seconds) == [3_600])
    }

    @Test func sessionsInTheFutureAreIgnoredForAPeriod() {
        let history = [played("epic:a", daysAgo: -0.1, hours: 1)]
        #expect(PlaytimeStats.perGame(sessions: history, allTime: [:], period: .week, now: now, calendar: calendar).isEmpty)
    }

    @Test func allTimeTakesTheLargerOfHistoryAndLibraryCounter() {
        let history = [played("epic:a", daysAgo: 1, hours: 2), played("steam:5", daysAgo: 400, hours: 4)]
        let library: [String: TimeInterval] = ["epic:a": 50 * 3_600, "gog:9": 3 * 3_600, "steam:5": 60, "ea:0": 0]
        let all = PlaytimeStats.perGame(sessions: history, allTime: library, period: .allTime, now: now, calendar: calendar)
        #expect(all.map(\.gameID) == ["epic:a", "steam:5", "gog:9"])
        let hours: [TimeInterval] = [50, 4, 3]
        #expect(all.map(\.seconds) == hours.map { $0 * 3_600 })
    }

    @Test func equalTotalsAreOrderedByID() {
        let history = [played("steam:2", daysAgo: 0.5, hours: 1), played("steam:1", daysAgo: 0.4, hours: 1),
                       played("gog:3", daysAgo: 0.3, hours: 4)]
        let order = PlaytimeStats.perGame(sessions: history, allTime: [:], period: .week, now: now, calendar: calendar).map(\.gameID)
        #expect(order == ["gog:3", "steam:1", "steam:2"])
    }

    @Test func storeTotalsSumAndSkipUnknownStores() {
        let games = [PlaytimeStats.GameTotal(gameID: "steam:1", seconds: 100), .init(gameID: "steam:2", seconds: 50),
                     .init(gameID: "epic:x", seconds: 120), .init(gameID: "weird:1", seconds: 999),
                     .init(gameID: "gog:1", seconds: 120)]
        #expect(PlaytimeStats.perStore(games) == [.init(store: .steam, seconds: 150), .init(store: .epic, seconds: 120),
                                                  .init(store: .gog, seconds: 120)])
    }

    @Test func weeklyListsEveryWeekOldestFirst() {
        let history = [played("steam:1", daysAgo: 1, hours: 2), played("steam:1", daysAgo: 15, hours: 3),
                       played("steam:1", daysAgo: 60, hours: 8)]
        let weeks = PlaytimeStats.weekly(sessions: history, weeks: 4, now: now, calendar: calendar)
        #expect(weeks.map(\.seconds) == [0, 3 * 3_600, 0, 2 * 3_600])
        #expect(weeks.last?.weekStart == Date(timeIntervalSince1970: 1_791_158_400))   // Monday 5 Oct, 00:00
        #expect(zip(weeks, weeks.dropFirst()).allSatisfy { $0.weekStart < $1.weekStart })
        #expect(PlaytimeStats.weekly(sessions: history, weeks: 0, now: now, calendar: calendar).isEmpty)
    }

    @Test func periodsAndStores() {
        #expect(PlaytimeStats.Period.allCases.map(\.title) == ["This week", "This month", "All time"])
        #expect(PlaytimeStats.periodStart(.allTime, now: now, calendar: calendar) == nil)
        #expect(PlaySession.store(of: "gog:99") == .gog)
        #expect(PlaySession.store(of: "no-store-here") == nil)
        #expect(played("ubisoft:5", daysAgo: 0, hours: 1).store == .ubisoft)
        #expect(PlaytimeStats.GameTotal(gameID: "battlenet:x", seconds: 1).store == .battlenet)
    }
}

@Suite struct SessionHistoryTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-sessions-\(UUID().uuidString)")

    func cleanUp() { try? FileManager.default.removeItem(at: home) }

    @Test func savesAndLoadsKeepingOnlyTheNewest() throws {
        defer { cleanUp() }
        let history = SessionStore(paths: Paths(home: home))
        #expect(history.load().isEmpty)

        let many = (0..<(SessionStore.maximumCount + 5)).map {
            PlaySession(gameID: "steam:\($0)", start: Date(timeIntervalSince1970: Double($0)), duration: 60)
        }
        history.save(many)
        let restored = history.load()
        #expect(restored.count == SessionStore.maximumCount)
        #expect(restored.first == many[5])
        #expect(restored.last == many.last)
    }

    @Test func fileHasTheSessionsShape() throws {
        defer { cleanUp() }
        let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        SessionStore(paths: Paths(home: home)).save([PlaySession(id: id, gameID: "gog:1", start: Date(timeIntervalSince1970: 1_800_000_000), duration: 90)])
        let raw = try Data(contentsOf: Paths(home: home).sessionsFile)
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: [[String: Any]]])
        let row = try #require(json["sessions"]?.first)
        #expect(row["id"] as? String == id.uuidString)
        #expect(row["gameID"] as? String == "gog:1")
        #expect(row["start"] as? String == "2027-01-15T08:00:00Z")
        #expect(row["duration"] as? Double == 90)
    }
}
