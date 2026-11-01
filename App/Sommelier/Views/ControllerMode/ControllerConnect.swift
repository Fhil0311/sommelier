// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// Controller silhouettes: Kenney Input Prompts (kenney.nl), CC0.
import AppKit
@preconcurrency import GameController
import SommelierKit
import SwiftUI

/// The controller in hand, drawn as its own shape: an Xbox Series pad, a DualSense, or a plain one for the rest.
/// Not a logo: the shapes only. Takes the foreground colour.
struct PadIcon: View {
    let kind: ControllerKind
    var disconnected = false

    private var name: String {
        switch kind { case .xbox: "PadXbox"; case .playStation: "PadPlayStation"; case .other: "PadGeneric" }
    }

    /// Where the Guide (PS) button sits on each shape, in its 64×64 drawing.
    var guidePoint: CGPoint {
        switch kind { case .xbox: CGPoint(x: 32, y: 21.5); case .playStation: CGPoint(x: 32, y: 32); case .other: CGPoint(x: 32, y: 30) }
    }

    var body: some View {
        Image(name).renderingMode(.template).resizable().aspectRatio(1, contentMode: .fit)
            .overlay {
                if disconnected {
                    // A diagonal line with a gap of the background around it.
                    GeometryReader { g in
                        Path { p in
                            p.move(to: CGPoint(x: g.size.width * 0.12, y: g.size.height * 0.12))
                            p.addLine(to: CGPoint(x: g.size.width * 0.88, y: g.size.height * 0.88))
                        }
                        .stroke(CM.ground, lineWidth: g.size.width * 0.12)
                        Path { p in
                            p.move(to: CGPoint(x: g.size.width * 0.12, y: g.size.height * 0.12))
                            p.addLine(to: CGPoint(x: g.size.width * 0.88, y: g.size.height * 0.88))
                        }
                        .stroke(style: StrokeStyle(lineWidth: g.size.width * 0.05, lineCap: .round))
                    }
                }
            }
    }
}

/// The silhouette coming in from the bottom up, then the Guide button lighting in wine with one ring around it.
struct AnimatedPad: View {
    let kind: ControllerKind
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var revealed: CGFloat = 0
    @State private var opacity = 0.5
    @State private var lit = false
    @State private var ring = false

    var body: some View {
        GeometryReader { g in
            let point = PadIcon(kind: kind).guidePoint
            let scale = g.size.width / 64
            ZStack(alignment: .topLeading) {
                PadIcon(kind: kind)
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * revealed) }
                    .opacity(opacity)
                Circle().fill(CM.wineHi).frame(width: 5 * scale, height: 5 * scale)
                    .position(x: point.x * scale, y: point.y * scale).opacity(lit ? 1 : 0)
                Circle().strokeBorder(CM.wineHi, lineWidth: 1.5 * scale)
                    .frame(width: (ring ? 18 : 5) * scale, height: (ring ? 18 : 5) * scale)
                    .position(x: point.x * scale, y: point.y * scale).opacity(ring ? 0 : (lit ? 1 : 0))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            if reduceMotion { revealed = 1; opacity = 1; lit = true; return }
            withAnimation(.easeOut(duration: 0.7).delay(0.2)) { revealed = 1; opacity = 1 }
            withAnimation(.easeOut(duration: 0.15).delay(1.05)) { lit = true }
            withAnimation(.easeOut(duration: 1).delay(1.05)) { ring = true }
        }
    }
}

/// A number counting up to the battery level, with a bar filling to it.
struct CountingBattery: View {
    let level: Double
    var barWidth: CGFloat = 120
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var delay = 1.1
    @State private var shown: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Capsule().fill(CM.ivory.opacity(0.15)).frame(width: barWidth, height: 8)
                .overlay(alignment: .leading) { Capsule().fill(CM.ivory).frame(width: barWidth * shown, height: 8) }
            Text(verbatim: "\(Int((shown * 100).rounded()))%").monospacedDigit()
                .contentTransition(.numericText(value: shown))
        }
        .onAppear {
            if reduceMotion { shown = level; return }
            withAnimation(.easeOut(duration: 0.8).delay(delay)) { shown = level }
        }
    }
}

/// What is shown when a controller connects, in the ordinary window or in Controller Mode, and the Guide button
/// outside Controller Mode (it opens it, while Sommelier is the app in front).
@MainActor @Observable
final class ControllerArrival {
    static let shared = ControllerArrival()

    struct Pad: Equatable, Identifiable {
        let id = UUID()
        let name: String
        let kind: ControllerKind
        let battery: Double?
    }

    /// The card in the ordinary window, or the note in Controller Mode.
    var shown: Pad?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var hide: Task<Void, Never>?

