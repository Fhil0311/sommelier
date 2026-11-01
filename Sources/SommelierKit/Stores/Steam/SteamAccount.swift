// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Steam account signed in inside the Steam environment, and signing it out from outside Steam.
/// Steam keeps a login in `config/loginusers.vdf` (who), `AppData/Local/Steam/local.vdf` (the saved token), its web
/// view's cookies, and the `AutoLoginUser` registry value. Removing them signs out; installed games stay.
public enum SteamAccount {
    /// The name the account shows in Steam (the most recent user); nil when no one is signed in.
    public static func signedInName(bottle: Bottle) -> String? { signedInName(steamDirectory: bottle.steamDirectory) }

    public static func signedInName(steamDirectory: URL) -> String? {
        guard let text = try? String(contentsOf: steamDirectory.appendingPathComponent("config/loginusers.vdf"), encoding: .utf8) else { return nil }
        return signedInName(loginUsers: text)
    }

    static func signedInName(loginUsers text: String) -> String? {
        guard let users = (try? VDFParser.parse(text))?["users"]?.entries, !users.isEmpty else { return nil }
        let user = users.first { $0.value["MostRecent"]?.string == "1" } ?? users.first!
        return user.value["PersonaName"]?.string ?? user.value["AccountName"]?.string ?? ""
    }

    static func loginUsersFile(_ bottle: Bottle) -> URL { bottle.steamDirectory.appendingPathComponent("config/loginusers.vdf") }

    /// Everything that keeps the account signed in, plus the cache that lists its games. Steam must not be running.
    public static func loginFiles(bottle: Bottle) -> [URL] {
        var files = [loginUsersFile(bottle), bottle.steamDirectory.appendingPathComponent("appcache/librarycache")]
        let users = bottle.driveC.appendingPathComponent("users")
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] {
            let steam = users.appendingPathComponent(user).appendingPathComponent("AppData/Local/Steam")
            files.append(steam.appendingPathComponent("local.vdf"))
            files.append(steam.appendingPathComponent("htmlcache"))
        }
        return files
    }

    /// Deletes the saved login. The registry value goes separately, through Wine (see `AppModel.signOutSteam`).
    public static func forget(bottle: Bottle) {
        for url in loginFiles(bottle: bottle) { try? FileManager.default.removeItem(at: url) }
    }
}
