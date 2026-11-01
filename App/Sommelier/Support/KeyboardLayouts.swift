// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Carbon.HIToolbox
import Foundation

/// The keyboard layouts the player has turned on in macOS (System Settings › Keyboard › Input Sources), read into
/// rows of letters for the on-screen keyboard: each key is what that layout types on the Mac's own key there.
enum KeyboardLayouts {
    struct Layout: Identifiable, Equatable {
        let id: String
        let name: String
        let rows: [[String]]
        /// The language the layout is for ("ru", "en"), for voice search.
        var language: String?
    }

    /// The Mac's letter keys, row by row, by virtual key code (the ANSI positions: Q W E … [ ], A S D … ; ', Z X C … , .).
    static let keyRows: [[UInt16]] = [
        [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47],
    ]

    /// Every enabled keyboard layout, the one in use first; plain QWERTY when none can be read.
    static func enabled() -> [Layout] {
        let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
                      kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [qwerty] }
        let current = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let currentID = current.flatMap { string($0, kTISPropertyInputSourceID) }
        var layouts: [Layout] = []
        for source in list {
            guard let id = string(source, kTISPropertyInputSourceID), let name = string(source, kTISPropertyLocalizedName),
                  let rows = rows(of: source), !layouts.contains(where: { $0.rows == rows }) else { continue }
            let languages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages)
                .map { Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String] ?? [] } ?? []
            layouts.append(Layout(id: id, name: name, rows: rows, language: languages.first))
        }
        if let index = layouts.firstIndex(where: { $0.id == currentID }) { layouts.insert(layouts.remove(at: index), at: 0) }
        return layouts.isEmpty ? [qwerty] : layouts
    }

    static let qwerty = Layout(id: "qwerty", name: "English", rows: ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }, language: "en")

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    /// The letters a layout types on the letter keys; nil for one that types none (an input method's helper).
    private static func rows(of source: TISInputSource) -> [[String]]? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let rows: [[String]] = data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [] }
            return keyRows.map { row in
                row.compactMap { code -> String? in
                    var dead: UInt32 = 0
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { return nil }
                    let text = String(utf16CodeUnits: chars, count: length)
                    return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty ? nil : text
                }
            }
        }
        // Letters only count when the main rows have them (a layout of symbols alone isn't useful for a search).
        let letters = rows.joined().filter { $0.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) } }
        return letters.count >= 20 ? rows : nil
    }
}
