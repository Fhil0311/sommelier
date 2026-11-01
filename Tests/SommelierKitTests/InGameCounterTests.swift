// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct InGameCounterTests {
    /// A record as framestats.c writes it.
    func record(sequence: UInt32 = 2, fps: Float = 59.5, updated: Date = Date(), magic: UInt32 = LiveFrameRate.magic) -> Data {
        var data = Data(count: 64)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: magic, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: sequence, toByteOffset: 8, as: UInt32.self)
            raw.storeBytes(of: UInt32(2560), toByteOffset: 12, as: UInt32.self)
            raw.storeBytes(of: UInt32(1440), toByteOffset: 16, as: UInt32.self)
            raw.storeBytes(of: fps, toByteOffset: 20, as: Float.self)
            raw.storeBytes(of: Float(16.8), toByteOffset: 24, as: Float.self)
            raw.storeBytes(of: Float(33.1), toByteOffset: 28, as: Float.self)
            raw.storeBytes(of: updated.timeIntervalSince1970, toByteOffset: 32, as: Double.self)
            raw.storeBytes(of: UInt64(12345), toByteOffset: 40, as: UInt64.self)
        }
        return data
    }

    @Test func readsTheDriversRecord() throws {
        let live = try #require(LiveFrameRate.parse(record(), exe: "Game.exe", pid: 42))
        #expect(abs(live.fps - 59.5) < 0.01)
        #expect(live.width == 2560 && live.height == 1440)
        #expect(abs(live.frameMs - 16.8) < 0.01)
        #expect(live.frames == 12345)
        #expect(LiveFrameRate.parse(record(sequence: 3), exe: "Game.exe", pid: 42) == nil)      // being written
        #expect(LiveFrameRate.parse(record(magic: 1), exe: "Game.exe", pid: 42) == nil)
        #expect(LiveFrameRate.parse(Data(count: 10), exe: "Game.exe", pid: 42) == nil)
    }

    @Test func picksTheGameNotTheLauncherNorOldRecords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try record(fps: 60).write(to: folder.appendingPathComponent("My-Game.exe-101-live.bin"))
        try record(fps: 120).write(to: folder.appendingPathComponent("EADesktop.exe-102-live.bin"))
        try record(fps: 200, updated: Date().addingTimeInterval(-10)).write(to: folder.appendingPathComponent("Old.exe-103-live.bin"))
        try Data("exe=x".utf8).write(to: folder.appendingPathComponent("My-Game.exe-101-metal.txt"))
        let live = try #require(LiveFrameRate.current(in: folder, excluding: ["EADesktop.exe"]))
        #expect(live.exe == "My-Game.exe")
        #expect(live.pid == 101)
    }

    @Test func settingsFromOtherVersionsStillLoad() throws {
        let old = try JSONDecoder().decode(InGameCounter.self, from: Data(#"{"enabled": true, "items": ["fps", "battery"], "corner": "middle"}"#.utf8))
        #expect(old.enabled)
        #expect(old.items == [.fps])
        #expect(old.corner == .topLeft)
        #expect(old.transparency == InGameCounter().transparency)
        #expect(old.textTransparency == 0)
        let invisible = try JSONDecoder().decode(InGameCounter.self, from: Data(#"{"textTransparency": 1}"#.utf8))
        #expect(invisible.textTransparency == InGameCounter.maxTextTransparency)      // the numbers never vanish
    }

    @Test func measuresThisMac() {
        let load = SystemLoad()
        _ = load.cpuPercent()
        let cpu = load.cpuPercent()
        #expect(cpu == nil || (0...100).contains(cpu!))
        #expect((SystemLoad.memory(of: getpid()) ?? 0) > 0)
        if let gpu = SystemLoad.gpuPercent() { #expect((0...100).contains(gpu)) }
    }
}
