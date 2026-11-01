// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct EngineLabelTests {
    private func described(_ wineVersion: String) -> String {
        EngineInfo(version: "2.0.1", wineVersion: wineVersion, backends: ["d3dMetal"], minMacOS: "14.0").wineDescription
    }

    @Test func crossOverTagBecomesASourceCredit() {
        #expect(described("11.0 (CrossOver 26.3.0)") == "11.0, from CrossOver 26.3.0 source")
        #expect(described("10.9 (CrossOver 25.1)") == "10.9, from CrossOver 25.1 source")
    }

    @Test func everythingElseIsShownUnchanged() {
        for label in ["11.18 (Staging)", "11.0, from CrossOver 26.3.0 source", "11.0 (CrossOver 26.3.0", "wine-11.0"] {
            #expect(described(label) == label)
        }
    }

    @Test func backendNamesAndRawValuesAreStable() {
        #expect(GraphicsBackend.allCases.map(\.rawValue) == ["auto", "d3dMetal", "dxmt", "dxvk", "wined3d"])
        #expect(GraphicsBackend.allCases.map(\.displayName) == ["Automatic", "D3DMetal", "DXMT", "DXVK", "WineD3D"])
    }

    @Test func backendsAddTheirOwnOverridesAndEnvironment() {
        #expect(GraphicsBackend.dxvk.overrides == ["d3d11,d3d10core=n,b"])
        #expect(GraphicsBackend.dxmt.overrides == ["dxgi,d3d11,d3d10core=b"])
        #expect(GraphicsBackend.d3dMetal.overrides.isEmpty && GraphicsBackend.wined3d.overrides.isEmpty)
        #expect(GraphicsBackend.dxvk.environment == ["DXVK_ASYNC": "1", "MVK_CONFIG_RESUME_LOST_DEVICE": "1"])
        #expect(GraphicsBackend.dxmt.environment.isEmpty)
    }

    @Test func automaticPicksD3DMetalOnlyFor64BitDirectX12() {
        let modern = GraphicsProbe(usesDirectX12: true, has64BitExecutable: true)
        #expect(GraphicsBackend.auto.resolved(for: modern, d3dMetalAvailable: true) == .d3dMetal)
        #expect(GraphicsBackend.auto.resolved(for: modern, d3dMetalAvailable: false) == .dxvk, "no D3DMetal imported")
        #expect(GraphicsBackend.auto.resolved(for: GraphicsProbe(usesDirectX12: true), d3dMetalAvailable: true) == .dxvk)
        #expect(GraphicsBackend.auto.resolved(for: nil, d3dMetalAvailable: true) == .dxvk, "not scanned yet")
        #expect(GraphicsBackend.wined3d.resolved(for: modern, d3dMetalAvailable: true) == .wined3d)
    }
}

@Suite struct LogWriterTests {
    @Test func foldsRepeatedLinesAndStopsAtTheCap() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-log-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let writer = try LogWriter(url: log, maxBytes: 200)
        writer.note("[Sommelier] Launch\n")

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "echo first; for n in 1 2 3; do echo again; done; echo last; seq 1 3000"]
        writer.attach(shell)
        try shell.run()
        shell.waitUntilExit()
        writer.finish("[Sommelier] Exit\n")

        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.hasPrefix("[Sommelier] Launch\nfirst\nagain\n[Sommelier] previous line repeated 2 more times\nlast\n"))
        #expect(text.contains("log capped at 0 MB"))
        #expect(text.hasSuffix("[Sommelier] Exit\n"))
        #expect(text.utf8.count < 600)
    }
}
