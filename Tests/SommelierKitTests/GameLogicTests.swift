// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A file from the test bundle's `Fixtures` folder.
private func fixtureBytes(_ name: String) throws -> Data {
    try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")))
}

/// Runs `body` with a new temporary folder (not yet created) and removes it afterwards.
private func inScratchFolder<T>(_ body: (URL) throws -> T) rethrows -> T {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-\(UUID().uuidString)")
    defer { _ = try? FileManager.default.removeItem(at: folder) }
    return try body(folder)
}

private func write(_ text: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: file, atomically: true, encoding: .utf8)
}

/// An executable stand-in for `wine` in `wineRoot/bin`, and the engine's `ENGINE.json` in `folder`.
private func fakeEngineFiles(at folder: URL, wineRoot: URL, version: String, backends: [String], minMacOS: String) throws {
    let wine = wineRoot.appendingPathComponent("bin/wine")
    try write("#!/bin/sh", to: wine)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: wine.path)
    let names = backends.map { "\"\($0)\"" }.joined(separator: ",")
    let description = #"{"version":"\#(version)","wineVersion":"11","backends":[\#(names)],"minMacOS":"\#(minMacOS)"}"#
    try write(description, to: folder.appendingPathComponent("ENGINE.json"))
}

/// A fake installed engine under `<root>/Engines/<version>` (plain `wine/` layout), with Apple's D3DMetal bridge
/// library inside it when `d3dMetal` is set. Other suites use it too.
@discardableResult func makeTestEngine(_ root: URL, version: String, backends: [String], d3dMetal: Bool) throws -> Engine {
    let folder = root.appendingPathComponent("Engines/\(version)", isDirectory: true)
    let wineRoot = folder.appendingPathComponent("wine", isDirectory: true)
    try fakeEngineFiles(at: folder, wineRoot: wineRoot, version: version, backends: backends, minMacOS: "14.0")
    if d3dMetal {
        try write("", to: wineRoot.appendingPathComponent("lib/external/libd3dshared.dylib"))
    }
    return try #require(Engine(directory: folder))
}

// MARK: - Wine environment

@Suite struct WineEnvironmentTests {
    let paths = Paths(home: URL(filePath: "/tmp/m"))
    let host = ["LANG": "en_US.UTF-8", "EDITOR_PLUGIN_TOKEN": "leak", "PATH": "/usr/bin", "HOME": "/Users/x"]

    var steam: Bottle { Bottle(kind: .steam, paths: paths) }

    /// The environment for a profile changed by `configure`, starting from nothing of the host's.
    func environment(engine: Engine? = nil, _ configure: (inout LaunchProfile) -> Void = { _ in }) -> [String: String] {
        var chosen = LaunchProfile()
        configure(&chosen)
        return WineRunner.environment(bottle: steam, profile: chosen, engine: engine, base: [:])
    }

