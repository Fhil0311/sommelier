// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Reads the file list of a mod's archive against the game's profile and says what the archive is: which mods
/// (units) it holds, of which kind, where every file goes, what the player has to be asked first, and why it
/// can't be installed when it can't. Pure: nothing is unpacked, read or written here. `ModStore` lists the
/// archive and `ModDeployer` places what the plan says, filling `{slot}` and `{next}` in from the game's state.
///
/// The steps, in order: unsafe paths refuse the whole archive; the `ignore` patterns drop the junk; one wrapper
/// folder comes off; several `variants` become a question; the `deny` list takes out loader copies with a note;
/// a `reject` rule refuses with its reason; then the kinds are tried in the profile's order, the first that
/// matches taking its files, the rest seeing what is left.
public enum ModArchive {
    /// What the player answered to the plan's questions. The plan is run again with them.
    public struct Answers: Equatable, Sendable {
        /// The variant folder picked, one of `ModPlan.Question.variant`'s options.
        public var variant: String?
        /// Kinds confirmed (true) or declined (false), by kind id (`ModPlan.Question.kind`).
        public var kinds: [String: Bool]

        public init(variant: String? = nil, kinds: [String: Bool] = [:]) {
            self.variant = variant; self.kinds = kinds
        }
    }

    /// The plan for an archive whose entries are `paths` (relative, either slash; folder entries with a trailing
    /// slash are skipped). `archiveName` names a unit that sits at the archive's root when no folder does;
    /// `manifests` holds the contents of the small files a `codeIf` kind reads, by archive path, when the caller
    /// has them.
    public static func plan(paths: [String], profile: ModProfile, archiveName: String? = nil,
                            manifests: [String: Data] = [:], answers: Answers = Answers()) -> ModPlan {
        var plan = ModPlan()
        var files: [String] = []
        for raw in paths {
            var path = raw.replacingOccurrences(of: "\\", with: "/")
            while path.hasPrefix("./") { path.removeFirst(2) }
            if path.isEmpty || path.hasSuffix("/") { continue }
            guard ModPath.isSafe(path) else { return ModPlan(refusal: .init(reason: .unsafePath, path: raw)) }
            files.append(path)
        }
        files = Array(Set(files)).sorted()
        let rules = profile.archive
        files.removeAll { path in rules.ignore.contains { ModGlob.matches($0, path) } }
        guard !files.isEmpty else { return ModPlan(refusal: .init(reason: .empty, path: nil)) }

        var wrapper: String?
        if rules.wrappers, let top = wrapperFolder(of: files, significant: significantNames(of: profile)) {
            files = files.map { String($0.dropFirst(top.count + 1)) }
            wrapper = top
            plan.base = top
            plan.notes.append(.wrapperRemoved(top))
        }

        // An archive that brings another loader's config (Mod Engine 2's `config_eldenring.toml`) is one mod whose
        // config says which of its folders load; a second `regulation.bin` in it is a disabled set, not a variant.
        let hasLoaderConfig = profile.kinds.contains { kind in kind.importer != nil && files.contains { ModGlob.matches(kind.match, $0) } }
        if let marker = rules.variants, !hasLoaderConfig {
            let variants = Array(Set(files.compactMap { unitRoot(ofMarkerPath: $0, marker: marker) }.filter { !$0.isEmpty })).sorted()
            if variants.count > 1 {
                guard let chosen = answers.variant, variants.contains(chosen) else {
                    plan.questions.append(.variant(options: variants))
                    return plan
                }
                files = files.filter { $0.hasPrefix(chosen + "/") }.map { String($0.dropFirst(chosen.count + 1)) }
                wrapper = chosen.split(separator: "/").last.map(String.init) ?? chosen
                plan.base = plan.base.isEmpty ? chosen : plan.base + "/" + chosen
                plan.notes.append(.variantChosen(chosen))
            }
        }

        for path in files where rules.deny.contains(where: { denies($0, path) }) {
            plan.notes.append(.denied(path))
        }
        files.removeAll { path in rules.deny.contains { denies($0, path) } }

        for rule in rules.reject {
            for path in files where ModGlob.matches(rule.match, path) {
                if rule.onlyFile && files.count > 1 { continue }
                if let nearby = rule.unlessNearby, hasNearby(nearby, to: path, in: files) { continue }
                return ModPlan(refusal: .init(reason: .rejected(rule.reason), path: path), notes: plan.notes)
            }
        }

        let fallbackName = wrapper ?? archiveName ?? "Mod"
        var remaining = files
        for kind in profile.kinds {
            let matched = remaining.filter { ModGlob.matches(kind.match, $0) }
            guard !matched.isEmpty else { continue }
            if kind.ask {
                switch answers.kinds[kind.id] {
                case true?: break
                case false?: continue
                case nil:
                    plan.questions.append(.kind(id: kind.id, files: matched))
                    remaining.removeAll { matched.contains($0) }
                    continue
                }
            }
            do {
                let units = try units(of: kind, matched: matched, remaining: &remaining, fallbackName: fallbackName, profile: profile,
                                      manifests: manifests, base: plan.base)
                plan.units.append(contentsOf: units)
                for unit in units {
                    for file in unit.files where file.skipped {
                        plan.notes.append(.skipped(file.source, framework: unit.framework ?? ""))
                    }
                }
            } catch let refusal as ModPlan.Refusal {
                return ModPlan(refusal: refusal, notes: plan.notes)
            } catch {
                return ModPlan(refusal: .init(reason: .unsafePath, path: nil), notes: plan.notes)
            }
        }
        plan.leftovers = remaining
        if plan.units.isEmpty && plan.questions.isEmpty {
            plan.refusal = .init(reason: .nothingRecognised, path: nil)
        }
        return plan
    }

