// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ImageIO
import SommelierKit
import UniformTypeIdentifiers

/// Every installed Windows game has a shortcut app in ~/Applications/Sommelier Games with the game's own icon
/// (its Steam icon, or the one in its .exe; the cover when it has none big enough).
/// Clicking it starts the game through Sommelier; while the game runs, the engine runs it from inside the shortcut
/// (`AppNames`), so the Dock shows the game by name and cover, and it can be kept in the Dock like any app.
extension AppModel {
    /// Makes missing shortcuts, gives covers to ones made before their art loaded, removes those of games no longer
    /// installed, and writes the engine's names table with them.
    func syncShortcuts() async {
        ShortcutApp.microphoneReason = String(localized: "Games with voice chat use the microphone.")
        let folder = ShortcutApp.defaultFolder
        let games = library.games.filter { $0.isInstalled && !$0.isNative }
        var apps: [String: URL] = [:]
        for game in games {
            let app = ShortcutApp.appURL(title: game.title, in: folder)
            let source = app.appendingPathComponent("Contents/Resources/AppIcon.source")
            let done = (try? String(contentsOf: source, encoding: .utf8)) == "official"
            let ours = ShortcutApp.existingGameID(at: app)
            if ours != nil, ours != game.id { continue }           // another game's shortcut has this name
            if ours == game.id, done || isActive(game) { apps[game.id] = app; continue }
            // Looking for a better icon (the store's, or the game's own programs) is slow: once per run per game,
            // not on every Steam start.
            if ours == game.id, shortcutsTried.contains(game.id) { apps[game.id] = app; continue }
            shortcutsTried.insert(game.id)
            // Already there with the cover: try for the official icon again, else keep it as it is.
            let official = await officialIcon(for: game)
            if ours == game.id, official == nil, FileManager.default.fileExists(atPath: source.path) { apps[game.id] = app; continue }
            var icon = official
            if icon == nil { icon = await coverIcon(for: game) }
            if let made = try? ShortcutApp.create(title: game.title, gameID: game.id, in: folder, icon: icon) {
                apps[game.id] = made
                if icon != nil {
                    try? (official != nil ? "official" : "cover").write(to: made.appendingPathComponent("Contents/Resources/AppIcon.source"),
                                                                       atomically: true, encoding: .utf8)
                }
            }
            if let icon { try? FileManager.default.removeItem(at: icon) }
        }
        for app in apps.values where ShortcutApp.updateInfo(at: app) {
            LSRegisterURL(app as CFURL, true)       // so macOS reads the new reason when the game asks
        }
        let keep = Set(apps.values.map(\.standardizedFileURL))
        for app in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where app.pathExtension == "app" && ShortcutApp.existingGameID(at: app) != nil && !keep.contains(app.standardizedFileURL) {
            try? FileManager.default.removeItem(at: app)
        }
        let names = AppNames(paths: paths), all = library.games
        await Task.detached(priority: .utility) { names.update(all, apps: apps) }.value
        await updateRedirects()
    }

    /// The game's own icon as a macOS icon, when one of at least 128 pixels exists: Steam's for a Steam game,
    /// else the largest in the game's programs.
    private func officialIcon(for game: Game) async -> URL? {
        var image: NSImage?
        if game.store == .steam, let url = steamArtwork(for: game)?.icon {
            let data = url.isFileURL ? try? Data(contentsOf: url) : try? await URLSession.shared.data(from: url).0
            if let data, let ico = NSImage(data: data), Self.largestSide(ico) >= 128 { image = ico }
        }
        if image == nil, let folder = game.installPath {
            let found = await Task.detached(priority: .utility) { Self.largestProgramIcon(in: folder) }.value
            if let found, found.size >= 128 { image = NSImage(data: found.ico) }
        }
        guard let image, let cg = Self.iconImage(fromIcon: image) else { return nil }
        return Self.writeIcns(cg)
    }

    /// The biggest icon among the game's own programs, three folders deep (as `AppNames` reads them).
    nonisolated static func largestProgramIcon(in folder: URL) -> (ico: Data, size: Int)? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var best: (ico: Data, size: Int)?
        for case let file as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            guard file.pathExtension.lowercased() == "exe", !AppNames.isHelper(file.lastPathComponent),
                  let icon = WindowsIcon.extract(from: file) else { continue }
            if icon.size > (best?.size ?? 0) { best = icon }
            if icon.size >= 256 { break }
        }
        return best
    }

    private static func largestSide(_ image: NSImage) -> Int {
        image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
    }

    /// 1024×1024: the Windows icon scaled into the icon grid (824 points, inset 100). A square, opaque one (most
    /// Steam icons) gets the rounded corners of Mac icons; one with its own shape stays as drawn.
    static func iconImage(fromIcon image: NSImage) -> CGImage? {
        var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
        context.interpolationQuality = .high
        if hasOpaqueCorners(source) {
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 185, cornerHeight: 185, transform: nil))
            context.clip()
        }
        context.draw(source, in: frame)
        return context.makeImage()
    }

    /// Whether all four corners of the image are solid (a square icon rather than a shape on transparency).
    private static func hasOpaqueCorners(_ image: CGImage) -> Bool {
        let size = 32
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        return [(1, 1), (size - 2, 1), (1, size - 2), (size - 2, size - 2)].allSatisfy { x, y in pixels[(y * size + x) * 4 + 3] > 240 }
    }

    private static func writeIcns(_ cg: CGImage) -> URL? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-icon-\(UUID().uuidString).icns")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.icns.identifier as CFString, 7, nil) else { return nil }
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            if let scaled = scaled(cg, to: size) { CGImageDestinationAddImage(destination, scaled, nil) }
        }
        return CGImageDestinationFinalize(destination) ? file : nil
    }

    /// The game's cover as a macOS icon (`.icns`, 16 to 1024 points): the art filling a rounded square on the
    /// standard icon grid. Nil while the cover hasn't loaded (a later sync adds it).
    private func coverIcon(for game: Game) async -> URL? {
        let url = coverURL(for: game) ?? headerURL(for: game)
        var image = artwork.image(url)
        for _ in 0..<20 where image == nil {
            try? await Task.sleep(for: .milliseconds(150))
            image = artwork.image(url)
        }
        guard let image, let cg = Self.iconImage(from: image) else { return nil }
        return Self.writeIcns(cg)
    }

    /// 1024×1024: the art clipped to the icon shape (824 points, inset 100, as Apple's grid), the middle of a tall
    /// cover (titles sit at its top on some covers and at the bottom on others).
    static func iconImage(from image: NSImage) -> CGImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let frame = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: frame, cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.addPath(shape)
        context.clip()
        let w = CGFloat(source.width), h = CGFloat(source.height), scale = max(frame.width / w, frame.height / h)
        let drawn = CGSize(width: w * scale, height: h * scale)
        context.draw(source, in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        context.resetClip()
        context.addPath(shape)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        context.setLineWidth(4)
        context.strokePath()
        return context.makeImage()
    }

    private static func scaled(_ image: CGImage, to size: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
