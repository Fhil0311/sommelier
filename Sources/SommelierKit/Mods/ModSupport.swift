// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How mods are installed into one game, from the mods list online (`GET /v1/mods.json`, signed like the recipes):
/// the frameworks (loaders) the game's mods need, the kinds of mods and where each goes, how the load order is
/// written, what conflicts, which logs give away a broken mod, and whether the game may go online with mods.
/// Data, not code: a new game is a new entry, as long as the general rules cover it.
///
/// A field this version doesn't know is skipped. A value it doesn't know in a closed list (`unit`, `format`,
/// `policy`, a download kind…) makes the whole entry invalid, so the game shows no mods section rather than a
/// wrong one; the other entries are unaffected (`ModsList`).
public struct ModProfile: Codable, Equatable, Sendable {
    /// `experimental` entries show only with the "experimental" flag on, like the game itself.
    public enum Status: String, Codable, Sendable { case ready, experimental }
    /// Which copy of the game the entry serves: the Windows one under Wine, the Mac version, or either. The other
    /// copy shows no mods section at all.
    public enum Runtime: String, Codable, Sendable {
        case wine, native, any

        public func serves(native: Bool) -> Bool {
            switch self {
            case .any: true
            case .native: native
            case .wine: !native
            }
        }
    }

    /// The game's id as the recipes name it ("steam:990080"), and the same game in other stores.
    public var game: String
    public var aliases: [String]
    public var status: Status
    public var runtime: Runtime
    public var sources: ModSources
    /// Installable dependencies (loaders), and the kinds of mods, checked in order: the first kind that matches
    /// takes its files, the rest see what is left.
    public var frameworks: [ModFramework]
    public var kinds: [ModKind]
    public var archive: ModArchiveRules
    public var loadOrder: LoadOrderSpec
    public var conflicts: ConflictSpec
    public var logs: [LogSpec]
    /// The save folders to back up before the first mod, as the saves list names them.
    public var saves: [SaveSource]
    public var online: OnlinePolicy
    public var notes: ModProfileNotes

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        game = try c.decode(String.self, forKey: .game)
        aliases = try c.decode(.aliases, default: [])
        // An entry that doesn't say is treated as still being tried out.
        status = try c.decode(.status, default: .experimental)
        runtime = try c.decode(.runtime, default: .wine)
        sources = try c.decode(.sources, default: ModSources())
        frameworks = try c.decode(.frameworks, default: [])
        kinds = try c.decode(.kinds, default: [])
        archive = try c.decode(.archive, default: ModArchiveRules())
        loadOrder = try c.decode(.loadOrder, default: LoadOrderSpec())
        conflicts = try c.decode(.conflicts, default: ConflictSpec())
        logs = try c.decode(.logs, default: [])
        saves = try c.decode(.saves, default: [])
        online = try c.decode(.online, default: OnlinePolicy())
        notes = try c.decode(.notes, default: ModProfileNotes())
    }

    /// The game's id in every store the entry names.
    public var gameIDs: [String] { [game] + aliases }
    public func covers(_ gameID: String) -> Bool { gameIDs.contains(gameID) }

    /// Whether this entry is for that installed copy: its id (or an alias) and its runtime. The `experimental`
    /// status is the caller's to gate.
    public func applies(to game: Game) -> Bool { covers(game.id) && runtime.serves(native: game.isNative) }

    public func framework(_ id: String) -> ModFramework? { frameworks.first { $0.id == id } }
    public func kind(_ id: String) -> ModKind? { kinds.first { $0.id == id } }
}

/// Where a game's mods come from: its Nexus Mods domain, its mod.io game id (none of the first five have one) and
/// authors' own pages for frameworks that live nowhere else.
public struct ModSources: Codable, Equatable, Sendable {
    public struct Nexus: Codable, Equatable, Sendable { public var domain: String }
    public struct ModIO: Codable, Equatable, Sendable { public var gameID: Int }
    public var nexus: Nexus?
    public var modio: ModIO?
    public var other: [String]

    public init(nexus: Nexus? = nil, modio: ModIO? = nil, other: [String] = []) {
        self.nexus = nexus; self.modio = modio; self.other = other
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nexus = try c.decodeIfPresent(Nexus.self, forKey: .nexus)
        modio = try c.decodeIfPresent(ModIO.self, forKey: .modio)
        other = try c.decode(.other, default: [])
    }
}

