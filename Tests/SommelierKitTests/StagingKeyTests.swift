// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite(.serialized) struct StagingKeyTests {
    @Test func onlyTheServicesHostsGetTheKey() {
        StagingKey.key = "secret"
        StagingKey.hosts = ["sommelier-api-staging.example.workers.dev"]
        defer { StagingKey.key = nil; StagingKey.hosts = [] }
        #expect(StagingKey.wants(URLRequest(url: URL(string: "https://sommelier-api-staging.example.workers.dev/v1/recipes.json")!)))
        #expect(!StagingKey.wants(URLRequest(url: URL(string: "https://store.steampowered.com/app/1/")!)))
    }

    @Test func withoutAKeyNothingHappens() {
        #expect(!StagingKey.wants(URLRequest(url: URL(string: "https://anything.workers.dev/")!)))
    }
}

@Suite struct DirectoryWatcherTests {
    @Test func onlyTheFolderItselfCounts() {
        let folder = URL(fileURLWithPath: "/tmp/sommelier-watch/steamapps")
        #expect(DirectoryWatcher.isDirectlyIn(folder, "/tmp/sommelier-watch/steamapps/appmanifest_1.acf"))
        #expect(!DirectoryWatcher.isDirectlyIn(folder, "/tmp/sommelier-watch/steamapps/common/Game/Saved/Logs/a.log"))
    }

    @Test func aBurstOfOtherFilesCallsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("common/Game"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = Counter()
        let watcher = DirectoryWatcher(directory: root, latency: 0.2, relevant: { DirectoryWatcher.isDirectlyIn(root, $0) }) { calls.add() }
        try await Task.sleep(for: .milliseconds(400))
        try Data("x".utf8).write(to: root.appendingPathComponent("common/Game/log.txt"))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(calls.value == 0)
        try Data("x".utf8).write(to: root.appendingPathComponent("appmanifest_1.acf"))
        try await Task.sleep(for: .milliseconds(1200))
        #expect(calls.value >= 1)
        watcher.stop()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@Suite struct MicrophoneTests {
    @Test func onlyAGameHearsTheMicrophone() {
        let bottle = Bottle(kind: .steam, paths: Paths(home: URL(fileURLWithPath: "/tmp/sommelier-mic")))
        #expect(WineRunner.environment(bottle: bottle, profile: LaunchProfile(), base: [:])["SOMMELIER_NO_MIC"] == "1")   // Steam, installers
        var game = LaunchProfile(); game.forGame = true
        #expect(WineRunner.environment(bottle: bottle, profile: game, base: [:])["SOMMELIER_NO_MIC"] == nil)
        #expect(WineRunner.programEnvironment(bottle: bottle, profile: game)["SOMMELIER_NO_MIC"] == "")   // unsets the store's "1"
        game.extraEnvironment = ["SOMMELIER_NO_MIC": "1"]                                                 // a recipe can still hide it
        #expect(WineRunner.programEnvironment(bottle: bottle, profile: game)["SOMMELIER_NO_MIC"] == "1")
        let saved = try! JSONEncoder().encode(game)
        #expect(!String(decoding: saved, as: UTF8.self).contains("forGame"))                              // never saved
    }
}
