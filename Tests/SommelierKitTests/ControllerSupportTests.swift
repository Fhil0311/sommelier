// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct ControllerSupportTests {
    let winebus = #"HKLM\System\CurrentControlSet\Services\WineBus\Devices"#

    @Test func padListMatchesWhatWinebusTreatsAsSony() {
        // dlls/winebus.sys: is_dualshock4_gamepad and is_dualsense_gamepad.
        let ids = Set(ControllerSupport.playStationPads.map(\.productID))
        #expect(ids == [0x05c4, 0x09cc, 0x0ba0, 0x0ce6, 0x0df2])
        #expect(ids.count == ControllerSupport.playStationPads.count)
    }

    @Test func turningItOnSetsHidrawToZeroPerPad() {
        let enabling = ControllerSupport.registryCommands(playStationAsXbox: true)
        #expect(enabling.count == ControllerSupport.playStationPads.count)
        #expect(enabling.contains(["reg", "add", winebus + #"\054c/09cc"#, "/v", "Hidraw", "/t", "REG_DWORD", "/d", "0", "/f"]))
        for command in enabling {
            #expect(command.count == 10)
            // winebus reads the subkey with %04x: four lowercase hex digits each.
            #expect(command[2].range(of: #"\\054c/[0-9a-f]{4}$"#, options: .regularExpression) != nil, "\(command[2])")
        }
    }

    @Test func turningItOffDeletesExactlyThoseKeys() {
        let added = ControllerSupport.registryCommands(playStationAsXbox: true).map { $0[2] }
        let removed = ControllerSupport.registryCommands(playStationAsXbox: false)
        #expect(removed.map { $0[2] } == added)
        #expect(removed.allSatisfy { $0 == ["reg", "delete", $0[2], "/f"] })
    }

    static let samples: [(Int, Int, ControllerSupport.Kind)] = [
        (0x054c, 0x05c4, .playStation),
        (0x054c, 0x0df2, .playStation),
        (0x054c, 0x0268, .playStation),       // DualShock 3: a Sony pad too (Wine doesn't remap it, but it is one)
        (0x045e, 0x02ea, .xbox),
        (0x057e, 0x2009, .nintendo),
        (0x2dc8, 0x6001, .other),
    ]

    @Test(arguments: samples)
    func classifiesByUSBIDs(vendor: Int, product: Int, expected: ControllerSupport.Kind) {
        #expect(ControllerSupport.Kind.classify(vendorID: vendor, productID: product) == expected)
    }

    @Test func connectedDeviceDescribesItself() {
        let pad = ControllerSupport.Connected(name: "Backbone One", vendorID: 0x054c, productID: 0x09cc,
                                              locationID: 7, transport: "USB")
        #expect(pad.kind == .playStation)
        #expect(pad.idString == "054C:09CC")
        #expect(pad.id == "\(0x054c):\(0x09cc):7")
    }

    @Test func listingConnectedPadsNeverDuplicates() {
        // Depends on what's plugged in; it has to come back cleanly either way.
        let attached = ControllerSupport.connected()
        #expect(Set(attached.map(\.id)).count == attached.count)
        #expect(attached.map(\.name) == attached.map(\.name).sorted())
    }

    @Test func olderSettingsWithoutControllerFieldsDecode() throws {
        let json = Data(#"{"onboardingCompleted":true,"verboseLogs":false,"appliedRetina":{}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.playStationAsXbox == nil)       // nil reads as on
        #expect(settings.appliedControllerCompat == nil)
    }
}
