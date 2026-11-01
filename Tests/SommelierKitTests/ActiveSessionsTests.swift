// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct ActiveSessionsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aGameStillRunningIsFollowedAgain() {
        let s = ActiveSession(gameID: "steam:648800", start: start, lastSeen: start.addingTimeInterval(600))
        #expect(s.recovery(isRunning: true, gameKnown: true, now: start.addingTimeInterval(900)) == .resume(since: start))
    }

    @Test func aGameThatEndedMeanwhileCountsUntilLastSeen() {
        let s = ActiveSession(gameID: "steam:648800", start: start, lastSeen: start.addingTimeInterval(600))
        #expect(s.recovery(isRunning: false, gameKnown: true, now: start.addingTimeInterval(9000))
                == .record(start: start, end: start.addingTimeInterval(600)))
    }

    @Test func nonsenseIsDropped() {
        let s = ActiveSession(gameID: "steam:1", start: start, lastSeen: start.addingTimeInterval(-5))
        #expect(s.recovery(isRunning: false, gameKnown: true) == .drop)
        #expect(ActiveSession(gameID: "steam:1", start: start, lastSeen: start).recovery(isRunning: true, gameKnown: false) == .drop)
    }

    @Test func theStoreKeepsOneSessionPerGame() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = ActiveSessionStore(paths: Paths(home: home))
        store.update(gameID: "a", start: start, seen: start)
        store.update(gameID: "a", start: start, seen: start.addingTimeInterval(30))
        store.update(gameID: "b", start: start, seen: start)
        #expect(store.load().count == 2)
        #expect(store.load().first { $0.gameID == "a" }?.lastSeen == start.addingTimeInterval(30))
        store.remove(gameID: "a")
        #expect(store.load().map(\.gameID) == ["b"])
    }
}
