// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Unreal Engine's save files (`GVAS`), as far as a recipe needs them: whole-number values inside one struct of the
/// file's top-level properties, set or added. Some games keep their options there rather than in an ini
/// (Expedition 33: `SharedGameUserSettings.sav`, the quality levels in `EngineSettingsData`), and apply them over
/// the ini when they start.
///
/// The property tags are Unreal 5.5's: name, a type-name tree, a 32-bit size, a flags byte (1: an array index
/// follows, 2: a GUID follows, 16: a true bool), then the payload. A struct's payload is a list of tags ending
/// with "None". Everything else in the file (the header, other properties) is left as it is.
public enum UnrealSave {
    static let magic = Data("GVAS".utf8)

    /// `data` with the named ints set in the named top-level struct. Nil when the file isn't a save, has no such
    /// struct, or the struct can't be read through to its end (then nothing is touched).
    public static func settingInts(_ data: Data, inStruct structName: String, values: [String: Int32]) -> Data? {
        guard data.starts(with: magic), !values.isEmpty, let tag = findStructTag(named: structName, in: data) else { return nil }
        var payload = data.subdata(in: tag.payload)
        var changed = false
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let entries = parseList(payload) else { return nil }
            if let existing = entries.first(where: { $0.name == name }) {
                guard existing.type == "IntProperty", existing.payload.count == 4 else { return nil }
                guard payload.subdata(in: existing.payload) != int32(value) else { continue }
                payload.replaceSubrange(existing.payload, with: int32(value))
            } else {
                payload.insert(contentsOf: intTag(name: name, value: value), at: entries.last?.end ?? payload.count - noneTag.count)
            }
            changed = true
        }
        guard changed else { return data }
        var out = data
        out.replaceSubrange(tag.payload, with: payload)
        out.replaceSubrange(tag.sizeAt..<tag.sizeAt + 4, with: int32(Int32(payload.count)))
        return out
    }

    /// The ints a struct holds, by name (for checks).
    public static func ints(_ data: Data, inStruct structName: String) -> [String: Int32]? {
        guard let tag = findStructTag(named: structName, in: data), let entries = parseList(data.subdata(in: tag.payload)) else { return nil }
        var out: [String: Int32] = [:]
        let payload = data.subdata(in: tag.payload)
        for entry in entries where entry.type == "IntProperty" && entry.payload.count == 4 {
            out[entry.name] = payload.subdata(in: entry.payload).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        }
        return out
    }

    // MARK: Encoding

    static func string(_ s: String) -> Data {
        var out = int32(Int32(s.utf8.count + 1))
        out.append(contentsOf: Array(s.utf8)); out.append(0)
        return out
    }
    static func int32(_ v: Int32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static let noneTag = string("None")

    /// `Name` IntProperty (no inner types), size 4, no flags, the value.
    static func intTag(name: String, value: Int32) -> Data {
        string(name) + string("IntProperty") + int32(0) + int32(4) + Data([0]) + int32(value)
    }

    // MARK: Reading

    struct Entry { var name: String; var type: String; var start: Int; var payload: Range<Int>; var end: Int }

    static func readString(_ d: Data, _ o: inout Int) -> String? {
        guard o + 4 <= d.count else { return nil }
        let n = Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard n >= 1, n <= 4096, o + 4 + n <= d.count, d[d.startIndex + o + 4 + n - 1] == 0 else { return nil }
        let s = String(decoding: d.subdata(in: o + 4..<o + 4 + n - 1), as: UTF8.self)
        o += 4 + n
        return s
    }

    /// Skips a type-name tree: a name, a count, that many trees.
    static func skipType(_ d: Data, _ o: inout Int) -> String? {
        guard let name = readString(d, &o), o + 4 <= d.count else { return nil }
        let n = Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }); o += 4
        guard n >= 0, n <= 8 else { return nil }
        for _ in 0..<n { guard skipType(d, &o) != nil else { return nil } }
        return name
    }

    /// One tag at `o` (relative to `d`); nil for "None" (then `o` is past it) or anything unreadable.
    static func readTag(_ d: Data, _ o: inout Int) -> Entry?? {
        let start = o
        guard let name = readString(d, &o) else { return nil }
        if name == "None" { return .some(nil) }
        guard let type = skipType(d, &o), o + 5 <= d.count else { return nil }
        let size = Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }); o += 4
        let flags = d[d.startIndex + o]; o += 1
        if flags & 1 != 0 { o += 4 }
        if flags & 2 != 0 { o += 16 }
        guard size >= 0, o + size <= d.count else { return nil }
        let entry = Entry(name: name, type: type, start: start, payload: o..<o + size, end: o + size)
        o += size
        return .some(entry)
    }

    /// A struct's payload as its tags, when it reads cleanly through to "None" at its very end.
    static func parseList(_ payload: Data) -> [Entry]? {
        var o = 0, out: [Entry] = []
        while o < payload.count {
            guard let tag = readTag(payload, &o) else { return nil }
            guard let entry = tag else { return o == payload.count ? out : nil }
            out.append(entry)
        }
        return nil
    }

    struct StructTag { var sizeAt: Int; var payload: Range<Int> }

    /// The top-level StructProperty tag with this name: its bytes start with the name string followed by the
    /// "StructProperty" string, which no other kind of data in a save has.
    static func findStructTag(named name: String, in data: Data) -> StructTag? {
        let pattern = string(name) + string("StructProperty")
        var from = data.startIndex
        while let range = data.range(of: pattern, in: from..<data.endIndex) {
            var o = range.lowerBound - data.startIndex
            if let read = readTag(data, &o), let entry = read, entry.type == "StructProperty" {
                // The size sits right after the type tree.
                var p = range.lowerBound - data.startIndex
                _ = readString(data, &p); _ = skipType(data, &p)
                if parseList(data.subdata(in: entry.payload)) != nil { return StructTag(sizeAt: p, payload: entry.payload) }
            }
            from = range.upperBound
        }
        return nil
    }
}