    // MARK: Archive shape

    /// The one folder at the archive's root everything sits in, when its name means nothing to the profile. A
    /// folder the kinds look for by name (`natives`, `reframework`, `LogicMods`…) is the layout itself, not a
    /// wrapper; a file at the root means there is no wrapper.
    static func wrapperFolder(of files: [String], significant: Set<String>) -> String? {
        let tops = Set(files.map { String($0.split(separator: "/", maxSplits: 1)[0]) })
        guard tops.count == 1, let top = tops.first, files.allSatisfy({ $0.contains("/") }) else { return nil }
        return significant.contains(top.lowercased()) ? nil : top
    }

    /// Every literal folder or file name the profile's kinds match on, lowercased.
    static func significantNames(of profile: ModProfile) -> Set<String> {
        var names: Set<String> = []
        func add(_ name: Substring) {
            guard !name.isEmpty, !name.contains(where: { "*?[{".contains($0) }) else { return }
            names.insert(name.lowercased())
        }
        for kind in profile.kinds {
            for pattern in ModGlob.alternatives(kind.match) { pattern.split(separator: "/").forEach(add) }
            kind.stripTo.map { add(Substring($0)) }
            kind.stripToParentOf?.split(separator: "|").forEach(add)
            kind.marker?.split(separator: "/").forEach(add)
        }
        profile.archive.variants?.split(separator: "/").forEach(add)
        return names
    }

    /// The folder a marker path belongs to: the path less the marker's own components, "" for the root. Nil when
    /// the path doesn't end in the marker.
    static func unitRoot(ofMarkerPath path: String, marker: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        let markerParts = marker.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard parts.count >= markerParts.count else { return nil }
        let tail = parts.suffix(markerParts.count)
        guard zip(tail, markerParts).allSatisfy({ $0.lowercased() == $1.lowercased() }) else { return nil }
        return parts.dropLast(markerParts.count).joined(separator: "/")
    }

    /// A deny entry is a file name (any depth) or, with a slash, a path pattern.
    static func denies(_ entry: String, _ path: String) -> Bool {
        if entry.contains("/") { return ModGlob.matches(entry, path) }
        return ModGlob.matchesName(entry, basename(path))
    }

    /// Whether a file of that name sits in the same folder as `path` or in a folder above it.
    static func hasNearby(_ name: String, to path: String, in files: [String]) -> Bool {
        var folder = parent(path)
        while true {
            let candidate = folder.isEmpty ? name : folder + "/" + name
            if files.contains(where: { $0.lowercased() == candidate.lowercased() }) { return true }
            guard !folder.isEmpty else { return false }
            folder = parent(folder)
        }
    }

