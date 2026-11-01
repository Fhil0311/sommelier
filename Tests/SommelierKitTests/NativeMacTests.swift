// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct MacBuildTests {
    @Test func steamTellsTheKindOfMacVersion() {
        #expect(MacBuild.steam(oslist: "windows", osextended: "") == nil)
        #expect(MacBuild.steam(oslist: "windows,macos", osextended: "") == .legacy32)                 // Half-Life 2, Portal
        #expect(MacBuild.steam(oslist: "windows,macos", osextended: "macos64") == .intel)              // Hades
        #expect(MacBuild.steam(oslist: "macos", osextended: "macos64,macosapplesilicon,macosnotarized") == .appleSilicon)
        #expect(MacBuild.legacy32.runsHere == false && MacBuild.intel.runsHere && MacBuild.unknown.runsHere)
    }
}

struct MachOTests {
    static func header(_ magic: [UInt8], _ cputype: [UInt8]) -> [UInt8] { magic + cputype + [UInt8](repeating: 0, count: 24) }

    @Test func readsArchitectures() {
        let arm64 = Self.header([0xCF, 0xFA, 0xED, 0xFE], [0x0C, 0x00, 0x00, 0x01])          // little-endian 64-bit, CPU_TYPE_ARM64
        #expect(MachO.architectures(in: arm64) == [.arm64])
        let i386 = Self.header([0xCE, 0xFA, 0xED, 0xFE], [0x07, 0x00, 0x00, 0x00])
        #expect(MachO.architectures(in: i386) == [.i386])
        // Universal: 2 slices, x86_64 and arm64.
        var fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
        fat += [0x01, 0x00, 0x00, 0x07] + [UInt8](repeating: 0, count: 16)
        fat += [0x01, 0x00, 0x00, 0x0C] + [UInt8](repeating: 0, count: 16)
        #expect(MachO.architectures(in: fat) == [.x86_64, .arm64])
        #expect(MachO.architectures(in: Array("not a binary at all".utf8)).isEmpty)
        #expect(MachO.build(for: [.x86_64, .arm64]) == .appleSilicon)
        #expect(MachO.build(for: [.x86_64]) == .intel)
        #expect(MachO.build(for: [.i386]) == .legacy32)
        #expect(MachO.build(for: []) == .legacy32)
    }

    @Test func readsARealBinary() {
        // The shell is universal on every Mac this runs on.
        let archs = MachO.architectures(of: URL(fileURLWithPath: "/bin/zsh"))
        #expect(archs.contains(.arm64) || archs.contains(.x86_64))
    }
}

struct SteamMacClientTests {
    @Test func listsSteamForMacsGamesAsNative() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let steamapps = home.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let manifest = """
        "AppState" { "appid" "632470" "name" "Disco Elysium" "StateFlags" "4" "installdir" "Disco Elysium" "SizeOnDisk" "12" }
        """
        try manifest.write(to: steamapps.appendingPathComponent("appmanifest_632470.acf"), atomically: true, encoding: .utf8)
        let games = SteamMacClient.scan(home: home)
        #expect(games.count == 1)
        #expect(games[0].isNative && games[0].isInstalled)
        #expect(games[0].installPath == steamapps.appendingPathComponent("common/Disco Elysium"))
        #expect(SteamMacClient.hasManifest(appID: "632470", home: home))
        #expect(!SteamMacClient.hasManifest(appID: "1", home: home))
        #expect(SteamMacClient.url("rungameid", appID: "632470").absoluteString == "steam://rungameid/632470")
    }

    @Test func legendaryInstalledPlatformMakesAGameNative() throws {
        let list = #"[{"app_name":"Garlic","app_title":"Enter the Gungeon","metadata":{"releaseInfo":[{"platform":["Windows","Mac"]}]}}]"#
        let installed = #"[{"app_name":"Garlic","title":"Enter the Gungeon","install_path":"/g","install_size":1,"platform":"Mac","executable":"EtG_OSX.app/Contents/MacOS/EtG_OSX"}]"#
        let games = try LegendaryParser.games(listJSON: Data(list.utf8), installedJSON: Data(installed.utf8))
        #expect(games[0].isNative && games[0].macBuild == .unknown)
        let windows = installed.replacingOccurrences(of: "\"Mac\"", with: "\"Windows\"")
        #expect(try LegendaryParser.games(listJSON: Data(list.utf8), installedJSON: Data(windows.utf8))[0].isNative == false)
    }
}

struct SteamMacLogOnTests {
    @Test func readsTheLastLogOnTime() {
        let log = """
        [2026-10-20 11:13:29] [Connecting, 4, 0] [U:1:1] PingWebSocketCM() results: 41ms
        [2026-10-20 11:13:30] [Logging On, 4, 75] [U:1:1] RecvMsgClientLogOnResponse() : [U:1:1] 'OK'
        [2026-10-20 11:13:30] [Logged On, 4, 75] [U:1:1] RecvMsgClientLogOnResponse() : processing complete
        [2026-10-20 11:14:00] [Logged On, 4, 75] [U:1:1] something else
        """
        let date = SteamMacClient.lastLogOn(in: log)
        let parts = Calendar.current.dateComponents([.year, .hour, .minute, .second], from: date ?? .distantPast)
        #expect(parts.year == 2026 && parts.hour == 11 && parts.minute == 13 && parts.second == 30)
        #expect(SteamMacClient.lastLogOn(in: "[2026-10-20 11:13:29] Connecting") == nil)
    }
}
