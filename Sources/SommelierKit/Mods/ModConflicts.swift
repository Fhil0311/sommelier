// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What stands between a game's enabled mods: two of them placing one file, a rule of the game (one
/// `regulation.bin`, one mod per `UniqueID`, pak chunks of one name), a mod whose framework isn't installed,
/// and a content pack whose host mod is missing. Pure: it reads the stored mods' plans and the manifest
/// fields the caller hands it (`manifestFields`), never the game folder. Reasons are keys for the app's
/// texts, as the profile writes them.
public enum ModConflicts {
    /// A warning shows a chip and the game runs; a block means the mods can't be on together, and turning the
    /// second one on is refused.
    public enum Severity: Equatable, Sendable { case warn, block }

    public struct Finding: Equatable, Sendable {
        public enum Cause: Equatable, Sendable {
            /// Two or more mods place one path. The winner is the uppermost in the load order, when the game has
            /// one; nil when nobody can say.
            case samePath(String, winner: String?)
            /// A rule of the profile, with what matched: a file stem for `sameStem`, the pattern for `max` on
            /// files, the field's value for `max` on a manifest field.
            case rule(reason: String, hint: String?, matched: String)
            /// A unit needs a framework that isn't installed.
            case needsFramework(String)
            /// The manifest names another mod this one needs that isn't among the enabled ones.
            case needsMod(String, label: String)
        }

        public var cause: Cause
        public var severity: Severity
        /// The mods involved, by key, in load order when there is one.
        public var mods: [String]

        public init(cause: Cause, severity: Severity, mods: [String]) { self.cause = cause; self.severity = severity; self.mods = mods }
    }

    public struct Report: Equatable, Sendable {
        public var findings: [Finding]

        public init(findings: [Finding] = []) { self.findings = findings }

        public func findings(for key: String) -> [Finding] { findings.filter { $0.mods.contains(key) } }
        /// Mods in a block.
        public var blocked: Set<String> { Set(findings.filter { $0.severity == .block }.flatMap(\.mods)) }
        public func isBlocked(_ key: String) -> Bool { findings.contains { $0.severity == .block && $0.mods.contains(key) } }
        public var isEmpty: Bool { findings.isEmpty }
    }

