// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct LogWriterLifetimeTests {
    /// A program the logged process started (legendary starting a game) writes after the process has ended and
    /// nobody keeps the writer: its line still reaches the log, and it isn't killed for writing to a closed pipe.
    @Test func programsStartedByTheProcessKeepTheirLog() async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString).done")
        defer { try? FileManager.default.removeItem(at: marker) }
        try start(log: log, marker: marker)
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(300))
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.contains("early") && text.contains("late"))
        #expect(FileManager.default.fileExists(atPath: marker.path))      // the late writer lived to the end
    }

    /// The writer goes out of scope here, as in `EpicProvider.playNative`: only the process's handler holds it.
    private func start(log: URL, marker: URL) throws {
        let writer = try LogWriter(url: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "(sleep 1; echo late; touch '\(marker.path)') & echo early"]
        writer.attach(process)
        process.terminationHandler = { _ in writer.finish("[exit]\n") }
        try process.run()
    }
}