    @Test func defaultProfileSnapshot() {
        let env = WineRunner.environment(bottle: steam, profile: LaunchProfile(), base: host)
        #expect(env == [
            "HOME": "/Users/x", "PATH": "/usr/bin", "LANG": "en_US.UTF-8",
            "WINEPREFIX": "/tmp/m/Bottles/steam",
            "WINEDEBUG": "-all,err+all,+pid", "WINEESYNC": "1", "WINEMSYNC": "1", "ROSETTA_ADVERTISE_AVX": "1", "WINE_LARGE_ADDRESS_AWARE": "1", "SOMMELIER_NO_MIC": "1",
            "SOMMELIER_FRAME_STATS_DIR": #"Z:\tmp\m\Bottles\steam\FrameStats"#,
            "SOMMELIER_APP_NAMES": "/tmp/m/AppNames.tsv",
            "SOMMELIER_EXE_REDIRECTS": "/tmp/m/ExeRedirects.tsv",
            "SOMMELIER_EXE_ENV": "/tmp/m/ExeEnvironment.tsv",
            "SOMMELIER_EXE_ARGS": "/tmp/m/ExeArguments.tsv",
            "SOMMELIER_NO_TRAY": "1",
            "WINEDLLOVERRIDES": "mscoree,mshtml=;winemenubuilder.exe=d;d3d11,d3d10core=n,b",
            "DXVK_ASYNC": "1", "MVK_CONFIG_RESUME_LOST_DEVICE": "1",
        ])
    }

    @Test func onlyAllowedHostVariablesPassThrough() {
        let env = WineRunner.environment(bottle: steam, profile: LaunchProfile(), base: host)
        #expect(!env.keys.contains("EDITOR_PLUGIN_TOKEN"))
        #expect(env["LANG"] == host["LANG"])
    }

    @Test func playerChoicesAndOwnVariablesComeLast() {
        let env = environment {
            $0.performanceHUD = true
            $0.verboseLogs = true
            $0.extraEnvironment = ["DXVK_ASYNC": "0", "SOME_SETTING": "on"]
        }
        let picked = ["MTL_HUD_ENABLED", "WINEDEBUG", "DXVK_ASYNC", "SOME_SETTING"].map { env[$0] }
        #expect(picked == ["1", "err+all,warn+module,+pid", "0", "on"])
    }

    @Test func wined3dNeedsNoDXVKOverrides() {
        let env = environment { $0.backend = .wined3d }
        #expect(env["WINEDLLOVERRIDES"]?.split(separator: ";") == ["mscoree,mshtml=", "winemenubuilder.exe=d"])
        #expect(env.keys.contains("DXVK_ASYNC") == false)
    }

    @Test func callerOverridesGoAtTheEnd() {
        let env = WineRunner.environment(bottle: steam, profile: LaunchProfile(), base: [:],
                                         extraOverrides: ["winhttp=n,b"])
        #expect(env["WINEDLLOVERRIDES"].map { $0.hasSuffix(";winhttp=n,b") } == true)
    }

    @Test func d3dMetalGetsItsVariablesOnlyWhenChosen() throws {
        try inScratchFolder { root in
            let engine = try makeTestEngine(root, version: "4.2.0", backends: ["d3dMetal"], d3dMetal: true)
            let bridge = engine.wineRoot.appendingPathComponent("lib/external/libd3dshared.dylib").path

            let metal = environment(engine: engine) { $0.backend = .d3dMetal }
            #expect(metal["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == bridge)
            #expect(metal["CX_ACTIVE_GRAPHICS_BACKEND"] == "d3dmetal")
            #expect(metal["D3DM_SUPPORT_DXR"] == "1")
            // D3DMetal's DLLs are Wine builtins: no DXVK overrides, no DXVK settings.
            #expect(metal["WINEDLLOVERRIDES"]?.split(separator: ";") == ["mscoree,mshtml=", "winemenubuilder.exe=d"])
            #expect(metal.keys.contains("DXVK_ASYNC") == false)

            let dxvk = environment(engine: engine) { $0.backend = .dxvk }
            #expect(dxvk.keys.contains("CX_APPLEGPTK_LIBD3DSHARED_PATH") == false)
        }
    }
}

// MARK: - Choosing a graphics backend

@Suite struct AutoBackendTests {
    let modern = GraphicsProbe(usesDirectX12: true, has64BitExecutable: true)
    let older = GraphicsProbe(usesDirectX12: false, has64BitExecutable: true)
    /// Names D3D12CreateDevice but is a 32-bit program, which D3DMetal can't run (Overcooked's Unity player).
    let thirtyTwoBit = GraphicsProbe(usesDirectX12: true, has64BitExecutable: false)

    @Test func d3dMetalOnlyForSixtyFourBitDirectX12WhenInstalled() {
        let auto = GraphicsBackend.auto
        #expect(auto.resolved(for: modern, d3dMetalAvailable: true) == .d3dMetal)
        #expect(auto.resolved(for: modern, d3dMetalAvailable: false) == .dxvk)
        #expect(auto.resolved(for: thirtyTwoBit, d3dMetalAvailable: true) == .dxvk)
    }

