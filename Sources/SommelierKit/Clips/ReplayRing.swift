// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The last stretch of a game, kept as already compressed pieces. Video comes in groups that start with a key
/// frame, so the oldest group can be dropped whole and a clip always starts on a key frame. Generic over what a
/// piece carries (a sample buffer in the app, a number in tests).
public struct ReplayRing<Payload> {
    public struct Piece {
        public var time: Double                 // seconds on one clock for video and sound
        public var isVideo: Bool
        public var isKeyFrame: Bool
        public var bytes: Int
        public var payload: Payload

        public init(time: Double, isVideo: Bool, isKeyFrame: Bool = false, bytes: Int, payload: Payload) {
            self.time = time; self.isVideo = isVideo; self.isKeyFrame = isKeyFrame; self.bytes = bytes; self.payload = payload
        }
    }

    /// How much is kept: the longest clip, and a ceiling on memory (never hit in normal use).
    public private(set) var keeps: Double
    public let byteLimit: Int
    public private(set) var pieces: [Piece] = []
    public private(set) var byteCount = 0

    public init(keeps seconds: Double, byteLimit: Int = 1_500_000_000) {
        keeps = seconds; self.byteLimit = byteLimit
    }

    public mutating func setKeeps(_ seconds: Double) {
        keeps = seconds
        trim()
    }

    public mutating func clear() { pieces.removeAll(); byteCount = 0 }

    public var isEmpty: Bool { !pieces.contains { $0.isVideo } }

    /// How long what is kept runs, in seconds (from the first key frame to the last piece).
    public var duration: Double {
        guard let first = pieces.first(where: { $0.isVideo }), let last = pieces.last(where: { $0.isVideo }) else { return 0 }
        return last.time - first.time
    }

    public mutating func append(_ piece: Piece) {
        // Video before the first key frame can't start a clip: left out.
        if piece.isVideo, !piece.isKeyFrame, !pieces.contains(where: { $0.isVideo }) { return }
        // Sound before any video is kept only as far as video will reach back.
        pieces.append(piece)
        byteCount += piece.bytes
        trim()
    }

    /// The pieces of a clip of the last `seconds`: from the newest key frame at or before that point, so it is
    /// never shorter than asked (when that much is kept), with the sound from the same moment on. Empty when there
    /// is no video.
    public func clip(last seconds: Double) -> [Piece] {
        guard let newest = pieces.last(where: { $0.isVideo })?.time else { return [] }
        let wanted = newest - seconds
        var start: Int?
        for (index, piece) in pieces.enumerated() where piece.isVideo && piece.isKeyFrame {
            if piece.time <= wanted { start = index } else { if start == nil { start = index }; break }
        }
        guard let start else { return [] }
        let from = pieces[start].time
        return pieces[start...].filter { $0.isVideo || $0.time >= from }
    }

    private mutating func trim() {
        guard let newest = pieces.last(where: { $0.isVideo })?.time else {
            // Sound alone: no more than the ring's length.
            if let last = pieces.last?.time {
                pieces.removeAll { last - $0.time > keeps + 2 }
                byteCount = pieces.reduce(0) { $0 + $1.bytes }
            }
            return
        }
        // The oldest group goes while the next key frame still leaves the full length (or memory is over).
        while true {
            let keys = pieces.indices.filter { pieces[$0].isVideo && pieces[$0].isKeyFrame }
            guard keys.count >= 2 else { break }
            let next = keys[1]
            guard newest - pieces[next].time >= keeps || byteCount > byteLimit else { break }
            byteCount -= pieces[..<next].reduce(0) { $0 + $1.bytes }
            pieces.removeFirst(next)
        }
        // Sound older than the first video is of no use.
        if let first = pieces.first(where: { $0.isVideo })?.time, pieces.contains(where: { !$0.isVideo && $0.time < first - 1 }) {
            pieces.removeAll { !$0.isVideo && $0.time < first - 1 }
            byteCount = pieces.reduce(0) { $0 + $1.bytes }
        }
    }
}
