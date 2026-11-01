// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Puts DXMT's `winemetal.dll` into a bottle.
///
/// Wine only loads a builtin DLL when the prefix has a file for it (outside prefix setup). `d3d11.dll` and
/// `dxgi.dll` already have one, so with `SOMMELIER_DLL_PREPEND` Wine finds DXMT's builtins for them. DXMT's own
/// `winemetal.dll` has none, so a copy of the builtin goes into System32 (64-bit) and SysWOW64 (32-bit).
/// Only DXMT's DLLs import it, so games on other backends never load it.
public enum DXMTSetup {
    public static let dll = "winemetal.dll"
    static let targets = [("x86_64-windows", "system32"), ("i386-windows", "syswow64")]

    public static func installStubs(from dxmtRoot: URL, into bottle: Bottle) throws {
        let fm = FileManager.default
        for (arch, folder) in targets {
            guard let data = fm.contents(atPath: dxmtRoot.appendingPathComponent("\(arch)/\(dll)").path) else { continue }
            let dir = bottle.driveC.appendingPathComponent("windows/\(folder)", isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { continue }
            let target = dir.appendingPathComponent(dll)
            if fm.contents(atPath: target.path) == data { continue }
            try data.write(to: target, options: .atomic)
        }
    }
}
