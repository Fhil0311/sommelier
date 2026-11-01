// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What Sommelier needs to know about a Windows executable: the CPU it's built for and the DLLs it links.
/// Reads only the headers and import tables, a few kilobytes even for a game binary of several gigabytes.
public struct PEImage: Sendable, Equatable {
    /// The COFF machine type.
    public enum Machine: Sendable, Equatable {
        case i386, x86_64, arm64, other(UInt16)

        init(_ code: UInt16) {
            let known: [UInt16: Machine] = [0x014c: .i386, 0x8664: .x86_64, 0xaa64: .arm64]
            self = known[code] ?? .other(code)
        }
    }

    public let machine: Machine
    /// DLL names (lowercased) from both the normal and the delay-load import tables.
    public let imports: Set<String>

    public var is64Bit: Bool { [.x86_64, .arm64].contains(machine) }

    /// Whether the executable links `dll`, compared without regard to case.
    public func imports(_ dll: String) -> Bool { imports.contains(dll.lowercased()) }

    /// Reads the file at `url`; nil when it can't be opened or isn't a PE image.
    public init?(url: URL) {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        self.init(source: { start, length in
            do {
                try file.seek(toOffset: UInt64(start))
                return try file.read(upToCount: length)
            } catch {
                return nil
            }
        })
    }

    /// Parses an image already in memory.
    public init?(data: Data) {
        self.init(source: { start, length in
            guard (0..<data.count).contains(start) else { return nil }
            let from = data.index(data.startIndex, offsetBy: start)
            let to = data.index(from, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            return data[from..<to]
        })
    }

    /// `source(offset, length)` returns up to `length` bytes at a file offset, or nil past the end.
    private init?(source: (Int, Int) -> Data?) {
        guard let layout = Layout(source: source) else { return nil }
        var found: Set<String> = []
        // Import directory (index 1): 20-byte entries, DLL name RVA at offset 12, a zero name ends the table.
        if let table = layout.directoryOffset(1) {
            layout.walk(table, entrySize: 20, source: source) { entry in
                guard let rva = entry.littleEndian(at: 12, bytes: 4), rva != 0 else { return false }
                if let name = layout.cString(atRVA: rva, source: source) { found.insert(name) }
                return true
            }
        }
        // Delay-load directory (index 13): 32-byte entries, name at offset 4. Bit 0 of the attributes says the
        // name is an RVA; old linkers wrote a full virtual address instead.
        if let table = layout.directoryOffset(13) {
            layout.walk(table, entrySize: 32, source: source) { entry in
                guard let attributes = entry.littleEndian(at: 0, bytes: 4),
                      let address = entry.littleEndian(at: 4, bytes: 4), address != 0 else { return false }
                let rva = attributes & 1 == 1 ? address : address - layout.loadAddress
                if let name = layout.cString(atRVA: rva, source: source) { found.insert(name) }
                return true
            }
        }
        machine = Machine(UInt16(truncatingIfNeeded: layout.machine))
        imports = found
    }

    /// The header fields the import scan needs, plus the section map for turning RVAs into file offsets.
    private struct Layout {
        struct Section { let address: Int, length: Int, fileOffset: Int }

        let machine: Int
        let loadAddress: Int
        let directories: [Int]       // RVA of each data directory, 0 when absent
        let sections: [Section]

        init?(source: (Int, Int) -> Data?) {
            // DOS header: "MZ", and the offset of the PE header at 0x3c (sanity-capped at 16 MB).
            guard let stub = source(0, 64), stub.count == 64, stub.starts(with: [0x4d, 0x5a]),
                  let peStart = stub.littleEndian(at: 0x3c, bytes: 4), peStart < 1 << 24 else { return nil }
            // "PE\0\0", the 20-byte COFF header, then the optional header with up to 16 data directories.
            guard let header = source(peStart, 264), header.starts(with: [0x50, 0x45, 0, 0]),
                  let machine = header.littleEndian(at: 4, bytes: 2),
                  let sectionCount = header.littleEndian(at: 6, bytes: 2),
                  let optionalLength = header.littleEndian(at: 20, bytes: 2),
                  let magic = header.littleEndian(at: 24, bytes: 2) else { return nil }

            let optional = 24
            let base: Int?
            let directoryCountAt: Int
            switch magic {
            case 0x20b:                                                   // PE32+
                base = header.littleEndian(at: optional + 24, bytes: 8)
                directoryCountAt = optional + 108
            case 0x10b:                                                   // PE32
                base = header.littleEndian(at: optional + 28, bytes: 4)
                directoryCountAt = optional + 92
            default:
                return nil
            }
            guard let base else { return nil }
            let directoryCount = header.littleEndian(at: directoryCountAt, bytes: 4) ?? 0
            directories = (0..<16).map { index in
                index < directoryCount ? header.littleEndian(at: directoryCountAt + 4 + index * 8, bytes: 4) ?? 0 : 0
            }

            guard (1..<200).contains(sectionCount),
                  let table = source(peStart + 24 + optionalLength, sectionCount * 40),
                  table.count == sectionCount * 40 else { return nil }
            sections = stride(from: 0, to: table.count, by: 40).compactMap { at in
                guard let virtualSize = table.littleEndian(at: at + 8, bytes: 4),
                      let address = table.littleEndian(at: at + 12, bytes: 4),
                      let rawSize = table.littleEndian(at: at + 16, bytes: 4),
                      let rawStart = table.littleEndian(at: at + 20, bytes: 4) else { return nil }
                return Section(address: address, length: max(virtualSize, rawSize), fileOffset: rawStart)
            }
            self.machine = machine
            loadAddress = base
        }

        func fileOffset(ofRVA rva: Int) -> Int? {
            let containing = sections.first { (($0.address)..<($0.address + $0.length)).contains(rva) }
            guard let section = containing else { return nil }
            return section.fileOffset + (rva - section.address)
        }

        func directoryOffset(_ index: Int) -> Int? {
            guard directories.indices.contains(index), directories[index] != 0 else { return nil }
            return fileOffset(ofRVA: directories[index])
        }

        /// Hands `visit` up to 1024 fixed-size table entries in turn, until one can't be read whole or `visit`
        /// returns false (the table's terminating entry).
        func walk(_ start: Int, entrySize: Int, source: (Int, Int) -> Data?, visit: (Data) -> Bool) {
            var next = start
            for _ in 0..<1024 {
                guard let entry = source(next, entrySize), entry.count == entrySize, visit(entry) else { return }
                next += entrySize
            }
        }

        /// A NUL-terminated name of at most 255 bytes, lowercased; nil when empty or unterminated.
        func cString(atRVA rva: Int, source: (Int, Int) -> Data?) -> String? {
            guard let offset = fileOffset(ofRVA: rva), let bytes = source(offset, 256),
                  let nul = bytes.firstIndex(of: 0), nul != bytes.startIndex else { return nil }
            return String(decoding: bytes[..<nul], as: UTF8.self).lowercased()
        }
    }
}

private extension Data {
    /// An unsigned little-endian integer of `bytes` bytes at `offset` from the start of this data.
    func littleEndian(at offset: Int, bytes: Int) -> Int? {
        guard offset >= 0, offset + bytes <= count else { return nil }
        let first = index(startIndex, offsetBy: offset)
        return self[first..<index(first, offsetBy: bytes)].reversed().reduce(0) { $0 << 8 | Int($1) }
    }
}