/// Where a framework's archive comes from. Always checked against `sha256` before anything is unpacked; a
/// framework without a hash can't be installed. Sommelier never runs anything out of the archive.
public struct ModDownload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A release asset of a GitHub repository (`repo`, `asset`).
        case github
        /// A file from a page (`url`, `file` as a glob); with `viaBrowser` the page opens in the embedded browser
        /// and the download is intercepted, for authors' pages that refuse a plain request.
        case url
        /// A Nexus mod (`domain`, `mod`), through the embedded browser.
        case nexus
        /// A file inside another framework's archive (`of`, `path`): SMAPI's Mac installer data.
        case inner
    }
    public var kind: Kind
    /// GitHub: the repository, the asset's file name and, when the hash pins one release, its tag (the latest
    /// release's asset otherwise).
    public var repo: String?, asset: String?, tag: String?
    public var url: String?, file: String?
    public var domain: String?, mod: Int?
    public var of: String?, path: String?
    public var sha256: String?
    public var viaBrowser: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        asset = try c.decodeIfPresent(String.self, forKey: .asset)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        file = try c.decodeIfPresent(String.self, forKey: .file)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        mod = try c.decodeIfPresent(Int.self, forKey: .mod)
        of = try c.decodeIfPresent(String.self, forKey: .of)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        viaBrowser = try c.decode(.viaBrowser, default: false)
    }
}

