// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The one load order the app shows for a game's mods: the installed mods in a list where the top wins, with
/// the ones the profile pins held at an end without a handle. The profile's `LoadOrderSpec` says how the list
/// is written into the game (`LoadOrderFiles`), and each format reads it back, so what the player arranged by
/// hand or with another manager shows up here too.
///
/// Pins (`pinFirst`, `pinLast`, `pinLastGroups`, a kind's `pinned`) name the position in the game's own order,
/// the way players talk about it ("Online Content Unlocker goes last"). For a format the game reads the other
/// way round (`reverse`) that end is the top of this list: what loads last wins, and the winner is on top.
public struct LoadOrder: Equatable, Sendable {
    public struct Item: Equatable, Identifiable, Sendable {
        public var key: String
        public var name: String
        public var enabled: Bool
        /// Held at the top (`first`) or the bottom (`last`) of the list, with no handle.
        public var pin: ModKind.Pin?

        public var id: String { key }
    }

    /// The remembered order in the game's store: `order.json`.
    struct Saved: Codable, Equatable {
        var format = 1
        var keys: [String] = []
    }

    static let fileName = "order.json"

    public var spec: LoadOrderSpec
    /// Top wins.
    public private(set) var items: [Item]

    /// Arranges the mods: the pinned ones at their ends, the rest in `saved` order, and mods `saved` doesn't
    /// know (just installed) at the bottom of their group, so a new mod never pushes an arranged one aside.
    public init(spec: LoadOrderSpec, mods: [StoredMod], saved: [String] = []) {
        self.spec = spec
        var rank: [String: Int] = [:]
        for (index, key) in saved.enumerated() where rank[key] == nil { rank[key] = index }
        var groups: [ModKind.Pin?: [(Int, Item)]] = [.first: [], nil: [], .last: []]
        for (index, mod) in mods.enumerated() {
            let item = Item(key: mod.key, name: mod.name, enabled: mod.enabled, pin: Self.pin(of: mod, spec: spec))
            groups[item.pin, default: []].append((rank[mod.key] ?? saved.count + index, item))
        }
        func sorted(_ pin: ModKind.Pin?) -> [Item] {
            (groups[pin] ?? []).enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1)
        }
        items = sorted(.first) + sorted(nil) + sorted(.last)
    }

    public var keys: [String] { items.map(\.key) }
    public var enabledKeys: [String] { items.filter(\.enabled).map(\.key) }
    /// Whether dragging means anything to the game.
    public var canReorder: Bool { spec.isReorderable }
    public func item(_ key: String) -> Item? { items.first { $0.key == key } }

    /// The list with one mod moved to `position` (its index in the new list). Nil when the game has no order,
    /// the mod is pinned, or the position is inside a pinned group.
    public func moving(_ key: String, to position: Int) -> LoadOrder? {
        guard canReorder, let from = items.firstIndex(where: { $0.key == key }), items[from].pin == nil else { return nil }
        let first = items.prefix { $0.pin == .first }.count
        let last = items.reversed().prefix { $0.pin == .last }.count
        guard position >= first, position <= items.count - last - 1 else { return nil }
        var copy = self
        let item = copy.items.remove(at: from)
        copy.items.insert(item, at: position)
        return copy
    }

    /// The list with a mod's switch set.
    public func setting(_ key: String, enabled: Bool) -> LoadOrder {
        var copy = self
        if let index = copy.items.firstIndex(where: { $0.key == key }) { copy.items[index].enabled = enabled }
        return copy
    }

    /// Where the profile pins a mod in the list, by its name or any of its units' names, its units' kinds
    /// (`pinLastGroups`) or a kind's own `pinned`. In the game's terms, flipped for a `reverse` format.
    public static func pin(of mod: StoredMod, spec: LoadOrderSpec) -> ModKind.Pin? {
        let names = Set(([mod.name] + mod.units.map(\.name)).map { $0.lowercased() })
        let gameEnd: ModKind.Pin?
        if spec.pinFirst.contains(where: { names.contains($0.lowercased()) }) {
            gameEnd = .first
        } else if spec.pinLast.contains(where: { names.contains($0.lowercased()) }) {
            gameEnd = .last
        } else if mod.units.contains(where: { spec.pinLastGroups.contains($0.kind.id) }) {
            gameEnd = .last
        } else {
            gameEnd = mod.units.compactMap(\.kind.pinned).first
        }
        guard let gameEnd else { return nil }
        guard spec.reverse else { return gameEnd }
        return gameEnd == .first ? .last : .first
    }

    // MARK: Remembering

    /// The keys the store remembers, top first.
    public static func saved(in store: ModStore) -> [String] {
        JSONStore<Saved>(url: store.folder.appendingPathComponent(fileName)).load(default: Saved()).keys
    }

    public func save(in store: ModStore) throws {
        try JSONStore<Saved>(url: store.folder.appendingPathComponent(Self.fileName)).save(Saved(keys: keys))
    }

    // MARK: Helpers for the formats

    /// The units of a mod a format writes: those whose kind is ordered that way.
    static func units(of mod: StoredMod, ordered order: ModKind.Order) -> [ModPlan.Unit] { mod.units.filter { $0.kind.order == order } }

    /// `existing` with our entries taken out and `ours` put where the first of them was (at the end when there
    /// was none): everything that isn't ours keeps its place.
    static func merge<T>(_ existing: [T], ours: [T], isOurs: (T) -> Bool) -> [T] {
        var result: [T] = []
        var inserted = false
        for entry in existing {
            if isOurs(entry) {
                if !inserted { result.append(contentsOf: ours); inserted = true }
            } else {
                result.append(entry)
            }
        }
        if !inserted { result.append(contentsOf: ours) }
        return result
    }

    /// The line ending a text uses, Windows style when it has any.
    static func lineEnding(of text: String) -> String { text.contains("\r\n") ? "\r\n" : "\n" }
}

