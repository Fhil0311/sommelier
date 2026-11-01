// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct RuntimeSetupTests {
    @Test func readsAnEpicGamesPrerequisite() {
        let json = """
        {"Sage": {"title": "Overcooked", "prereq_info": null},
         "Fortnite": {"title": "F", "prereq_info": {"ids": ["UE4Prereq"], "name": "UE4 Prerequisites (x64)",
                      "path": "Engine\\\\Extras\\\\Redist\\\\en-us\\\\UE4PrereqSetup_x64.exe", "args": "/quiet /norestart"}}}
        """.data(using: .utf8)!
        #expect(GamePrerequisites.epicInstaller(for: "Sage", installedJSON: json) == nil)
        #expect(GamePrerequisites.epicInstaller(for: "Missing", installedJSON: json) == nil)
        let f = GamePrerequisites.epicInstaller(for: "Fortnite", installedJSON: json)
        #expect(f?.path == "Engine\\Extras\\Redist\\en-us\\UE4PrereqSetup_x64.exe")
        #expect(f?.arguments == ["/quiet", "/norestart"])
    }

    @Test func aFreshEnvironmentHasNoRuntime() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = Paths(home: tmp)
        let bottle = Bottle(kind: .epic, paths: paths)
        #expect(!RuntimeSetup.isInstalled(in: bottle))
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        try "0".write(to: RuntimeSetup.marker(in: bottle), atomically: true, encoding: .utf8)
        #expect(!RuntimeSetup.isInstalled(in: bottle))
        try String(RuntimeSetup.version).write(to: RuntimeSetup.marker(in: bottle), atomically: true, encoding: .utf8)
        #expect(RuntimeSetup.isInstalled(in: bottle))
    }
}