    @Test func everythingElseStaysOnDXVK() {
        let unprobed = GraphicsProbe?.none
        #expect([GraphicsBackend.auto.resolved(),
                 GraphicsBackend.auto.resolved(for: older, d3dMetalAvailable: true),
                 GraphicsBackend.auto.resolved(for: unprobed, d3dMetalAvailable: true)].allSatisfy { $0 == .dxvk })
    }

    @Test func anExplicitChoiceIsKept() {
        #expect(GraphicsBackend.dxvk.resolved(for: modern, d3dMetalAvailable: true) == .dxvk)
    }
}

// MARK: - Steam libraries

@Suite struct SteamManifestTests {
    let steamapps = URL(fileURLWithPath: "/s/steamapps")

    func manifest(_ fields: String) -> String { #""AppState" { \#(fields) }"# }

    @Test func readsAnInstalledGame() throws {
        let text = String(decoding: try fixtureBytes("appmanifest_268910.acf"), as: UTF8.self)
        let cuphead = try #require(SteamLibrary.parseManifest(text, steamapps: steamapps))
        #expect((cuphead.id, cuphead.title, cuphead.sizeOnDisk) == ("steam:268910", "Cuphead", 4_044_947_883))
        #expect(cuphead.isInstalled && cuphead.installProgress == nil)
        #expect(cuphead.installPath == steamapps.appendingPathComponent("common/Cuphead"))
        #expect(cuphead.coverURL?.pathComponents.suffix(2) == ["268910", "library_600x900.jpg"])
    }

    @Test func aDownloadReportsHowFarItGot() throws {
        let text = manifest(#""appid" "77" "name" "Huge" "StateFlags" "1026" "installdir" "Huge" "BytesToDownload" "800" "BytesDownloaded" "600""#)
        let huge = try #require(SteamLibrary.parseManifest(text, steamapps: steamapps))
        #expect(!huge.isInstalled)
        #expect(huge.installProgress == 0.75)
    }

    @Test func skipsToolsRedistributablesAndJunk() {
        let skipped = [
            manifest(#""appid" "228980" "name" "Steamworks Common Redistributables" "StateFlags" "4""#),
            manifest(#""appid" "5" "name" "Proton Experimental" "StateFlags" "4""#),
            "not { a manifest",
        ]
        #expect(skipped.compactMap { SteamLibrary.parseManifest($0, steamapps: steamapps) }.isEmpty)
    }

    @Test func findsGamesInEveryLibraryFolderOfABottle() throws {
        try inScratchFolder { home in
            let prefix = Bottle(kind: .steam, paths: Paths(home: home))
            let primary = prefix.steamDirectory.appendingPathComponent("steamapps")
            let extra = prefix.driveC.appendingPathComponent("More/steamapps")
            try write(#"""
            "libraryfolders"
            {
                "0" { "path" "C:\\Program Files (x86)\\Steam" }
                "1" { "path" "C:\\More" }
                "2" { "path" "F:\\Nowhere" }
            }
            """#, to: primary.appendingPathComponent("libraryfolders.vdf"))
            try write(manifest(#""appid" "10" "name" "Zebra" "StateFlags" "4" "installdir" "Zebra""#),
                      to: primary.appendingPathComponent("appmanifest_10.acf"))
            try write(manifest(#""appid" "20" "name" "aardvark" "StateFlags" "4" "installdir" "Aardvark""#),
                      to: extra.appendingPathComponent("appmanifest_20.acf"))
            // F: doesn't exist; the other two folders are merged and sorted ignoring case.
            #expect(SteamLibrary.scan(bottle: prefix).map(\.title) == ["aardvark", "Zebra"])
        }
    }
}

@Suite struct WindowsPathTests {
    @Test func driveCMapsIntoTheBottle() {
        let prefix = Bottle(kind: .epic, paths: Paths(home: URL(fileURLWithPath: "/root")))
        #expect(prefix.unixURL(forWindowsPath: #"C:\Program Files\Epic Games"#)?.path
            == "/root/Bottles/epic/drive_c/Program Files/Epic Games")
        #expect(prefix.unixURL(forWindowsPath: #"G:\game"#) == nil)
    }

    @Test func otherLettersFollowTheirDosdevicesLink() throws {
        try inScratchFolder { home in
            let prefix = Bottle(kind: .steam, paths: Paths(home: home))
            let devices = prefix.url.appendingPathComponent("dosdevices")
            let files = FileManager.default
            try files.createDirectory(at: devices, withIntermediateDirectories: true)
            try files.createSymbolicLink(atPath: devices.appendingPathComponent("z:").path, withDestinationPath: "/")
            try files.createSymbolicLink(atPath: devices.appendingPathComponent("e:").path, withDestinationPath: "../drive_c/games")

            #expect(prefix.unixURL(forWindowsPath: #"Z:\Volumes\External\Games"#)?.path == "/Volumes/External/Games")
            let viaLink = prefix.driveC.appendingPathComponent("games/x").standardizedFileURL.path
            #expect(prefix.unixURL(forWindowsPath: #"e:\x"#)?.path == viaLink)      // lower-case letters too
            #expect(prefix.unixURL(forWindowsPath: #"Q:\x"#) == nil)                // no link for Q:
            #expect(prefix.unixURL(forWindowsPath: "Steam") == nil)                 // not a Windows path
        }
    }
}

// MARK: - Epic (Legendary)

@Suite struct LegendaryOutputTests {
    @Test func combinesTheLibraryWithWhatIsInstalled() throws {
        let games = try LegendaryParser.games(listJSON: try fixtureBytes("legendary-list.json"),
                                              installedJSON: try fixtureBytes("legendary-installed.json"))
        #expect(games.map(\.storeID) == ["Heron", "Plover", "Quail"])            // by title, ignoring case
        let first = try #require(games.first)
        #expect(!first.isInstalled && first.coverURL == nil)
        let installed = try #require(games.last)
        #expect(installed.id == "epic:Quail" && installed.isInstalled)
        #expect(installed.installPath?.path == "/Users/player/Games/Sommelier/Epic/WrenValley")
        #expect([installed.coverURL, installed.heroURL].map { $0?.lastPathComponent } == ["wren-thumb.png", "wren-wide.png"])
    }

    @Test func readsDownloadProgress() {
        let samples: [(String, Double?)] = [
            ("[DLManager] INFO: = Progress: 40.00% (400/1000), Running for 00:01:00, ETA: 00:01:30", 0.4),
            ("[DLManager] INFO: = Progress: 100.00% (9/9)", 1),
            ("[Core] INFO: Logging in...", nil),
        ]
        for (line, expected) in samples {
            #expect(LegendaryParser.progress(from: line) == expected, "\(line)")
        }
    }
}

// MARK: - Engines

@Suite struct EngineLocatorChoiceTests {
    /// An engine in either layout: Wine inside `Wine.app` or a plain `wine/` folder.
    func installEngine(in root: URL, version: String, backends: [String], appBundle: Bool) throws {
        let folder = root.appendingPathComponent("Engines/\(version)", isDirectory: true)
        let wineRoot = folder.appendingPathComponent(appBundle ? "Wine.app/Contents/Resources/wine" : "wine")
        try fakeEngineFiles(at: folder, wineRoot: wineRoot, version: version, backends: backends, minMacOS: "15.0")
    }

    @Test func ordersVersionsNumericallyAndPicksByBackend() throws {
        try inScratchFolder { home in
            try installEngine(in: home, version: "2.0.0-dxvk", backends: ["dxvk"], appBundle: true)
            try installEngine(in: home, version: "2.10.0-dxmt", backends: ["dxmt"], appBundle: false)
            let engines = EngineLocator(paths: Paths(home: home))

            #expect(engines.installed().map(\.version) == ["2.10.0-dxmt", "2.0.0-dxvk"])   // 10 is newer than 0
            let chosen = [GraphicsBackend.dxvk, .auto, .d3dMetal].map { engines.engine(for: $0)?.version }
            #expect(chosen == ["2.0.0-dxvk", "2.10.0-dxmt", "2.10.0-dxmt"])                  // no D3DMetal: newest
            let bundled = try #require(engines.engine(for: .dxvk))
            #expect(bundled.wine.pathComponents.suffix(6) == ["Wine.app", "Contents", "Resources", "wine", "bin", "wine"])
        }
    }

    @Test func d3dMetalCountsOnlyWithAppleBridgePresent() throws {
        try inScratchFolder { home in
            try makeTestEngine(home, version: "1.5.0", backends: ["dxvk"], d3dMetal: false)
            let claimsOnly = try makeTestEngine(home, version: "1.9.0", backends: ["d3dMetal"], d3dMetal: false)
            let complete = try makeTestEngine(home, version: "1.7.0", backends: ["d3dMetal"], d3dMetal: true)

            #expect((claimsOnly.supports(.d3dMetal), claimsOnly.d3dMetalLibrary == nil) == (false, true))
            #expect((complete.supports(.d3dMetal), complete.d3dMetalLibrary == nil) == (true, false))

            // The active engine stays unless the backend needs what it lacks.
            let engines = EngineLocator(paths: Paths(home: home))
            #expect(engines.engine(for: .d3dMetal, activeVersion: "1.5.0")?.version == "1.7.0")
            #expect(engines.engine(for: .dxvk, activeVersion: "1.5.0")?.version == "1.5.0")
        }
    }

    @Test func nothingInstalledMeansNoEngine() {
        let empty = EngineLocator(paths: Paths(home: URL(fileURLWithPath: "/nonexistent-sommelier")))
        #expect(empty.engine(for: .auto) == nil)
        #expect(empty.installed().isEmpty)
    }
}

// MARK: - Known issues

@Suite struct KnownIssueNoteTests {
    let fortnite = Game(store: .epic, storeID: "Fortnite", title: "Fortnite", isInstalled: true)
    let unlisted = Game(store: .gog, storeID: "42", title: "Unlisted", isInstalled: true)
    let dx12Game = Game(store: .steam, storeID: "1091500", title: "Cyberpunk 2077", isInstalled: true)

    @Test func listedNotesWithTheRemoteOnesFirst() {
        #expect(KnownIssues.note(for: fortnite).map { $0.contains("anti-cheat") } == true)
        #expect(KnownIssues.note(for: unlisted) == nil)
        #expect(KnownIssues.note(for: unlisted, remote: ["gog:42": "Install the patch first."]) == "Install the patch first.")
        #expect(KnownIssues.note(for: fortnite, remote: ["epic:Fortnite": "Replaced"]) == "Replaced")
    }

    @Test func directX12NoteWhileD3DMetalIsMissing() {
        let probe = GraphicsProbe(usesDirectX12: true, has64BitExecutable: true)
        #expect(KnownIssues.note(for: dx12Game, probe: probe) == KnownIssues.needsDirectX12Engine)
        #expect(KnownIssues.note(for: dx12Game, probe: probe, d3dMetalAvailable: true) == nil)
        #expect(KnownIssues.note(for: dx12Game, probe: GraphicsProbe()) == nil)
        #expect(KnownIssues.note(for: dx12Game) == nil)        // not probed yet
    }
}

// MARK: - Launch options typed by the player

@Suite struct LaunchOptionTextTests {
    @Test func environmentLinesKeepOnlyValidPairs() {
        let typed = """
        # a note to self
        WINE_FULLSCREEN=1
        NOT A VARIABLE
           PADDED  =  x=y
        =nothing
        HAS-DASH=1
        """
        let parsed = LaunchProfile.parseEnvironment(typed)
        #expect(parsed == ["WINE_FULLSCREEN": "1", "PADDED": "x=y"])
        #expect(LaunchProfile.parseEnvironment(LaunchProfile.formatEnvironment(parsed)) == parsed)   // round trip
    }

    @Test func argumentsSplitOnSpacesExceptInQuotes() {
        #expect(LaunchProfile.parseArguments(#"-skipintro   -profile "My Save" -dx11"#) == ["-skipintro", "-profile", "My Save", "-dx11"])
        #expect(LaunchProfile.parseArguments("\t  ") == [])
    }
}
