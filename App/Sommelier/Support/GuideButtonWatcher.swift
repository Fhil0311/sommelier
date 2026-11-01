// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import IOKit.hid
import SommelierKit

/// The controller's Guide button (PS, Xbox), read from the device itself (IOKit HID), below the layer where macOS
/// takes it for its own use: the system's game overlay and app shortcut never reach apps through GameController
/// on macOS 26. Reports come whether Sommelier is in front or not, so the button can open Controller Mode from
/// anywhere. Only this one button is read here; everything else stays with GameController.
@MainActor
final class GuideButtonWatcher {
    static let shared = GuideButtonWatcher()

    private var manager: IOHIDManager?
    private var pressed: [UInt32: Bool] = [:]        // by device registry id
    private var pressedAt: Date?
    var onPress: (() -> Void)?
    var onHold: (() -> Void)?
    private var holdTask: Task<Void, Never>?

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_MultiAxisController],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        // Only the buttons: the sticks report constantly and are of no interest here.
        IOHIDManagerSetInputValueMatchingMultiple(manager, [[kIOHIDElementUsagePageKey: kHIDPage_Button],
                                                            [kIOHIDElementUsagePageKey: kHIDPage_Consumer]] as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let watcher = Unmanaged<GuideButtonWatcher>.fromOpaque(context).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
            let down = IOHIDValueGetIntegerValue(value) != 0
            let device = IOHIDElementGetDevice(element)
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            let id = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? UInt32) ?? UInt32(product)
            MainActor.assumeIsolated { watcher.input(page: page, usage: usage, down: down, vendor: vendor, product: product, device: id) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        ControllerLog.note("guide watcher: HID manager \(opened == kIOReturnSuccess ? "open" : "failed \(opened)")")
        self.manager = manager
    }

    /// Which report is the Guide button: Sony pads say Button 13 (DualShock 4, DualSense, over USB and
    /// Bluetooth); Xbox pads say Consumer "AC Home" (0x223) over Bluetooth, Button 11/13 on some firmware. Anything
    /// else is logged once per usage, so an unknown pad's button can be found in the log and added.
    private func isGuide(page: UInt32, usage: UInt32, vendor: Int, product: Int) -> Bool {
        let kind = ControllerSupport.Kind.classify(vendorID: vendor, productID: product)
        switch (page, usage) {
        case (UInt32(kHIDPage_Consumer), 0x223), (UInt32(kHIDPage_Consumer), 0x40):       // AC Home, Menu
            return true
        case (UInt32(kHIDPage_Button), 13): return kind == .playStation || kind == .other
        case (UInt32(kHIDPage_Button), 11), (UInt32(kHIDPage_Button), 17): return kind == .xbox
        case (UInt32(kHIDPage_Button), 13): return kind == .nintendo      // Switch Pro: Home is button 13 too
        default: return false
        }
    }

    private var seen: Set<String> = []

    private func input(page: UInt32, usage: UInt32, down: Bool, vendor: Int, product: Int, device: UInt32) {
        let key = "\(vendor):\(product):\(page):\(usage)"
        if down, !seen.contains(key) {
            seen.insert(key)
            ControllerLog.note(String(format: "guide watcher: pad %04x:%04x pressed page 0x%x usage 0x%x", vendor, product, page, usage))
        }
        guard isGuide(page: page, usage: usage, vendor: vendor, product: product) else { return }
        let was = pressed[device] ?? false
        pressed[device] = down
        if down, !was {
            pressedAt = Date()
            ControllerLog.note("guide button down (HID)")
            holdTask?.cancel()
            holdTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.pressed[device] == true else { return }
                self.pressedAt = nil
                self.onHold?()
            }
        } else if !down, was {
            holdTask?.cancel()
            if pressedAt != nil { pressedAt = nil; onPress?() }
        }
    }
}