    func start(model: AppModel) {
        self.model = model
        ControllerLog.file = model.paths.logs.appendingPathComponent("Controller.log")
        let input = ControllerInput.shared
        input.watchConnections()
        input.onConnect = { [weak self] pad in self?.connected(pad) }
        GCController.controllers().forEach(watchGuide)
        GCController.controllers().forEach { model.notePad(ControllerInput.kind(of: $0)) }
        // The Guide button from the device: opens Controller Mode from anywhere, works the menu inside it.
        let watcher = GuideButtonWatcher.shared
        watcher.onPress = { [weak self] in
            if ControllerModeWindow.shared.isOpen { ControllerInput.shared.guidePressed() }
            else if let model = self?.model {
                switch (model.settings.controllerMode ?? ControllerModeSettings()).guideButton {
                case .nothing: return
                case .whileInFront where !NSApp.isActive: return
                default: self?.dismiss(); ControllerModeWindow.shared.enter(model: model)
                }
            }
            ControllerModeWindow.shared.guideOpened()
        }
        watcher.onHold = { if ControllerModeWindow.shared.isOpen { ControllerInput.shared.guideHeld() } }
        watcher.start()
        // Started with a controller already on and the setting on: straight into Controller Mode.
        if (model.settings.controllerMode ?? ControllerModeSettings()).openWhenControllerConnects, !GCController.controllers().isEmpty {
            Task { try? await Task.sleep(for: .seconds(1)); ControllerModeWindow.shared.enter(model: model) }
        }
    }

    private func connected(_ pad: GCController) {
        guard let model else { return }
        model.notePad(ControllerInput.kind(of: pad))
        watchGuide(pad)
        let settings = model.settings.controllerMode ?? ControllerModeSettings()
        if !ControllerModeWindow.shared.isOpen, settings.openWhenControllerConnects {
            ControllerModeWindow.shared.enter(model: model)
            return
        }
        let level = pad.battery.flatMap { $0.batteryState == .unknown ? nil : Double($0.batteryLevel) }
        show(Pad(name: pad.vendorName ?? pad.productCategory, kind: ControllerInput.kind(of: pad), battery: level))
    }

    func show(_ pad: Pad) {
        withAnimation(.easeOut(duration: 0.45)) { shown = pad }
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(ControllerModeWindow.shared.isOpen ? 5.5 : 7))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    func dismiss() {
        hide?.cancel()
        withAnimation(.easeIn(duration: 0.4)) { shown = nil }
    }

    /// Outside Controller Mode the Guide button opens it (when Sommelier is in front), and any button closes the
    /// card. Inside, ControllerInput handles the buttons.
    private func watchGuide(_ pad: GCController) {
        guard let gamepad = pad.extendedGamepad else { return }
        // Ask the system to leave the Guide button to the app in front. macOS 26 may still take it (its game
        // overlay); macOS 27 lets the player give it to apps in System Settings.
        gamepad.buttonHome?.preferredSystemGestureState = .disabled
        gamepad.valueChangedHandler = { [weak self] _, element in
            MainActor.assumeIsolated {
                guard let self, !ControllerModeWindow.shared.isOpen, NSApp.isActive else { return }
                if element == gamepad.buttonHome { return }          // handled from the device (GuideButtonWatcher)
                if self.shown != nil, (element as? GCControllerButtonInput)?.isPressed == true {
                    self.dismiss()
                }
            }
        }
    }
}

/// The card at the top of the ordinary window when a controller connects.
struct ControllerConnectCard: View {
    let pad: ControllerArrival.Pad
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var step = 0

    var body: some View {
        HStack(spacing: 30) {
            AnimatedPad(kind: pad.kind).frame(width: 150, height: 150).foregroundStyle(CM.ivory)
            VStack(alignment: .leading, spacing: 8) {
                Text(pad.name).font(.system(size: 22, weight: .bold)).opacity(step >= 1 ? 1 : 0).offset(y: step >= 1 ? 0 : 8)
                Text("Connected").font(.system(size: 15)).foregroundStyle(CM.t2).opacity(step >= 2 ? 1 : 0).offset(y: step >= 2 ? 0 : 8)
                if let level = pad.battery {
                    CountingBattery(level: level, delay: reduceMotion ? 0 : 0.2).font(.system(size: 15, weight: .semibold))
                        .opacity(step >= 3 ? 1 : 0)
                }
                HStack(spacing: 6) {
                    Text("Press")
                    Circle().strokeBorder(CM.t2, lineWidth: 1.5).frame(width: 20, height: 20)
                        .overlay(PadIcon(kind: pad.kind).frame(width: 13, height: 13))
                    Text("to open Controller Mode")
                }
                .font(.system(size: 14)).foregroundStyle(CM.t2).padding(.top, 6).opacity(step >= 4 ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(CM.ivory)
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(width: 740)
        .background(CM.graphite.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(CM.line))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
        .onTapGesture { ControllerArrival.shared.dismiss() }
        .onAppear {
            if reduceMotion { step = 4; return }
            for (index, delay) in [0.35, 0.45, 0.9, 1.6].enumerated() {
                withAnimation(.easeOut(duration: 0.35).delay(delay)) { step = max(step, index + 1) }
            }
        }
    }
}

/// The smaller note in Controller Mode, under the top bar on the right.
struct ControllerConnectNote: View {
    let pad: ControllerArrival.Pad

    var body: some View {
        HStack(spacing: 18) {
            AnimatedPad(kind: pad.kind).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(pad.name).font(CM.font(24, .semibold))
                HStack(spacing: 0) {
                    Text("Connected")
                    if let level = pad.battery { Text(verbatim: ", "); CountingBattery(level: level, barWidth: 0, delay: 0.2).padding(.leading, -12) }
                }
                .font(CM.font(21)).foregroundStyle(CM.t2)
            }
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .background(CM.graphite.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(CM.line, lineWidth: 2))
    }
}
