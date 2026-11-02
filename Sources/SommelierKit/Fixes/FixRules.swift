// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The things Sommelier can do to fix a launch. A closed list: a rule, built in or from the fixes list online, can
/// only pick one of these, never run anything else. Each knows how to undo itself where that makes sense.
public enum FixAction: Codable, Equatable, Sendable {
    case switchGraphics(GraphicsBackend)
    /// Wine Mono, the .NET runtime, into the game's environment.
    case installDotNet
    /// The Visual C++ runtime DLLs, copied from an environment that has them.
    case installVCRuntime
    case disableEAOverlay
    /// Environment variables added to the game's launch profile.
    case setEnvironment([String: String])
    /// Opens the DirectX 12 (D3DMetal) set-up.
    case setUpDirectX12
    /// The EA app, from the game's own installer.
    case setUpEAApp
    /// Turbo (MetalFX upscaling) off for the game: it draws at the full resolution.
    case turnOffTurbo
    /// A DLL override for the game (`WINEDLLOVERRIDES`): "n" native, "b" builtin, "n,b", "b,n" or "" disabled.
    case overrideDLL(String, String)
    /// The game starts from `run` (relative to its folder) where its store would start `instead` (a launcher).
    case runExecutable(instead: String, run: String)
    /// The Windows version the game's program sees ("win7", "win10", "winxp"): Wine's AppDefaults for the exe.
    case setWindowsVersion(version: String, exe: String)
    /// Arguments added to the game's launch.
    case addArguments([String])
    /// A runtime from its maker's own package (`Component`), into the game's environment, with the game's DLL
    /// overrides set to use it.
    case installComponent(Component)
    /// A value in the game's own settings file (`GameConfigFile` spec): a key in a section, or with `field` a field
    /// of the struct the key holds. `${level}` in the value is the tuning level the Mac gets.
    case editConfig(file: String, section: String, key: String, field: String?, value: String)
    /// Whole-number values inside a struct of the game's Unreal save file (`GameConfigFile` spec, `.sav`;
    /// `UnrealSave`): games that keep their options in a save and apply them over the ini. `${level}` as before.
    case editSave(file: String, structName: String, values: [String: String])
    /// The game draws PlayStation buttons when told so in its settings (Unreal's CommonUI: `DefaultGamepadName=PS5`
    /// in `Game.ini`): written before each launch while a PlayStation controller is connected, taken out when none is
    /// (AppModel+Controllers). Only for games known to ship the PlayStation glyphs. Not an applied fix: nothing to undo.
    case playStationPrompts(file: String, section: String, values: [String: String])
    /// Files another mod loader left in the game (`ModPath` specs, from the mods profile's `cleanBeforeVanilla`),
    /// moved into the game's mod store before a launch without mods (`LaunchGuard`). Nothing of Sommelier's own.
    case removeModLeftovers([String])
    /// A mod in the game's store, by its key, turned off: its loader named it in a log (`ModDiagnostics`). The
    /// files stay in the store; where the loader allows it the mod is only marked off (`ModDeployer.setEnabled`).
    case disableMod(String)
    /// A framework (mod loader), by its id, turned off for the launch without removing it: its `disableArgument`
    /// added where it has one, else its DLL overrides and redirect taken out of the launch profile.
    case disableFramework(String)

    /// A fix about the game's mods: never part of a report or a recipe (`CompatibilityReport.Settings`), since
    /// a mod's key would name it and a loader's override is no way to run the game.
    public var concernsMods: Bool {
        switch self {
        case .removeModLeftovers, .disableMod, .disableFramework: true
        default: false
        }
    }

