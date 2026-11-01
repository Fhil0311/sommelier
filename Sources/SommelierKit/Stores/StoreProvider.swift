// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// A place games come from. Steam, Epic, GOG and the publisher launchers each provide one, so the library can ask
/// them all the same question.
public protocol StoreProvider: Sendable {
    /// Which store this is.
    var kind: StoreKind { get }
    /// The store's games as they are right now: owned, installed or still downloading.
    func refresh() async throws -> [Game]
}

extension Sequence where Element == Game {
    /// The order stores hand their games to the library in: by title, ignoring case.
    func inLibraryOrder() -> [Game] {
        sorted { first, second in first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending }
    }
}

/// Fetches a store helper (legendary, gogdl) whose build we pin, and installs it only when its SHA-256 matches the
/// pinned value, so a tampered or truncated download is never run.
enum PinnedHelperDownload {
    /// `name` appears in the error messages ("Epic helper"); `failure` wraps them in the store's error type.
    static func install(from source: URL, sha256 expected: String, to destination: URL, paths: Paths,
                        name: String, failure: (String) -> any Error) async throws {
        try paths.createDirectories()   // the Tools folder may not exist yet
        let (downloaded, response) = try await URLSession.shared.download(from: source)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure("Couldn't download the \(name).")
        }
        let hex = SHA256.hash(data: try Data(contentsOf: downloaded)).map { String(format: "%02x", $0) }.joined()
        guard hex == expected else { throw failure("The downloaded \(name) failed its integrity check.") }
        let files = FileManager.default
        try? files.removeItem(at: destination)              // an older pinned build, if any
        try files.moveItem(at: downloaded, to: destination)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }
}

/// Runs the command-line store helpers (legendary, gogdl) when only their JSON answer matters.
enum StoreHelperOutput {
    /// Starts `tool` and collects everything it prints on stdout, plus its exit status.
    ///
    /// The helpers log progress on stderr. That stream goes to /dev/null rather than a pipe: a pipe nobody reads
    /// fills up after about 64 KB, and the helper would then block forever waiting to write.
    static func capture(_ tool: URL, _ arguments: [String], environment: [String: String]) async throws -> (status: Int32, data: Data) {
        let child = Process()
        child.executableURL = tool
        child.arguments = arguments
        child.environment = environment
        child.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        child.standardOutput = stdout
        return try await withCheckedThrowingContinuation { continuation in
            // Reading to the end blocks, so it happens off the cooperative thread pool.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try child.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let collected = stdout.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                continuation.resume(returning: (child.terminationStatus, collected))
            }
        }
    }
}
