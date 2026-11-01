// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A Windows program's own icon, read from its resources: the largest image of its first icon group, as a
/// one-image `.ico` file (which macOS reads). Only the file is read; nothing runs.
public enum WindowsIcon {
    /// The icon, with its size in pixels (256 for the largest modern icons), or nil when the program has none.
    public static func extract(from exe: URL) -> (ico: Data, size: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: exe) else { return nil }
        defer { try? handle.close() }
        // Resources are usually near the end; executables of a few GB aren't icons' business: read up to 256 MB.
        guard let data = try? handle.read(upToCount: 256 << 20), data.count > 0x40 else { return nil }
        return extract(fromImage: [UInt8](data))
    }

    static func extract(fromImage b: [UInt8]) -> (ico: Data, size: Int)? {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { o >= 0 && o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : nil }

        guard u16(0) == 0x5A4D, let pe = u32(0x3C), u32(pe) == 0x0000_4550,
              let sectionCount = u16(pe + 6), let optionalSize = u16(pe + 20) else { return nil }
        let optional = pe + 24
        guard let magic = u16(optional) else { return nil }
        let directories = optional + (magic == 0x20B ? 112 : 96)            // PE32+ or PE32
        guard let resourceRVA = u32(directories + 2 * 8), resourceRVA != 0 else { return nil }

        // RVA → file offset through the section table.
        let sections = optional + optionalSize
        func offset(_ rva: Int) -> Int? {
            for i in 0..<sectionCount {
                let s = sections + i * 40
                guard let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20), let virtualSize = u32(s + 8) else { return nil }
                if rva >= va, rva < va + max(rawSize, virtualSize) { return rva - va + raw }
            }
            return nil
        }
        guard let root = offset(resourceRVA) else { return nil }

        /// The entries of a resource directory: (id or -1 for a named one, offset of the target, is a directory).
        func entries(_ dir: Int) -> [(id: Int, target: Int, isDirectory: Bool)] {
            guard let named = u16(dir + 12), let ids = u16(dir + 14) else { return [] }
            return (0..<(named + ids)).compactMap { i in
                let e = dir + 16 + i * 8
                guard let name = u32(e), let data = u32(e + 4) else { return nil }
                return (name & 0x8000_0000 != 0 ? -1 : name, root + (data & 0x7FFF_FFFF), data & 0x8000_0000 != 0)
            }
        }
        /// The first leaf under a directory (any name, any language).
        func firstLeaf(_ dir: Int) -> Int? {
            guard let entry = entries(dir).first else { return nil }
            return entry.isDirectory ? firstLeaf(entry.target) : entry.target
        }
        func leafData(_ leaf: Int) -> ArraySlice<UInt8>? {
            guard let rva = u32(leaf), let size = u32(leaf + 4), let start = offset(rva), start + size <= b.count, size > 0 else { return nil }
            return b[start..<(start + size)]
        }

        let types = entries(root)
        guard let groupType = types.first(where: { $0.id == 14 && $0.isDirectory }),           // RT_GROUP_ICON
              let iconType = types.first(where: { $0.id == 3 && $0.isDirectory }),             // RT_ICON
              let groupLeaf = firstLeaf(groupType.target), let group = leafData(groupLeaf) else { return nil }
        let g = Array(group)
        guard g.count >= 6 else { return nil }
        let count = Int(g[4]) | Int(g[5]) << 8
        var best: (size: Int, depth: Int, id: Int, entry: ArraySlice<UInt8>)?
        for i in 0..<count {
            let e = 6 + i * 14
            guard e + 14 <= g.count else { break }
            let size = g[e] == 0 ? 256 : Int(g[e]), depth = Int(g[e + 6]) | Int(g[e + 7]) << 8
            let id = Int(g[e + 12]) | Int(g[e + 13]) << 8
            if best == nil || size > best!.size || (size == best!.size && depth > best!.depth) {
                best = (size, depth, id, g[e..<(e + 12)])
            }
        }
        guard let best, let iconDir = entries(iconType.target).first(where: { $0.id == best.id }),
              let leaf = iconDir.isDirectory ? firstLeaf(iconDir.target) : iconDir.target, let image = leafData(leaf) else { return nil }

        // ICONDIR + one ICONDIRENTRY (the group entry's first 12 bytes, then the image's offset) + the image.
        var ico = Data([0, 0, 1, 0, 1, 0])
        ico.append(contentsOf: best.entry.prefix(8))
        let length = UInt32(image.count)
        ico.append(contentsOf: withUnsafeBytes(of: length.littleEndian, Array.init))
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(22).littleEndian, Array.init))
        ico.append(contentsOf: image)
        return (ico, best.size)
    }
}
