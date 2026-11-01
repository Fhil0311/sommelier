// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import SystemConfiguration

/// What Sommelier knows about a launch that failed: enough to recognise a known problem (`FixRules`) and, with the
/// user's say-so, to send to the developer. Paths and account names are scrubbed before anything is kept.
public struct LaunchDiagnostics: Codable, Equatable, Sendable {
    public var gameID: String
    public var title: String
    public var store: String
    public var native: Bool
    public var engineVersion: String?
    public var wineVersion: String?
    public var backend: String?
    public var macOS: String
    public var chip: String
    public var exitCode: Int32?
    /// How long the game ran before it quit; nil when it never started.
    public var secondsRunning: Int?
    /// The end of the launch log (Wine's and the program's output), scrubbed.
    public var logTail: String
    /// The end of Steam's `content_log.txt` for Steam games, scrubbed.
    public var steamLogTail: String?
    /// The end of the launcher's log (Steam's, a store's): a game a running launcher starts writes there, not to
    /// its own log. Scrubbed.
    public var launcherLogTail: String?
    /// The start of macOS's crash report for the game, when it left one.
    public var crashReport: String?
    /// The ends of the logs the game's mods profile names (its loader's, SMAPI's), scrubbed of paths and of every
    /// mod's name (`ModDiagnostics`); nil when the game has no mods profile or no such log.
    public var modLogTail: String?
    /// Whether mods were in play for the launch. A flag only: which mods never leaves the Mac.
    public var mods: Bool?
    /// What the player wrote when they said the game doesn't really run (`StatusDispute`), at most 500 characters.
    public var playerNote: String?
    public var collected = Date()

    public init(gameID: String, title: String, store: String, native: Bool = false, engineVersion: String? = nil,
                wineVersion: String? = nil, backend: String? = nil, macOS: String = "", chip: String = "",
                exitCode: Int32? = nil, secondsRunning: Int? = nil, logTail: String = "", steamLogTail: String? = nil,
                crashReport: String? = nil) {
        self.gameID = gameID; self.title = title; self.store = store; self.native = native
        self.engineVersion = engineVersion; self.wineVersion = wineVersion; self.backend = backend
        self.macOS = macOS; self.chip = chip; self.exitCode = exitCode; self.secondsRunning = secondsRunning
        self.logTail = logTail; self.steamLogTail = steamLogTail; self.crashReport = crashReport
    }

    /// Everything the rules look at, in one text.
    public var searchableText: String { [logTail, launcherLogTail ?? "", steamLogTail ?? "", modLogTail ?? "", crashReport ?? ""].joined(separator: "\n") }

    /// Takes the mods' names out of every text, after the rules have read them: the game's own log and a crash
    /// report name a mod's folder or library as readily as the loader's log does.
    public mutating func scrubModNames(_ names: [String]) {
        guard !names.isEmpty else { return }
        logTail = DiagnosticsCollector.scrub(logTail, names: names)
        steamLogTail = steamLogTail.map { DiagnosticsCollector.scrub($0, names: names) }
        launcherLogTail = launcherLogTail.map { DiagnosticsCollector.scrub($0, names: names) }
        crashReport = crashReport.map { DiagnosticsCollector.scrub($0, names: names) }
        modLogTail = modLogTail.map { DiagnosticsCollector.scrub($0, names: names) }
    }
}

public enum DiagnosticsCollector {
    /// Bytes kept from the end of each log.
    public static let tailBytes = 96 * 1024

    public static func collect(game: Game, engine: Engine?, backend: GraphicsBackend?, logURL: URL?, launcherLogURL: URL? = nil,
                               steamHome: SteamHome?, started: Date, exitCode: Int32?, secondsRunning: Int?) -> LaunchDiagnostics {
        var d = LaunchDiagnostics(gameID: game.id, title: game.title, store: game.store.rawValue, native: game.isNative,
                                  engineVersion: engine?.version, wineVersion: engine?.info.wineVersion, backend: backend?.rawValue,
                                  macOS: ProcessInfo.processInfo.operatingSystemVersionString, chip: chip(),
                                  exitCode: exitCode, secondsRunning: secondsRunning)
        if let logURL { d.logTail = scrub(tail(of: logURL)) }
        if let launcherLogURL, launcherLogURL != logURL { d.launcherLogTail = scrub(tail(of: launcherLogURL)) }
        if let steamHome, game.store == .steam { d.steamLogTail = scrub(tail(of: steamHome.log("content_log.txt"), bytes: 32 * 1024)) }
        d.crashReport = crashReport(for: game, since: started).map(scrub)
        return d
    }

