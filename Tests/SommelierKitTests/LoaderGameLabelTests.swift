// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct LoaderGameLabelTests {
    /// The loader's built-in plist as CrossOver 26.3 ships it (1074 bytes, with its comments).
    static let crossOverPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleAllowMixedLocalizations</key>
        <true/>
        <key>CFBundleDevelopmentRegion</key>
        <string>English</string>
        <key>CFBundleExecutable</key>
        <string>wineloader</string><!-- CrossOver Hack 10913 -->
        <key>CFBundleIdentifier</key>
        <string>com.codeweavers.CrossOver.wineloader</string><!-- CrossOver Hack 10913 -->
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>CrossOver-Hosted Application</string><!-- CrossOver Hack 10913 -->
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>11.0</string>
        <key>CFBundleSignature</key>
        <string>????</string>
        <key>CFBundleVersion</key>
        <string>11.0</string>
        <key>NSPrincipalClass</key>
        <string>WineApplication</string>
        <key>LSUIElement</key>
        <string>1</string>
    </dict>
    </plist>

    """

    /// A thin 64-bit Mach-O with one `__TEXT` segment holding `__info_plist` at `plist`, optionally signed.
    static func machO(plist: Data, padding: Int = 0, signed: Bool = false) -> (file: Data, range: Range<Int>) {
        var file = Data(count: 32)
        func put(_ value: UInt32, at: Int) { withUnsafeBytes(of: value.littleEndian) { file.replaceSubrange(at..<at + 4, with: $0) } }
        func put(_ text: String, at: Int) { var bytes = Array(text.utf8); bytes += [UInt8](repeating: 0, count: 16 - bytes.count); file.replaceSubrange(at..<at + 16, with: bytes) }
        let commandCount: UInt32 = signed ? 2 : 1
        put(0xFEED_FACF, at: 0); put(commandCount, at: 16)
        let segment = 32, sectionAt = segment + 72, commandEnd = sectionAt + 80
        file.append(Data(count: commandEnd - 32 + (signed ? 16 : 0)))
        put(0x19, at: segment); put(72 + 80, at: segment + 4); put("__TEXT", at: segment + 8); put(1, at: segment + 64)
        let dataStart = file.count + 64
        file.append(Data(count: 64))
        put("__info_plist", at: sectionAt); put("__TEXT", at: sectionAt + 16)
        let length = plist.count + padding
        withUnsafeBytes(of: UInt64(length).littleEndian) { file.replaceSubrange(sectionAt + 32..<sectionAt + 40, with: $0) }
        put(UInt32(dataStart), at: sectionAt + 48)
        if signed { put(0x1D, at: commandEnd); put(16, at: commandEnd + 4) }
        file.append(plist); file.append(Data(count: padding))
        return (file, dataStart..<dataStart + length)
    }

    @Test func findsTheSection() {
        let plist = Data(Self.crossOverPlist.utf8)
        let made = Self.machO(plist: plist, padding: 7)
        #expect(LoaderGameLabel.infoPlistSection(in: made.file) == made.range)
        #expect(LoaderGameLabel.infoPlistSection(in: Data("not a mach-o".utf8)) == nil)
        #expect(LoaderGameLabel.infoPlistSection(in: Self.machO(plist: plist, signed: true).file) == nil)
    }

    @Test func addsTheCategoryInTheSameRoom() throws {
        let plist = Data(Self.crossOverPlist.utf8)
        let labelled = try #require(LoaderGameLabel.labelled(plist: plist))
        #expect(labelled.count == plist.count)
        let parsed = try #require(PropertyListSerialization.propertyList(from: labelled, format: nil) as? [String: Any])
        #expect(parsed["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(parsed["LSSupportsGameMode"] as? Bool == true)
        #expect(parsed["LSUIElement"] as? String == "1")                      // the agent marker stays
        #expect(parsed["CFBundleIdentifier"] as? String == "com.codeweavers.CrossOver.wineloader")
        #expect(LoaderGameLabel.labelled(plist: labelled) == nil)              // done once
        let off = try #require(LoaderGameLabel.labelled(plist: labelled, on: false))
        #expect(off.count == plist.count)
        let parsedOff = try #require(PropertyListSerialization.propertyList(from: off, format: nil) as? [String: Any])
        #expect(parsedOff["LSApplicationCategoryType"] == nil && parsedOff["LSSupportsGameMode"] == nil)
        #expect(parsedOff["CFBundleIdentifier"] as? String == "com.codeweavers.CrossOver.wineloader")
        #expect(LoaderGameLabel.labelled(plist: off, on: false) == nil)
    }

    @Test func refusesWhenItWouldNotFit() {
        let tight = Data(#"<plist version="1.0"><dict><key>A</key><string>b</string></dict></plist>"#.utf8)
        #expect(LoaderGameLabel.labelled(plist: tight) == nil)
    }

    @Test func rewritesAFileInPlace() throws {
        let plist = Data(Self.crossOverPlist.utf8)
        let made = Self.machO(plist: plist)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try made.file.write(to: file)
        #expect(LoaderGameLabel.set(true, loaderAt: file))
        let after = try Data(contentsOf: file)
        #expect(after.count == made.file.count)
        #expect(after[..<made.range.lowerBound] == made.file[..<made.range.lowerBound])
        #expect(String(decoding: after[made.range], as: UTF8.self).contains("public.app-category.games"))
        #expect(!LoaderGameLabel.set(true, loaderAt: file))                       // already labelled
    }
}
