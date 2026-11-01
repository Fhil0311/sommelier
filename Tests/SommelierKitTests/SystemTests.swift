// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A fresh temporary folder name; nothing is created.
private func temporaryHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-\(UUID().uuidString)", isDirectory: true)
}

/// Runs `body` with a temporary home that is removed afterwards.
private func withTemporaryHome(_ body: (URL) throws -> Void) rethrows {
    let home = temporaryHome()
    defer { _ = try? FileManager.default.removeItem(at: home) }
    try body(home)
}

@Suite struct PathsTests {
    @Test func everythingHangsOffTheGivenHome() {
        let root = Paths(home: URL(fileURLWithPath: "/tmp/sommelier-test", isDirectory: true))
        let expected = [
            root.engine(version: "3.1.4"): "/tmp/sommelier-test/Engines/3.1.4",
            root.bottle("gog"): "/tmp/sommelier-test/Bottles/gog",
            root.libraryFile: "/tmp/sommelier-test/Library.json",
            root.settingsFile: "/tmp/sommelier-test/Settings.json",
            root.sessionsFile: "/tmp/sommelier-test/Sessions.json",
            root.d3dMetal: "/tmp/sommelier-test/D3DMetal",
            root.legendaryConfig: "/tmp/sommelier-test/legendary",
            root.gogConfig: "/tmp/sommelier-test/gog",
        ]
        for (url, path) in expected { #expect(url.path == path) }
    }

    @Test func logFolderNamesHaveNoColons() {
        let root = Paths(home: URL(fileURLWithPath: "/h"))
        #expect(root.gameLogs("gog:1207658924").lastPathComponent == "gog-1207658924")
        #expect(root.gameLogs("epic:a:b").lastPathComponent == "epic-a-b")
    }

    @Test func gamesInstallUnderTheUsersGamesFolder() {
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/Sommelier").path
        #expect(Paths(home: URL(fileURLWithPath: "/h")).defaultGamesFolder.path == expected)
    }

    @Test func createsItsFoldersWithPrivateStoreConfigs() throws {
        try withTemporaryHome { home in
            let made = Paths(home: home)
            try made.createDirectories()
            let folders = [made.engines, made.tools, made.bottles, made.artwork, made.logs]
            #expect(folders.allSatisfy { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            for secret in [made.legendaryConfig, made.gogConfig] {
                let mode = try FileManager.default.attributesOfItem(atPath: secret.path)[.posixPermissions] as? Int
                #expect(mode == 0o700)
            }
        }
    }
}

@Suite struct LogStoreTests {
    @Test func keepsOnlyTheNewestRuns() throws {
        try withTemporaryHome { home in
            let logs = LogStore(paths: Paths(home: home), keep: 2)
            let start = Date(timeIntervalSince1970: 1_750_000_000)
            let made = try (0..<5).map { try logs.newLog(for: "gog:9", now: start.addingTimeInterval(Double($0))) }
            let kept = logs.logs(for: "gog:9")
            #expect(kept.map(\.lastPathComponent) == [made[4], made[3]].map(\.lastPathComponent))
            #expect(Set(kept.map { $0.deletingLastPathComponent().lastPathComponent }) == ["gog-9"])
        }
    }

    @Test func aGameWithoutLogsHasNone() {
        #expect(LogStore(paths: Paths(home: temporaryHome())).logs(for: "steam:1").isEmpty)
    }

    @Test func stampsSortLikeTime() {
        let earlier = LogStore.stamp(Date(timeIntervalSince1970: 1_750_000_000))
        let later = LogStore.stamp(Date(timeIntervalSince1970: 1_750_000_000.25))
        #expect(earlier < later)
        #expect(earlier.count == "yyyyMMdd-HHmmss-SSS".count)
    }

    @Test func excerptIsTheLastLines() throws {
        try withTemporaryHome { home in
            let logs = LogStore(paths: Paths(home: home))
            let log = try logs.newLog(for: "ea:5")
            try (1...60).map { "line \($0)" }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            #expect(logs.excerpt(of: log, lines: 2) == "line 59\nline 60")
            #expect(logs.excerpt(of: log).split(separator: "\n").count == 40)
            #expect(logs.excerpt(of: home.appendingPathComponent("missing.log")) == "")
        }
    }
}

@Suite struct SystemCheckTests {
    @Test func thisMacPassesTheBlockingChecks() async {
        let report = await SystemCheck().run()
        #expect([report.appleSilicon, report.macOS] == [.ok, .ok])
    }

    @Test func onlyFailuresStopSetup() {
        var report = SystemReport(appleSilicon: .ok, macOS: .ok, rosetta: .ok,
                                  disk: .warning("low"), memory: .warning("low"))
        #expect(report.canContinue)
        report.rosetta = .failed("missing")
        #expect(!report.canContinue)
    }
}
