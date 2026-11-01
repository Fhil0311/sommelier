// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import IOKit.pwr_mgt
import SommelierKit
import SwiftUI

/// Controller Mode's window: the whole of one display, black around a 1920×1080 picture scaled to fit, with the
/// cursor hidden while a controller is in use. One at a time; entering again brings it forward.
@MainActor
final class ControllerModeWindow {
    static let shared = ControllerModeWindow()

    private var window: NSWindow?
    /// The ordinary windows put away while Controller Mode is up, to come back when it closes.
    private var hidden: [NSWindow] = []
    private weak var model: AppModel?
    private var sleepAssertion: IOPMAssertionID = 0
    private var observers: [Any] = []

    var isOpen: Bool { window != nil }

    func enter(model: AppModel) {
        self.model = model
        model.settings.usageControllerMode = true
        ControllerLog.file = model.paths.logs.appendingPathComponent("Controller.log")
        if let window { window.makeKeyAndOrderFront(nil); Self.comeToFront(); return }
        let settings = model.settings.controllerMode ?? ControllerModeSettings()
        let screen = NSScreen.screens.first { $0.localizedName == settings.display } ?? NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false, screen: screen)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        window.title = "Sommelier"
        CM.fit(screen.frame.size, size: settings.size)
        CM.background = settings.background
        window.contentView = NSHostingView(rootView: ControllerModeView(screenSize: screen.frame.size).environment(model).environment(model.artwork))
        window.setFrame(screen.frame, display: true)
        self.window = window
        // Only Controller Mode on screen: the ordinary window would come forward with the app and sit over it.
        hidden = NSApp.windows.filter { $0 !== window && $0.isVisible && !($0 is NSPanel) }
        hidden.forEach { $0.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        Self.comeToFront()
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        ControllerInput.shared.start()
        if settings.keepDisplayAwake { keepAwake(true) }
        ControllerLog.note("entered on \(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))")
        // The game's window came up: let it have the cursor; back in front: hide it again.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ControllerModeWindow.shared.frontChanged() }
        })
    }

    func exit() {
        guard let window else { return }
        ControllerInput.shared.stop()
        keepAwake(false)
        NSCursor.unhide()
        NSApp.presentationOptions = []
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        window.orderOut(nil)
        self.window = nil
        ControllerLog.note("left")
        // Back to the ordinary window(s).
        hidden.forEach { $0.makeKeyAndOrderFront(nil) }
        hidden.removeAll()
        NSApp.activate()
    }

    /// Brings Controller Mode back in front (when a game quit, or "Return" was chosen from elsewhere).
    /// In front of whatever is there: the Guide button is pressed from anywhere, and macOS 14+ only takes an
    /// app forward on its own say-so when asked this way.
    static func comeToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [])
        shared.window?.makeKeyAndOrderFront(nil)
    }

    /// When the Guide button was last pressed: macOS acts on it too (its game overlay or app) right after
    /// Sommelier did, and takes the front; for a couple of seconds after, Sommelier takes it back.
    private var guidePressedAt: Date?

    func guideOpened() {
        guidePressedAt = Date()
        for delay in [0.5, 1.1, 2.0] {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, self.window != nil, let at = self.guidePressedAt, Date().timeIntervalSince(at) < 2.5, !NSApp.isActive else { return }
                ControllerLog.note("guide: taking the front back from \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                self.comeForward()
            }
        }
    }

    func comeForward() {
        guard let window else { return }
        Self.comeToFront()
        window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }

    private func frontChanged() {
        guard window != nil else { return }
        if NSApp.isActive { NSApp.presentationOptions = [.hideDock, .hideMenuBar]; return }
        NSApp.presentationOptions = []; NSCursor.unhide()
        // Lost the front right after the Guide button: that's the system acting on the same press.
        if let at = guidePressedAt, Date().timeIntervalSince(at) < 2.5 {
            Task { [weak self] in try? await Task.sleep(for: .milliseconds(250)); self?.comeForward() }
        }
    }

    func setCursorHidden(_ hidden: Bool) {
        guard window != nil, NSApp.isActive else { return }
        if hidden { NSCursor.hide() } else { NSCursor.unhide() }
    }

    private func keepAwake(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Sommelier Controller Mode" as CFString, &sleepAssertion)
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
