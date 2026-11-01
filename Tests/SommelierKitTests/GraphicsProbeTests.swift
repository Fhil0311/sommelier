// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Writes a small but valid PE file: DOS header, PE/COFF header, optional header with 16 data directories and
/// a single section (file offset 0x400, RVA 0x2000) holding the import tables and DLL names.
struct FakeExecutable {
    var machine: UInt16 = 0x8664
    var imports: [String] = []
    var delayImports: [String] = []
    /// Bytes appended after the image (padding, embedded strings).
    var trailer = Data()

    var bytes: Data {
        var out = Data(count: 0x800)
        func le(_ value: Int, at offset: Int, width: Int) {
            for i in 0..<width { out[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        let wide = machine != 0x014c
        let pe = 0x40, optional = pe + 24, optionalSize = wide ? 240 : 224
        let sectionRVA = 0x2000, sectionFile = 0x400
        func file(_ rva: Int) -> Int { rva - sectionRVA + sectionFile }

        out.replaceSubrange(0..<2, with: Array("MZ".utf8))
        le(pe, at: 0x3c, width: 4)
        out.replaceSubrange(pe..<pe + 4, with: [0x50, 0x45, 0, 0])
        le(Int(machine), at: pe + 4, width: 2)
        le(1, at: pe + 6, width: 2)                                    // section count
        le(optionalSize, at: pe + 20, width: 2)
        le(wide ? 0x20b : 0x10b, at: optional, width: 2)
        let directories = optional + (wide ? 112 : 96)
        le(16, at: directories - 4, width: 4)
        let section = optional + optionalSize
        le(0x400, at: section + 8, width: 4)                           // virtual size
        le(sectionRVA, at: section + 12, width: 4)
        le(0x400, at: section + 16, width: 4)                          // raw size
        le(sectionFile, at: section + 20, width: 4)

        let importTable = sectionRVA, delayTable = sectionRVA + 0x100
        var nextName = sectionRVA + 0x200
        func name(_ text: String) -> Int {
            let rva = nextName
            out.replaceSubrange(file(rva)..<file(rva) + text.utf8.count, with: Array(text.utf8))
            nextName += text.utf8.count + 1                            // the zero byte is already there
            return rva
        }
        le(importTable, at: directories + 1 * 8, width: 4)
        for (index, dll) in imports.enumerated() { le(name(dll), at: file(importTable) + index * 20 + 12, width: 4) }
        le(delayTable, at: directories + 13 * 8, width: 4)
        for (index, dll) in delayImports.enumerated() {
            let entry = file(delayTable) + index * 32
            le(1, at: entry, width: 4)                                 // attributes: RVA-based
            le(name(dll), at: entry + 4, width: 4)
        }
        return out + trailer
    }

    /// Big enough to count as a game binary rather than a helper.
    var gameSized: Data { bytes + Data(count: GraphicsProbe.minimumExecutableSize) }
}

@Suite struct PEImageTests {
    @Test func sixtyFourBitImageWithImports() throws {
        let image = try #require(PEImage(data: FakeExecutable(imports: ["KERNEL32.dll", "D3D12.dll"]).bytes))
        #expect(image.machine == .x86_64 && image.is64Bit)
        #expect(image.imports == ["kernel32.dll", "d3d12.dll"])         // lowercased
        #expect(image.imports("d3d12.DLL") && !image.imports("d3d11.dll"))
    }

    @Test func thirtyTwoBitImage() throws {
        let image = try #require(PEImage(data: FakeExecutable(machine: 0x014c, imports: ["d3d9.dll"]).bytes))
        #expect(image.machine == .i386 && !image.is64Bit)
        #expect(image.imports == ["d3d9.dll"])
    }

    @Test func armAndUnknownMachines() throws {
        #expect(PEImage(data: FakeExecutable(machine: 0xaa64).bytes)?.machine == .arm64)
        #expect(PEImage(data: FakeExecutable(machine: 0x01c4).bytes)?.machine == .other(0x01c4))
    }

    @Test func delayLoadedDLLsCount() throws {
        let image = try #require(PEImage(data: FakeExecutable(imports: ["user32.dll"], delayImports: ["dxgi.dll", "d3d12.dll"]).bytes))
        #expect(image.imports == ["user32.dll", "dxgi.dll", "d3d12.dll"])
    }

    @Test func readsFromAFileToo() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-pe-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: url) }
        try FakeExecutable(imports: ["xinput1_3.dll"]).bytes.write(to: url)
        #expect(PEImage(url: url)?.imports == ["xinput1_3.dll"])
        #expect(PEImage(url: url.appendingPathExtension("missing")) == nil)
    }

    @Test func notAnExecutable() {
        #expect(PEImage(data: Data()) == nil)
        #expect(PEImage(data: Data("MZ but nothing else".utf8)) == nil)
        #expect(PEImage(data: Data(count: 0x800)) == nil)
        var cut = FakeExecutable().bytes
        cut.removeSubrange(0x50...)                                    // inside the PE header
        #expect(PEImage(data: cut) == nil)
        var badMagic = FakeExecutable().bytes
        badMagic[0x40 + 24] = 0x99
        #expect(PEImage(data: badMagic) == nil)
    }