    // MARK: Units

    private static func units(of kind: ModKind, matched: [String], remaining: inout [String], fallbackName: String,
                              profile: ModProfile, manifests: [String: Data], base: String) throws -> [ModPlan.Unit] {
        var units: [ModPlan.Unit] = []
        switch kind.unit {
        case .triple:
            for path in matched where remaining.contains(path) {
                let folder = parent(path), name = stem(path)
                let members = remaining.filter {
                    parent($0) == folder && stem($0).lowercased() == name.lowercased() && ["pak", "ucas", "utoc"].contains(ext($0))
                }
                guard Set(members.map(ext)) == ["pak", "ucas", "utoc"] else {
                    throw ModPlan.Refusal(reason: .incompleteTriple, path: path)
                }
                units.append(try unit(kind, name: name, root: folder, files: members.map { ($0, basename($0)) }, profile: profile, manifests: manifests, base: base))
                remaining.removeAll { members.contains($0) }
            }

        case .folder:
            let marker = kind.marker ?? basename(kind.match)
            // Shallowest first; a marker inside a folder already taken is part of that mod, not one of its own.
            let candidates = Array(Set(matched.compactMap { unitRoot(ofMarkerPath: $0, marker: marker) })).sorted { ($0.count, $0) < ($1.count, $1) }
            var roots: [String] = []
            for root in candidates where !roots.contains(where: { isUnder($0, root) }) { roots.append(root) }
            for root in roots {
                let members = remaining.filter { isUnder(root, $0) }
                let name = root.isEmpty ? fallbackName : basename(root)
                units.append(try unit(kind, name: name, root: root, files: members.map { ($0, relative($0, to: root)) }, profile: profile, manifests: manifests, base: base))
                remaining.removeAll { members.contains($0) }
            }

        case .file:
            for path in matched where remaining.contains(path) {
                let folder = parent(path), name = stem(path)
                var members = [path]
                if kind.siblings {
                    members += remaining.filter { $0 != path && isSibling($0, of: path) }
                }
                let placed: [(String, String)] = members.map { member in
                    if let strip = kind.stripTo, let from = fromSegment(strip, in: member) { return (member, from) }
                    return (member, relative(member, to: folder))
                }
                units.append(try unit(kind, name: name, root: folder, files: placed, profile: profile, manifests: manifests, base: base, mainFile: path))
                remaining.removeAll { members.contains($0) }
            }

        case .tree:
            let anchors = (kind.stripTo.map { [$0] } ?? kind.stripToParentOf?.split(separator: "|").map(String.init) ?? []).map { $0.lowercased() }
            guard !anchors.isEmpty else { throw ModPlan.Refusal(reason: .nothingRecognised, path: nil) }
            var roots: [String] = []
            for path in matched {
                let parts = path.split(separator: "/").map(String.init)
                guard let index = parts.firstIndex(where: { anchors.contains($0.lowercased()) }) else { continue }
                let root = parts[..<index].joined(separator: "/")
                if !roots.contains(root) { roots.append(root) }
            }
            for root in roots.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
                let depth = root.isEmpty ? 0 : root.split(separator: "/").count
                let members: [(String, String)] = remaining.compactMap { path in
                    guard isUnder(root, path) else { return nil }
                    let parts = path.split(separator: "/").map(String.init)
                    guard parts.count > depth else { return nil }
                    // From a named folder on (`natives/…`) only that folder; from a parent on, the whole folder.
                    if kind.stripTo != nil, !anchors.contains(parts[depth].lowercased()) { return nil }
                    return (path, parts[depth...].joined(separator: "/"))
                }
                guard !members.isEmpty else { continue }
                let name = root.isEmpty ? fallbackName : basename(root)
                units.append(try unit(kind, name: name, root: root, files: members, profile: profile, manifests: manifests, base: base))
                let sources = Set(members.map(\.0))
                remaining.removeAll { sources.contains($0) }
            }
        }
        return units
    }

    /// One unit, with its destinations worked out and checked. `files` pairs an archive path with its path
    /// relative to the kind's `to`; `mainFile` is the file a file-destination `to` names (the others go next to
    /// it). `base` is the archive folder the paths are relative to, so a manifest the caller keyed by its full
    /// archive path is still found.
    private static func unit(_ kind: ModKind, name: String, root: String, files: [(String, String)], profile: ModProfile,
                             manifests: [String: Data], base: String, mainFile: String? = nil) throws -> ModPlan.Unit {
        let safeName = folderName(name)
        let target = kind.to.replacingOccurrences(of: "{name}", with: safeName)
        let toFolder = target.hasSuffix("/") || target.hasSuffix(":")
        let framework = kind.framework.flatMap(profile.framework)
        var planned: [ModPlan.File] = []
        for (source, relativePath) in files.sorted(by: { $0.0 < $1.0 }) {
            let destination: String
            if toFolder {
                destination = target + relativePath
            } else if source == mainFile {
                destination = target
            } else {
                destination = parentSpec(target) + basename(source)
            }
            guard let path = ModPath(destination) else { throw ModPlan.Refusal(reason: .unsafePath, path: source) }
            // A folder named like Sommelier's own files in the store (`frameworks`, `deployed.json`) would land
            // on them: the loader Sommelier runs could be swapped for the archive's.
            if path.root == .store, ModStore.isOwnPath(path.components, loaderFiles: storeLoaderFiles(of: profile)) {
                throw ModPlan.Refusal(reason: .unsafePath, path: source)
            }
            let skipped = framework?.skip.contains { normalised($0) == normalised(path.path) } ?? false
            planned.append(.init(source: source, destination: destination, skipped: skipped))
        }
        var code = kind.code
        if let field = kind.codeIf, let marker = kind.marker {
            let markerPath = root.isEmpty ? marker : root + "/" + marker
            let keys = [markerPath, base.isEmpty ? markerPath : base + "/" + markerPath].map { $0.lowercased() }
            if let data = manifests.first(where: { keys.contains(normalised($0.key)) })?.value {
                // A manifest that can't be read can't say there is no code.
                code = manifestHasField(field, in: data) ?? true
            }
        }
        // A unit read through another loader's config (Mod Engine 2's) loads the DLLs that config names: one
        // that holds a DLL runs code, whatever the kind says.
        if kind.importer != nil, planned.contains(where: { !$0.skipped && ext($0.destination) == "dll" }) { code = true }
        return .init(kind: kind, name: safeName, root: root, code: code, framework: kind.framework, files: planned)
    }

    /// The names of the store's files the profile's load order writes itself (me3's `sommelier.me3`).
    static func storeLoaderFiles(of profile: ModProfile) -> [String] {
        guard let file = profile.loadOrder.file, let path = ModPath(file), path.root == .store, let first = path.components.first else { return [] }
        return [first]
    }

    /// `manifest.EntryDll`: whether the JSON holds that field with a value. Nested fields with dots. The
    /// manifest is read the way SMAPI's Json.NET reads it, comments and trailing commas allowed; nil when it
    /// can't be read even so.
    static func manifestHasField(_ field: String, in data: Data) -> Bool? {
        var keys = field.split(separator: ".").map(String.init)
        if keys.first == "manifest" { keys.removeFirst() }
        guard var node = (try? JSONSerialization.jsonObject(with: data)) ?? (try? JSONSerialization.jsonObject(with: lenientJSON(data))) else { return nil }
        for key in keys {
            guard let object = node as? [String: Any], let next = object.first(where: { $0.key.lowercased() == key.lowercased() })?.value else { return false }
            node = next
        }
        if let text = node as? String { return !text.trimmingCharacters(in: .whitespaces).isEmpty }
        return !(node is NSNull)
    }

    /// JSON with what Json.NET forgives taken out: `//` and `/* */` comments, and a comma before a closing
    /// bracket. Strings are left as they are.
    static func lenientJSON(_ data: Data) -> Data {
        let text = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0, inString = false
        while index < text.count {
            let c = text[index]
            if inString {
                out.append(c)
                if c == "\\", index + 1 < text.count { out.append(text[index + 1]); index += 2; continue }
                if c == "\"" { inString = false }
                index += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); index += 1; continue }
            if c == "/", index + 1 < text.count, text[index + 1] == "/" {
                while index < text.count, text[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", index + 1 < text.count, text[index + 1] == "*" {
                index += 2
                while index < text.count, !(text[index] == "*" && index + 1 < text.count && text[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            if c == "," {
                var ahead = index + 1
                while ahead < text.count, text[ahead].properties.isWhitespace { ahead += 1 }
                if ahead < text.count, text[ahead] == "}" || text[ahead] == "]" { index += 1; continue }
            }
            out.append(c)
            index += 1
        }
        return Data(String(out).utf8)
    }

    // MARK: Paths

    static func basename(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
    static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    static func ext(_ path: String) -> String { (basename(path) as NSString).pathExtension.lowercased() }
    static func stem(_ path: String) -> String { (basename(path) as NSString).deletingPathExtension }
    static func isUnder(_ root: String, _ path: String) -> Bool { root.isEmpty || path.hasPrefix(root + "/") }
    static func relative(_ path: String, to root: String) -> String { root.isEmpty ? path : String(path.dropFirst(root.count + 1)) }
    static func normalised(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/").lowercased() }

    /// The path from the first folder of that name on, when the path has one.
    static func fromSegment(_ name: String, in path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(where: { $0.lowercased() == name.lowercased() }) else { return nil }
        return parts[index...].joined(separator: "/")
    }

    /// A file next to another with the same stem (`Rampage.asi` and `Rampage.ini`), or inside a folder next to it
    /// whose name starts with that stem (`RampageFiles/`).
    static func isSibling(_ candidate: String, of path: String) -> Bool {
        let folder = parent(path), name = stem(path).lowercased()
        guard isUnder(folder, candidate) else { return false }
        let rest = relative(candidate, to: folder)
        guard let first = rest.split(separator: "/").first.map(String.init) else { return false }
        if first == rest { return stem(first).lowercased() == name }
        return first.lowercased().hasPrefix(name)
    }

    /// The spec of the folder a file spec sits in, with its trailing slash.
    static func parentSpec(_ spec: String) -> String {
        guard let slash = spec.lastIndex(of: "/") else {
            return spec.firstIndex(of: ":").map { String(spec[...$0]) } ?? spec
        }
        return String(spec[...slash])
    }

    /// A unit's name as a folder name: no separators, no leading dot (a dot means "off" to SMAPI).
    static func folderName(_ name: String) -> String {
        var cleaned = name.map { "/\\:".contains($0) ? "-" : $0 }.map(String.init).joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Mod" : String(cleaned.prefix(100))
    }
}

/// What an archive turns into, or why it doesn't.
public struct ModPlan: Equatable, Sendable {
    /// One archive file and where it goes: a `ModPath` spec that may still hold `{slot}` or `{next}` for the
    /// deployer. A skipped file is one the framework says can't work under Wine; it stays in the store only.
    public struct File: Codable, Equatable, Sendable {
        public var source: String
        public var destination: String
        public var skipped: Bool

        public var needsSlot: Bool { destination.contains("{slot}") }
        public var needsNext: Bool { destination.contains("{next}") }
    }

    /// One mod found in the archive: a pak triple, a folder, a file with its siblings, a subtree. Kept in the
    /// store's `mod.json` as it was planned, so the deployer places the same files again later.
    public struct Unit: Codable, Equatable, Sendable {
        public var kind: ModKind
        public var name: String
        /// The unit's folder in the archive ("" for the root).
        public var root: String
        /// The unit runs code: the sheet once, before it is placed.
        public var code: Bool
        /// The framework it needs, by id.
        public var framework: String?
        public var files: [File]
    }

    public enum Question: Equatable, Sendable {
        /// Several variants of the mod in one archive: the player picks one folder.
        case variant(options: [String])
        /// An ambiguous kind: is this a mod of that kind? With the files it would take.
        case kind(id: String, files: [String])
    }

    /// Why the archive can't be installed. Reasons are keys for the app's texts, not texts.
    public struct Refusal: Error, Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// A path that could leave the game folder (`..`, absolute, a drive).
            case unsafePath
            /// A `reject` rule of the profile matched, with its reason ("executable", "saveFile"…).
            case rejected(String)
            /// A `.pak` without its `.ucas` and `.utoc`.
            case incompleteTriple
            /// Nothing in the archive is a kind of mod the game takes.
            case nothingRecognised
            /// Nothing but junk inside.
            case empty
        }
        public var reason: Reason
        public var path: String?

        public init(reason: Reason, path: String?) { self.reason = reason; self.path = path }
    }

    /// Things worth telling the player that don't stop the install.
    public enum Note: Equatable, Sendable {
        case wrapperRemoved(String)
        case variantChosen(String)
        /// A loader copy inside the mod's archive, left out: the framework places its own.
        case denied(String)
        /// A file the framework says can't work under Wine, left out.
        case skipped(String, framework: String)
    }

    public var units: [Unit]
    public var questions: [Question]
    public var refusal: Refusal?
    public var notes: [Note]
    /// Files no kind took (screenshots, modinfo, readmes): kept in the store, never placed.
    public var leftovers: [String]
    /// The archive folder every `source` is relative to: the wrapper taken off and the variant chosen, "" for
    /// the archive's root. The store keeps that folder's contents as the mod's files.
    public var base: String

    public init(units: [Unit] = [], questions: [Question] = [], refusal: Refusal? = nil, notes: [Note] = [], leftovers: [String] = [], base: String = "") {
        self.units = units; self.questions = questions; self.refusal = refusal; self.notes = notes; self.leftovers = leftovers; self.base = base
    }

    /// Nothing left to ask or refuse: the deployer can take it.
    public var isReady: Bool { refusal == nil && questions.isEmpty && !units.isEmpty }
    /// The frameworks the units need, in the order they came up.
    public var frameworks: [String] {
        var seen: [String] = []
        for unit in units { if let framework = unit.framework, !seen.contains(framework) { seen.append(framework) } }
        return seen
    }
    public var containsCode: Bool { units.contains { $0.code } }
}

/// The glob dialect the profiles use: `*` and `?` within a name, `**` for any number of folders (none too),
/// `{a,b}` and `a|b` for alternatives, case-insensitive, slashes either way. A pattern is matched against the
/// whole relative path, so `*.lua` is a file at the root and `**/*.lua` one anywhere.
public enum ModGlob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        let segments = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return alternatives(pattern).contains { alternative in
            matchSegments(alternative.split(separator: "/")[...], segments[...])
        }
    }

    /// A single name against a pattern without slashes.
    public static func matchesName(_ pattern: String, _ name: String) -> Bool {
        alternatives(pattern).contains { matchSegment(Substring($0), Substring(name)) }
    }

    /// `a|b` and `{a,b}` written out as plain patterns.
    public static func alternatives(_ pattern: String) -> [String] {
        pattern.replacingOccurrences(of: "\\", with: "/").split(separator: "|").flatMap { expandBraces(String($0)) }
    }

    static func expandBraces(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{") else { return [pattern] }
        var depth = 0, close: String.Index?
        var index = open
        while index < pattern.endIndex {
            if pattern[index] == "{" { depth += 1 }
            if pattern[index] == "}" { depth -= 1; if depth == 0 { close = index; break } }
            index = pattern.index(after: index)
        }
        guard let close else { return [pattern] }
        var parts: [String] = [], current = ""
        depth = 0
        for character in pattern[pattern.index(after: open)..<close] {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == "," && depth == 0 { parts.append(current); current = "" } else { current.append(character) }
        }
        parts.append(current)
        let prefix = String(pattern[..<open]), suffix = String(pattern[pattern.index(after: close)...])
        return parts.flatMap { expandBraces(prefix + $0 + suffix) }
    }

    static func matchSegments(_ pattern: ArraySlice<Substring>, _ path: ArraySlice<Substring>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            var rest = path
            while true {
                if matchSegments(pattern.dropFirst(), rest) { return true }
                guard !rest.isEmpty else { return false }
                rest = rest.dropFirst()
            }
        }
        guard let segment = path.first, matchSegment(first, segment) else { return false }
        return matchSegments(pattern.dropFirst(), path.dropFirst())
    }

    static func matchSegment(_ pattern: Substring, _ text: Substring) -> Bool {
        let p = Array(pattern.lowercased()), t = Array(text.lowercased())
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
