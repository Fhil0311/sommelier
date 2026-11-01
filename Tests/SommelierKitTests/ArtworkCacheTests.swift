// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SommelierKit

@Suite struct ArtworkCacheTests {
    /// A 600×900 PNG, like a Steam cover.
    static func cover() -> Data {
        let context = CGContext(data: nil, width: 600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @Test func storesAndReadsBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkCache(directory: dir)
        let url = URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/945360/library_600x900.jpg")!
        #expect(!cache.has(url))
        let data = Self.cover()
        cache.store(data, for: url)
        #expect(cache.has(url))
        #expect(cache.data(for: url) == data)
        #expect(cache.file(for: url).pathExtension == "jpg")
        #expect(cache.file(for: url) == cache.file(for: url))                    // same name every time
        #expect(cache.file(for: URL(string: "https://example.com/a")!).pathExtension == "img")
    }

    @Test func decodesDownToTheTier() throws {
        let data = Self.cover()
        let small = try #require(ArtworkCache.decode(data, maxPixelSize: 512))
        #expect(small.image.height == 512 && small.image.width == 341 && small.capped)
        let full = try #require(ArtworkCache.decode(data, maxPixelSize: 2048))
        #expect(full.image.height == 900 && full.image.width == 600 && !full.capped)
        #expect(ArtworkCache.decode(Data("not an image".utf8), maxPixelSize: 512) == nil)
    }

    @Test func tiers() {
        #expect(ArtworkCache.tier(forPixels: 300) == 512)
        #expect(ArtworkCache.tier(forPixels: 512) == 512)
        #expect(ArtworkCache.tier(forPixels: 700) == 1024)
        #expect(ArtworkCache.tier(forPixels: 2400) == 2048)
    }

    @Test func tintsRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkCache(directory: dir)
        #expect(cache.loadTints().isEmpty)
        cache.saveTints(["a.jpg": [0.1, 0.2, 0.3]])
        #expect(cache.loadTints() == ["a.jpg": [0.1, 0.2, 0.3]])
    }

    @Test func prunesOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkCache(directory: dir)
        let old = URL(string: "https://example.com/old.jpg")!, new = URL(string: "https://example.com/new.jpg")!
        cache.store(Data(count: 1000), for: old)
        let yesterday = timeval(tv_sec: Int(Date().timeIntervalSince1970) - 86_400, tv_usec: 0)
        var times = [yesterday, yesterday]                                      // accessed and modified yesterday
        #expect(utimes(cache.file(for: old).path, &times) == 0)
        cache.store(Data(count: 1000), for: new)
        cache.prune(limit: 1500)
        #expect(!cache.has(old))
        #expect(cache.has(new))
    }
}