// MARK: - prefixFolder

extension LoadOrder {
    /// Hogwarts Legacy's `~mods/{slot}/`: every pak mod sits in a folder named `NNN_<key>`, and Unreal mounts
    /// them alphabetically, later wins, so the top of the list gets the highest number (`reverse`). Numbers go
    /// in steps of ten; renumbering renames the folders through the deployer, which keeps its records in step.
    public enum PrefixFolder {
        public static let step = 10

        /// The slot folder name of each mod that has one, by key, for the list as it stands.
        public static func slots(for order: LoadOrder, mods: [StoredMod]) -> [String: String] {
            let byKey = Dictionary(mods.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let slotted = order.items.filter { byKey[$0.key].map(hasSlot) ?? false }
            var slots: [String: String] = [:]
            for (index, item) in slotted.enumerated() {
                let number = (order.spec.reverse ? slotted.count - 1 - index : index) * step
                slots[item.key] = slot(number: number, key: item.key)
            }
            return slots
        }

        public static func slot(number: Int, key: String) -> String { String(format: "%03d_%@", number, key) }

        /// Whether a mod has a unit that goes into a slot folder.
        public static func hasSlot(_ mod: StoredMod) -> Bool { mod.units.contains { $0.files.contains(where: \.needsSlot) } }

        /// The key and number a slot folder's name carries, or nil for a folder that isn't one of ours.
        static func parse(_ folder: String, known: Set<String>) -> (number: Int, key: String)? {
            guard let underscore = folder.firstIndex(of: "_") else { return nil }
            let digits = folder[..<underscore], key = String(folder[folder.index(after: underscore)...])
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits), known.contains(key) else { return nil }
            return (number, key)
        }

        /// The order the slot folders in the game spell out, top first: by number, the highest first when the
        /// game reads them in reverse. Folders that aren't ours (other managers', the player's) are left out.
        public static func read(folders: [String], known: Set<String>, reverse: Bool) -> [String] {
            let parsed = folders.compactMap { parse($0, known: known) }.sorted { ($0.number, $0.key) < ($1.number, $1.key) }
            let keys = parsed.map(\.key)
            return reverse ? keys.reversed() : keys
        }

        /// The folder spec a mod's slot sits in (`game:Phoenix/Content/Paks/~mods/`), from its first slotted
        /// destination.
        static func parentSpec(of mod: StoredMod) -> String? {
            for unit in mod.units {
                for file in unit.files where file.needsSlot {
                    guard let range = file.destination.range(of: "{slot}") else { continue }
                    return String(file.destination[..<range.lowerBound])
                }
            }
            return nil
        }

        /// The slot folder each deployed mod has in the game right now, from the deployer's records.
        public static func current(mods: [StoredMod], deployer: ModDeployer) -> [String: String] {
            var slots: [String: String] = [:]
            for mod in mods {
                guard let parent = parentSpec(of: mod) else { continue }
                for destination in deployer.deployed(mod.key) where destination.hasPrefix(parent) {
                    let rest = destination.dropFirst(parent.count)
                    if let slash = rest.firstIndex(of: "/") { slots[mod.key] = String(rest[..<slash]); break }
                }
            }
            return slots
        }

