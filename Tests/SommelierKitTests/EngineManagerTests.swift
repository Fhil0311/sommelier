// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit
import Testing
@testable import SommelierKit

/// A temporary Sommelier home plus a place to build engine archives in.
private final class InstallSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-engines-\(UUID().uuidString)")
    var paths: Paths { Paths(home: root.appendingPathComponent("home")) }
    var manager: EngineManager { EngineManager(paths: paths) }

    init() throws { try makeFolder(root) }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// Packs a pretend engine (`wine` is a shell script exiting with `wineStatus`) as a real `.tar.xz`.
    func archive(version: String, wineStatus: Int = 0, includeManifest: Bool = true) throws -> URL {
        let files = FileManager.default
        let tree = root.appendingPathComponent("tree-\(UUID().uuidString)")
        let bin = tree.appendingPathComponent("wine/bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try "#!/bin/sh\necho wine-test\nexit \(wineStatus)\n".write(to: wine, atomically: true, encoding: .utf8)
        try markExecutable(wine)
        if includeManifest {
            let json = "{\"version\":\"\(version)\",\"wineVersion\":\"test\",\"backends\":[\"dxvk\"],\"minMacOS\":\"14.0\"}"
            try json.write(to: tree.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        }
        let output = root.appendingPathComponent("sommelier-engine-\(version)-\(UUID().uuidString).tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", output.path, "-C", tree.path, "."]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return output
    }

    /// A manifest entry for `archive`, with its real digest and size unless overridden.
    func entry(_ archive: URL, version: String, digest: String? = nil, size: Int64? = nil) throws -> EngineManifest.Entry {
        let bytes = try Data(contentsOf: archive)
        let realDigest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return EngineManifest.Entry(version: version, url: archive, sha256: digest ?? realDigest,
                                    size: size ?? Int64(bytes.count), minAppVersion: nil, backends: ["dxvk"])
    }

    var installedVersions: [String] { EngineLocator(paths: paths).installed().map(\.version) }
}

/// Collects the phases an install reports, without repeats.
private final class PhaseRecorder: @unchecked Sendable {
    private let guardLock = NSLock()
    private var phases: [EnginePhase] = []
    func record(_ phase: EnginePhase) {
        guardLock.withLock { if phases.last != phase { phases.append(phase) } }
    }
    var recorded: [EnginePhase] { guardLock.withLock { phases } }
}

@Suite struct EngineInstallTests {
    @Test func installsAnEngineThatPassesEveryCheck() async throws {
        let sandbox = try InstallSandbox()
        let recorder = PhaseRecorder()
        let entry = try sandbox.entry(try sandbox.archive(version: "1.2.0"), version: "1.2.0")
        let engine = try await sandbox.manager.install(entry) { phase, _ in recorder.record(phase) }

        #expect(engine.version == "1.2.0" && engine.isUsable)
        #expect(sandbox.installedVersions == ["1.2.0"])
        #expect(recorder.recorded == [.downloading, .verifying, .extracting, .finishing])
        let scratch = try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.engines.path)
            .filter { $0.hasPrefix(".install-") }
        #expect(scratch.isEmpty)
    }

    @Test func uppercaseDigestInTheManifestIsAccepted() async throws {
        let sandbox = try InstallSandbox()
        var entry = try sandbox.entry(try sandbox.archive(version: "1.0.0"), version: "1.0.0")
        entry.sha256 = entry.sha256.uppercased()
        _ = try await sandbox.manager.install(entry)
        #expect(sandbox.installedVersions == ["1.0.0"])
    }

    @Test func wrongDigestIsRejected() async throws {
        let sandbox = try InstallSandbox()
        let entry = try sandbox.entry(try sandbox.archive(version: "1.0.0"), version: "1.0.0",
                                      digest: String(repeating: "ab", count: 32))
        await #expect(throws: EngineError.checksumMismatch) { _ = try await sandbox.manager.install(entry) }
        #expect(sandbox.installedVersions.isEmpty)
    }

    @Test func wrongSizeIsRejected() async throws {
        let sandbox = try InstallSandbox()
        let entry = try sandbox.entry(try sandbox.archive(version: "1.0.0"), version: "1.0.0", size: 7)
        await #expect(throws: EngineError.sizeMismatch) { _ = try await sandbox.manager.install(entry) }
    }

    @Test func archiveWithoutEngineManifestIsInvalid() async throws {
        let sandbox = try InstallSandbox()
        let entry = try sandbox.entry(try sandbox.archive(version: "1.0.0", includeManifest: false), version: "1.0.0")
        await #expect(throws: EngineError.invalidEngine) { _ = try await sandbox.manager.install(entry) }
    }

    @Test func archiveForAnotherVersionIsInvalid() async throws {
        let sandbox = try InstallSandbox()
        let entry = try sandbox.entry(try sandbox.archive(version: "3.0.0"), version: "1.0.0")
        await #expect(throws: EngineError.invalidEngine) { _ = try await sandbox.manager.install(entry) }
    }

    @Test func brokenReplacementLeavesTheWorkingCopyInPlace() async throws {
        let sandbox = try InstallSandbox()
        _ = try await sandbox.manager.install(try sandbox.entry(try sandbox.archive(version: "1.0.0"), version: "1.0.0"))
        let broken = try sandbox.entry(try sandbox.archive(version: "1.0.0", wineStatus: 3), version: "1.0.0")
        await #expect(throws: EngineError.sanityCheckFailed) { _ = try await sandbox.manager.install(broken) }
        #expect(sandbox.installedVersions == ["1.0.0"])
        let engine = try #require(EngineLocator(paths: sandbox.paths).installed().first)
        let check = try await ProcessRunner.run(engine.wine, ["--version"])
        #expect(check.succeeded)
    }

    @Test func unreachableArchiveIsADownloadError() async throws {
        let sandbox = try InstallSandbox()
        let missing = EngineManifest.Entry(version: "1.0.0", url: sandbox.root.appendingPathComponent("absent.tar.xz"),
                                           sha256: "00", size: 0, minAppVersion: nil, backends: nil)
        await #expect(throws: EngineError.self) { _ = try await sandbox.manager.install(missing) }
        #expect(sandbox.installedVersions.isEmpty)
    }

    @Test func removeDeletesOneVersion() async throws {
        let sandbox = try InstallSandbox()
        for version in ["1.0.0", "1.1.0"] {
            _ = try await sandbox.manager.install(try sandbox.entry(try sandbox.archive(version: version), version: version))
        }
        try sandbox.manager.remove(version: "1.0.0")
        #expect(sandbox.installedVersions == ["1.1.0"])
    }

    @Test func digestMatchesAKnownValue() throws {
        let sandbox = try InstallSandbox()
        let file = sandbox.root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        #expect(try EngineManager.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct EngineManifestTests {
    @Test func decodesEntriesAndServerSettings() throws {
        let json = #"""
        {"engines":[{"version":"1.9.0","url":"https://example.com/a.tar.xz","sha256":"aa","size":1},
                    {"version":"1.10.0","url":"https://example.com/b.tar.xz","sha256":"bb","size":2,"backends":["dxvk"]}],
         "steamArgs":["-one","-two"],"knownIssues":{"steam:10":"Needs a launcher"}}
        """#
        let manifest = try EngineManifest.decode(Data(json.utf8))
        #expect(manifest.engines.count == 2)
        #expect(manifest.latest?.version == "1.10.0")   // numeric, not alphabetical
        #expect(manifest.steamArgs == ["-one", "-two"])
        #expect(manifest.knownIssues == ["steam:10": "Needs a launcher"])
        #expect(manifest.engines[0].backends == nil)
    }

    @Test func d3dMetalForEachMacOS() throws {
        let json = #"""
        {"engines":[],
         "d3dMetal":[{"version":"4.0b3","url":"https://x/4","sha256":"a","size":1,"minMacOS":27},
                     {"version":"3.0","url":"https://x/3","sha256":"b","size":1},
                     {"version":"2.1","url":"https://x/2","sha256":"c","size":1}]}
        """#
        let manifest = try EngineManifest.decode(Data(json.utf8))
        #expect(manifest.d3dMetal(forMacOS: 26)?.version == "3.0")       // the newest of those for any macOS
        #expect(manifest.d3dMetal(forMacOS: 27)?.version == "4.0b3")
        #expect(manifest.d3dMetal(forMacOS: 28)?.version == "4.0b3")
        #expect(try EngineManifest.decode(Data(#"{"engines":[]}"#.utf8)).d3dMetal(forMacOS: 27) == nil)
    }

    @Test func missingEngineListDoesNotDecode() throws {
        #expect(throws: DecodingError.self) { _ = try EngineManifest.decode(Data(#"{"steamArgs":[]}"#.utf8)) }
        #expect(try EngineManifest.decode(Data(#"{"engines":[]}"#.utf8)).latest == nil)
    }

    @Test func newestEngineForEachBackend() throws {
        let json = #"""
        {"engines":[{"version":"1.0.0","url":"https://x/1","sha256":"a","size":1,"backends":["dxvk"]},
                    {"version":"2.0.0","url":"https://x/2","sha256":"b","size":1,"backends":["d3dMetal","dxmt"]},
                    {"version":"1.2.0","url":"https://x/3","sha256":"c","size":1,"backends":["dxvk"]},
                    {"version":"9.0.0","url":"https://x/4","sha256":"d","size":1}]}
        """#
        let manifest = try EngineManifest.decode(Data(json.utf8))
        #expect(manifest.latest?.version == "9.0.0")
        #expect(manifest.latest(supporting: .dxvk)?.version == "1.2.0")
        #expect(manifest.latest(supporting: .d3dMetal)?.version == "2.0.0")
        #expect(manifest.latest(supporting: .dxmt)?.version == "2.0.0")
        #expect(manifest.latest(supporting: .wined3d) == nil)
    }
}

@Suite struct EngineLocatorTests {
    /// Installs pretend engines directly into `Engines/<version>`.
    private func home(with engines: [(version: String, backends: [String])]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-locator-\(UUID().uuidString)")
        for spec in engines {
            let folder = home.appendingPathComponent("Engines/\(spec.version)")
            let bin = folder.appendingPathComponent("wine/bin")
            try makeFolder(bin)
            let wine = bin.appendingPathComponent("wine")
            try "#!/bin/sh\nexit 0\n".write(to: wine, atomically: true, encoding: .utf8)
            try markExecutable(wine)
            let list = spec.backends.map { "\"\($0)\"" }.joined(separator: ",")
            try "{\"version\":\"\(spec.version)\",\"wineVersion\":\"t\",\"backends\":[\(list)],\"minMacOS\":\"14\"}"
                .write(to: folder.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        }
        return home
    }

    @Test func activeEngineWinsWhenItFits() throws {
        let root = try home(with: [("1.0.0", ["dxvk"]), ("2.0.0", ["dxvk"])])
        defer { cleanUp(root) }
        let locator = EngineLocator(paths: Paths(home: root))
        #expect(locator.installed().map(\.version) == ["2.0.0", "1.0.0"])
        #expect(locator.engine(for: .auto)?.version == "2.0.0")
        #expect(locator.engine(for: .auto, activeVersion: "1.0.0")?.version == "1.0.0")
        #expect(locator.engine(for: .dxvk, activeVersion: "1.0.0")?.version == "1.0.0", "a rollback is honoured")
        #expect(locator.engine(for: .dxvk, activeVersion: "7.7.7")?.version == "2.0.0")   // unknown setting ignored
    }

    @Test func backendTheActiveEngineLacksComesFromAnotherEngine() throws {
        let root = try home(with: [("1.0.0", ["dxvk"]), ("2.0.0", ["d3dMetal", "dxmt"])])
        defer { cleanUp(root) }
        // DXMT needs its DLL folder before the engine counts as able to run it.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Engines/2.0.0/wine/lib/dxmt/x86_64-windows"),
                                                withIntermediateDirectories: true)
        let locator = EngineLocator(paths: Paths(home: root))
        #expect(locator.engine(for: .dxmt, activeVersion: "1.0.0")?.version == "1.0.0")   // not runnable yet: fallback
        try Data().write(to: root.appendingPathComponent("Engines/2.0.0/wine/lib/dxmt/x86_64-windows/\(DXMTSetup.dll)"))
        #expect(locator.engine(for: .dxmt, activeVersion: "1.0.0")?.version == "2.0.0")
        #expect(locator.engine(for: .dxvk, activeVersion: "2.0.0")?.version == "1.0.0")
    }

    @Test func foldersWithoutARunnableWineAreIgnored() throws {
        let root = try home(with: [("1.0.0", ["dxvk"])])
        defer { cleanUp(root) }
        try makeFolder(root.appendingPathComponent("Engines/9.0.0"))
        try #"{"version":"9.0.0","wineVersion":"t","backends":[],"minMacOS":"14"}"#
            .write(to: root.appendingPathComponent("Engines/9.0.0/ENGINE.json"), atomically: true, encoding: .utf8)
        #expect(EngineLocator(paths: Paths(home: root)).installed().map(\.version) == ["1.0.0"])
    }
}

@Suite struct SettingsAndLibraryPersistenceTests {
    private func temporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-persist-\(UUID().uuidString)")
    }

    @Test func settingsFromBeforePerBottleEnginesStillLoad() throws {
        let home = temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let layout = Paths(home: home)
        try makeFolder(home)
        // A Settings.json exactly as an earlier release wrote it.
        let earlier = #"{"appliedRetina":{"steam":true},"onboardingCompleted":true,"verboseLogs":false}"#
        try earlier.write(to: layout.settingsFile, atomically: true, encoding: .utf8)
        let previous = JSONStore<AppSettings>(url: layout.settingsFile).load(default: .init())
        #expect(previous.onboardingCompleted)
        #expect(previous.appliedRetina["steam"] == true)
        #expect(previous.bottleEngines == nil, "a key the old file lacks decodes as nil")
    }

    @Test func settingsRoundTripAndACorruptFileIsKeptAside() throws {
        let home = temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let layout = Paths(home: home)
        let settingsStore = JSONStore<AppSettings>(url: layout.settingsFile)
        #expect(!settingsStore.load(default: AppSettings()).onboardingCompleted)   // no file yet

        var settings = AppSettings()
        settings.onboardingCompleted = true
        settings.activeEngineVersion = "2.0.0"
        settings.appliedRetina["epic"] = true
        try settingsStore.save(settings)
        #expect(settingsStore.load(default: AppSettings()) == settings)

        try "{ not json".write(to: layout.settingsFile, atomically: true, encoding: .utf8)
        #expect(settingsStore.load(default: AppSettings()).activeEngineVersion == nil)
        #expect(FileManager.default.fileExists(atPath: layout.settingsFile.appendingPathExtension("corrupt").path))
    }

    @Test func mergingOneStoreKeepsTheOthersAndPrunesOrphanedData() {
        let steamGame = Game(store: .steam, storeID: "7", title: "Zeta", isInstalled: true)
        let removed = Game(store: .epic, storeID: "old", title: "Gone", isInstalled: false)
        let fresh = Game(store: .epic, storeID: "new", title: "alpha", isInstalled: true)
        let merged = LibraryStore.merged(cached: [steamGame, removed], replacing: .epic, with: [fresh])
        #expect(merged.map(\.id) == ["epic:new", "steam:7"])

        var userData = ["epic:new": UserGameData(), "epic:old": UserGameData()]
        userData["epic:new"]?.playTime = 99
        let kept = LibraryStore.pruned(userData, keeping: merged)
        #expect(Array(kept.keys) == ["epic:new"])
        #expect(kept["epic:new"]?.playTime == 99)
    }

    @Test func libraryWithDatesAndProfilesRoundTrips() throws {
        let home = temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let library = LibraryStore(paths: .init(home: home))
        var played = UserGameData()
        played.lastPlayed = Date(timeIntervalSince1970: 1_790_000_000)
        played.playTime = 7200
        played.profile.backend = .d3dMetal
        played.profile.extraEnvironment = ["KEY": "value"]
        var snapshot = LibraryFile()
        snapshot.games = [Game(store: .gog, storeID: "42", title: "Answer", isInstalled: true)]
        snapshot.userData["gog:42"] = played
        library.save(snapshot)

        let reread = library.load()
        #expect(reread.games.map(\.id) == ["gog:42"])
        let restored = try #require(reread.userData["gog:42"])
        #expect(restored.lastPlayed == played.lastPlayed)
        #expect(restored.playTime == 7200)
        #expect(restored.profile.backend == .d3dMetal)
        #expect(restored.profile.extraEnvironment == ["KEY": "value"])
    }
}

private func makeFolder(_ path: URL) throws {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
}

private func markExecutable(_ file: URL) throws {
    try FileManager.default.setAttributes([FileAttributeKey.posixPermissions: 0o755], ofItemAtPath: file.path)
}

private func cleanUp(_ folder: URL) { try? FileManager.default.removeItem(at: folder) }

@Suite struct EngineUpdateTests {
    func entry(_ version: String, _ backends: [String], app: String? = nil) -> EngineManifest.Entry {
        .init(version: version, url: URL(fileURLWithPath: "/e/\(version).tar.xz"), sha256: "", size: 0, minAppVersion: app, backends: backends)
    }

    @Test func offersTheNewestDXMTEngineWhenItIsNewerThanWhatIsInstalled() {
        let list = EngineManifest(engines: [entry("2.2.1", ["d3dMetal", "dxmt"]), entry("2.2.10", ["d3dMetal", "dxmt"]), entry("3.0.0", ["dxvk"])])
        #expect(list.update(over: ["2.2.1", "2.1.0"], appVersion: "1.0")?.version == "2.2.10")
        #expect(list.update(over: ["2.2.10"], appVersion: "1.0") == nil)          // already current
        #expect(list.update(over: [], appVersion: "1.0")?.version == "2.2.10")
    }

    @Test func skipsEnginesThatNeedANewerApp() {
        let list = EngineManifest(engines: [entry("2.2.1", ["dxmt"]), entry("2.3.0", ["dxmt"], app: "1.4")])
        #expect(list.update(over: ["2.2.0"], appVersion: "1.3.9")?.version == "2.2.1")
        #expect(list.update(over: ["2.2.0"], appVersion: "1.4")?.version == "2.3.0")
        #expect(list.update(over: ["2.2.1"], appVersion: "1.3")  == nil)
    }
}
