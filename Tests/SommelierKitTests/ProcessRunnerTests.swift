// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Lines seen by an `onLine` callback, which may be called from any thread.
private final class SeenLines: @unchecked Sendable {
    private let mutex = NSLock()
    private var seen: [ProcessRunner.Line] = []
    func record(_ line: ProcessRunner.Line) { mutex.withLock { seen.append(line) } }
    var out: [String] { mutex.withLock { seen.compactMap { if case .stdout(let s) = $0 { s } else { nil } } } }
    var err: [String] { mutex.withLock { seen.compactMap { if case .stderr(let s) = $0 { s } else { nil } } } }
}

@Suite struct ProcessRunnerTests {
    let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func reportsExitStatusAndBothStreams() async throws {
        let result = try await ProcessRunner.run(shell, ["-c", "echo out; echo err >&2; exit 7"])
        #expect(result.status == 7 && !result.succeeded)
        #expect(Set(result.output.components(separatedBy: "\n")) == ["out", "err"])
        #expect(try await ProcessRunner.run(shell, ["-c", "true"]).succeeded)
    }

    @Test func callbackGetsEachLineTaggedWithItsStream() async throws {
        let lines = SeenLines()
        _ = try await ProcessRunner.run(shell, ["-c", "printf 'one\\ntwo\\n'; printf 'oops\\n' >&2"]) { lines.record($0) }
        #expect(lines.out == ["one", "two"])
        #expect(lines.err == ["oops"])
    }

    @Test func lastLineWithoutNewlineIsKept() async throws {
        let lines = SeenLines()
        let result = try await ProcessRunner.run(shell, ["-c", "printf 'first\\nlast'; sleep 0.2"]) { lines.record($0) }
        #expect(lines.out == ["first", "last"])
        #expect(result.output == "first\nlast")
    }

    @Test func environmentAndWorkingDirectoryAreApplied() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await ProcessRunner.run(shell, ["-c", "echo \"$ONLY_THIS\"; echo \"${HOME:-none}\"; pwd -P"],
                                                 environment: ["ONLY_THIS": "set"], currentDirectory: folder)
        let lines = result.output.components(separatedBy: "\n")
        #expect(lines.first == "set")
        #expect(lines.dropFirst().first == "none")                  // the given environment replaces the inherited one
        #expect(lines.last?.hasSuffix("/" + folder.lastPathComponent) == true)
    }

    @Test func manyLinesArriveInOrder() async throws {
        let result = try await ProcessRunner.run(shell, ["-c", "i=1; while [ $i -le 2000 ]; do echo $i; i=$((i+1)); done"])
        #expect(result.output.components(separatedBy: "\n") == (1...2000).map(String.init))
    }

    @Test func cancellingTheTaskStopsTheProgram() async throws {
        let started = ContinuousClock.now
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["60"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = try await task.value
        #expect(!result.succeeded)
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test func missingExecutableThrows() async {
        do {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/no/such/tool-\(UUID().uuidString)"))
            Issue.record("a missing executable should throw")
        } catch {
            #expect(error is ProcessRunnerError)
        }
    }

    @Test func splitterHoldsPartialLinesUntilTheyEnd() {
        let cutter = LineBuffer()
        #expect(cutter.take(Data("par".utf8)) == [])
        #expect(cutter.take(Data("tial\n\nnext".utf8)) == ["partial", ""])
        #expect(cutter.take(Data(" one\nx".utf8)) == ["next one"])
        #expect(cutter.flush() == "x")
        #expect(cutter.flush() == nil)
        #expect(cutter.take(Data("\n".utf8)) == [""])
    }
}
