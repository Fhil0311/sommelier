// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct BattleNetConfigTests {
    func root(_ data: Data?) throws -> [String: Any] {
        let bytes = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    func client(_ data: Data?) throws -> [String: Any] {
        try #require(try root(data)["Client"] as? [String: Any])
    }

    @Test func signsInByItselfAndQuitsOnClose() throws {
        let written = #"{"Client":{"AutoStartMinimized":"true","RememberAccountName":"x"},"5a61":{"Services":{"LastLoginRegion":"US"}}}"#
        let prepared = LauncherStore.battleNetConfigPrepared(Data(written.utf8))
        let settings = try client(prepared)
        #expect(settings["AutoLogin"] as? String == "true" && settings["HideOnClose"] as? String == "false")
        #expect(settings["AutoStartMinimized"] as? String == "true")             // the rest stays
        #expect(try root(prepared)["5a61"] != nil)
        #expect(LauncherStore.battleNetConfigPrepared(prepared) == nil)           // already so: left alone
    }

    @Test func aMissingConfigIsStarted() throws {
        let settings = try client(LauncherStore.battleNetConfigPrepared(nil))
        #expect(settings["AutoLogin"] as? String == "true" && settings["HideOnClose"] as? String == "false")
    }
}
