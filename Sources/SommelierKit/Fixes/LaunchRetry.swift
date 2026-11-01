// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What to offer after a crash the logs don't explain, or explain only as graphics: Turbo off, when the crash can
/// be Turbo's doing; then the engine's other way to run the game's graphics. Each is a rule like any other
/// (`FixRule`) and goes through the "didn't start" sheet, applied by the player's one click, never by itself.
public enum LaunchRetry {
    public static let turboRuleID = "turbo"
    public static let graphicsRuleID = "auto-graphics"

    /// What the launch was, beyond the diagnostics.
    public struct Context: Sendable {
        public var backend: GraphicsBackend
        /// The player left the graphics on Automatic; a backend they picked themselves stays.
        public var automatic: Bool
        public var turbo: Bool
        /// Backends the game could run on instead, best first: supported by the engine, set up, and able to run
        /// this game (DirectX 12 needs D3DMetal; D3DMetal needs a 64-bit game).
        public var alternatives: [GraphicsBackend]
        public var appliedRuleIDs: Set<String>
        public var turboFailedBefore: Bool

        public init(backend: GraphicsBackend, automatic: Bool, turbo: Bool, alternatives: [GraphicsBackend],
                    appliedRuleIDs: Set<String> = [], turboFailedBefore: Bool = false) {
            self.backend = backend; self.automatic = automatic; self.turbo = turbo; self.alternatives = alternatives
            self.appliedRuleIDs = appliedRuleIDs; self.turboFailedBefore = turboFailedBefore
        }
    }

    /// Whether Turbo can have caused the crash. Turbo only acts once the game draws through MetalFX, and
    /// Sommelier's DXMT logs that moment ("Turbo: MetalFX swap chain …"): a game that died before it can't blame
    /// Turbo, nor can one whose Mac has no MetalFX. A crash report naming MetalFX settles it the other way.
    public static func turboBlamed(_ d: LaunchDiagnostics) -> Bool {
        let text = d.searchableText
        if text.contains("MetalFX spatial scaler is not supported") { return false }
        if text.contains("Turbo: MetalFX spatial scaler could not be created") { return true }
        if let crash = d.crashReport, crash.contains("MetalFX") || crash.contains("MTLFX") { return true }
        return text.contains("Turbo: MetalFX swap chain")
    }

    /// A matched rule that explains the crash with something graphics can't change (anti-cheat, a runtime, an
    /// overlay) comes before any retry. Explanations that are only guesses (a missing DLL the log may always
    /// name, a video that may just be skipped) don't.
    static func settles(_ rule: FixRule) -> Bool {
        switch rule.action {
        case .switchGraphics?: false
        case nil: !["missing-dll", "video-playback"].contains(rule.id)
        default: true
        }
    }

    /// Rules to offer before the matched ones. Only for a game that ran and died: one that never started is Steam's,
    /// the store's or the launcher's doing, not the graphics'. The graphics rule remembers the backend it leaves
    /// (`backendIs`), for the sheet's words.
    public static func rules(_ d: LaunchDiagnostics, context c: Context, matched: [FixRule]) -> [FixRule] {
        guard d.secondsRunning != nil else { return [] }
        if let first = matched.first, settles(first) { return [] }
        var out: [FixRule] = []
        if c.turbo, !c.turboFailedBefore, !c.appliedRuleIDs.contains(turboRuleID), turboBlamed(d) {
            out.append(FixRule(id: turboRuleID,
                               cause: "The game didn't start with Turbo (MetalFX upscaling). Without it, it draws at the full resolution.",
                               patterns: [], conditions: [.backendIs(c.backend)], action: .turnOffTurbo))
        }
        if c.automatic, !c.appliedRuleIDs.contains(graphicsRuleID), let next = c.alternatives.first(where: { $0 != c.backend }) {
            out.append(FixRule(id: graphicsRuleID,
                               cause: "\(c.backend.displayName) didn't work out for this game. \(next.displayName) is the engine's other way to run its graphics.",
                               patterns: [], conditions: [.backendIs(c.backend)], action: .switchGraphics(next)))
        }
        return out
    }
}

extension FixRule {
    /// The backend a retry rule leaves, for its words ("DXMT didn't work out; let's try D3DMetal").
    public var previousBackend: GraphicsBackend? {
        for case .backendIs(let backend) in conditions { return backend }
        return nil
    }
}
