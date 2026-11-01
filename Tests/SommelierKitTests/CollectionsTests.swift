// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct CollectionsTests {
    @Test func addsOnceAndRemovesAnyCopy() {
        var shelf = GameCollection(name: "Weekend")
        shelf.add("steam:1")
        shelf.add("steam:1")
        shelf.add("gog:9")
        #expect(shelf.gameIDs == ["steam:1", "gog:9"])
        #expect(shelf.contains(anyOf: ["epic:x", "gog:9"]))
        shelf.remove(anyOf: ["gog:9", "steam:2"])
        #expect(shelf.gameIDs == ["steam:1"])
    }

    @Test func savesAndLoads() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = CollectionStore(paths: Paths(home: home))
        #expect(store.load().isEmpty)
        store.save([GameCollection(id: "a", name: "Co-op", gameIDs: ["steam:1"])])
        #expect(store.load() == [GameCollection(id: "a", name: "Co-op", gameIDs: ["steam:1"])])
    }
}
