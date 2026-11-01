// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Why D3DMetal couldn't be imported, worded for the person using the app.
public enum D3DMetalError: Equatable, LocalizedError {
    /// hdiutil couldn't mount the image (often because Apple's license on it hasn't been accepted in Finder).
    case couldNotOpen, notFound
    /// Carries the file name that failed the check, the missing DLL, or the underlying error text.
    case notSignedByApple(String), missingModule(String), copyFailed(String)

    public var errorDescription: String? { message }

    private var message: String {
        switch self {
        case .couldNotOpen: return "Couldn't open the disk image. Open it in Finder first (agree to Apple's license if asked), then choose the opened disk."
        case .notFound: return "That file doesn't contain D3DMetal. Choose the Game Porting Toolkit disk image you downloaded from Apple."
        case .notSignedByApple(let file): return "\(file) isn't signed by Apple, so Sommelier won't use it. Download the Game Porting Toolkit again from developer.apple.com."
        case .missingModule(let dll): return "This Game Porting Toolkit is missing \(dll). Download the current version from developer.apple.com."
        case .copyFailed(let reason): return "Couldn't install D3DMetal. \(reason)"
        }
    }
}

/// What was imported and when; stored as `D3DMETAL.json` (ISO 8601 date).
public struct D3DMetalInfo: Equatable, Codable, Sendable {
    public var version: String      // the framework's CFBundleShortVersionString
    public var importedAt: Date     // when the user accepted Apple's license
    /// Downloaded by Sommelier (kept current by it), rather than taken from the player's own toolkit (left alone).
    public var fromSommelier: Bool? = nil
}

/// A checked copy of D3DMetal that is not installed yet: the user still has to accept Apple's license.
public struct StagedD3DMetal: Sendable {   // returned by `D3DMetalStore.stage`
    public let directory: URL       // the hidden staging folder in Paths.home
    public let info: D3DMetalInfo   // written there as D3DMETAL.json
    public let license: URL?        // Apple's license from the toolkit (RTF or text), when one was found
}

/// Installs Apple's D3DMetal (Direct3D 12 on Metal) into `Paths.d3dMetal`.
///
/// Apple's license lets D3DMetal be passed on unchanged for non-commercial use, so Sommelier (free) offers it from
/// its own service (`EngineManifest.d3dMetal`, `install`); a player may instead take it from their own Game Porting
/// Toolkit download (`stage`, `commit`). Either way the copy is checked for Apple's code signature and kept apart
/// from the engines; from there it is linked into each engine built for it, so engine updates keep working with
/// DirectX 12.
public struct D3DMetalStore: Sendable {   // one per Sommelier home
    /// D3DMetal's Windows-side modules. Everything else in Direct3D stays Wine's.
    /// `d3d12core` comes with D3DMetal from Game Porting Toolkit 4 (before, Wine's own served D3DMetal's d3d12).
    static let modules = ["d3d10", "d3d11", "d3d12", "d3d12core", "dxgi"] + ["atidxx64", "nvapi64", "nvngx", "nvngx-on-metalfx"]
    /// Apple's DLSS-to-MetalFX module, which games look for as `nvngx` (Apple's read-me: rename it). It only acts
    /// with `D3DM_ENABLE_METALFX=1`; without it, DLSS just isn't offered.
    static let metalFXModule = "nvngx-on-metalfx", dlssModule = "nvngx"
    /// Raised when `link` lays an engine out differently, so engines linked before are linked again.
    static let layout = 2
    /// Modules a toolkit must have to be usable.
    static let requiredModules = ["d3d11", "d3d12", "dxgi"]
    /// Written into an engine's `lib/external` with the linked version, so linking again is skipped.
    static let marker = ".sommelier-d3dmetal"

    /// Apple's download page for the toolkit (needs a free Apple Account).
    public static let downloadPage: URL = {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "developer.apple.com"
        parts.path = "/download/all/"
        parts.queryItems = [URLQueryItem(name: "q", value: "game porting toolkit")]
        guard let url = parts.url else { preconditionFailure("invalid download page URL") }
        return url
    }()

    /// The toolkit's disk image itself. Opened in the browser: a signed-in player gets the download at once, anyone
    /// else signs in on Apple's own page first and is sent back to it. Sommelier never sees the Apple Account.
    public static let directDownload = URL(string:
        "https://developer.apple.com/services-account/download?path=/Developer_Tools/Game_Porting_Toolkit_4.0_beta_1/Game_Porting_Toolkit_4.0_beta_3.dmg")!