    @Test func worksOnSlicedData() throws {
        let sliced = (Data(count: 5) + FakeExecutable(imports: ["d3d11.dll"]).bytes).dropFirst(5)
        #expect(PEImage(data: sliced)?.imports == ["d3d11.dll"])
    }
}

@Suite struct GraphicsProbeTests {
    /// Creates a game folder from relative paths and contents.
    final class GameFolder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-probe-\(UUID().uuidString)")
        init(_ files: [String: Data]) throws {
            for (path, contents) in files {
                let file = url.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: file)
            }
        }
        deinit { try? FileManager.default.removeItem(at: url) }
        var probe: GraphicsProbe { GraphicsProbe.scan(url) }
    }

    @Test func linkedD3D12() throws {
        let game = try GameFolder(["Binaries/Win64/Game.exe": FakeExecutable(imports: ["dxgi.dll", "d3d12.dll"]).gameSized])
        #expect(game.probe == GraphicsProbe(usesDirectX12: true, has64BitExecutable: true))
    }

    @Test func plainDirectX11Game() throws {
        let game = try GameFolder(["game.exe": FakeExecutable(machine: 0x014c, imports: ["d3d11.dll"]).gameSized])
        #expect(game.probe == GraphicsProbe())
    }

    @Test func vendorDX12HelperImport() throws {
        let game = try GameFolder(["x.exe": FakeExecutable(imports: ["ffx_backend_dx12_x64.dll"]).gameSized])
        #expect(game.probe.usesDirectX12)
    }

    @Test(arguments: ["D3D12/D3D12Core.dll", "dxil.dll", "bin/dxilconv7.dll"])
    func shippedDX12Files(path: String) throws {
        let game = try GameFolder(["Game.exe": FakeExecutable(imports: ["kernel32.dll"]).gameSized, path: Data([0])])
        #expect(game.probe.usesDirectX12)
    }

    @Test func agilityCoreOutsideItsFolderDoesNotCount() throws {
        let game = try GameFolder(["Game.exe": FakeExecutable().gameSized, "D3D12Core.dll": Data([0])])
        #expect(!game.probe.usesDirectX12)
    }

    @Test func entryPointNameInsideTheBinary() throws {
        var exe = FakeExecutable(imports: ["kernel32.dll"])
        exe.trailer = Data(count: GraphicsProbe.minimumExecutableSize) + GraphicsProbe.directX12EntryPoint + Data([0])
        let game = try GameFolder(["Game.exe": exe.bytes])
        #expect(game.probe.usesDirectX12)
    }

    @Test func helpersRedistributablesAndDeepFoldersAreIgnored() throws {
        let dx12 = FakeExecutable(imports: ["d3d12.dll"])
        let game = try GameFolder([
            "_CommonRedist/DirectX/Jun2010/DXSETUP.exe": dx12.gameSized,
            "EasyAntiCheat/eac.exe": dx12.gameSized,
            "uninstall.exe": dx12.gameSized,
            "small.exe": dx12.bytes,                                        // below the size cut-off
            "a/b/c/d/deep.exe": dx12.gameSized,                             // past maxDepth
            "Game.exe": FakeExecutable(imports: ["d3d11.dll"]).gameSized,
        ])
        #expect(game.probe == GraphicsProbe(usesDirectX12: false, has64BitExecutable: true))
    }

    @Test func streamedSearchFindsMatchesOnEveryChunkBoundary() throws {
        let needle = GraphicsProbe.directX12EntryPoint
        let game = try GameFolder(["blob": Data(repeating: 0x41, count: 97) + needle + Data(repeating: 0x42, count: 61)])
        let blob = game.url.appendingPathComponent("blob")
        for chunk in [1, 5, 16, 17, 97, 100, 113, 114, 1 << 16] {
            #expect(GraphicsProbe.contains(needle, in: blob, chunkSize: chunk), "chunk size \(chunk)")
        }
        #expect(!GraphicsProbe.contains(needle + Data("!".utf8), in: blob, chunkSize: 16))
        #expect(!GraphicsProbe.contains(needle, in: blob.appendingPathExtension("missing")))
    }

    @Test func probeRoundTripsThroughJSON() throws {
        let probe = GraphicsProbe(usesDirectX12: true, has64BitExecutable: false)
        let json = try JSONEncoder().encode(probe)
        let keys = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Bool])
        #expect(keys == ["usesDirectX12": true, "has64BitExecutable": false])
        #expect(try JSONDecoder().decode(GraphicsProbe.self, from: json) == probe)
    }

    /// Checks real installs on demand:
    /// `SOMMELIER_PROBE_DX12=<dir>:<dir> SOMMELIER_PROBE_NOT_DX12=<dir> swift test --filter installedGames`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_PROBE_DX12"] != nil
                   || ProcessInfo.processInfo.environment["SOMMELIER_PROBE_NOT_DX12"] != nil))
    func installedGames() {
        func folders(_ variable: String) -> [String] {
            (ProcessInfo.processInfo.environment[variable] ?? "").split(separator: ":").map(String.init)
        }
        for path in folders("SOMMELIER_PROBE_DX12") {
            #expect(GraphicsProbe.scan(URL(fileURLWithPath: path)).usesDirectX12, "\(path)")
        }
        for path in folders("SOMMELIER_PROBE_NOT_DX12") {
            #expect(!GraphicsProbe.scan(URL(fileURLWithPath: path)).usesDirectX12, "\(path)")
        }
    }
}
