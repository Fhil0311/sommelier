// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

/// What a play session showed about a game, sent to the compatibility database when the player allows it (see
/// server/api/README.md, `POST /v1/reports`). Nothing in it identifies the player: the client id is a random id
/// made once per install, and the server keeps only a salted hash of it.
public struct CompatibilityReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case ran, crashed, didNotStart }

    public struct GameRef: Codable, Equatable, Sendable {
        public var store: String
        public var id: String
        public var title: String?
        public var steamAppID: String?

        public init(store: String, id: String, title: String? = nil, steamAppID: String? = nil) {
            self.store = store; self.id = id; self.title = title; self.steamAppID = steamAppID
        }
    }

    public struct FrameRate: Codable, Equatable, Sendable {
        public var average: Double
        public var low: Double?
        public var resolution: String?

        public init(average: Double, low: Double? = nil, resolution: String? = nil) {
            self.average = average; self.low = low; self.resolution = resolution
        }
    }

    public struct System: Codable, Equatable, Sendable {
        public var chip: String
        public var gpuCores: Int?
        public var ramGB: Int?
        public var macOS: String?

        public init(chip: String, gpuCores: Int? = nil, ramGB: Int? = nil, macOS: String? = nil) {
            self.chip = chip; self.gpuCores = gpuCores; self.ramGB = ramGB; self.macOS = macOS
        }
    }

    public struct Setup: Codable, Equatable, Sendable {
        public var app: String?
        public var engine: String?
        public var backend: String?

        public init(app: String? = nil, engine: String? = nil, backend: String? = nil) {
            self.app = app; self.engine = engine; self.backend = backend
        }
    }

    /// How Sommelier ran the game: the player's choices that change how it runs, so the database can tell which
    /// settings work for a game. Built by `Settings(profile:…)`, which keeps only what can't identify anyone.
    public struct Settings: Codable, Equatable, Sendable {
        /// "manual" when the player picked the graphics, "auto" when Sommelier did, "retry" when the first choice
        /// failed and the "didn't start" sheet offered this one (`LaunchRetry`), "recipe" from the recipes list.
        public var backendChoice: String
        public var retina: Bool
        public var metalFX: Bool
        public var rayTracing: Bool
        public var commandAsControl: Bool
        /// Known variables only (graphics layers, Wine), with plain values.
        public var environment: [String: String]
        /// Plain `-flag` arguments only.
        public var arguments: [String]
        /// How many of the player's own variables and arguments were left out.
        public var otherCustom: Int
        /// Ids of the one-click fixes in effect ("manual" for one picked in the game's settings).
        public var fixes: [String]
        /// Shaders other players shared came down for this game.
        public var shadersFromOthers: Bool
        /// What the player's fixes did (not the recipe's, not the automatic graphics switch): a fix that works for
        /// several players becomes the game's recipe. Nil when none (and in reports queued by older versions).
        public var actions: [FixAction]?

        public init(backendChoice: String, retina: Bool, metalFX: Bool, rayTracing: Bool, commandAsControl: Bool,
                    environment: [String: String] = [:], arguments: [String] = [], otherCustom: Int = 0,
                    fixes: [String] = [], shadersFromOthers: Bool = false, actions: [FixAction] = []) {
            self.backendChoice = backendChoice; self.retina = retina; self.metalFX = metalFX; self.rayTracing = rayTracing
            self.commandAsControl = commandAsControl; self.environment = environment; self.arguments = arguments
            self.otherCustom = otherCustom; self.fixes = fixes; self.shadersFromOthers = shadersFromOthers
            self.actions = actions.isEmpty ? nil : actions
        }

        /// Prefixes of variables that only tune the graphics layers and Wine. Anything else stays on the Mac.
        static let knownPrefixes = ["DXMT_", "DXVK_", "D3DM_", "MTL_", "MVK_", "WINE", "VKD3D_", "DXGI_", "METAL_"]
        /// Values that are settings, not paths or names: no slashes, no spaces at the ends, short.
        static let plainValue = #"^[A-Za-z0-9._,=:;+\-]{0,120}$"#
        static let plainArgument = #"^-{1,2}[A-Za-z][A-Za-z0-9_.+\-]{0,39}$"#
        static let fixID = #"^[a-z0-9][a-z0-9.-]{0,63}$"#

        static func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        /// Fixes about mods stay out: a disabled mod's key would name it, and a loader's overrides are no way to
        /// run the game, so they must never become a recipe. The report's `mods` flag says mods were in play.
        public init(profile: LaunchProfile, applied: [AppliedFix], shadersFromOthers: Bool) {
            let applied = applied.filter { !$0.concernsMods }
            let fixes = applied.map(\.ruleID)
            var env: [String: String] = [:], args: [String] = [], other = 0
            for (key, value) in profile.extraEnvironment.sorted(by: { $0.key < $1.key }) {
                let known = Self.knownPrefixes.contains { key.hasPrefix($0) } && !key.contains("PATH") && !key.contains("FILE")
                    && !key.contains("DIR") && !key.contains("LOG")
                if known, Self.matches(value, Self.plainValue), env.count < 20 { env[key] = value } else { other += 1 }
            }
            for argument in profile.extraArguments {
                if Self.matches(argument, Self.plainArgument), args.count < 20 { args.append(argument) } else { other += 1 }
            }
            let choice = fixes.contains(LaunchRetry.graphicsRuleID) ? "retry" : fixes.contains(Recipe.ruleID) ? "recipe"
                : profile.backend == .auto ? "auto" : "manual"
            self.init(backendChoice: choice, retina: profile.retina,
                      metalFX: profile.metalFX, rayTracing: profile.rayTracing, commandAsControl: profile.commandAsControl,
                      environment: env, arguments: args, otherCustom: other,
                      fixes: Array(fixes.filter { Self.matches($0, Self.fixID) }.prefix(10)),
                      shadersFromOthers: shadersFromOthers,
                      actions: Array(applied.filter { $0.ruleID != Recipe.ruleID && $0.ruleID != LaunchRetry.graphicsRuleID }
                        .map(\.action).prefix(10)))
        }
    }

    public var client: String
    public var game: GameRef
    public var outcome: Outcome
    public var minutes: Int?
    public var fps: FrameRate?
    public var system: System?
    public var sommelier: Setup?
    public var settings: Settings?
    /// Whether the game asked for HDR in the session (DXMT's counter says); nil when it couldn't tell. The service
    /// keeps the games with HDR, so every app offers the HDR switch before a first launch (`HDRGamesService`).
    public var hdr: Bool?
    /// True when mods were in play (a mod on, or a loader's files in the game): the session says nothing about
    /// the plain game, so the service keeps it out of the game's status and graphics statistics. A flag only,
    /// never which mods; nil when there were none.
    public var mods: Bool?

    public init(client: String, game: GameRef, outcome: Outcome, minutes: Int? = nil, fps: FrameRate? = nil,
                system: System? = nil, sommelier: Setup? = nil, settings: Settings? = nil, hdr: Bool? = nil, mods: Bool? = nil) {
        self.client = client; self.game = game; self.outcome = outcome; self.minutes = minutes
        self.fps = fps; self.system = system; self.sommelier = sommelier; self.settings = settings; self.hdr = hdr
        self.mods = mods == true ? true : nil
    }

    /// How a session that ended is reported: long enough to count as played, or nothing (a short session that
    /// ended without a failure may just be the player changing their mind).
    public static func outcome(playedSeconds: TimeInterval) -> Outcome? { playedSeconds >= 120 ? .ran : nil }
}