    /// The environment variables a rule or recipe may set: graphics and Wine tuning only. Anything else
    /// (`DYLD_*`, `WINESERVER`, `WINELOADER`, `PATH`, `HOME`…) could make Wine load or start another program,
    /// so a list from the service can't set it, whatever the service accepted.
    public static func allowsEnvironment(_ key: String) -> Bool {
        let prefixes = ["DXMT_", "D3DM_", "MTL_", "DXVK_", "VKD3D_", "MVK_"]
        let names: Set<String> = ["SOMMELIER_HIDE_WINE", "SOMMELIER_FORCE_SDR", "SOMMELIER_NO_MIC",
                                  "WINE_LARGE_ADDRESS_AWARE", "WINEESYNC", "WINEMSYNC", "WINEDEBUG",
                                  "SOMMELIER_VIDEO_SYSMEM", "WINE_ROSETTA_CPUID7_OR"]
        return names.contains(key) || prefixes.contains { key.hasPrefix($0) && key.count > $0.count }
    }

    /// Not a fix to apply once and record, but a setting kept right before each launch (`playStationPrompts`):
    /// Fix Launch and the applied fixes leave it out.
    public var isBeforeEachLaunch: Bool {
        if case .playStationPrompts = self { return true }
        return false
    }

    /// A settings edit that follows the tuning level (`${level}`): part of "matched to this Mac", done with it.
    public var followsTuning: Bool {
        switch self {
        case .editConfig(_, _, _, _, let value): GameConfigEditor.followsMac(value)
        case .editSave(_, _, let values): values.values.contains { GameConfigEditor.followsMac($0) }
        default: false
        }
    }

    /// A plain description of the change.
    public var summary: String {
        switch self {
        case .switchGraphics(let backend): "Switch graphics to \(backend.displayName)"
        case .installDotNet: "Install the .NET runtime"
        case .installVCRuntime: "Install the Visual C++ runtime"
        case .disableEAOverlay: "Turn off the EA app's in-game overlay"
        case .setEnvironment(let env): "Set \(env.keys.sorted().joined(separator: ", "))"
        case .setUpDirectX12: "Set up DirectX 12"
        case .setUpEAApp: "Set up the EA app"
        case .turnOffTurbo: "Turn off Turbo"
        case .overrideDLL(let dll, let mode): "Override \(dll) (\(mode.isEmpty ? "disabled" : mode))"
        case .runExecutable(_, let run): "Start \(run) instead of the launcher"
        case .setWindowsVersion(let version, _): "Have the game see Windows \(Self.windowsName(version))"
        case .addArguments(let args): "Add \(args.joined(separator: " "))"
        case .installComponent(let component): "Install \(component.displayName)"
        case .editConfig(_, _, let key, let field, let value): "Game settings: \(field ?? key) = \(value)"
        case .editSave(_, _, let values): "Game settings: \(Self.listing(values))"
        case .playStationPrompts: "Game settings: PlayStation button prompts"
        case .removeModLeftovers: "Remove leftover mod files"
        case .disableMod(let key): "Turn off the mod \(key)"
        case .disableFramework(let id): "Turn off \(id)"
        }
    }

    /// Whether Sommelier can put things back afterwards.
    public var isUndoable: Bool {
        switch self {
        case .switchGraphics, .installVCRuntime, .disableEAOverlay, .setEnvironment, .turnOffTurbo,
             .overrideDLL, .runExecutable, .setWindowsVersion, .addArguments: true
        case .installComponent(let component): component.isUndoable
        case .editConfig, .editSave, .playStationPrompts: true
        case .installDotNet, .setUpDirectX12, .setUpEAApp: false      // harmless to keep, and nothing of the game's
        case .removeModLeftovers: false                                // kept in the mod store's `.leftovers/`, not in the fixes list
        case .disableMod, .disableFramework: true
        }
    }

    /// "OverallScalabilityLevel +10 = 2": the first key, how many more, and the value when they share one.
    public static func listing(_ values: [String: String]) -> String {
        let keys = values.keys.sorted()
        guard let first = keys.first else { return "" }
        let same = Set(values.values).count == 1
        let names = keys.count > 1 ? "\(first) +\(keys.count - 1)" : first
        return same ? "\(names) = \(values[first]!)" : names
    }

    /// Wine's version names as people say them ("win7" → "7").
    public static func windowsName(_ version: String) -> String {
        let names = ["winxp": "XP", "winxp64": "XP", "vista": "Vista", "win7": "7", "win8": "8", "win81": "8.1", "win10": "10", "win11": "11"]
        return names[version] ?? version
    }

