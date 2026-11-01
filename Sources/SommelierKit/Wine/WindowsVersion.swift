// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Windows version one program sees, through Wine's per-program settings
/// (`HKCU\Software\Wine\AppDefaults\<exe>\Version`): a game that refuses to run on "Windows 10" can be told it's
/// on 7. The bottle's own version (the other games') stays.
public struct WindowsVersion: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    static func key(for exe: String) -> String { "HKCU\\Software\\Wine\\AppDefaults\\\(exe)" }

    /// `wine reg add` for the program; `nil` version deletes the setting.
    @discardableResult
    public func set(_ version: String?, for exe: String, in bottle: Bottle, engine: Engine) async -> Bool {
        guard bottle.exists, exe.lowercased().hasSuffix(".exe"), !exe.contains("\\"), !exe.contains("/") else { return false }
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: engine)
        let args = version.map { ["reg", "add", Self.key(for: exe), "/v", "Version", "/t", "REG_SZ", "/d", $0, "/f"] }
            ?? ["reg", "delete", Self.key(for: exe), "/v", "Version", "/f"]
        return (try? await ProcessRunner.run(engine.wine, args, environment: env))?.succeeded == true
    }
}
