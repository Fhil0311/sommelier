// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Which processors a Mac program is built for, from its file header. Stores other than Steam don't say whether a
/// Mac version is 64-bit, and a 32-bit one hasn't run since macOS 10.15, so a downloaded Mac version is checked.
public enum MachO {
    public enum Arch: String, Sendable { case arm64, x86_64, i386, ppc, other }

    /// The architectures in `file` (one for a plain binary, several for a universal one); empty when it isn't
    /// a Mach-O file.
    public static func architectures(of file: URL) -> Set<Arch> {
        guard let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 4096),
              data.count >= 8 else { return [] }
        return architectures(in: [UInt8](data))
    }

    static func architectures(in bytes: [UInt8]) -> Set<Arch> {
        func be32(_ i: Int) -> UInt32 { UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3]) }
        func le32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24 }
        guard bytes.count >= 8 else { return [] }
        switch be32(0) {
        case 0xCAFE_BABE:                                            // universal: a table of (cputype, subtype, offset, size, align)
            let count = Int(be32(4))
            guard count < 32, bytes.count >= 8 + count * 20 else { return [] }
            return Set((0..<count).map { arch(cputype: be32(8 + $0 * 20)) })
        case 0xFEED_FACF, 0xFEED_FACE:                               // big-endian 64/32-bit
            return [arch(cputype: be32(4))]
        default: break
        }
        switch le32(0) {
        case 0xFEED_FACF, 0xFEED_FACE: return [arch(cputype: le32(4))]
        default: return []
        }
    }

    private static func arch(cputype: UInt32) -> Arch {
        switch cputype {
        case 0x0100_000C: .arm64
        case 0x0100_0007: .x86_64
        case 0x0000_0007: .i386
        case 0x0000_0012, 0x0100_0012: .ppc
        default: .other
        }
    }

    /// What the architectures mean for running the program on an Apple Silicon Mac today.
    public static func build(for archs: Set<Arch>) -> MacBuild {
        if archs.contains(.arm64) { return .appleSilicon }
        if archs.contains(.x86_64) { return .intel }
        return .legacy32
    }
}
