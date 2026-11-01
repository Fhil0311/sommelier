// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Why installing an engine failed, worded for the person using the app.
public enum EngineError: Equatable, LocalizedError {
    case downloadFailed(String)   // carries the reason, already worded for people
    case sizeMismatch, checksumMismatch
    case extractFailed, invalidEngine, sanityCheckFailed, inUse

    public var errorDescription: String? { message }

    private var message: String {
        switch self {
        case .downloadFailed(let reason): return "Couldn't download the game engine. \(reason)"
        case .sizeMismatch, .checksumMismatch: return "The downloaded engine is damaged (it failed its integrity check). Please try again."
        case .extractFailed: return "Couldn't unpack the game engine."
        case .invalidEngine: return "The downloaded engine isn't a valid Sommelier engine."
        case .sanityCheckFailed: return "The game engine was installed but didn't start. Make sure Rosetta is installed."
        case .inUse: return "A game is running. Close it before changing the engine."
        }
    }
}

/// The stages of an engine install, reported with a 0...1 fraction (only downloading reports real progress).
public enum EnginePhase: Equatable, Sendable {
    case downloading, verifying, extracting, finishing
}

/// Fetches the engine list and installs engines into `Paths.engines`, one folder per version.
///
/// An install happens in a scratch folder next to the engines and only replaces an existing copy of the same
/// version once the new one is unpacked; if the new engine then fails to start, the old copy is put back.
/// Other versions stay installed so the user can roll back.
public struct EngineManager: Sendable {   // stateless; safe to create per use
    public let paths: Paths   // engines go to `paths.engines`
    public init(paths home: Paths) { paths = home }