    /// Checks the enabled mods among `mods`. `order` is the load order's keys, top first, for who wins;
    /// `installedFrameworks` the ids of the frameworks in place; `manifests` each mod's manifest fields
    /// (`manifestFields`), by key.
    public static func check(_ mods: [StoredMod], profile: ModProfile, order: [String]? = nil, installedFrameworks: Set<String> = [],
                             manifests: [String: [String: String]] = [:]) -> Report {
        let enabled = mods.filter(\.enabled)
        let rank: [String: Int] = Dictionary((order ?? enabled.map(\.key)).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func ordered(_ keys: some Sequence<String>) -> [String] {
            Array(Set(keys)).sorted { (rank[$0] ?? Int.max, $0) < (rank[$1] ?? Int.max, $1) }
        }
        var findings: [Finding] = []

        // The same path twice. With no order to speak of (SMAPI sorts itself, or everything loads) nobody can
        // say which file the game takes, so the two can't be on together.
        var owners: [String: [String]] = [:]
        var display: [String: String] = [:]
        for mod in enabled {
            for path in placedPaths(of: mod) {
                let lower = path.lowercased()
                if owners[lower]?.contains(mod.key) != true { owners[lower, default: []].append(mod.key) }
                if display[lower] == nil { display[lower] = path }
            }
        }
        let samePathSeverity: Severity = profile.loadOrder.isReorderable ? (profile.conflicts.samePath == .block ? .block : .warn) : .block
        // A file the game's rules count (one `regulation.bin` at a time) is the rule's finding, not a same-path one too.
        let counted = profile.conflicts.rules.filter { $0.max != nil }.compactMap(\.match)
        for (lower, keys) in owners.sorted(by: { $0.key < $1.key }) where keys.count > 1 && !counted.contains(where: { ModGlob.matches($0, lower) }) {
            let involved = ordered(keys)
            let winner = (profile.loadOrder.isReorderable && order != nil) ? involved.first : nil
            findings.append(.init(cause: .samePath(display[lower] ?? lower, winner: winner), severity: samePathSeverity, mods: involved))
        }

        // The game's rules.
        for rule in profile.conflicts.rules {
            if let pattern = rule.match {
                var byStem: [String: [String]] = [:]
                var matching: [String] = []
                for mod in enabled {
                    let hits = placedPaths(of: mod).filter { ModGlob.matches(pattern, $0) }
                    guard !hits.isEmpty else { continue }
                    matching.append(mod.key)
                    for hit in hits {
                        let stem = ModArchive.stem(hit).lowercased()
                        if byStem[stem]?.contains(mod.key) != true { byStem[stem, default: []].append(mod.key) }
                    }
                }
                if rule.sameStem {
                    for (stem, keys) in byStem.sorted(by: { $0.key < $1.key }) where keys.count > 1 {
                        findings.append(.init(cause: .rule(reason: rule.reason, hint: rule.hint, matched: stem), severity: .warn, mods: ordered(keys)))
                    }
                }
                if let max = rule.max, matching.count > max {
                    findings.append(.init(cause: .rule(reason: rule.reason, hint: rule.hint, matched: pattern), severity: .block, mods: ordered(matching)))
                }
            } else if let field = rule.field, let max = rule.max {
                var byValue: [String: [String]] = [:]
                for mod in enabled {
                    guard let value = manifests[mod.key].flatMap({ value(of: field, in: $0) }) else { continue }
                    byValue[value.lowercased(), default: []].append(mod.key)
                }
                for (_, keys) in byValue.sorted(by: { $0.key < $1.key }) where keys.count > max {
                    let shown = manifests[keys[0]].flatMap { value(of: field, in: $0) } ?? ""
                    findings.append(.init(cause: .rule(reason: rule.reason, hint: rule.hint, matched: shown), severity: .block, mods: ordered(keys)))
                }
            }
        }

        // What a mod needs: its framework, and the mod its manifest says it is a pack for. The host is any
        // enabled mod whose manifest carries that id under the same field name (`UniqueID`), or a framework.
        let frameworkNames = Set(profile.frameworks.flatMap { [$0.id.lowercased(), $0.name.lowercased()] })
        for mod in enabled {
            for framework in mod.frameworks where !installedFrameworks.contains(framework) {
                findings.append(.init(cause: .needsFramework(framework), severity: .block, mods: [mod.key]))
            }
            guard let needs = profile.conflicts.needs, let wanted = manifests[mod.key].flatMap({ value(of: needs.field, in: $0) }) else { continue }
            let hostField = "manifest." + (needs.field.split(separator: ".").last.map(String.init) ?? needs.field)
            let hosted = enabled.contains { other in
                other.key != mod.key && manifests[other.key].flatMap { value(of: hostField, in: $0) }?.lowercased() == wanted.lowercased()
            }
            if !hosted && !frameworkNames.contains(wanted.lowercased()) {
                findings.append(.init(cause: .needsMod(wanted, label: needs.label), severity: .block, mods: [mod.key]))
            }
        }

        return Report(findings: findings)
    }

    /// The paths a mod places, as the game sees them (root included), with the placeholders that are the mod's
    /// own (`{slot}`, `{next}`) filled with its key, so two mods' slots never read as one path. A kind the
    /// loader's config orders keeps every mod in a folder of its own and lays them over the game's files by the
    /// path inside that folder (me3's packages), so that inner path is what two such mods can clash on.
    static func placedPaths(of mod: StoredMod) -> [String] {
        var paths: [String] = []
        for unit in mod.units {
            let own = unit.kind.order == .config ? ModDeployer.unitFolder(of: unit) : nil
            for file in unit.files where !file.skipped {
                var path = file.destination.replacingOccurrences(of: "{slot}", with: mod.key).replacingOccurrences(of: "{next}", with: mod.key)
                if let own, path.lowercased().hasPrefix(own.lowercased()) { path = String(path.dropFirst(own.count)) }
                if !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    // MARK: Manifests

    /// The fields of a mod's manifests (`manifest.json` of a SMAPI mod, a kind's `marker`), flattened to dotted
    /// lowercase keys (`uniqueid`, `contentpackfor.uniqueid`) with string values, read from the store. The
    /// first unit's manifest sets a key; a later unit's doesn't override it.
    public static func manifestFields(of mod: StoredMod, store: ModStore) -> [String: String] {
        var fields: [String: String] = [:]
        for unit in mod.units {
            guard let marker = unit.kind.marker else { continue }
            let path = unit.root.isEmpty ? marker : unit.root + "/" + marker
            let url = store.file(of: mod.key, at: path)
            guard let size = FileScan.attributes(url)?[.size] as? NSNumber, size.intValue <= ModStore.manifestLimit,
                  let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            flatten(object, prefix: "", into: &fields)
        }
        return fields
    }

    static func flatten(_ node: Any, prefix: String, into fields: inout [String: String]) {
        if let object = node as? [String: Any] {
            for (key, value) in object { flatten(value, prefix: prefix.isEmpty ? key.lowercased() : prefix + "." + key.lowercased(), into: &fields) }
        } else if let text = node as? String {
            if fields[prefix] == nil { fields[prefix] = text }
        } else if let number = node as? NSNumber {
            let flag = CFGetTypeID(number) == CFBooleanGetTypeID()
            if fields[prefix] == nil { fields[prefix] = flag ? (number.boolValue ? "true" : "false") : number.stringValue }
        }
    }

    /// A profile field (`manifest.ContentPackFor.UniqueID`) looked up in flattened fields.
    static func value(of field: String, in fields: [String: String]) -> String? {
        var keys = field.split(separator: ".").map { $0.lowercased() }
        if keys.first == "manifest" { keys.removeFirst() }
        guard let text = fields[keys.joined(separator: ".")]?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}
