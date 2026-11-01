// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Puts Sommelier's wrapper (`engine/steamwebhelper-wrapper`) in front of Chromium helpers that stay blank
/// under Wine on macOS.
///
/// With Chromium's GPU work in a separate process, the browser process's windows get painted from another
/// process, which Wine's Mac driver cannot show: the window appears but stays empty. The wrapper takes the
/// helper's file name, moves the vendor's binary to `<name>_real.exe`, and starts it with the GPU kept
/// in-process and software compositing. Steam's helper is wrapped by `SteamProvider.ensureWebHelperWrapper`.
public enum ChromiumHelperWrapper {   // namespace only
    /// Helpers wrapped in every bottle, relative to drive C. Rockstar's Social Club helper draws the Rockstar
    /// Games Launcher's sign-in window; left blank, games that require the launcher never get to start.
    static let helpers = ["Program Files/Rockstar Games/Social Club/SocialClubHelper.exe"]

    /// Identifies the generic wrapper, which can start any `<name>_real.exe`. Older engines carry a wrapper
    /// without it that only knows `steamwebhelper_real.exe`.
    static let marker = Data("sommelier-chromium-wrapper/2".utf8)

    /// Files at least this large are never taken for an unmarked old wrapper (Steam's helper is far larger).
    private static let legacyWrapperSizeLimit = 500_000

    /// The wrapper built into the app's resources.
    public static var bundledWrapper: URL? {
        Bundle.main.url(forResource: "chromium-helper-wrapper", withExtension: "exe")
    }

    /// The wrapper to use: the app's own when present, else the engine's if it is the generic kind.
    static func wrapper(in source: Engine, bundled appCopy: URL? = bundledWrapper) -> Data? {
        for candidate in [appCopy, source.steamWebHelperWrapper].compactMap({ $0 }) {
            guard let bytes = FileManager.default.contents(atPath: candidate.path) else { continue }
            if isGenericWrapper(bytes) { return bytes }
        }
        return nil
    }

    /// Wraps each known helper present in `target` and returns the paths that changed. Only files are swapped,
    /// so this is safe while the bottle runs; when a vendor update or repair restores its helper, the next
    /// launch wraps it again.
    @discardableResult public static func apply(
        to target: Bottle, engine source: Engine, bundled appCopy: URL? = bundledWrapper
    ) -> [String] {
        guard target.exists, let bytes = wrapper(in: source, bundled: appCopy) else { return [] }
        return helpers.filter { relative in
            let file = target.driveC.appendingPathComponent(relative)
            return (try? wrap(file, with: bytes)) == true
        }
    }

    /// Makes `helperFile` the wrapper, keeping the vendor's binary as `<name>_real.exe`. Returns whether anything
    /// was written.
    ///
    /// Each step leaves a launchable pair behind: the vendor binary is copied aside before the wrapper takes its
    /// place, and both writes are atomic. With `legacy`, any file under 500 KB also counts as an old wrapper
    /// (the first wrappers had no marker).
    static func wrap(_ helperFile: URL, with replacement: Data, legacyWrapper legacy: Bool = false) throws -> Bool {
        if replacement.isEmpty { throw WineRunnerError.launchFailed("the Chromium helper wrapper is empty") }
        let stem = helperFile.deletingPathExtension().lastPathComponent
        let original = helperFile.deletingLastPathComponent().appendingPathComponent(stem + "_real.exe")
        // The saved original must be a real program, not an empty file or another copy of the wrapper.
        func hasSavedOriginal() -> Bool {
            guard let saved = FileManager.default.contents(atPath: original.path) else { return false }
            return !saved.isEmpty && !isGenericWrapper(saved)
        }
        func install() throws -> Bool {
            try replacement.write(to: helperFile, options: .atomic)
            return true
        }

        guard let present = FileManager.default.contents(atPath: helperFile.path) else {
            // Interrupted earlier between the two writes: the vendor binary is safe, only the wrapper is missing.
            return hasSavedOriginal() ? try install() : false
        }

        if isGenericWrapper(present) || (legacy && present.count < legacyWrapperSizeLimit) {
            guard hasSavedOriginal() else { throw WineRunnerError.launchFailed(missingOriginalMessage) }
            return present == replacement ? false : try install()
        }

        // A vendor binary, new or freshly restored by an update: it becomes the saved original.
        try present.write(to: original, options: .atomic)
        return try install()
    }

    private static let missingOriginalMessage =
        "the original Chromium helper is missing; repair Steam to download it again"

    private static func isGenericWrapper(_ bytes: Data) -> Bool { bytes.range(of: marker) != nil }
}
