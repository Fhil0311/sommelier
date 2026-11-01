// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SommelierKit

@Suite struct TitleSearchTests {
    let titles = ["The Witcher 3: Wild Hunt — Remastered", "Cyberpunk 2077", "Elden Ring", "Age of Empires IV: Anniversary Edition",
                  "Hades II", "Hollow Knight", "Battlefield V"]
    func find(_ q: String) -> [String] { TitleSearch.matches(q, in: titles) { $0 } }

    @Test func exactWordsInAnyOrder() {
        #expect(find("witcher 3") == ["The Witcher 3: Wild Hunt — Remastered"])
        #expect(find("ring elden") == ["Elden Ring"])
    }

    @Test func spokenMistakesStillFind() {
        #expect(find("eldon ring").first == "Elden Ring")
        #expect(find("киберпанк").first == "Cyberpunk 2077")
        #expect(find("age of empires four").first == "Age of Empires IV: Anniversary Edition")
        #expect(find("hades two").first == "Hades II")
        #expect(find("hollow night").first == "Hollow Knight")
    }

    @Test func nonsenseFindsNothing() {
        #expect(find("zzz qqq").isEmpty)
        #expect(find("").isEmpty)
    }
}
