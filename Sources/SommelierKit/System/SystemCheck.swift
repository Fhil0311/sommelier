// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the setup screen shows about this Mac. A failed chip, macOS or Rosetta check stops setup; low disk space
/// and memory are only warnings.
public struct SystemReport: Sendable, Equatable {
    /// One check's outcome; the text explains a problem to the player.
    public enum Status: Sendable, Equatable { case ok, warning(String), failed(String) }

    public var appleSilicon, macOS, rosetta: Status
    public var disk, memory: Status

    /// False when any blocking check failed.
    public var canContinue: Bool { ![appleSilicon, macOS, rosetta].contains(where: \.isFailure) }
}

extension SystemReport.Status {
    var isFailure: Bool {
        guard case .failed = self else { return false }
        return true
    }
}

/// Checks that this Mac can run Sommelier's games: Apple silicon, a recent enough macOS, Rosetta 2, and room
/// on disk and in memory.
public struct SystemCheck: Sendable {
    /// The oldest macOS major version supported.
    public static let minMacOSMajor: Int = 15
    /// Below this much free space (decimal gigabytes, as Finder counts) there's a warning.
    public static let warnFreeBytes: Int64 = 30_000_000_000
    /// Below this much memory there's a warning.
    public static let warnMemoryBytes: UInt64 = 16 << 30

    // The texts double as keys in the app's string catalog.
    private enum Message {
        static let notAppleSilicon = "Sommelier needs a Mac with Apple Silicon."
        static let noRosetta = "Rosetta 2 is not installed."
        static let lowDisk = "Less than 30 GB free. Games may not fit."
        static let lowMemory = "16 GB or more memory is recommended for demanding games."
        static var oldMacOS: String { "Sommelier needs macOS \(minMacOSMajor) or later." }
    }

    public init() {}

    /// Runs every check. `volume` is any URL on the disk whose free space matters.
    public func run(volume disk: URL = FileManager.default.homeDirectoryForCurrentUser) async -> SystemReport {
        let required = OperatingSystemVersion(majorVersion: Self.minMacOSMajor, minorVersion: 0, patchVersion: 0)
        let host = ProcessInfo.processInfo
        let arm = Self.sysctlInt("hw.optional.arm64") == 1
        let rosettaResult = await rosettaStatus()
        return SystemReport(
            appleSilicon: arm ? .ok : .failed(Message.notAppleSilicon),
            macOS: host.isOperatingSystemAtLeast(required) ? .ok : .failed(Message.oldMacOS),
            rosetta: rosettaResult,
            disk: Self.diskStatus(disk),
            memory: host.physicalMemory < Self.warnMemoryBytes ? .warning(Message.lowMemory) : .ok)
    }

    /// Rosetta is there when an Intel-only command can run.
    public func rosettaStatus() async -> SystemReport.Status { await Self.rosettaRuns() ? .ok : .failed(Message.noRosetta) }

    private static func rosettaRuns() async -> Bool {
        (try? await succeeds("/usr/bin/arch", "-x86_64", "/usr/bin/true")) == true
    }

    /// Installs Rosetta 2, agreeing to Apple's license on the player's behalf: only call it after they said yes.
    public func installRosetta() async throws -> Bool { try await Self.succeeds(Self.updater, "--install-rosetta", "--agree-to-license") }

    private static let updater = "/usr/sbin/softwareupdate"

    private static func succeeds(_ tool: String, _ arguments: String...) async throws -> Bool {
        try await ProcessRunner.run(URL(fileURLWithPath: tool), arguments).succeeded
    }

    /// Free space for important use (what macOS would free up for it, too). Unknown counts as fine.
    static func diskStatus(_ volume: URL) -> SystemReport.Status {
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        guard let free = (try? volume.resourceValues(forKeys: [key]))?.volumeAvailableCapacityForImportantUsage else {
            return .ok
        }
        return free < warnFreeBytes ? .warning(Message.lowDisk) : .ok
    }

    /// A 32-bit integer from `sysctl`, or nil when the name doesn't exist on this Mac.
    static func sysctlInt(_ key: String) -> Int? {
        var result: Int32 = 0
        var length = MemoryLayout.size(ofValue: result)
        guard sysctlbyname(key, &result, &length, nil, 0) == 0 else { return nil }
        return Int(result)
    }
}
