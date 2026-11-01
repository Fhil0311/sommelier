// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct PlayLinkTests {
    @Test func linkCarriesTheGameBothWays() throws {
        let link = try #require(GameLink.playURL(gameID: "steam:268910"))
        #expect(link.scheme == GameLink.scheme)
        #expect(link.host == "play")
        #expect(GameLink.gameID(from: link) == "steam:268910")
        #expect(GameLink.gameID(from: try #require(URL(string: "sommelier://play?game=gog:1207658924"))) == "gog:1207658924")
        #expect(GameLink.gameID(from: try #require(URL(string: "SOMMELIER://PLAY?game=epic:Sugar"))) == "epic:Sugar")
    }

    @Test func anythingElseIsRejected() throws {
        let rejected = [
            "sommelier://play?game=nothing", "sommelier://play?game=steam:", "sommelier://play?game=steam:1%20;rm",
            "sommelier://open?game=steam:1", "http://play?game=steam:1", "sommelier://play", "sommelier://play?id=steam:1",
            "sommelier://play?game=bogus:1", "sommelier://play?game=steam:../../x", "sommelier://play?game=steam:a:b",
        ]
        for text in rejected {
            #expect(GameLink.gameID(from: try #require(URL(string: text))) == nil, "\(text)")
        }
        #expect(GameLink.playURL(gameID: "steam:1'; touch /tmp/x") == nil)
        #expect(GameLink.playURL(gameID: "steam:é") == nil)
    }

    @Test func idLengthIsBounded() {
        #expect(GameLink.isValid("epic:" + String(repeating: "a", count: 200)))
        #expect(!GameLink.isValid("epic:" + String(repeating: "a", count: 201)))
        #expect(GameLink.isValid("ubisoft:Ab_1.2-3"))
        #expect(!GameLink.isValid(":123"))
    }
}

@Suite struct GameShortcutTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-shortcuts-\(UUID().uuidString)", isDirectory: true)
    }

    func plist(_ app: URL) throws -> [String: Any] {
        let raw = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any])
    }

    @Test func bundleIsAScriptThatOpensThePlayLink() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try ShortcutApp.create(title: "Hades: Gold/2", gameID: "epic:Rose", in: folder)
        #expect(app == ShortcutApp.appURL(title: "Hades: Gold/2", in: folder))
        #expect(app.lastPathComponent == "Hades- Gold-2.app")

        let launcher = app.appendingPathComponent("Contents/MacOS/launch")
        #expect(try String(contentsOf: launcher, encoding: .utf8) == "#!/bin/sh\nexec /usr/bin/open 'sommelier://play?game=epic:Rose'\n")
        let mode = try FileManager.default.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? Int
        #expect(mode == 0o755)

        let info = try plist(app)
        #expect(info["CFBundleIdentifier"] as? String == "gg.sommelier.game.epic-rose")
        #expect(info["CFBundleExecutable"] as? String == "launch")
        #expect(info["CFBundleName"] as? String == "Hades- Gold-2")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["LSUIElement"] == nil)          // the game inside must show in the Dock
        #expect(info["CFBundleIconFile"] == nil)
        #expect(ShortcutApp.existingGameID(at: app) == "epic:Rose")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Hades- Gold-2.app"])
    }

    @Test func iconIsCopiedIn() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = folder.appendingPathComponent("cover.icns")
        try FileManager.default.createDirectory(at: icon.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("icns".utf8).write(to: icon)
        let app = try ShortcutApp.create(title: "Celeste", gameID: "steam:504230", in: folder, icon: icon)
        #expect(try plist(app)["CFBundleIconFile"] as? String == "AppIcon")
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
    }

    @Test func ownShortcutIsReplacedAndOtherAppsAreLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ShortcutApp.create(title: "Celeste", gameID: "steam:504230", in: folder)
        let marker = first.appendingPathComponent("Contents/old-marker")
        try Data().write(to: marker)
        let again = try ShortcutApp.create(title: "Celeste", gameID: "steam:504230", in: folder)
        #expect(again == first)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Occupied.app/Contents"), withIntermediateDirectories: true)
        #expect(throws: ShortcutError.nameTaken("Occupied.app")) { try ShortcutApp.create(title: "Occupied", gameID: "gog:1", in: folder) }
        #expect(throws: ShortcutError.nameTaken("Celeste.app")) { try ShortcutApp.create(title: "Celeste", gameID: "gog:2", in: folder) }
        #expect(throws: ShortcutError.invalidGame) { try ShortcutApp.create(title: "Y", gameID: "no-colon", in: folder) }
        #expect(ShortcutApp.existingGameID(at: folder.appendingPathComponent("Occupied.app")) == nil)
    }

    @Test func defaultFolderIsInTheUsersApplications() {
        #expect(ShortcutApp.defaultFolder.path.hasSuffix("/Applications/Sommelier Games"))
    }
}
