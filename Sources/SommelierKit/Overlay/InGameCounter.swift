// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import IOKit

/// The in-game counter's settings: what it shows, where, how big, and how see-through its background is.
public struct InGameCounter: Codable, Equatable, Sendable {
    public enum Item: String, Codable, CaseIterable, Sendable {
        case fps, frameTime, gpu, cpu, memory, thermal
    }
    public enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    public enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large
    }

    public var enabled = false
    public var items: [Item] = [.fps, .gpu, .memory, .thermal]
    public var corner: Corner = .topLeft
    public var size: Size = .medium
    /// How see-through the background is, 0 (solid) to 1 (none). The numbers stay readable either way.
    public var transparency = 0.4
    /// How see-through the numbers and labels are, 0 (solid) to `maxTextTransparency`, so they never vanish.
    public var textTransparency = 0.0
    public static let maxTextTransparency = 0.8

    public init() {}

    public func shows(_ item: Item) -> Bool { items.contains(item) }

    /// Missing or unknown values keep their defaults, so settings from other versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InGameCounter()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        items = ((try? c.decodeIfPresent([String].self, forKey: .items)) ?? nil)?.compactMap(Item.init(rawValue:)) ?? d.items
        corner = ((try? c.decodeIfPresent(String.self, forKey: .corner)) ?? nil).flatMap(Corner.init(rawValue:)) ?? d.corner
        size = ((try? c.decodeIfPresent(String.self, forKey: .size)) ?? nil).flatMap(Size.init(rawValue:)) ?? d.size
        transparency = min(max((try? c.decodeIfPresent(Double.self, forKey: .transparency)) ?? nil ?? d.transparency, 0), 1)
        textTransparency = min(max((try? c.decodeIfPresent(Double.self, forKey: .textTransparency)) ?? nil ?? d.textTransparency, 0),
                               Self.maxTextTransparency)
    }
}

/// The current frame rate a game's Mac driver publishes twice a second (`framestats.c` in the engine's winemac
/// patch): `<exe>-<pid>-live.bin` in the bottle's FrameStats folder, a 64-byte record.
public struct LiveFrameRate: Equatable, Sendable {
    public var exe: String
    public var pid: Int32
    public var fps: Double
    public var frameMs: Double
    public var maxMs: Double
    public var width: Int
    public var height: Int
    public var updated: Date
    public var frames: UInt64

    static let size = 64
    static let magic: UInt32 = 0x564c_4d53            // "SMLV"

    /// Parses the record; nil when it isn't one, or was being written (odd sequence).
    static func parse(_ data: Data, exe: String, pid: Int32) -> LiveFrameRate? {
        guard data.count >= size else { return nil }
        func u32(_ at: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        func f32(_ at: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: Float.self) } }
        guard u32(0) == magic, u32(4) == 1, u32(8) % 2 == 0 else { return nil }
        let updated = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: Double.self) }
        let frames = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        return LiveFrameRate(exe: exe, pid: pid, fps: Double(f32(20)), frameMs: Double(f32(24)), maxMs: Double(f32(28)),
                             width: Int(u32(12)), height: Int(u32(16)), updated: Date(timeIntervalSince1970: updated), frames: frames)
    }

    /// Reads one file, twice if needed, so a record caught mid-write isn't used.
    static func read(_ url: URL) -> LiveFrameRate? {
        let name = url.deletingPathExtension().lastPathComponent      // Game.exe-1234-live
        guard name.hasSuffix("-live") else { return nil }
        let parts = name.dropLast(5).split(separator: "-")
        guard parts.count >= 2, let pid = Int32(parts.last!) else { return nil }
        let exe = parts.dropLast().joined(separator: "-")
        for _ in 0..<3 {
            guard let first = try? Data(contentsOf: url), let a = parse(first, exe: exe, pid: pid) else { continue }
            guard let second = try? Data(contentsOf: url), second == first else { continue }
            return a
        }
        return nil
    }

    /// The game's current frame rate: of the records updated in the last two seconds, the busiest one whose
    /// executable isn't a launcher.
    public static func current(in folder: URL, now: Date = Date(), excluding: Set<String> = []) -> LiveFrameRate? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "bin" }
            .compactMap(read)
            .filter { now.timeIntervalSince($0.updated) < 2 && !excluding.contains($0.exe) }
            .max { $0.fps < $1.fps }
    }

    /// The executables that drew at least one frame through the Mac driver since `date`: their records were
    /// written then (the driver makes a record on the first frame it shows, so a game that draws nothing has none).
    public static func drawers(in folder: URL, since date: Date) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> String? in
            guard url.lastPathComponent.hasSuffix("-live.bin"),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= date else { return nil }
            let parts = url.deletingPathExtension().lastPathComponent.dropLast(5).split(separator: "-")
            return parts.count >= 2 ? parts.dropLast().joined(separator: "-") : nil
        }
    }

    /// Deletes the records of processes that are gone, once they are ten minutes old: a session that just ended
    /// is still judged by them (`drawers`).
    public static func cleanUp(in folder: URL, now: Date = Date()) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.lastPathComponent.hasSuffix("-live.bin") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > 600 else { continue }
            let parts = url.deletingPathExtension().lastPathComponent.dropLast(5).split(separator: "-")
            if let pid = parts.last.flatMap({ Int32($0) }), kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

/// How busy the Mac is, measured from outside the game: GPU and CPU load, a process's memory, heat.
public final class SystemLoad: @unchecked Sendable {
    private var previousTicks: [UInt32]?

    public init() {}

    /// The GPU's load in percent, as the graphics driver reports it ("Device Utilization %"; Intel and AMD GPUs
    /// use other names).
    public static func gpuPercent() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Int?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)", "GPU Core Utilization"] {
                if let value = (stats[key] as? NSNumber)?.intValue {
                    let percent = key == "GPU Core Utilization" ? value / 10_000_000 : value
                    best = max(best ?? 0, min(max(percent, 0), 100))
                    break
                }
            }
        }
        return best
    }

    /// The whole Mac's CPU load in percent since the previous call (nil on the first).
    public func cpuPercent() -> Int? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { previousTicks = ticks }
        guard let previous = previousTicks, previous.count == ticks.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            for state in 0..<Int(CPU_STATE_MAX) {
                let delta = UInt64(ticks[base + state] &- previous[base + state])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total > 0 ? Int((Double(busy) / Double(total) * 100).rounded()) : nil
    }

    /// The memory a process uses, as Activity Monitor counts it (its footprint), in bytes.
    public static func memory(of pid: Int32) -> UInt64? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }
}
