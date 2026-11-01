// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import ImageIO

/// Covers, heroes and logos on disk, as Steam keeps its `librarycache`: downloaded once, read from disk from
/// then on, and decoded no larger than the view that shows them needs.
public struct ArtworkCache: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Where the image at `url` lives on disk, whether or not it has been fetched yet.
    public func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = ["jpg", "jpeg", "png", "webp", "gif"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "img"
        return directory.appendingPathComponent("\(digest).\(ext)")
    }

    public func has(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: file(for: url).path) }

    public func data(for url: URL) -> Data? { try? Data(contentsOf: file(for: url)) }

    public func store(_ data: Data, for url: URL) {
        try? data.write(to: file(for: url), options: .atomic)
    }

    /// The image decoded with its long side no larger than `maxPixelSize`: a card's cover needn't fill the
    /// memory a full-size one does. Returns the image and whether the limit cut it down.
    public static func decode(_ data: Data, maxPixelSize: Int) -> (image: CGImage, capped: Bool)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var capped = false
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
            capped = max(width, height) > maxPixelSize
        }
        return (image, capped)
    }

    /// The size tier to decode at for a view `pixels` across: a few steps, so the same image isn't decoded
    /// again for every slightly different frame.
    public static func tier(forPixels pixels: Double) -> Int {
        pixels <= 512 ? 512 : pixels <= 1024 ? 1024 : 2048
    }

    // MARK: Tints

    /// Each image's main colour, kept beside the files so it is worked out once per image, not once per launch.
    public var tintsFile: URL { directory.appendingPathComponent("Tints.json") }

    public func loadTints() -> [String: [Double]] {
        (try? JSONDecoder().decode([String: [Double]].self, from: Data(contentsOf: tintsFile))) ?? [:]
    }

    public func saveTints(_ tints: [String: [Double]]) {
        if let data = try? JSONEncoder().encode(tints) { try? data.write(to: tintsFile, options: .atomic) }
    }

    public func tintKey(for url: URL) -> String { file(for: url).lastPathComponent }

    // MARK: Housekeeping

    /// Keeps the folder under `limit` bytes by removing the images not opened for longest.
    public func prune(limit: Int = 500 * 1024 * 1024) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(URL, Int, Date)] = []
        for file in files where file.lastPathComponent != "Tints.json" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let used = values?.contentAccessDate ?? values?.contentModificationDate ?? .distantPast
            entries.append((file, values?.fileSize ?? 0, used))
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        for (file, size, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}
