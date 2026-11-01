// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How one game is started: graphics backend, display and input options, the player's own variables, arguments
/// and DLL overrides. Only data; `WineRunner` turns it into an environment. Saved in the library as JSON.
public struct LaunchProfile: Codable, Hashable, Sendable {
    public var backend = GraphicsBackend.auto
    /// Apple's Metal performance overlay.
    public var performanceHUD = false
    /// Hand the game the display's real pixels (4x the points on Retina). Off by default: it's by far the
    /// heaviest option, and scaled-up output looks fine in most games.
    public var retina = false
    /// Wine logs warnings about module loading too, not only errors.
    public var verboseLogs = false
    /// D3DMetal: MetalFX upscaling for games that offer NVIDIA DLSS.
    public var metalFX = false
    /// D3DMetal: DirectX Raytracing on the Apple GPUs that can do it.
    public var rayTracing = true
    /// ⌘ works as Ctrl, so Windows shortcuts like Ctrl+S keep working.
    public var commandAsControl = false
    /// Let the game output HDR where the Mac's display shows it (DXMT reports HDR10). When off, DXMT reports SDR.
    public var hdr = true
    /// The player's own `KEY=value` variables, applied last.
    public var extraEnvironment = [String: String]()
    /// Arguments added after the store's own.
    public var extraArguments = [String]()
    /// Per-DLL `WINEDLLOVERRIDES` entries: name → `n`, `b`, `n,b`, `b,n`, or empty to disable the DLL.
    public var dllOverrides = [String: String]()
    /// Start another program than the launcher the store starts (paths relative to the game's folder).
    public var redirect: ExecutableRedirect?
    /// DXMT "Turbo": render at the display's size in points and let MetalFX scale up to its pixels. Never saved;
    /// Sommelier decides it per launch.
    public var turbo = false
    /// This launch is a game's (not a store, a launcher, an installer or Wine's own set-up). Only a game hears the
    /// microphone, so macOS asks for it when a game opens it, as for any Mac app, and never on a store's behalf.
    /// Never saved, like Turbo: set per launch.
    public var forGame = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case backend
        case performanceHUD
        case retina
        case verboseLogs
        case metalFX
        case rayTracing
        case commandAsControl
        case hdr
        case extraEnvironment
        case extraArguments
        case dllOverrides
        case redirect
    }

    /// Tolerant decoding: any key that's absent keeps its default, so profiles written by earlier builds load.
    public init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        func load<Value: Decodable>(_ key: CodingKeys, or fallback: Value) throws -> Value {
            try saved.decodeIfPresent(Value.self, forKey: key) ?? fallback
        }
        self.init()
        backend = try load(.backend, or: backend)
        performanceHUD = try load(.performanceHUD, or: performanceHUD)
        retina = try load(.retina, or: retina)
        verboseLogs = try load(.verboseLogs, or: verboseLogs)
        metalFX = try load(.metalFX, or: metalFX)
        rayTracing = try load(.rayTracing, or: rayTracing)
        commandAsControl = try load(.commandAsControl, or: commandAsControl)
        hdr = try load(.hdr, or: hdr)
        extraEnvironment = try load(.extraEnvironment, or: extraEnvironment)
        extraArguments = try load(.extraArguments, or: extraArguments)
        dllOverrides = try load(.dllOverrides, or: dllOverrides)
        redirect = try saved.decodeIfPresent(ExecutableRedirect.self, forKey: .redirect)
    }
}

/// A recipe's launcher bypass: where the store would start `instead` (the tail of the launcher's path inside the
/// game's folder), start `run`, given relative to the launcher's folder as protonfixes write it. Either slash.
public struct ExecutableRedirect: Codable, Hashable, Sendable {
    public var instead: String
    public var run: String

    public init(instead: String, run: String) {
        self.instead = instead
        self.run = run
    }
}

public extension LaunchProfile {
    /// Reads the variables field: one `KEY=value` per line. Blank lines, `#` comments and lines whose key isn't
    /// made of letters, digits and underscores are skipped; spaces around key and value are dropped.
    static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in text.split(whereSeparator: \.isNewline) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.first == "#" { continue }
            guard let separator = trimmed.firstIndex(of: "="), separator > trimmed.startIndex else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            if !name.allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) { continue }
            result[name] = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// The inverse of `parseEnvironment`, one line per variable in key order.
    static func formatEnvironment(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }

    /// Splits the arguments field at spaces. Double quotes group words (`-name "Two Words"`) and are removed;
    /// `""` gives an empty argument.
    static func parseArguments(_ text: String) -> [String] {
        var result: [String] = []
        var word: String?            // nil between arguments
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                word = word ?? ""
            } else if character.isWhitespace, !quoted {
                if let finished = word { result.append(finished) }
                word = nil
            } else {
                word = (word ?? "") + String(character)
            }
        }
        if let word { result.append(word) }
        return result
    }
}
