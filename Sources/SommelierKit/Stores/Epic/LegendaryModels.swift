// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One owned game as `legendary list --json` prints it.
struct LegendaryOwnedGame: Decodable {
    struct Details: Decodable {   // only the parts Sommelier shows
        struct Picture: Decodable { let type, url: String }
        struct ReleaseInfo: Decodable { let platform: [String]? }
        let keyImages: [Picture]?
        let releaseInfo: [ReleaseInfo]?
    }
    let appName, title: String
    let details: Details?

    enum CodingKeys: String, CodingKey { case appName = "app_name", title = "app_title", details = "metadata" }

    /// The first picture of the listed kinds, in order of preference.
    func picture(_ preferred: [String]) -> URL? {
        let pictures = details?.keyImages ?? []
        for kind in preferred {
            if let match = pictures.first(where: { $0.type == kind }) { return URL(string: match.url) }
        }
        return nil
    }

    /// Epic sells a Mac version of the game too.
    var hasMacRelease: Bool {
        (details?.releaseInfo ?? []).contains { ($0.platform ?? []).contains("Mac") }
    }
}

/// One installed game as `legendary list-installed --json` prints it.
struct LegendaryInstall: Decodable {
    let appName, installPath: String
    let title, version: String?
    let installSize: Int64?
    /// "Windows" or "Mac": which of the game's versions is on disk.
    let platform: String?
    /// The executable relative to `installPath`; inside the bundle for a Mac version ("Game.app/Contents/MacOS/Game").
    let executable: String?

    private enum CodingKeys: String, CodingKey {
        case appName = "app_name", installPath = "install_path", installSize = "install_size"
        case title, version, platform, executable
    }

    var folder: URL { URL(fileURLWithPath: installPath) }
    var isMacVersion: Bool { platform == "Mac" }
}

/// Turns legendary's JSON into library entries.
public enum LegendaryParser: Sendable {
    /// Every owned game, with install state, size and art filled in from the installed list. Sorted by title,
    /// ignoring case.
    public static func games(listJSON list: Data, installedJSON installs: Data) throws -> [Game] {
        let json = JSONDecoder()
        let owned = try json.decode([LegendaryOwnedGame].self, from: list)
        // Keyed by app name; should legendary ever list one twice, the later entry counts.
        var installed: [String: LegendaryInstall] = [:]
        for entry in try json.decode([LegendaryInstall].self, from: installs) { installed[entry.appName] = entry }

        return owned.map { item -> Game in
            let local = installed[item.appName]
            return Game(
                store: .epic, storeID: item.appName, title: item.title,
                isInstalled: local != nil,
                installPath: local?.folder,
                sizeOnDisk: local?.installSize,
                coverURL: item.picture(["DieselGameBoxTall", "Thumbnail"]),
                heroURL: item.picture(["DieselGameBox", "OfferImageWide"]),
                macBuild: macBuild(of: item, installed: local),
                native: local?.isMacVersion == true ? true : nil)
        }
        .inLibraryOrder()
    }

    /// Epic doesn't say which processors its Mac versions are built for. Once one is installed its binary does;
    /// before that, "a Mac version exists" is all we know.
    private static func macBuild(of item: LegendaryOwnedGame, installed: LegendaryInstall?) -> MacBuild? {
        if let installed, installed.isMacVersion, let relative = installed.executable {
            let found = MachO.architectures(of: installed.folder.appendingPathComponent(relative))
            if !found.isEmpty { return MachO.build(for: found) }
        }
        return item.hasMacRelease ? .unknown : nil
    }

    /// The fraction done from a legendary download line such as
    /// `[DLManager] INFO: = Progress: 12.34% (123/1000), Running for ...`.
    public static func progress(from output: String) -> Double? {
        guard let start = output.range(of: "Progress: ")?.upperBound else { return nil }
        let end = output[start...].firstIndex(of: "%") ?? output.endIndex
        guard let percent = Double(output[start..<end]) else { return nil }
        return max(0, min(percent / 100, 1))
    }
}
