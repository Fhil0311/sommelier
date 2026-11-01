// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// The contents of an engine's `ENGINE.json`.
public struct EngineInfo: Equatable, Codable, Sendable {
    public var version: String       // the engine's own version, e.g. "2.0.1"
    public var wineVersion: String   // as the build recorded it
    public var backends: [String]    // `GraphicsBackend` raw values the engine was built for
    public var minMacOS: String      // e.g. "14.0"

    /// `wineVersion` as shown to people. Engine 2.0.1 records "11.0 (CrossOver 26.3.0)", which reads as if
    /// Sommelier bundled CrossOver; the engine is Wine compiled from CodeWeavers' published source, so that form
    /// becomes "11.0, from CrossOver 26.3.0 source". Anything else is shown unchanged.
    public var wineDescription: String { Self.describe(wineVersion) }

    private static func describe(_ recorded: String) -> String {
        let tag = " (CrossOver "
        guard recorded.hasSuffix(")"), let tagRange = recorded.range(of: tag) else { return recorded }
        let wine = recorded[..<tagRange.lowerBound]
        let crossOver = recorded[tagRange.upperBound...].dropLast()
        return "\(wine), from CrossOver \(crossOver) source"
    }
}

/// An installed engine: a folder with `ENGINE.json` next to a Wine tree.
public struct Engine: Equatable, Sendable {
    public let directory: URL    // the engine's folder, normally `Paths.engines/<version>`
    public let info: EngineInfo  // its ENGINE.json

    /// Reads `ENGINE.json` in `folder`; nil when it is missing or unreadable.
    public init?(directory folder: URL) {
        let manifest = folder.appendingPathComponent("ENGINE.json")
        guard let data = try? Data(contentsOf: manifest),
              let decoded = try? JSONDecoder().decode(EngineInfo.self, from: data) else { return nil }
        directory = folder
        info = decoded
    }

    public var version: String { info.version }   // shorthand

    /// The Wine prefix tree (`bin`, `lib`, ...). Falls back to `<directory>/wine` when none is found yet.
    public var wineRoot: URL {
        Self.findWineRoot(in: directory) ?? directory.appendingPathComponent("wine", isDirectory: true)
    }
    public var wine: URL { binary("wine") }
    public var wineserver: URL { binary("wineserver") }

    /// An engine is usable once its `wine` launcher is executable.
    public var isUsable: Bool { executable("bin/wine") != nil }

    /// The Chromium helper wrapper the engine ships (keeps Steam's web UI on software rendering).
    public var steamWebHelperWrapper: URL {
        directory.appendingPathComponent("steamwebhelper-wrapper.exe", isDirectory: false)
    }

    /// Apple's D3DMetal bridge, once D3DMetal has been linked into the engine. CrossOver-based Wine loads it from
    /// `CX_APPLEGPTK_LIBD3DSHARED_PATH`; D3DMetal's DLLs reach Metal only through it.
    public var d3dMetalLibrary: URL? { existing("lib/external/libd3dshared.dylib") }

    /// DXMT's Direct3D 10/11 DLLs, laid out like `lib/wine`. They sit outside Wine's own DLL folder so a single
    /// game can opt in (the engine's `cxcompatdb.so` puts the folder first when `SOMMELIER_DLL_PREPEND` names it)
    /// while everything else keeps the engine's default Direct3D.
    public var dxmtRoot: URL? {
        let root = wineRoot.appendingPathComponent("lib/dxmt")
        let marker = root.appendingPathComponent("x86_64-windows").appendingPathComponent(DXMTSetup.dll)
        return FileManager.default.fileExists(atPath: marker.path) ? root : nil
    }

    /// Whether the engine's Mac driver counts the frames it shows (`LiveFrameRate`; Sommelier's engines from 2.2.2).
    /// Read from the driver itself, once per engine folder.
    public var macDriverCountsFrames: Bool {
        let driver = wineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemac.so")
        return Self.frameCounting.withLock { known in
            if let answer = known[driver.path] { return answer }
            let answer = (try? Data(contentsOf: driver, options: .mappedIfSafe))?.range(of: Data("-live.bin".utf8)) != nil
            known[driver.path] = answer
            return answer
        }
    }
    private static let frameCounting = Mutex<[String: Bool]>([:])