/// A value a framework's settings file gets: a string, a flag or a number, or for ini files a section holding
/// keys. Written by the settings editors (ini, json, key=value), never interpreted.
public indirect enum ModSettingValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: ModSettingValue])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let flag = try? single.decode(Bool.self) { self = .bool(flag) }
        else if let number = try? single.decode(Double.self) { self = .number(number) }
        else if let text = try? single.decode(String.self) { self = .string(text) }
        else { self = .object(try single.decode([String: ModSettingValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .string(let text): try single.encode(text)
        case .bool(let flag): try single.encode(flag)
        case .number(let number): try single.encode(number)
        case .object(let fields): try single.encode(fields)
        }
    }
}

/// An installable dependency of a game's mods: a loader (UE4SS, REFramework, SMAPI, me3) or a proxy DLL. The
/// profile says where it comes from, which of its files go where (`pick`), what it needs from Wine (DLL
/// overrides, components) and how the launch changes while it is on. Everything it places is recorded like a
/// mod's files, so removing it takes exactly its own files out again.
public struct ModFramework: Codable, Equatable, Sendable {
    /// Files of the archive (a glob, or several with `|`) and the folder or file they go to (`ModPath` spec).
    /// `stripTo` keeps the path from that folder on; `unpack` unpacks the picked file (itself an archive) there.
    public struct Pick: Codable, Equatable, Sendable {
        public var match: String
        public var to: String
        public var stripTo: String?
        public var unpack: Bool

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            match = try c.decode(String.self, forKey: .match)
            to = try c.decode(String.self, forKey: .to)
            stripTo = try c.decodeIfPresent(String.self, forKey: .stripTo)
            unpack = try c.decode(.unpack, default: false)
        }
    }

    /// A copy of one of the game's files under another name (SMAPI's `deps.json`).
    public struct Copy: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
    }

    /// Values set in a settings file the framework reads, in its format.
    public struct SettingsEdit: Codable, Equatable, Sendable {
        public enum Format: String, Codable, Sendable { case ini, json, keyValue }
        public var file: String
        public var format: Format
        public var set: [String: ModSettingValue]
    }

    /// How the game starts while the framework is on: another program of the game's instead of the store's one
    /// (`ExecutableRedirect`), a loader of our own with its arguments (`{gameExe}`, `{config}` filled in), or
    /// extra arguments. Nothing when absent.
    public struct Launch: Codable, Equatable, Sendable {
        public struct Redirect: Codable, Equatable, Sendable {
            public var instead: String
            public var run: String
        }
        public struct Loader: Codable, Equatable, Sendable {
            public var exe: String
            public var args: [String]
            /// The config file format Sommelier generates for it ("me3").
            public var config: String?
            /// The loader needs the bottle's Steam running (it starts the game through it).
            public var steamInBottle: Bool

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                exe = try c.decode(String.self, forKey: .exe)
                args = try c.decode(.args, default: [])
                config = try c.decodeIfPresent(String.self, forKey: .config)
                steamInBottle = try c.decode(.steamInBottle, default: false)
            }
        }
        public var redirect: Redirect?
        public var loader: Loader?
        public var arguments: [String]?
    }

    public var id: String
    public var name: String
    public var license: String?
    /// The framework runs code inside the game (true for all of them so far): the "This mod contains code" sheet.
    public var code: Bool
    /// Installed only when a mod needs it, not with the game's first mod.
    public var optional: Bool
    public var download: ModDownload
    public var pick: [Pick]
    /// Stale files to take out of the game (an old loader copy that breaks this one), and files of mods that are
    /// never placed under Wine (a plugin that can't work here).
    public var remove: [String]
    public var skip: [String]
    public var copyAs: [Copy]
    public var settings: [SettingsEdit]
    /// `WINEDLLOVERRIDES` entries, into `LaunchProfile.dllOverrides` as an applied fix while the framework is on.
    public var dllOverrides: [String: String]
    /// Runtimes the framework needs, by the name of the `FixAction` that installs them (`componentActions`).
    public var components: [String]
    public var launch: Launch?
    /// An argument that turns the framework off without removing it, for Fix Launch.
    public var disableArgument: String?
    /// Other frameworks this one needs.
    public var requires: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        code = try c.decode(.code, default: false)
        optional = try c.decode(.optional, default: false)
        download = try c.decode(ModDownload.self, forKey: .download)
        pick = try c.decode(.pick, default: [])
        remove = try c.decode(.remove, default: [])
        skip = try c.decode(.skip, default: [])
        copyAs = try c.decode(.copyAs, default: [])
        settings = try c.decode(.settings, default: [])
        dllOverrides = try c.decode(.dllOverrides, default: [:])
        components = try c.decode(.components, default: [])
        if let unknown = components.first(where: { Self.componentAction(named: $0) == nil }) {
            throw DecodingError.dataCorruptedError(forKey: .components, in: c, debugDescription: "unknown component \(unknown)")
        }
        launch = try c.decodeIfPresent(Launch.self, forKey: .launch)
        disableArgument = try c.decodeIfPresent(String.self, forKey: .disableArgument)
        requires = try c.decode(.requires, default: [])
    }

    /// The fix action that installs a named component: one of the runtime installs, or a `Component` by its name.
    /// Only installs: a profile can't switch graphics or change the engine through this.
    public static func componentAction(named name: String) -> FixAction? {
        switch name {
        case "installVCRuntime": .installVCRuntime
        case "installDotNet": .installDotNet
        case "setUpDirectX12": .setUpDirectX12
        default: Component(rawValue: name).map(FixAction.installComponent)
        }
    }

    public var componentActions: [FixAction] { components.compactMap(Self.componentAction(named:)) }
}

/// One kind of mod a game takes, and where its files go. The kinds of a profile are tried in order.
public struct ModKind: Codable, Equatable, Sendable {
    /// What one mod is made of.
    public enum Unit: String, Codable, Sendable {
        /// Three files of one name, `.pak`/`.ucas`/`.utoc` (Unreal).
        case triple
        /// A whole folder, found by its `marker` file.
        case folder
        /// A single file, with its `siblings` of the same base name when asked.
        case file
        /// A subtree from the `stripTo` folder on (`natives/…`, `reframework/…`).
        case tree
    }
    /// How mods of this kind are ordered against each other (`LoadOrderSpec.Format` says how it is written).
    public enum Order: String, Codable, Sendable { case prefix, orderFile, deploy, config, none }
    /// The kind's group is pinned at one end of the load order, without a handle.
    public enum Pin: String, Codable, Sendable { case first, last }
    /// A mod of this kind is turned on and off by a line or a name, not by being there.
    public struct Enable: Codable, Equatable, Sendable {
        public enum Format: String, Codable, Sendable {
            /// `<Name> : 1` lines in UE4SS's `mods.txt` (`file`).
            case ue4ssModsTxt
            /// A dot in front of the folder's name (SMAPI).
            case dotPrefix
        }
        public var format: Format
        public var file: String?
    }

