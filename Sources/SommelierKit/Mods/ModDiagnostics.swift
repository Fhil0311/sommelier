// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads the logs a game's mods profile names after a failed launch and turns what they say into fixes, the way
/// `FixRules` reads the game's own log: the loader names a broken mod, so that mod goes off; the loader can't find
/// its addresses in a new game version, so the loader goes off until it updates; a crash dump appeared, so the mod
/// added last is the usual suspect. The matches carry `FixAction.disableMod` with the mod's store key or
/// `disableFramework` with the framework's id, never a name. The tails kept for the diagnostics have every mod's
/// name taken out: a report may go to the developer, and mod names stay on the Mac.
public struct ModDiagnostics: Sendable {
    /// Rule ids of the fixes found here, all under one prefix so reports and recipes can leave them out.
    public static let ruleIDPrefix = "mods."
    public static let brokenModRule = "mods.broken-mod"
    public static let loaderOutdatedRule = "mods.loader-outdated"
    public static let newestModRule = "mods.newest-mod"

    public let profile: ModProfile
    public let roots: ModRoots

    public init(profile: ModProfile, roots: ModRoots) { self.profile = profile; self.roots = roots }

    /// What the profile's logs gave for one launch.
    public struct Result: Equatable, Sendable {
        public var matches: [FixRules.Match] = []
        /// The tails read, each under a line naming its log, scrubbed of paths and of every mod's name: for
        /// `LaunchDiagnostics.modLogTail`. Nil when no log was there.
        public var tail: String?
        /// SMAPI's own summary of the session, when the profile asks for it.
        public var summary: SMAPISummary?
        /// Captures of a `disableMod` rule no stored mod answers to: a mod the player put in by hand, or a name
        /// the loader writes differently from the profile's expectation.
        public var unresolved: [String] = []

        public init() {}
    }

    /// The mods and frameworks as the app knows them at the time of the launch, so a rule can name a key and a
    /// fix already applied isn't offered twice. `manifests` are the flattened manifest fields by key
    /// (`ModConflicts.manifestFields`), for loaders that write a mod's unique id or manifest name.
    public struct State: Sendable {
        public var mods: [StoredMod]
        public var installedFrameworks: Set<String>?
        public var manifests: [String: [String: String]]
        public var applied: [AppliedFix]

        public init(mods: [StoredMod], installedFrameworks: Set<String>? = nil, manifests: [String: [String: String]] = [:], applied: [AppliedFix] = []) {
            self.mods = mods; self.installedFrameworks = installedFrameworks; self.manifests = manifests; self.applied = applied
        }
    }

    // MARK: Reading

    /// Reads every log of the profile and matches its rules. `since` is when the launch started: a crash dump
    /// from before it is an old one and blames nobody. Nothing is written anywhere.
    public func collect(_ state: State, since: Date? = nil) -> Result {
        var result = Result()
        var tails: [String] = []
        for log in profile.logs {
            let files = Self.files(for: log, roots: roots)
            if let exists = log.exists {
                let fresh = files.contains { file in since.map { Self.modified(file) >= $0 } ?? true }
                if fresh, let match = Self.match(for: exists.action, rule: nil, capture: nil, log: log, profile: profile, state: state,
                                                 evidence: log.file, weight: 3, unresolved: &result.unresolved) {
                    result.matches.append(match)
                }
                continue
            }
            guard let file = files.first else { continue }
            let text = DiagnosticsCollector.tail(of: file)
            guard !text.isEmpty else { continue }
            result.matches += Self.matches(in: text, log: log, profile: profile, state: state, unresolved: &result.unresolved)
            if log.summary == .smapi { result.summary = SMAPISummary.parse(text) }
            tails.append("== \(log.file) ==\n" + text)
        }
        result.matches = Self.distinct(result.matches)
        if !tails.isEmpty { result.tail = Self.scrub(tails.joined(separator: "\n"), mods: state.mods, manifests: state.manifests) }
        return result
    }

