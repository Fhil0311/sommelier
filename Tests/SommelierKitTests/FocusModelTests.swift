// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import Testing
@testable import SommelierKit

@Suite struct FocusModelTests {
    typealias T = FocusModel.Target
    /// A row of three covers and a row of three below, plus a wide tab above.
    let targets = [
        T(id: "tab", frame: CGRect(x: 0, y: 0, width: 600, height: 40)),
        T(id: "a1", frame: CGRect(x: 0, y: 100, width: 100, height: 150)), T(id: "a2", frame: CGRect(x: 120, y: 100, width: 100, height: 150)),
        T(id: "a3", frame: CGRect(x: 240, y: 100, width: 100, height: 150)),
        T(id: "b1", frame: CGRect(x: 0, y: 300, width: 100, height: 150)), T(id: "b2", frame: CGRect(x: 120, y: 300, width: 100, height: 150)),
        T(id: "b3", frame: CGRect(x: 240, y: 300, width: 100, height: 150)),
    ]
    func frame(_ id: String) -> CGRect { targets.first { $0.id == id }!.frame }

    @Test func walksARowBeforeJumping() {
        #expect(FocusModel.next(from: frame("a1"), towards: .right, among: targets, excluding: "a1")?.id == "a2")
        #expect(FocusModel.next(from: frame("a3"), towards: .right, among: targets, excluding: "a3") == nil)
        #expect(FocusModel.next(from: frame("a2"), towards: .down, among: targets, excluding: "a2")?.id == "b2")
        #expect(FocusModel.next(from: frame("b3"), towards: .up, among: targets, excluding: "b3")?.id == "a3")
    }

    @Test func aWideThingAboveIsReachedFromAnyColumn() {
        #expect(FocusModel.next(from: frame("a3"), towards: .up, among: targets, excluding: "a3")?.id == "tab")
        #expect(FocusModel.next(from: frame("tab"), towards: .down, among: targets, excluding: "tab")?.id == "a3")   // the nearest to its centre
    }

    @Test func aColumnIsPreferredButNotRequired() {
        let far = T(id: "far", frame: CGRect(x: 900, y: 300, width: 100, height: 150))
        #expect(FocusModel.next(from: frame("a3"), towards: .down, among: [far, targets[0]], excluding: "a3")?.id == "far")
    }

    @Test func firstIsTopLeft() {
        #expect(FocusModel.first(among: targets)?.id == "tab")
        #expect(FocusModel.first(among: []) == nil)
    }

    @Test func settingsKeepDefaults() throws {
        let s = try JSONDecoder().decode(ControllerModeSettings.self, from: Data(#"{"size":"huge","labels":"xbox"}"#.utf8))
        #expect(s.size == .standard && s.labels == .xbox && s.keepDisplayAwake)
    }
}
