// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage
import SommelierKit
import Observation
import SwiftUI

/// Covers, heroes and logos: fetched once and kept on disk (as Steam keeps its library cache), decoded no larger
/// than the view that shows them, and held in memory up to a budget so a big library doesn't grow the app
/// without bound. Each image's main colour is worked out once (game pages and the sidebar take their tint from it).
@MainActor @Observable
final class ArtworkStore {
    /// Changes whenever an image arrives; views that show images read it through `image(_:)` and re-render.
    private(set) var generation = 0
    private(set) var tints: [URL: Color] = [:]
    /// Loads that gave up (a 404, say): there is no image to wait for.
    private(set) var failedCount = 0

    @ObservationIgnored private let disk: ArtworkCache
    @ObservationIgnored private let memory = NSCache<NSURL, Entry>()
    /// Loads under way, with the largest size tier asked for while they ran.
    @ObservationIgnored private var loading: [URL: Int] = [:]
    @ObservationIgnored private var failed: Set<URL> = []
    @ObservationIgnored private var savedTints: [String: [Double]]
    @ObservationIgnored private var tintSave: Task<Void, Never>?

    final class Entry {
        let image: NSImage
        let tier: Int
        let capped: Bool                                              // smaller than the file: a bigger tier has more
        init(image: NSImage, tier: Int, capped: Bool) { self.image = image; self.tier = tier; self.capped = capped }
    }

    /// Decoded images kept in memory at most; beyond it the least recently shown go, to come back from disk.
    static let memoryBudget = 192 * 1024 * 1024
    static let fullTier = 2048

    init(directory: URL) {
        disk = ArtworkCache(directory: directory)
        memory.totalCostLimit = Self.memoryBudget
        savedTints = disk.loadTints()
        for (key, rgb) in savedTints where rgb.count == 3 { tintsByKey[key] = Self.wash((rgb[0], rgb[1], rgb[2])) }
        let disk = self.disk
        Task.detached(priority: .background) { disk.prune() }
    }

    @ObservationIgnored private var tintsByKey: [String: Color] = [:]

    /// The image, decoded for a view `pixels` across (its long side, in pixels). Nil while it loads; asking
    /// starts the load, so a view needs no separate `onAppear` for it.
    func image(_ url: URL?, pixels: Double = Double(fullTier)) -> NSImage? {
        _ = generation
        guard let url else { return nil }
        let tier = ArtworkCache.tier(forPixels: pixels)
        if let entry = memory.object(forKey: url as NSURL) {
            if entry.capped, entry.tier < tier { load(url, tier: tier) }  // shown bigger now: fetch the detail
            return entry.image
        }
        load(url, tier: tier)
        return nil
    }

    func tint(_ url: URL?) -> Color? {
        guard let url else { return nil }
        return tints[url] ?? tintsByKey[disk.tintKey(for: url)]
    }

    func hasFailed(_ url: URL?) -> Bool {
        _ = failedCount                                               // views asking re-render when a load gives up
        return url.map { failed.contains($0) } ?? true
    }

    /// Starts fetching (or decoding) the image so it is ready when a view asks.
    func load(_ url: URL?, pixels: Double = Double(fullTier)) {
        guard let url else { return }
        load(url, tier: ArtworkCache.tier(forPixels: pixels))
    }

    private func load(_ url: URL, tier: Int) {
        guard !failed.contains(url) else { return }
        if let running = loading[url] { if tier > running { loading[url] = tier }; return }
        if let entry = memory.object(forKey: url as NSURL), !(entry.capped && entry.tier < tier) { return }
        loading[url] = tier
        let disk = self.disk
        let needsTint = tint(url) == nil
        Task {
            var data = await Task.detached(priority: .userInitiated) { url.isFileURL ? try? Data(contentsOf: url) : disk.data(for: url) }.value
            var rgb: (Double, Double, Double)?
            if data == nil, !url.isFileURL, let fetched = await Self.fetch(url, tint: needsTint) {
                data = fetched.0
                rgb = fetched.1
                await Task.detached(priority: .utility) { disk.store(fetched.0, for: url) }.value
            } else if let data, needsTint {
                rgb = await Task.detached(priority: .utility) { Self.backgroundTint(of: data) }.value
            }
            guard let data else { finish(url, failed: true); return }
            if let rgb { setTint(rgb, for: url) }
            var decodeTier = loading[url] ?? tier
            while true {
                let limit = decodeTier
                guard let decoded = await Task.detached(priority: .userInitiated) { ArtworkCache.decode(data, maxPixelSize: limit) }.value else {
                    finish(url, failed: true); return
                }
                let image = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
                memory.setObject(Entry(image: image, tier: limit, capped: decoded.capped), forKey: url as NSURL,
                                 cost: decoded.image.bytesPerRow * decoded.image.height)
                generation += 1
                let wanted = loading[url] ?? limit                    // a bigger view asked while decoding
                guard decoded.capped, wanted > limit else { break }
                decodeTier = wanted
            }
            finish(url, failed: false)
        }
    }

