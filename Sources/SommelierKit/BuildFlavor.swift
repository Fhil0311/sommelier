// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Whether this is the development build (bundle identifier `gg.sommelier.app.dev`, what the Debug configuration
/// makes). It has a folder, a link scheme and shortcuts of its own, so it can run beside the released Sommelier
/// without the two touching each other's games, settings or links. Anything else (the release, tests) is the real one.
public enum BuildFlavor: Sendable {
    public static var isDevelopment: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true }
}