    /// Versions a rule or recipe may set.
    public static let windowsVersions = ["winxp", "winxp64", "vista", "win7", "win8", "win81", "win10", "win11"]
    /// Override modes a rule or recipe may set.
    public static let overrideModes = ["", "n", "b", "n,b", "b,n", "d"]
}

/// When a rule applies, beyond its patterns.
public enum FixCondition: Codable, Equatable, Sendable {
    case backendIs(GraphicsBackend)
    case backendIsNot(GraphicsBackend)
    case store(StoreKind)
    case notNative
    case noD3DMetal
    /// Only this game (its id, "steam:271590"): for fixes found for one game.
    case game(String)
    /// The game starts through this launcher ("ea", "ubisoft", "rockstar"), as its files say (`GameFacts`).
    case launcherIs(String)
    /// The game ships an anti-cheat (Easy Anti-Cheat, BattlEye).
    case hasAntiCheat
    /// The game's engine ("unreal", "unity").
    case engineIs(String)
    /// The game ships Epic Online Services.
    case usesEpicOnlineServices
}

/// "This in the log means that, and this fixes it." Patterns are regular expressions; one match is enough.
public struct FixRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// What went wrong, in plain words, for the user (English).
    public var cause: String
    /// The same in other languages, by language code ("ru", "zh-Hans"): rules from the fixes list online carry
    /// their own translations.
    public var causes: [String: String]? = nil
    public var patterns: [String]
    public var conditions: [FixCondition] = []
    /// Nil: a known problem Sommelier can't fix (the text says what the user can do).
    public var action: FixAction?

    public init(id: String, cause: String, patterns: [String], conditions: [FixCondition] = [], action: FixAction? = nil,
                causes: [String: String]? = nil) {
        self.id = id; self.cause = cause; self.patterns = patterns; self.conditions = conditions; self.action = action
        self.causes = causes
    }

    private enum CodingKeys: String, CodingKey { case id, cause, causes, patterns, conditions, action }

    /// Rules in the fixes list leave out what they don't need (no conditions, no action, no translations).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cause = try c.decode(String.self, forKey: .cause)
        causes = try c.decodeIfPresent([String: String].self, forKey: .causes)
        patterns = try c.decode([String].self, forKey: .patterns)
        conditions = try c.decodeIfPresent([FixCondition].self, forKey: .conditions) ?? []
        action = try c.decodeIfPresent(FixAction.self, forKey: .action)
    }
}

/// What the matcher knows about the launch besides the logs.
public struct FixContext: Sendable {
    public var gameID: String? = nil
    public var backend: GraphicsBackend
    public var store: StoreKind
    public var native: Bool
    public var d3dMetalReady: Bool
    /// Rules already applied to this game: they aren't offered again.
    public var appliedRuleIDs: Set<String>
    /// What the game's files say (nil: not known, and rules that ask aren't offered).
    public var facts: GameFacts?
    public init(gameID: String? = nil, backend: GraphicsBackend, store: StoreKind, native: Bool, d3dMetalReady: Bool,
                appliedRuleIDs: Set<String> = []) {
        self.gameID = gameID; self.backend = backend; self.store = store; self.native = native; self.d3dMetalReady = d3dMetalReady; self.appliedRuleIDs = appliedRuleIDs
    }

    public init(gameID: String? = nil, backend: GraphicsBackend, store: StoreKind, native: Bool, d3dMetalReady: Bool,
                appliedRuleIDs: Set<String> = [], facts: GameFacts?) {
        self.init(gameID: gameID, backend: backend, store: store, native: native, d3dMetalReady: d3dMetalReady, appliedRuleIDs: appliedRuleIDs)
        self.facts = facts
    }
}