        /// The order as the game has it now: the slot folders at the mods' parent folder.
        public static func read(order spec: LoadOrderSpec, mods: [StoredMod], roots: ModRoots) -> [String] {
            guard let parent = mods.lazy.compactMap(parentSpec).first, let folder = roots.resolve(parent) else { return [] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return read(folders: names, known: Set(mods.map(\.key)), reverse: spec.reverse)
        }

        /// Renames the deployed mods' slot folders so they carry the list's numbers. Two mods swapping numbers
        /// go through a holding name first, so no folder ever lands on another's. Returns the renames made.
        @discardableResult
        public static func apply(_ order: LoadOrder, mods: [StoredMod], deployer: ModDeployer) throws -> [(from: String, to: String)] {
            let wanted = slots(for: order, mods: mods), present = current(mods: mods, deployer: deployer)
            var moves: [(parent: String, from: String, to: String)] = []
            for mod in mods {
                guard let parent = parentSpec(of: mod), let have = present[mod.key], let want = wanted[mod.key], have != want else { continue }
                moves.append((parent, have, want))
            }
            guard !moves.isEmpty else { return [] }
            for move in moves { try deployer.renameFolder(move.parent + move.from + "/", to: move.parent + holding(move.to) + "/") }
            for move in moves { try deployer.renameFolder(move.parent + holding(move.to) + "/", to: move.parent + move.to + "/") }
            return moves.map { ($0.parent + $0.from + "/", $0.parent + $0.to + "/") }
        }

        private static func holding(_ slot: String) -> String { "." + slot + ".moving" }
    }
}

// MARK: - ue4ssModsTxt

extension LoadOrder {
    /// UE4SS's `mods.txt`: one `<Name> : 1` or `: 0` line per mod, read top to bottom. Our mods' lines are written
    /// in list order where the first of them stood; UE4SS's own lines, other managers' lines, comments and blank
    /// lines stay exactly where they were.
    public enum UE4SSModsTxt {
        /// The `mods.txt` spec of the profile, from the first kind turned on and off through it.
        public static func file(in profile: ModProfile) -> String? {
            profile.kinds.first { $0.enable?.format == .ue4ssModsTxt }?.enable?.file
        }

        /// The names a mod has in the file, with the mod's key.
        static func names(of mods: [StoredMod]) -> [(name: String, key: String)] {
            mods.flatMap { mod in mod.units.filter { $0.kind.enable?.format == .ue4ssModsTxt }.map { ($0.name, mod.key) } }
        }

        /// The name a line sets, or nil for a comment, a blank or anything else.
        static func name(of line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }

        public static func write(_ text: String, order: LoadOrder, mods: [StoredMod]) -> String {
            let ending = lineEnding(of: text)
            var lines = text.isEmpty ? [] : text.components(separatedBy: ending)
            if lines.last == "" { lines.removeLast() }
            let known = names(of: mods)
            let ours = Set(known.map { $0.name.lowercased() })
            var wanted: [String] = []
            for item in order.items {
                for (name, key) in known where key == item.key {
                    wanted.append("\(name) : \(item.enabled ? 1 : 0)")
                }
            }
            let merged = merge(lines, ours: wanted) { line in name(of: line).map { ours.contains($0.lowercased()) } ?? false }
            return merged.isEmpty ? "" : merged.joined(separator: ending) + ending
        }

        /// The keys the file lists, top first, with the switch each line sets.
        public static func read(_ text: String, mods: [StoredMod]) -> [(key: String, enabled: Bool)] {
            let known = Dictionary(names(of: mods).map { ($0.name.lowercased(), $0.key) }, uniquingKeysWith: { first, _ in first })
            var result: [(key: String, enabled: Bool)] = []
            for line in text.components(separatedBy: .newlines) {
                guard let name = name(of: line), let key = known[name.lowercased()], !result.contains(where: { $0.key == key }) else { continue }
                let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
                result.append((key, value == "1"))
            }
            return result
        }
    }
}

// MARK: - deployOrder

extension LoadOrder {
    /// RE4's loose files: the game has no order file, so the order is the order the files were placed in. The
    /// bottom of the list is placed first and the top last, so the top's files are the ones on disk; what they
    /// covered is in `deployed.json` and comes back when they go.
    public enum DeployOrder {
        /// The keys in the order they are to be placed: bottom first, enabled mods only.
        public static func sequence(_ order: LoadOrder) -> [String] { order.enabledKeys.reversed() }

