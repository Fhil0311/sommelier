// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The stores Sommelier keeps a Wine prefix for. The raw value names the prefix's folder.
public enum BottleKind: String, Codable, Sendable, CaseIterable { case steam, epic, gog, ubisoft, ea, battlenet }

/// One store's Wine prefix (a "bottle"): `<home>/Bottles/<kind>`. A plain description of where things are;
/// `BottleManager` creates it.
public struct Bottle: Sendable, Equatable {
    public let kind: BottleKind
    /// The prefix folder.
    public let url: URL

    public init(kind: BottleKind, paths: Paths) {
        self.kind = kind
        url = paths.bottle(kind.rawValue)
    }

    /// The Windows `C:` drive.
    public var driveC: URL { url.appendingPathComponent("drive_c") }
    /// Steam's install folder, where its installer puts it.
    public var steamDirectory: URL { driveC.appendingPathComponent("Program Files (x86)/Steam") }
    public var steamExecutable: URL { steamDirectory.appendingPathComponent("steam.exe") }

    /// Set up by `wineboot`: the Windows folder is there.
    public var exists: Bool { Self.present(driveC.appendingPathComponent("windows")) }
    /// Wine Mono (Wine's .NET runtime) has been installed.
    public var hasMono: Bool { Self.present(driveC.appendingPathComponent("windows/mono/mono-2.0")) }

    private static func present(_ item: URL) -> Bool { FileManager.default.fileExists(atPath: item.path) }
}

public extension Bottle {
    /// How a program in this bottle names a Mac file: `C:\…` inside `drive_c`, otherwise `Z:\…`, Wine's drive
    /// for the Mac's root folder.
    func windowsPath(of url: URL) -> String {
        let full = url.standardizedFileURL.path
        let cRoot = driveC.standardizedFileURL.path + "/"
        let windows = full.hasPrefix(cRoot) ? "C:/" + full.dropFirst(cRoot.count) : "Z:" + full
        return windows.replacingOccurrences(of: "/", with: "\\")
    }

    /// The Windows user's folders that Wine links to the Mac's own (Documents, Downloads, Music, Pictures, Videos,
    /// Templates, and the link to the Mac's desktop inside Desktop).
    static let linkedUserFolders = ["Documents", "Downloads", "Music", "Pictures", "Videos", "Templates"]

    /// Makes the Windows user's folders real folders inside the environment instead of links to the Mac's: games
    /// keep their saves and settings here, never touch the player's own files, and macOS never asks for access to
    /// Documents on their behalf. Each gets a `desktop.ini` (as on Windows), so Wine, which links an empty folder
    /// again when the environment is updated, leaves it alone. What the player's Mac folders hold isn't copied.
    /// Not while the environment runs (a game could be writing there).
    @discardableResult
    func isolateUserFolders() -> [String] {
        let fm = FileManager.default
        let users = driveC.appendingPathComponent("users")
        var changed: [String] = []
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] where user.lastPathComponent != "Public" {
            for name in Self.linkedUserFolders {
                let folder = user.appendingPathComponent(name)
                if let target = try? fm.destinationOfSymbolicLink(atPath: folder.path), !target.hasPrefix(url.path) {
                    guard (try? fm.removeItem(at: folder)) != nil else { continue }
                    changed.append(name)
                }
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: folder.path, isDirectory: &isDir) {
                    guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { continue }
                } else if !isDir.boolValue { continue }
                let ini = folder.appendingPathComponent("desktop.ini")
                if !fm.fileExists(atPath: ini.path) { try? "[.ShellClassInfo]\r\n".write(to: ini, atomically: true, encoding: .utf8) }
            }
            // CrossOver puts a link to the Mac's desktop inside the Windows desktop.
            for name in ["My Mac Desktop", "My Linux Desktop"] {
                let link = user.appendingPathComponent("Desktop/\(name)")
                if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil, (try? fm.removeItem(at: link)) != nil { changed.append("Desktop/\(name)") }
            }
        }
        return changed
    }

    /// The Mac file behind a Windows path such as `D:\Games\x`, accepting either slash. `C:` is `drive_c`; any
    /// other letter follows the bottle's `dosdevices` link for it (`Z:` → `/`, so Steam libraries on the Mac's
    /// disk or an external one resolve too). Nil when the path has no drive or the bottle has no such drive.
    func unixURL(forWindowsPath path: String) -> URL? {
        var components = path.split { $0 == "/" || $0 == "\\" }.map(String.init)
        guard !components.isEmpty else { return nil }
        let letter = components.removeFirst().lowercased()
        guard letter.count == 2, letter.last == ":", let base = driveRoot(letter) else { return nil }
        return components.reduce(base) { $0.appendingPathComponent($1) }
    }

    /// Where a lowercased drive (`"d:"`) points on the Mac, or nil when the bottle doesn't map it.
    private func driveRoot(_ letter: String) -> URL? {
        if letter == "c:" { return driveC }
        let devices = url.appendingPathComponent("dosdevices", isDirectory: true)
        let link = devices.appendingPathComponent(letter)
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        // Wine's links are usually relative (`../drive_c`), so they resolve against the dosdevices folder.
        return URL(fileURLWithPath: destination, relativeTo: devices).standardizedFileURL
    }
}