    public var id: String
    /// The mod runs code: the sheet once per mod. `codeIf` names a manifest field that decides instead.
    public var code: Bool
    public var codeIf: String?
    /// The framework the mod needs ("Needs UE4SS" with Install until it is there).
    public var framework: String?
    public var unit: Unit
    /// What to look for among the archive's paths (a glob, case-insensitive).
    public var match: String
    public var marker: String?
    public var stripTo: String?
    public var stripToParentOf: String?
    /// Where the unit goes (`ModPath` spec). `{slot}` is `NNN_<slug>` by load order, `{name}` the unit's name and
    /// `{next}` the next free number.
    public var to: String
    public var siblings: Bool
    public var order: Order
    public var pinned: Pin?
    public var enable: Enable?
    /// The mod replaces one of the game's files, which is kept for the uninstall.
    public var backupOriginal: Bool
    /// An ambiguous kind: the player is asked whether this is one.
    public var ask: Bool
    /// Files of an installed mod kept when it is updated (its config).
    public var keepOnUpdate: [String]
    /// How the unit's file merges into the game's own ("ini"), and which importer reads another loader's layout
    /// ("modengine2"). Names the deployer knows; others are left for a later version.
    public var merge: String?
    public var importer: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        code = try c.decode(.code, default: false)
        codeIf = try c.decodeIfPresent(String.self, forKey: .codeIf)
        framework = try c.decodeIfPresent(String.self, forKey: .framework)
        unit = try c.decode(Unit.self, forKey: .unit)
        match = try c.decode(String.self, forKey: .match)
        marker = try c.decodeIfPresent(String.self, forKey: .marker)
        stripTo = try c.decodeIfPresent(String.self, forKey: .stripTo)
        stripToParentOf = try c.decodeIfPresent(String.self, forKey: .stripToParentOf)
        to = try c.decode(String.self, forKey: .to)
        siblings = try c.decode(.siblings, default: false)
        order = try c.decode(.order, default: .none)
        pinned = try c.decodeIfPresent(Pin.self, forKey: .pinned)
        enable = try c.decodeIfPresent(Enable.self, forKey: .enable)
        backupOriginal = try c.decode(.backupOriginal, default: false)
        ask = try c.decode(.ask, default: false)
        keepOnUpdate = try c.decode(.keepOnUpdate, default: [])
        merge = try c.decodeIfPresent(String.self, forKey: .merge)
        importer = try c.decodeIfPresent(String.self, forKey: .importer)
    }
}

/// How a mod's archive is read before its kinds are matched.
public struct ModArchiveRules: Codable, Equatable, Sendable {
    /// Files that make the archive unusable, with the reason (a key for the app's texts, not a text): programs,
    /// save files, legacy formats. `unlessNearby` lifts the rule when that file sits next to the match;
    /// `onlyFile` applies it only when the match is all the archive holds.
    public struct Reject: Codable, Equatable, Sendable {
        public var match: String
        public var reason: String
        public var unlessNearby: String?
        public var onlyFile: Bool

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            match = try c.decode(String.self, forKey: .match)
            reason = try c.decode(String.self, forKey: .reason)
            unlessNearby = try c.decodeIfPresent(String.self, forKey: .unlessNearby)
            onlyFile = try c.decode(.onlyFile, default: false)
        }
    }

    public static let defaultIgnore = ["__MACOSX/**", "**/.DS_Store", "**/Thumbs.db", "**/desktop.ini", "**/*.url", "**/readme*"]

    /// A marker file that stands for one variant of the mod: several in one archive mean a question.
    public var variants: String?
    /// One wrapping folder at the archive's root is taken off.
    public var wrappers: Bool
    public var ignore: [String]
    public var reject: [Reject]
    /// Files never placed from a mod's archive, whatever kind matched: copies of the proxy DLLs the framework
    /// places itself.
    public var deny: [String]

    public init() {
        variants = nil; wrappers = true; ignore = Self.defaultIgnore; reject = []; deny = []
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variants = try c.decodeIfPresent(String.self, forKey: .variants)
        wrappers = try c.decode(.wrappers, default: true)
        ignore = try c.decode(.ignore, default: Self.defaultIgnore)
        reject = try c.decode(.reject, default: [])
        deny = try c.decode(.deny, default: [])
    }
}