/// The Mac a report comes from: chip, GPU cores, memory, macOS version. No serial numbers or names.
public enum MacSystem {
    public static var current: CompatibilityReport.System {
        CompatibilityReport.System(chip: chipName(sysctlString("machdep.cpu.brand_string") ?? ""),
                                   gpuCores: gpuCores(),
                                   ramGB: Int((Double(sysctlInt("hw.memsize") ?? 0) / 1_073_741_824).rounded()),
                                   macOS: osVersion(ProcessInfo.processInfo.operatingSystemVersion))
    }

    /// "Apple M2 Pro" stays; "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz" becomes "Intel Core i7-9750H".
    static func chipName(_ brand: String) -> String {
        guard brand.hasPrefix("Intel") else { return brand.trimmingCharacters(in: .whitespaces) }
        var name = brand.replacingOccurrences(of: "(R)", with: "").replacingOccurrences(of: "(TM)", with: "")
        if let at = name.range(of: " CPU") ?? name.range(of: " @") { name = String(name[..<at.lowerBound]) }
        return name.split(separator: " ").joined(separator: " ")
    }

    static func osVersion(_ v: OperatingSystemVersion) -> String {
        v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    /// Apple GPUs publish their core count on the AGX accelerator in the I/O registry.
    private static func gpuCores() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }
}

