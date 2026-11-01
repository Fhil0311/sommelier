// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Store launchers and their helper programs stay out of the Dock and Cmd-Tab: only Sommelier and games show
/// there. Each program gets `ShowInDock=n` in `HKCU\Software\Wine\AppDefaults\<exe>\Mac Driver`, an option of
/// Sommelier's Mac driver; their windows still work and come forward when Sommelier opens the launcher.
public struct DockVisibility: Sendable {
    /// Bump when the lists change, so bottles set up before get the new entries.
    static let version = 1

    /// The programs to keep out of the Dock, per environment.
    public static let hidden: [BottleKind: [String]] = [
        .steam: ["steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe", "steamerrorreporter.exe", "steamerrorreporter64.exe",
                 "steamsysinfo.exe", "streaming_client.exe", "gameoverlayui.exe", "gameoverlayui64.exe", "uninstall.exe"],
        .ea: ["EADesktop.exe", "EABackgroundService.exe", "EACefSubProcess.exe", "EAConnect_microsoft.exe", "EACrashReporter.exe",
              "EAEgsLauncher.exe", "EAEgsProxy.exe", "EAGEP.exe", "EALaunchHelper.exe", "EALauncher.exe", "EALocalHostSvc.exe",
              "EASteamAuthHelper.exe", "EASteamLauncher.exe", "EASteamProxy.exe", "EAUninstall.exe", "EAUpdater.exe",
              "ErrorReporter.exe", "GetGameToken.exe", "IGOProxy32.exe", "Link2EA.exe", "OriginLegacyCompatibility.exe",
              "PolicyProxy32.exe", "PolicyProxy64.exe"],
        .ubisoft: ["upc.exe", "UbisoftConnect.exe", "UbisoftExtension.exe", "UbisoftGameLauncher.exe", "UbisoftGameLauncher64.exe",
                   "UpcElevationService.exe", "UplayCrashReporter.exe", "UplayService.exe", "UplayWebCore.exe", "WriteMiniDump.exe",
                   "Uninstall.exe"],
        .battlenet: ["Battle.net.exe", "Battle.net Launcher.exe", "Agent.exe", "BlizzardError.exe", "Battle.net Uninstaller.exe"],
    ]

    /// Where the bottles are.
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    /// The registry file that hides a bottle's launcher programs.
    static func registryFile(for kind: BottleKind) -> String {
        var text = "REGEDIT4\n"
        for exe in hidden[kind] ?? [] {
            text += "\n[HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(exe)\\Mac Driver]\n\"ShowInDock\"=\"n\"\n"
        }
        return text
    }

    /// Writes the settings into the bottle once (again when the lists change). Quick when already done.
    public func apply(_ kind: BottleKind, engine: Engine) async {
        let bottle = BottleManager(paths: paths).bottle(kind)
        guard bottle.exists, !(Self.hidden[kind] ?? []).isEmpty else { return }
        let marker = bottle.url.appendingPathComponent(".sommelier-dock")
        if (try? String(contentsOf: marker, encoding: .utf8)) == "\(Self.version)" { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-dock-\(kind.rawValue).reg")
        guard (try? Self.registryFile(for: kind).write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try? await ProcessRunner.run(engine.wine, ["reg", "import", file.path],
                                                  environment: WineRunner.environment(bottle: bottle, profile: .init()))
        if result?.succeeded == true { try? "\(Self.version)".write(to: marker, atomically: true, encoding: .utf8) }
    }
}
