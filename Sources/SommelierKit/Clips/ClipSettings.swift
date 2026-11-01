// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the player chose for clips (Settings › Clips). Everything but the switch has a default, and values from
/// other versions that aren't understood keep their defaults.
public struct ClipSettings: Codable, Equatable, Sendable {
    public enum Length: Int, Codable, CaseIterable, Sendable {
        case half = 30, minute = 60, twoMinutes = 120
        public var seconds: Double { Double(rawValue) }
    }

    public enum Quality: String, Codable, CaseIterable, Sendable {
        case light, normal, high

        /// What recording costs: the picture's largest side, frames a second, and the video bit rate.
        public var profile: Profile {
            switch self {
            case .light: Profile(maxHeight: 1080, fps: 30, bitsPerSecond: 12_000_000)
            case .normal: Profile(maxHeight: 1440, fps: 60, bitsPerSecond: 25_000_000)
            case .high: Profile(maxHeight: nil, fps: 60, bitsPerSecond: 50_000_000)
            }
        }

        public struct Profile: Equatable, Sendable {
            public var maxHeight: Int?
            public var fps: Int
            public var bitsPerSecond: Int

            /// Megabytes of video in a minute (what Settings tells the player).
            public var megabytesPerMinute: Int { bitsPerSecond / 8 * 60 / 1_000_000 }
        }
    }

    /// The master switch. Off until the player turns it on, which is also when macOS asks for screen recording.
    public var enabled = false
    public var length: Length = .minute
    public var quality: Quality = .normal
    /// The game's own sound goes into clips (never the microphone, never other apps).
    public var gameSound = true
    /// Save the last 30 seconds when a game crashes or freezes.
    public var saveOnCrash = true
    /// Hold the pad's Share or Create button for a second to save a clip.
    public var controllerButton = true
    /// How much room automatic clips (before a crash) may take, in gigabytes.
    public var automaticLimitGB = 5
    /// Games clips are switched off for (the ⋯ menu on a game's page).
    public var disabledGames: [String] = []
    /// How many games the "⌥⌘S saves…" hint has been shown in, so it stops after three.
    public var hintsShown = 0
    /// The key that saves a clip, as a macOS virtual key code and Carbon modifier flags (⌥⌘S by default).
    public var keyCode = 1
    public var keyModifiers = 2304            // cmdKey (256) | optionKey (2048)

    public static let hintLimit = 3

    public init() {}

    public func records(_ gameID: String) -> Bool { enabled && !disabledGames.contains(gameID) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        length = ((try? c.decodeIfPresent(Int.self, forKey: .length)) ?? nil).flatMap(Length.init(rawValue:)) ?? d.length
        quality = ((try? c.decodeIfPresent(String.self, forKey: .quality)) ?? nil).flatMap(Quality.init(rawValue:)) ?? d.quality
        gameSound = (try? c.decodeIfPresent(Bool.self, forKey: .gameSound)) ?? d.gameSound
        saveOnCrash = (try? c.decodeIfPresent(Bool.self, forKey: .saveOnCrash)) ?? d.saveOnCrash
        controllerButton = (try? c.decodeIfPresent(Bool.self, forKey: .controllerButton)) ?? d.controllerButton
        automaticLimitGB = max(1, (try? c.decodeIfPresent(Int.self, forKey: .automaticLimitGB)) ?? d.automaticLimitGB)
        disabledGames = (try? c.decodeIfPresent([String].self, forKey: .disabledGames)) ?? d.disabledGames
        hintsShown = (try? c.decodeIfPresent(Int.self, forKey: .hintsShown)) ?? d.hintsShown
        keyCode = (try? c.decodeIfPresent(Int.self, forKey: .keyCode)) ?? d.keyCode
        keyModifiers = (try? c.decodeIfPresent(Int.self, forKey: .keyModifiers)) ?? d.keyModifiers
    }

    /// The key as the player reads it: "⌥⌘S".
    public var keyName: String {
        var text = ""
        if keyModifiers & 4096 != 0 { text += "⌃" }
        if keyModifiers & 2048 != 0 { text += "⌥" }
        if keyModifiers & 512 != 0 { text += "⇧" }
        if keyModifiers & 256 != 0 { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "?")
    }

    /// Virtual key codes of the letters, digits and function keys a clip key can be.
    static let keyNames: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12",
    ]

    /// Whether `keyCode` with `modifiers` can be a clip key: a known key with Command, Option or Control held (a
    /// bare letter would eat typing), not the in-game counter's ⌥⌘F.
    public static func isValidKey(code: Int, modifiers: Int) -> Bool {
        guard keyNames[code] != nil, modifiers & (256 | 2048 | 4096) != 0 else { return false }
        return !(code == 3 && modifiers & 0x1F00 == 2304)
    }
}