/// How the list of enabled mods (top wins in the app) is written into the game.
public struct LoadOrderSpec: Codable, Equatable, Sendable {
    public enum Format: String, Codable, Sendable {
        /// Folders renamed `000_`, `010_`… (Unreal mounts alphabetically, later wins, hence `reverse`).
        case prefixFolder
        /// `<Name> : 1/0` lines in UE4SS's `mods.txt`; other people's lines are kept.
        case ue4ssModsTxt
        /// The order the files are placed in: bottom first, the files it overwrote recorded.
        case deployOrder
        /// The loader sorts by dependencies itself (SMAPI): no handles.
        case dependencies
        /// Lenny's Mod Loader `lml/mods.xml`; later in the file wins, hence `reverse`.
        case lml
        /// A config generated for the loader before each launch (me3), in list order, first wins.
        case loaderConfig
        /// Everything loads; only on and off.
        case none
    }

    public var format: Format
    /// The game reads its order the other way round: the top of the list gets the last place.
    public var reverse: Bool
    /// Mods by name kept at one end whatever the player does, and whole kinds (`ModKind.id`) kept last.
    public var pinFirst: [String]
    public var pinLast: [String]
    public var pinLastGroups: [String]
    /// The order file (`ModPath` spec) and the config format, for the formats that have them.
    public var file: String?
    public var config: String?

    public init() {
        format = .none; reverse = false; pinFirst = []; pinLast = []; pinLastGroups = []; file = nil; config = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(.format, default: .none)
        reverse = try c.decode(.reverse, default: false)
        pinFirst = try c.decode(.pinFirst, default: [])
        pinLast = try c.decode(.pinLast, default: [])
        pinLastGroups = try c.decode(.pinLastGroups, default: [])
        file = try c.decodeIfPresent(String.self, forKey: .file)
        config = try c.decodeIfPresent(String.self, forKey: .config)
    }

    /// Whether dragging in the list means anything to the game.
    public var isReorderable: Bool { format != .dependencies && format != .none }
}

/// What counts as a conflict between enabled mods.
public struct ConflictSpec: Codable, Equatable, Sendable {
    /// Two enabled mods place the same relative path: a warning (the upper wins), or neither can be on.
    public enum SamePath: String, Codable, Sendable { case warn, block }
    /// A game rule by file name or manifest field: at most `max` enabled mods may match, or with `sameStem` two
    /// mods may not match with the same file stem. `reason` and `hint` are keys for the app's texts.
    public struct Rule: Codable, Equatable, Sendable {
        public var match: String?
        public var field: String?
        public var max: Int?
        public var sameStem: Bool
        public var reason: String
        public var hint: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            match = try c.decodeIfPresent(String.self, forKey: .match)
            field = try c.decodeIfPresent(String.self, forKey: .field)
            max = try c.decodeIfPresent(Int.self, forKey: .max)
            sameStem = try c.decode(.sameStem, default: false)
            reason = try c.decode(String.self, forKey: .reason)
            hint = try c.decodeIfPresent(String.self, forKey: .hint)
        }
    }
    /// A manifest field naming another mod this one needs ("Needs Content Patcher" with Install).
    public struct Needs: Codable, Equatable, Sendable {
        public var field: String
        public var label: String
    }

    public var samePath: SamePath
    public var rules: [Rule]
    public var needs: Needs?

    public init() { samePath = .warn; rules = []; needs = nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samePath = try c.decode(.samePath, default: .warn)
        rules = try c.decode(.rules, default: [])
        needs = try c.decodeIfPresent(Needs.self, forKey: .needs)
    }
}

