// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which Direct3D implementation a game runs on. The raw values are persisted (game profiles, engine
/// manifests, `ENGINE.json`), so they must not change.
public enum GraphicsBackend: String, CaseIterable, Codable, Sendable {
    case auto                              // decided per game by `resolved(for:d3dMetalAvailable:)`
    case d3dMetal, dxmt, dxvk, wined3d     // concrete choices

    public var displayName: String {       // as shown in menus and settings
        switch self {
        case .auto: return "Automatic"
        case .d3dMetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }

    /// The concrete backend for a game when this one is `.auto`; any explicit choice is returned unchanged.
    ///
    /// DXVK on macOS stops at Direct3D 11 feature level 11.0 and has no Direct3D 12, so DirectX 12 games go to
    /// D3DMetal when an engine with it is installed. D3DMetal has no 32-bit side, though, so a game also needs a
    /// 64-bit executable (a 32-bit Unity player can still name `D3D12CreateDevice`). Everything else stays on
    /// DXVK, the backend the verified games were tested with.
    public func resolved(for scan: GraphicsProbe? = nil, d3dMetalAvailable: Bool = false) -> GraphicsBackend {
        if self != .auto { return self }
        guard d3dMetalAvailable, let scan, scan.usesDirectX12, scan.has64BitExecutable else { return .dxvk }
        return .d3dMetal
    }

    /// Entries this backend adds to `WINEDLLOVERRIDES`.
    var overrides: [String] {   // read by WineRunner.environment
        switch self {
        case .dxvk:
            return ["d3d11,d3d10core=n,b"]
        case .dxmt:
            // DXMT ships builtin DLLs found through SOMMELIER_DLL_PREPEND. Forcing builtin keeps Wine from
            // picking the native d3d11/dxgi copies `WineD3DFallback` may leave in System32 for one launcher.
            return ["dxgi,d3d11,d3d10core=b"]
        case .auto, .d3dMetal, .wined3d:
            return []
        }
    }

    /// Environment variables this backend needs.
    var environment: [String: String] {   // merged into the launch environment
        guard self == .dxvk else { return [:] }
        return ["DXVK_ASYNC": "1", "MVK_CONFIG_RESUME_LOST_DEVICE": "1"]
    }
}
