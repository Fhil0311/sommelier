// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct TitleMatchingTests {
    func key(_ title: String) -> String { GameInfoService.normalized(title) }

    @Test func punctuationAndMarksDontMatter() {
        #expect(key("Tom Clancy's Rainbow Six® Siege") == key("Tom Clancy’s Rainbow Six Siege"))
        #expect(key("DOOM: The Dark Ages") == "doomthedarkages")
        #expect(key("Ratchet & Clank") == "ratchetandclank")
        #expect(key("Café 2") == "caf2")                            // only ASCII letters and digits stay
    }

    @Test func differentWordsStillDiffer() {
        #expect(key("Hades II") != key("Hades"))
    }

    @Test func storeLanguagesFollowTheApp() {
        #expect(GameInfoService.steamLanguage(for: "ru") == "russian")
        #expect(GameInfoService.steamLanguage(for: "zh-Hant-TW") == "tchinese")
        #expect(GameInfoService.steamLanguage(for: "pt-BR") == "brazilian")
        #expect(GameInfoService.steamLanguage(for: "en") == "english")
        #expect(GameInfoService.steamLanguage(for: "xx") == "english")
    }
}

@Suite struct StoreDetailsTests {
    /// An `appdetails` answer for app 1 with the given `data` fields.
    func answer(_ fields: String) -> Data {
        Data(#"{"1":{"success":true,"data":{\#(fields)}}}"#.utf8)
    }

    @Test func readsAFullAnswer() throws {
        let json = #"""
        {"504230":{"success":true,"data":{
          "short_description":"<i>Climb</i> the mountain &amp; face yourself.",
          "developers":["Maddy Makes Games"],"publishers":["Maddy Makes Games","Extremely OK Games"],
          "release_date":{"coming_soon":false,"date":"25 Jan, 2018"},
          "genres":[{"id":"23","description":"Indie"},{"id":"1","description":"Action"}],
          "categories":[{"id":9,"description":"Co-op"},{"id":2,"description":"Single-player"}],
          "controller_support":"partial","metacritic":{"score":92},
          "screenshots":[{"id":0,"path_full":"https://img.example/a.jpg"},{"id":1,"path_full":"https://img.example/b.jpg"}],
          "movies":[{"id":7,"thumbnail":"https://img.example/first.jpg","hls_h264":"https://vid.example/first.m3u8"},
                    {"id":8,"thumbnail":"https://img.example/main.jpg","hls_h264":"https://vid.example/main.m3u8","highlight":true}]}}}
        """#
        let celeste = try #require(try GameInfoService.parseDetails(Data(json.utf8), appID: "504230"))
        #expect(celeste.steamAppID == "504230")
        #expect(celeste.summary == "Climb the mountain & face yourself.")
        #expect(celeste.developers + celeste.publishers == ["Maddy Makes Games", "Maddy Makes Games", "Extremely OK Games"])
        #expect(celeste.releaseDate == "25 Jan, 2018")
        #expect(celeste.genres == ["Indie", "Action"])
        #expect(celeste.players == [.single, .coop])                       // in a fixed order, not Steam's
        #expect(celeste.controllerSupport == "partial" && celeste.metacritic == 92)
        #expect(celeste.screenshots.map(\.lastPathComponent) == ["a.jpg", "b.jpg"])
        #expect(celeste.trailerChecked == true)
        #expect(celeste.trailerURL?.lastPathComponent == "main.m3u8")      // the highlighted movie wins
        #expect(celeste.trailerThumbnail?.lastPathComponent == "main.jpg")
        let art = [celeste.logoURL, celeste.heroURL, celeste.coverURL].map { $0?.lastPathComponent }
        #expect(art == ["logo.png", "library_hero.jpg", "library_600x900.jpg"])
    }

    @Test func aStoreWithoutTheAppGivesNothing() throws {
        #expect(try GameInfoService.parseDetails(Data(#"{"7":{"success":false}}"#.utf8), appID: "7") == nil)
        #expect(try GameInfoService.parseDetails(answer(#""short_description":"x""#), appID: "2") == nil)
    }

    @Test func olderAnswersLinkMP4FilesAndEmptyTextIsDropped() throws {
        let fields = #""short_description":"  ","release_date":{"date":""},"movies":[{"thumbnail":"https://e.x/s.jpg","mp4":{"max":"https://e.x/m.mp4"}}]"#
        let info = try #require(try GameInfoService.parseDetails(answer(fields), appID: "1"))
        #expect(info.summary == nil)
        #expect(info.releaseDate == nil)
        #expect(info.trailerURL?.lastPathComponent == "m.mp4")
    }

    @Test func multiplayerCategories() throws {
        let fields = #""categories":[{"id":49,"description":"PvP"},{"id":"36","description":"Online PvP"}]"#
        let info = try #require(try GameInfoService.parseDetails(answer(fields), appID: "1"))
        #expect(info.players == [.multi, .online])
    }

    @Test func profilesFromOlderVersionsStillLoad() throws {
        let profile = try JSONDecoder().decode(LaunchProfile.self, from: Data(#"{"backend":"dxvk","performanceHUD":true}"#.utf8))
        #expect(profile.backend == .dxvk && profile.performanceHUD && !profile.retina && profile.rayTracing && !profile.metalFX)
    }
}

@Suite struct DirectXRequirementTests {
    @Test func findsTheVersionInAnyLanguage() {
        let blocks = [
            "<ul><li><strong>DirectX:</strong> Version 12</li></ul>": 12,
            "<li><strong>DirectX:</strong> версии 12<br></li>": 12,
            "<li><strong>DirectX 版本：</strong> 12</li>": 12,
            "<strong>DirectX:</strong> Version 11<br>": 11,
            "<strong>Graphics:</strong> GTX 970<br>": 0,
        ]
        for (html, version) in blocks {
            #expect(GameInfoService.directXVersion(in: html) == version, "\(html)")
        }
    }

    @Test func requirementsAsAnObjectOrAnEmptyArray() throws {
        func details(_ requirements: String) -> Data {
            Data(#"{"1":{"success":true,"data":{"short_description":"x","pc_requirements":\#(requirements)}}}"#.utf8)
        }
        let listed = try GameInfoService.parseDetails(details(#"{"minimum":"<strong>DirectX:</strong> Version 12","recommended":"x"}"#), appID: "1")
        #expect(listed?.minimumDirectX == 12)
        let none = try GameInfoService.parseDetails(details("[]"), appID: "1")
        #expect(none?.minimumDirectX == 0)
        #expect(none?.summary == "x")
    }

    @Test func storeMarkupBecomesText() {
        #expect(GameInfoService.plainText("  <p>Tom &amp; Jerry&#39;s &quot;Show&quot;&nbsp;</p> ") == #"Tom & Jerry's "Show""#)
        #expect(GameInfoService.plainText("&amp;lt;") == "&lt;")
    }
}

@Suite struct DeckReportTests {
    @Test func readsVerifiedAndUntestedReports() throws {
        let rated = ##"{"success":1,"results":{"appid":1262560,"resolved_category":2,"resolved_items":[{"display_type":4,"loc_token":"#SteamDeckVerified_TestResult_DefaultControllerConfigNotFullyFunctional"}],"steam_deck_blog_url":""}}"##
        let deck = try GameInfoService.parseDeckReport(Data(rated.utf8))
        #expect(deck.category == 2)
        #expect(deck.tokens == ["#SteamDeckVerified_TestResult_DefaultControllerConfigNotFullyFunctional"])

        let untested = #"{"success":1,"results":{"resolved_category":0,"resolved_items":[]}}"#
        #expect(try GameInfoService.parseDeckReport(Data(untested.utf8)).category == 0)
        #expect(try GameInfoService.parseDeckReport(Data(#"{"success":2}"#.utf8)) == DeckCompatibility(category: 0, tokens: []))
    }

    @Test func cachesFromBeforeTheDeckFieldStillLoad() throws {
        let cached = #"{"developers":[],"publishers":[],"genres":[],"players":[],"screenshots":[],"minimumDirectX":11,"fetched":"2026-10-01T00:00:00Z"}"#
        let reader = JSONDecoder()
        reader.dateDecodingStrategy = .iso8601
        let info = try reader.decode(GameInfo.self, from: Data(cached.utf8))
        #expect(info.deck == nil && info.deckChecked == nil)
        #expect(info.minimumDirectX == 11)
    }
}
