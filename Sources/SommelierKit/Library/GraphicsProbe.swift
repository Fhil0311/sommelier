// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The graphics API a game needs and whether it ships a 64-bit binary, as far as its installed files tell.
/// Stores don't publish either, so Sommelier reads executable headers and looks for files only DirectX 12 games
/// carry. Nothing is run. Stored with the game in the library.
public struct GraphicsProbe: Codable, Sendable, Equatable {
    /// Direct3D 12 is used or available. Most DX12 games load `d3d12.dll` at run time rather than linking it, so
    /// DX12-only helper DLLs and the bare `D3D12CreateDevice` name count too.
    public var usesDirectX12 = false
    /// At least one game-sized executable is x86-64 or ARM64.
    public var has64BitExecutable = false

    public init(usesDirectX12: Bool = false, has64BitExecutable: Bool = false) {
        (self.usesDirectX12, self.has64BitExecutable) = (usesDirectX12, has64BitExecutable)
    }

    /// Folder names (substrings, lowercase) that hold installers, redistributables, crash reporters or
    /// anti-cheat: never the game itself.
    static let ignoredFolderParts = [
        "redist", "vcredist", "directx", "prereq", "installer", "support", "thirdparty",   // installers and extras
        "easyanticheat", "battleye", "__overlay", "crashreport",                            // anti-cheat, overlays
    ]
    /// Executable name substrings (lowercase) of uninstallers, setup programs and reporters.
    static let ignoredExecutableParts = ["unins", "setup", "redist", "crash", "report", "vc_", "dxsetup", "dotnet",
                                         "ue4prereq"]
    /// Smaller executables are launchers and helpers; actual game binaries are bigger.
    static let minimumExecutableSize = 1_500_000
    /// The needle for the last-resort search through executables.
    static let directX12EntryPoint = Data("D3D12CreateDevice".utf8)

    /// A file only DirectX 12 games ship: the Agility SDK's `D3D12/D3D12Core.dll`, or the DXIL signer
    /// (`dxil.dll`, `dxilconv*.dll`). Both names lowercase.
    static func isDirectX12File(_ name: String, folder: String) -> Bool {
        switch name {
        case "d3d12core.dll": return folder == "d3d12"
        case "dxil.dll": return true
        default: return name.hasPrefix("dxilconv") && name.hasSuffix(".dll")
        }
    }

    /// An imported DLL that means Direct3D 12: `d3d12.dll` itself, or a vendor library's DX12 build
    /// (e.g. `amd_fidelityfx_loader_dx12.dll`).
    static func isDirectX12Import(_ dll: String) -> Bool { ["d3d12", "_dx12"].contains { dll.contains($0) } }

    /// Looks through a game folder, `maxDepth` levels deep, parsing at most `maxExecutables` executables.
    public static func scan(_ directory: URL, maxDepth: Int = 4, maxExecutables: Int = 32) -> GraphicsProbe {
        var result = GraphicsProbe()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return result }
        let rootDepth = directory.standardizedFileURL.pathComponents.count
        var candidates: [URL] = []

        while let item = items.nextObject() as? URL {
            let name = item.lastPathComponent.lowercased()
            let info = try? item.resourceValues(forKeys: Set(keys))
            if info?.isDirectory == true {
                let depth = item.standardizedFileURL.pathComponents.count - rootDepth
                if depth >= maxDepth || ignoredFolderParts.contains(where: { name.contains($0) }) {
                    items.skipDescendants()
                }
                continue
            }
            if isDirectX12File(name, folder: item.deletingLastPathComponent().lastPathComponent.lowercased()) {
                result.usesDirectX12 = true
            }
            guard candidates.count < maxExecutables, item.pathExtension.lowercased() == "exe",
                  (info?.fileSize ?? 0) >= minimumExecutableSize,
                  !ignoredExecutableParts.contains(where: { name.contains($0) }),
                  let image = PEImage(url: item) else { continue }
            candidates.append(item)
            result.has64BitExecutable = result.has64BitExecutable || image.is64Bit
            result.usesDirectX12 = result.usesDirectX12 || image.imports.contains(where: isDirectX12Import)
        }

        // Slowest check, so only when nothing else answered: the entry point's name inside a game binary
        // (these can be hundreds of megabytes).
        if !result.usesDirectX12 {
            result.usesDirectX12 = candidates.contains { contains(directX12EntryPoint, in: $0) }
        }
        return result
    }

    /// Whether `file` contains the bytes of `needle`. Reads `chunkSize` bytes at a time and carries the last
    /// `needle.count - 1` bytes into the next read, so a match split across two reads is still found.
    static func contains(_ needle: Data, in file: URL, chunkSize: Int = 8 << 20) -> Bool {
        guard !needle.isEmpty else { return true }
        guard let reader = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? reader.close() }
        var window = Data()
        while true {
            guard let block = try? reader.read(upToCount: chunkSize), !block.isEmpty else { return false }
            window.append(block)
            if window.withUnsafeBytes({ hay in
                needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
            }) {
                return true
            }
            window = window.suffix(needle.count - 1)
        }
    }
}
