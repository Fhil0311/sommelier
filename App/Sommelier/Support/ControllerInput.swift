// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import IOKit.ps
@preconcurrency import GameController
import SommelierKit

/// What Controller Mode is told: a press, as the screen reads it, from any controller or from the keyboard
/// (arrows, Return, Esc and a few letters, so it can be tried and used without a controller).
enum ControllerEvent: Equatable {
    case move(FocusModel.Direction)
    case a, b, x, y, leftBumper, rightBumper, leftTrigger, rightTrigger, menu, view, guide
    /// The Guide button held for a second (the overlay later; logged for now).
    case guideHeld
}

/// Which family of buttons the controller in hand belongs to, for the glyphs at the bottom of the screen.
enum ControllerKind: Hashable { case xbox, playStation, other }

/// Reads controllers (GameController) and the keyboard and turns them into `ControllerEvent`s: the pad and the
/// left stick move the focus, with a repeat while held; the buttons map one to one. Only while Controller Mode is
/// up: outside it, nothing is read and nothing is taken from the games.
@MainActor @Observable
final class ControllerInput {
    static let shared = ControllerInput()

    /// Whether some controller is connected now.
    private(set) var connected = false
    private(set) var kind = ControllerKind.other
    /// 0…1, or nil when the controller doesn't say.
    private(set) var battery: Double?
    private(set) var charging = false
    /// Set while the player uses a controller or the keyboard; a mouse move clears it (and the focus ring with it).
    private(set) var usingController = false

    @ObservationIgnored var onEvent: ((ControllerEvent) -> Void)?
    @ObservationIgnored var onConnect: ((GCController) -> Void)?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var repeatTask: Task<Void, Never>?
    @ObservationIgnored private var held: FocusModel.Direction?
    @ObservationIgnored private var observers: [Any] = []
    @ObservationIgnored private var batteryTimer: Timer?

    private init() {}

    /// For the debug snapshot: act as if the controller were in use (no mouse hover takes the focus).
    func pretendControllerInUse() { usingController = true }

