// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Signing in to Epic Games and GOG on the store's own web page. The page ends on a redirect that carries a
/// one-time code; the store's helper trades that code for tokens. Passwords only ever go to the store.
public enum StoreSignIn {
    /// Epic's login page for Legendary's client id: once signed in it shows JSON with `authorizationCode`.
    public static let epicURL = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!

    public static func url(for store: StoreKind) -> URL? {
        switch store {
        case .epic: epicURL
        case .gog: GOGProvider.loginURL
        default: nil
        }
    }

    /// GOG: the code is in the redirect's query (`embed.gog.com/on_login_success?code=…`).
    public static func gogCode(redirect url: URL) -> String? {
        guard url.host == "embed.gog.com", url.path.hasPrefix("/on_login_success") else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "code" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Epic: the page at `/id/api/redirect` whose body is the JSON with the code.
    public static func isEpicCodePage(_ url: URL) -> Bool {
        url.host?.hasSuffix("epicgames.com") == true && url.path == "/id/api/redirect"
    }

    /// The code in that page's text; nil until the user has signed in (the field is null then).
    public static func epicCode(pageText: String) -> String? {
        struct Redirect: Decodable { let authorizationCode: String? }
        let code = (try? JSONDecoder().decode(Redirect.self, from: Data(pageText.utf8)))?.authorizationCode
        return code.flatMap { $0.isEmpty ? nil : $0 }
    }
}
