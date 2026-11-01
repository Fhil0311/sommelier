// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Marks an engine's Wine loader as a game for macOS Game Mode.
///
/// gamepolicyd turns Game Mode on for a full-screen, focused process whose Info.plist has a games category. A game
/// runs from a hard link to the loader inside its shortcut app, and Launch Services reads the loader's own built-in
/// Info.plist (`__TEXT,__info_plist`) for it: CrossOver's has no category, so Wine games never got Game Mode.
/// Engines from the `loader-game-category` patch on carry the category; for earlier ones this writes it into the
/// section in place. In place, so the inode (and the shortcuts' hard links to it) stays; the section has spare
/// room because the linker pads it. Programs that run outside a shortcut app (Steam, launchers) are unaffected:
/// Launch Services doesn't take the built-in plist for them.
public enum LoaderGameLabel {
    static let category = "public.app-category.games"

    /// The loader processes run as (`bin/wine` only starts it).
    public static func loader(of engine: Engine) -> URL {
        engine.wineRoot.appendingPathComponent("lib/wine/x86_64-unix/wine")
    }

    /// Adds the category to the engine's loader (`on`) or takes it out (the player turned Game Mode off). True when
    /// the file changed; false when it already was so or couldn't be changed (not a plain Mach-O, signed, no room).
    /// Applies from the next program started.
    @discardableResult public static func set(_ on: Bool, for engine: Engine) -> Bool {
        set(on, loaderAt: loader(of: engine))
    }

    static func set(_ on: Bool, loaderAt url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let section = infoPlistSection(in: data) else { return false }
        guard let updated = labelled(plist: data[section], on: on) else { return false }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(section.lowerBound))
            try handle.write(contentsOf: updated)
            return true
        } catch { return false }
    }

    /// The plist bytes with the category added (or removed), padded to the same length; nil when it already is
    /// so, isn't a plist or wouldn't fit.
    static func labelled(plist bytes: Data, on: Bool = true) -> Data? {
        let trimmed = bytes.prefix { $0 != 0 }
        guard var plist = (try? PropertyListSerialization.propertyList(from: trimmed, format: nil)) as? [String: Any],
              (plist["LSApplicationCategoryType"] != nil) != on else { return nil }
        if on {
            plist["LSApplicationCategoryType"] = category
            plist["LSSupportsGameMode"] = true
        } else {
            plist["LSApplicationCategoryType"] = nil
            plist["LSSupportsGameMode"] = nil
        }
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              let text = String(data: xml, encoding: .utf8) else { return nil }
        // Whitespace between tags carries nothing: dropped so the result fits where the old plist was.
        let compact = text.replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression)
        var result = Data(compact.utf8)
        guard result.count <= bytes.count else { return nil }
        result.append(contentsOf: [UInt8](repeating: 0x0A, count: bytes.count - result.count))
        return result
    }

    /// Where `__TEXT,__info_plist` lies in a thin 64-bit Mach-O; nil for anything else, or when the file carries a
    /// code signature (a change would break it).
    static func infoPlistSection(in data: Data) -> Range<Int>? {
        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= data.count else { return nil }
            return data[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func name(_ at: Int) -> String? {
            guard at + 16 <= data.count else { return nil }
            return String(decoding: data[at..<at + 16].prefix { $0 != 0 }, as: UTF8.self)
        }
        guard u32(0) == 0xFEED_FACF, let commands = u32(16) else { return nil }       // MH_MAGIC_64
        var cursor = 32, found: Range<Int>?
        for _ in 0..<commands {
            guard let command = u32(cursor), let size = u32(cursor + 4), size >= 8 else { return nil }
            if command == 0x1D { return nil }                                             // LC_CODE_SIGNATURE
            if command == 0x19, name(cursor + 8) == "__TEXT", let sections = u32(cursor + 64) {   // LC_SEGMENT_64
                var section = cursor + 72
                for _ in 0..<sections {
                    if name(section) == "__info_plist", let offset = u32(section + 48), let length = u32(section + 32) {
                        let range = Int(offset)..<Int(offset) + Int(length)
                        if range.upperBound <= data.count { found = range }
                    }
                    section += 80
                }
            }
            cursor += Int(size)
        }
        return found
    }
}