    /// Starts listening for controllers coming and going (for the "controller connected" note), always.
    func watchConnections() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let pad = note.object as? GCController
            MainActor.assumeIsolated {
                guard let self, let pad else { return }
                self.refreshControllers()
                if self.active { self.attach(pad) }
                self.onConnect?(pad)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
        })
        refreshControllers()
    }

    /// Controller Mode is up: read everything.
    func start() {
        guard !active else { return }
        active = true
        watchConnections()
        GCController.controllers().forEach(attach)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let mapped = Self.keyEvent(event) else { return event }
            self.usingController = true
            self.onEvent?(mapped)
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            self?.usingController = false
            return event
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshControllers() }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        GCController.controllers().forEach(detach)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        keyMonitor = nil; mouseMonitor = nil
        batteryTimer?.invalidate(); batteryTimer = nil
        repeatTask?.cancel(); repeatTask = nil; held = nil
    }

    private func refreshControllers() {
        let pads = GCController.controllers()
        connected = !pads.isEmpty
        let pad = GCController.current ?? pads.first
        kind = pad.map(Self.kind(of:)) ?? .other
        // Only a level the controller actually reports: "unknown" (a wired pad, or one that doesn't say) reads as
        // 0 and would show an empty battery.
        if let level = pad?.battery, level.batteryState != .unknown {
            battery = Double(level.batteryLevel)
            charging = level.batteryState == .charging || level.batteryState == .full
        } else {
            battery = nil
            charging = false
        }
    }

    static func kind(of pad: GCController) -> ControllerKind {
        if pad.extendedGamepad is GCXboxGamepad { return .xbox }
        if pad.extendedGamepad is GCDualShockGamepad || pad.extendedGamepad is GCDualSenseGamepad { return .playStation }
        // By what the pad says it is: a DualShock 4 over Bluetooth names itself "Wireless Controller".
        let names = [pad.productCategory, pad.vendorName ?? ""].map { $0.lowercased() }
        if names.contains(where: { $0.contains("xbox") }) { return .xbox }
        if names.contains(where: { $0.contains("dualshock") || $0.contains("dualsense") || $0.contains("playstation") || $0.contains("sony") || $0 == "wireless controller" }) { return .playStation }
        return .other
    }

    // MARK: Controllers

    private func attach(_ pad: GCController) {
        guard let gamepad = pad.extendedGamepad else { return }
        pad.handlerQueue = .main
        func button(_ input: GCControllerButtonInput?, _ event: ControllerEvent) {
            input?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.send(event) }
            }
        }
        button(gamepad.buttonA, .a); button(gamepad.buttonB, .b); button(gamepad.buttonX, .x); button(gamepad.buttonY, .y)
        button(gamepad.leftShoulder, .leftBumper); button(gamepad.rightShoulder, .rightBumper)
        button(gamepad.leftTrigger, .leftTrigger); button(gamepad.rightTrigger, .rightTrigger)
        button(gamepad.buttonMenu, .menu); button(gamepad.buttonOptions, .view)
        // The Guide button: the system's own action is asked to stand aside while Controller Mode is up (macOS 27
        // lets the player decide in System Settings; before that the system may still take it).
        // The Guide button comes from the device itself (GuideButtonWatcher): macOS keeps it from GameController.
        // The system is still asked to leave it alone, for the versions that listen.
        gamepad.buttonHome?.preferredSystemGestureState = .disabled
        let move: (GCControllerDirectionPad) -> Void = { pad in
            pad.valueChangedHandler = { [weak self] _, x, y in
                MainActor.assumeIsolated { self?.stick(x: x, y: y) }
            }
        }
        move(gamepad.dpad)
        move(gamepad.leftThumbstick)
    }

    private func detach(_ pad: GCController) {
        guard let gamepad = pad.extendedGamepad else { return }
        let buttons: [GCControllerButtonInput?] = [gamepad.buttonA, gamepad.buttonB, gamepad.buttonX, gamepad.buttonY, gamepad.leftShoulder,
                                                   gamepad.rightShoulder, gamepad.leftTrigger, gamepad.rightTrigger, gamepad.buttonMenu, gamepad.buttonOptions]
        for button in buttons { button?.pressedChangedHandler = nil }
        gamepad.buttonHome?.pressedChangedHandler = nil
        gamepad.buttonHome?.preferredSystemGestureState = .enabled
        gamepad.dpad.valueChangedHandler = nil
        gamepad.leftThumbstick.valueChangedHandler = nil
    }

    private func send(_ event: ControllerEvent) {
        usingController = true
        onEvent?(event)
    }

    /// A stick or pad: a direction once it is pushed past the middle, repeated while held (slow first, then quick).
    private func stick(x: Float, y: Float) {
        let direction: FocusModel.Direction?
        if abs(x) < 0.5 && abs(y) < 0.5 { direction = nil }
        else if abs(x) > abs(y) { direction = x > 0 ? .right : .left }
        else { direction = y > 0 ? .up : .down }
        guard direction != held else { return }
        held = direction
        repeatTask?.cancel(); repeatTask = nil
        guard let direction else { return }
        send(.move(direction))
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                guard let self, self.held == direction else { return }
                self.send(.move(direction))
                try? await Task.sleep(for: .milliseconds(95))
            }
        }
    }

    /// From `GuideButtonWatcher`, while Controller Mode is up.
    func guidePressed() { if active { send(.guide) } }
    func guideHeld() { if active { send(.guideHeld) } }

    // MARK: The keyboard

    static func keyEvent(_ event: NSEvent) -> ControllerEvent? {
        guard !event.modifierFlags.contains(.command) else { return nil }
        switch event.keyCode {
        case 126: return .move(.up)
        case 125: return .move(.down)
        case 123: return .move(.left)
        case 124: return .move(.right)
        case 36, 76: return .a                 // Return, Enter
        case 53: return .b                     // Esc
        case 51: return .b                     // Delete: back too
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g": return .guide
        case "y": return .y
        case "x": return .x
        case "q": return .leftBumper
        case "e": return .rightBumper
        case "[": return .leftTrigger
        case "]": return .rightTrigger
        case "m": return .menu
        default: return nil
        }
    }
}

/// `Logs/Controller.log`: what Controller Mode saw of the controller (the Guide button above all), a line each.
enum ControllerLog {
    nonisolated(unsafe) static var file: URL?
    private static let lock = NSLock()

    static func note(_ text: String) {
        guard let file else { return }
        lock.withLock {
            let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) ?? 0 > 500_000 { try? handle.truncate(atOffset: 0) }
                try? handle.write(contentsOf: line)
            } else { try? line.write(to: file) }
        }
    }
}

/// The Mac's own battery, for the top bar: nil on a Mac without one.
enum MacBattery {
    struct Reading: Equatable { var percent: Int; var charging: Bool; var onPower: Bool }

    static func read() -> Reading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Reading(percent: Int((Double(now) / Double(max) * 100).rounded()), charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           onPower: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
    }
}
