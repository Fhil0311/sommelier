// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Installs components into a fresh bottle with a real engine: `SOMMELIER_COMPONENTS_TEST=<engine folder>` (the
/// one with `ENGINE.json`). Packages already in `SOMMELIER_COMPONENTS_CACHE` are copied in, so nothing is
/// downloaded twice.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_COMPONENTS_TEST"] != nil), .serialized)
struct ComponentInstallTests {
    static func setUp() async throws -> (Paths, Bottle, Engine) {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("components-\(UUID().uuidString)")
        let paths = Paths(home: home)
        try paths.createDirectories()
        if let cache = env["SOMMELIER_COMPONENTS_CACHE"] {
            let folder = ComponentInstaller(paths: paths).folder
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: cache)) ?? [] {
                try? FileManager.default.copyItem(atPath: cache + "/" + file, toPath: folder.appendingPathComponent(file).path)
            }
        }
        let engine = try #require(Engine(directory: URL(fileURLWithPath: env["SOMMELIER_COMPONENTS_TEST"]!)))
        let bottle = try await BottleManager(paths: paths).ensure(.epic, engine: engine)
        return (paths, bottle, engine)
    }

    @Test func shaderCompilerAndDirectXGoIn() async throws {
        let (paths, bottle, engine) = try await Self.setUp()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = ComponentInstaller(paths: paths)
        #expect(!installer.isInstalled(.d3dcompiler47, in: bottle))
        let compiler = try await installer.install(.d3dcompiler47, in: bottle, engine: engine)
        #expect(compiler.sorted() == ["syswow64/d3dcompiler_47.dll", "system32/d3dcompiler_47.dll"].sorted())
        #expect(installer.isInstalled(.d3dcompiler47, in: bottle))
        let windows = bottle.driveC.appendingPathComponent("windows")
        let size = (try? FileManager.default.attributesOfItem(atPath: windows.appendingPathComponent("system32/d3dcompiler_47.dll").path)[.size] as? Int) ?? 0
        #expect(size > 4_000_000)

        #expect(!installer.isInstalled(.directx, in: bottle))
        let directx = try await installer.install(.directx, in: bottle, engine: engine)
        #expect(directx.contains("syswow64/d3dx9_43.dll") && directx.contains("system32/xactengine3_7.dll") && directx.contains("system32/d3dcompiler_43.dll"))
        #expect(installer.isInstalled(.directx, in: bottle))
        #expect(!ComponentInstaller.isWineBuiltin(windows.appendingPathComponent("syswow64/d3dx9_43.dll")))
        #expect(ComponentInstaller.isWineBuiltin(windows.appendingPathComponent("system32/d3d11.dll")))
        #expect(!FileManager.default.fileExists(atPath: windows.appendingPathComponent("temp/sommelier-directx").path))
    }

    @Test func oldDirectXPartsAndFontsGoIn() async throws {
        let (paths, bottle, engine) = try await Self.setUp()
        defer { try? FileManager.default.removeItem(at: paths.home) }
        let installer = ComponentInstaller(paths: paths)
        let windows = bottle.driveC.appendingPathComponent("windows")
        for component in [Component.directplay, .dsound, .directmusic] {
            #expect(!installer.isInstalled(component, in: bottle))
            let files = try await installer.install(component, in: bottle, engine: engine)
            #expect(installer.isInstalled(component, in: bottle))
            #expect(files.allSatisfy { $0.hasPrefix("syswow64/") } && files.count == (Component.fromDxnt[component]?.count ?? 0))
        }
        #expect(!ComponentInstaller.isWineBuiltin(windows.appendingPathComponent("syswow64/dplayx.dll")))
        #expect(Component.directplay.overrides["dplayx"] == "n" && Component.directplay.overrides["dplaysvr.exe"] == "n")
        #expect(Component.directmusic.overrides["streamci"] == "n" && Component.directmusic.overrides["dsound"] == "n,b")

        let fonts = try await installer.install(.corefonts, in: bottle, engine: engine)
        #expect(fonts.contains("Fonts/arial.ttf") && fonts.contains("Fonts/verdana.ttf") && fonts.contains("Fonts/times.ttf"))
        #expect(fonts.count >= 25)
        #expect(installer.isInstalled(.corefonts, in: bottle))
    }
}
