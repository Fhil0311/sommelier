// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SaveLocationsTests {
    let box: SaveSandbox
    init() throws { box = try SaveSandbox() }

    private func place(_ root: SaveRoot, _ path: String, stores: [String]? = nil) -> SaveLocationsList.Place {
        SaveLocationsList.Place(root: root, path: path, stores: stores)
    }

    @Test func filesGiveTheirFolder() throws {
        try box.put("x", at: "users/me/Documents/The Witcher 3/gamesaves/a.sav")
        let found = place(.documents, "The Witcher 3/gamesaves/*.sav").folders(in: box.roots)
        #expect(found == [SaveSource(root: .documents, path: "The Witcher 3/gamesaves")])
    }

    @Test func wildcardStepsMatchFolders() throws {
        try box.put("x", at: "users/me/AppData/Roaming/EldenRing/7656119/ER0000.sl2")
        let found = place(.roaming, "EldenRing/*").folders(in: box.roots)
        #expect(found == [SaveSource(root: .roaming, path: "EldenRing/7656119")])
    }

    @Test func neverTheWholeGameOrARoot() throws {
        try box.put("x", at: "game/save1.dat")
        #expect(place(.install, "*.dat").folders(in: box.roots).isEmpty)
        #expect(place(.install, "Missing/*.sav").folders(in: box.roots).isEmpty)
        #expect(place(.roaming, "../escape").folders(in: box.roots).isEmpty)
    }

    @Test func bigFoldersAreLeftOut() throws {
        try box.put(String(repeating: "x", count: 2000), at: "users/me/AppData/Local/Game/Saved/a.sav")
        #expect(place(.local, "Game/Saved").folders(in: box.roots, largest: 1000).isEmpty)
    }

    @Test func lookupByIdThenTitleAndStore() throws {
        let json = #"{"version":1,"games":{"steam:1":[{"root":"documents","path":"A"}],"title:hadesii":[{"root":"savedGames","path":"Hades II","stores":["epic"]},{"root":"documents","path":"B","stores":["steam"]}],"steam:2":[{"root":"nowhere","path":"x"}]}}"#
        let list = try JSONDecoder().decode(SaveLocationsList.self, from: Data(json.utf8))
        #expect(list.places(for: Game(store: .steam, storeID: "1", title: "A", isInstalled: true)).map(\.path) == ["A"])
        #expect(list.places(for: Game(store: .epic, storeID: "x", title: "Hades II", isInstalled: true)).map(\.path) == ["Hades II"])
        #expect(list.places(for: Game(store: .steam, storeID: "2", title: "Z", isInstalled: true)).isEmpty)
    }
}
