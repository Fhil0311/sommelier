// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit

/// "Similar Games" on a game's page: Steam's recommendations for it, with the user's own copies where they have one.
extension AppModel {
    enum SimilarPick: Identifiable {
        case owned(Game)
        case store(SteamStore.Item)
        var id: String {
            switch self {
            case .owned(let game): game.id
            case .store(let item): "store:\(item.appID)"
            }
        }
    }

    /// The game's Steam app id: its own, or the Steam match of a game from another store.
    func steamAppID(of game: Game) -> String? { game.store == .steam ? game.storeID : info[game.id]?.steamAppID }

    /// Fetches the recommendations once per game per run: Steam's list, then names, covers and prices for the
    /// user's region (the Mac's region, which is the Steam store's region for nearly everyone).
    func loadSimilar(to game: Game) async {
        guard let appID = steamAppID(of: game), similarItems[appID] == nil else { return }
        similarItems[appID] = []                                   // asked: don't ask again while this runs
        let ids = Array(await SteamStore.moreLike(appID: appID).prefix(30))   // many aren't sold in every region
        let country = Locale.current.region?.identifier ?? "US"
        let language = GameInfoService.steamLanguage(for: Bundle.main.preferredLocalizations.first ?? "en")
        similarItems[appID] = await SteamStore.items(ids, country: country, language: language)
        #if DEBUG
        // SOMMELIER_DEBUG_SALE=1 puts the first card on sale, to see the sale tag without waiting for one.
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_SALE"] == "1", var items = similarItems[appID], let first = items.first {
            items[0] = SteamStore.Item(appID: first.appID, name: first.name, cover: first.cover, price: "$17.99",
                                       originalPrice: "$59.99", discount: 70)
            similarItems[appID] = items
        }
        #endif
    }

    /// What to show: each recommended game the user owns as their copy, the rest as store cards.
    func similar(to game: Game) -> [SimilarPick] {
        guard let appID = steamAppID(of: game), let items = similarItems[appID], !items.isEmpty else { return [] }
        let owned = Dictionary(games(for: .allGames).compactMap { g in steamAppID(of: g).map { ($0, g) } }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in
            if let mine = owned[item.appID] { return mine.id == game.id ? nil : .owned(mine) }
            return .store(item)
        }
    }
}