/// A log the game or its loader writes, read after a failed launch like the launch diagnostics read the game's
/// own, with the rules that turn a line into a fix: turn off the mod the line names (`modFrom` is the capture
/// group with its name), the framework, or the newest mod when a crash dump merely exists.
public struct LogSpec: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case disableMod, disableFramework, disableNewestMod }
    /// A named reader of the log after the game quits, for the one-line summary on the game's card.
    public enum Summary: String, Codable, Sendable { case smapi }
    public struct Rule: Codable, Equatable, Sendable {
        public var pattern: String
        public var action: Action
        public var modFrom: Int?
        public var framework: String?
        /// The capture is the mod's unique id from its manifest, not its folder name.
        public var byUniqueID: Bool

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pattern = try c.decode(String.self, forKey: .pattern)
            action = try c.decode(Action.self, forKey: .action)
            modFrom = try c.decodeIfPresent(Int.self, forKey: .modFrom)
            framework = try c.decodeIfPresent(String.self, forKey: .framework)
            byUniqueID = try c.decode(.byUniqueID, default: false)
        }
    }
    public struct Exists: Codable, Equatable, Sendable { public var action: Action }

    /// The file (`ModPath` spec, may hold `*` in its name) and where some versions write it instead.
    public var file: String
    public var altFile: String?
    public var rules: [Rule]
    public var exists: Exists?
    public var summary: Summary?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        altFile = try c.decodeIfPresent(String.self, forKey: .altFile)
        rules = try c.decode(.rules, default: [])
        exists = try c.decodeIfPresent(Exists.self, forKey: .exists)
        summary = try c.decodeIfPresent(Summary.self, forKey: .summary)
    }
}

/// Whether the game may go online with mods on, and how a modded launch differs from a plain one. The policy
/// never changes the game's engine or bottle.
public struct OnlinePolicy: Codable, Equatable, Sendable {
    public enum Policy: String, Codable, Sendable {
        /// Online as usual.
        case allowed
        /// Story mode only: a notice once and a standing line on the mods page; "Play without mods" takes the
        /// loader out (`playWithoutModsRemoves`).
        case storyOnly
        /// With mods the game starts offline only, through the loader; with `antiCheat` the plain launch is
        /// refused while any mod is on.
        case offlineOnly
    }
    /// `same`: the game's usual path with the overrides; `loader`: the framework's `launch.loader`.
    public enum ModdedLaunch: String, Codable, Sendable { case same, loader }
    /// A save file of its own for modded play (`"default"` in the profile: on unless the player turns it off).
    public struct SeparateSave: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var via: String?
        public var file: String?

        private enum CodingKeys: String, CodingKey { case enabled = "default", via, file }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decode(.enabled, default: true)
            via = try c.decodeIfPresent(String.self, forKey: .via)
            file = try c.decodeIfPresent(String.self, forKey: .file)
        }
    }

    public var policy: Policy
    /// The anti-cheat the game runs online ("eac"), never started with mods.
    public var antiCheat: String?
    public var moddedLaunch: ModdedLaunch
    public var separateSave: SeparateSave?
    /// Leftovers (`ModPath` specs, a folder with a trailing slash) checked before a plain launch, and what "Play
    /// without mods" takes out of the game.
    public var cleanBeforeVanilla: [String]
    public var playWithoutModsRemoves: [String]
    /// Which line the code sheet gains ("offline", "storyOnly"); the texts are the app's.
    public var noticeKey: String?

    public init() {
        policy = .allowed; antiCheat = nil; moddedLaunch = .same; separateSave = nil
        cleanBeforeVanilla = []; playWithoutModsRemoves = []; noticeKey = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decode(.policy, default: .allowed)
        antiCheat = try c.decodeIfPresent(String.self, forKey: .antiCheat)
        moddedLaunch = try c.decode(.moddedLaunch, default: .same)
        separateSave = try c.decodeIfPresent(SeparateSave.self, forKey: .separateSave)
        cleanBeforeVanilla = try c.decode(.cleanBeforeVanilla, default: [])
        playWithoutModsRemoves = try c.decode(.playWithoutModsRemoves, default: [])
        noticeKey = try c.decodeIfPresent(String.self, forKey: .noticeKey)
    }

    /// The plain launch is refused while mods are on: an anti-cheat that must never see them.
    public var forbidsPlainLaunchWithMods: Bool { policy == .offlineOnly && antiCheat != nil }
}

/// Odds and ends about the game.
public struct ModProfileNotes: Codable, Equatable, Sendable {
    /// A file whose change means the game updated (mods may stop working until the framework does too).
    public var gameVersionFile: String?
    /// Paths Sommelier never touches (the game's own mod system): a test checks removing our mods leaves them.
    public var untouched: [String]
    /// Turning off the last mod with code takes the framework and its overrides out too.
    public var cleanupOnLastCodeMod: Bool

