// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SteamRunningAppParseTests {
    @Test func hexValueBecomesTheDecimalAppID() {
        let registry = """
        [Software\\\\Valve\\\\Steam] 1700000000
        "Rate"="30000"
        "RunningAppID"=dword:0003bb62
        "SteamPath"="c:/program files (x86)/steam"
        """
        #expect(SteamRunningApp.parse(registry: Data(registry.utf8)) == "244578")
        #expect(SteamRunningApp.parse(registry: Data("\"RunningAppID\"=dword:FFFFFFFF".utf8)) == "4294967295")
    }

    @Test func idleMissingOrCutOffMeansNothingRuns() {
        for text in ["\"RunningAppID\"=dword:00000000\n", "no such value", "\"RunningAppID\"=dword:12", "\"RunningAppID\"=dword:zzzzzzzz", ""] {
            #expect(SteamRunningApp.parse(registry: Data(text.utf8)) == nil, "\(text)")
        }
    }

    @Test func readsUserRegFromTheBottle() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-steamreg-\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: scratch) }
        let steamBottle = Bottle(kind: .steam, paths: Paths(home: scratch))
        #expect(SteamRunningApp.read(bottle: steamBottle) == nil)
        let registry = steamBottle.url.appendingPathComponent("user.reg")
        try FileManager.default.createDirectory(at: steamBottle.url, withIntermediateDirectories: true)
        try Data("\"RunningAppID\"=dword:0000000a\n".utf8).write(to: registry)
        #expect(SteamRunningApp.read(bottle: steamBottle) == "10")
    }
}
