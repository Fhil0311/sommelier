// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Gives the Rockstar Games Launcher Wine's own Direct3D in bottles whose engine runs D3DMetal.
///
/// D3DMetal brings `d3d10`, `d3d11` and `dxgi` but no `d3d10_1` or `d3d10core`. The launcher creates a Direct3D
/// 10.1 device (its UI is Direct2D on top of it), which then pairs Wine's d3d10core with Apple's dxgi, fails, and
/// the launcher reports "failed to initialize". With Wine's complete set it starts.
///
/// The launcher looks for these DLLs in System32 only, so Wine's builds are placed there with the builtin marker
/// cleared: Wine treats them as native DLLs and `wineboot` leaves them alone. A per-app override makes only
/// `Launcher.exe` prefer native; every other program keeps builtin order and therefore D3DMetal. The launcher's
/// Direct3D 12 probe is disabled as well, because Apple's d3d12 on Wine's dxgi crashes it and it only reads GPU
/// details from it.
public struct WineD3DFallback: Sendable {   // one per Sommelier home
    static let modules = ["d3d10", "d3d11", "dxgi"]   // Wine's DLLs that D3DMetal replaces in the engine
    static let apps = ["Launcher.exe"]                 // programs that get the fallback
    static let disabled = ["d3d12", "d3d12core"]       // turned off for them (they only probe these)
    /// Written to System32 when the fallback is installed; its presence is what allows removing the DLLs later,
    /// so files Sommelier didn't place are never deleted.
    static let marker = ".sommelier-wine-d3d"
    static let revision = 2   // raise when the overrides change, so bottles set up before get them rewritten

    public let paths: Paths   // whose bottles are updated
    public init(paths home: Paths) { paths = home }

    /// Where an engine keeps Wine's originals of `modules`, outside every DLL search path.
    static func stash(in target: Engine) -> URL {
        target.wineRoot.appendingPathComponent("lib").appendingPathComponent("wine-d3d/x86_64-windows", isDirectory: true)
    }

    /// Copies Wine's `modules` aside before D3DMetal replaces them. A module already saved, or one that isn't
    /// Wine's build (D3DMetal was linked earlier), is skipped, so the saved copies always stay Wine's.
    static func stashOriginals(of target: Engine) throws {
        let fm = fileSystem
        let dllFolder = target.wineRoot.appendingPathComponent("lib/wine/x86_64-windows")
        let destination = stash(in: target)
        for file in modules.map({ "\($0).dll" }) {
            let saved = destination.appendingPathComponent(file)
            if fm.fileExists(atPath: saved.path) { continue }
            guard let bytes = fm.contents(atPath: dllFolder.appendingPathComponent(file).path), isWineBuild(bytes) else { continue }
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try bytes.write(to: saved)
        }
    }

    /// Wine writes "Wine builtin DLL" into the 16 bytes at offset 0x40 of its PE files.
    private static let builtinMarkerRange = 0x40..<0x50
    private static let builtinMarker = Data("Wine builtin DLL".utf8)

    /// True for a DLL Wine built: it carries the builtin marker and isn't one of D3DMetal's, which carry the same
    /// marker but embed their build path ("D3DMetalDLLs").
    static func isWineBuild(_ bytes: Data) -> Bool {
        guard bytes.count > builtinMarkerRange.upperBound else { return false }
        let base = bytes.startIndex
        let header = bytes.subdata(in: (base + builtinMarkerRange.lowerBound)..<(base + builtinMarkerRange.upperBound))
        return header == builtinMarker && bytes.range(of: Data("D3DMetalDLLs".utf8)) == nil
    }

    /// `original` with the builtin marker zeroed, which makes Wine load it like any Windows DLL.
    static func nativeCopy(of original: Data) -> Data {
        var result = original
        let start = result.startIndex + builtinMarkerRange.lowerBound
        result.resetBytes(in: start..<(start + builtinMarkerRange.count))
        return result
    }

    /// Brings the bottle in line with `current`: installs the fallback when that engine runs D3DMetal and has
    /// Wine's originals stashed, and removes it otherwise (a DXVK engine needs System32 free for its own DLLs).
    /// Call before anything starts in the bottle.
    public func update(_ which: BottleKind, engine current: Engine) async {
        let prefix = Bottle(kind: which, paths: paths)
        if !prefix.exists { return }   // nothing set up yet
        let system32 = prefix.driveC.appendingPathComponent("windows").appendingPathComponent("system32")
        let stampFile = system32.appendingPathComponent(Self.marker)
        let fm = fileSystem

        if current.supports(.d3dMetal), let originals = Self.stashedOriginals(of: current) {
            var wroteFiles = false
            for (name, bytes) in originals {
                let placed = system32.appendingPathComponent(name + ".dll")
                let wanted = Self.nativeCopy(of: bytes)
                if fm.contents(atPath: placed.path) == wanted { continue }
                // Can't write (e.g. a file in use): try again on the next launch rather than half-configure.
                guard (try? wanted.write(to: placed, options: .atomic)) != nil else { return }
                wroteFiles = true
            }
            let stamp = "\(current.version) r\(Self.revision)"
            let recorded = try? String(contentsOf: stampFile, encoding: .utf8)
            if !wroteFiles && recorded == stamp { return }
            await setOverrides(enabled: true, engine: current, bottle: prefix)
            try? stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: stampFile.path) {
            // Wine restores the engine's own builtin copies on its next prefix update.
            for name in Self.modules {
                try? fm.removeItem(at: system32.appendingPathComponent(name + ".dll"))
            }
            await setOverrides(enabled: false, engine: current, bottle: prefix)
            try? fm.removeItem(at: stampFile)
        }
    }

    /// Wine's saved DLLs in `modules` order, or nil unless every one of them is there.
    private static func stashedOriginals(of target: Engine) -> [(String, Data)]? {
        let folder = stash(in: target)
        var found: [(String, Data)] = []
        for name in modules {
            guard let bytes = fileSystem.contents(atPath: folder.appendingPathComponent(name + ".dll").path) else { return nil }
            found.append((name, bytes))
        }
        return found
    }

    /// Adds or removes the per-app DLL overrides under `HKCU\Software\Wine\AppDefaults\<app>\DllOverrides`.
    private func setOverrides(enabled: Bool, engine: Engine, bottle: Bottle) async {
        let environment = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        var entries = (Self.modules + ["d3d10_1", "d3d10core"]).map { (dll: $0, order: "native,builtin") }
        entries += Self.disabled.map { (dll: $0, order: "") }
        for program in Self.apps {
            let key = "HKCU\\Software\\Wine\\AppDefaults\\\(program)\\DllOverrides"
            guard enabled else {
                _ = try? await ProcessRunner.run(engine.wine, ["reg", "delete", key, "/f"], environment: environment)
                continue
            }
            for entry in entries {
                let arguments = ["reg", "add", key, "/v", entry.dll, "/d", entry.order, "/f"]
                _ = try? await ProcessRunner.run(engine.wine, arguments, environment: environment)
            }
        }
    }
}

/// Shorthand for the default file manager (not stored: `FileManager` isn't `Sendable`).
private var fileSystem: FileManager { FileManager.default }
