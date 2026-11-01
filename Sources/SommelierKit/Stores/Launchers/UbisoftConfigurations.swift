// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The games an account owns on Ubisoft Connect, from the launcher's own cache: after sign-in it keeps a
/// configuration for every product of the account in `cache/configuration/configurations`, a list of
/// (uplay id, install id, YAML) records. Games (as opposed to DLC and passes) have a `start_game` section; their
/// names and artwork are in the YAML's `localizations` table. Nothing is sent anywhere to read it.
public enum UbisoftConfigurations {
    public struct Entry: Equatable, Sendable {
        public let uplayID: Int
        public let installID: Int
        public let name: String
        public let thumbnail: String?
        public let background: String?
        /// Set for a game bought on Steam: Ubisoft Connect can't install it itself (it would set up Steam inside
        /// its own environment and download through it), so Sommelier installs the Steam copy instead.
        public var steamAppID: String? = nil
    }

    /// Ubisoft's CDN for the artwork the configurations name.
    public static func assetURL(_ file: String) -> URL? {
        URL(string: "https://ubistatic3-a.akamaihd.net/orbit/uplay_launcher_3_0/assets/\(file)")
    }

    public static func parse(_ data: Data) -> [Entry] {
        let bytes = [UInt8](data)
        var entries: [Entry] = []
        _ = try? Protobuf.fields(bytes, 0..<bytes.count) { field, value in
            guard field == 1, case .bytes(let record) = value else { return }
            var uplayID = 0, installID = 0, yaml = ""
            try Protobuf.fields(bytes, record) { field, value in
                switch (field, value) {
                case (1, .varint(let v)): uplayID = Int(v)
                case (2, .varint(let v)): installID = Int(v)
                case (3, .bytes(let r)): yaml = String(decoding: bytes[r], as: UTF8.self)
                default: break
                }
            }
            if let entry = entry(uplayID: uplayID, installID: installID, yaml: yaml) { entries.append(entry) }
        }
        return entries
    }

    /// A game from one configuration; nil for DLC, passes and anything without a name.
    static func entry(uplayID: Int, installID: Int, yaml: String) -> Entry? {
        let yaml = yaml.replacingOccurrences(of: "\r\n", with: "\n")          // the launcher writes Windows line ends
        guard yaml.contains("start_game:"), uplayID > 0 else { return nil }
        let strings = localizations(in: yaml)
        func resolve(_ key: String) -> String? {
            guard let raw = rootValue(key, in: yaml) else { return nil }
            return strings[raw] ?? raw
        }
        guard let name = resolve("name"), !name.isEmpty else { return nil }
        return Entry(uplayID: uplayID, installID: installID > 0 ? installID : uplayID, name: name,
                     thumbnail: resolve("thumb_image"), background: resolve("background_image"),
                     steamAppID: steamActivation(in: yaml))
    }

    /// The Steam app of a game whose licence lives on Steam: `third_party_platform: name: Steam` at the root, with
    /// `steam_app_id` under `start_game: steam:`.
    static func steamActivation(in yaml: String) -> String? {
        guard let platform = try? NSRegularExpression(pattern: "(?m)^  third_party_platform:\\s*\\n\\s+name: *Steam\\s*$"),
              platform.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)) != nil,
              let app = try? NSRegularExpression(pattern: "(?m)^\\s+steam_app_id: *(\\d+)"),
              let match = app.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)),
              let range = Range(match.range(at: 1), in: yaml) else { return nil }
        return String(yaml[range])
    }

    /// `root:`'s direct `key: value` (two-space indent), unquoted.
    static func rootValue(_ key: String, in yaml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?m)^  \(key): *(.+)$"),
              let match = regex.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)),
              let range = Range(match.range(at: 1), in: yaml) else { return nil }
        return unquote(String(yaml[range]))
    }

    /// The `localizations:` table's `default` (or English) strings: `l1: For Honor`.
    static func localizations(in yaml: String) -> [String: String] {
        guard let start = yaml.range(of: "\nlocalizations:\n") else { return [:] }
        let table = yaml[start.upperBound...]
        var result: [String: String] = [:]
        var language: String?
        for line in table.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("  ") && !line.hasPrefix("    ") {
                language = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            } else if line.hasPrefix("    "), language == "default" || (language == "en-US" && result.isEmpty) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.index(line.startIndex, offsetBy: 4)..<colon]
                result[String(key)] = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            } else if !line.hasPrefix(" "), !line.isEmpty {
                break                                             // the next top-level section
            }
        }
        return result
    }

    static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let first = v.first, (first == "'" || first == "\""), v.last == first { v = String(v.dropFirst().dropLast()) }
        return v
    }
}
