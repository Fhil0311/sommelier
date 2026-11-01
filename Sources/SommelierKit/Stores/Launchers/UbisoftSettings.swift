// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Ubisoft Connect's own settings (`AppData/Local/Ubisoft Game Launcher/settings.yaml`, a flat YAML the launcher
/// rewrites when it quits). Its in-game overlay hooks `dxgi.dll` and draws with a D3D10 device of its own inside
/// the game, which leaves Watch Dogs 2 on a black screen under Wine (Lutris switches the overlay off for the same
/// reason); nothing of it works here anyway.
public enum UbisoftSettings {
    /// The settings text with the overlay off, and without the launcher's "turn the overlay back on?" question when
    /// a game starts (the launcher's window is hidden, so the player wouldn't see it and the game would wait). Only
    /// those two lines of the `overlay:` block change; a file without the block gets one (the launcher merges it
    /// with its defaults on start).
    public static func overlayDisabled(_ yaml: String) -> String {
        var lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inOverlay = false, found = false
        for i in lines.indices {
            let line = lines[i]
            if !line.hasPrefix(" ") { inOverlay = line == "overlay:"; found = found || inOverlay; continue }
            let setting = line.trimmingCharacters(in: .whitespaces)
            if inOverlay, setting == "enabled: true" || setting == "warning_enabled: true" {
                lines[i] = line.replacingOccurrences(of: "true", with: "false")
            }
        }
        if found { return lines.joined(separator: "\n") }
        let block = "overlay:\n  enabled: false\n  warning_enabled: false\n"
        if yaml.isEmpty { return block }
        return yaml.hasSuffix("\n") ? yaml + block : yaml + "\n" + block
    }

    /// Switches the overlay off for every account folder in the bottle. Done before the launcher starts: it reads the
    /// file then and writes it back on quit.
    public static func disableOverlay(in bottle: Bottle) {
        let fm = FileManager.default
        let users = bottle.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            let folder = users.appendingPathComponent("\(user)/AppData/Local/Ubisoft Game Launcher")
            guard fm.fileExists(atPath: folder.path) else { continue }
            let file = folder.appendingPathComponent("settings.yaml")
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let updated = overlayDisabled(text)
            if updated != text { try? updated.write(to: file, atomically: true, encoding: .utf8) }
        }
    }
}
