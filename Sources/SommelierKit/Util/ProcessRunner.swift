// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How a command run through `ProcessRunner` ended.
public struct ProcessResult: Sendable {
    /// The exit code, or the signal number when the process was killed.
    public let status: Int32
    /// Every line from standard output and standard error, in arrival order, joined by newlines.
    public let output: String

    public var succeeded: Bool { status == 0 }
}

/// The executable could not be started at all (missing, not executable…).
public enum ProcessRunnerError: Error { case launchFailed(String) }

/// Runs a command-line program from async code: waits for it to exit, collects its output and can hand each
/// line to a callback as it arrives. Cancelling the calling task stops the program and everything it started
/// (SIGTERM, then SIGKILL for whatever is still there a few seconds later).
public enum ProcessRunner {
    /// One line of output and the stream it came from.
    public enum Line: Sendable { case stdout(String), stderr(String) }

    /// Starts `executable` and returns once it has exited and both output streams are drained.
    /// `environment` replaces the inherited one when given. Throws `ProcessRunnerError` if it can't start;
    /// a non-zero exit is reported in the result, not thrown.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String] = [],
                           environment: [String: String]? = nil, currentDirectory: URL? = nil,
                           onLine: (@Sendable (Line) -> Void)? = nil) async throws -> ProcessResult {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        if let environment { child.environment = environment }
        if let currentDirectory { child.currentDirectoryURL = currentDirectory }

        let transcript = Transcript()
        let deliver: @Sendable (Line) -> Void = { line in
            switch line {
            case .stdout(let text), .stderr(let text): transcript.add(text)
            }
            onLine?(line)
        }
        let readers = [StreamReader(tag: { .stdout($0) }, deliver: deliver), StreamReader(tag: { .stderr($0) }, deliver: deliver)]
        child.standardOutput = readers[0].pipe
        child.standardError = readers[1].pipe

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<ProcessResult, Error>) in
                child.terminationHandler = { ended in
                    readers.forEach { $0.finish() }
                    done.resume(returning: ProcessResult(status: ended.terminationStatus, output: transcript.text))
                }
                for reader in readers { reader.start() }
                do {
                    try child.run()
                    // Cancelled before it started: the handler below found nothing to stop.
                    if Task.isCancelled { stopTree(of: child.processIdentifier) }
                } catch {
                    readers.forEach { $0.stop() }
                    done.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        }, onCancel: {
            if child.isRunning { stopTree(of: child.processIdentifier) }
        })
    }

    /// Stops the process and its descendants: helpers such as legendary run their downloads in worker processes
    /// that a signal to the parent alone leaves running.
    static func stopTree(of pid: pid_t) {
        let tree = descendants(of: pid) + [pid]
        for member in tree { kill(member, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for member in tree where kill(member, 0) == 0 { kill(member, SIGKILL) }
        }
    }

    private static func descendants(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        let children = buffer.prefix(Int(count)).filter { $0 > 0 }
        return children.flatMap { descendants(of: $0) + [$0] }
    }
}

/// Reads one of the child's output pipes, turning bytes into lines as they come.
private final class StreamReader: @unchecked Sendable {
    let pipe = Pipe()
    private let splitter = LineBuffer()
    private let tag: @Sendable (String) -> ProcessRunner.Line
    private let deliver: @Sendable (ProcessRunner.Line) -> Void

    init(tag: @escaping @Sendable (String) -> ProcessRunner.Line, deliver: @escaping @Sendable (ProcessRunner.Line) -> Void) {
        self.tag = tag
        self.deliver = deliver
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            emit(splitter.take(bytes))
        }
    }

    func stop() { pipe.fileHandleForReading.readabilityHandler = nil }

    /// After exit: reads what's still in the pipe, then hands over a last line that had no newline.
    func finish() {
        stop()
        emit(splitter.take(pipe.fileHandleForReading.readDataToEndOfFile()))
        if let rest = splitter.flush() { emit([rest]) }
    }

    private func emit(_ lines: [String]) {
        for line in lines { deliver(tag(line)) }
    }
}

/// Collects output lines from both streams, thread-safely.
private final class Transcript: @unchecked Sendable {
    private let mutex = NSLock()
    private var collected = [String]()

    func add(_ line: String) { mutex.withLock { collected.append(line) } }
    var text: String { mutex.withLock { collected.joined(separator: "\n") } }
}

/// Cuts a byte stream into `\n`-terminated lines, holding an unfinished line until the rest arrives.
final class LineBuffer: @unchecked Sendable {
    private let mutex = NSLock()
    private var pending = Data()

    /// Adds bytes and returns the lines they complete (without the newline).
    func take(_ data: Data) -> [String] {
        mutex.withLock {
            pending.append(data)
            var complete: [String] = []
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                complete.append(String(decoding: pending[start..<newline], as: UTF8.self))
                start = pending.index(after: newline)
            }
            pending.removeSubrange(pending.startIndex..<start)
            return complete
        }
    }

    /// Returns and clears an unfinished last line, if any.
    func flush() -> String? {
        mutex.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
    }
}