        /// The order the game has now, top first, from the owners in the order they were placed.
        public static func read(owners: [String], known: Set<String>) -> [String] { owners.filter(known.contains).reversed() }

        /// Places the mods again where the game's sequence departs from the list's: from the first mod out of
        /// place on, every later one is taken out and put back in order. Returns the keys placed again.
        @discardableResult
        public static func apply(_ order: LoadOrder, mods: [StoredMod], deployer: ModDeployer) throws -> [String] {
            let byKey = Dictionary(mods.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            let wanted = sequence(order).filter { byKey[$0] != nil }
            let wantedSet = Set(wanted)
            let current = deployer.owners().filter(wantedSet.contains)
            var start = 0
            while start < wanted.count, start < current.count, wanted[start] == current[start] { start += 1 }
            let stale = current.dropFirst(start)
            for key in stale.reversed() { if try deployer.isDeployed(key) { try deployer.remove(owner: key) } }
            var placed: [String] = []
            for key in wanted.dropFirst(start) {
                guard let mod = byKey[key] else { continue }
                if try stale.contains(key) || !deployer.isDeployed(key) {
                    try deployer.deploy(mod)
                    placed.append(key)
                }
            }
            return placed
        }
    }
}

// MARK: - lml

extension LoadOrder {
    /// Lenny's Mod Loader's `lml/mods.xml`: `<Mods>` holds one `<Mod folder="…">` per mod with its switch,
    /// `<LoadOrder>` lists the folders, and the later in that list the later it loads and the more it wins
    /// (`reverse`). Mods that aren't ours keep their elements and their places.
    ///
    /// The shape follows the LCPDFR wiki; the real file is to be checked against a first launch.
    public enum LML {
        /// A mod's folders under `lml/`, with the mod's key.
        static func folders(of mods: [StoredMod]) -> [(folder: String, key: String)] {
            mods.flatMap { mod in units(of: mod, ordered: .orderFile).map { ($0.name, mod.key) } }
        }

        public static func write(_ xml: String?, order: LoadOrder, mods: [StoredMod]) throws -> String {
            let document: XMLDocument
            if let xml, !xml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document = try XMLDocument(xmlString: xml, options: [])
            } else {
                document = XMLDocument(rootElement: XMLElement(name: "ModsManager"))
                document.version = "1.0"
                document.characterEncoding = "utf-8"
            }
            let root: XMLElement
            if let existing = document.rootElement() {
                root = existing
            } else {
                root = XMLElement(name: "ModsManager")
                document.setRootElement(root)
            }
            let modsElement = child(named: "Mods", of: root)
            let orderElement = child(named: "LoadOrder", of: root)

            let known = folders(of: mods)
            let ours = Set(known.map { $0.folder.lowercased() })
            for item in order.items {
                for (folder, key) in known where key == item.key {
                    let element = modsElement.elements(forName: "Mod").first { $0.attribute(forName: "folder")?.stringValue?.lowercased() == folder.lowercased() }
                        ?? newMod(folder: folder, name: item.name, in: modsElement)
                    setChild(of: element, named: "Enabled", to: item.enabled ? "true" : "false")
                }
            }

            // In the game's terms: the list's winner, on top, goes last in the file when the loader reads it
            // the other way round.
            var wantedFolders: [String] = []
            for item in order.items { for (folder, key) in known where key == item.key { wantedFolders.append(folder) } }
            if order.spec.reverse { wantedFolders.reverse() }
            let existing = orderElement.elements(forName: "Mod")
            let merged = merge(existing.map { $0.stringValue ?? "" }, ours: wantedFolders) { ours.contains($0.lowercased()) }
            for element in existing { element.detach() }
            for folder in merged {
                let element = XMLElement(name: "Mod", stringValue: folder)
                orderElement.addChild(element)
            }
            return document.xmlString(options: [.nodePrettyPrint]) + "\n"
        }

        /// The keys the file orders, top first (the last in the file first, when the loader reads it in
        /// reverse). Mods in `<Mods>` but not in `<LoadOrder>` are left out.
        public static func read(_ xml: String, reverse: Bool, mods: [StoredMod]) -> [String] {
            guard let document = try? XMLDocument(xmlString: xml, options: []), let root = document.rootElement() else { return [] }
            let known = Dictionary(folders(of: mods).map { ($0.folder.lowercased(), $0.key) }, uniquingKeysWith: { first, _ in first })
            let listed = root.elements(forName: "LoadOrder").first?.elements(forName: "Mod").compactMap { $0.stringValue } ?? []
            var keys: [String] = []
            for folder in listed {
                guard let key = known[folder.lowercased()], !keys.contains(key) else { continue }
                keys.append(key)
            }
            return reverse ? keys.reversed() : keys
        }

