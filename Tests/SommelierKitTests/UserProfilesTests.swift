// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A throwaway bottle with a fake Mac home beside it, removed when the test ends.
private final class ProfileSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-profiles-\(UUID().uuidString)")
    var bottle: URL { root.appendingPathComponent("bottle") }
    var macHome: URL { root.appendingPathComponent("home") }
    var users: URL { bottle.appendingPathComponent("drive_c/users") }
    private let files = FileManager.default

    init() throws {
        for folder in [macHome.appendingPathComponent("Documents"), macHome.appendingPathComponent("Desktop"),
                       users.appendingPathComponent("Public")] {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// A Wine-style profile: AppData, Documents linked to the Mac, and Desktop either linked or a real folder
    /// holding CrossOver's "My Mac Desktop" link.
    @discardableResult func makeProfile(_ name: String, desktopLinked: Bool = true) throws -> URL {
        let profile = users.appendingPathComponent(name)
        try files.createDirectory(at: profile.appendingPathComponent("AppData/Local"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: profile.appendingPathComponent("Documents"),
                                     withDestinationURL: macHome.appendingPathComponent("Documents"))
        let desktop = profile.appendingPathComponent("Desktop")
        if desktopLinked {
            try files.createSymbolicLink(at: desktop, withDestinationURL: macHome.appendingPathComponent("Desktop"))
        } else {
            try files.createDirectory(at: desktop, withIntermediateDirectories: true)
            try files.createSymbolicLink(at: desktop.appendingPathComponent("My Mac Desktop"),
                                         withDestinationURL: macHome.appendingPathComponent("Desktop"))
        }
        return profile
    }

    func put(_ text: String, at file: URL, age: TimeInterval) throws {
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: age)], ofItemAtPath: file.path)
    }

    func text(_ file: URL) -> String? { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }
    func linkTarget(_ link: URL) -> String? { try? files.destinationOfSymbolicLink(atPath: link.path) }
    func isEmptyFolder(_ folder: URL) -> Bool { (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true }
}

@Suite struct UserProfilesTests {
    @Test func foldsTheCrossOverProfileInKeepingNewestFilesAndBackingUpTheRest() throws {
        let box = try ProfileSandbox()
        let mine = try box.makeProfile("mac")
        let shared = try box.makeProfile("crossover", desktopLinked: false)
        try box.put("only mine", at: mine.appendingPathComponent("AppData/Local/GameA/save.dat"), age: 100)
        try box.put("only shared", at: shared.appendingPathComponent("AppData/Local/GameB/deep/save.dat"), age: 300)
        try box.put("mine, stale", at: mine.appendingPathComponent("AppData/Local/GameC/s.dat"), age: 100)
        try box.put("shared, fresh", at: shared.appendingPathComponent("AppData/Local/GameC/s.dat"), age: 300)
        try box.put("mine, fresh", at: mine.appendingPathComponent("AppData/Local/GameD/s.dat"), age: 300)
        try box.put("shared, stale", at: shared.appendingPathComponent("AppData/Local/GameD/s.dat"), age: 100)

        let report = try UserProfiles.unify(bottle: box.bottle, userName: "mac", now: Date(timeIntervalSince1970: 500))

        #expect(report.linked)
        #expect(box.linkTarget(shared) == "mac")                    // relative link
        #expect(box.text(mine.appendingPathComponent("AppData/Local/GameA/save.dat")) == "only mine")
        #expect(box.text(mine.appendingPathComponent("AppData/Local/GameB/deep/save.dat")) == "only shared")
        #expect(box.text(mine.appendingPathComponent("AppData/Local/GameC/s.dat")) == "shared, fresh")
        #expect(box.text(mine.appendingPathComponent("AppData/Local/GameD/s.dat")) == "mine, fresh")
        #expect(report.moved.contains("AppData/Local/GameB"))
        #expect(report.moved.contains("AppData/Local/GameC/s.dat"))

        // Both losing copies survive in the backup, outside drive_c.
        let backup = try #require(report.backupFolder)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "profile-backups")
        #expect(backup.path.hasPrefix(box.bottle.path) && !backup.path.contains("/drive_c/"))
        #expect(box.text(backup.appendingPathComponent("AppData/Local/GameC/s.dat")) == "mine, stale")
        #expect(box.text(backup.appendingPathComponent("AppData/Local/GameD/s.dat")) == "shared, stale")
        #expect(Set(report.keptAside).isSuperset(of: ["AppData/Local/GameC/s.dat", "AppData/Local/GameD/s.dat"]))

        // Reading through the link now reaches the merged profile.
        #expect(box.text(shared.appendingPathComponent("AppData/Local/GameA/save.dat")) == "only mine")
    }

    @Test func linksOnBothSidesAreNotFollowed() throws {
        let box = try ProfileSandbox()
        let mine = try box.makeProfile("mac")                        // Desktop is a link to the Mac
        try box.makeProfile("crossover", desktopLinked: false)       // Desktop is a folder
        let report = try UserProfiles.unify(bottle: box.bottle, userName: "mac")

        #expect(box.isEmptyFolder(box.macHome.appendingPathComponent("Desktop")))
        #expect(box.isEmptyFolder(box.macHome.appendingPathComponent("Documents")))
        #expect(report.keptAside == ["Desktop"])                     // set aside, not merged into the Mac's Desktop
        #expect(box.linkTarget(mine.appendingPathComponent("Documents")) == box.macHome.appendingPathComponent("Documents").path)
        #expect(box.linkTarget(mine.appendingPathComponent("Desktop")) == box.macHome.appendingPathComponent("Desktop").path)
    }

    @Test func identicalLinksAreDroppedWithoutABackup() throws {
        let box = try ProfileSandbox()
        try box.makeProfile("mac")
        try box.makeProfile("crossover")                             // same Documents and Desktop links
        let report = try UserProfiles.unify(bottle: box.bottle, userName: "mac")
        #expect(report.linked)
        #expect(report.keptAside.isEmpty && report.backupFolder == nil)
        #expect(!FileManager.default.fileExists(atPath: box.bottle.appendingPathComponent("profile-backups").path))
    }

    @Test func withoutACrossOverFolderOnlyTheLinkIsMadeAndASecondRunDoesNothing() throws {
        let box = try ProfileSandbox()
        try box.makeProfile("mac")
        let first = try UserProfiles.unify(bottle: box.bottle, userName: "mac")
        #expect(first.linked)
        #expect(first.moved.isEmpty && first.keptAside.isEmpty && first.backupFolder == nil)
        #expect(box.linkTarget(box.users.appendingPathComponent("crossover")) == "mac")

        #expect(try UserProfiles.unify(bottle: box.bottle, userName: "mac") == UserProfiles.Report())
    }

    @Test func refusesWhenThereIsNoRealProfileOrTheNameIsCrossOver() throws {
        let box = try ProfileSandbox()
        let shared = try box.makeProfile("crossover")
        #expect(try UserProfiles.unify(bottle: box.bottle, userName: "mac") == UserProfiles.Report())
        #expect(try UserProfiles.unify(bottle: box.bottle, userName: "crossover") == UserProfiles.Report())
        #expect(try UserProfiles.unify(bottle: box.bottle, userName: "") == UserProfiles.Report())
        #expect(box.linkTarget(shared) == nil)                       // still a real folder
    }
}
