// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How fast a game ran, as Sommelier's DXMT measures it quietly (`d3d11_frame_stats.cpp` in the DXMT fork): each
/// process that draws through DXMT writes `<exe>-<pid>.txt` into its bottle's `FrameStats` folder every 10 seconds
/// from the moment it makes a swap chain (average frame rate, the slowest 1% of frames, render size, and every
/// frame presented, so a hung game leaves a file saying `presented=0`). Games on D3DMetal aren't measured yet.
public enum FrameStats {
    /// Where a bottle's processes write: `SOMMELIER_FRAME_STATS_DIR` in their environment, as a Windows path.
    public static func folder(in bottle: Bottle) -> URL { bottle.url.appendingPathComponent("FrameStats", isDirectory: true) }

    public static func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }

    public struct Sample: Equatable, Sendable {
        public var exe: String
        public var frames: Int
        public var seconds: Double
        public var average: Double
        public var low1: Double
        public var width: Int
        public var height: Int
        /// Every frame the game presented, the first seconds included (`frames` leaves those out). Files from an
        /// older DXMT don't say; then it's `frames`.
        public var presented: Int
        /// The game asked whether an HDR colour space can be presented (1) or switched to one (2): it knows HDR.
        public var hdr: Int

        public init(exe: String, frames: Int, seconds: Double, average: Double, low1: Double, width: Int, height: Int, presented: Int? = nil, hdr: Int = 0) {
            self.exe = exe; self.frames = frames; self.seconds = seconds; self.average = average; self.low1 = low1
            self.width = width; self.height = height; self.presented = presented ?? frames; self.hdr = hdr
        }
    }

    static func parse(_ text: String) -> Sample? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let exe = values["exe"], let frames = values["frames"].flatMap(Int.init), let seconds = values["seconds"].flatMap(Double.init),
              let average = values["average"].flatMap(Double.init), let low1 = values["low1"].flatMap(Double.init) else { return nil }
        return Sample(exe: exe, frames: frames, seconds: seconds, average: average, low1: low1,
                      width: values["width"].flatMap(Int.init) ?? 0, height: values["height"].flatMap(Int.init) ?? 0,
                      presented: values["presented"].flatMap(Int.init), hdr: values["hdr"].flatMap(Int.init) ?? 0)
    }

    /// The game's frame rate in a session: the longest-measured process written since `since` whose executable is in
    /// the game's folder (a launcher drawing through DXMT, like the EA app, doesn't count). At least a minute of
    /// measured play, or nil.
    public static func session(in bottle: Bottle, since: Date, gameFolder: URL?) -> CompatibilityReport.FrameRate? {
        guard let best = samples(in: bottle, since: since, gameFolder: gameFolder)
            .max(by: { $0.seconds < $1.seconds }), best.seconds >= 60, best.average > 0 else { return nil }
        let resolution = best.width > 0 && best.height > 0 ? "\(best.width)x\(best.height)" : nil
        return CompatibilityReport.FrameRate(average: (best.average * 10).rounded() / 10,
                                             low: best.low1 > 0 ? min((best.low1 * 10).rounded() / 10, best.average) : nil,
                                             resolution: resolution)
    }

    /// Every sample written since `since` by a process from the game's folder (any process when the folder is unknown).
    public static func samples(in bottle: Bottle, since: Date, gameFolder: URL?) -> [Sample] {
        let folder = folder(in: bottle)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> Sample? in
            guard url.pathExtension == "txt",
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= since, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text)
        }
        .filter { sample in gameFolder.map { ShaderCache.executable(sample.exe, isIn: $0) } ?? true }
    }

    /// Drops files older than a day.
    public static func prune(in bottle: Bottle, now: Date = Date()) {
        let folder = folder(in: bottle)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(at: url) }
        }
    }
}
