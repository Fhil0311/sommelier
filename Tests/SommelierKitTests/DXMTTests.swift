// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// An engine with (or without) DXMT laid out in `lib/dxmt` like the 2.x build puts it.
private func makeDXMTEngine(_ root: URL, dxmt: Bool) throws -> Engine {
    let engine = try makeTestEngine(root, version: "2.1.0", backends: ["d3dMetal", "dxmt"], d3dMetal: true)
    if dxmt {
        for arch in ["x86_64-windows", "i386-windows"] {
            let dir = engine.wineRoot.appendingPathComponent("lib/dxmt/\(arch)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("winemetal \(arch)".utf8).write(to: dir.appendingPathComponent("winemetal.dll"))
        }
    }
    return engine
}

@Suite struct DXMTTests {
    let paths = Paths(home: URL(fileURLWithPath: "/tmp/somm-dxmt"))
    var bottle: Bottle { Bottle(kind: .steam, paths: paths) }

    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)") }

    @Test func dxmtPrependsItsFolderAndLoadsBuiltinsOnly() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDXMTEngine(root, dxmt: true)
        var p = LaunchProfile()
        p.backend = .dxmt
        let env = WineRunner.environment(bottle: bottle, profile: p, engine: engine, base: [:])
        #expect(env["SOMMELIER_DLL_PREPEND"] == engine.wineRoot.appendingPathComponent("lib/dxmt").path)
        // Builtin only, so Wine's native copies that WineD3DFallback leaves in System32 are never picked.
        #expect(env["WINEDLLOVERRIDES"] == "mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core=b")
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == nil)
    }

    @Test func otherBackendsOnTheSameEngineKeepTheEnginesDirect3D() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDXMTEngine(root, dxmt: true)
        for backend in [GraphicsBackend.d3dMetal, .wined3d, .auto] {
            var p = LaunchProfile()
            p.backend = backend
            #expect(WineRunner.environment(bottle: bottle, profile: p, engine: engine, base: [:])["SOMMELIER_DLL_PREPEND"] == nil)
        }
    }

    @Test func engineWithoutDXMTFilesDoesNotOfferIt() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDXMTEngine(root, dxmt: false)          // listed in ENGINE.json, files missing
        #expect(engine.dxmtRoot == nil)
        #expect(!engine.supports(.dxmt))
        var p = LaunchProfile()
        p.backend = .dxmt
        #expect(WineRunner.environment(bottle: bottle, profile: p, engine: engine, base: [:])["SOMMELIER_DLL_PREPEND"] == nil)

        let withFiles = try makeDXMTEngine(temp(), dxmt: true)
        defer { try? FileManager.default.removeItem(at: withFiles.directory.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(withFiles.supports(.dxmt))
    }

    @Test func installsWinemetalStubsIntoBothSystemFolders() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDXMTEngine(root, dxmt: true)
        let bottle = Bottle(kind: .steam, paths: Paths(home: root))
        let windows = bottle.driveC.appendingPathComponent("windows")
        for folder in ["system32", "syswow64"] {
            try FileManager.default.createDirectory(at: windows.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let dxmt = try #require(engine.dxmtRoot)
        try DXMTSetup.installStubs(from: dxmt, into: bottle)
        #expect(FileManager.default.contents(atPath: windows.appendingPathComponent("system32/winemetal.dll").path) == Data("winemetal x86_64-windows".utf8))
        #expect(FileManager.default.contents(atPath: windows.appendingPathComponent("syswow64/winemetal.dll").path) == Data("winemetal i386-windows".utf8))
        try DXMTSetup.installStubs(from: dxmt, into: bottle)       // second run: nothing to do, no error
    }

    @Test func skipsBottlesWithoutAWindowsFolder() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try makeDXMTEngine(root, dxmt: true)
        let bottle = Bottle(kind: .epic, paths: Paths(home: root))
        try DXMTSetup.installStubs(from: try #require(engine.dxmtRoot), into: bottle)
        #expect(!FileManager.default.fileExists(atPath: bottle.driveC.path))
    }
}
