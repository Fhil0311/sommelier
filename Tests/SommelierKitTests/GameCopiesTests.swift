// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct GameCopiesTests {
    static func game(_ store: StoreKind, _ id: String, _ title: String, installed: Bool = false) -> Game {
        Game(store: store, storeID: id, title: title, isInstalled: installed)
    }

    @Test func sameSteamGameIsOneEntry() {
        let steam = Self.game(.steam, "49520", "Borderlands 2")
        let epic = Self.game(.epic, "Dodo", "Borderlands 2")
        let gog = Self.game(.gog, "1", "Borderlands 2")
        let groups = GameCopies.group([steam, epic, gog]) { $0.store == .epic ? "49520" : nil }
        #expect(groups.count == 1)
        #expect(groups[0].map(\.store) == [.steam, .epic, .gog])        // GOG joined by title: it has no Steam ID
    }

    @Test func titlesDontJoinDifferentSteamGames() {
        let old = Self.game(.steam, "17430", "Need for Speed: Most Wanted")
        let new = Self.game(.epic, "x", "Need for Speed: Most Wanted")
        #expect(GameCopies.group([old, new]) { _ in "1262560" }.count == 2)
        // Two copies in one store aren't one game either.
        #expect(GameCopies.group([Self.game(.epic, "a", "Same"), Self.game(.epic, "b", "Same")]) { _ in nil }.count == 2)
    }

    @Test func showsTheCopyYouUse() {
        let steam = Self.game(.steam, "1", "G"), epic = Self.game(.epic, "e", "G", installed: true)
        #expect(GameCopies.preferred([steam, epic]) { _ in nil }?.store == .epic)                     // installed wins
        #expect(GameCopies.preferred([Self.game(.epic, "e", "G"), steam]) { _ in nil }?.store == .steam)   // then Steam first
        let played = Self.game(.gog, "g", "G")
        #expect(GameCopies.preferred([steam, played]) { $0.store == .gog ? Date() : nil }?.store == .gog)
    }
}
