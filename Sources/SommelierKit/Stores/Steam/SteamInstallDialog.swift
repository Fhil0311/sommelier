// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Tells when Steam's install dialog (a modal inside Steam's main window, not a window of its own) has closed.
///
/// Steam leaves two traces: `logs/console_log.txt` gets "Installs.CancelInstall" when Cancel is pressed, and
/// `logs/webhelper.txt` gets "WasHidden 0" when the page under the dialog shows again, which happens on any close,
/// Install included. A close followed by no app manifest means the user backed out.
public enum SteamInstallDialog {
    /// Where both logs end now; pass it to `closed(since:)` to read only what Steam writes after the click.
    public struct Mark: Sendable, Equatable {
        public let console: UInt64
        public let webhelper: UInt64
    }

    public static func mark(bottle: Bottle) -> Mark { mark(home: SteamHome(bottle: bottle)) }

    public static func mark(home: SteamHome) -> Mark {
        Mark(console: length(home.log("console_log.txt")), webhelper: length(home.log("webhelper.txt")))
    }

    /// Whether the dialog has closed since `mark`.
    public static func closed(since mark: Mark, bottle: Bottle) -> Bool { closed(since: mark, home: SteamHome(bottle: bottle)) }

    public static func closed(since mark: Mark, home: SteamHome) -> Bool {
        closed(console: appended(home.log("console_log.txt"), since: mark.console),
               webhelper: appended(home.log("webhelper.txt"), since: mark.webhelper))
    }

    /// Only the main window's page counts ("SteamBrowser-..."): other Steam windows, such as the Uninstall dialog,
    /// log "WasHidden 0" when they open.
    static func closed(console: String, webhelper: String) -> Bool {
        console.contains("Installs.CancelInstall")
            || webhelper.split(separator: "\n").contains { $0.contains("SteamBrowser") && $0.contains("WasHidden 0") }
    }

    static func length(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64) ?? 0
    }

    /// Text written after `offset`. A log that shrank (Steam started a new one) is read from the start.
    static func appended(_ url: URL, since offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: offset <= size ? offset : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}