        /// Whether the file switches a folder on; nil when it isn't listed.
        public static func enabled(_ xml: String, folder: String) -> Bool? {
            guard let document = try? XMLDocument(xmlString: xml, options: []), let root = document.rootElement() else { return nil }
            let element = root.elements(forName: "Mods").first?.elements(forName: "Mod").first { $0.attribute(forName: "folder")?.stringValue?.lowercased() == folder.lowercased() }
            return element?.elements(forName: "Enabled").first?.stringValue.map { $0.lowercased() == "true" }
        }

        private static func child(named name: String, of parent: XMLElement) -> XMLElement {
            if let existing = parent.elements(forName: name).first { return existing }
            let element = XMLElement(name: name)
            parent.addChild(element)
            return element
        }

        private static func newMod(folder: String, name: String, in parent: XMLElement) -> XMLElement {
            let element = XMLElement(name: "Mod")
            element.addAttribute(XMLNode.attribute(withName: "folder", stringValue: folder) as! XMLNode)
            element.addChild(XMLElement(name: "Name", stringValue: name))
            element.addChild(XMLElement(name: "Enabled", stringValue: "true"))
            element.addChild(XMLElement(name: "Overwrite", stringValue: "false"))
            parent.addChild(element)
            return element
        }

        private static func setChild(of parent: XMLElement, named name: String, to value: String) {
            if let existing = parent.elements(forName: name).first { existing.stringValue = value } else { parent.addChild(XMLElement(name: name, stringValue: value)) }
        }
    }
}

// MARK: - loaderConfig (me3)

extension LoadOrder {
    /// me3's profile, generated before every modded launch: `[[packages]]` (folders in FromSoftware's layout) and
    /// `[[natives]]` (DLL mods) in list order, first wins, with a save file of its own and online kept off.
    /// Paths are relative to the profile file, which sits in the game's store next to the mods. A mod that came
    /// with Mod Engine 2's `config_eldenring.toml` is read from that file: its `mods` become packages and its
    /// `external_dlls` natives; its launcher is never run.
    public enum Me3 {
        public struct Entry: Equatable, Sendable {
            public enum Kind: String, Sendable { case package = "packages", native = "natives" }
            public var kind: Kind
            public var id: String?
            /// Relative to the profile file, with forward slashes.
            public var path: String

            public init(kind: Kind, id: String? = nil, path: String) { self.kind = kind; self.id = id; self.path = path }
        }

        /// The game as me3 names it, from the profile's id. Elden Ring is the one the profiles know.
        public static func game(for profile: ModProfile) -> String {
            let known = ["steam:1245620": "eldenring", "steam:2622380": "nightreign", "steam:814380": "sekiro", "steam:374320": "ds3", "steam:1888160": "armoredcore6"]
            return profile.gameIDs.lazy.compactMap { known[$0] }.first ?? "eldenring"
        }

        /// What a mod contributes to the profile: a tree or folder unit is a package, a file unit's DLLs are
        /// natives, and a unit with the Mod Engine 2 importer is read from its config in the store. Units whose
        /// files don't sit next to the profile file are left out, and so is an imported entry the mod doesn't
        /// hold a file for: a DLL the archive rules denied (Seamless Co-op in a Mod Engine 2 bundle) would stop
        /// me3 from starting at all. An imported DLL of a unit not marked as code is never loaded.
        public static func entries(of mod: StoredMod, configFile: String, store: ModStore) -> [Entry] {
            guard let config = ModPath(configFile) else { return [] }
            let folder = ModArchive.parentSpec(config.spec)
            var entries: [Entry] = []
            for unit in units(of: mod, ordered: .config) {
                if unit.kind.importer == "modengine2" {
                    guard let marker = unit.kind.marker, let base = ModDeployer.unitFolder(of: unit), base.hasPrefix(folder) else { continue }
                    let markerPath = unit.root.isEmpty ? marker : unit.root + "/" + marker
                    guard let text = try? String(contentsOf: store.file(of: mod.key, at: markerPath), encoding: .utf8) else { continue }
                    let held = unit.files.filter { !$0.skipped }.map { $0.destination.lowercased() }
                    entries += importModEngine2(text, under: String(base.dropFirst(folder.count))).filter { entry in
                        // A DLL is loaded only for a unit the player was told runs code.
                        if entry.kind == .native && !unit.code { return false }
                        let spec = (folder + entry.path).lowercased()
                        return held.contains { entry.kind == .package ? $0.hasPrefix(spec) : $0 == spec }
                    }
                } else if unit.kind.unit == .file {
                    for file in unit.files where !file.skipped && ModArchive.ext(file.destination) == "dll" && file.destination.hasPrefix(folder) {
                        entries.append(.init(kind: .native, path: String(file.destination.dropFirst(folder.count))))
                    }
                } else if let base = ModDeployer.unitFolder(of: unit), base.hasPrefix(folder) {
                    entries.append(.init(kind: .package, id: unit.name, path: String(base.dropFirst(folder.count))))
                }
            }
            return entries
        }

