// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// A collection being named in the sidebar, and the game to put on it once it has a name.
struct NamingCollection: Equatable {
    var seedGameID: String?
}

extension AppModel {
    func collection(_ id: String) -> GameCollection? { collections.first { $0.id == id } }

    /// The collection's games in the order they were added, one per game owned in several stores.
    func gamesIn(collection id: String) -> [Game] {
        guard let shelf = collection(id) else { return [] }
        let byID = Dictionary(visibleGames.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>(), result: [Game] = []
        for gameID in shelf.gameIDs {
            guard let game = byID[gameID] else { continue }
            let copies = copies(of: game).map(\.id)
            if copies.contains(where: seen.contains) { continue }
            seen.formUnion(copies)
            result.append(game)
        }
        return result
    }

    func isIn(_ game: Game, collection id: String) -> Bool {
        collection(id)?.contains(anyOf: copies(of: game).map(\.id)) ?? false
    }

    func isInAnyCollection(_ game: Game) -> Bool { collections.contains { isIn(game, collection: $0.id) } }

    /// Starts naming a new collection in the sidebar; `game` goes on it once it's named.
    func beginNamingCollection(with game: Game? = nil) { naming = NamingCollection(seedGameID: game?.id) }

    /// Makes the collection being named (an empty name gets the default one) and opens it.
    func finishNamingCollection(_ name: String) {
        guard let naming else { return }
        self.naming = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shelf = GameCollection(name: trimmed.isEmpty ? String(localized: "New Collection") : trimmed,
                                   gameIDs: naming.seedGameID.map { [$0] } ?? [])
        collections.append(shelf)
        saveCollections()
        if naming.seedGameID == nil { selection = .collection(shelf.id) }
    }

    func toggle(_ game: Game, in id: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        if isIn(game, collection: id) { collections[index].remove(anyOf: copies(of: game).map(\.id)) }
        else { collections[index].add(game.id) }
        saveCollections()
    }

    func rename(collection id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = trimmed
        saveCollections()
    }

    func delete(collection id: String) {
        collections.removeAll { $0.id == id }
        if selection == .collection(id) { selection = .home }
        saveCollections()
    }

    private func saveCollections() { CollectionStore(paths: paths).save(collections) }
}
