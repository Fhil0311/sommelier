// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import SommelierKit

struct DockVisibilityTests {
    @Test func hidesEachLauncherProgram() {
        let reg = DockVisibility.registryFile(for: .ea)
        #expect(reg.hasPrefix("REGEDIT4\n"))
        #expect(reg.contains(#"[HKEY_CURRENT_USER\Software\Wine\AppDefaults\EADesktop.exe\Mac Driver]"# + "\n\"ShowInDock\"=\"n\""))
        #expect(DockVisibility.registryFile(for: .epic) == "REGEDIT4\n")   // Epic and GOG hold only games
    }
}
