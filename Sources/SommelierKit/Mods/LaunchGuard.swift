// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Decides how a game with mods starts, from the profile's online policy: the game's usual path with the
/// framework's overrides, or the framework's own loader (me3), and whether the usual path is allowed at all while
/// mods are on (an anti-cheat that must never see them). Before a launch without mods it looks for what other
/// loaders left in the game folder (`cleanBeforeVanilla`), so the anti-cheat doesn't meet those either. It only
/// chooses the path and builds the loader's command: the game's engine and bottle are never its to change, whatever
/// the policy says (Denuvo in Hogwarts Legacy wants the same engine every time).
public struct LaunchGuard: Sendable {
    public let profile: ModProfile
    public let roots: ModRoots

    public init(profile: ModProfile, roots: ModRoots) { self.profile = profile; self.roots = roots }

    /// How the loader is started: a Windows program on this Mac, its arguments with `{gameExe}` and `{config}`
    /// filled in, and its folder as the working directory. The app runs it in the game's bottle through
    /// `WineRunner`, with the game's launch profile.
    public struct LoaderCommand: Equatable, Sendable {
        public var framework: String
        public var executable: URL
        public var arguments: [String]
        public var workingDirectory: URL
        /// The loader starts the game through the bottle's Steam, which must be running.
        public var steamInBottle: Bool
        /// The config the loader reads (`loadOrder.file`), regenerated before each launch.
        public var config: URL?
    }

    /// The path a launch takes.
    public enum Launch: Equatable, Sendable {
        /// The game's usual path, with whatever the launch profile holds. `leftovers` are other loaders' files
        /// found in the game folder before a launch without mods (`FixAction.removeModLeftovers` takes them out).
        case plain(leftovers: [String])
        case loader(LoaderCommand)
    }

    /// Why the game can't start the way it was asked to.
    public enum Refusal: Error, Equatable {
        /// Mods are on and the policy allows no usual launch, but the loader framework isn't installed (nil: the
        /// profile names none).
        case loaderRequired(framework: String?)
        /// The loader framework is installed but its program isn't where the profile says.
        case loaderMissing(String)
        /// The game's program the loader needs isn't known.
        case gameMissing
    }

    // MARK: The path

    /// Whether the usual path may start the game right now.
    public func allowsPlainLaunch(modsEnabled: Bool) -> Bool { !(modsEnabled && profile.online.forbidsPlainLaunchWithMods) }

    /// The framework whose loader starts a modded game, when the profile has one.
    public var loaderFramework: ModFramework? { profile.frameworks.first { $0.launch?.loader != nil } }

    /// The path for a launch: the loader when mods are on and the policy wants it (or has it installed and asks
    /// for it), the usual path otherwise. `installed` are the frameworks in the game; `gameExe` is the game's
    /// program when the app knows it (else the loader's `{gameExe:default}` names it); `windowsPath` turns a Mac
    /// path into the one the loader sees in the bottle.
    public func decide(modsEnabled: Bool, installed: Set<String>, gameExe: URL? = nil,
                       windowsPath: (URL) -> String = LaunchGuard.winePath) throws -> Launch {
        guard modsEnabled else { return .plain(leftovers: leftovers()) }
        let wantsLoader = profile.online.moddedLaunch == .loader || profile.online.forbidsPlainLaunchWithMods
        guard wantsLoader else { return .plain(leftovers: []) }
        guard let framework = loaderFramework, installed.contains(framework.id) else {
            if profile.online.forbidsPlainLaunchWithMods { throw Refusal.loaderRequired(framework: loaderFramework?.id) }
            return .plain(leftovers: [])
        }
        return .loader(try loaderCommand(framework, gameExe: gameExe, windowsPath: windowsPath))
    }

