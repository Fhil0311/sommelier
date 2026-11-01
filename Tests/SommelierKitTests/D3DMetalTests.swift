// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A scratch folder under the system temp directory, removed by `remove()`.
private struct Scratch {
    let url: URL
    init(_ label: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-\(label)-\(UUID().uuidString)")
        try makeFolder(url)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    func file(_ relative: String, _ contents: String = "x") throws {
        let target = url.appendingPathComponent(relative)
        try makeFolder(target.deletingLastPathComponent())
        try Data(contents.utf8).write(to: target)
    }
}

/// Lays out a toolkit the way Apple's disk does (`redist/lib/external`, `redist/lib/wine/x86_64-windows`), with
/// unsigned placeholder files.
private func makeToolkit(in scratch: Scratch, dlls: [String] = ["d3d11", "d3d12", "dxgi", "nvapi64"]) throws -> URL {
    let lib = scratch.url.appendingPathComponent("redist/lib")
    try FileManager.default.createDirectory(at: lib.appendingPathComponent("external/D3DMetal.framework"),
                                            withIntermediateDirectories: true)
    try scratch.file("redist/lib/external/libd3dshared.dylib", "unsigned")
    for dll in dlls { try scratch.file("redist/lib/wine/x86_64-windows/\(dll).dll", "MZ") }
    return lib
}

private func writeEngineJSON(at folder: URL, version: String, backends: [String]) throws {
    try makeFolder(folder)
    let list = backends.map { #""\#($0)""# }.joined(separator: ", ")
    let json = "{\"version\":\"\(version)\",\"wineVersion\":\"test\",\"backends\":[\(list)],\"minMacOS\":\"14.0\"}"
    try json.write(to: folder.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
}

@Suite struct D3DMetalStoreTests {
    @Test func prefersTheEvaluationImageOnApplesDisk() throws {
        let disk = try Scratch("gptk-disk"); defer { disk.remove() }
        #expect(D3DMetalStore.nestedImage(in: disk.url) == nil)
        try disk.file("Metal Shader Converter 3.0.pkg")
        try disk.file("Another Tool.dmg")
        #expect(D3DMetalStore.nestedImage(in: disk.url)?.lastPathComponent == "Another Tool.dmg")
        try disk.file("Evaluation environment for Windows games 3.0.dmg")
        #expect(D3DMetalStore.nestedImage(in: disk.url)?.lastPathComponent == "Evaluation environment for Windows games 3.0.dmg")
    }

    @Test func findsTheLibFolderFromSeveralStartingPoints() throws {
        let kit = try Scratch("gptk"); defer { kit.remove() }
        let lib = try makeToolkit(in: kit).standardizedFileURL
        for start in [kit.url, kit.url.appendingPathComponent("redist"), lib] {
            #expect(D3DMetalStore.locate(in: start)?.standardizedFileURL == lib)
        }
    }

    @Test func findsNothingInAFolderWithoutD3DMetal() throws {
        let empty = try Scratch("no-gptk"); defer { empty.remove() }
        try empty.file("lib/external/libd3dshared.dylib")   // the framework is missing
        #expect(D3DMetalStore.locate(in: empty.url) == nil)
    }

    @Test func onlyApplesOwnSignaturePasses() throws {
        #expect(D3DMetalStore.isSignedByApple(URL(fileURLWithPath: "/bin/ls")))
        let kit = try Scratch("gptk-sig"); defer { kit.remove() }
        let lib = try makeToolkit(in: kit)
        #expect(!D3DMetalStore.isSignedByApple(lib.appendingPathComponent("external/libd3dshared.dylib")))
        #expect(!D3DMetalStore.isSignedByApple(kit.url.appendingPathComponent("does-not-exist")))
    }

    @Test func unsignedCopyIsRefusedAndCleanedUp() async throws {
        let kit = try Scratch("gptk-unsigned"); defer { kit.remove() }
        _ = try makeToolkit(in: kit)
        let home = kit.url.appendingPathComponent("home")
        let importer = D3DMetalStore(paths: .init(home: home))
        await #expect(throws: D3DMetalError.notSignedByApple("D3DMetal.framework")) {
            _ = try await importer.stage(from: kit.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        #expect(importer.installed == nil, "nothing was imported")
    }

    @Test func toolkitWithoutD3D12IsRejected() async throws {
        let kit = try Scratch("gptk-partial"); defer { kit.remove() }
        _ = try makeToolkit(in: kit, dlls: ["d3d11", "dxgi"])
        let importer = D3DMetalStore(paths: .init(home: kit.url.appendingPathComponent("home")))
        await #expect(throws: D3DMetalError.missingModule("d3d12.dll")) { _ = try await importer.stage(from: kit.url) }
    }

    @Test func folderWithoutAToolkitIsNotFound() async throws {
        let folder = try Scratch("not-gptk"); defer { folder.remove() }
        try folder.file("readme.txt")
        let importer = D3DMetalStore(paths: .init(home: folder.url.appendingPathComponent("home")))
        await #expect(throws: D3DMetalError.notFound) { _ = try await importer.stage(from: folder.url) }
    }

    @Test func onlyEnginesBuiltForD3DMetalCanUseIt() throws {
        let root = try Scratch("engines"); defer { root.remove() }
        try writeEngineJSON(at: root.url.appendingPathComponent("cx"), version: "2.0.0", backends: ["d3dMetal", "dxmt"])
        try writeEngineJSON(at: root.url.appendingPathComponent("stock"), version: "1.0.0", backends: ["dxvk"])
        let cx = try #require(Engine(directory: root.url.appendingPathComponent("cx")))
        let stock = try #require(Engine(directory: root.url.appendingPathComponent("stock")))
        #expect(D3DMetalStore.canUse(cx))
        #expect(!D3DMetalStore.canUse(stock))
    }

    @Test func linkingCopiesModulesPointsUnixSidesAtTheBridgeAndStashesWine() throws {
        let home = try Scratch("d3d-link"); defer { home.remove() }
        let paths = Paths(home: home.url)
        // An imported D3DMetal, as `commit` leaves it.
        let d3d = paths.d3dMetal
        try makeFolder(d3d.appendingPathComponent("external"))
        try Data("bridge".utf8).write(to: d3d.appendingPathComponent("external/libd3dshared.dylib"))
        try makeFolder(d3d.appendingPathComponent("x86_64-windows"))
        for module in ["d3d11", "d3d12", "d3d12core", "dxgi", "nvngx-on-metalfx"] {
            try Data("apple \(module)".utf8).write(to: d3d.appendingPathComponent("x86_64-windows/\(module).dll"))
        }
        try #"{"version":"3.0","importedAt":"2026-01-02T03:04:05Z"}"#
            .write(to: d3d.appendingPathComponent("D3DMETAL.json"), atomically: true, encoding: .utf8)
        let importer = D3DMetalStore(paths: paths)
        #expect(importer.installed?.version == "3.0")

        // An engine with Wine's own Direct3D DLLs.
        let engineDir = paths.engine(version: "2.0.0")
        try writeEngineJSON(at: engineDir, version: "2.0.0", backends: ["d3dMetal"])
        let windows = engineDir.appendingPathComponent("wine/lib/wine/x86_64-windows")
        try makeFolder(windows)
        try FileManager.default.createDirectory(at: engineDir.appendingPathComponent("wine/lib/wine/x86_64-unix"),
                                                withIntermediateDirectories: true)
        let wineD3D11 = Data("MZ".utf8) + Data(count: 0x3E) + Data("Wine builtin DLL".utf8) + Data("wine d3d11".utf8)
        try wineD3D11.write(to: windows.appendingPathComponent("d3d11.dll"))
        let cx = try #require(Engine(directory: engineDir))
        #expect(!cx.supports(.d3dMetal))

        try importer.link(into: cx)
        #expect(cx.supports(.d3dMetal), "the bridge library is in place")
        #expect(FileManager.default.contents(atPath: windows.appendingPathComponent("d3d12.dll").path) == Data("apple d3d12".utf8))
        let unixSide = engineDir.appendingPathComponent("wine/lib/wine/x86_64-unix/d3d11.so").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: unixSide) == "../../external/libd3dshared.dylib")
        let stashed = WineD3DFallback.stash(in: cx).appendingPathComponent("d3d11.dll")
        #expect(FileManager.default.contents(atPath: stashed.path) == wineD3D11)
        let stamp = engineDir.appendingPathComponent("wine/lib/external/\(D3DMetalStore.marker)")
        #expect(try String(contentsOf: stamp, encoding: .utf8) == "3.0 layout \(D3DMetalStore.layout)")
        // GPTK 4's own d3d12core, and the MetalFX module under the name games look for (Apple's read-me).
        #expect(FileManager.default.contents(atPath: windows.appendingPathComponent("d3d12core.dll").path) == Data("apple d3d12core".utf8))
        #expect(FileManager.default.contents(atPath: windows.appendingPathComponent("nvngx.dll").path) == Data("apple nvngx-on-metalfx".utf8))
        let dlssUnix = engineDir.appendingPathComponent("wine/lib/wine/x86_64-unix/nvngx.so").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dlssUnix) == "../../external/libd3dshared.dylib")

        // Same version again: nothing is copied (a changed file stays changed).
        try Data("edited".utf8).write(to: windows.appendingPathComponent("d3d12.dll"))
        try importer.link(into: cx)
        #expect(FileManager.default.contents(atPath: windows.appendingPathComponent("d3d12.dll").path) == Data("edited".utf8))
    }

