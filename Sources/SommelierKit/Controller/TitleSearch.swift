// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Finding games by what was typed or said: every word in the title, in any order; failing that, words that sound
/// alike. Speech gets titles wrong in ways spelling doesn't ("киберпанк" for Cyberpunk, "eldon ring" for Elden
/// Ring), so the near match compares words in Latin letters and forgives a letter or two per word.
public enum TitleSearch {
    /// The titles that match `query`, best first.
    public static func matches<T>(_ query: String, in items: [T], title: (T) -> String) -> [T] {
        let words = normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let exact = items.filter { item in
            let t = normalized(title(item))
            return words.allSatisfy { t.contains($0) }
        }
        if !exact.isEmpty { return exact }
        // Near: each spoken word close to some word of the title; ranked by how close.
        var scored: [(T, Int)] = []
        for item in items {
            let titleWords = normalized(title(item)).split(separator: " ").map { sound(String($0)) }
            var total = 0
            var all = true
            for word in words.map(sound) {
                let best = titleWords.map { distance(word, $0, prefix: true) }.min() ?? 99
                if best > allowed(word) { all = false; break }
                total += best
            }
            if all { scored.append((item, total)) }
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Letters that sound the same, made the same: "kiberpank" and "cyberpunk" both become "kiberpunk"-like.
    static func sound(_ word: String) -> String {
        var w = word
        for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "kv"), ("x", "ks"), ("c", "k"), ("y", "i"), ("w", "v"), ("j", "i"), ("z", "s")] {
            w = w.replacingOccurrences(of: from, with: to)
        }
        return w
    }

    /// How many letters may differ: none for short words, one for five or more, two for eight or more.
    static func allowed(_ word: String) -> Int { word.count >= 8 ? 2 : word.count >= 5 ? 1 : 0 }

    /// Lowercase, Latin letters (Cyrillic transliterated), digits and spaces only; "III" read as 3.
    public static func normalized(_ text: String) -> String {
        var out = text.lowercased().applyingTransform(.toLatin, reverse: false) ?? text.lowercased()
        out = out.applyingTransform(.stripDiacritics, reverse: false) ?? out
        out = out.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        let numerals = ["ii": "2", "iii": "3", "iv": "4", "two": "2", "three": "3", "four": "4", "dva": "2", "tri": "3", "chetyre": "4"]
        return out.split(separator: " ").map { numerals[String($0)] ?? String($0) }.joined(separator: " ")
    }

    /// Edit distance; with `prefix`, the title word may run on past the spoken one ("witch" against "witcher").
    static func distance(_ a: String, _ b: String, prefix: Bool) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return prefix ? (row.min() ?? row[b.count]) : row[b.count]
    }
}
