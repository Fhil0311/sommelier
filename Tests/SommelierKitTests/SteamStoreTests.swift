// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct SteamStoreTests {
    @Test func readsRecommendationsInOrder() {
        let html = #"<a data-ds-appid="292030"></a><a data-ds-appid="990080"><a data-ds-appid="1,2"><a data-ds-appid="990080"><a data-ds-appid="20920">"#
        #expect(SteamStore.recommended(in: html, excluding: "292030") == ["990080", "20920"])
    }

    @Test func readsGamesWithPrices() throws {
        let json = #"""
        {"response":{"store_items":[
          {"appid":1245620,"name":"ELDEN RING","type":0,"visible":true,
           "assets":{"asset_url_format":"steam/apps/1245620/${FILENAME}?t=1","library_capsule":"library_600x900.jpg"},
           "best_purchase_option":{"formatted_final_price":"$39.99"}},
          {"appid":1091500,"name":"Cyberpunk 2077","type":0,"visible":true},
          {"appid":5,"name":"Soundtrack","type":4}]}}
        """#
        let items = SteamStore.parseItems(Data(json.utf8), order: ["1091500", "1245620", "5"])
        #expect(items.map(\.name) == ["Cyberpunk 2077", "ELDEN RING"])
        #expect(items[0].price == nil)                                   // not sold in that country
        #expect(items[1].price == "$39.99")
        #expect(items[1].cover?.absoluteString == "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1245620/library_600x900.jpg?t=1")
    }
}
