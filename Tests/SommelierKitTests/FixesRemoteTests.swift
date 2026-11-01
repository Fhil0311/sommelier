// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Answers every request with the status the test sets (this suite's own, so it doesn't race other suites' stubs).
final class FailureStubProtocol: URLProtocol, @unchecked Sendable {
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
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct FixesRemoteTests {
    static let list = #"""
    { "version": 1, "rules": [
      { "id": "overcooked-gl", "cause": "Unity fell back to OpenGL.", "causes": { "ru": "Unity перешла на OpenGL." },
        "patterns": ["OpenGL core profile"], "conditions": [ { "game": { "_0": "epic:Sage" } }, { "notNative": {} } ],
        "action": { "switchGraphics": { "_0": "dxmt" } } },
      { "id": "from-the-future", "cause": "Needs an action this app doesn't know.", "patterns": ["x"],
        "action": { "rebootTheMoon": {} } },
      { "id": "vcruntime", "cause": "Replaced online.", "patterns": ["mfc140u\\.dll"], "action": { "installVCRuntime": {} } }
    ] }
    """#

    @Test func readsTheListAndSkipsWhatItDoesntKnow() throws {
        let list = try JSONDecoder().decode(FixesList.self, from: Data(Self.list.utf8))
        #expect(list.rules.map(\.id) == ["overcooked-gl", "vcruntime"])
        #expect(list.rules[0].causes?["ru"] == "Unity перешла на OpenGL.")
        #expect(list.rules[0].conditions == [.game("epic:Sage"), .notNative])
        #expect(list.rules[0].action == .switchGraphics(.dxmt))
    }

    @Test func onlineRulesComeFirstAndReplaceBuiltInOnes() throws {
        let remote = try JSONDecoder().decode(FixesList.self, from: Data(Self.list.utf8)).rules
        let rules = FixRules.merged(remote: remote)
        #expect(rules.first?.id == "overcooked-gl")
        #expect(rules.filter { $0.id == "vcruntime" }.map(\.cause) == ["Replaced online."])
        #expect(rules.count == FixRules.builtIn.count + 1)
    }

    @Test func gameRulesOnlyMatchTheirGame() throws {
        let remote = try JSONDecoder().decode(FixesList.self, from: Data(Self.list.utf8)).rules
        let d = LaunchDiagnostics(gameID: "epic:Sage", title: "Overcooked", store: "epic", logTail: "GfxDevice: OpenGL core profile 4.1")
        let here = FixContext(gameID: "epic:Sage", backend: .d3dMetal, store: .epic, native: false, d3dMetalReady: true)
        let elsewhere = FixContext(gameID: "epic:Other", backend: .d3dMetal, store: .epic, native: false, d3dMetalReady: true)
        #expect(FixRules.match(d, context: here, rules: remote).map(\.id) == ["overcooked-gl"])
        #expect(FixRules.match(d, context: elsewhere, rules: remote).isEmpty)
    }

    @Test func failureReportsGoAsPreviewed() async throws {
        FailureStubProtocol.bodies = []
        FailureStubProtocol.status = 201
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailureStubProtocol.self]
        var diagnostics = LaunchDiagnostics(gameID: "epic:Sage", title: "Overcooked", store: "epic", logTail: "err: x")
        diagnostics.collected = Date(timeIntervalSince1970: 1_792_500_000)          // whole seconds: ISO 8601 keeps no more
        let report = FailureReport(client: "3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b", game: .init(store: "epic", id: "Sage", title: "Overcooked"),
                                   diagnostics: diagnostics,
                                   matched: ["vcruntime"], sommelier: .init(app: "0.1.0"))
        try await report.send(to: URL(string: "https://api.test")!, session: URLSession(configuration: config), clientVersion: "test")
        let sent = try #require(FailureStubProtocol.bodies.last)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(FailureReport.self, from: sent) == report)
        #expect(report.preview.contains("\"matched\""))

        FailureStubProtocol.status = 400
        await #expect(throws: FailureReport.SendError.refused(400)) {
            try await report.send(to: URL(string: "https://api.test")!, session: URLSession(configuration: config), clientVersion: "test")
        }
    }

    @Test func savedListIsReadBack() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = FixesService(paths: Paths(home: home), baseURL: URL(string: "http://127.0.0.1:9")!)
        #expect(service.cached().isEmpty)
        try Data(Self.list.utf8).write(to: service.file)
        #expect(service.cached().count == 2)
    }
}
