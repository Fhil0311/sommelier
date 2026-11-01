// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct LaunchRetryTests {
    static func crashed(_ log: String = "", crash: String? = nil, seconds: Int? = 7) -> LaunchDiagnostics {
        LaunchDiagnostics(gameID: "steam:1", title: "G", store: "steam", backend: "dxmt", secondsRunning: seconds, logTail: log, crashReport: crash)
    }
    static let swapChain = "info: Turbo: MetalFX swap chain 1440x900 -> 2880x1800"
    static let auto = LaunchRetry.Context(backend: .dxmt, automatic: true, turbo: true, alternatives: [.d3dMetal, .wined3d])

    @Test func turboFirstWhenItDrewThroughMetalFX() {
        let rules = LaunchRetry.rules(Self.crashed(Self.swapChain), context: Self.auto, matched: [])
        #expect(rules.map(\.id) == ["turbo", "auto-graphics"])
        #expect(rules[0].action == .turnOffTurbo)
        #expect(rules[1].action == .switchGraphics(.d3dMetal))
        #expect(rules[1].previousBackend == .dxmt)
    }

    @Test func turboIsNotBlamedForACrashBeforeItActed() {
        #expect(LaunchRetry.rules(Self.crashed("err:module:import_dll foo"), context: Self.auto, matched: []).map(\.id) == ["auto-graphics"])
        #expect(LaunchRetry.turboBlamed(Self.crashed("warn: MetalFX spatial scaler is not supported on this device")) == false)
        #expect(LaunchRetry.turboBlamed(Self.crashed(crash: "Thread 3 Crashed: 0 MetalFX 0x1 MTLFXSpatialScaler")) == true)
        #expect(LaunchRetry.turboBlamed(Self.crashed("err: Turbo: MetalFX spatial scaler could not be created for 1x1")) == true)
    }

    @Test func eachStepIsOfferedOnce() {
        var c = Self.auto; c.appliedRuleIDs = ["turbo"]
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: c, matched: []).map(\.id) == ["auto-graphics"])
        c.appliedRuleIDs = ["turbo", "auto-graphics"]
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: c, matched: []).isEmpty)
        var failedBefore = Self.auto; failedBefore.turboFailedBefore = true
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: failedBefore, matched: []).map(\.id) == ["auto-graphics"])
    }

    @Test func respectsThePlayerAndTheEngine() {
        var manual = Self.auto; manual.automatic = false; manual.turbo = false
        #expect(LaunchRetry.rules(Self.crashed(), context: manual, matched: []).isEmpty)
        var noOther = Self.auto; noOther.alternatives = [.dxmt]; noOther.turbo = false
        #expect(LaunchRetry.rules(Self.crashed(), context: noOther, matched: []).isEmpty)
        // Never started: not a graphics problem.
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain, seconds: nil), context: Self.auto, matched: []).isEmpty)
    }

    @Test func aRuleThatExplainsTheCrashComesFirst() {
        let anticheat = FixRules.builtIn.first { $0.id == "anticheat" }!
        let dotnet = FixRules.builtIn.first { $0.id == "dotnet" }!
        let dxmtFail = FixRules.builtIn.first { $0.id == "dxmt-fail" }!
        let missing = FixRules.builtIn.first { $0.id == "missing-dll" }!
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: Self.auto, matched: [anticheat]).isEmpty)
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: Self.auto, matched: [dotnet]).isEmpty)
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: Self.auto, matched: [dxmtFail]).count == 2)
        #expect(LaunchRetry.rules(Self.crashed(Self.swapChain), context: Self.auto, matched: [missing]).count == 2)
    }

    @Test func theReportSaysTheChoiceWasARetry() {
        var profile = LaunchProfile(); profile.backend = .d3dMetal
        #expect(CompatibilityReport.Settings(profile: profile, applied: ["auto-graphics"].map { AppliedFix(ruleID: $0, action: .installVCRuntime, undo: .none) }, shadersFromOthers: false).backendChoice == "retry")
        #expect(CompatibilityReport.Settings(profile: profile, applied: ["turbo"].map { AppliedFix(ruleID: $0, action: .installVCRuntime, undo: .none) }, shadersFromOthers: false).backendChoice == "manual")
    }
}