    @Test func committingReplacesTheEarlierImport() throws {
        let home = try Scratch("d3d-commit"); defer { home.remove() }
        let paths = Paths(home: home.url)
        let importer = D3DMetalStore(paths: paths)
        func stagedCopy(_ version: String) throws -> StagedD3DMetal {
            let folder = home.url.appendingPathComponent(".d3dmetal-\(version)")
            try makeFolder(folder.appendingPathComponent("external"))
            try Data().write(to: folder.appendingPathComponent("external/libd3dshared.dylib"))
            let info = D3DMetalInfo(version: version, importedAt: Date(timeIntervalSince1970: 1_800_000_000))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(info).write(to: folder.appendingPathComponent("D3DMETAL.json"))
            return StagedD3DMetal(directory: folder, info: info, license: nil)
        }
        try importer.commit(try stagedCopy("1.0"), engines: [])
        #expect(importer.installed?.version == "1.0")
        try importer.commit(try stagedCopy("2.0"), engines: [])
        #expect(importer.installed?.version == "2.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.url.path).filter { $0.hasPrefix(".d3dmetal") }
        #expect(leftovers == [], "no staging or backup folders remain")

        let declined = try stagedCopy("3.0")
        importer.discard(declined)
        #expect(!FileManager.default.fileExists(atPath: declined.directory.path))
        #expect(importer.installed?.version == "2.0")
    }

