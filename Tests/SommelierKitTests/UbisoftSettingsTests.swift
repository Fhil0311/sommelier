// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SommelierKit

struct UbisoftSettingsTests {
    let settings = """
    misc:
      enable_auto_wall_posts: true
    overlay:
      enabled: true
      forceunhookgame: false
      fps_enabled: false
      warning_enabled: true
    user:
      offline: false

    """

    @Test func switchesOnlyTheOverlayOff() {
        let out = UbisoftSettings.overlayDisabled(settings)
        #expect(out.contains("overlay:\n  enabled: false\n  forceunhookgame: false\n  fps_enabled: false\n  warning_enabled: false\n"))
        #expect(out.contains("enable_auto_wall_posts: true"))   // other `true` values stay
        #expect(out.hasSuffix("offline: false\n"))
    }

    @Test func leavesAnAlreadyOffFileAlone() {
        let off = UbisoftSettings.overlayDisabled(settings)
        #expect(UbisoftSettings.overlayDisabled(off) == off)
    }

    @Test func addsTheBlockWhenMissing() {
        #expect(UbisoftSettings.overlayDisabled("") == "overlay:\n  enabled: false\n  warning_enabled: false\n")
        #expect(UbisoftSettings.overlayDisabled("user:\n  offline: false\n") == "user:\n  offline: false\noverlay:\n  enabled: false\n  warning_enabled: false\n")
    }
}
