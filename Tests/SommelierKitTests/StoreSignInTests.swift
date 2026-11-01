// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct StoreSignInTests {
    @Test func gogCodeComesFromTheRedirect() {
        let url = URL(string: "https://embed.gog.com/on_login_success?origin=client&code=abc123")!
        #expect(StoreSignIn.gogCode(redirect: url) == "abc123")
        #expect(StoreSignIn.gogCode(redirect: URL(string: "https://embed.gog.com/on_login_success?origin=client")!) == nil)
        #expect(StoreSignIn.gogCode(redirect: URL(string: "https://evil.example/on_login_success?code=abc")!) == nil)
        #expect(StoreSignIn.gogCode(redirect: URL(string: "https://login.gog.com/auth?code=abc")!) == nil)
    }

    @Test func epicCodeComesFromTheRedirectPage() {
        #expect(StoreSignIn.isEpicCodePage(URL(string: "https://www.epicgames.com/id/api/redirect?clientId=x&responseType=code")!))
        #expect(!StoreSignIn.isEpicCodePage(URL(string: "https://www.epicgames.com/id/login")!))
        let page = #"{"warning":"Do not share this code with any 3rd party service.","redirectUrl":"https://localhost/launcher/authorized?code=abc","authorizationCode":"abc","exchangeCode":null,"sid":null}"#
        #expect(StoreSignIn.epicCode(pageText: page) == "abc")
        #expect(StoreSignIn.epicCode(pageText: #"{"redirectUrl":null,"authorizationCode":null,"sid":null}"#) == nil)
        #expect(StoreSignIn.epicCode(pageText: "<html>not json</html>") == nil)
    }

    @Test func everyDirectStoreHasASignInPage() {
        #expect(StoreSignIn.url(for: .epic)?.host == "www.epicgames.com")
        #expect(StoreSignIn.url(for: .gog) != nil)
        #expect(StoreSignIn.url(for: .steam) == nil)
    }
}
