// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Controller Mode's own settings (its settings screen). Values from other versions that aren't understood keep
/// their defaults.
public struct ControllerModeSettings: Codable, Equatable, Sendable {
    public enum Size: String, Codable, CaseIterable, Sendable {
        case standard, large, extraLarge
        /// How much bigger than the design (1920×1080 at 26 pt) everything is drawn.
        public var scale: Double { switch self { case .standard: 1; case .large: 1.15; case .extraLarge: 1.3 } }
    }
    /// What the Guide button (PS, Xbox) does outside Controller Mode.
    public enum GuideButton: String, Codable, CaseIterable, Sendable { case whileInFront, anywhere, nothing }
    /// What is behind the screens without a game of their own: a warm dark room, or slate blue.
    public enum Background: String, Codable, CaseIterable, Sendable { case warm, cool }
    public enum Labels: String, Codable, CaseIterable, Sendable { case automatic, xbox, playStation }

    public var size: Size = .standard
    /// The display's name to open on; nil is the main one.
    public var display: String?
    public var openWhenControllerConnects = false
    public var labels: Labels = .automatic
    public var background: Background = .warm
    public var sounds = true
    public var guideButton: GuideButton = .whileInFront
    public var keepDisplayAwake = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ControllerModeSettings()
        size = ((try? c.decodeIfPresent(String.self, forKey: .size)) ?? nil).flatMap(Size.init(rawValue:)) ?? d.size
        display = (try? c.decodeIfPresent(String.self, forKey: .display)) ?? nil
        openWhenControllerConnects = (try? c.decodeIfPresent(Bool.self, forKey: .openWhenControllerConnects)) ?? d.openWhenControllerConnects
        labels = ((try? c.decodeIfPresent(String.self, forKey: .labels)) ?? nil).flatMap(Labels.init(rawValue:)) ?? d.labels
        guideButton = ((try? c.decodeIfPresent(String.self, forKey: .guideButton)) ?? nil).flatMap(GuideButton.init(rawValue:)) ?? d.guideButton
        background = ((try? c.decodeIfPresent(String.self, forKey: .background)) ?? nil).flatMap(Background.init(rawValue:)) ?? d.background
        sounds = (try? c.decodeIfPresent(Bool.self, forKey: .sounds)) ?? d.sounds
        keepDisplayAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepDisplayAwake)) ?? d.keepDisplayAwake
    }
}
