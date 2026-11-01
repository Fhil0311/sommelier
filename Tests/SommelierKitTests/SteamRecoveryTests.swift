// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Steam's start-up safety: when file verification may be skipped, and how the web-helper wrapper is put in place
/// (and recovered) without ever losing Valve's own helper.
@Suite("Steam recovery")
struct SteamRecoveryTests {
    /// Each test gets its own Sommelier home.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-steam-\(UUID().uuidString)")
    /// Stands in for Valve's helper: big enough to count as a real client.
    let valveHelper = Data(repeating: 0x5A, count: 700_000)
    /// Stands in for Sommelier's wrapper, recognisable by its marker.
    let ourWrapper = Data("MZ wrapper ".utf8) + ChromiumHelperWrapper.marker

    var client: SteamProvider { SteamProvider(paths: Paths(home: home)) }
    var steamFolder: URL { client.bottle.steamDirectory }
    var cefFolder: URL { steamFolder.appendingPathComponent("bin/cef/cef.win64") }
    var helperFile: URL { cefFolder.appendingPathComponent("steamwebhelper.exe") }
    var savedHelperFile: URL { cefFolder.appendingPathComponent("steamwebhelper_real.exe") }

    init() throws {
        try FileManager.default.createDirectory(at: cefFolder, withIntermediateDirectories: true)
    }

    private func removeHome() { try? FileManager.default.removeItem(at: home) }

    /// A minimal engine; with `wrapper` it ships the Steam web-helper wrapper.
    private func testEngine(wrapper: Bool = true) throws -> Engine {
        let folder = home.appendingPathComponent("engine")
        try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true, attributes: nil)
        let manifest = #"{"version":"test","wineVersion":"test","backends":["dxvk"],"minMacOS":"15.0"}"#
        try manifest.write(to: folder.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let engine = try #require(Engine(directory: folder))
        if wrapper { try ourWrapper.write(to: engine.steamWebHelperWrapper) }
        return engine
    }

    /// Lays out what a fully updated Steam client has: client library, interface, real web helper.
    private func installFullClient() throws {
        try valveHelper.write(to: helperFile)
        try Data("dll".utf8).write(to: steamFolder.appendingPathComponent("steamclient.dll"))
        try FileManager.default.createDirectory(at: steamFolder.appendingPathComponent("clientui"), withIntermediateDirectories: true)
    }

    @Test func verificationIsSkippedOnlyForACompleteClient() throws {
        defer { removeHome() }
        #expect(!client.isClientReady)                                  // bootstrapper only
        #expect(!client.arguments().contains("-noverifyfiles"))

        try installFullClient()
        #expect(client.isClientReady)
        #expect(client.arguments() == SteamProvider.defaultArguments + ["-noverifyfiles"])
        #expect(client.arguments(verifyFiles: true) == SteamProvider.defaultArguments)   // repair always verifies

        try Data("stub".utf8).write(to: helperFile)                     // a helper too small to be real
        #expect(!client.isClientReady)
        try valveHelper.write(to: savedHelperFile)                      // ...but the saved original counts
        #expect(client.isClientReady)
    }

    @Test func noCEFFolderYetMeansNothingToWrap() throws {
        defer { removeHome() }
        try FileManager.default.removeItem(at: cefFolder)
        #expect(try client.ensureWebHelperWrapper(engine: testEngine(wrapper: false)).isEmpty)
    }

    @Test func valveHelperStaysWhenTheEngineHasNoWrapper() throws {
        defer { removeHome() }
        try valveHelper.write(to: helperFile)
        let engine = try testEngine(wrapper: false)
        #expect(throws: (any Error).self) { try client.ensureWebHelperWrapper(engine: engine) }
        #expect(try Data(contentsOf: helperFile) == valveHelper)
        #expect(!FileManager.default.fileExists(atPath: savedHelperFile.path))

        try ourWrapper.write(to: engine.steamWebHelperWrapper)          // the engine gets one: wrap now
        #expect(try client.ensureWebHelperWrapper(engine: engine) == ["cef.win64"])
        #expect(try Data(contentsOf: helperFile) == ourWrapper)
        #expect(try Data(contentsOf: savedHelperFile) == valveHelper)
        #expect(try client.ensureWebHelperWrapper(engine: engine) == [])   // already done
    }

    @Test func halfFinishedSwapIsCompleted() throws {
        defer { removeHome() }
        try valveHelper.write(to: savedHelperFile)                      // moved aside, wrapper never written
        #expect(try client.ensureWebHelperWrapper(engine: testEngine()) == ["cef.win64"])
        #expect(try Data(contentsOf: helperFile) == ourWrapper)
        #expect(try Data(contentsOf: savedHelperFile) == valveHelper)
    }

    @Test func blockedBackupKeepsValveHelperRunnable() throws {
        defer { removeHome() }
        try valveHelper.write(to: helperFile)
        // A folder where the backup should go makes moving Valve's helper aside fail.
        try FileManager.default.createDirectory(at: savedHelperFile, withIntermediateDirectories: true)
        try Data("in the way".utf8).write(to: savedHelperFile.appendingPathComponent("blocker"))
        #expect(throws: (any Error).self) { try client.ensureWebHelperWrapper(engine: testEngine()) }
        #expect(try Data(contentsOf: helperFile) == valveHelper)
    }

    @Test func olderWrapperIsReplacedAndOriginalKept() throws {
        defer { removeHome() }
        try Data("previous wrapper build".utf8).write(to: helperFile)
        try valveHelper.write(to: savedHelperFile)
        #expect(try client.ensureWebHelperWrapper(engine: testEngine()) == ["cef.win64"])
        #expect(try Data(contentsOf: helperFile) == ourWrapper)
        #expect(try Data(contentsOf: savedHelperFile) == valveHelper)
    }

    @Test func gameArgumentsComeAfterTheAppID() async throws {
        defer { removeHome() }
        let engine = try testEngine()
        let files = FileManager.default
        try files.createDirectory(at: engine.wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: client.bottle.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        // A fake wine that prints each argument on its own line, plus one variable Steam's games inherit.
        let echo = "#!/bin/sh\nprintf '%s\\n' \"$@\"\necho \"sandbox=$QTWEBENGINE_DISABLE_SANDBOX\"\n"
        try echo.write(to: engine.wine, atomically: true, encoding: .utf8)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.wine.path)

        var options = LaunchProfile()
        options.extraArguments = ["-windowed", "two words"]
        let game = Game(store: .steam, storeID: "620", title: "Portal 2", isInstalled: true)
        let run = try client.play(game, engine: engine, profile: options)
        for _ in 0..<1000 where run.isRunning { try await Task.sleep(for: .milliseconds(10)) }   // up to 10 s on a busy machine
        let log = try String(contentsOf: run.logURL, encoding: .utf8)
        #expect(log.contains("-silent\n"))
        #expect(log.contains("-applaunch\n620\n-windowed\ntwo words\n"))
        #expect(log.contains("sandbox=1"))
        #expect(log.contains("engine=test"))
    }
}
