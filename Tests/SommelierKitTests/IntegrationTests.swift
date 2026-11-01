// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Installs a real engine from a manifest and runs its Wine. Opt-in, since it downloads hundreds of megabytes:
/// `SOMMELIER_INTEGRATION=1 SOMMELIER_MANIFEST=file:///…/engine-manifest.json swift test --filter EngineIntegrationTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    @Test func newestEngineInstallsAndWineStarts() async throws {
        let manifestURL = try #require(ProcessInfo.processInfo.environment["SOMMELIER_MANIFEST"].flatMap { URL(string: $0) })
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-integration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let installer = EngineManager(paths: .init(home: sandbox))
        let newest = try #require(try await installer.fetchManifest(from: manifestURL).latest)
        let installed = try await installer.install(newest)

        let version = try await ProcessRunner.run(installed.wine, ["--version"], environment: ["HOME": NSHomeDirectory()])
        #expect(version.succeeded)
        #expect(version.output.contains("wine-11"))
        #expect(FileManager.default.fileExists(atPath: installed.steamWebHelperWrapper.path), "the engine ships the wrapper")
    }
}
