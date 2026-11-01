// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// EA games bought on Steam start through the EA app (Steam runs `steam2ea://launchgame/<id>`). Steam installs the
/// EA app itself from the game's `__Installer` folder on first launch, but in Wine that fails with error 1603: the
/// installer runs a .NET custom action, and Steam's environment has no .NET. This puts Wine Mono in first, then
/// runs the same installer quietly.
public struct EAAppSetup: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    /// The EA app installer an EA game ships, when the game needs the EA app.
    public static func installer(inGame folder: URL) -> URL? {
        let url = folder.appendingPathComponent("__Installer/Origin/redist/internal/EAappInstaller.exe")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The EA app is installed in the environment (any version: it updates itself).
    public static func isInstalled(in bottle: Bottle) -> Bool {
        let root = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return versions.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/EA Desktop/Link2EA.exe").path) }
    }

    /// Whether launching this game needs `ensure` first.
    public static func needsSetup(gameFolder: URL, bottle: Bottle) -> Bool {
        installer(inGame: gameFolder) != nil && (!bottle.hasMono || !isInstalled(in: bottle))
    }

    /// Turns off the EA app's in-game overlay, which breaks games under Wine: with it NFS Most Wanted shows a black
    /// screen on WineD3D and crashes on DXMT. The overlay is a per-account setting (`user.igoEnabled` in
    /// `user_<id>.ini`), and that file only exists after the first sign-in; until then the overlay's DLLs are set
    /// aside instead. Run before every launch: EA app updates bring the DLLs back in a new version folder.
    public static func disableOverlay(in bottle: Bottle) {
        let fm = FileManager.default
        var settingsFound = false
        let users = bottle.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let folder = users.appendingPathComponent("\(user)/AppData/Local/Electronic Arts/EA Desktop")
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("user_") && name.hasSuffix(".ini") {
                let file = folder.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                settingsFound = true
                let updated = overlayOff(in: text)
                if updated != text { try? updated.write(to: file, atomically: true, encoding: .utf8) }
            }
        }
        guard !settingsFound else { return }
        let root = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        for version in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            for dll in ["IGO32.dll", "IGO64.dll"] {
                let url = root.appendingPathComponent("\(version)/EA Desktop/\(dll)")
                if fm.fileExists(atPath: url.path) { try? fm.moveItem(at: url, to: url.appendingPathExtension("off")) }
            }
        }
    }

    /// The settings text with `user.igoEnabled=false` (replacing any value, keeping the file's line endings).
    static func overlayOff(in text: String) -> String { overlay(enabled: false, in: text) }

    static func overlay(enabled: Bool, in text: String) -> String {
        let newline = text.contains("\r\n") || text.isEmpty ? "\r\n" : "\n"
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        lines.removeAll { $0.lowercased().hasPrefix("user.igoenabled=") }
        lines.append("user.igoEnabled=\(enabled)")
        return lines.joined(separator: newline) + newline
    }

    /// Undoes `disableOverlay`: the setting back on, set-aside DLLs back in place.
    public static func enableOverlay(in bottle: Bottle) {
        let fm = FileManager.default
        let users = bottle.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let folder = users.appendingPathComponent("\(user)/AppData/Local/Electronic Arts/EA Desktop")
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("user_") && name.hasSuffix(".ini") {
                let file = folder.appendingPathComponent(name)
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    try? overlay(enabled: true, in: text).write(to: file, atomically: true, encoding: .utf8)
                }
            }
        }
        let root = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        for version in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            for dll in ["IGO32.dll", "IGO64.dll"] {
                let off = root.appendingPathComponent("\(version)/EA Desktop/\(dll).off")
                if fm.fileExists(atPath: off.path) { try? fm.moveItem(at: off, to: off.deletingPathExtension()) }
            }
        }
    }

    /// Installs Wine Mono and then the EA app from the game's own installer. Does nothing already done.
    public func ensure(gameFolder: URL, bottle: Bottle, engine: Engine) async throws {
        guard let installer = Self.installer(inGame: gameFolder) else { return }
        try await WineMono(paths: paths).ensureInstalled(in: bottle, engine: engine)
        guard !Self.isInstalled(in: bottle) else { return }
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: engine)
        // The arguments Steam's install script uses, plus /quiet: no setup window, and the EA app isn't opened.
        let result = try await ProcessRunner.run(engine.wine, [installer.lastPathComponent, "/quiet", "EAX_LAUNCH_CLIENT=0", "IGNORE_INSTALLED=1"],
                                                 environment: env, currentDirectory: installer.deletingLastPathComponent())
        guard result.succeeded, Self.isInstalled(in: bottle) else {
            throw WineRunnerError.launchFailed("couldn't install the EA app")
        }
    }
}
