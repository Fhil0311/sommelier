// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct SteamInstallDialogTests {
    // Lines Steam wrote when its install dialog for Arkanoid was opened, then cancelled (October 2026).
    @Test func cancelAndCloseSignals() {
        #expect(SteamInstallDialog.closed(console: "[2026-10-19 21:43:17] STARTUP SlowJSMethodCall Installs.CancelInstall took 1.0ms",
                                          webhelper: ""))
        #expect(SteamInstallDialog.closed(console: "",
                                          webhelper: "[2026-10-19 21:43:17] SteamBrowser-'Welcome to': WasHidden 0: (1, 92) 1278x657"))
        // Another Steam window opening (the Uninstall dialog) isn't the install dialog closing.
        #expect(!SteamInstallDialog.closed(console: "",
                                           webhelper: "[2026-10-19 21:55:00] Uninstall-'Uninstall': WasHidden 0: (0, 0) 648x224"))
        // Opening the dialog hides the page: not a close.
        #expect(!SteamInstallDialog.closed(console: "[2026-10-19 21:42:42] ExecuteSteamURL: \"steam://install/1717270\"",
                                           webhelper: "[2026-10-19 21:42:42] SteamBrowser-'Welcome to': WasHidden 1: (1, 92) 1278x657"))
    }

    @Test func onlyLinesAfterTheMarkCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("somm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: root))
        let logs = bottle.steamDirectory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try "old: Installs.CancelInstall\n".write(to: logs.appendingPathComponent("console_log.txt"), atomically: true, encoding: .utf8)
        try "old: WasHidden 0\n".write(to: logs.appendingPathComponent("webhelper.txt"), atomically: true, encoding: .utf8)

        let mark = SteamInstallDialog.mark(bottle: bottle)
        #expect(!SteamInstallDialog.closed(since: mark, bottle: bottle))         // earlier dialogs don't count
        let handle = try FileHandle(forWritingTo: logs.appendingPathComponent("webhelper.txt"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("new: SteamBrowser-'Welcome to': WasHidden 0\n".utf8))
        try handle.close()
        #expect(SteamInstallDialog.closed(since: mark, bottle: bottle))
    }
}