        /// The profile text for the list's enabled mods, top first.
        public static func write(order: LoadOrder, mods: [StoredMod], game: String, savefile: String?, entries: (StoredMod) -> [Entry]) -> String {
            let byKey = Dictionary(mods.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            var text = "# Generated by Sommelier before each modded launch; edits are overwritten.\n"
            text += "profileVersion = \"v1\"\n"
            if let savefile { text += "savefile = \(quoted(savefile))\n" }
            text += "start_online = false\n\n[[supports]]\ngame = \(quoted(game))\n"
            var ids: Set<String> = []
            for key in order.enabledKeys {
                guard let mod = byKey[key] else { continue }
                for entry in entries(mod) {
                    text += "\n[[\(entry.kind.rawValue)]]\n"
                    if entry.kind == .package {
                        var id = entry.id ?? entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        var n = 2
                        while ids.contains(id.lowercased()) { id = (entry.id ?? "package") + "-\(n)"; n += 1 }
                        ids.insert(id.lowercased())
                        text += "id = \(quoted(id))\n"
                    }
                    text += "path = \(quoted(entry.path))\n"
                }
            }
            return text
        }

        /// The packages and natives a profile text lists, in order, and its top-level values.
        public static func read(_ toml: String) -> (entries: [Entry], values: [String: String]) {
            var entries: [Entry] = [], values: [String: String] = [:]
            var table: String?
            for raw in toml.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                if line.hasPrefix("[[") {
                    table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                    if let kind = Entry.Kind(rawValue: table ?? "") { entries.append(.init(kind: kind, path: "")) }
                    continue
                }
                if line.hasPrefix("[") { table = line; continue }
                guard let pair = keyValue(line) else { continue }
                let (key, value) = pair
                if table == nil {
                    values[key] = value
                } else if Entry.Kind(rawValue: table ?? "") != nil, !entries.isEmpty {
                    if key == "path" { entries[entries.count - 1].path = value.replacingOccurrences(of: "\\", with: "/") }
                    if key == "id" { entries[entries.count - 1].id = value }
                }
            }
            return (entries.filter { !$0.path.isEmpty }, values)
        }

        /// The keys a profile text orders, top first, by the paths each mod contributes.
        public static func read(_ toml: String, mods: [StoredMod], entries: (StoredMod) -> [Entry]) -> [String] {
            let owners = Dictionary(mods.flatMap { mod in entries(mod).map { ($0.path.lowercased(), mod.key) } }, uniquingKeysWith: { first, _ in first })
            var keys: [String] = []
            for entry in read(toml).entries {
                guard let key = owners[entry.path.lowercased()], !keys.contains(key) else { continue }
                keys.append(key)
            }
            return keys
        }

        /// Mod Engine 2's `config_eldenring.toml`: `mods = [ { enabled = true, name = "…", path = "mod" }, … ]`
        /// in priority order (first wins) and `external_dlls = [ "x.dll", … ]`, both relative to the launcher's
        /// folder, which is `folder` relative to our profile. An absolute path (another disk, a drive letter)
        /// can't be inside the archive and is dropped; a disabled mod too.
        public static func importModEngine2(_ toml: String, under folder: String) -> [Entry] {
            let base = folder.isEmpty || folder.hasSuffix("/") ? folder : folder + "/"
            var entries: [Entry] = []
            if let body = arrayBody(of: "mods", in: toml) {
                for table in inlineTables(in: body) {
                    guard table["enabled"]?.lowercased() != "false", let path = table["path"].flatMap(relativePath) else { continue }
                    entries.append(.init(kind: .package, id: table["name"], path: base + (path.hasSuffix("/") ? path : path + "/")))
                }
            }
            if let body = arrayBody(of: "external_dlls", in: toml) {
                for path in strings(in: body).compactMap(relativePath) {
                    entries.append(.init(kind: .native, path: base + path))
                }
            }
            return entries
        }