    private func finish(_ url: URL, failed didFail: Bool) {
        loading[url] = nil
        if didFail { failed.insert(url); failedCount += 1 }
    }

    private func setTint(_ rgb: (Double, Double, Double), for url: URL) {
        let color = Self.wash(rgb)
        tints[url] = color
        let key = disk.tintKey(for: url)
        tintsByKey[key] = color
        savedTints[key] = [rgb.0, rgb.1, rgb.2]
        tintSave?.cancel()
        let snapshot = savedTints, disk = self.disk
        tintSave = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            disk.saveTints(snapshot)
        }
    }

    /// The page wash from an art colour: its hue and saturation at a fixed 22% lightness (HSL), as on the site,
    /// so bright art (a yellow cover) can't light up the page. Applied when shown, so saved tints follow too.
    nonisolated static func wash(_ rgb: (Double, Double, Double)) -> Color {
        let (r, g, b) = rgb
        let high = max(r, g, b), low = min(r, g, b), l = (high + low) / 2, d = high - low
        guard d > 0.0001 else { return Color(red: 0.22, green: 0.22, blue: 0.22) }
        let s = min(1, d / (1 - abs(2 * l - 1)))
        var h: Double
        if high == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if high == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        let lightness = 0.22
        let c = (1 - abs(2 * lightness - 1)) * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = lightness - c / 2
        let (r1, g1, b1): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return Color(red: r1 + m, green: g1 + m, blue: b1 + m)
    }

    nonisolated static func fetch(_ url: URL, tint: Bool) async -> (Data, (Double, Double, Double)?)? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200, !data.isEmpty else { return nil }
        return (data, tint ? backgroundTint(of: data) : nil)
    }

    /// The image's average colour, darkened and slightly saturated so white text stays readable on it.
    nonisolated static func backgroundTint(of data: Data) -> (Double, Double, Double)? {
        guard let image = CIImage(data: data),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image,
                                                                       kCIInputExtentKey: CIVector(cgRect: image.extent)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()])
            .render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8, colorSpace: nil)
        let ns = NSColor(srgbRed: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let tinted = NSColor(hue: h, saturation: min(1, s * 1.25 + 0.1), brightness: min(0.42, max(0.18, b * 0.6)), alpha: 1)
        return (Double(tinted.redComponent), Double(tinted.greenComponent), Double(tinted.blueComponent))
    }
}

/// A cover or hero image, with a titled placeholder while it loads or when the store has none.
struct Artwork: View {
    @Environment(ArtworkStore.self) private var store
    @Environment(\.displayScale) private var scale
    let url: URL?
    let title: String
    var titleOnPlaceholder = true
    /// A wide image to build a stand-in from when there is no image at `url` (Steam's header capsule): Steam's
    /// library does the same for games without a cover.
    var fallback: URL? = nil
    /// The frame's long side in points, so the image is decoded no larger than it is shown.
    @State private var points: Double = 0

    var body: some View {
        // The image fills whatever frame it is given and never widens it (a bare scaledToFill image would).
        Color.clear
            .overlay {
                if points > 0, let image = store.image(url, pixels: points * scale) {   // decoded for this frame's size
                    Image(nsImage: image).resizable().scaledToFill()
                } else if points > 0, store.hasFailed(url), let fallback, let wide = store.image(fallback, pixels: points * scale) {
                    standIn(wide)
                } else {
                    Theme.placeholder
                    if titleOnPlaceholder {
                        Text(title)
                            .font(.headline)
                            .multilineTextAlignment(.center).foregroundStyle(Theme.onDark.opacity(0.6)).padding(12)
                    }
                }
            }
            .clipped()
            .onGeometryChange(for: Double.self) { max($0.size.width, $0.size.height) } action: { points = $0 }
    }

    /// The wide image on a blurred, darkened copy of itself, with the title under it. Sized by the frame it is
    /// given (the images never widen it, as with the cover itself).
    private func standIn(_ wide: NSImage) -> some View {
        Color.clear
            .overlay { Image(nsImage: wide).resizable().scaledToFill().blur(radius: 24, opaque: true) }
            .overlay(.black.opacity(0.45))
            .overlay {
                VStack(spacing: points > 120 ? 10 : 4) {
                    Image(nsImage: wide).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: points > 120 ? 4 : 2, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                    if titleOnPlaceholder {
                        Text(title).font(.headline).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
                .padding(.horizontal, points > 120 ? 12 : 3)
            }
            .clipped()
        .accessibilityLabel(title)
    }
}
