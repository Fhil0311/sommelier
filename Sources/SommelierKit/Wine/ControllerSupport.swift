// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

/// Game controllers: what the Mac has plugged in, and how Wine should present PlayStation pads.
///
/// By default Wine hands Sony pads to games as raw HID ("hidraw") and hides their XInput side, so a game that only
/// speaks XInput finds no controller. That includes the Backbone One PlayStation Edition, which reports itself as
/// a DualShock 4 (054C:09CC). A `Hidraw` value of 0 under winebus's per-device key turns XInput back on for that
/// pad (checked on a Backbone One: an `XI_00` device appears). The product list matches the pads Wine's winebus
/// itself treats as DualShock 4 or DualSense.
public enum ControllerSupport {
    /// Sony's USB vendor ID.
    public static let sonyVendor: UInt16 = 0x054c

    /// A Sony pad model, by USB product ID.
    public struct Pad: Sendable, Equatable {
        public let productID: UInt16
        public let name: String
    }

    public static let playStationPads = [
        (0x05c4, "DualShock 4"),
        (0x09cc, "DualShock 4, second model (the Backbone One PlayStation Edition says it is one)"),
        (0x0ba0, "DualShock 4 USB wireless adapter"),
        (0x0ce6, "DualSense"),
        (0x0df2, "DualSense Edge"),
    ].map { Pad(productID: $0.0, name: $0.1) }

    /// winebus's per-device options live under this key, in `<vendor>/<product>` subkeys (lowercase hex, 4 digits).
    static let devicesKey = #"HKLM\System\CurrentControlSet\Services\WineBus\Devices"#

    static func deviceKey(_ pad: Pad) -> String {
        devicesKey + "\\" + String(format: "%04x/%04x", sonyVendor, pad.productID)
    }

    /// `wine` argument lists that switch PlayStation pads to XInput (`Hidraw` = 0 for each), or back to Wine's
    /// default by deleting those keys. Pure, for tests.
    public static func registryCommands(playStationAsXbox enabled: Bool) -> [[String]] {
        let tail = enabled ? ["/v", "Hidraw", "/t", "REG_DWORD", "/d", "0", "/f"] : ["/f"]
        return playStationPads.map { ["reg", enabled ? "add" : "delete", deviceKey($0)] + tail }
    }

    // MARK: Connected controllers

    /// The family a controller belongs to, from its USB IDs.
    public enum Kind: String, Sendable {
        case playStation, xbox, nintendo, other

        public static func classify(vendorID: Int, productID: Int) -> Kind {
            switch vendorID {
            case 0x045e:
                return .xbox
            case 0x057e:
                return .nintendo
            case Int(sonyVendor):           // any Sony pad, the listed ones and others (a DualShock 3, a new model)
                return .playStation
            default:
                return .other
            }
        }
    }

    /// A controller the Mac sees right now.
    public struct Connected: Sendable, Equatable, Identifiable {
        public let name: String
        public let vendorID: Int
        public let productID: Int
        /// Where it's attached; tells two identical pads apart.
        public let locationID: Int
        /// "USB", "Bluetooth"… as IOKit reports it.
        public let transport: String

        public var kind: Kind { .classify(vendorID: vendorID, productID: productID) }
        public var id: String { [vendorID, productID, locationID].map(String.init).joined(separator: ":") }
        /// `VVVV:PPPP` in uppercase hex, the usual way to write USB IDs.
        public var idString: String { [vendorID, productID].map { String(format: "%04X", $0) }.joined(separator: ":") }
    }

    /// Joysticks and gamepads currently attached, sorted by name, each once. Reads the I/O Registry only and opens
    /// no device: no Input Monitoring permission, and no interference with a game using the pad.
    public static func connected() -> [Connected] {
        var services: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &services) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(services) }

        var pads: [String: Connected] = [:]
        while true {
            let service = IOIteratorNext(services)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let pad = controller(service), pads[pad.id] == nil { pads[pad.id] = pad }
        }
        return pads.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// The controller behind one HID service, or nil for keyboards, mice and the like. Generic Desktop page (1),
    /// usages Joystick (4) and Game Pad (5).
    private static func controller(_ service: io_registry_entry_t) -> Connected? {
        func read<T>(_ key: String, as type: T.Type) -> T? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
        }
        let usage = read("PrimaryUsage", as: Int.self)
        guard read("PrimaryUsagePage", as: Int.self) == 1, usage == 4 || usage == 5 else { return nil }
        return Connected(name: read("Product", as: String.self) ?? "Game controller",
                         vendorID: read("VendorID", as: Int.self) ?? 0,
                         productID: read("ProductID", as: Int.self) ?? 0,
                         locationID: read("LocationID", as: Int.self) ?? 0,
                         transport: read("Transport", as: String.self) ?? "")
    }
}

public extension WineRunner {
    /// Applies or removes the PlayStation-as-Xbox keys in `bottle`; Wine picks them up on its next start there.
    /// Deleting keys that aren't there does no harm.
    func applyControllerCompatibility(playStationAsXbox enabled: Bool, engine: Engine, bottle: Bottle) async {
        let env = Self.environment(bottle: bottle, profile: .init())
        for command in ControllerSupport.registryCommands(playStationAsXbox: enabled) {
            _ = try? await ProcessRunner.run(engine.wine, command, environment: env)
        }
    }
}
