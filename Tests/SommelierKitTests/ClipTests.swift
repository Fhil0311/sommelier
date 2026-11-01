// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct ReplayRingTests {
    typealias Ring = ReplayRing<Int>

    /// One second of video at 4 frames a second: a key frame, then three more.
    func feed(_ ring: inout Ring, seconds: Int, bytes: Int = 100) {
        for s in 0..<seconds {
            for f in 0..<4 { ring.append(.init(time: Double(s) + Double(f) * 0.25, isVideo: true, isKeyFrame: f == 0, bytes: bytes, payload: s * 4 + f)) }
        }
    }

    @Test func keepsTheLengthAndStartsOnAKeyFrame() {
        var ring = Ring(keeps: 10)
        feed(&ring, seconds: 40)
        #expect(ring.pieces.first?.isKeyFrame == true)
        #expect(ring.duration >= 9.5 && ring.duration <= 12)
        #expect(ring.byteCount == ring.pieces.reduce(0) { $0 + $1.bytes })
    }

    @Test func aClipIsNeverShorterThanAsked() {
        var ring = Ring(keeps: 30)
        feed(&ring, seconds: 100)
        let clip = ring.clip(last: 30)
        #expect(clip.first?.isKeyFrame == true)
        let span = (clip.last?.time ?? 0) - (clip.first?.time ?? 0)
        #expect(span >= 29.75)
        let short = ring.clip(last: 5)
        #expect(((short.last?.time ?? 0) - (short.first?.time ?? 0)) >= 4.75 && short.count < clip.count)
    }

    @Test func aClipAsksForMoreThanThereIs() {
        var ring = Ring(keeps: 60)
        feed(&ring, seconds: 8)
        #expect(ring.clip(last: 60).count == 32)
    }

    @Test func videoBeforeTheFirstKeyFrameIsLeftOut() {
        var ring = Ring(keeps: 10)
        ring.append(.init(time: 0, isVideo: true, isKeyFrame: false, bytes: 1, payload: 0))
        #expect(ring.isEmpty)
        ring.append(.init(time: 1, isVideo: true, isKeyFrame: true, bytes: 1, payload: 1))
        #expect(!ring.isEmpty)
    }

    @Test func soundFollowsTheClipStart() {
        var ring = Ring(keeps: 5)
        for s in 0..<30 {
            ring.append(.init(time: Double(s), isVideo: true, isKeyFrame: true, bytes: 10, payload: s))
            for k in 0..<10 { ring.append(.init(time: Double(s) + Double(k) * 0.1, isVideo: false, bytes: 5, payload: -1)) }
        }
        let clip = ring.clip(last: 5)
        let start = clip.first { $0.isVideo }!.time
        #expect(clip.filter { !$0.isVideo }.allSatisfy { $0.time >= start })
        #expect(clip.contains { !$0.isVideo })
    }

    @Test func memoryCeilingDropsOldGroups() {
        var ring = Ring(keeps: 1000, byteLimit: 2_000)
        feed(&ring, seconds: 60, bytes: 100)
        #expect(ring.byteCount <= 2_000 + 400)
        #expect(ring.pieces.first?.isKeyFrame == true)
    }

    @Test func shorteningTheRingTrims() {
        var ring = Ring(keeps: 60)
        feed(&ring, seconds: 100)
        ring.setKeeps(10)
        #expect(ring.duration < 13)
    }
}

@Suite struct ClipStoreTests {
    func store() -> (ClipStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clips-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (ClipStore(folder: root), root)
    }

