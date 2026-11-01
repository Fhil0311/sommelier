// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Puts Valve's Steam for Mac in place: its installer image from Valve's own server, the app copied to
/// Applications. Signing in stays with the user (Steam Guard can't be skipped); `isSignedIn` tells when it's done.
public struct SteamMacInstaller: Sendable {
    /// Valve's installer: a small bootstrapper that fetches the rest when Steam first opens.
    public static let imageURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/steam.dmg")!
    public static let bundleIdentifier = "com.valvesoftware.steam"

    public enum Failure: Error, LocalizedError {
        case download, noAppInImage, copy(String)
        public var errorDescription: String? {
            switch self {
            case .download: "Couldn't download Steam for Mac."
            case .noAppInImage: "Valve's installer didn't contain Steam."
            case .copy(let why): "Couldn't put Steam in Applications: \(why)"
            }
        }
    }

    public init() {}

    /// Downloads and installs Steam for Mac (into /Applications, or ~/Applications when that isn't writable).
    /// Does nothing when it's already there. Returns the installed app.
    @discardableResult
    public func install(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        if SteamMacClient.isInstalled { return SteamMacClient.appURL }
        let (image, response) = try await URLSession.shared.download(from: Self.imageURL)
        defer { try? FileManager.default.removeItem(at: image) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        onProgress(0.5)
        let dmg = image.appendingPathExtension("dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: image, to: dmg)
        defer { try? FileManager.default.removeItem(at: dmg) }

        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-steam-\(UUID().uuidString)")
        let attach = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                                 ["attach", dmg.path, "-nobrowse", "-quiet", "-mountpoint", mount.path])
        guard attach.succeeded else { throw Failure.download }
        defer { Task { _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", mount.path, "-quiet"]) } }
        guard let app = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else { throw Failure.noAppInImage }

        let target = Self.applicationsFolder().appendingPathComponent("Steam.app")
        do { try FileManager.default.copyItem(at: app, to: target) }
        catch { throw Failure.copy(error.localizedDescription) }
        onProgress(1)
        return target
    }

    /// /Applications when this user may write there (admins can), else the user's own Applications folder.
    static func applicationsFolder() -> URL {
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: shared.path) { return shared }
        let own = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        return own
    }

    /// Someone has signed in to Steam for Mac (it then remembers the account).
    public static var isSignedIn: Bool {
        SteamAccount.signedInName(steamDirectory: SteamMacClient.home) != nil
    }
}
