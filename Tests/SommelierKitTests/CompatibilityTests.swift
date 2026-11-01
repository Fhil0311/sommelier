// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct CompatibilityTests {
    func deck(_ category: Int, _ tokens: String...) -> DeckCompatibility {
        DeckCompatibility(category: category, tokens: tokens.map { "#SteamDeckVerified_TestResult_\($0)" })
    }

    func rate(_ deck: DeckCompatibility?, blocks: Bool = false, single: Bool? = nil, played: TimeInterval = 0, mac: Bool = false) -> Compatibility {
        Compatibility.rate(deck: deck, blocksOnlinePlay: blocks, singlePlayer: single, playedHere: played, macVersion: mac)
    }

    @Test func steamDeckResultsGiveAnAnswer() {
        #expect(rate(deck(3)) == Compatibility(.likely, .deckVerified))
        #expect(rate(deck(2, "TextInputDoesNotAutomaticallyInvokesKeyboard")) == Compatibility(.likely, .deckPlayable))
        #expect(rate(deck(1, "UnsupportedGraphicsPerformance")) == Compatibility(.unknown, .deckTooDemanding, notes: [.demanding]))
        #expect(rate(deck(1, "SteamOSDoesNotSupport")) == Compatibility(.wontRun, .deckFails))
        #expect(rate(deck(0)) == Compatibility(.unknown, .noData))
        #expect(rate(nil) == Compatibility(.unknown, .noData))
    }

    @Test func antiCheatSeparatesOnlineOnlyGames() {
        // Online-only (no single-player): won't run at all.
        #expect(rate(deck(1, "UnsupportedAntiCheat_Other"), single: false) == Compatibility(.wontRun, .onlineOnlyBlocked))
        #expect(rate(nil, blocks: true, single: false) == Compatibility(.wontRun, .onlineOnlyBlocked))
        // With single-player, or unknown: only online play is closed.
        #expect(rate(deck(1, "UnsupportedAntiCheatConfiguration"), single: true) == Compatibility(.unknown, .offlineUnknown, notes: [.noOnline]))
        #expect(rate(nil, blocks: true) == Compatibility(.unknown, .offlineUnknown, notes: [.noOnline]))
        // Valve's result for the rest of the game still counts when the anti-cheat comes from the list.
        #expect(rate(deck(3), blocks: true, single: true) == Compatibility(.likely, .deckVerified, notes: [.noOnline]))
        // The same game rates the same from either source (GTA V: Valve's Deck result on Steam, the list on Epic).
        #expect(rate(deck(1, "UnsupportedAntiCheat_Other"), single: true) == rate(nil, blocks: true, single: true))
    }

    @Test func playingHereAndMacVersionsBeatTheGuess() {
        #expect(rate(deck(1, "SteamOSDoesNotSupport"), played: 120) == Compatibility(.works, .playedHere))
        #expect(rate(nil, played: 90).verdict == .works)
        #expect(rate(nil, played: 30).verdict == .unknown)                              // a crash at start isn't "works"
        #expect(rate(nil, blocks: true, single: false, played: 600) == Compatibility(.works, .playedHere, notes: [.noOnline]))
        #expect(rate(deck(1, "SteamOSDoesNotSupport"), mac: true) == Compatibility(.works, .macVersion, notes: [.macVersion]))
    }

    @Test func orderAndWarnings() {
        #expect(Compatibility.Verdict.allCases.sorted() == Compatibility.Verdict.allCases)
        #expect(rate(deck(1, "SteamOSDoesNotSupport")).warnsBeforeInstall)
        #expect(!rate(nil).warnsBeforeInstall && !rate(nil, blocks: true).warnsBeforeInstall)
    }
}

struct AntiCheatTests {
    static let list = #"""
    [{"name":"Fall Guys: Ultimate Knockout","status":"Running","anticheats":["Easy Anti-Cheat"],"native":false,"storeIds":{"steam":"1097150"}},
     {"name":"Fortnite","status":"Denied","anticheats":["Easy Anti-Cheat"],"native":false,"storeIds":{}},
     {"name":"Rocket League (FACEIT)","status":"Broken","anticheats":["FACEIT"],"native":false,"storeIds":{}},
     {"name":"Some Native Game","status":"Supported","anticheats":["BattlEye"],"native":true,"storeIds":{"steam":"5"}},
     {"name":"Odd","status":"Whatever","anticheats":[],"storeIds":{}}]
    """#

    @Test func parsesAndFindsGames() throws {
        let entries = try AntiCheat.parse(Data(Self.list.utf8))
        #expect(entries.map(\.name) == ["Fall Guys: Ultimate Knockout", "Fortnite", "Rocket League (FACEIT)"])
        let index = AntiCheat.Index(entries)
        #expect(index.entry(steamAppID: nil, title: "Fall Guys")?.status == .running)        // Epic's name for it
        #expect(index.entry(steamAppID: "1097150", title: "anything")?.status == .running)
        #expect(index.entry(steamAppID: nil, title: "FORTNITE")?.status == .denied)
        #expect(index.entry(steamAppID: nil, title: "Rocket League") == nil)                  // a variant, not the game
        #expect(index.entry(steamAppID: "5", title: "Some Native Game") == nil)
        #expect(index.entry(steamAppID: "239140", title: "Fall Guys") == nil)               // has a Steam ID: never by title
    }

    @Test func ratesForAMac() {
        func entry(_ status: AntiCheat.Status, _ anticheat: String) -> AntiCheat.Entry {
            AntiCheat.Entry(name: "G", status: status, anticheats: [anticheat], steamAppID: nil)
        }
        #expect(entry(.denied, "BattlEye").blocksOnlinePlayOnMac)                  // GTA Online (story mode still runs)
        #expect(entry(.broken, "XIGNCODE3").blocksOnlinePlayOnMac)
        #expect(entry(.running, "Easy Anti-Cheat").blocksOnlinePlayOnMac)          // Fall Guys: Steam Deck yes, Mac no
        #expect(!entry(.supported, "VAC").blocksOnlinePlayOnMac)                   // Counter-Strike runs fine

    }

    @Test func playersWordBeatsGuessesButNotThisMac() {
        let failsOnDeck = DeckCompatibility(category: 1, tokens: [])
        #expect(Compatibility.rate(deck: failsOnDeck, community: .works) == Compatibility(.works, .players))
        #expect(Compatibility.rate(deck: DeckCompatibility(category: 3, tokens: []), community: .wontRun) == Compatibility(.wontRun, .playersFail))
        #expect(Compatibility.rate(deck: nil, playedHere: 600, community: .wontRun).reason == .playedHere)     // this Mac wins
        #expect(Compatibility.rate(deck: nil, macVersion: true, community: .wontRun).reason == .macVersion)
        let antiCheat = Compatibility.rate(deck: nil, blocksOnlinePlay: true, community: .works)
        #expect(antiCheat.verdict == .works && antiCheat.notes == [.noOnline])
        #expect(Compatibility.rate(deck: nil, community: .unknown).reason == .noData)                        // only works/wontRun decide
    }

    @Test func verdictsListKeepsOnlyAnswersItKnows() throws {
        let json = #"{"version": 1, "games": {"steam:1": "works", "gog:2": "wontRun", "epic:3": "maybe"}}"#
        let list = try JSONDecoder().decode(CommunityVerdictsList.self, from: Data(json.utf8))
        #expect(list.byGame == ["steam:1": .works, "gog:2": .wontRun])
    }
}
