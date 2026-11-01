// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import SommelierKit

/// The menu on Sommelier's Dock icon (right click): the store launchers open now (Steam, EA app, Ubisoft Connect,
/// Battle.net), like a browser lists its windows. Launchers have no Dock icon of their own (see `DockVisibility`),
/// so this is how to get one back when its window is lost. Each has Show Window (forward, or opened again when it
/// hides in the background) and Quit (for real, which closing its window doesn't do).
@MainActor
final class SommelierAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    /// Opens the main window again (set by the window's content: SwiftUI's `openWindow`).
    var openMainWindow: (() -> Void)?

    /// Closing the window keeps Sommelier running, as Mac apps do: games and downloads go on, and the Dock icon
    /// brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The chosen appearance before any window appears, so a light Sommelier never flashes dark.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let settings = JSONStore<AppSettings>(url: Paths().settingsFile).load(default: AppSettings())
        AppAppearance(setting: settings.appearance).apply()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMainWindow?() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        let running = WineWindows.programs(enginesFolder: model.paths.engines.path)
        for kind in [StoreKind.steam, .ea, .ubisoft, .battlenet] where running.contains(where: { Self.isLauncher(kind, $0.commandLine) }) {
            let item = NSMenuItem(title: kind.displayName, action: nil, keyEquivalent: "")
            let actions = NSMenu()
            for (title, action) in [(String(localized: "Show Window"), #selector(showLauncher(_:))),
                                    (String(localized: "Quit"), #selector(quitLauncher(_:)))] {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self
                entry.representedObject = kind.rawValue
                actions.addItem(entry)
            }
            item.submenu = actions
            item.image = NSImage(named: kind.logoName).map { image in
                let copy = image.copy() as! NSImage
                copy.size = NSSize(width: 16, height: 16)
                copy.isTemplate = true
                return copy
            }
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// Whether an engine process belongs to a store's launcher (its games, which run from inside some launchers'
    /// folders, don't count).
    static func isLauncher(_ kind: StoreKind, _ commandLine: String) -> Bool {
        let line = commandLine.lowercased()
        switch kind {
        case .steam: return line.contains(#"\steam\"#) && !line.contains("steamapps")
        case .ea: return line.contains(#"\ea desktop\"#)
        case .ubisoft: return line.contains(#"\ubisoft game launcher\"#) && !line.contains(#"\games\"#)
        // The client and its Agent (which Wine shows with forward slashes); games install beside it, not inside.
        case .battlenet: return line.contains(#"\battle.net\"#) || line.contains("/battle.net/")
        default: return false
        }
    }

    @objc private func showLauncher(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = StoreKind(rawValue: raw) else { return }
        Task { await model?.showLauncher(kind) }
    }

    /// Quits the launcher for real, background processes too (closing its window only sends it to the tray).
    @objc private func quitLauncher(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = StoreKind(rawValue: raw) else { return }
        Task { await model?.quitLauncher(kind) }
    }

    private var closing = false

    /// Quitting Sommelier closes everything it started: the store launchers, their downloads, and running games,
    /// so nothing of it is left running without a window to get back to. Asked first when that loses something:
    /// a running game (unsaved progress), a download (it stops). When the Mac logs out or shuts down, nothing is
    /// asked.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Updater.log("quit requested (model: \(model != nil), closing: \(closing), relaunching: \(AppLanguage.isRelaunching))")
        guard let model, !closing, !AppLanguage.isRelaunching else { return .terminateNow }
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        let systemQuit = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShutDown, kAEShowShutdownDialog]
            .map { OSType($0) }.contains(reason ?? 0)
        if !systemQuit {
            let games = model.runningGames
            if let game = games.first {
                let alert = NSAlert()
                alert.messageText = games.count == 1 ? String(localized: "\(game.title) is still running") : String(localized: "Games are still running")
                alert.informativeText = games.count == 1 ? String(localized: "If you quit Sommelier, the game closes too. Unsaved progress is lost.")
                    : String(localized: "If you quit Sommelier, the games close too. Unsaved progress is lost.")
                alert.addButton(withTitle: String(localized: "Exit"))
                alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
                if alert.runModal() != .alertFirstButtonReturn { AppLanguage.cancelRelaunch(); return .terminateCancel }
            }
            if let download = model.launcherDownloadsOnQuit().first {
                let alert = NSAlert()
                alert.messageText = String(localized: "\(download.game.title) is still downloading")
                alert.informativeText = String(localized: "If you quit Sommelier, the download stops.")
                alert.addButton(withTitle: String(localized: "Close"))
                alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
                if alert.runModal() != .alertFirstButtonReturn { AppLanguage.cancelRelaunch(); return .terminateCancel }
            }
        }
        closing = true
        for window in sender.windows { window.orderOut(nil) }
        Updater.log("quitting: windows hidden, visible now: \(sender.windows.filter(\.isVisible).map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title })")
        // To the player Sommelier is gone at once: no Dock icon, no menu bar grape. Steam and the launchers it
        // started are still being closed in the background (a few seconds), then the process ends.
        MenuBarItem.shared.setVisible(false)
        sender.setActivationPolicy(.prohibited)
        let began = Date()
        Task { @MainActor in
            await model.closeEverythingOnQuit()
            Updater.log("quitting: environments closed in \(Int(Date().timeIntervalSince(began))) s")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Hands SwiftUI's `openWindow` to the app delegate, so a click on the Dock icon can bring the main window back
/// after it was closed.
struct MainWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let delegate: SommelierAppDelegate
    var body: some View {
        Color.clear.frame(width: 0, height: 0).onAppear {
            delegate.openMainWindow = { openWindow(id: "main") }
            // AppKit can't open SwiftUI's Settings window by itself any more (showSettingsWindow: does nothing).
            MenuBarItem.shared.openSettingsWindow = { openSettings() }
        }
    }
}