/// Creates and fills the stores' prefixes. Every step is safe to repeat.
public struct BottleManager: Sendable {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func bottle(_ kind: BottleKind) -> Bottle { .init(kind: kind, paths: paths) }

    /// Returns the store's prefix, creating it with `wineboot` and Sommelier's registry defaults when it is missing.
    @discardableResult public func ensure(_ kind: BottleKind, engine: Engine) async throws -> Bottle {
        let bottle = self.bottle(kind)
        guard !bottle.exists else { return bottle }
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true, attributes: nil)
        let env = WineRunner.environment(bottle: bottle, profile: .init())
        let created = try await ProcessRunner.run(engine.wine, ["wineboot", "--init"], environment: env)
        if !created.succeeded || !bottle.exists {
            throw WineRunnerError.launchFailed("couldn't create the \(kind.rawValue) environment")
        }
        // Mac players reach for ⌘ where Windows wants Ctrl, so the left Command key sends Ctrl.
        let macDriver = #"HKCU\Software\Wine\Mac Driver"#
        _ = try await ProcessRunner.run(engine.wine, ["reg", "add", macDriver, "/v", "LeftCommandIsCtrl", "/d", "y", "/f"],
                                        environment: env)
        // No "Wine Debugger" window when a helper process crashes: Sommelier reads the logs instead.
        _ = try await ProcessRunner.run(
            engine.wine, ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"],
            environment: env)
        bottle.isolateUserFolders()
        if kind == .epic {
            // Some Epic games look for the Epic launcher's URL scheme and won't start without the key (Fallout New
            // Vegas, Dishonored: Death of the Outsider); the key alone satisfies them. Heroic does the same.
            _ = try await ProcessRunner.run(engine.wine, ["reg", "add", #"HKEY_CLASSES_ROOT\com.epicgames.launcher"#, "/f"], environment: env)
        }
        return bottle
    }

    /// Epic and GOG prefixes hold nothing but games, so the first Play creates them. Steam, Ubisoft and EA get
    /// theirs while their launcher is installed: an empty one made earlier would hide a missing launcher.
    public static func createsEnvironmentOnPlay(_ store: StoreKind) -> Bool { [.epic, .gog].contains(store) }

    /// Readies the prefix a game of `store` plays in, rebuilding it if it's gone (say, after a reset). Returns
    /// nil, doing nothing, for stores whose launcher sets up its own prefix.
    @discardableResult public func prepareForPlay(_ store: StoreKind, engine: Engine) async throws -> Bottle? {
        if !Self.createsEnvironmentOnPlay(store) { return nil }
        let prepared = try await ensure(store.bottleKind, engine: engine)
        provisionRuntime(in: prepared.kind)
        return prepared
    }

    /// Runtime DLLs a new prefix lacks but some games' plugins link against. The MFC runtime is one: Moonlighter's
    /// Razer Chroma plugin needs it, or `GameManager.Awake` throws and the screen stays black. Steam's prefix
    /// usually has them (it installs the Visual C++ runtime), so they're copied from any other prefix that does.
    /// Nothing is downloaded and nothing already there is replaced. Returns `folder/dll` for each copy.
    @discardableResult public func provisionRuntime(in kind: BottleKind) -> [String] {
        let destination = bottle(kind)
        guard destination.exists else { return [] }
        let files = FileManager.default
        let donors = BottleKind.allCases.filter { $0 != kind }.map(bottle).filter(\.exists)
        var copied = [String]()
        for donor in donors {
            for relative in Self.runtimeFiles {
                let from = donor.driveC.appendingPathComponent("windows/" + relative)
                let to = destination.driveC.appendingPathComponent("windows/" + relative)
                guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { continue }
                if (try? files.copyItem(at: from, to: to)) != nil { copied.append(relative) }
            }
        }
        return copied
    }

    /// The runtime files `provisionRuntime` looks for, relative to `C:\windows`.
    private static let runtimeFiles = ["system32", "syswow64"].flatMap { folder in
        ["mfc140u.dll", "mfcm140u.dll"].map { "\(folder)/\($0)" }
    }
}
