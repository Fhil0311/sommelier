// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// A stamp of the game's version from the profile's `gameVersionFile`, so the app can tell that the game
/// updated since the mods went in: a patch moves the paths inside the archives and breaks the proxy's
/// signatures, so the mods page says the mods may not work until the framework updates. A small text file
/// (Hogwarts' `DA_Version.txt`) is the stamp as written; a program (RE4's `re4.exe`) is stamped by its size and
/// the hash of its first megabyte, which a patch always changes and which costs nothing to read.
public enum ModGameVersion {
    /// How much of a program is hashed.
    static let sampleBytes = 1 << 20
    /// A file up to this size is read as text.
    static let textBytes = 4096

    /// The stamp for the profile's file, nil when the profile names none or the file isn't there.
    public static func stamp(profile: ModProfile, roots: ModRoots) -> String? {
        guard let spec = profile.notes.gameVersionFile, let path = ModPath(spec), let url = roots.resolve(path) else { return nil }
        return stamp(of: url)
    }

    public static func stamp(of file: URL) -> String? {
        guard FileScan.isRegularFile(file), let size = (FileScan.attributes(file)?[.size] as? NSNumber)?.int64Value else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        if size <= textBytes, let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains("\0") { return trimmed }
            try? handle.seek(toOffset: 0)
        }
        guard let head = try? handle.read(upToCount: sampleBytes) else { return nil }
        let digest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        return "\(size):\(digest.prefix(16))"
    }

    /// Whether the game changed since `known` was stamped. Nothing known, or nothing to stamp, means no.
    public static func changed(since known: String?, profile: ModProfile, roots: ModRoots) -> Bool {
        guard let known, let now = stamp(profile: profile, roots: roots) else { return false }
        return now != known
    }
}
