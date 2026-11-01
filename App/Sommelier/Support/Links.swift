// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit

/// Where players reach us (design: contacts.html): the Help menu, the About window (Credits.html) and the
/// "didn't start" sheet.
/// Mail and the site wait for the domain: until `mailReady`, only Discord shows.
enum Links {
    /// support@playsommelier.com and playsommelier.com work once the domain does (decided 23.10.2026).
    static let mailReady = false

    static let discord = URL(string: "https://discord.gg/6gmB6dc2J2")!
    static let site = URL(string: "https://playsommelier.com")!
    static let mailAddress = "support@playsommelier.com"

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    /// A new message with the versions in the subject, so we can help without asking: "Sommelier 1.3.2 · macOS 26.1 · Apple M4 Pro".
    static var mail: URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)"
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = mailAddress
        parts.queryItems = [URLQueryItem(name: "subject", value: "Sommelier \(appVersion) · macOS \(macOS) · \(MacSystem.current.chip)")]
        return parts.url
    }

    static func open(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    // The About window is macOS's own (its menu item stays translated in every language): the contact line under the
    // version comes from Credits.html in the app. When `mailReady` turns on, add the mail link there too.
}
