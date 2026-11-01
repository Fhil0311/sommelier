// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Bytes shaped like a PE file as far as the fallback cares: "MZ", padding up to 0x40, a 16-byte tag there
/// ("Wine builtin DLL" for Wine's builds), then a body.
private func fakeDLL(tag: String = "Wine builtin DLL", body: String = "wine d3d") -> Data {
    var bytes = Data("MZ".utf8)
    bytes.append(Data(count: 0x40 - bytes.count))
    var tagBytes = Data(tag.utf8.prefix(16))
    tagBytes.append(Data(count: 16 - tagBytes.count))
    bytes.append(tagBytes)
    bytes.append(Data(body.utf8))
    bytes.append(Data(count: 24))
    return bytes
}

/// A Sommelier home with a D3DMetal-capable engine whose `wine` only records its arguments, and a Steam bottle.
private struct FallbackSandbox {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-fallback-\(UUID().uuidString)")
    var paths: Paths { Paths(home: home) }
    var engineDir: URL { paths.engine(version: "2.0.0") }
    var wineLog: URL { home.appendingPathComponent("wine-calls.txt") }
    var system32: URL { Bottle(kind: .steam, paths: paths).driveC.appendingPathComponent("windows/system32") }
    var markerFile: URL { system32.appendingPathComponent(WineD3DFallback.marker) }

