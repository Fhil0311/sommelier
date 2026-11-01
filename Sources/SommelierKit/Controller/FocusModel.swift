// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation

/// Where a controller's focus goes next: the nearest thing in the direction pressed, as a console does it.
/// Pure geometry, so the screens only report where their things are.
public enum FocusModel {
    public enum Direction: Sendable { case up, down, left, right }

    public struct Target: Equatable, Sendable {
        public var id: String
        public var frame: CGRect
        public init(id: String, frame: CGRect) { self.id = id; self.frame = frame }
    }

    /// The target to move to from `current` among `targets`, or nil when there is nothing that way. Left and right
    /// stay in the row (a target that shares some height with the current one); up and down prefer the column but
    /// settle for anything in that direction. The nearest wins, sideways distance weighing three times.
    public static func next(from current: CGRect, towards direction: Direction, among targets: [Target], excluding currentID: String? = nil) -> Target? {
        let candidates = targets.filter { $0.id != currentID && !$0.frame.isEmpty && isAhead($0.frame, of: current, towards: direction) }
        let aligned = candidates.filter { overlaps($0.frame, current, across: direction) }
        switch direction {
        case .left, .right: return nearest(aligned, to: current, towards: direction)
        case .up, .down: return nearest(aligned, to: current, towards: direction) ?? nearest(candidates, to: current, towards: direction)
        }
    }

    private static func isAhead(_ frame: CGRect, of current: CGRect, towards direction: Direction) -> Bool {
        switch direction {
        case .left: frame.midX < current.midX - 4
        case .right: frame.midX > current.midX + 4
        case .up: frame.midY < current.midY - 4
        case .down: frame.midY > current.midY + 4
        }
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect, across direction: Direction) -> Bool {
        switch direction {
        case .left, .right: a.minY < b.maxY && b.minY < a.maxY
        case .up, .down: a.minX < b.maxX && b.minX < a.maxX
        }
    }

    private static func nearest(_ targets: [Target], to current: CGRect, towards direction: Direction) -> Target? {
        targets.min { distance($0.frame, current, direction) < distance($1.frame, current, direction) }
    }

    private static func distance(_ frame: CGRect, _ current: CGRect, _ direction: Direction) -> CGFloat {
        let dx = abs(frame.midX - current.midX), dy = abs(frame.midY - current.midY)
        switch direction {
        case .left, .right: return dx + dy * 3
        case .up, .down: return dy + dx * 3
        }
    }

    /// The first thing to focus on a screen: the top-left one.
    public static func first(among targets: [Target]) -> Target? {
        targets.filter { !$0.frame.isEmpty }.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }
}
