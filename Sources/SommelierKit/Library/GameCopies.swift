// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The same game owned in several stores, shown once in the combined library.
///
/// Copies are the same game when they share a Steam app ID (other stores' games are matched to their Steam page
/// already). Titles only join copies when one side has no Steam ID: two games with one title and different Steam
/// IDs are different games (Need for Speed: Most Wanted from 2005 and from 2012).
public enum GameCopies {
    /// Groups of copies, each in the order the games came in. `steamAppID` gives a non-Steam game's Steam ID when
    /// it's known.
    public static func group(_ games: [Game], steamAppID: (Game) -> String?) -> [[Game]] {
        var groups: [[Game]] = []
        var bySteamID: [String: Int] = [:]
        var byTitle: [String: [Int]] = [:]
        var unmatched: [Game] = []

        for game in games {
            guard let id = game.store == .steam ? game.storeID : steamAppID(game) else { unmatched.append(game); continue }
            if let index = bySteamID[id] {
                groups[index].append(game)
            } else {
                bySteamID[id] = groups.count
                byTitle[GameInfoService.normalized(game.title), default: []].append(groups.count)
                groups.append([game])
            }
        }
        for game in unmatched {
            let title = GameInfoService.normalized(game.title)
            // Joins a group only when the title points to exactly one, and that group lacks this store.
            if !title.isEmpty, let candidates = byTitle[title], candidates.count == 1,
               !groups[candidates[0]].contains(where: { $0.store == game.store }) {
                groups[candidates[0]].append(game)
            } else {
                if !title.isEmpty { byTitle[title, default: []].append(groups.count) }
                groups.append([game])
            }
        }
        return groups
    }

    /// The copy to show: an installed one (the most recently played), else the first store in Steam, Epic, GOG order.
    public static func preferred(_ copies: [Game], lastPlayed: (Game) -> Date?) -> Game? {
        copies.min { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            let (pa, pb) = (lastPlayed(a) ?? .distantPast, lastPlayed(b) ?? .distantPast)
            if pa != pb { return pa > pb }
            return storeOrder(a.store) < storeOrder(b.store)
        }
    }

    static func storeOrder(_ store: StoreKind) -> Int { StoreKind.allCases.firstIndex(of: store) ?? 0 }
}
