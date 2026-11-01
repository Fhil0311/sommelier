// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct AnnouncementsTests {
    let json = #"""
    { "version": 1, "announcements": [
      { "id": "steam-outage", "level": "important", "title": { "en": "Steam sign-in is down", "ru": "Вход в Steam не работает" },
        "body": { "en": "Valve is fixing it." }, "link": { "url": "https://playsommelier.com/status", "label": { "en": "Details" } },
        "from": "2026-10-21T00:00:00Z", "until": "2026-10-23T00:00:00.000Z", "belowApp": "0.3", "games": ["steam:271590"], "notify": true },
      { "id": "future", "level": "critical", "title": { "en": "A level this version doesn't know" } },
      { "id": "hello", "level": "info", "title": { "en": "Welcome" } }
    ] }
    """#

    @Test func readsTheListAndSkipsWhatItCantRead() throws {
        let list = try AnnouncementList.decoder.decode(AnnouncementList.self, from: Data(json.utf8))
        #expect(list.announcements.map(\.id) == ["steam-outage", "hello"])
        #expect(list.announcements[0].link?.url.absoluteString == "https://playsommelier.com/status")
    }

    @Test func picksThePlayersLanguage() {
        let title = ["en": "Down", "ru": "Не работает", "zh": "不可用"]
        #expect(Announcement.text(title, languages: ["ru-RU", "en"]) == "Не работает")
        #expect(Announcement.text(title, languages: ["zh-Hans"]) == "不可用")
        #expect(Announcement.text(title, languages: ["ja"]) == "Down")
    }

    @Test func whoSeesIt() throws {
        let list = try AnnouncementList.decoder.decode(AnnouncementList.self, from: Data(json.utf8))
        let a = list.announcements[0]
        let during = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!
        #expect(a.applies(now: during, appVersion: "0.2.1", games: ["steam:271590"]))
        #expect(!a.applies(now: during, appVersion: "0.3.0", games: ["steam:271590"]))       // fixed in 0.3
        #expect(!a.applies(now: during, appVersion: "0.2.1", games: ["epic:Sage"]))          // doesn't have the game
        #expect(!a.applies(now: during.addingTimeInterval(86_400 * 3), appVersion: "0.2.1", games: ["steam:271590"]))   // over
        #expect(Announcement.compare("0.10", "0.9") == .orderedDescending)
        #expect(Announcement.compare("1.0", "1") == .orderedSame)
    }
}