    /// Downloads and decodes `engine-manifest.json`. Every failure becomes `EngineError.downloadFailed`.
    /// The list is signed (`engine-manifest.json.sig` next to it, see `Signature`): its checksums are what every
    /// engine download is checked against, so a list nobody signed would let anyone who controls its host run
    /// their own program on every Mac. Release builds also take it, and the engines it names, over HTTPS only.
    public func fetchManifest(from address: URL) async throws -> EngineManifest {
        let body: Data
        let response: URLResponse
        if Signature.required, address.scheme != "https" {
            throw EngineError.downloadFailed("The engine list isn't available.")
        }
        do {
            (body, response) = try await URLSession.shared.data(from: address)
        } catch {
            throw EngineError.downloadFailed(Self.describe(error))
        }
        // A missing list comes back as an error page; report the status rather than "unreadable".
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw EngineError.downloadFailed("The engine list isn't available (the server answered \(status)).")
        }
        let signatureURL = address.deletingLastPathComponent().appendingPathComponent(address.lastPathComponent + ".sig")
        let signed = try? await URLSession.shared.data(from: signatureURL)
        let signature = signed.flatMap { (data, response) in
            (response as? HTTPURLResponse)?.statusCode == 200 ? String(decoding: data, as: UTF8.self) : nil
        }
        guard Signature.accepts(body, signature: signature) else {
            throw EngineError.downloadFailed("The engine list isn't available.")          // not signed: as if there were none
        }
        do {
            let manifest = try EngineManifest.decode(body)
            if Signature.required, manifest.engines.contains(where: { $0.url.scheme != "https" }) {
                throw EngineError.downloadFailed("The engine list isn't available.")
            }
            return manifest
        } catch let decoding as DecodingError {
            throw EngineError.downloadFailed("The engine list is unreadable. \(decoding.localizedDescription)")
        } catch {
            throw EngineError.downloadFailed(Self.describe(error))
        }
    }

    /// Downloads, verifies, unpacks and test-starts `wanted`, returning the installed engine.
    @discardableResult public func install(
        _ wanted: EngineManifest.Entry,
        progress: @escaping @Sendable (EnginePhase, Double) -> Void = { _, _ in }
    ) async throws -> Engine {
        @Sendable func report(_ phase: EnginePhase, _ fraction: Double = 0) { progress(phase, fraction) }
        let fm = fileSystem
        // Hidden scratch folder on the same volume, so the final move is a rename. Creating it also creates
        // the engines folder on a first install.
        let scratch = paths.engines.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        report(.downloading)
        let archive = scratch.appendingPathComponent("engine.tar.xz")
        try await download(wanted.url, to: archive) { fraction in report(.downloading, fraction) }

        report(.verifying)
        try Self.verify(archive, against: wanted)

        report(.extracting)
        let unpacked = scratch.appendingPathComponent("extracted", isDirectory: true)
        try await unpack(archive, into: unpacked)
        let candidate = Engine(directory: unpacked)
        if candidate?.isUsable != true || candidate?.version != wanted.version { throw EngineError.invalidEngine }

        report(.finishing)
        let target = paths.engine(version: wanted.version)
        let backup = scratch.appendingPathComponent("previous", isDirectory: true)
        func restoreBackup() {
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: target) }
        }
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: backup) }
        do {
            try fm.moveItem(at: unpacked, to: target)
        } catch {
            restoreBackup()
            throw EngineError.extractFailed   // couldn't move the new copy into place
        }
        // The archive came from the internet; the checksum above stands in for Gatekeeper's quarantine.
        _ = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", target.path])

        if let installed = Engine(directory: target), await Self.starts(installed) { return installed }
        try? fm.removeItem(at: target)   // didn't start: back to the previous copy, if there was one
        restoreBackup()
        throw EngineError.sanityCheckFailed   // usually Rosetta missing
    }

    /// Deletes an installed engine version.
    public func remove(version unwanted: String) throws {
        try fileSystem.removeItem(at: paths.engine(version: unwanted))
    }

    // MARK: Steps

    /// Hex SHA-256 of a file, read in chunks so large archives don't need to fit in memory.
    static func sha256(of archive: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        var digest = SHA256()
        let chunkSize = 1 << 22
        while true {
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the archive's size (when the manifest gives one) and its SHA-256.
    private static func verify(_ archive: URL, against entry: EngineManifest.Entry) throws {
        try verify(archive, size: entry.size, sha256: entry.sha256)
    }

    static func verify(_ archive: URL, size: Int64, sha256 digest: String) throws {
        if size > 0 {
            let attributes = try? fileSystem.attributesOfItem(atPath: archive.path)
            let actual = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if actual != size { throw EngineError.sizeMismatch }
        }
        if try sha256(of: archive) != digest.lowercased() { throw EngineError.checksumMismatch }
    }

    func unpack(_ archive: URL, into folder: URL) async throws {
        try fileSystem.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let result = try await ProcessRunner.run(tar, ["-xJf", archive.path, "-C", folder.path])
        if !result.succeeded { throw EngineError.extractFailed }
    }

    /// Whether `wine --version` runs (fails when Rosetta is missing or the build is broken).
    private static func starts(_ engine: Engine) async -> Bool {
        let result = try? await ProcessRunner.run(engine.wine, ["--version"], environment: ["HOME": NSHomeDirectory()])
        return result?.succeeded == true
    }

    private static func describe(_ error: Error) -> String { (error as NSError).localizedDescription }

    /// Downloads `source` to `destination`, reporting progress; HTTP errors become `downloadFailed`.
    func download(
        _ source: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let observer = DownloadProgressObserver(report: onProgress)
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(from: source, delegate: observer)
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw EngineError.downloadFailed(Self.describe(error))
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw EngineError.downloadFailed("The server answered \(status).")
        }
        do {
            if fileSystem.fileExists(atPath: destination.path) { try fileSystem.removeItem(at: destination) }
            try fileSystem.moveItem(at: temporary, to: destination)
        } catch {
            throw EngineError.downloadFailed(Self.describe(error))
        }
    }
}

/// Forwards a download task's byte counts as a fraction.
private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    init(report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // Required by the protocol; the async download API hands over the file itself.
    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}

/// Shorthand for the default file manager (not stored: `FileManager` isn't `Sendable`).
private var fileSystem: FileManager { FileManager.default }
