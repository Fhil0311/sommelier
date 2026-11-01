// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct SteamAccountTests {
    @Test func namesTheMostRecentUser() {
        let text = """
        "users"
        {
        \t"1"
        \t{
        \t\t"AccountName"\t\t"old"
        \t\t"PersonaName"\t\t"Old One"
        \t}
        \t"2"
        \t{
        \t\t"AccountName"\t\t"new"
        \t\t"PersonaName"\t\t"New One"
        \t\t"MostRecent"\t\t"1"
        \t}
        }
        """
        #expect(SteamAccount.signedInName(loginUsers: text) == "New One")
        #expect(SteamAccount.signedInName(loginUsers: "\"users\"\n{\n}\n") == nil)
    }

    @Test func forgetsTheLoginAndKeepsGames() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: home))
        let fm = FileManager.default
        let steam = bottle.steamDirectory
        let local = bottle.driveC.appendingPathComponent("users/me/AppData/Local/Steam")
        for dir in [steam.appendingPathComponent("config"), steam.appendingPathComponent("appcache/librarycache/42"),
                    steam.appendingPathComponent("steamapps"), local.appendingPathComponent("htmlcache")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let manifest = steam.appendingPathComponent("steamapps/appmanifest_42.acf")
        for file in [steam.appendingPathComponent("config/loginusers.vdf"), local.appendingPathComponent("local.vdf"), manifest] {
            try Data("x".utf8).write(to: file)
        }

        SteamAccount.forget(bottle: bottle)

        #expect(!fm.fileExists(atPath: steam.appendingPathComponent("config/loginusers.vdf").path))
        #expect(!fm.fileExists(atPath: local.appendingPathComponent("local.vdf").path))
        #expect(!fm.fileExists(atPath: local.appendingPathComponent("htmlcache").path))
        #expect(!fm.fileExists(atPath: steam.appendingPathComponent("appcache/librarycache").path))
        #expect(fm.fileExists(atPath: manifest.path))
        #expect(SteamAccount.signedInName(bottle: bottle) == nil)
    }
}