    public init() { gameVersionFile = nil; untouched = []; cleanupOnLastCodeMod = true }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gameVersionFile = try c.decodeIfPresent(String.self, forKey: .gameVersionFile)
        untouched = try c.decode(.untouched, default: [])
        cleanupOnLastCodeMod = try c.decode(.cleanupOnLastCodeMod, default: true)
    }
}

/// `{ "version": 1, "games": [ModProfile…] }`. An entry this version can't read is left out; the rest stay.
public struct ModsList: Codable, Sendable {
    public var version: Int
    public var games: [ModProfile]

    private struct Lenient: Decodable {
        let profile: ModProfile?
        init(from decoder: Decoder) throws { profile = try? ModProfile(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        games = try c.decode([Lenient].self, forKey: .games).compactMap(\.profile)
    }

    /// The entry for an installed copy of a game: by its id or an alias, and for its runtime. Nil means the game
    /// shows no mods section.
    public func profile(for game: Game) -> ModProfile? { games.first { $0.applies(to: game) } }

    /// The entry naming a game id, whatever runtime it serves.
    public func profile(covering gameID: String) -> ModProfile? { games.first { $0.covers(gameID) } }
}

extension ModsList: VersionedList {}

/// Keeps the mods list online on disk (`Mods.json`) and refreshes it at most once a day. The list changes what
/// runs, so it must come signed.
public struct ModsService: Sendable {
    let list: OnlineList<ModsList>

    public init(paths: Paths, baseURL: URL? = nil, session: URLSession = .shared) {
        list = OnlineList(path: "v1/mods.json", file: paths.home.appendingPathComponent("Mods.json"), baseURL: baseURL, session: session, signed: true)
    }

    public func cached() -> ModsList? { list.cached() }
    @discardableResult public func refresh(now: Date = Date()) async -> ModsList? { await list.refresh(now: now) }
}

/// A place a profile names: one of the roots the mods know and a relative path under it, written
/// "root:relative/path" ("game:Phoenix/Binaries/Win64/", "tools:me3/bin/me3.exe", "home:.config/StardewValley").
/// The path may be empty (the root itself), name a file of any type, hold `*` in a name and the `{slot}`,
/// `{name}` and `{next}` placeholders; never `..`, a drive or an absolute path.
public struct ModPath: Equatable, Sendable {
    public enum Root: String, CaseIterable, Sendable {
        /// The game's folder; for a Mac version the `Contents/MacOS` folder inside its `.app`.
        case game
        /// Sommelier's mod store for the game (`<Sommelier>/Mods/<game>/`).
        case store
        /// `<Sommelier>/Tools/`, for a loader that must not sit in the game (me3).
        case tools
        /// The Mac user's home folder.
        case home
        /// The Windows user's `AppData\Local`, `AppData\Roaming` and `Documents` in the game's bottle.
        case appdata, roaming, documents
    }

    public let root: Root
    public let path: String

    public init?(_ spec: String) {
        guard let colon = spec.firstIndex(of: ":"), let root = Root(rawValue: String(spec[..<colon])) else { return nil }
        let path = String(spec[spec.index(after: colon)...])
        guard Self.isSafe(path) else { return nil }
        self.root = root; self.path = path
    }

    public var spec: String { "\(root.rawValue):\(path)" }

    /// The path's parts, with either kind of slash.
    public var components: [String] { path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) }

    /// Relative, with real names only: nothing that could leave the root.
    public static func isSafe(_ path: String) -> Bool {
        guard path.count <= 300, !path.contains(":"), !path.contains("\0"), !path.hasPrefix("/"), !path.hasPrefix("\\") else { return false }
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return parts.allSatisfy { $0 != ".." && $0 != "." }
    }
}

/// The folders behind each `ModPath.Root` for one installed copy of a game. A root a copy doesn't have (the
/// Windows folders of a Mac version, a game that isn't installed) resolves to nothing.
public struct ModRoots: Equatable, Sendable {
    public let game: URL?
    public let store: URL
    public let tools: URL
    public let home: URL
    public let appdata: URL?, roaming: URL?, documents: URL?