    /// Whether the engine's ntdll gives programs their folder's own environment (`ExecutableEnvironment`;
    /// Sommelier's engines from 2.2.4): then a game's graphics never need the store restarted.
    public var supportsProgramEnvironment: Bool {
        let ntdll = wineRoot.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        return Self.programEnvironment.withLock { known in
            if let answer = known[ntdll.path] { return answer }
            let answer = (try? Data(contentsOf: ntdll, options: .mappedIfSafe))?.range(of: Data("SOMMELIER_EXE_ENV".utf8)) != nil
            known[ntdll.path] = answer
            return answer
        }
    }
    private static let programEnvironment = Mutex<[String: Bool]>([:])

    /// Whether the engine's ntdll adds arguments to programs a store starts (`ExecutableArguments`).
    public var supportsProgramArguments: Bool {
        let ntdll = wineRoot.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        return Self.programArguments.withLock { known in
            if let answer = known[ntdll.path] { return answer }
            let answer = (try? Data(contentsOf: ntdll, options: .mappedIfSafe))?.range(of: Data("SOMMELIER_EXE_ARGS".utf8)) != nil
            known[ntdll.path] = answer
            return answer
        }
    }
    private static let programArguments = Mutex<[String: Bool]>([:])

    /// The cellar tool that turns a game's recorded DXMT pipelines into a Metal binary archive on this Mac.
    public var cellarTool: URL? { executable("lib/dxmt/x86_64-unix/cellar") }

    /// GStreamer plugins for Media Foundation (video cutscenes), when the engine bundles them.
    public var gstreamerPlugins: URL? { existing("lib/gstreamer-1.0") }

    /// GStreamer's plugin scanner helper, when the engine bundles it.
    public var gstreamerScanner: URL? { executable("libexec/gstreamer-1.0/gst-plugin-scanner") }

    /// Whether the engine can run `backend` right now. `.auto` and WineD3D always work; D3DMetal additionally
    /// needs the imported library and DXMT its DLL folder.
    public func supports(_ wanted: GraphicsBackend) -> Bool {
        let builtFor = info.backends.contains(wanted.rawValue)
        switch wanted {
        case .auto, .wined3d: return true
        case .d3dMetal: return builtFor && d3dMetalLibrary != nil
        case .dxmt: return builtFor && dxmtRoot != nil
        case .dxvk: return builtFor
        }
    }

    /// Locates the Wine tree: `<dir>/wine`, or inside an app bundle (`<dir>/*.app/Contents/Resources/wine`,
    /// the layout of Gcenx's builds).
    static func findWineRoot(in folder: URL) -> URL? {
        func hasLauncher(_ root: URL) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("bin/wine").path)
        }
        let plain = folder.appendingPathComponent("wine")
        if hasLauncher(plain) { return plain }
        let listing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let bundles = (listing ?? [])
            .filter { $0.pathExtension == "app" }
        return bundles.lazy.map { $0.appendingPathComponent("Contents/Resources/wine") }.first(where: hasLauncher)
    }

    private func binary(_ name: String) -> URL { wineRoot.appendingPathComponent("bin").appendingPathComponent(name) }

    private func existing(_ relative: String) -> URL? {
        let url = wineRoot.appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func executable(_ relative: String) -> URL? {
        let url = wineRoot.appendingPathComponent(relative)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

/// Finds the engines installed under `Paths.engines` and picks one for a backend.
public struct EngineLocator: Sendable {   // reads the disk on every call
    public let paths: Paths   // engines are looked up in `paths.engines`
    public init(paths home: Paths) { paths = home }

    /// Usable engines, newest version first.
    public func installed() -> [Engine] {   // unreadable or unrunnable folders are skipped
        let folders = (try? FileManager.default.contentsOfDirectory(at: paths.engines, includingPropertiesForKeys: nil)) ?? []
        let engines = folders.compactMap { Engine(directory: $0) }.filter { $0.isUsable }
        return engines.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// The engine for `backend`:
    /// 1. the active engine (the user's choice, e.g. a rollback) when the backend is automatic or it was built
    ///    for the backend;
    /// 2. otherwise the newest engine built for the backend that can run it now;
    /// 3. otherwise the active engine, or failing that the newest one.
    public func engine(for wanted: GraphicsBackend, activeVersion: String? = nil) -> Engine? {
        let engines = installed()
        let active = activeVersion.flatMap { version in engines.first { $0.version == version } }
        if let active, wanted == .auto || active.info.backends.contains(wanted.rawValue) {
            return active
        }
        if wanted != .auto,
           let capable = engines.first(where: { $0.info.backends.contains(wanted.rawValue) && $0.supports(wanted) }) {
            return capable
        }
        return active ?? engines.first
    }
}
