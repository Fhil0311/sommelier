// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct ChromiumHelperWrapperTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-wrapper-\(UUID().uuidString)")
    var helper: URL { folder.appendingPathComponent("SocialClubHelper.exe") }
    var original: URL { folder.appendingPathComponent("SocialClubHelper_real.exe") }
    let vendorBinary = Data("MZ the vendor's chromium helper".utf8)
    let currentWrapper = Data("MZ current wrapper | ".utf8) + ChromiumHelperWrapper.marker

    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    private func contents(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    @Test func firstWrapMovesTheVendorBinaryAside() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try vendorBinary.write(to: helper)
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper))
        #expect(contents(helper) == currentWrapper)
        #expect(contents(original) == vendorBinary)

        // Already wrapped: nothing is written and the saved binary survives.
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper) == false)
        #expect(contents(original) == vendorBinary)
    }

    @Test func olderWrapperIsReplacedInPlace() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try (Data("MZ earlier wrapper | ".utf8) + ChromiumHelperWrapper.marker).write(to: helper)
        try vendorBinary.write(to: original)
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper))
        #expect(contents(helper) == currentWrapper)
        #expect(contents(original) == vendorBinary)
    }

    @Test func restoredVendorBinaryReplacesTheSavedOne() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try vendorBinary.write(to: original)
        let update = Data("MZ the vendor's chromium helper, updated".utf8)
        try update.write(to: helper)   // an installer or repair put its own helper back
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper))
        #expect(contents(original) == update)
        #expect(contents(helper) == currentWrapper)
    }

    @Test func interruptedSwapIsCompleted() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try vendorBinary.write(to: original)   // the helper itself is gone
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper))
        #expect(contents(helper) == currentWrapper)
        #expect(contents(original) == vendorBinary)
    }

    @Test func absentHelperIsNotCreated() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper) == false)
        #expect(contents(helper) == nil)
        // A "saved original" that is itself a wrapper doesn't count either.
        try currentWrapper.write(to: original)
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper) == false)
        #expect(contents(helper) == nil)
    }

    @Test func wrapperWithoutItsOriginalIsAnError() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try (Data("MZ earlier wrapper | ".utf8) + ChromiumHelperWrapper.marker).write(to: helper)
        #expect(throws: WineRunnerError.self) { _ = try ChromiumHelperWrapper.wrap(helper, with: currentWrapper) }
        try Data().write(to: original)
        #expect(throws: WineRunnerError.self) { _ = try ChromiumHelperWrapper.wrap(helper, with: currentWrapper) }
    }

    @Test func emptyWrapperIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try vendorBinary.write(to: helper)
        #expect(throws: WineRunnerError.self) { _ = try ChromiumHelperWrapper.wrap(helper, with: Data()) }
        #expect(contents(helper) == vendorBinary)
    }

    @Test func legacyModeTreatsSmallUnmarkedFilesAsOldWrappers() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let unmarkedWrapper = Data("MZ steamwebhelper_real.exe only".utf8)
        try unmarkedWrapper.write(to: helper)
        try vendorBinary.write(to: original)
        #expect(try ChromiumHelperWrapper.wrap(helper, with: currentWrapper, legacyWrapper: true))
        #expect(contents(original) == vendorBinary)   // not overwritten by the old wrapper
        #expect(contents(helper) == currentWrapper)
    }

    @Test func choosesTheAppsWrapperBeforeAGenericEngineWrapper() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"version":"1.0.0","wineVersion":"11.0","backends":["dxvk"],"minMacOS":"14.0"}"#
            .write(to: folder.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let published = try #require(Engine(directory: folder))
        let bundled = folder.appendingPathComponent("chromium-helper-wrapper.exe")

        // Engine 1.0.0 shipped a Steam-only wrapper without the marker.
        try Data("MZ steamwebhelper_real.exe only".utf8).write(to: published.steamWebHelperWrapper)
        #expect(ChromiumHelperWrapper.wrapper(in: published, bundled: nil) == nil, "the old wrapper isn't generic")
        #expect(ChromiumHelperWrapper.wrapper(in: published, bundled: bundled) == nil)   // not built into the app either

        try currentWrapper.write(to: bundled)
        #expect(ChromiumHelperWrapper.wrapper(in: published, bundled: bundled) == currentWrapper)

        let engineWrapper = Data("MZ engine wrapper | ".utf8) + ChromiumHelperWrapper.marker
        try engineWrapper.write(to: published.steamWebHelperWrapper)
        #expect(ChromiumHelperWrapper.wrapper(in: published, bundled: nil) == engineWrapper)
        #expect(ChromiumHelperWrapper.wrapper(in: published, bundled: bundled) == currentWrapper)
    }

    @Test func applyWrapsTheSocialClubHelperInABottle() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = Paths(home: folder.appendingPathComponent("home"))
        let bottle = Bottle(kind: .steam, paths: paths)
        let socialClub = bottle.driveC.appendingPathComponent(ChromiumHelperWrapper.helpers[0])
        try FileManager.default.createDirectory(at: socialClub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bottle.driveC.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try vendorBinary.write(to: socialClub)
        try #"{"version":"1.0.0","wineVersion":"11.0","backends":["dxvk"],"minMacOS":"14.0"}"#
            .write(to: folder.appendingPathComponent("ENGINE.json"), atomically: true, encoding: .utf8)
        let engine = try #require(Engine(directory: folder))
        let bundled = folder.appendingPathComponent("chromium-helper-wrapper.exe")
        try currentWrapper.write(to: bundled)

        #expect(ChromiumHelperWrapper.apply(to: bottle, engine: engine, bundled: bundled) == ChromiumHelperWrapper.helpers)
        #expect(contents(socialClub) == currentWrapper)
        #expect(ChromiumHelperWrapper.apply(to: bottle, engine: engine, bundled: bundled).isEmpty)
    }

    @Test func markerIsSommeliersGenericWrapperTag() {
        #expect(String(decoding: ChromiumHelperWrapper.marker, as: UTF8.self) == "sommelier-chromium-wrapper/2")
    }
}
