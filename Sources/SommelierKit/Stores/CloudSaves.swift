// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Cloud saves for Epic Games and GOG, through the stores' helpers (Legendary, gogdl). Before a game starts, newer
/// cloud saves come down; after it quits, newer local saves go up. When both sides changed, the user picks.
/// (Steam does this itself.)
public enum CloudSaveMode: Sendable {
    /// Take newer saves from the cloud; never upload.
    case download
    /// Send newer saves to the cloud; never download.
    case upload
    case forceDownload
    case forceUpload
}

public enum CloudSaveOutcome: Equatable, Sendable {
    case synced
    case nothingToDo
    /// The game has no cloud saves on this store.
    case unsupported
    /// Both sides changed since the last sync. Dates as the helper printed them.
    case conflict(cloud: String, local: String)
    case failed(String)
}

public enum CloudSaves {
    /// Reads Legendary's `sync-saves` output.
    public static func parseLegendary(_ output: String, status: Int32) -> CloudSaveOutcome {
        if output.contains("does not support cloud saves") || output.contains("Could not find") && output.contains("save") { return .unsupported }
        if output.contains("is in conflict") {
            let cloud = line(after: "Cloud save date: ", in: output) ?? "?"
            let local = line(after: "Local save date: ", in: output) ?? "?"
            return .conflict(cloud: cloud, local: local)
        }
        guard status == 0 else { return .failed(lastLine(of: output)) }
        if output.contains("is up to date") || output.contains("No cloud or local savegame found") || output.contains("disabled, skipping") {
            return .nothingToDo
        }
        return .synced
    }

    /// Reads gogdl's `save-sync` output; its last line is the new sync timestamp when it did something.
    public static func parseGOG(_ output: String, status: Int32) -> (CloudSaveOutcome, timestamp: String?) {
        let stamp = output.split(whereSeparator: \.isNewline).last.map(String.init).flatMap { Double($0) != nil ? $0 : nil }
        if output.contains("Files in conflict") { return (.conflict(cloud: "?", local: "?"), nil) }
        guard status == 0 else { return (.failed(lastLine(of: output)), nil) }
        if output.contains("Refused to") || output.contains("Nothing to do") { return (.nothingToDo, stamp) }
        return (.synced, stamp)
    }

    static func line(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        return String(rest[..<(rest.firstIndex(where: \.isNewline) ?? rest.endIndex)]).trimmingCharacters(in: .whitespaces)
    }

    static func lastLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "unknown error"
    }
}

/// Where a GOG game keeps its saves, from GOG's own per-game configuration, with GOG's placeholders turned into
/// folders of the game's Wine environment. Nothing of the user's is sent to get it (only the game's client id).
public enum GOGSaveLocations {
    public struct Location: Equatable, Sendable {
        public let name: String
        public let path: URL
    }

    public static func configURL(clientID: String) -> URL {
        URL(string: "https://remote-config.gog.com/components/galaxy_client/clients/\(clientID)?component_version=2.0.45")!
    }

    /// Templates from GOG's configuration (`<?DOCUMENTS?>/My Games/...`), or GOG's default folder when the game
    /// defines none; nil when the game has cloud saves turned off.
    public static func templates(from data: Data, clientID: String) -> [(name: String, template: String)]? {
        struct Response: Decodable {
            struct Content: Decodable {
                struct Platform: Decodable {
                    struct Storage: Decodable {
                        struct Loc: Decodable { let name: String; let location: String }
                        let enabled: Bool?
                        let locations: [Loc]?
                    }
                    let cloudStorage: Storage?
                }
                let Windows: Platform?
                enum CodingKeys: String, CodingKey { case Windows = "windows" }
            }
            let content: Content?
        }
        guard let storage = (try? JSONDecoder().decode(Response.self, from: data))?.content?.Windows?.cloudStorage,
              storage.enabled != false else { return nil }
        let locations = (storage.locations ?? []).map { (name: $0.name, template: $0.location) }
        return locations.isEmpty ? [(name: "__default", template: "%LocalAppData%/GOG.com/Galaxy/Applications/\(clientID)/Storage/Shared/Files")] : locations
    }

    /// A template as a folder in the Wine environment. `user` is the Windows user folder (`drive_c/users/<name>`).
    public static func resolve(_ template: String, install: URL, user: URL) -> URL {
        var text = template
        let appData = user.appendingPathComponent("AppData")
        let variables: [String: String] = [
            "<?INSTALL?>": install.path,
            "<?SAVED_GAMES?>": user.appendingPathComponent("Saved Games").path,
            "<?APPLICATION_DATA_LOCAL?>": appData.appendingPathComponent("Local").path,
            "<?APPLICATION_DATA_LOCAL_LOW?>": appData.appendingPathComponent("LocalLow").path,
            "<?APPLICATION_DATA_ROAMING?>": appData.appendingPathComponent("Roaming").path,
            "<?DOCUMENTS?>": user.appendingPathComponent("Documents").path,
            "%LocalAppData%": appData.appendingPathComponent("Local").path,
            "%LOCALAPPDATA%": appData.appendingPathComponent("Local").path,
            "%APPDATA%": appData.appendingPathComponent("Roaming").path,
            "%USERPROFILE%": user.path,
        ]
        for (key, value) in variables { text = text.replacingOccurrences(of: key, with: value, options: .caseInsensitive) }
        return URL(fileURLWithPath: text.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
    }

    /// The Windows user folder of an environment (Wine names it after the Mac user, CrossOver's build "crossover").
    public static func userFolder(in bottle: Bottle) -> URL? {
        let users = bottle.driveC.appendingPathComponent("users")
        return ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [])
            .first { $0.lastPathComponent != "Public" }
    }
}