        // MARK: TOML bits

        static func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }

        /// `key = value` with the quotes taken off a string value and a trailing comment dropped.
        static func keyValue(_ line: String) -> (String, String)? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            if let found = string(at: value.startIndex, in: value) { return (key, found.0) }
            if let hash = value.firstIndex(of: "#") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            return (key, value)
        }

        /// A quoted string starting at `index` ("…" with escapes, '…' literal) and where it ends.
        static func string(at index: String.Index, in text: String) -> (String, String.Index)? {
            guard index < text.endIndex, text[index] == "\"" || text[index] == "'" else { return nil }
            let quote = text[index]
            var result = "", cursor = text.index(after: index)
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == quote { return (result, text.index(after: cursor)) }
                if quote == "\"", character == "\\", text.index(after: cursor) < text.endIndex {
                    cursor = text.index(after: cursor)
                    switch text[cursor] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(text[cursor])
                    }
                } else {
                    result.append(character)
                }
                cursor = text.index(after: cursor)
            }
            return nil
        }

        /// The text between the brackets of `key = [ … ]`, across lines, strings respected.
        static func arrayBody(of key: String, in toml: String) -> String? {
            var searchFrom = toml.startIndex
            while let range = toml.range(of: key, range: searchFrom..<toml.endIndex) {
                searchFrom = range.upperBound
                let lineStart = toml[..<range.lowerBound].lastIndex(of: "\n").map { toml.index(after: $0) } ?? toml.startIndex
                guard toml[lineStart..<range.lowerBound].allSatisfy(\.isWhitespace) else { continue }
                var cursor = range.upperBound
                while cursor < toml.endIndex, toml[cursor] == " " || toml[cursor] == "\t" { cursor = toml.index(after: cursor) }
                guard cursor < toml.endIndex, toml[cursor] == "=" else { continue }
                cursor = toml.index(after: cursor)
                while cursor < toml.endIndex, toml[cursor].isWhitespace { cursor = toml.index(after: cursor) }
                guard cursor < toml.endIndex, toml[cursor] == "[" else { continue }
                let open = cursor
                var depth = 0
                while cursor < toml.endIndex {
                    if let found = string(at: cursor, in: toml) { cursor = found.1; continue }
                    if toml[cursor] == "[" { depth += 1 }
                    if toml[cursor] == "]" { depth -= 1; if depth == 0 { return String(toml[toml.index(after: open)..<cursor]) } }
                    cursor = toml.index(after: cursor)
                }
                return nil
            }
            return nil
        }

        /// The `{ … }` inline tables of an array body, each as its key/value pairs.
        static func inlineTables(in body: String) -> [[String: String]] {
            var tables: [[String: String]] = []
            var cursor = body.startIndex
            while cursor < body.endIndex {
                if let found = string(at: cursor, in: body) { cursor = found.1; continue }
                guard body[cursor] == "{" else { cursor = body.index(after: cursor); continue }
                // Inside the braces: `key = value` pairs between commas, a string kept whole whatever it holds.
                var pairs: [String] = [], current = ""
                cursor = body.index(after: cursor)
                var closed = false
                while cursor < body.endIndex, !closed {
                    if let found = string(at: cursor, in: body) { current += "\u{1}" + found.0 + "\u{1}"; cursor = found.1; continue }
                    let character = body[cursor]
                    if character == "}" { closed = true } else if character == "," { pairs.append(current); current = "" } else { current.append(character) }
                    cursor = body.index(after: cursor)
                }
                pairs.append(current)
                var table: [String: String] = [:]
                for pair in pairs {
                    guard let equals = pair.firstIndex(of: "=") else { continue }
                    let key = pair[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{1}", with: "")
                    if !key.isEmpty { table[key] = value }
                }
                tables.append(table)
            }
            return tables
        }

        /// The quoted strings of an array body, in order.
        static func strings(in body: String) -> [String] {
            var found: [String] = []
            var cursor = body.startIndex
            while cursor < body.endIndex {
                if let text = string(at: cursor, in: body) { found.append(text.0); cursor = text.1 } else { cursor = body.index(after: cursor) }
            }
            return found
        }

        /// A config path as a path under the archive: slashes forward and single (a literal TOML string keeps
        /// its doubled backslashes), `.` parts dropped; nil for an absolute one or one that climbs out.
        static func relativePath(_ raw: String) -> String? {
            let parts = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).filter { $0 != "." && !$0.isEmpty }
            let path = parts.joined(separator: "/")
            guard !path.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("\\"), ModPath.isSafe(path) else { return nil }
            return path
        }
    }
}

