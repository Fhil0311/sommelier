// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The URL a game shortcut opens to have Sommelier start that game, e.g. `sommelier://play?game=steam%3A268910`.
public enum GameLink: Sendable {
    /// `sommelier-dev` for the development build, so a link opens the app that made it.
    public static var scheme: String { BuildFlavor.isDevelopment ? "sommelier-dev" : "sommelier" }
    private static let action = "play"
    private static let parameter = "game"

    /// The link for a game, or nil if the id isn't one a link may carry.
    public static func playURL(
        gameID: String
    ) -> URL? {
        if !isValid(gameID) { return nil }
        var parts = URLComponents()
        (parts.scheme, parts.host) = (scheme, action)
        parts.queryItems = [URLQueryItem(name: parameter, value: gameID)]
        return parts.url
    }

    /// The game a link asks for. Anything that isn't a well-formed play link gives nil.
    public static func gameID(
        from url: URL
    ) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == action else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let value = query.first(where: { $0.name == parameter })?.value, isValid(value) else { return nil }
        return value
    }

    /// A game id is "<store>:<key>": a known store, then 1 to 200 ASCII letters, digits, `.`, `_` or `-`.
    /// The strict alphabet is what makes the id safe to put in a shell script and a bundle id.
    public static func isValid(
        _ id: String
    ) -> Bool {
        guard let colon = id.firstIndex(of: ":"), StoreKind(rawValue: String(id[..<colon])) != nil else { return false }
        let key = id[id.index(after: colon)...]
        guard (1...200).contains(key.count) else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }
}
