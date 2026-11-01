// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A library file must survive entries this version can't fully read: losing it starts the library over and
/// takes every game's play time and settings with it.
struct LibraryFileTests {
    func decode(_ json: String) throws -> LibraryFile {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryFile.self, from: Data(json.utf8))
    }

    @Test func gameDataWithoutSettingsKeepsItsPlayTime() throws {
        let file = try decode(#"""
        { "games": [], "userData": {
            "steam:648800": { "playTime": 48.5, "lastPlayed": "2026-10-20T20:42:04Z" },
            "epic:Sage": { "playTime": 120, "profile": { "backend": "dxmt" } } } }
        """#)
        #expect(file.userData["steam:648800"]?.playTime == 48.5)
        #expect(file.userData["steam:648800"]?.profile == LaunchProfile())
        #expect(file.userData["epic:Sage"]?.profile.backend == .dxmt)
    }

    @Test func oneBadEntryDoesntTakeTheRestWithIt() throws {
        let file = try decode(#"""
        { "games": [ { "id": "steam:1", "store": "steam", "storeID": "1", "title": "Good", "isInstalled": false }, { "id": 5 } ],
          "userData": { "steam:1": { "playTime": 10 }, "steam:2": "not an object", "steam:3": { "playTime": "soon", "lastPlayed": "2026-10-20T20:42:04Z" } } }
        """#)
        #expect(file.games.map(\.title) == ["Good"])
        #expect(file.userData["steam:1"]?.playTime == 10)
        #expect(file.userData["steam:2"] == nil)
        #expect(file.userData["steam:3"]?.playTime == 0)                     // the bad field only
        #expect(file.userData["steam:3"]?.lastPlayed != nil)
    }
}