    public static func tail(of url: URL, bytes: Int = tailBytes) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// macOS writes `~/Library/Logs/DiagnosticReports/<process>-<date>.ips` when a program crashes. The game's is
    /// the newest one from after the launch whose process ran from the game's folder or carries its name.
    public static func crashReport(for game: Game, since started: Date) -> String? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "ips" }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > started }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let folderPath = game.installPath?.path
        let names = ["wine-preloader", "wine64-preloader", "wine", game.title]
        for file in candidates {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let head = String(text.prefix(12_000))
            let matches = (folderPath.map { head.contains($0) } ?? false) || names.contains { head.contains("\"procName\":\"\($0)") || head.contains("Process: \($0)") }
            if matches { return crashSummary(text) }
        }
        return nil
    }

    /// What of a macOS crash report (`.ips`: a JSON header line, then the JSON report) is sent: the process name,
    /// macOS version, the exception and the crashed thread's frames (library and symbol). Nothing else: the report
    /// also holds the home folder, the user's id and keys that stay the same for the Mac (`crashReporterKey`,
    /// `deviceIdentifierForVendor`), which would tie reports together even after "Delete my data".
    public static func crashSummary(_ text: String) -> String? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }
        var lines: [String] = []
        func add(_ label: String, _ value: Any?) {
            if let value, !"\(value)".isEmpty { lines.append("\(label): \(value)") }
        }
        add("process", body["procName"] as? String)
        add("macOS", header["os_version"] as? String)
        add("type", header["bug_type"] as? String)
        if let exception = body["exception"] as? [String: Any] {
            add("exception", [exception["type"], exception["signal"], exception["subtype"], exception["codes"]]
                .compactMap { $0.map { "\($0)" } }.joined(separator: " "))
        }
        if let termination = body["termination"] as? [String: Any] {
            add("termination", [termination["namespace"], termination["indicator"]].compactMap { $0.map { "\($0)" } }.joined(separator: " "))
        }
        if let asi = body["asi"] as? [String: [String]] {
            for (library, messages) in asi.sorted(by: { $0.key < $1.key }) { add("message (\(library))", messages.joined(separator: " ")) }
        }
        let images = (body["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
        if let threads = body["threads"] as? [[String: Any]] {
            let crashed = (body["faultingThread"] as? Int).flatMap { threads.indices.contains($0) ? threads[$0] : nil }
                ?? threads.first { ($0["triggered"] as? Bool) == true }
            for frame in ((crashed?["frames"] as? [[String: Any]]) ?? []).prefix(24) {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                let symbol = frame["symbol"] as? String ?? "+\(frame["imageOffset"] ?? "?")"
                lines.append("  \(image) \(symbol)")
            }
        }
        return lines.isEmpty ? nil : scrub(lines.joined(separator: "\n"))
    }

    /// Takes out what identifies the user: home folder and disk names however a path is written (Wine doubles its
    /// backslashes, crash reports escape slashes), the Mac user's and computer's names wherever they appear, Steam
    /// IDs and account names, Epic's user arguments and tokens.
    public static func scrub(_ text: String) -> String {
        scrub(text, names: identifyingNames())
    }

    /// The same with the names to take out given: the mods' names (`ModDiagnostics`), or a test's.
    public static func scrub(_ text: String, names: [String]) -> String {
        var out = text
        let separator = #"(?:\\+|/|\\?/)"#                     // \, \\, /, or JSON's \/
        let patterns: [(String, String)] = [
            (#"(?i)([A-Z]:"# + separator + #"users"# + separator + #")[^\\/\s"']+"#, "$1…"),
            (#"(?i)((?:^|[^A-Za-z])"# + separator + #"?Users"# + separator + #")[^\\/\s"']+"#, "$1…"),
            (#"(?i)((?:^|[^A-Za-z])"# + separator + #"?Volumes"# + separator + #")[^\\/"'\n]+?(?="# + separator + #"|["']|$)"#, "$1…"),
            (#"7656119\d{10}"#, "<steamid>"),
            (#"\[U:1:\d+\]"#, "[U:1:…]"),
            (#"(?i)(AccountName|PersonaName|AutoLoginUser)"\s*"[^"]*""#, "$1\" \"…\""),
            (#"-AUTH_PASSWORD=\S+"#, "-AUTH_PASSWORD=…"),
            (#"(?i)-(epicusername|epicuserid|epicdisplayname)=("[^"]*"|\S+)"#, "-$1=…"),
            (#"(?i)"(access_token|refresh_token|token|id_token)"\s*:\s*"[^"]+""#, "\"$1\": \"…\""),
            (#"(?i)(token|bearer)[=: ]+[A-Za-z0-9._\-]{16,}"#, "$1=…"),
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: replacement)
        }
        // Whole words only: a short name ("max") mustn't cut "MaxFPS" out of a log.
        for name in names where name.count >= 3 {
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "…")
        }
        return out
    }

    /// The Mac user's short and full names and the computer's name: whatever else a log says, these go.
    static func identifyingNames() -> [String] {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""      // no network lookup, as Host would
        var names = [NSUserName(), NSFullUserName(), computer]
        names += NSFullUserName().split(separator: " ").map(String.init)          // first and last name on their own
        return Array(Set(names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })).sorted { $0.count > $1.count }
    }

    static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