    @Test func downloadPageSearchesForTheToolkit() {
        #expect(D3DMetalStore.downloadPage.absoluteString == "https://developer.apple.com/download/all/?q=game%20porting%20toolkit")
    }

    @Test func toolkitNamesMatchApplesDownloadsOnly() {
        for name in ["Game_Porting_Toolkit_3.0.dmg", "Game Porting Toolkit 4 beta 1.dmg", "game-porting-toolkit",
                     "Evaluation environment for Windows games 3.0"] {
            #expect(D3DMetalStore.isToolkitName(name), "\(name)")
        }
        for name in ["Porting.Kit-7.0.2-Apple Silicon.dmg", "CrossOver.dmg", "Toolkit.dmg"] {
            #expect(!D3DMetalStore.isToolkitName(name), "\(name)")
        }
    }

    /// Opt-in check against a real download:
    /// `SOMMELIER_GPTK=/path/to/toolkit.dmg [SOMMELIER_GPTK_ENGINE=/path/to/engine] swift test --filter realToolkit`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_GPTK"] != nil))
    func realToolkitImportsAndLinks() async throws {
        let settings = ProcessInfo.processInfo.environment
        let home = try Scratch("gptk-real"); defer { home.remove() }
        let paths = Paths(home: home.url)
        let importer = D3DMetalStore(paths: paths)
        let toolkit = URL(fileURLWithPath: try #require(settings["SOMMELIER_GPTK"]))
        let staged = try await importer.stage(from: toolkit)
        #expect(!["", "unknown"].contains(staged.info.version))

        var targets: [Engine] = []
        if let enginePath = settings["SOMMELIER_GPTK_ENGINE"] {
            // Work on a copy without D3DMetal, so the real engine stays untouched.
            let clone = paths.engine(version: "test")
            try makeFolder(paths.engines)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: enginePath), to: clone)
            try? FileManager.default.removeItem(at: clone.appendingPathComponent("wine/lib/external"))
            let target = try #require(Engine(directory: clone))
            #expect(!target.supports(.d3dMetal))
            targets.append(target)
        }
        try importer.commit(staged, engines: targets)
        #expect(importer.installed == staged.info)
        for linked in targets {
            #expect(linked.supports(.d3dMetal), "linked during commit")
            let framework = linked.wineRoot.appendingPathComponent("lib/external/D3DMetal.framework")
            #expect(D3DMetalStore.isSignedByApple(framework))
            let link = linked.wineRoot.appendingPathComponent("lib/wine/x86_64-unix/d3d12.so").path
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "../../external/libd3dshared.dylib")
        }
    }
}

/// Creates a folder and any missing parents.
private func makeFolder(_ path: URL) throws {
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: nil)
}