    /// The loader's command from the framework's `launch.loader`: `{gameExe}` (or `{gameExe:Game/x.exe}`, the
    /// default under the game's folder) and `{config}` (`{profile}` too) are filled in as paths in the bottle.
    public func loaderCommand(_ framework: ModFramework, gameExe: URL? = nil, windowsPath: (URL) -> String = LaunchGuard.winePath) throws -> LoaderCommand {
        guard let loader = framework.launch?.loader else { throw Refusal.loaderMissing(framework.id) }
        guard let executable = roots.resolve(loader.exe), FileScan.isRegularFile(executable) else { throw Refusal.loaderMissing(framework.id) }
        let config = profile.loadOrder.file.flatMap(roots.resolve)
        var arguments: [String] = []
        for argument in loader.args {
            arguments.append(try Self.expand(argument) { name, fallback in
                switch name {
                case "gameExe":
                    if let gameExe { return windowsPath(gameExe) }
                    guard let fallback, let game = roots.game, ModPath.isSafe(fallback) else { throw Refusal.gameMissing }
                    return windowsPath(URL(fileURLWithPath: ([game.path] + fallback.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)).joined(separator: "/")))
                case "config", "profile":
                    guard let config else { throw Refusal.loaderMissing(framework.id) }
                    return windowsPath(config)
                default:
                    return nil
                }
            })
        }
        return LoaderCommand(framework: framework.id, executable: executable, arguments: arguments,
                             workingDirectory: executable.deletingLastPathComponent(), steamInBottle: loader.steamInBottle, config: config)
    }

    /// `{name}` and `{name:default}` placeholders in an argument, each replaced by what `value` gives for it; one
    /// it doesn't know stays as written.
    static func expand(_ argument: String, value: (String, String?) throws -> String?) rethrows -> String {
        var out = "", rest = Substring(argument)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { out += rest[open...]; return out }
            let inside = rest[rest.index(after: open)..<close]
            let name = String(inside.prefix(while: { $0 != ":" }))
            let fallback = inside.contains(":") ? String(inside.drop(while: { $0 != ":" }).dropFirst()) : nil
            out += try value(name, fallback) ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    /// A Mac path as Wine shows it on its `Z:` drive.
    public static func winePath(_ url: URL) -> String { "Z:" + url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\") }

    // MARK: Saves

    /// Whether a modded launch keeps its own save file: the profile's default unless the player chose.
    public func usesSeparateSave(playerChoice: Bool? = nil) -> Bool {
        guard let save = profile.online.separateSave else { return false }
        return playerChoice ?? save.enabled
    }

    /// The modded save file's name, when the loader keeps one.
    public var separateSaveFile: String? { profile.online.separateSave?.file }

    // MARK: Leftovers

    /// What other loaders left in the game folder, of the things the profile's `cleanBeforeVanilla` lists (or
    /// `specs`): the specs that exist right now, a `*` in a name standing for each file it matches. Files the
    /// deployer placed are Sommelier's own and are left out.
    public func leftovers(_ specs: [String]? = nil, deployer: ModDeployer? = nil) -> [String] {
        Self.present(specs ?? profile.online.cleanBeforeVanilla, roots: roots, deployer: deployer)
    }

    /// What "Play without mods" takes out of the game (`playWithoutModsRemoves`): Sommelier's own files, which
    /// the deployer and the framework installer take out properly, and other loaders' files, moved aside.
    public func playWithoutModsTargets(deployer: ModDeployer) -> (ours: [String], foreign: [String]) {
        let all = Self.present(profile.online.playWithoutModsRemoves, roots: roots, deployer: nil)
        let owned = Self.deployedSpecs(deployer)
        return (all.filter { Self.isOwned($0, by: owned) }, all.filter { !Self.isOwned($0, by: owned) })
    }

    static func present(_ specs: [String], roots: ModRoots, deployer: ModDeployer?) -> [String] {
        let owned = deployer.map(deployedSpecs) ?? []
        var found: [String] = []
        for spec in specs {
            guard let path = ModPath(spec), !path.path.isEmpty, let url = roots.resolve(path) else { continue }
            let folder = path.path.hasSuffix("/") || path.path.hasSuffix("\\")
            let name = path.components.last ?? ""
            if name.contains("*") || name.contains("?") {
                let parent = url.deletingLastPathComponent()
                let prefix = ModArchive.parentSpec(path.spec)
                for entry in ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).sorted() where ModGlob.matchesName(name, entry) {
                    let candidate = prefix + entry + (FileScan.isDirectory(parent.appendingPathComponent(entry)) ? "/" : "")
                    if !isOwned(candidate, by: owned) { found.append(candidate) }
                }
                continue
            }
            guard FileScan.attributes(url) != nil, FileScan.isDirectory(url) == folder, !isOwned(path.spec, by: owned) else { continue }
            found.append(path.spec)
        }
        return found
    }

    private static func deployedSpecs(_ deployer: ModDeployer) -> [String] { deployer.owners().flatMap(deployer.deployed) }

    /// A spec is Sommelier's when the deployer placed it, or placed something inside it.
    private static func isOwned(_ spec: String, by owned: [String]) -> Bool {
        owned.contains { $0.lowercased() == spec.lowercased() || (spec.hasSuffix("/") && $0.lowercased().hasPrefix(spec.lowercased())) }
    }

    /// Moves the leftovers out of the game into the store's `.leftovers/<when>/`, keeping their paths, and returns
    /// the specs moved. Nothing is deleted, and nothing the deployer placed is touched.
    @discardableResult
    public static func removeLeftovers(_ specs: [String], roots: ModRoots, store: ModStore, deployer: ModDeployer? = nil, now: Date = Date()) throws -> [String] {
        let present = present(specs, roots: roots, deployer: deployer ?? ModDeployer(roots: roots, store: store))
        guard !present.isEmpty else { return [] }
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let bin = store.folder.appendingPathComponent(".leftovers", isDirectory: true).appendingPathComponent(stamp, isDirectory: true)
        let disk = FileManager.default
        var moved: [String] = []
        for spec in present {
            guard let path = ModPath(spec), let url = roots.resolve(path) else { continue }
            let target = URL(fileURLWithPath: ([bin.path, path.root.rawValue] + path.components).joined(separator: "/"))
            try disk.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileScan.attributes(target) != nil { try disk.removeItem(at: target) }
            try disk.moveItem(at: url, to: target)
            moved.append(spec)
        }
        return moved
    }
}