    func write(_ clip: Clip, in store: ClipStore, bytes: Int = 10) -> URL {
        let url = store.newURL(game: clip.gameTitle, at: clip.date)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: url)
        store.save(clip, for: url)
        return url
    }

    func clip(_ id: String, origin: Clip.Origin = .key, at seconds: TimeInterval = 0, favorite: Bool = false) -> Clip {
        Clip(id: id, gameID: "steam:1", gameTitle: "Witcher: 3", date: Date(timeIntervalSince1970: 1_700_000_000 + seconds), seconds: 30,
             origin: origin, hasSound: true, favorite: favorite, quality: "Normal")
    }

    @Test func namesAreSafeAndUnique() throws {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(ClipStore.safeName("The Witcher 3: Wild/Hunt?") == "The Witcher 3 Wild Hunt")
        #expect(ClipStore.safeName("...") == "Game")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = store.newURL(game: "A/B", at: date)
        #expect(first.deletingLastPathComponent().lastPathComponent == "A B")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: first)
        #expect(store.newURL(game: "A/B", at: date) != first)
    }

    @Test func listsNewestFirstWithNotesAndSizes() throws {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        _ = write(clip("a", at: 0), in: store, bytes: 100)
        _ = write(clip("b", origin: .crash, at: 60, favorite: true), in: store, bytes: 200)
        let all = store.clips()
        #expect(all.count == 2)
        #expect(all.first?.origin == .crash && all.first?.favorite == true && all.first?.bytes == 200)
        #expect(ClipStore.totalBytes(all) == 300)
    }

    @Test func aVideoWithoutANoteIsListed() throws {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Hades II", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(count: 5).write(to: directory.appendingPathComponent("clip.mp4"))
        let all = store.clips()
        #expect(all.count == 1 && all[0].gameTitle == "Hades II" && all[0].origin == .key)
    }

    @Test func favoriteRenameAndDelete() throws {
        let (store, root) = store(); defer { try? FileManager.default.removeItem(at: root) }
        _ = write(clip("a"), in: store)
        var one = try #require(store.clips().first)
        store.setFavorite(true, for: one)
        one = try #require(store.clips().first)
        #expect(one.favorite)
        store.rename(one, to: "  Boss fight ")
        one = try #require(store.clips().first)
        #expect(one.name == "Boss fight")
        store.rename(one, to: one.gameTitle)
        #expect(try #require(store.clips().first).name == nil)
        store.delete(one)
        #expect(store.clips().isEmpty)
    }

    @Test func onlyOldAutomaticClipsMakeRoom() {
        func make(_ id: String, _ origin: Clip.Origin, _ t: TimeInterval, _ bytes: Int, fav: Bool = false) -> Clip {
            var c = clip(id, origin: origin, at: t, favorite: fav); c.bytes = bytes; return c
        }
        let all = [make("manual", .key, 0, 900), make("old", .crash, 10, 100), make("fav", .crash, 20, 100, fav: true),
                   make("mid", .crash, 30, 100), make("new", .crash, 40, 100)]
        let gone = ClipStore.clipsToRemove(from: all, limitBytes: 250).map(\.id)
        #expect(gone == ["old", "mid"])
        #expect(ClipStore.clipsToRemove(from: all, limitBytes: 10_000).isEmpty)
    }

    @Test func trimPointsSnapToTheTicks() {
        #expect(ClipStore.snapped(3.2, duration: 30) == 4)
        #expect(ClipStore.snapped(-1, duration: 30) == 0)
        #expect(ClipStore.snapped(31, duration: 30) == 30)
    }
}

@Suite struct ClipSettingsTests {
    @Test func defaultsAndKeyName() {
        let s = ClipSettings()
        #expect(!s.enabled && s.length == .minute && s.quality == .normal && s.keyName == "⌥⌘S")
        #expect(s.records("steam:1") == false)
    }

    @Test func oldOrBrokenValuesKeepDefaults() throws {
        let s = try JSONDecoder().decode(ClipSettings.self, from: Data(#"{"enabled":true,"length":45,"quality":"ultra","automaticLimitGB":0}"#.utf8))
        #expect(s.enabled && s.length == .minute && s.quality == .normal && s.automaticLimitGB == 1)
    }

    @Test func perGameSwitch() {
        var s = ClipSettings(); s.enabled = true; s.disabledGames = ["steam:2"]
        #expect(s.records("steam:1") && !s.records("steam:2"))
    }

    @Test func profilesAndKeys() {
        #expect(ClipSettings.Quality.light.profile.megabytesPerMinute == 90)
        #expect(ClipSettings.Quality.normal.profile.megabytesPerMinute == 187)
        #expect(ClipSettings.Quality.high.profile.megabytesPerMinute == 375)
        #expect(ClipSettings.isValidKey(code: 1, modifiers: 2304))
        #expect(!ClipSettings.isValidKey(code: 3, modifiers: 2304))        // ⌥⌘F is the counter's
        #expect(!ClipSettings.isValidKey(code: 1, modifiers: 0))           // a bare letter
    }
}