public enum FixRules {
    /// What's been seen so far. Order matters: the first match is what the user is offered.
    public static let builtIn: [FixRule] = [
        FixRule(id: "anticheat", cause: "This game's anti-cheat (Easy Anti-Cheat or BattlEye) refuses to run under Wine on a Mac. Online play can't work; single-player modes may, if the game has them.",
                patterns: [#"EasyAntiCheat|BEService|BattlEye|EAC_"#], conditions: [.notNative, .hasAntiCheat]),
        FixRule(id: "ea-app-missing", cause: "The game starts through the EA app, which isn't set up in Steam's environment yet.",
                patterns: [#"steam2ea://|AppError_28|ThreadShellExecute returned no PID"#], conditions: [.store(.steam), .notNative, .launcherIs("ea")], action: .setUpEAApp),
        FixRule(id: "dotnet", cause: "The game, or its installer, needs the .NET runtime, which the environment doesn't have yet.",
                patterns: [#"(?i)\.NET Framework|mscoree\.dll.*(not found|failed)|returned 1603|JunoInitializeSession|System\.(IO|Runtime)\..*Exception"#],
                conditions: [.notNative], action: .installDotNet),
        FixRule(id: "directx12", cause: "The game needs DirectX 12. Set up Apple's D3DMetal once, then DirectX 12 games can run.",
                patterns: [#"D3D12CreateDevice|d3d12\.dll|(?i)DirectX ?12 (is )?(required|not supported)|DXGI_ERROR_UNSUPPORTED"#],
                conditions: [.notNative, .noD3DMetal], action: .setUpDirectX12),
        FixRule(id: "vcruntime", cause: "The game needs the Visual C++ runtime, which the environment doesn't have.",
                patterns: [#"import_dll Library (mfc1\d0u?|msvcp1\d0|vcruntime1\d0|msvcr1\d0)\.dll"#], conditions: [.notNative], action: .installVCRuntime),
        FixRule(id: "ea-overlay", cause: "The EA app's in-game overlay crashed the game. It breaks games under Wine.",
                patterns: [#"IGO(32|64)\.dll|IGOProxy"#], conditions: [.notNative, .launcherIs("ea")], action: .disableEAOverlay),
        FixRule(id: "vulkan", cause: "The game asked for Vulkan (DXVK), which this engine doesn't have. DXMT runs Direct3D 11 games on Metal instead.",
                patterns: [#"(?i)vulkan|VK_ERROR|libvulkan"#], conditions: [.notNative, .backendIsNot(.dxmt)], action: .switchGraphics(.dxmt)),
        FixRule(id: "d3d11-fail", cause: "Direct3D 11 failed to start on Wine's own graphics. DXMT runs Direct3D 11 on Metal and works for most games.",
                patterns: [#"err:d3d|err:wined3d|Failed to create (a |the )?D3D11 ?device|D3D11CreateDevice.*(failed|E_FAIL)"#],
                conditions: [.notNative, .backendIsNot(.dxmt)], action: .switchGraphics(.dxmt)),
        FixRule(id: "dxmt-fail", cause: "The game crashed in DXMT's Metal translation. Wine's own graphics are slower but run more games.",
                patterns: [#"winemetal|dxmt.*(err|fatal|assert)|(?i)MTLCommandBuffer.*error"#],
                conditions: [.notNative, .backendIs(.dxmt)], action: .switchGraphics(.wined3d)),
        FixRule(id: "eos-overlay", cause: "The Epic Online Services overlay crashed the game. It doesn't work under Wine; the game itself runs without it.",
                patterns: [#"EOSOVH-Win(64|32)-Shipping\.dll"#], conditions: [.notNative, .usesEpicOnlineServices]),
        FixRule(id: "video-playback", cause: "The game plays a video through Windows Media Foundation, which this engine can't decode yet. Some games skip the video; others wait on it or crash.",
                patterns: [#"err:mf(plat|readwrite|src|srcwrap)?:|(?i)mfplat.*(failed|error)|(?i)failed to (create|initiali[sz]e) (the )?media (foundation|session|engine)"#],
                conditions: [.notNative]),
        FixRule(id: "cpu-features", cause: "The game checks for CPU instructions (AVX) that Rosetta doesn't fully provide. There's no fix yet; a game with a legacy or compatibility executable may run with that one.",
                patterns: [#"(?i)\bAVX2?\b.{0,60}(not supported|required|unsupported|missing|isn't supported)|(?i)(requires?|needs?) .{0,40}\bAVX2?\b|(?i)unsupported (cpu|processor)|(?i)does not support (the )?AVX"#],
                conditions: [.notNative]),
        // Steam's own gldriverquery.exe asks for SDL2.dll in every launch log: not the game's problem.
        FixRule(id: "missing-dll", cause: "A library the game needs is missing from the environment. The log names it; this is usually a runtime the game's installer would have added.",
                patterns: [#"import_dll Library (?!SDL2\.dll)\S+\.dll \(which is needed by L"(?!C:\\\\Program Files \(x86\)\\\\Steam\\\\bin\\\\)"#], conditions: [.notNative]),
        FixRule(id: "mac-32bit", cause: "This Mac version is 32-bit and can't run on today's macOS. The Windows version runs through Sommelier instead.",
                patterns: [#"Bad CPU type in executable|(?i)32-bit.*not supported"#]),
    ]

    /// A rule that matched, with the line that made it and how much that line is worth.
    public struct Match: Equatable, Sendable {
        public let rule: FixRule
        /// The line of the logs (or crash report) that matched, trimmed.
        public let evidence: String
        public let weight: Int
    }

    /// Rules that explain little by themselves: they come after anything more specific.
    static let generic: Set<String> = ["missing-dll", "video-playback"]

    /// The matches, most telling first: a crash report naming the cause outweighs the game's log, which outweighs
    /// Steam's notes; a generic rule loses a point. Same weight: the list's order.
    public static func ranked(_ d: LaunchDiagnostics, context: FixContext, rules: [FixRule] = builtIn) -> [Match] {
        let sources: [(text: String, weight: Int)] = [(d.crashReport ?? "", 3), (d.logTail, 2), (d.launcherLogTail ?? "", 2),
                                                      (d.modLogTail ?? "", 2), (d.steamLogTail ?? "", 1)]
        var out: [(match: Match, order: Int)] = []
        for (order, rule) in rules.enumerated() {
            guard !context.appliedRuleIDs.contains(rule.id), rule.conditions.allSatisfy({ holds($0, context) }) else { continue }
            var best: Match?
            for source in sources where !source.text.isEmpty {
                for pattern in rule.patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern),
                          let m = regex.firstMatch(in: source.text, range: NSRange(source.text.startIndex..., in: source.text)),
                          let range = Range(m.range, in: source.text) else { continue }
                    let line = source.text[source.text.lineRange(for: range)].trimmingCharacters(in: .whitespacesAndNewlines)
                    let weight = source.weight - (generic.contains(rule.id) ? 1 : 0)
                    if best.map({ weight > $0.weight }) ?? true { best = Match(rule: rule, evidence: String(line.prefix(300)), weight: weight) }
                }
            }
            if let best { out.append((best, order)) }
        }
        return out.sorted { $0.match.weight != $1.match.weight ? $0.match.weight > $1.match.weight : $0.order < $1.order }.map(\.match)
    }

    /// Rules whose patterns match the diagnostics and whose conditions hold, most telling first (`ranked`).
    public static func match(_ diagnostics: LaunchDiagnostics, context: FixContext, rules: [FixRule] = builtIn) -> [FixRule] {
        ranked(diagnostics, context: context, rules: rules).map(\.rule)
    }

    /// The old order-only matcher, kept for comparison in tests.
    static func matchInOrder(_ diagnostics: LaunchDiagnostics, context: FixContext, rules: [FixRule] = builtIn) -> [FixRule] {
        let text = diagnostics.searchableText
        return rules.filter { rule in
            guard !context.appliedRuleIDs.contains(rule.id) else { return false }
            guard rule.conditions.allSatisfy({ holds($0, context) }) else { return false }
            return rule.patterns.contains { pattern in
                (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    static func holds(_ condition: FixCondition, _ c: FixContext) -> Bool {
        switch condition {
        case .backendIs(let b): c.backend == b
        case .backendIsNot(let b): c.backend != b
        case .store(let s): c.store == s
        case .notNative: !c.native
        case .noD3DMetal: !c.d3dMetalReady
        case .game(let id): c.gameID == id
        case .launcherIs(let name): c.facts?.launcher?.rawValue == name
        case .hasAntiCheat: c.facts?.antiCheat == true
        case .engineIs(let name): c.facts?.engine?.rawValue == name
        case .usesEpicOnlineServices: c.facts?.epicOnlineServices == true
        }
    }

    /// Rules from the fixes list online (`fixes.json`): they come first and can replace built-in ones by id.
    public static func merged(remote: [FixRule]) -> [FixRule] {
        let ids = Set(remote.map(\.id))
        return remote + builtIn.filter { !ids.contains($0.id) }
    }
}

/// A fix that was applied to a game, with what it takes to undo it.
public struct AppliedFix: Codable, Equatable, Sendable, Identifiable {
    public enum Undo: Codable, Equatable, Sendable {
        case previousBackend(GraphicsBackend)
        /// Files Sommelier added, relative to the environment's `drive_c/windows`.
        case removeFiles([String])
        case previousEnvironment([String: String])
        case enableEAOverlay
        case turnOnTurbo
        /// The override the game had for the DLL before (nil: none).
        case previousDLLOverride(String, String?)
        case previousExecutable(instead: String?, run: String?)
        case removeWindowsVersion(exe: String)
        case previousArguments([String])
        /// Files the component added under the environment's `drive_c/windows`, and the game's overrides before.
        case uninstallComponent(files: [String], previousOverrides: [String: String?])
        /// The settings files an edit changed, with the copies made before (`GameConfigEditor`).
        case restoreConfig(files: [String], backups: [String?])
        /// The mod turned on again (`disableMod`).
        case enableMod(String)
        /// What turning a framework off took out of the launch profile (`ModDiagnostics.disable`): the overrides
        /// before (nil: none), the arguments before, and the redirect before when one was cleared.
        case restoreFrameworkLaunch(overrides: [String: String?], arguments: [String], instead: String?, run: String?)
        case none
    }
    public var id: UUID
    public var ruleID: String
    public var action: FixAction
    public var date: Date
    public var undo: Undo

    public init(ruleID: String, action: FixAction, undo: Undo, date: Date = Date()) {
        id = UUID(); self.ruleID = ruleID; self.action = action; self.undo = undo; self.date = date
    }

    /// Applied for the game's mods: by a framework install (`framework:<id>`), by the mods diagnostics
    /// (`mods.…`), or an action about mods. Reports and recipes leave these out.
    public var concernsMods: Bool {
        ruleID.hasPrefix("framework:") || ruleID.hasPrefix(ModDiagnostics.ruleIDPrefix) || action.concernsMods
    }
}

/// The fixes list online (`GET /v1/fixes.json`): `{ "version": 1, "rules": [FixRule…] }`. A rule this version of the
/// app can't read (an action or condition it doesn't know yet) is left out instead of failing the whole list.
public struct FixesList: Codable, Sendable {
    public var version: Int
    public var rules: [FixRule]

    public init(version: Int = 1, rules: [FixRule]) { self.version = version; self.rules = rules }

    private struct Lenient: Decodable {
        let rule: FixRule?
        init(from decoder: Decoder) throws { rule = try? FixRule(from: decoder) }
    }
    private enum Keys: String, CodingKey { case version, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .version)
        rules = try c.decode([Lenient].self, forKey: .rules).compactMap(\.rule)
    }
}

/// Keeps the fixes list online on disk (`Fixes.json`) and refreshes it at most once a day.
public struct FixesService: Sendable {
    let list: OnlineList<FixesList>
    public var file: URL { list.file }
    public var url: URL { list.url }

    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        list = OnlineList(path: "v1/fixes.json", file: paths.home.appendingPathComponent("Fixes.json"), baseURL: baseURL, session: session, signed: true)
    }

    public func cached() -> [FixRule] { list.cached()?.rules ?? [] }

    /// The list from the service, saved for next time; the saved one when the service can't be reached or it's
    /// less than a day old.
    public func refresh(now: Date = Date()) async -> [FixRule] { (await list.refresh(now: now))?.rules ?? [] }
}
