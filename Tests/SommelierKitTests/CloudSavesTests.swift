// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct CloudSavesTests {
    @Test func readsLegendarysOutcome() {
        // Real lines from `legendary sync-saves` on this Mac.
        let conflict = """
        [cli] INFO: Cloud save for "Overcooked" is in conflict:
        [cli] INFO: - Cloud save date: 2026-10-18 12:00:00
        [cli] INFO: - Local save date: 2026-10-19 21:14:16
        [cli] WARNING: Run the command again with appropriate force parameter to effectively pick the save
        """
        #expect(CloudSaves.parseLegendary(conflict, status: 0) == .conflict(cloud: "2026-10-18 12:00:00", local: "2026-10-19 21:14:16"))
        #expect(CloudSaves.parseLegendary("[cli] INFO: No cloud or local savegame found.", status: 0) == .nothingToDo)
        #expect(CloudSaves.parseLegendary("[cli] INFO: Save game uploading is disabled, skipping...", status: 0) == .nothingToDo)
        #expect(CloudSaves.parseLegendary("[cli] INFO: Save game for \"X\" is up to date, skipping...", status: 0) == .nothingToDo)
        #expect(CloudSaves.parseLegendary("ValueError: Game does not support cloud saves", status: 1) == .unsupported)
        #expect(CloudSaves.parseLegendary("[cli] INFO: Downloading cloud save...\n[cli] INFO: Done", status: 0) == .synced)
        #expect(CloudSaves.parseLegendary("boom", status: 1) == .failed("boom"))
    }

    @Test func readsGogdlsOutcome() {
        let (synced, stamp) = CloudSaves.parseGOG("[saves] INFO: Uploading files\n[saves] INFO: Done\n1792440000.123", status: 0)
        #expect(synced == .synced && stamp == "1792440000.123")
        #expect(CloudSaves.parseGOG("Files in conflict force downloading or uploading of files\n1792440000.1", status: 0).0 == .conflict(cloud: "?", local: "?"))
        let (refused, kept) = CloudSaves.parseGOG("Refused to upload files, newer files in the cloud\n0", status: 0)
        #expect(refused == .nothingToDo && kept == "0")
    }

    @Test func resolvesGogSavePlaceholders() throws {
        let data = #"{"content":{"windows":{"cloudStorage":{"enabled":true,"locations":[{"name":"saves","location":"<?DOCUMENTS?>/My Games/Thing/Saves"},{"name":"cfg","location":"<?APPLICATION_DATA_LOCAL?>\\Thing"}]}}}}"#
        let templates = try #require(GOGSaveLocations.templates(from: Data(data.utf8), clientID: "42"))
        #expect(templates.map(\.name) == ["saves", "cfg"])
        let user = URL(fileURLWithPath: "/b/drive_c/users/crossover")
        let install = URL(fileURLWithPath: "/g/Thing")
        #expect(GOGSaveLocations.resolve(templates[0].template, install: install, user: user).path == "/b/drive_c/users/crossover/Documents/My Games/Thing/Saves")
        #expect(GOGSaveLocations.resolve(templates[1].template, install: install, user: user).path == "/b/drive_c/users/crossover/AppData/Local/Thing")
        #expect(GOGSaveLocations.resolve("<?INSTALL?>/profiles", install: install, user: user).path == "/g/Thing/profiles")

        let none = #"{"content":{"windows":{"cloudStorage":{"enabled":true,"locations":[]}}}}"#
        #expect(GOGSaveLocations.templates(from: Data(none.utf8), clientID: "42")?.first?.template.contains("Applications/42/Storage") == true)
        #expect(GOGSaveLocations.templates(from: Data(#"{"content":{"windows":{"cloudStorage":{"enabled":false}}}}"#.utf8), clientID: "42") == nil)
        #expect(GOGParser.clientID(infoJSON: Data(#"{"gameId":"1","clientId":"5500","playTasks":[]}"#.utf8)) == "5500")
    }
}
