// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A shelf the player makes: a name and the games on it, in the order they were added.
public struct GameCollection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Library game ids. A game owned in several stores counts as on the shelf when any of its copies is.
    public var gameIDs: [String]

    public init(id: String = UUID().uuidString, name: String, gameIDs: [String] = []) {
        self.id = id; self.name = name; self.gameIDs = gameIDs
    }

    /// Whether any of these ids (one game's copies) is on the shelf.
    public func contains(anyOf ids: [String]) -> Bool { ids.contains { gameIDs.contains($0) } }

    public mutating func add(_ id: String) { if !gameIDs.contains(id) { gameIDs.append(id) } }

    /// Takes the game off, whichever of its copies was added.
    public mutating func remove(anyOf ids: [String]) { gameIDs.removeAll { ids.contains($0) } }
}

/// `Collections.json`: the player's collections, in sidebar order.
public struct CollectionStore: Sendable {
    let store: JSONStore<[GameCollection]>

    public init(paths: Paths) { store = JSONStore(url: paths.home.appendingPathComponent("Collections.json")) }

    public func load() -> [GameCollection] { store.load(default: []) }

    public func save(_ collections: [GameCollection]) { try? store.save(collections) }
}
