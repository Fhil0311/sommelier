// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Wine Mono, the open-source .NET runtime Wine uses in place of Microsoft's.
///
/// Installers and launchers with managed code fail without it: the EA app's installer runs a .NET custom action
/// and stops with error 1603, and Mafia: Definitive Edition's launcher never opens. The MSI is downloaded once from
/// WineHQ into `Paths.tools`, checked against the digest Wine itself pins for this release, and installed only into
/// bottles that need it.
public struct WineMono: Sendable {   // one per Sommelier home
    /// The release Wine 11 asks for and its digest (`MONO_VERSION` and `MONO_SHA` in Wine's
    /// `dlls/appwiz.cpl/addons.c`).
    public static let version = "10.4.1", sha256 = "071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23"
    public static let downloadURL: URL = {
        let file = "wine-mono-\(version)-x86.msi"
        guard let url = URL(string: "https://dl.winehq.org/wine/wine-mono/\(version)/\(file)") else {
            preconditionFailure("invalid Wine Mono URL")
        }
        return url
    }()

    public let paths: Paths   // where the installer is cached
    public init(paths home: Paths) { paths = home }

    /// Where the downloaded MSI is kept between installs.
    public var cachedInstaller: URL { paths.tools.appendingPathComponent(Self.downloadURL.lastPathComponent) }

    /// Hex SHA-256 of a file.
    static func digest(of installer: URL) throws -> String {
        let bytes = try Data(contentsOf: installer, options: .mappedIfSafe)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Installs Wine Mono into `target` unless it is already there.
    public func ensureInstalled(in target: Bottle, engine runtime: Engine) async throws {
        if target.hasMono { return }
        let msi = try await installerReadyToRun()
        var environment = WineRunner.environment(bottle: target, profile: LaunchProfile())
        // The usual overrides disable mscoree; the installer is the one thing that must be able to load it.
        environment["WINEDLLOVERRIDES"] = "mshtml=;winemenubuilder.exe=d"
        let dosPath = "Z:" + msi.path.replacingOccurrences(of: "/", with: "\\")
        let run = try await ProcessRunner.run(runtime.wine, ["msiexec", "/i", dosPath, "/qn"], environment: environment)
        // msiexec can exit 0 without installing anything, so the bottle itself is checked as well.
        if !run.succeeded || !target.hasMono { throw Self.failure("couldn't install the .NET runtime (Wine Mono)") }
    }

    /// The cached MSI if its digest still matches; otherwise a fresh, verified download.
    func installerReadyToRun() async throws -> URL {
        let cached = cachedInstaller
        if FileManager.default.fileExists(atPath: cached.path) {
            if (try? Self.digest(of: cached)) == Self.sha256 { return cached }
            try? FileManager.default.removeItem(at: cached)   // damaged or from an interrupted copy
        }

        let (downloaded, response) = try await URLSession.shared.download(from: Self.downloadURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            throw Self.failure("couldn't download the .NET runtime (Wine Mono)")
        }
        if try Self.digest(of: downloaded) != Self.sha256 {
            throw Self.failure("the downloaded .NET runtime failed its integrity check")
        }
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloaded, to: cached)
        return cached
    }

    private static func failure(_ reason: String) -> Error { WineRunnerError.launchFailed(reason) }
}