/// Sends reports, and keeps the ones that couldn't go (offline, service down) to send later.
public struct CompatibilityReporter: Sendable {
    public static let defaultURL = URL(string: "https://api.playsommelier.com")!
    static let maxPending = 200

    public let baseURL: URL
    public let queueFile: URL
    public let session: URLSession
    public let clientVersion: String

    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared, clientVersion: String = "dev") {
        // SOMMELIER_API_URL points the app at a local service while developing (`npx wrangler dev`).
        let override = ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:))
        self.baseURL = baseURL ?? override ?? Self.defaultURL
        self.queueFile = paths.home.appendingPathComponent("PendingReports.json")
        self.session = session
        self.clientVersion = clientVersion
    }

    /// Sends the report and anything still waiting; what doesn't go stays queued.
    public func send(_ report: CompatibilityReport) async {
        var queue = pending()
        queue.append(report)
        await flush(queue)
    }

    /// Sends what's waiting (at start-up).
    public func sendPending() async {
        let queue = pending()
        if !queue.isEmpty { await flush(queue) }
    }

    func pending() -> [CompatibilityReport] {
        (try? JSONDecoder().decode([CompatibilityReport].self, from: Data(contentsOf: queueFile))) ?? []
    }

    private func flush(_ queue: [CompatibilityReport]) async {
        var left: [CompatibilityReport] = []
        for i in queue.indices {
            // A refused report won't get better by waiting; offline or service down keeps the rest, in order.
            if await post(queue[i]) == .later { left = Array(queue[i...]); break }
        }
        save(Array(left.suffix(Self.maxPending)))
    }

    enum PostResult { case sent, refused, later }

    func post(_ report: CompatibilityReport) async -> PostResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/reports"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Sommelier/\(clientVersion)", forHTTPHeaderField: ShaderShare.clientHeader)
        request.httpBody = try? JSONEncoder().encode(report)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .later }
        switch http.statusCode {
        case 200..<300: return .sent
        case 400, 413: return .refused
        default: return .later                                 // 429 and 5xx: try again another time
        }
    }

    /// Asks the server to delete everything sent from this install (`POST /v1/forget`): its session reports and
    /// launch failures. Reports still waiting to go are dropped too. True once the server confirmed.
    public func forget(client: String) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/forget"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Sommelier/\(clientVersion)", forHTTPHeaderField: ShaderShare.clientHeader)
        request.httpBody = try? JSONEncoder().encode(["client": client])
        guard let (_, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        save([])
        return true
    }

    private func save(_ queue: [CompatibilityReport]) {
        if queue.isEmpty { try? FileManager.default.removeItem(at: queueFile); return }
        try? JSONEncoder().encode(queue).write(to: queueFile, options: .atomic)
    }
}