    /// Direct form, handy in tests.
    public init(game: URL?, store: URL, tools: URL, home: URL, appdata: URL? = nil, roaming: URL? = nil, documents: URL? = nil) {
        self.game = game; self.store = store; self.tools = tools; self.home = home
        self.appdata = appdata; self.roaming = roaming; self.documents = documents
    }

    /// For an installed copy. A Wine copy's Windows folders come from its bottle's user profile (as the save
    /// roots find it); a Mac version has none of them, its `documents:` is the Mac's and its `game:` is the
    /// `Contents/MacOS` folder of the `.app` it is installed as.
    public init(game: Game, bottle: Bottle?, paths: Paths, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let store = paths.mods(game.id)
        if game.isNative {
            self.init(game: game.installPath.flatMap(Self.nativeBinaries(in:)), store: store, tools: paths.tools, home: home,
                      documents: home.appendingPathComponent("Documents", isDirectory: true))
        } else {
            let profile = bottle.map { SaveRoots(bottle: $0, installPath: game.installPath).profile }
            self.init(game: game.installPath, store: store, tools: paths.tools, home: home,
                      appdata: profile?.appendingPathComponent("AppData/Local", isDirectory: true),
                      roaming: profile?.appendingPathComponent("AppData/Roaming", isDirectory: true),
                      documents: profile?.appendingPathComponent("Documents", isDirectory: true))
        }
    }

    /// The programs folder of the Mac version installed at `installPath`: the `.app` itself, or the one `.app`
    /// inside the folder (Steam installs `Stardew Valley/Stardew Valley.app`). Nil when there is none.
    public static func nativeBinaries(in installPath: URL) -> URL? {
        let app: URL?
        if installPath.pathExtension == "app" {
            app = installPath
        } else {
            // By name, so the folder is named the way the library names it (no links resolved on the way).
            let names = (try? FileManager.default.contentsOfDirectory(atPath: installPath.path)) ?? []
            app = names.filter { $0.hasSuffix(".app") }.sorted().first.map { installPath.appendingPathComponent($0, isDirectory: true) }
        }
        return app?.appendingPathComponent("Contents/MacOS", isDirectory: true)
    }

    public func base(_ root: ModPath.Root) -> URL? {
        switch root {
        case .game: game
        case .store: store
        case .tools: tools
        case .home: home
        case .appdata: appdata
        case .roaming: roaming
        case .documents: documents
        }
    }

    /// Where a path is on this Mac, or nil when its root isn't there for this copy. The place need not exist, and
    /// nothing on disk is looked at: a trailing slash in the spec is what makes it a folder.
    public func resolve(_ path: ModPath) -> URL? {
        guard let top = base(path.root) else { return nil }
        let parts = path.components
        guard !parts.isEmpty else { return top }
        let folder = path.path.hasSuffix("/") || path.path.hasSuffix("\\")
        return URL(fileURLWithPath: ([top.path] + parts).joined(separator: "/"), isDirectory: folder)
    }

    /// `resolve` for a spec as the profile writes it; nil for an unsafe or unknown one.
    public func resolve(_ spec: String) -> URL? { ModPath(spec).flatMap(resolve) }
}

extension KeyedDecodingContainer {
    /// The value, or `fallback` when the key is absent or null. A value of the wrong shape (an unknown enum case
    /// among them) still throws, which is what makes the whole entry invalid.
    fileprivate func decode<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

// MARK: - The player's mod state

/// What the player has settled about a game's mods beyond the store's own records (which mods are on, their
/// order and the code consent live in `mod.json` and `order.json`): the choices and notices that belong to the
/// game rather than to one mod. Kept in `UserGameData.mods`.
public struct ModState: Equatable, Codable, Sendable {
    /// The player's choice for a loader's own save file (`online.separateSave`); nil means the profile's default.
    public var separateSave: Bool?
    /// The one-time line about the game's online policy (`online.noticeKey`) was shown with the first mod.
    public var noticeShown: Bool?
    /// A backup of the saves was made before the first mod went in.
    public var savesBackedUp: Bool?
    /// What the loader said about the last session (SMAPI's summary), as one line for the mods page, and when.
    public var lastSummary: String?
    public var lastSummaryDate: Date?
    /// The game's version stamp (`ModGameVersion`) when the mods were last checked: a different one now means
    /// the game updated under them.
    public var gameVersion: String?

    public init() {}
}