    init() throws {
        let files = FileManager.default
        let bin = engineDir.appendingPathComponent("wine/bin")
        try files.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(wineLog.path)'\n".write(to: wine, atomically: true, encoding: .utf8)
        try files.setAttributes([FileAttributeKey.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try #"{"version":"2.0.0","wineVersion":"11.0","backends":["d3dMetal"],"minMacOS":"14.0"}"#
            .write(to: engineDir.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        try files.createDirectory(at: engineDir.appendingPathComponent("wine/lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        try files.createDirectory(at: system32, withIntermediateDirectories: true)
    }

    func engine() throws -> Engine { try #require(Engine(directory: engineDir)) }

    /// Makes the engine look like D3DMetal was linked into it, or not.
    func setD3DMetalLinked(_ linked: Bool) throws {
        let bridge = engineDir.appendingPathComponent("wine/lib/external/libd3dshared.dylib")
        if linked {
            try FileManager.default.createDirectory(at: bridge.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: bridge)
        } else {
            try FileManager.default.removeItem(at: bridge)
        }
    }

    var wineCalls: [String] {
        ((try? String(contentsOf: wineLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

@Suite struct WineD3DFallbackTests {
    @Test func tellsWineBuildsFromAppleAndNativeDLLs() {
        #expect(WineD3DFallback.isWineBuild(fakeDLL()))
        #expect(!WineD3DFallback.isWineBuild(fakeDLL(body: "/Library/D3DMetalDLLsBase/dxgi.c")))   // Apple's, same tag
        #expect(!WineD3DFallback.isWineBuild(fakeDLL(tag: "")))                                    // already native
        #expect(!WineD3DFallback.isWineBuild(Data("MZ".utf8)))                                     // too short
    }

    @Test func nativeCopyZeroesOnlyTheTag() {
        let builtin = fakeDLL()
        let native = WineD3DFallback.nativeCopy(of: builtin)
        #expect(native.count == builtin.count)
        #expect(native.dropFirst(0x40).prefix(16).allSatisfy { $0 == 0 })
        #expect(native.prefix(0x40) == builtin.prefix(0x40))
        #expect(native.dropFirst(0x50) == builtin.dropFirst(0x50))
        #expect(!WineD3DFallback.isWineBuild(native), "no longer looks builtin")
    }

    @Test func stashKeepsTheFirstWineCopyOnly() throws {
        let sandbox = try FallbackSandbox(); defer { sandbox.cleanup() }
        let windows = sandbox.engineDir.appendingPathComponent("wine/lib/wine/x86_64-windows")
        for module in WineD3DFallback.modules {
            try fakeDLL(body: "wine \(module)").write(to: windows.appendingPathComponent("\(module).dll"))
        }
        let d3dEngine = try sandbox.engine()
        try WineD3DFallback.stashOriginals(of: d3dEngine)
        let saved = WineD3DFallback.stash(in: d3dEngine)
        for module in WineD3DFallback.modules {
            #expect(FileManager.default.contents(atPath: saved.appendingPathComponent("\(module).dll").path)
                    == fakeDLL(body: "wine \(module)"))
        }

        // D3DMetal has since replaced the engine's copies; the saved originals stay, and a lost one isn't
        // refilled with Apple's DLL.
        try fakeDLL(body: "D3DMetalDLLs d3d11").write(to: windows.appendingPathComponent("d3d11.dll"))
        try fakeDLL(body: "D3DMetalDLLs dxgi").write(to: windows.appendingPathComponent("dxgi.dll"))
        try FileManager.default.removeItem(at: saved.appendingPathComponent("dxgi.dll"))
        try WineD3DFallback.stashOriginals(of: d3dEngine)
        #expect(FileManager.default.contents(atPath: saved.appendingPathComponent("d3d11.dll").path) == fakeDLL(body: "wine d3d11"))
        #expect(!FileManager.default.fileExists(atPath: saved.appendingPathComponent("dxgi.dll").path), "Apple's dxgi isn't saved")
    }

    @Test func installsOnceThenRemovesWhenD3DMetalGoes() async throws {
        let sandbox = try FallbackSandbox(); defer { sandbox.cleanup() }
        try sandbox.setD3DMetalLinked(true)
        let engine = try sandbox.engine()
        let saved = WineD3DFallback.stash(in: engine)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        for module in WineD3DFallback.modules {
            try fakeDLL(body: "wine \(module)").write(to: saved.appendingPathComponent("\(module).dll"))
        }
        let fallback = WineD3DFallback(paths: sandbox.paths)

        await fallback.update(.steam, engine: engine)
        for module in WineD3DFallback.modules {
            let placed = FileManager.default.contents(atPath: sandbox.system32.appendingPathComponent("\(module).dll").path)
            #expect(placed == WineD3DFallback.nativeCopy(of: fakeDLL(body: "wine \(module)")))
        }
        #expect(try String(contentsOf: sandbox.markerFile, encoding: .utf8) == "2.0.0 r\(WineD3DFallback.revision)")
        let added = sandbox.wineCalls
        #expect(added.count == 7)
        #expect(added.allSatisfy { $0.hasPrefix(#"reg add HKCU\Software\Wine\AppDefaults\Launcher.exe\DllOverrides /v "#) })
        #expect(added.contains(#"reg add HKCU\Software\Wine\AppDefaults\Launcher.exe\DllOverrides /v d3d10core /d native,builtin /f"#))
        #expect(added.contains(#"reg add HKCU\Software\Wine\AppDefaults\Launcher.exe\DllOverrides /v d3d12 /d  /f"#))

        // Nothing changed: no registry work on the next launch.
        await fallback.update(.steam, engine: engine)
        #expect(sandbox.wineCalls.count == 7)

        // An engine without D3DMetal: our files and overrides go away.
        try sandbox.setD3DMetalLinked(false)
        await fallback.update(.steam, engine: engine)
        for module in WineD3DFallback.modules {
            #expect(!FileManager.default.fileExists(atPath: sandbox.system32.appendingPathComponent("\(module).dll").path))
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.markerFile.path))
        #expect(sandbox.wineCalls.last == #"reg delete HKCU\Software\Wine\AppDefaults\Launcher.exe\DllOverrides /f"#)
    }

    @Test func leavesSystem32AloneWithoutItsMarker() async throws {
        let sandbox = try FallbackSandbox(); defer { sandbox.cleanup() }
        let someoneElses = sandbox.system32.appendingPathComponent("dxgi.dll")
        try Data("installed by a game".utf8).write(to: someoneElses)
        await WineD3DFallback(paths: sandbox.paths).update(.steam, engine: try sandbox.engine())
        #expect(FileManager.default.contents(atPath: someoneElses.path) == Data("installed by a game".utf8))
        #expect(sandbox.wineCalls.isEmpty)
    }

    @Test func engineWithoutDXVKGetsNoDXVKOverrides() throws {
        let sandbox = try FallbackSandbox(); defer { sandbox.cleanup() }
        let bottle = Bottle(kind: .steam, paths: sandbox.paths)
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: try sandbox.engine(), base: [:])
        let overrides = env["WINEDLLOVERRIDES"]
        #expect(overrides == "mscoree,mshtml=;winemenubuilder.exe=d")
    }
}
