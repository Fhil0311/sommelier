// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The interface language. macOS picks an app's language from `AppleLanguages` when the app starts, so a change
/// here is saved for this app only and takes effect after a relaunch (the same as choosing it in System Settings).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", russian = "ru", chinese = "zh-Hans", chineseTraditional = "zh-Hant", japanese = "ja"
    case korean = "ko", german = "de", french = "fr", spanish = "es", portugueseBrazil = "pt-BR", italian = "it"
    case dutch = "nl", swedish = "sv", polish = "pl", ukrainian = "uk", belarusian = "be", turkish = "tr"

    var id: String { rawValue }

    /// The order Settings lists them in: "Same as System" at the top, then the chosen language with Belarusian right
    /// under it, then the others in a fixed mixed order, drawn once at random (23.10.2026).
    static func ordered(selected: AppLanguage) -> [AppLanguage] {
        let mixed: [AppLanguage] = [.korean, .japanese, .ukrainian, .polish, .chinese, .russian, .english, .spanish,
                                    .portugueseBrazil, .french, .swedish, .turkish, .chineseTraditional, .dutch, .german, .italian]
        let rest = mixed + allCases.filter { !mixed.contains($0) && $0 != .system && $0 != .belarusian }   // any added later
        return ([.system, selected, .belarusian] + rest).reduce(into: [AppLanguage]()) { list, language in
            if !list.contains(language) { list.append(language) }
        }
    }

    /// Each language names itself in its own language, as macOS does, so it can be found whatever is on screen.
    var name: String {
        switch self {
        case .system: String(localized: "Same as System")
        case .english: "English"
        case .russian: "Русский"
        case .chinese: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .portugueseBrazil: "Português (Brasil)"
        case .italian: "Italiano"
        case .dutch: "Nederlands"
        case .swedish: "Svenska"
        case .polish: "Polski"
        case .ukrainian: "Українська"
        case .belarusian: "Беларуская"
        case .turkish: "Türkçe"
        }
    }

    static var current: AppLanguage {
        guard let saved = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
              UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil,
              let first = saved.first else { return .system }
        // Traditional Chinese comes as zh-Hant or a region that uses it (zh-TW, zh-HK, zh-MO); other zh is Simplified.
        if first.hasPrefix("zh") {
            return ["zh-Hant", "zh-TW", "zh-HK", "zh-MO"].contains(where: first.hasPrefix) ? .chineseTraditional : .chinese
        }
        if first.hasPrefix("pt") { return .portugueseBrazil }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    /// The language the app is showing right now (it changes only after a relaunch).
    static var running: String { Bundle.main.preferredLocalizations.first ?? "en" }

    func apply() {
        switch self {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        default: UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// What the helper runs: wait for the old copy to be gone (at most two minutes), then start a new one. `$1` is the
    /// app, `$2` the old copy's process id. Not started if the old copy never quits (the player answered "Cancel" to
    /// "a game is still running"): then nothing opens, and the old copy simply stays.
    static let relaunchScript = #"i=0; while kill -0 "$2" 2>/dev/null; do sleep 0.3; i=$((i+1)); [ $i -gt 400 ] && exit 0; done; exec /usr/bin/open -n "$1""#

    /// Quits this copy, then starts a fresh one: one after the other, so two copies never run together (the new one
    /// would start while the old one is still closing Steam and the launchers under it) and none is left behind.
    static func relaunch() {
        cancelRelaunch()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", relaunchScript, "sommelier-relaunch", Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do { try helper.run() } catch { return }                // couldn't start the helper: stay, rather than quit for nothing
        pendingHelper = helper
        isRelaunching = true                                     // see applicationShouldTerminate: only the app restarts
        NSApp.terminate(nil)
    }

    /// The helper waiting to start the new copy; the quit may still be cancelled (a game is running and the player said Cancel).
    nonisolated(unsafe) private static var pendingHelper: Process?

    /// The quit was cancelled: no new copy must start later because the player quit by hand.
    static func cancelRelaunch() {
        pendingHelper?.terminate()
        pendingHelper = nil
        isRelaunching = false
    }

    /// The app is quitting only to start again (a new language): what it started (Steam, launchers, games) keeps
    /// running, and the new copy picks it up as it does after any restart. Nothing to ask, nothing to wait for.
    nonisolated(unsafe) static var isRelaunching = false
}
