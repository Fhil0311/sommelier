// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct WindowsIconTests {
    @Test func notAProgramHasNoIcon() {
        #expect(WindowsIcon.extract(fromImage: [UInt8](repeating: 0, count: 512)) == nil)
        #expect(WindowsIcon.extract(fromImage: Array("MZ".utf8) + [UInt8](repeating: 0xFF, count: 200)) == nil)
    }
}
