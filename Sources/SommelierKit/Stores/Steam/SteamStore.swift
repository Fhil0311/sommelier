// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Steam's public store: the games it recommends next to one ("More Like This") and their names, covers and prices
/// in a country's currency. Read without signing in; nothing about the player is sent beyond the country.
public enum SteamStore {
    /// A game in the store, as a card shows it.
    public struct Item: Equatable, Sendable, Identifiable {
        public let appID: String
        public let name: String
        public let cover: URL?
        /// "$39.99", in the country's currency; nil when it isn't sold there (or is free).
        public let price: String?
        /// The price before a discount, and the discount, while one runs.
        public let originalPrice: String?
        public let discount: Int?
        public var id: String { appID }

        public init(appID: String, name: String, cover: URL?, price: String?, originalPrice: String?, discount: Int?) {
            self.appID = appID; self.name = name; self.cover = cover
            self.price = price; self.originalPrice = originalPrice; self.discount = discount
        }
        public var storePage: URL { URL(string: "https://store.steampowered.com/app/\(appID)/")! }
    }

    /// The apps Steam recommends next to `appID`, best first, from its "More Like This" page.
    public static func moreLike(appID: String, session: URLSession = .shared) async -> [String] {
        guard appID.allSatisfy(\.isNumber),
              let url = URL(string: "https://store.steampowered.com/recommended/morelike/app/\(appID)/") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request) else { return [] }
        return recommended(in: String(decoding: data, as: UTF8.self), excluding: appID)
    }

    /// The app ids the page lists, in order, each once, without the game itself.
    static func recommended(in html: String, excluding appID: String) -> [String] {
        var seen: Set<String> = [appID], ids: [String] = []
        let marker = #"data-ds-appid=""#
        var rest = html[...]
        while let start = rest.range(of: marker) {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            // A bundle lists several ids ("1,2,3"): it isn't one game.
            let value = String(rest[..<end])
            if value.allSatisfy(\.isNumber), seen.insert(value).inserted { ids.append(value) }
            rest = rest[end...]
        }
        return ids
    }

    /// Names, covers and prices for these apps in `country` (two letters, as macOS gives it), games only.
    public static func items(_ appIDs: [String], country: String, language: String, session: URLSession = .shared) async -> [Item] {
        guard !appIDs.isEmpty else { return [] }
        let request: [String: Any] = [
            "ids": appIDs.compactMap { Int($0) }.map { ["appid": $0] },
            "context": ["language": language, "country_code": country.uppercased()],
            "data_request": ["include_basic_info": true, "include_assets": true],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request),
              var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1") else { return [] }
        components.queryItems = [URLQueryItem(name: "input_json", value: String(decoding: json, as: UTF8.self))]
        guard let url = components.url, let (data, _) = try? await session.data(from: url) else { return [] }
        return parseItems(data, order: appIDs)
    }

    static func parseItems(_ data: Data, order: [String]) -> [Item] {
        struct Envelope: Decodable { let response: Response }
        struct Response: Decodable { let store_items: [StoreItem]? }
        struct StoreItem: Decodable {
            let appid: Int?
            let name: String?
            let type: Int?
            let visible: Bool?
            let assets: Assets?
            let best_purchase_option: Purchase?
            struct Assets: Decodable { let asset_url_format: String?; let library_capsule: String? }
            struct Purchase: Decodable { let formatted_final_price: String?; let formatted_original_price: String?; let discount_pct: Int? }
        }
        guard let items = (try? JSONDecoder().decode(Envelope.self, from: data))?.response.store_items else { return [] }
        let found: [String: Item] = Dictionary(items.compactMap { item -> (String, Item)? in
            // Type 0 is a game (not DLC, a soundtrack or software).
            guard let appid = item.appid, let name = item.name, !name.isEmpty, (item.type ?? 0) == 0, item.visible != false else { return nil }
            var cover: URL?
            if let format = item.assets?.asset_url_format, let capsule = item.assets?.library_capsule {
                cover = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/" + format.replacingOccurrences(of: "${FILENAME}", with: capsule))
            }
            let purchase = item.best_purchase_option
            return (String(appid), Item(appID: String(appid), name: name, cover: cover, price: purchase?.formatted_final_price,
                                        originalPrice: purchase?.formatted_original_price, discount: purchase?.discount_pct))
        }, uniquingKeysWith: { a, _ in a })
        return order.compactMap { found[$0] }
    }
}
