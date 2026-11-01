// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct AppNamesTests {
    @Test func namesTheGamesProgramsButNotItsHelpers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let witcher = root.appendingPathComponent("The Witcher 3")
        for path in ["bin/x64/witcher3.exe", "bin/x64/unins000.exe", "_CommonRedist/vcredist_x64.exe", "REDprelauncher.exe"] {
            let file = witcher.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let table = AppNames.table(for: [(title: "The Witcher 3: Wild Hunt", folder: witcher, app: nil)])
        #expect(Set(table.split(separator: "\n")) == ["witcher3.exe\tThe Witcher 3 – Wild Hunt", "REDprelauncher.exe\tThe Witcher 3 – Wild Hunt"])
        let withApp = AppNames.table(for: [(title: "Raft", folder: witcher, app: URL(fileURLWithPath: "/Apps/Raft.app"))])
        #expect(withApp.contains("witcher3.exe\tRaft\t/Apps/Raft.app\n"))
    }

    @Test func findsUnrealGamesProgramsDeepInTheirProject() throws {
        let game = FileManager.default.temporaryDirectory.appendingPathComponent("unreal-\(UUID().uuidString)/Expedition 33")
        defer { try? FileManager.default.removeItem(at: game.deletingLastPathComponent()) }
        for path in ["Expedition33_Steam.exe", "Sandfall/Binaries/Win64/SandFall-Win64-Shipping.exe",
                     "Engine/Extras/Redist/en-us/UEPrereqSetup_x64.exe", "Sandfall/Plugins/Sentry/Binaries/Win64/crashpad_handler.exe",
                     "Sandfall/Content/Paks/hidden.exe"] {
            let file = game.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let table = AppNames.table(for: [(title: "Clair Obscur: Expedition 33", folder: game, app: URL(fileURLWithPath: "/Apps/E33.app"))])
        let names = Set(table.split(separator: "\n").map { $0.split(separator: "\t")[0] })
        #expect(names == ["Expedition33_Steam.exe", "SandFall-Win64-Shipping.exe"])
        #expect(table.contains("SandFall-Win64-Shipping.exe\tClair Obscur – Expedition 33\t/Apps/E33.app"))
    }

    @Test func pointsWineAtTheTable() {
        let paths = Paths(home: URL(fileURLWithPath: "/tmp/somm-home"))
        let env = WineRunner.environment(bottle: Bottle(kind: .steam, paths: paths), profile: LaunchProfile(), base: [:])
        #expect(env["SOMMELIER_APP_NAMES"] == "/tmp/somm-home/AppNames.tsv")
    }
}

struct UserFoldersTests {
    @Test func linksToTheMacsFoldersBecomeTheEnvironmentsOwn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        try paths.createDirectories()
        let bottle = Bottle(kind: .steam, paths: paths)
        let user = bottle.driveC.appendingPathComponent("users/crossover")
        let mac = home.appendingPathComponent("MacDocuments")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        try "mine".write(to: mac.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Desktop"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("Documents"), withDestinationURL: mac)
        try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("Desktop/My Mac Desktop"), withDestinationURL: mac)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("Music"), withIntermediateDirectories: true)

        let changed = bottle.isolateUserFolders()
        #expect(Set(changed) == ["Documents", "Desktop/My Mac Desktop"])
        let docs = user.appendingPathComponent("Documents")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: docs.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: docs.appendingPathComponent("desktop.ini").path))
        #expect(!FileManager.default.fileExists(atPath: docs.appendingPathComponent("private.txt").path))     // nothing of the Mac's copied
        #expect(FileManager.default.fileExists(atPath: mac.appendingPathComponent("private.txt").path))       // and nothing of it touched
        #expect(FileManager.default.fileExists(atPath: user.appendingPathComponent("Music/desktop.ini").path))
        #expect(FileManager.default.fileExists(atPath: user.appendingPathComponent("Videos/desktop.ini").path))
        #expect(bottle.isolateUserFolders().isEmpty)                                                           // once is enough
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_APPNAMES_FOLDER"] != nil))
struct AppNamesRealFolderTests {
    @Test func realGameFolder() {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMMELIER_APPNAMES_FOLDER"]!)
        print("TABLE:\n" + AppNames.table(for: [(title: "Game", folder: folder, app: nil)]))
    }
}
