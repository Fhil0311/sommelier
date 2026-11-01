// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct SteamDepotProgressTests {
    // Minimal protobuf writer for test data.
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
        return out
    }
    static func field(_ n: Int, bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }
    static func field(_ n: Int, varint v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func id(_ n: UInt8) -> [UInt8] { [UInt8](repeating: n, count: 20) }

    /// Two files: one with chunks 1 and 2, one with chunk 3. Compressed sizes 100, 200, 300.
    static var manifest: Data {
        func chunk(_ n: UInt8, _ size: UInt64) -> [UInt8] {
            field(6, bytes: field(1, bytes: id(n)) + [0x15] + le32(7) + field(3, varint: 0) + field(4, varint: size * 2) + field(5, varint: size))
        }
        let payload = field(1, bytes: field(1, bytes: Array("a.bin".utf8)) + field(2, varint: 600) + chunk(1, 100) + chunk(2, 200))
            + field(1, bytes: field(1, bytes: Array("b.bin".utf8)) + chunk(3, 300))
        return Data(le32(0x71F6_17D0) + le32(UInt32(payload.count)) + payload + le32(0x1F48_12BE))
    }

    static func statePatch(_ ids: [UInt8]) -> Data {
        Data(Array("MO42".utf8) + [UInt8](repeating: 0, count: 20) + ids.flatMap { id($0) + [4, 1, 0, 0] })
    }

    @Test func readsChunkSizesAndCompletedChunks() throws {
        let chunks = try #require(SteamDepotProgress.chunks(manifest: Self.manifest))
        #expect(chunks.count == 3)
        #expect(chunks[Data(Self.id(2))] == 200)
        #expect(SteamDepotProgress.completed(statePatch: Self.statePatch([1, 3])) == [Data(Self.id(1)), Data(Self.id(3))])
        #expect(SteamDepotProgress.completed(statePatch: Data("nope".utf8)).isEmpty)
        #expect(SteamDepotProgress.chunks(manifest: Data([1, 2, 3, 4, 5, 6, 7, 8])) == nil)
    }

    @Test func addsUpWhatSteamHas() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamapps = root.appendingPathComponent("steamapps"), depotcache = root.appendingPathComponent("depotcache")
        try FileManager.default.createDirectory(at: steamapps.appendingPathComponent("downloading"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depotcache, withIntermediateDirectories: true)
        #expect(SteamDepotProgress.read(appID: "10", steamapps: steamapps, steamDirectory: root) == nil)

        try Self.manifest.write(to: depotcache.appendingPathComponent("11_123.manifest"))
        try Self.statePatch([1, 3]).write(to: steamapps.appendingPathComponent("downloading/state_10_11.patch"))
        let progress = try #require(SteamDepotProgress.read(appID: "10", steamapps: steamapps, steamDirectory: root))
        #expect(progress.done == 400 && progress.total == 600)
    }

    @Test func chunkListsWinOverReservedSpace() {
        let manifest = """
        "AppState" { "StateFlags" "1026" "BytesToDownload" "1000" "BytesDownloaded" "10" "BytesToStage" "1200" "BytesStaged" "12" }
        """
        // The files already take 1100 bytes (reserved up front) but Steam has fetched 300 of the 1000 chunks.
        #expect(SteamDownload.parse(manifest: manifest, writtenSoFar: 1100, fetched: (300, 1000))?.bytesDone == 300)
        #expect(SteamDownload.parse(manifest: manifest, writtenSoFar: 0, fetched: (5000, 1000))?.bytesDone == 1000)
    }

    @Test func anUpdateDoesNotCountTheChunksItKeeps() {
        // Dispatch's update (23.10): 13.0 GB to download of a 22.6 GB depot; the 9.6 GB still on disk are marked as
        // had from the start. Steam showed 52 %; the chunk lists said 16.7 GB had.
        let manifest = """
        "AppState" { "StateFlags" "1030" "BytesToDownload" "13015941424" "BytesDownloaded" "6812574480" "BytesToStage" "24336050871" "BytesStaged" "17496299150" }
        """
        let update = SteamDownload.parse(manifest: manifest, fetched: (16_661_161_152, 22_640_752_688))
        let kept: Int64 = 22_640_752_688 - 13_015_941_424
        #expect(update?.phase == .downloading)
        #expect(update?.bytesDone == 16_661_161_152 - kept)                                   // 7.0 GB, about 54 %
        #expect(update?.bytesTotal == 13_015_941_424)
        // Before any new chunk arrives the kept ones alone count for nothing (the manifest's number stands).
        #expect(SteamDownload.parse(manifest: manifest, fetched: (9_624_811_264, 22_640_752_688))?.bytesDone == 6_812_574_480)
    }
}