// MARK: - Reading and writing the game's files

/// Writes the list into the game the way the profile's format wants and reads it back; the store keeps a copy
/// of the list (`order.json`) for the formats that hold only part of it (a profile lists enabled mods only, a
/// game with no order has nothing).
public struct LoadOrderFiles: Sendable {
    public let profile: ModProfile
    public let roots: ModRoots
    public let store: ModStore
    public let deployer: ModDeployer

    public init(profile: ModProfile, roots: ModRoots, store: ModStore, deployer: ModDeployer) {
        self.profile = profile; self.roots = roots; self.store = store; self.deployer = deployer
    }

    public init(profile: ModProfile, deployer: ModDeployer) {
        self.init(profile: profile, roots: deployer.roots, store: deployer.store, deployer: deployer)
    }

    /// The list as the game and the store have it, for these mods.
    public func read(mods: [StoredMod]) -> LoadOrder {
        let spec = profile.loadOrder
        let known = Set(mods.map(\.key))
        let fromGame: [String]
        switch spec.format {
        case .prefixFolder:
            fromGame = LoadOrder.PrefixFolder.read(order: spec, mods: mods, roots: roots)
        case .ue4ssModsTxt:
            fromGame = text(at: LoadOrder.UE4SSModsTxt.file(in: profile)).map { LoadOrder.UE4SSModsTxt.read($0, mods: mods).map(\.key) } ?? []
        case .deployOrder:
            fromGame = LoadOrder.DeployOrder.read(owners: deployer.owners(), known: known)
        case .lml:
            fromGame = text(at: spec.file).map { LoadOrder.LML.read($0, reverse: spec.reverse, mods: mods) } ?? []
        case .loaderConfig:
            fromGame = text(at: spec.file).map { LoadOrder.Me3.read($0, mods: mods, entries: me3Entries) } ?? []
        case .dependencies, .none:
            fromGame = []
        }
        let remembered = LoadOrder.saved(in: store).filter { !fromGame.contains($0) }
        return LoadOrder(spec: spec, mods: mods, saved: fromGame + remembered)
    }

    /// Writes the list into the game and remembers it. `separateSave` is the player's choice for a loader that
    /// keeps a save file of its own (on by the profile's default).
    public func apply(_ order: LoadOrder, mods: [StoredMod], separateSave: Bool = true) throws {
        let spec = profile.loadOrder
        switch spec.format {
        case .prefixFolder:
            try LoadOrder.PrefixFolder.apply(order, mods: mods, deployer: deployer)
        case .ue4ssModsTxt:
            guard let file = LoadOrder.UE4SSModsTxt.file(in: profile), let url = roots.resolve(file) else { throw ModDeployError.rootUnavailable(LoadOrder.UE4SSModsTxt.file(in: profile) ?? "") }
            try write(LoadOrder.UE4SSModsTxt.write(text(at: file) ?? "", order: order, mods: mods), to: url)
            try deployer.noteEdited(file)
        case .deployOrder:
            try LoadOrder.DeployOrder.apply(order, mods: mods, deployer: deployer)
        case .lml:
            guard let file = spec.file, let url = roots.resolve(file) else { throw ModDeployError.rootUnavailable(spec.file ?? "") }
            try write(try LoadOrder.LML.write(text(at: file), order: order, mods: mods), to: url)
            try deployer.noteEdited(file)
        case .loaderConfig:
            guard let file = spec.file, let url = roots.resolve(file) else { throw ModDeployError.rootUnavailable(spec.file ?? "") }
            let save = profile.online.separateSave
            let savefile = (separateSave && save?.enabled != false) ? save?.file : nil
            try write(LoadOrder.Me3.write(order: order, mods: mods, game: LoadOrder.Me3.game(for: profile), savefile: savefile, entries: me3Entries), to: url)
        case .dependencies, .none:
            break
        }
        try order.save(in: store)
    }

    /// What a mod contributes to the me3 profile, for the profile's config file.
    public func me3Entries(_ mod: StoredMod) -> [LoadOrder.Me3.Entry] {
        guard let file = profile.loadOrder.file else { return [] }
        return LoadOrder.Me3.entries(of: mod, configFile: file, store: store)
    }

    private func text(at spec: String?) -> String? {
        guard let spec, let url = roots.resolve(spec) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
