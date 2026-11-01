// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Compression
import Foundation
import Testing
@testable import SommelierKit

struct UbisoftDownloadsTests {
    // Minimal protobuf writing, for building Ubisoft's files.
    func varint(_ v: UInt64) -> [UInt8] { var v = v, out: [UInt8] = []; while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }; return out + [UInt8(v)] }
    func field(_ n: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(v) }
    func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }

    func manifest(_ chunks: [(Int, [(String, Int)])], languages: [Int: String] = [:], addOns: Set<Int> = []) -> Data {
        var body: [UInt8] = []
        for (id, files) in chunks {
            var chunk = field(1, UInt64(id))
            if let language = languages[id] { chunk += field(5, Array(language.utf8)) }
            if addOns.contains(id) { chunk += field(8, 3962) }
            for (name, size) in files { chunk += field(3, field(1, Array(name.utf8)) + field(2, UInt64(size))) }
            body += field(4, chunk)
        }
        var deflated = [UInt8](repeating: 0, count: body.count + 1024)
        let n = compression_encode_buffer(&deflated, deflated.count, body, body.count, nil, COMPRESSION_ZLIB)
        let signature = Array("c2lnbmF0dXJl".utf8)
        var data = Data()
        for v in [UInt32(1), UInt32(signature.count), UInt32(body.count)] { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: signature)
        data.append(contentsOf: [0x78, 0x9C] + deflated.prefix(n))
        return data
    }

    func state(product: Int, chunks: [(Int, Bool)]) -> Data {
        var bytes = field(1, Array("186F2D93".utf8)) + field(28, UInt64(product))
        for (id, wanted) in chunks { bytes += field(6, field(1, UInt64(id)) + field(2, 0) + field(3, wanted ? 1 : 0)) }
        return Data(bytes)
    }

    @Test func progressCountsOnlyTheWantedChunks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ubi-\(UUID().uuidString)/WATCH_DOGS2")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try manifest([(0, [("bin\\game.exe", 4096)]), (1, [("data\\big.dat", 8192)]), (64, [("sound_french.dat", 1_000_000)])])
            .write(to: folder.appendingPathComponent("uplay_install.manifest"))
        try state(product: 2688, chunks: [(0, true), (1, true), (64, false)]).write(to: folder.appendingPathComponent("uplay_install.state"))
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("bin/game.exe"))

        let half = try #require(UbisoftDownloads.progress(in: folder))
        #expect(half.productID == 2688)
        #expect(half.total == 4096 + 8192)                       // French sound isn't part of this install
        #expect(half.done == 4096)
        #expect(UbisoftDownloads.inProgress(gamesFolder: folder.deletingLastPathComponent())[2688] != nil)

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 8192).write(to: folder.appendingPathComponent("data/big.dat"))
        #expect(UbisoftDownloads.progress(in: folder)?.isComplete == true)
        #expect(UbisoftDownloads.inProgress(gamesFolder: folder.deletingLastPathComponent()).isEmpty)
    }

    /// While it downloads: no chunk list yet, the manifest in the launcher's data folder, files in uplay_download.
    @Test func progressWhileDownloading() throws {
        let launcher = FileManager.default.temporaryDirectory.appendingPathComponent("ubi-\(UUID().uuidString)")
        let folder = launcher.appendingPathComponent("games/WATCH_DOGS2")
        let staging = folder.appendingPathComponent("uplay_download/2688")
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcher.appendingPathComponent("data/2688/manifests"), withIntermediateDirectories: true)
        try manifest([(0, [("bin\\game.exe", 4096)]), (1, [("english.dat", 4096)]), (2, [("french.dat", 9000)]), (3, [("ultra.dat", 9000)])],
                     languages: [1: "en-US", 2: "fr-FR"], addOns: [3])
            .write(to: launcher.appendingPathComponent("data/2688/manifests/186F2D93"))
        let state = field(3, Array("en-US".utf8)) + field(10, Array("186F2D93".utf8)) + field(28, 2688)
        try Data(state).write(to: folder.appendingPathComponent("uplay_install.state"))
        try Data(repeating: 1, count: 4096).write(to: staging.appendingPathComponent("bin/game.exe"))

        let p = try #require(UbisoftDownloads.progress(in: folder))
        #expect(p.total == 8192)                  // the game and English; not French, not the texture add-on
        #expect(p.done == 4096)
        #expect(abs(p.fraction - 0.5) < 0.001)
    }

    @Test func aCancelledDownloadIsntOne() throws {
        let reg = "[Software\\\\Ubisoft\\\\Launcher\\\\Installs\\\\2688] 1792578352\n#time=1dd61468c7a1ae4\n\"InstallState\"=dword:00000003\n\n[Software\\\\Wine]\n"
        #expect(UbisoftDownloads.installStates(userReg: reg) == [2688: 3])
        let launcher = FileManager.default.temporaryDirectory.appendingPathComponent("ubi-\(UUID().uuidString)")
        let folder = launcher.appendingPathComponent("games/WATCH_DOGS2")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("uplay_download/2688"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launcher.appendingPathComponent("data/2688/manifests"), withIntermediateDirectories: true)
        try manifest([(0, [("game.exe", 4096)])]).write(to: launcher.appendingPathComponent("data/2688/manifests/186F"))
        try Data(field(10, Array("186F".utf8)) + field(28, 2688)).write(to: folder.appendingPathComponent("uplay_install.state"))
        let games = launcher.appendingPathComponent("games")
        #expect(UbisoftDownloads.inProgress(gamesFolder: games)[2688] != nil)                         // files left behind
        #expect(UbisoftDownloads.inProgress(gamesFolder: games, installStates: [2688: 3]).isEmpty)    // but cancelled
        #expect(UbisoftDownloads.inProgress(gamesFolder: games, installStates: [2688: 1])[2688] != nil)
    }

    @Test func sparseFilesCountWhatIsWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 50_000_000)                   // full length, nothing written
        try handle.close()
        #expect(UbisoftDownloads.onDisk(url) < 1_000_000)
    }

    /// Against a real install: SOMMELIER_UBISOFT_GAME=<game folder>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_UBISOFT_GAME"] != nil))
    func readsARealInstall() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMMELIER_UBISOFT_GAME"]!)
        let p = try #require(UbisoftDownloads.progress(in: folder))
        print("UBI product \(p.productID) total \(p.total) done \(p.done) fraction \(p.fraction)")
        #expect(p.total > 0)
    }
}

struct UbisoftSteamActivationTests {
    @Test func aGameBoughtOnSteamNamesItsSteamApp() {
        let steam = "version: 2.0\nroot:\n  name: l1\n  start_game:\n    steam:\n      steam_app_id: 552520\n      arguments: -uplay_steam_mode\n  third_party_platform:\n    name: Steam\n  upn_enabled: true\n"
        let own = "version: 2.0\nroot:\n  name: l1\n  start_game:\n    online:\n      executables: []\n"
        #expect(UbisoftConfigurations.steamActivation(in: steam) == "552520")
        #expect(UbisoftConfigurations.steamActivation(in: own) == nil)
    }
}
