// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import OSLog

/// The runtime libraries Windows games take for granted: the Visual C++ 2015–2022 runtime and the DirectX June 2010
/// runtime (d3dx9/10/11, d3dcompiler_43, XAudio2, X3DAudio, XInput). Steam's own client installs them for each game
/// from its "Steamworks Common Redistributables"; an Epic or GOG download brings only the game's files, and Wine's
/// stand-ins for these DLLs fall short for many games (the most frequent fix in Proton's and Heroic's lists). So
/// Sommelier installs Microsoft's own packages once per environment that has no client to do it: downloaded from
/// Microsoft, run silently. Wine Mono (.NET) goes in first: DXSETUP needs it. A marker in the environment records
/// the set's version.
public struct RuntimeSetup: Sendable {
    /// Bumped when the set changes, so environments made before get the additions.
    public static let version = 1
    static let vcRedist = [
        ("vc_redist.x64.exe", URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!),
        ("vc_redist.x86.exe", URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!),
    ]
    static let directX = ("directx_Jun2010_redist.exe",
                          URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!)

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    var cache: URL { paths.tools.appendingPathComponent("redist", isDirectory: true) }
    static func marker(in bottle: Bottle) -> URL { bottle.url.appendingPathComponent(".sommelier-runtime") }

    /// Environments whose games come without a client to install their runtime: Epic's and GOG's.
    public static func needsRuntime(_ kind: BottleKind) -> Bool { kind == .epic || kind == .gog }

    public static func isInstalled(in bottle: Bottle) -> Bool {
        (try? String(contentsOf: marker(in: bottle), encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0 >= version
    }

    /// Installs the set into `bottle` unless its marker says it's there. Mono first (quick), then Visual C++, then
    /// DirectX. A package that fails is skipped, not fatal: the others still help, and the marker isn't written, so
    /// the next launch tries again.
    public func ensureInstalled(in bottle: Bottle, engine: Engine) async {
        guard bottle.exists, !Self.isInstalled(in: bottle) else { return }
        let log = Logger(subsystem: "gg.sommelier", category: "runtime")
        var complete = true
        do { try await WineMono(paths: paths).ensureInstalled(in: bottle, engine: engine) } catch {
            complete = false; log.error("Runtime: Mono: \(error.localizedDescription, privacy: .public)")
        }
        var env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: engine)
        env["WINEDLLOVERRIDES"] = "mshtml=;winemenubuilder.exe=d"
        for (name, url) in Self.vcRedist {
            do {
                let installer = try await cached(name, from: url)
                let r = try await ProcessRunner.run(engine.wine, [installer.windowsPath, "/quiet", "/norestart"], environment: env)
                // 0 = done, 1638 = a newer version is there, 3010 = done, asks to reboot
                guard [0, 1638, 3010].contains(r.status) else { throw RuntimeSetupError.installerFailed(name, r.status) }
            } catch { complete = false; log.error("Runtime: \(name, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        do { try await installDirectX(in: bottle, engine: engine, environment: env) } catch {
            complete = false; log.error("Runtime: DirectX: \(error.localizedDescription, privacy: .public)")
        }
        if complete {
            try? String(Self.version).write(to: Self.marker(in: bottle), atomically: true, encoding: .utf8)
            log.info("Runtime: set \(Self.version) installed in \(bottle.kind.rawValue, privacy: .public)")
        }
    }

    /// The DirectX package is a self-extracting archive with DXSETUP inside: extracted to a temporary folder in the
    /// environment, then run silently (about half a minute). It wants .NET for its "Managed DirectX" part, hence
    /// Mono first; without it, it stops at that part and installs nothing.
    func installDirectX(in bottle: Bottle, engine: Engine, environment env: [String: String]) async throws {
        let package = try await cached(Self.directX.0, from: Self.directX.1)
        let work = bottle.driveC.appendingPathComponent("dxredist")
        defer { try? FileManager.default.removeItem(at: work) }
        let extract = try await ProcessRunner.run(engine.wine, [package.windowsPath, "/Q", "/C", "/T:C:\\dxredist"], environment: env)
        guard extract.succeeded, FileManager.default.fileExists(atPath: work.appendingPathComponent("DXSETUP.exe").path) else {
            throw RuntimeSetupError.installerFailed(Self.directX.0, extract.status)
        }
        let setup = try await ProcessRunner.run(engine.wine, ["C:\\dxredist\\DXSETUP.exe", "/silent"], environment: env)
        // DXSETUP's own log has the last word ("Installation ended with value 0 = Installation succeeded").
        let log = (try? String(contentsOf: bottle.driveC.appendingPathComponent("windows/logs/DirectX.log"), encoding: .utf8)) ?? ""
        guard setup.succeeded, log.contains("Installation succeeded") else { throw RuntimeSetupError.installerFailed("DXSETUP.exe", setup.status) }
    }

    /// The package from the cache, downloaded first when it isn't there.
    func cached(_ name: String, from url: URL) async throws -> URL {
        let fm = FileManager.default
        let file = cache.appendingPathComponent(name)
        if fm.fileExists(atPath: file.path) { return file }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RuntimeSetupError.downloadFailed(name) }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: tmp, to: file)
        return file
    }
}

public enum RuntimeSetupError: Error, LocalizedError {
    case downloadFailed(String)
    case installerFailed(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let name): "couldn't download \(name)"
        case .installerFailed(let name, let status): "\(name) failed with status \(status)"
        }
    }
}

/// A game's own prerequisite installers, which the store's client would run after the download on Windows: Epic's
/// manifests name one (`prereq_info`: typically the Unreal prerequisites or a Visual C++ package, with its silent
/// switches) and Legendary records it with the install without running it. Sommelier runs it once, in the game's
/// environment, and leaves a marker in the game's folder.
public enum GamePrerequisites {
    public struct Installer: Equatable, Sendable {
        public var path: String
        public var arguments: [String]
    }

    static let marker = ".sommelier-prerequisites"

    /// The installer an Epic game asks for, from Legendary's `installed.json`.
    public static func epicInstaller(for storeID: String, installedJSON: Data) -> Installer? {
        guard let all = try? JSONSerialization.jsonObject(with: installedJSON) as? [String: Any],
              let game = all[storeID] as? [String: Any], let info = game["prereq_info"] as? [String: Any],
              let path = info["path"] as? String, !path.isEmpty else { return nil }
        let args = (info["args"] as? String ?? "").split(separator: " ").map(String.init)
        return Installer(path: path, arguments: args)
    }

    public static func isDone(in folder: URL) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(marker).path) }

    /// Runs the installer from the game's folder, silently, and marks the folder. An installer that isn't there
    /// (some manifests name one the download doesn't carry) counts as done.
    public static func run(_ installer: Installer, in folder: URL, bottle: Bottle, engine: Engine) async throws {
        let exe = folder.appendingPathComponent(installer.path.replacingOccurrences(of: "\\", with: "/"))
        if FileManager.default.fileExists(atPath: exe.path) {
            var env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: engine)
            env["WINEDLLOVERRIDES"] = "mshtml=;winemenubuilder.exe=d"
            let r = try await ProcessRunner.run(engine.wine, [exe.windowsPath] + installer.arguments, environment: env)
            guard [0, 1638, 3010].contains(r.status) else { throw RuntimeSetupError.installerFailed(installer.path, r.status) }
        }
        try? "".write(to: folder.appendingPathComponent(marker), atomically: true, encoding: .utf8)
    }
}

extension URL {
    /// The path as Wine sees it (`Z:\…`).
    var windowsPath: String { "Z:" + path.replacingOccurrences(of: "/", with: "\\") }
}
