// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal

/// The cellar: a game's pipelines built into a Metal binary archive ahead of time, so its first run on this Mac
/// skips the shader compiling that makes the first minutes stutter. An archive is for one macOS major version
/// and one GPU: Sommelier's service builds them for every Mac from players' records (see server/decanter), and
/// when it has none for this Mac, the engine's `cellar` tool builds one here from the records in the game's
/// shader cache. DXMT opens whatever is in `<cache>/<exe>/cellar/` (d3d11_cellar in Sommelier's DXMT).
public struct Cellar: Sendable {
    public let cache: ShaderCache
    public init(paths: Paths) { cache = ShaderCache(paths: paths) }

    /// This Mac, as archives are keyed: macOS major version ("26") and Metal's name for the GPU ("applegpu_g16s").
    public static var mac: (os: String, arch: String)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return (String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion), device.architecture.name)
    }

    public func folder(exe: String) -> URL {
        cache.directory.appendingPathComponent(exe, isDirectory: true).appendingPathComponent("cellar", isDirectory: true)
    }

    /// An archive from the service, and one built here.
    public static func serviceFile(os: String, arch: String) -> String { "sommelier-\(os)-\(arch).metallib" }
    public static func localFile(os: String, arch: String) -> String { "local-\(os)-\(arch).metallib" }

    public func hasServiceArchive(exe: String, os: String, arch: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(exe: exe).appendingPathComponent(Self.serviceFile(os: os, arch: arch)).path)
    }

    /// Keeps an archive from the service. Archives for other Macs (an earlier macOS, the machine this folder
    /// came from) go: Metal would only skip them.
    public func store(_ data: Data, exe: String, os: String, arch: String) throws {
        let folder = folder(exe: exe)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(Self.serviceFile(os: os, arch: arch)), options: .atomic)
        prune(exe: exe, os: os, arch: arch)
    }

    /// Removes archives that aren't for this Mac.
    public func prune(exe: String, os: String, arch: String) {
        let keep: Set<String> = [Self.serviceFile(os: os, arch: arch), Self.localFile(os: os, arch: arch)]
        for file in (try? FileManager.default.contentsOfDirectory(at: folder(exe: exe), includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "metallib" && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The executable's shader database and pipeline records, when it has both (the newest Metal version).
    func inputs(exe: String) -> (shaders: URL, records: URL)? {
        let folder = cache.directory.appendingPathComponent(exe, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var shaders: [Int: URL] = [:], records: [Int: URL] = [:]
        for file in files {
            guard let (kind, metal) = ShaderCache.kindAndMetalVersion(of: file) else { continue }
            if kind == .shaders { shaders[metal] = file } else { records[metal] = file }
        }
        guard let metal = records.keys.max(), let r = records[metal], let s = shaders[metal] else { return nil }
        return (s, r)
    }

    /// When the executable's pipeline records last changed (nil without any).
    public func recordsDate(exe: String) -> Date? {
        guard let inputs = inputs(exe: exe) else { return nil }
        return (try? inputs.records.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Builds the executable's recorded pipelines into a local archive with the engine's tool, at a low priority.
    /// Returns how many pipelines it holds; nil when there is nothing to build from.
    @discardableResult
    public func cook(exe: String, engine: Engine, os: String, arch: String) async throws -> Int? {
        guard let tool = engine.cellarTool, let inputs = inputs(exe: exe) else { return nil }
        let folder = folder(exe: exe)
        let work = folder.appendingPathComponent(".cooking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/nice"),
                                                 ["-n", "15", tool.path, "cook", inputs.shaders.path, inputs.records.path, work.path])
        guard result.succeeded, let built = Self.built(in: result.output) else { throw CellarError.toolFailed(result.output) }
        let archive = work.appendingPathComponent("device.metallib")
        guard built > 0, FileManager.default.fileExists(atPath: archive.path) else { return 0 }
        let target = folder.appendingPathComponent(Self.localFile(os: os, arch: arch))
        _ = try FileManager.default.replaceItemAt(target, withItemAt: archive)
        prune(exe: exe, os: os, arch: arch)
        return built
    }

    /// `built=167 failed=0 …`, as the tool reports.
    static func built(in output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            for pair in line.split(separator: " ") where pair.hasPrefix("built=") { return Int(pair.dropFirst("built=".count)) }
        }
        return nil
    }
}

public enum CellarError: Error, LocalizedError {
    case toolFailed(String)
    public var errorDescription: String? {
        switch self {
        case .toolFailed(let output): "The cellar tool failed: \(output.suffix(300))"
        }
    }
}