    /// The files a log spec stands for, newest first: the spec's file (its name may hold `*`), or the alternative
    /// place when the first has nothing.
    static func files(for log: LogSpec, roots: ModRoots) -> [URL] {
        for spec in [log.file, log.altFile].compactMap({ $0 }) {
            guard let path = ModPath(spec), let url = roots.resolve(path) else { continue }
            let found: [URL]
            if url.lastPathComponent.contains("*") {
                let folder = url.deletingLastPathComponent()
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                found = names.filter { ModGlob.matchesName(url.lastPathComponent, $0) }.map { folder.appendingPathComponent($0) }
                    .filter(FileScan.isRegularFile).sorted { modified($0) > modified($1) }
            } else {
                found = FileScan.isRegularFile(url) ? [url] : []
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    // MARK: Matching

    /// The rules of one log against its text, in the order they are written: every match of a pattern is one fix
    /// (two broken mods are two fixes), the same mod only once. Pure, for sample logs in tests.
    public static func matches(in text: String, log: LogSpec, profile: ModProfile, state: State, unresolved: inout [String]) -> [FixRules.Match] {
        var out: [FixRules.Match] = []
        let range = NSRange(text.startIndex..., in: text)
        for rule in log.rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            for found in regex.matches(in: text, range: range) {
                guard let whole = Range(found.range, in: text) else { continue }
                var capture: String?
                if let group = rule.modFrom, group < found.numberOfRanges, let r = Range(found.range(at: group), in: text) {
                    capture = String(text[r])
                }
                let line = text[text.lineRange(for: whole)].trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = match(for: rule.action, rule: rule, capture: capture, log: log, profile: profile, state: state,
                                     evidence: String(line.prefix(300)), weight: 2, unresolved: &unresolved) {
                    out.append(match)
                }
            }
        }
        return distinct(out)
    }

    /// One rule's match turned into a fix, or nil when there is nothing to turn off: the mod isn't known or is
    /// off already, the framework isn't installed, the same fix was applied before.
    static func match(for action: LogSpec.Action, rule: LogSpec.Rule?, capture: String?, log: LogSpec, profile: ModProfile, state: State,
                      evidence: String, weight: Int, unresolved: inout [String]) -> FixRules.Match? {
        let fix: FixAction
        let id: String, cause: String
        switch action {
        case .disableMod:
            guard let capture else { return nil }
            guard let mod = mod(named: capture, in: state, byUniqueID: rule?.byUniqueID ?? false) else {
                let name = capture.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, !unresolved.contains(name) { unresolved.append(name) }
                return nil
            }
            fix = .disableMod(mod.key); id = brokenModRule; cause = brokenModCause
        case .disableFramework:
            guard let framework = rule?.framework, profile.frameworks.contains(where: { $0.id == framework }),
                  state.installedFrameworks?.contains(framework) ?? true else { return nil }
            fix = .disableFramework(framework); id = loaderOutdatedRule; cause = loaderOutdatedCause
        case .disableNewestMod:
            guard let newest = state.mods.filter(\.enabled).max(by: { ($0.added, $0.key) < ($1.added, $1.key) }) else { return nil }
            fix = .disableMod(newest.key); id = newestModRule; cause = newestModCause
        }
        guard !state.applied.contains(where: { $0.action == fix }) else { return nil }
        let rule = FixRule(id: id, cause: cause, patterns: rule.map { [$0.pattern] } ?? [], action: fix)
        return FixRules.Match(rule: rule, evidence: DiagnosticsCollector.scrub(evidence), weight: weight)
    }

    /// The first match for each fix; the others repeat it.
    static func distinct(_ matches: [FixRules.Match]) -> [FixRules.Match] {
        var seen: [FixAction] = []
        return matches.filter { match in
            guard let action = match.rule.action, !seen.contains(action) else { return false }
            seen.append(action)
            return true
        }
    }

    /// The enabled mod a loader's log names: by the manifest's unique id when the rule says so, else by its
    /// name, its key, one of its units' names, a manifest's name or id, or a file of it (`autorun/x.lua`,
    /// `X.asi`, a path ending in the capture). Case doesn't matter, nor the kind of slash.
    public static func mod(named capture: String, in state: State, byUniqueID: Bool = false) -> StoredMod? {
        let wanted = normalise(capture)
        guard !wanted.isEmpty else { return nil }
        // A loader that writes the whole path (`"C:\Games\X\Rampage.asi" failed to load`): the file's own name.
        let wantedName = ModArchive.basename(wanted)
        for mod in state.mods where mod.enabled {
            let fields = state.manifests[mod.key] ?? [:]
            if byUniqueID {
                if fields["uniqueid"].map(normalise) == wanted { return mod }
                continue
            }
            var names = [mod.name, mod.key] + mod.units.map(\.name)
            names += [fields["name"], fields["uniqueid"]].compactMap { $0 }
            if names.contains(where: { normalise($0) == wanted }) { return mod }
            for unit in mod.units {
                for file in unit.files where !file.skipped {
                    let destination = normalise(ModPath(file.destination)?.path ?? file.destination)
                    let source = normalise(file.source)
                    if destination == wanted || destination.hasSuffix("/" + wanted) || source == wanted || source.hasSuffix("/" + wanted)
                        || ModArchive.basename(destination) == wantedName || ModArchive.basename(source) == wantedName { return mod }
                }
            }
        }
        return nil
    }

    static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Causes

    /// The causes in plain words, as the built-in rules carry theirs (the app translates by rule id).
    public static let brokenModCause = "The game's mod loader reports an error in one of the mods. Turning it off should let the game start."
    public static let loaderOutdatedCause = "The mod loader doesn't work with this version of the game yet. The game starts without it; mods stay off until it updates."
    public static let newestModCause = "The game crashed and its mod loader left a crash dump. The mod added last is the usual suspect."

    // MARK: Scrubbing

    /// The manifest fields a loader writes about a mod (SMAPI: `Content Patcher 2.4.4 by Pathoschild | Loads
    /// content packs…`, its unique id in errors).
    static let manifestNameFields = ["name", "author", "uniqueid", "description"]

    /// Every name a mod goes by in a log: its name, its store key, its units' names, its archive's name without
    /// the extension, and what its manifest calls it (`manifests`, flattened by key as in `State`): the name, the
    /// author, the unique id whole and part by part, the description. Three characters or more; the collector
    /// takes them out as whole words, the way it takes out the user's names.
    public static func names(of mods: [StoredMod], manifests: [String: [String: String]] = [:]) -> [String] {
        var names: Set<String> = []
        for mod in mods {
            names.insert(mod.name); names.insert(mod.key)
            for unit in mod.units { names.insert(unit.name) }
            names.insert((mod.archive.name as NSString).deletingPathExtension)
            let fields = manifests[mod.key] ?? [:]
            for field in manifestNameFields { if let value = fields[field] { names.insert(value) } }
            if let id = fields["uniqueid"] { names.formUnion(id.split(separator: ".").map(String.init)) }
        }
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
    }

    /// Paths and the user's names out as always, then the mods' names.
    public static func scrub(_ text: String, mods: [StoredMod], manifests: [String: [String: String]] = [:]) -> String {
        DiagnosticsCollector.scrub(DiagnosticsCollector.scrub(text), names: names(of: mods, manifests: manifests))
    }

    /// Whether mods are in play for a game: a stored mod is on, or a framework's files sit in the game. The
    /// report's flag, and nothing more about them.
    public static func inPlay(store: ModStore, roots: ModRoots) -> Bool {
        store.list().contains(where: \.enabled) || !ModDeployer(roots: roots, store: store).owners().isEmpty
    }

    /// The whole of it for a failed launch: reads the profile's logs, puts their scrubbed tails into the
    /// diagnostics as `modLogTail`, sets the `mods` flag, and takes every mod's name out of the other texts too,
    /// since the game's own log and a crash report name a mod's folder or library as readily as the loader's
    /// log does. The matches come back for the fixes list, ranked with `FixRules.ranked`'s by weight.
    public func attach(to diagnostics: inout LaunchDiagnostics, state: State, inPlay: Bool, since: Date? = nil) -> Result {
        let result = collect(state, since: since)
        diagnostics.modLogTail = result.tail
        diagnostics.mods = inPlay ? true : nil
        diagnostics.scrubModNames(Self.names(of: state.mods, manifests: state.manifests))
        return result
    }

    // MARK: Turning a framework off

    /// Turns a framework off for the launch without removing it: its `disableArgument` added when it has one,
    /// else its DLL overrides taken out of the launch profile along with the redirect it set. The files stay
    /// for when it updates; the fix undoes either way (`restore`).
    public static func disable(_ framework: ModFramework, in profile: inout LaunchProfile, now: Date = Date()) -> AppliedFix {
        let action = FixAction.disableFramework(framework.id)
        let arguments = profile.extraArguments
        if let argument = framework.disableArgument {
            if !arguments.contains(argument) { profile.extraArguments.append(argument) }
            return AppliedFix(ruleID: loaderOutdatedRule, action: action,
                              undo: .restoreFrameworkLaunch(overrides: [:], arguments: arguments, instead: nil, run: nil), date: now)
        }
        var overrides: [String: String?] = [:]
        for dll in framework.dllOverrides.keys.sorted() {
            overrides[dll] = .some(profile.dllOverrides[dll])
            profile.dllOverrides[dll] = nil
        }
        var instead: String?, run: String?
        if let redirect = framework.launch?.redirect, profile.redirect == ExecutableRedirect(instead: redirect.instead, run: redirect.run) {
            instead = redirect.instead; run = redirect.run
            profile.redirect = nil
        }
        return AppliedFix(ruleID: loaderOutdatedRule, action: action,
                          undo: .restoreFrameworkLaunch(overrides: overrides, arguments: arguments, instead: instead, run: run), date: now)
    }

    /// Puts back what `disable` changed. Other undos are left alone.
    public static func restore(_ undo: AppliedFix.Undo, in profile: inout LaunchProfile) {
        guard case .restoreFrameworkLaunch(let overrides, let arguments, let instead, let run) = undo else { return }
        for (dll, mode) in overrides { profile.dllOverrides[dll] = mode }
        profile.extraArguments = arguments
        if let instead, let run { profile.redirect = ExecutableRedirect(instead: instead, run: run) }
    }
}

/// What SMAPI's `SMAPI-latest.txt` says about the session, for the one-line summary after the game quits: the
/// versions, how many mods loaded, which it skipped and which have updates. Lines are `[time LEVEL Source] text`.
public struct SMAPISummary: Equatable, Sendable {
    public var smapiVersion: String?
    public var gameVersion: String?
    /// "Loaded N mods".
    public var loaded: Int?
    /// Mods SMAPI couldn't load, as it names them.
    public var skipped: [String] = []
    /// Mods with an update available, as SMAPI names them.
    public var updates: [String] = []
    /// A newer SMAPI, when it says so.
    public var smapiUpdate: String?
    /// Lines at the ERROR level.
    public var errors = 0

    public init() {}

    static let line = try! NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2} (\w+) +[^\]]*\] ?(.*)$"#)

    public static func parse(_ text: String) -> SMAPISummary {
        var summary = SMAPISummary()
        enum Section { case none, skipped, updates }
        var section = Section.none
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let rawLine = String(raw)
            var level = "", message = rawLine
            if let m = line.firstMatch(in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine)),
               let l = Range(m.range(at: 1), in: rawLine), let t = Range(m.range(at: 2), in: rawLine) {
                level = String(rawLine[l]); message = String(rawLine[t])
            }
            let trimmed = message.trimmingCharacters(in: .whitespaces)
            if level == "ERROR" { summary.errors += 1 }
            if let versions = captures(#"^SMAPI (\S+) with Stardew Valley (\S+)"#, trimmed) {
                summary.smapiVersion = versions[0]; summary.gameVersion = versions[1]
            } else if let count = captures(#"^Loaded (\d+) mods?"#, trimmed) {
                summary.loaded = Int(count[0])
            } else if let version = captures(#"^You can update SMAPI to (\S+?):?(?:\s|$)"#, trimmed) {
                summary.smapiUpdate = version[0]; section = .none
            } else if trimmed.hasPrefix("Skipped mods") {
                section = .skipped
            } else if captures(#"^You can update \d+ mods?:?$"#, trimmed) != nil {
                section = .updates
            } else if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" }) {
                // A blank line or the rule under a heading: still the same section.
            } else {
                switch section {
                case .skipped:
                    if trimmed.hasPrefix("- "), let name = captures(#"^- (.+?)(?: \d\S*)? because"#, trimmed) {
                        summary.skipped.append(name[0])
                    } else if !message.hasPrefix(" ") && !trimmed.hasPrefix("These mods") { section = .none }
                case .updates:
                    if let name = captures(#"^(.+?) \d\S*: https?://"#, trimmed) {
                        summary.updates.append(name[0])
                    } else if !message.hasPrefix(" ") { section = .none }
                case .none:
                    break
                }
            }
        }
        return summary
    }

    static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}