    /// The current link from the service (`GET /v1/toolkit.json`), so a new toolkit needs no app update; the
    /// built-in one when the service can't be reached. Only a disk image in Apple's Developer_Tools is taken.
    /// The link for this Mac: the newest toolkit on macOS 27 and later, the stable one below.
    public static func currentDownload(session: URLSession = .shared,
                                       macOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) async -> URL {
        let old = macOSMajor < 27
        let base = ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:)) ?? CompatibilityReporter.defaultURL
        var request = URLRequest(url: base.appendingPathComponent("v1/toolkit.json"))
        request.timeoutInterval = 5
        struct Answer: Decodable { let version: Int; let download: String; let legacy: String? }
        let builtIn = old ? legacyDirectDownload : directDownload
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.version == 1,
              let url = URL(string: old ? (answer.legacy ?? answer.download) : answer.download), isAppleDownload(url) else { return builtIn }
        return url
    }

    static func isAppleDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "developer.apple.com"
            && url.absoluteString.hasPrefix("https://developer.apple.com/services-account/download?path=/Developer_Tools/")
            && url.absoluteString.hasSuffix(".dmg") && !url.absoluteString.contains("..")
    }

    /// The stable toolkit (GPTK 3.0) for macOS below 27, where the GPTK 4 beta has no Metal 4 and hangs games (its
    /// ray tracing pipelines crash).
    public static let legacyDirectDownload = URL(string:
        "https://developer.apple.com/services-account/download?path=/Developer_Tools/Game_Porting_Toolkit_3.0/Game_Porting_Toolkit_3.0.dmg")!

    /// Whether a file or volume name looks like Apple's toolkit ("Game_Porting_Toolkit_3.0.dmg", or the
    /// "Evaluation environment for Windows games" disk inside it). Similar names such as Porting Kit don't
    /// match. A match is only a hint; the signature check decides.
    public static func isToolkitName(_ name: String) -> Bool {
        let words = name.lowercased().map { $0 == "_" || $0 == "-" ? " " : String($0) }.joined()
        return ["game porting toolkit", "evaluation environment for windows games"].contains { words.contains($0) }
    }

    public let paths: Paths   // the Sommelier home it imports into
    public init(paths home: Paths) { paths = home }

    /// The imported copy (`Paths.d3dMetal`).
    var importFolder: URL { paths.d3dMetal }
    var infoFile: URL { importFolder.appendingPathComponent("D3DMETAL.json", isDirectory: false) }

    /// The imported D3DMetal, if there is a complete one.
    public var installed: D3DMetalInfo? {   // read fresh on every call
        let bridge = importFolder.appendingPathComponent("external/libd3dshared.dylib")
        guard FileManager.default.fileExists(atPath: bridge.path),
              let data = try? Data(contentsOf: infoFile) else { return nil }
        return try? Self.decoder.decode(D3DMetalInfo.self, from: data)
    }

    /// Apple's license as copied with the import.
    public var licenseFile: URL? {  // nil when the toolkit shipped none
        for name in ["LICENSE.rtf", "LICENSE.txt"] {
            let candidate = importFolder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: Importing

    /// Copies and checks D3DMetal from `source` into a staging folder; nothing changes until `commit`.
    /// `source` may be Apple's `.dmg`, the opened toolkit disk, or a folder inside it.
    public func stage(from input: URL) async throws -> StagedD3DMetal {
        try fileSystem.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let staging = paths.home.appendingPathComponent(".d3dmetal-" + UUID().uuidString, isDirectory: true)
        do {
            return try await stageAny(input, into: staging)
        } catch {
            try? fileSystem.removeItem(at: staging)
            throw error
        }
    }

    private func stageAny(_ input: URL, into staging: URL) async throws -> StagedD3DMetal {
        if Self.isDiskImage(input) {
            return try await stageImage(input, into: staging, depth: 1)
        }
        do {
            return try extract(from: input, into: staging)
        } catch D3DMetalError.notFound {
            // The user opened Apple's outer disk and picked it; D3DMetal lives in the image inside.
            if let inner = Self.nestedImage(in: input) { return try await stageImage(inner, into: staging, depth: 0) }
            throw D3DMetalError.notFound
        }
    }

    private static func isDiskImage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "dmg" }

    /// Stages from a disk image. Since Game Porting Toolkit 3.0 Apple's download is an image that contains a
    /// second one ("Evaluation environment for Windows games") holding D3DMetal; `depth` is how many such
    /// levels may still be opened.
    private func stageImage(_ image: URL, into staging: URL, depth: Int) async throws -> StagedD3DMetal {
        let mountPoint = try await Self.attach(image)
        let outcome: Result<StagedD3DMetal, Error>
        do {
            outcome = .success(try extract(from: mountPoint, into: staging))
        } catch D3DMetalError.notFound where depth > 0 {
            if let inner = Self.nestedImage(in: mountPoint) {
                do { outcome = .success(try await stageImage(inner, into: staging, depth: depth - 1)) }
                catch { outcome = .failure(error) }
            } else {
                outcome = .failure(D3DMetalError.notFound)
            }
        } catch {
            outcome = .failure(error)
        }
        await Self.detach(mountPoint)
        return try outcome.get()
    }

    /// The disk image at the top of `folder`, preferring Apple's evaluation environment; nil when there is none.
    static func nestedImage(in disk: URL) -> URL? {
        let items = (try? fileSystem.contentsOfDirectory(at: disk, includingPropertiesForKeys: nil)) ?? []
        let images = items.filter(isDiskImage).sorted { $0.lastPathComponent.compare($1.lastPathComponent) == .orderedAscending }
        let evaluation = images.first { $0.lastPathComponent.localizedCaseInsensitiveContains("evaluation") }
        return evaluation ?? images.first
    }

    /// Installs a staged import (the user accepted Apple's license), replacing any earlier one, and links it
    /// into `engines`. A failed move puts the earlier import back.
    public func commit(_ staged: StagedD3DMetal, engines targets: [Engine]) throws {
        let fm = fileSystem
        let previous = paths.home.appendingPathComponent(".d3dmetal-old-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fm.fileExists(atPath: importFolder.path)
        if hadPrevious { try fm.moveItem(at: importFolder, to: previous) }
        do {
            try fm.moveItem(at: staged.directory, to: importFolder)
        } catch {
            if hadPrevious { try? fm.moveItem(at: previous, to: importFolder) }
            throw D3DMetalError.copyFailed((error as NSError).localizedDescription)
        }
        if hadPrevious { try? fm.removeItem(at: previous) }
        try targets.forEach(link(into:))
    }

    /// Downloads Sommelier's copy of D3DMetal, checks the archive against the signed engine list and the files in it
    /// for Apple's signature, installs it in place of any earlier one and links it into `engines`.
    @discardableResult public func install(_ wanted: EngineManifest.D3DMetalEntry, engines targets: [Engine],
                                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> D3DMetalInfo {
        let fm = fileSystem
        try fm.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let scratch = paths.home.appendingPathComponent(".d3dmetal-download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let manager = EngineManager(paths: paths)
        let archive = scratch.appendingPathComponent("d3dmetal.tar.xz")
        try await manager.download(wanted.url, to: archive, onProgress: progress)
        try EngineManager.verify(archive, size: wanted.size, sha256: wanted.sha256)
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try await manager.unpack(archive, into: unpacked)
        var staged = try await stage(from: unpacked)
        staged = StagedD3DMetal(directory: staged.directory, info: D3DMetalInfo(version: staged.info.version,
                                importedAt: Date(), fromSommelier: true), license: staged.license)
        try Self.encoder.encode(staged.info).write(to: staged.directory.appendingPathComponent("D3DMETAL.json"))
        do { try commit(staged, engines: targets) } catch { discard(staged); throw error }
        return staged.info
    }

    /// Deletes a staged import the user declined.
    public func discard(_ declined: StagedD3DMetal) {
        try? fileSystem.removeItem(at: declined.directory)
    }

    // MARK: Engines

    /// Whether `engine` was built to run D3DMetal (the CrossOver-source engines).
    public static func canUse(_ candidate: Engine) -> Bool {
        candidate.info.backends.contains(GraphicsBackend.d3dMetal.rawValue)
    }

    /// Copies the imported D3DMetal into `engine` unless that version is already there. On APFS the copies are
    /// clones, so each engine costs next to no disk space. Wine's own DLLs are stashed first for `WineD3DFallback`.
    public func link(into target: Engine) throws {
        guard let info = installed, Self.canUse(target) else { return }
        let fm = fileSystem
        let engineLib = target.wineRoot.appendingPathComponent("lib")
        let external = engineLib.appendingPathComponent("external")
        let stamp = external.appendingPathComponent(Self.marker)
        let linked = "\(info.version) layout \(Self.layout)"
        if (try? String(contentsOf: stamp, encoding: .utf8)) == linked { return }

        do {
            // Build the new folder beside the old one, then swap.
            let incoming = engineLib.appendingPathComponent("external.new")
            try? fm.removeItem(at: incoming)
            try fm.copyItem(at: importFolder.appendingPathComponent("external"), to: incoming)
            if fm.fileExists(atPath: external.path) { try fm.removeItem(at: external) }
            try fm.moveItem(at: incoming, to: external)

            // Wine's own Direct3D is saved before D3DMetal's DLLs overwrite it.
            try WineD3DFallback.stashOriginals(of: target)
            let windowsSide = engineLib.appendingPathComponent("wine/x86_64-windows")
            let unixSide = engineLib.appendingPathComponent("wine/x86_64-unix")
            let imported = importFolder.appendingPathComponent("x86_64-windows")
            for name in Self.modules {
                var source = imported.appendingPathComponent("\(name).dll")
                if name == Self.dlssModule, !fm.fileExists(atPath: source.path) {
                    source = imported.appendingPathComponent("\(Self.metalFXModule).dll")
                }
                guard fm.fileExists(atPath: source.path) else { continue }
                try Self.replace(windowsSide.appendingPathComponent("\(name).dll"), withCopyOf: source)
                // The DLL's unix half is libd3dshared, which forwards to Metal.
                let unixHalf = unixSide.appendingPathComponent("\(name).so")
                try? fm.removeItem(at: unixHalf)
                try fm.createSymbolicLink(atPath: unixHalf.path, withDestinationPath: "../../external/libd3dshared.dylib")
            }
            try linked.write(to: stamp, atomically: true, encoding: .utf8)
        } catch {
            throw D3DMetalError.copyFailed((error as NSError).localizedDescription)
        }
    }

    // MARK: Copying and checking

    /// Copies D3DMetal from wherever it sits under `source` into `staging` and verifies the copy.
    private func extract(from source: URL, into staging: URL) throws -> StagedD3DMetal {
        let fm = fileSystem
        guard let lib = Self.locate(in: source) else { throw D3DMetalError.notFound }
        let dlls = lib.appendingPathComponent("wine/x86_64-windows")
        if let missing = Self.requiredModules.first(where: { !fm.fileExists(atPath: dlls.appendingPathComponent("\($0).dll").path) }) {
            throw D3DMetalError.missingModule("\(missing).dll")
        }

        let stagedDLLs = staging.appendingPathComponent("x86_64-windows")
        do {
            try fm.createDirectory(at: stagedDLLs, withIntermediateDirectories: true)
            try fm.copyItem(at: lib.appendingPathComponent("external"), to: staging.appendingPathComponent("external"))
            for file in Self.modules.map({ "\($0).dll" }) where fm.fileExists(atPath: dlls.appendingPathComponent(file).path) {
                try fm.copyItem(at: dlls.appendingPathComponent(file), to: stagedDLLs.appendingPathComponent(file))
            }
        } catch {
            throw D3DMetalError.copyFailed((error as NSError).localizedDescription)
        }

        // Verify what was copied, since those are the bytes that will run, not the source.
        let stagedExternal = staging.appendingPathComponent("external")
        let framework = stagedExternal.appendingPathComponent("D3DMetal.framework")
        let bridge = stagedExternal.appendingPathComponent("libd3dshared.dylib")
        if let unsigned = [framework, bridge].first(where: { !Self.isSignedByApple($0) }) {
            throw D3DMetalError.notSignedByApple(unsigned.lastPathComponent)
        }
        // Files copied off a downloaded image are quarantined; Apple's signature was just checked instead.
        Self.clearQuarantine(staging)

        let copiedLicense = Self.findLicense(near: lib, within: source).flatMap { shipped -> URL? in
            let name = shipped.pathExtension.lowercased() == "rtf" ? "LICENSE.rtf" : "LICENSE.txt"
            let copy = staging.appendingPathComponent(name)
            return (try? fm.copyItem(at: shipped, to: copy)) == nil ? nil : copy
        }
        // Apple's notices for the open-source parts go along with its license.
        var folder = lib
        while folder.path.hasPrefix(source.path), folder != folder.deletingLastPathComponent() {
            let notices = folder.appendingPathComponent("Acknowledgements.rtf")
            if fm.fileExists(atPath: notices.path) {
                try? fm.copyItem(at: notices, to: staging.appendingPathComponent("Acknowledgements.rtf"))
                break
            }
            folder = folder.deletingLastPathComponent()
        }
        let info = D3DMetalInfo(version: Self.version(of: framework), importedAt: Date())
        try Self.encoder.encode(info).write(to: staging.appendingPathComponent("D3DMETAL.json"))
        return StagedD3DMetal(directory: staging, info: info, license: copiedLicense)
    }

    /// The `lib` folder containing D3DMetal (`external/libd3dshared.dylib` and `external/D3DMetal.framework`):
    /// `source` itself, `source/lib`, or a `lib` folder up to six levels down (Apple's disk has `redist/lib`).
    /// Symbolic links and framework bundles are not searched.
    static func locate(in searchRoot: URL) -> URL? {
        let fm = fileSystem
        func holdsD3DMetal(_ folder: URL) -> Bool {
            let external = folder.appendingPathComponent("external")
            return fm.fileExists(atPath: external.appendingPathComponent("libd3dshared.dylib").path)
                && fm.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path)
        }
        for direct in [searchRoot, searchRoot.appendingPathComponent("lib")] where holdsD3DMetal(direct) { return direct }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walk = fm.enumerator(at: searchRoot, includingPropertiesForKeys: keys) else { return nil }
        while let item = walk.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if item.lastPathComponent == "lib" && holdsD3DMetal(item) { return item }
            if item.pathExtension == "framework" || walk.level >= 6 { walk.skipDescendants() }
        }
        return nil
    }

    /// Apple's license text: a License/LICENSE file in `lib` or any folder above it that is still inside `source`
    /// (Apple's `License.rtf` sits at the top of the toolkit's disk), else the one inside the framework (in recent
    /// toolkits that is only xxHash's notice).
    private static func findLicense(near lib: URL, within source: URL) -> URL? {
        let resources = lib.appendingPathComponent("external/D3DMetal.framework/Versions/A/Resources")
        var candidates: [URL] = []
        var folder = lib
        while folder.path.hasPrefix(source.path) {
            for ext in ["rtf", "txt"] {
                for stem in ["License", "LICENSE"] { candidates.append(folder.appendingPathComponent("\(stem).\(ext)")) }
            }
            candidates.append(folder.appendingPathComponent("LICENSE"))
            let up = folder.deletingLastPathComponent()
            if up == folder { break }
            folder = up
        }
        candidates.append(resources.appendingPathComponent("LICENSE"))
        return candidates.first { fileSystem.fileExists(atPath: $0.path) }
    }

    /// The framework's marketing version, else its build version, else "unknown".
    private static func version(of framework: URL) -> String {
        let info = Bundle(url: framework)?.infoDictionary ?? [:]
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = info[key] as? String { return value }
        }
        return "unknown"
    }

    private static func replace(_ target: URL, withCopyOf source: URL) throws {
        try? fileSystem.removeItem(at: target)
        try fileSystem.copyItem(at: source, to: target)
    }

    /// True only for code signed by Apple itself (a Developer ID from anyone else fails), checked strictly,
    /// for every architecture and including nested code.
    static func isSignedByApple(_ item: URL) -> Bool {
        var staticCode: SecStaticCode?
        var appleAnchor: SecRequirement?
        guard SecStaticCodeCreateWithPath(item as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &appleAnchor) == errSecSuccess,
              let staticCode, let appleAnchor else { return false }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidityWithErrors(staticCode, strict, appleAnchor, nil) == errSecSuccess
    }

    private static func clearQuarantine(_ folder: URL) {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/xattr", isDirectory: false)
        tool.arguments = ["-dr", "com.apple.quarantine", folder.path]
        do {
            try tool.run()
            tool.waitUntilExit()
        } catch {
            // Not fatal: quarantined copies only make Gatekeeper ask once more.
        }
    }

    // MARK: Disk images

    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    /// Mounts `image` read-only at a private mount point, without showing it in Finder.
    static func attach(_ diskImage: URL) async throws -> URL {
        let point = fileSystem.temporaryDirectory.appendingPathComponent("sommelier-gptk-" + UUID().uuidString)
        try fileSystem.createDirectory(at: point, withIntermediateDirectories: true)
        let arguments = ["attach", diskImage.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", point.path]
        if (try? await ProcessRunner.run(hdiutil, arguments))?.succeeded == true { return point }
        try? fileSystem.removeItem(at: point)
        throw D3DMetalError.couldNotOpen   // usually Apple's license on the image not yet accepted
    }

    /// Unmounts (forcing it if a plain detach fails) and removes the mount point.
    static func detach(_ point: URL) async {
        for extra in [[], ["-force"]] {
            let result = try? await ProcessRunner.run(hdiutil, ["detach", point.path] + extra)
            if result?.succeeded == true { break }
        }
        try? fileSystem.removeItem(at: point)
    }

    // MARK: Coding

    private static var encoder: JSONEncoder {   // ISO 8601 dates, as D3DMETAL.json has always used
        let coder = JSONEncoder()
        coder.dateEncodingStrategy = .iso8601
        return coder
    }

    private static var decoder: JSONDecoder {   // matches `encoder`
        let coder = JSONDecoder()
        coder.dateDecodingStrategy = .iso8601
        return coder
    }
}

/// Shorthand for the default file manager (not stored: `FileManager` isn't `Sendable`).
private var fileSystem: FileManager { FileManager.default }
