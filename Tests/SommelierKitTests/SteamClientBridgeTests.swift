// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct SteamClientBridgeTests {
    @Test func steamStartsWithItsDevToolsOnOurPort() {
        #expect(SteamProvider.defaultArguments.contains("-cef-enable-debugging"))
        let port = SteamProvider.defaultArguments.firstIndex(of: "-devtools-port").map { SteamProvider.defaultArguments[$0 + 1] }
        #expect(port == String(SteamClientBridge.port) && port != "8080")
    }

    @Test func evaluateRequestsWaitForTheScript() throws {
        let text = SteamClientBridge.evaluateMessage(id: 7, expression: "1 + 1")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(object["id"] as? Int == 7 && object["method"] as? String == "Runtime.evaluate")
        #expect(params["expression"] as? String == "1 + 1" && params["awaitPromise"] as? Bool == true)
    }

    @Test func repliesAreMatchedToTheirRequest() {
        #expect(SteamClientBridge.answer(to: 1, in: #"{"id":1,"result":{"result":{"type":"boolean","value":true}}}"#) == true)
        #expect(SteamClientBridge.answer(to: 1, in: #"{"id":1,"result":{"result":{"type":"object"},"exceptionDetails":{"text":"x"}}}"#) == false)
        #expect(SteamClientBridge.answer(to: 1, in: #"{"id":2,"result":{"result":{"value":true}}}"#) == nil)
        #expect(SteamClientBridge.answer(to: 1, in: #"{"method":"Runtime.consoleAPICalled","params":{}}"#) == nil)
    }

    @Test func noSteamMeansNoPause() async {
        let bridge = SteamClientBridge(port: 1)       // nothing listens there
        #expect(await bridge.pause(appID: "220") == false)
        #expect(await bridge.resume(appID: "not a number") == false)
    }
}
