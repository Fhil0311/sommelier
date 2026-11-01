// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Unreal Engine games (hundreds of them): `AppData/Local/<Project>/Saved/Config/<Windows|WindowsNoEditor>/
/// GameUserSettings.ini`, with the engine's scalability groups (0 low … 3 epic) and the resolution.
public struct UnrealSettings: TuningAdapter {
    public let id = "unreal"
    public init() {}

    /// The project: a folder of the game with `Binaries/Win64/*.exe` and `Content/Paks` (how Unreal packages a
    /// game). `confident` when its executable is named after it (`<Project>-Win64-Shipping.exe` or `<Project>.exe`),
    /// so a settings folder can be made for it before the game's first run.
    static func project(in folder: URL) -> (name: String, confident: Bool, dir: URL)? {
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []) + [folder]
        for dir in candidates {
            guard fm.fileExists(atPath: dir.appendingPathComponent("Content/Paks").path),
                  let exes = try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("Binaries/Win64").path),
                  exes.contains(where: { $0.lowercased().hasSuffix(".exe") }) else { continue }
            let name = dir.lastPathComponent
            let confident = exes.contains { $0.caseInsensitiveCompare("\(name)-Win64-Shipping.exe") == .orderedSame
                || $0.caseInsensitiveCompare("\(name).exe") == .orderedSame }
            return (name, confident, dir)
        }
        return nil
    }

    static let platforms = ["Windows", "WindowsNoEditor"]

    /// Where a game may keep its settings: most in `AppData/Local/<Project>/Saved/Config`, some (Deep Rock
    /// Galactic) next to the game, in `<Project>/Saved/Config`. Which one is the game's build setting, not
    /// something its files say.
    static func configFolders(for game: Game, bottle: Bottle) -> (project: (name: String, confident: Bool, dir: URL), folders: [URL])? {
        guard let folder = game.installPath, let project = Self.project(in: folder),
              let user = GOGSaveLocations.userFolder(in: bottle) else { return nil }
        return (project, [user.appendingPathComponent("AppData/Local/\(project.name)/Saved/Config", isDirectory: true),
                          project.dir.appendingPathComponent("Saved/Config", isDirectory: true)])
    }

    public func files(for game: Game, bottle: Bottle) -> [URL] {
        guard let (project, folders) = Self.configFolders(for: game, bottle: bottle) else { return [] }
        let fm = FileManager.default
        // The game's own settings, wherever it wrote them (after its first run).
        let existing = folders.flatMap { config in
            Self.platforms.map { config.appendingPathComponent("\($0)/GameUserSettings.ini") }.filter { fm.fileExists(atPath: $0.path) }
        }
        if !existing.isEmpty { return existing }
        guard project.confident else { return [] }      // not sure it is the game's project: wait for its first run
        // Before the first run nothing says which folder the game reads: both get the settings (the other is ignored).
        return folders.flatMap { config in Self.platforms.map { config.appendingPathComponent("\($0)/GameUserSettings.ini") } }
    }

    public func tuned(_ text: String?, file: URL, level: TuningLevel, power: MacPower) -> String? {
        let (w, h) = power.resolution(for: level)
        let quality = "\(level.rawValue)"
        var values: [(section: String, key: String, value: String)] = [
            "sg.ViewDistanceQuality", "sg.AntiAliasingQuality", "sg.ShadowQuality", "sg.GlobalIlluminationQuality",
            "sg.ReflectionQuality", "sg.PostProcessQuality", "sg.TextureQuality", "sg.EffectsQuality",
            "sg.FoliageQuality", "sg.ShadingQuality",
        ].map { (section: "ScalabilityGroups", key: $0, value: quality) }
        values.append((section: "ScalabilityGroups", key: "sg.ResolutionQuality", value: level == .low ? "75" : "100"))
        // The resolution lives in the settings class's own section. A game with a class of its own (Expedition 33:
        // `/Script/SandFall.ConfigurableGameUserSettings`) reads that one over the engine's, so every such section
        // the file has gets the values; the engine's when the file has none yet.
        for settings in Self.settingsSections(in: text) {
            for (key, value) in [("ResolutionSizeX", "\(w)"), ("ResolutionSizeY", "\(h)"),
                                 ("LastUserConfirmedResolutionSizeX", "\(w)"), ("LastUserConfirmedResolutionSizeY", "\(h)"),
                                 ("FullscreenMode", "1"), ("LastConfirmedFullscreenMode", "1"), ("PreferredFullscreenMode", "1")] {
                values.append((section: settings, key: key, value: value))
            }
        }
        return IniFile.setting(values, in: text)
    }

    /// The `[/Script/<Module>.<Class>GameUserSettings]` sections of the file, the engine's own when there are none.
    static func settingsSections(in text: String?) -> [String] {
        let found = (text ?? "").components(separatedBy: .newlines).compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[/Script/"), t.hasSuffix("GameUserSettings]") else { return nil }
            return String(t.dropFirst().dropLast())
        }
        return found.isEmpty ? ["/Script/Engine.GameUserSettings"] : found
    }
}
