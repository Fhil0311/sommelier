// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The log files of each game's runs, in `Logs/<game>/<time stamp>.log`. Only the newest `keep` are kept, so logs
/// never pile up. Time stamps sort the same as text and as time, which is what every listing here relies on.
public struct LogStore: Sendable {
    /// Where the logs live, and how many runs to keep per game.
    public let paths: Paths, keep: Int

    public init(paths: Paths, keep limit: Int = 5) {
        (self.paths, keep) = (paths, limit)
    }

    /// Starts an empty log for a new run, then trims the game's older ones.
    public func newLog(for game: String, now time: Date = .now) throws -> URL {
        let folder = paths.gameLogs(game)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("\(Self.stamp(time)).log")
        files.createFile(atPath: log.path, contents: nil)
        try trim(folder)
        return log
    }

    /// The game's logs, newest first.
    public func logs(for game: String) -> [URL] {
        (try? newestFirst(in: paths.gameLogs(game))) ?? []
    }

    /// The end of a log, for the details shown when a game fails to start.
    public func excerpt(of file: URL, lines count: Int = 40) -> String {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return "" }
        return content.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    private func newestFirst(in folder: URL) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "log" }.sorted { $1.lastPathComponent < $0.lastPathComponent }
    }

    private func trim(_ folder: URL) throws {
        let stale = try newestFirst(in: folder).dropFirst(keep)
        stale.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// `20261022-153012-045`: local time down to the millisecond.
    static func stamp(_ moment: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: moment)
    }
}

/// Copies a program's output into its log while keeping the file sane. A line that repeats back to back is written
/// once, followed by how many more times it came; and once the log reaches `maxBytes`, the program's output stops
/// being written (one game printed the same Wine warning tens of millions of times, gigabytes in minutes).
/// Sommelier's own notes are always written.
public final class LogWriter: @unchecked Sendable {
    /// The log file this writes to.
    public let url: URL
    let maxBytes: Int

    /// 20 MB, unless `SOMMELIER_LOG_MAX_MB` asks for more (tracing Wine can need gigabytes).
    public static var defaultMaxBytes: Int {
        let megabytes = ProcessInfo.processInfo.environment["SOMMELIER_LOG_MAX_MB"].flatMap { Int($0) } ?? 20
        return megabytes * 1_048_576
    }

    private let file: FileHandle
    private let pipe = Pipe()
    private let mutex = NSLock()
    // Everything below is guarded by `mutex`.
    private var bytesWritten = 0
    private var unfinishedLine = ""
    private var previousLine: String?
    private var repeatCount = 0
    private var full = false

    public init(url: URL, maxBytes: Int = LogWriter.defaultMaxBytes) throws {
        guard let file = try? FileHandle(forWritingTo: url) else { throw WineRunnerError.launchFailed("can't open log file") }
        (self.url, self.maxBytes, self.file) = (url, maxBytes, file)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] reader in
            let chunk = reader.availableData
            guard !chunk.isEmpty else { return }
            self?.take(chunk)
        }
    }

    /// Points the process's standard output and error at this log.
    public func attach(_ process: Process) {
        let input = pipe.fileHandleForWriting
        process.standardOutput = input
        process.standardError = input
    }

    /// Writes one of Sommelier's own lines (what was launched, how it ended). Never dropped.
    public func note(_ text: String) {
        mutex.withLock {
            endRepeats()
            try? file.write(contentsOf: Data(text.utf8))
        }
    }

    /// Call when the process has exited. Programs started by it (a store's launcher starting the game) still hold
    /// the pipe and their output belongs here too, so reading goes on until the last of them closes it; only then
    /// is the file closed.
    ///
    /// The handler holds the writer itself until then: nothing else may (the process that held it has ended), and a
    /// writer gone early closes the pipe's reading end, so the next line a still-running program writes kills it
    /// (SIGPIPE). A Mac game legendary started, slow to print its first line while Rosetta translated it, died so.
    public func finish(_ event: String) {
        try? pipe.fileHandleForWriting.close()
        note(event)
        pipe.fileHandleForReading.readabilityHandler = { reader in
            let chunk = reader.availableData
            if chunk.isEmpty {
                reader.readabilityHandler = nil         // lets the writer go
                self.closeFile()
            } else {
                self.take(chunk)
            }
        }
    }

    private func take(_ chunk: Data) {
        mutex.withLock {
            let text = unfinishedLine + String(decoding: chunk, as: UTF8.self)
            var pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
            unfinishedLine = pieces.popLast().map(String.init) ?? ""
            pieces.forEach { record(String($0)) }
        }
    }

    private func closeFile() {
        mutex.withLock {
            if !unfinishedLine.isEmpty {
                record(unfinishedLine)
                unfinishedLine = ""
            }
            endRepeats()
            try? file.close()
        }
    }

    /// Counts a line that repeats the one before it, or writes it out.
    private func record(_ line: String) {
        if let previousLine, previousLine == line {
            repeatCount += 1
            return
        }
        endRepeats()
        previousLine = line
        append(line + "\n")
    }

    /// Writes the count of a run of repeats, if there was one, and starts afresh.
    private func endRepeats() {
        if repeatCount > 0 {
            append("[Sommelier] previous line repeated \(repeatCount) more times\n")
        }
        repeatCount = 0
        previousLine = nil
    }

    private func append(_ text: String) {
        if full { return }
        let size = text.utf8.count
        guard bytesWritten + size <= maxBytes else {
            full = true
            let notice = "[Sommelier] log capped at \(maxBytes / 1_048_576) MB; the rest of the program's output is dropped\n"
            try? file.write(contentsOf: Data(notice.utf8))
            return
        }
        bytesWritten += size
        try? file.write(contentsOf: Data(text.utf8))
    }
}
