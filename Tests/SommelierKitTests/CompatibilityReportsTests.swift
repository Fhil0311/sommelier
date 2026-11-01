// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Answers every request with the status the test sets.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var bodies: [Data] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            stream.close(); Self.bodies.append(data)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct CompatibilityReportsTests {
    let report = CompatibilityReport(client: "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b",
                                     game: .init(store: "epic", id: "Sage", title: "Overcooked"),
                                     outcome: .ran, minutes: 15,
                                     system: .init(chip: "Apple M2 Pro", gpuCores: 19, ramGB: 32, macOS: "15.6"),
                                     sommelier: .init(app: "0.1", engine: "2.2.1", backend: "dxmt"))

    func reporter(_ status: Int?) throws -> CompatibilityReporter {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        if let status { StubProtocol.status = status; config.protocolClasses = [StubProtocol.self] }
        // No stub: a port nothing listens on, as when offline or before the service exists.
        let url = URL(string: status == nil ? "http://127.0.0.1:9" : "https://api.test")!
        return CompatibilityReporter(paths: Paths(home: home), baseURL: url, session: URLSession(configuration: config), clientVersion: "test")
    }

    @Test func sessionsCountAsPlayedAfterTwoMinutes() {
        #expect(CompatibilityReport.outcome(playedSeconds: 600) == .ran)
        #expect(CompatibilityReport.outcome(playedSeconds: 119) == nil)
    }

    @Test func chipNamesFitTheService() {
        #expect(MacSystem.chipName("Apple M2 Pro") == "Apple M2 Pro")
        #expect(MacSystem.chipName("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == "Intel Core i7-9750H")
        #expect(MacSystem.osVersion(OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)) == "15.6")
        #expect(MacSystem.osVersion(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)) == "26.1.2")
        let mine = MacSystem.current
        #expect(!mine.chip.isEmpty && (mine.ramGB ?? 0) >= 4)
    }

    @Test func sentReportsLeaveTheQueue() async throws {
        StubProtocol.bodies = []
        let r = try reporter(201)
        await r.send(report)
        #expect(r.pending().isEmpty)
        let sent = try JSONDecoder().decode(CompatibilityReport.self, from: try #require(StubProtocol.bodies.last))
        #expect(sent == report)
    }

    @Test func offlineReportsWaitAndRefusedOnesDont() async throws {
        let offline = try reporter(nil)
        await offline.send(report)
        await offline.send(report)
        #expect(offline.pending().count == 2)

        let refused = try reporter(400)
        await refused.send(report)
        #expect(refused.pending().isEmpty)

        let busy = try reporter(429)
        await busy.send(report)
        #expect(busy.pending().count == 1)
    }

    @Test func settingsKeepOnlyWhatCantIdentifyAnyone() {
        var profile = LaunchProfile()
        profile.backend = .dxmt
        profile.retina = false
        profile.extraEnvironment = [
            "DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=1.5",        // known, plain: goes
            "WINEDEBUG": "-all",                                          // known, plain: goes
            "DXVK_LOG_PATH": "/Users/anna/logs",                          // a path: stays
            "DXMT_SHADER_CACHE_PATH": "C:/x",                             // a path by its name: stays
            "MY_TOKEN": "abc",                                            // unknown: stays
            "MTL_HUD_ENABLED": "1 /Users/anna",                           // not a plain value: stays
        ]
        profile.extraArguments = ["-dx11", "--skip-intro", "-name=Anna", "/Users/anna/save", "+connect"]
        let s = CompatibilityReport.Settings(profile: profile, applied: ["overcooked-gl", "manual", "Bad Id!"].map { AppliedFix(ruleID: $0, action: .installVCRuntime, undo: .none) }, shadersFromOthers: true)
        #expect(s.backendChoice == "manual")
        #expect(s.retina == false)
        #expect(s.environment == ["DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=1.5", "WINEDEBUG": "-all"])
        #expect(s.arguments == ["-dx11", "--skip-intro"])
        #expect(s.otherCustom == 7)
        #expect(s.fixes == ["overcooked-gl", "manual"])
        #expect(s.shadersFromOthers)
        #expect(CompatibilityReport.Settings(profile: LaunchProfile(), applied: [], shadersFromOthers: false).backendChoice == "auto")
        // What the fixes did goes too, in the recipes' form; the recipe's own and the automatic graphics don't.
        let applied = [AppliedFix(ruleID: "manual", action: .installComponent(.physx), undo: .none),
                       AppliedFix(ruleID: "recipe", action: .turnOffTurbo, undo: .none),
                       AppliedFix(ruleID: "auto-graphics", action: .switchGraphics(.d3dMetal), undo: .none)]
        let withActions = CompatibilityReport.Settings(profile: LaunchProfile(), applied: applied, shadersFromOthers: false)
        #expect(withActions.actions == [.installComponent(.physx)])
        let json = String(decoding: try! JSONEncoder().encode(withActions), as: UTF8.self)
        #expect(json.contains(#""actions":[{"installComponent":{"_0":"physx"}}]"#))
        #expect(CompatibilityReport.Settings(profile: LaunchProfile(), applied: [], shadersFromOthers: false).actions == nil)
    }

    @Test func forgettingAsksTheServerAndDropsWaitingReports() async throws {
        let offline = try reporter(nil)
        await offline.send(report)
        #expect(await offline.forget(client: report.client) == false)
        #expect(offline.pending().count == 1)                  // not confirmed: nothing changes

        StubProtocol.bodies = []
        let online = try reporter(200)
        try JSONEncoder().encode([report]).write(to: online.queueFile)
        #expect(await online.forget(client: report.client))
        #expect(online.pending().isEmpty)
        let body = try JSONDecoder().decode([String: String].self, from: try #require(StubProtocol.bodies.last))
        #expect(body == ["client": report.client])
    }

    /// With the API running locally (`npx wrangler@4 dev --port 8788` in server/api) and SOMMELIER_API_URL set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_API_URL"] != nil))
    func reachesTheLocalService() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("reports-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var live = report
        live.client = UUID().uuidString.lowercased()
        live.system = MacSystem.current
        var profile = LaunchProfile()
        profile.backend = .dxmt
        profile.extraEnvironment = ["DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=1.5", "DXVK_LOG_PATH": "/tmp"]
        live.settings = .init(profile: profile, applied: [AppliedFix(ruleID: "overcooked-gl", action: .installVCRuntime, undo: .none)], shadersFromOthers: false)
        let r = CompatibilityReporter(paths: Paths(home: home), clientVersion: "test")
        await r.send(live)
        #expect(r.pending().isEmpty)
    }
}
