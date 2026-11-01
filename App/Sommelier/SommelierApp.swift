// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

@main
struct SommelierApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        // A debug build talks to the services running on this Mac (`wrangler dev` in server/api on 8788 and
        // server/decanter on 8789) unless told otherwise; a release build talks to the real ones.
        setenv("SOMMELIER_API_URL", "http://127.0.0.1:8788", 0)
        setenv("SOMMELIER_DECANTER_URL", "http://127.0.0.1:8789", 0)
        StagingKey.install()                // only when started with SOMMELIER_STAGING_KEY (the test services)
        #endif
        _model = State(initialValue: AppModel())
    }
    @State private var updater = Updater()
    @NSApplicationDelegateAdaptor(SommelierAppDelegate.self) private var appDelegate

    /// The main window's size the first time: 1280×800 on a big screen, smaller on a small one so it fits whole beside
    /// the menu bar and the Dock (about 88% of the room there is), never under the smallest the window can be.
    private static var firstLaunchSize: CGSize {
        let room = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: min(1280, max(980, (room.width * 0.88).rounded())),
                      height: min(800, max(640, (room.height * 0.88).rounded())))
    }

    var body: some Scene {
        @Bindable var updater = updater
        Window("Sommelier", id: "main") {
            ContentView()
                .environment(model)
                .environment(updater)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    AppAppearance(setting: model.settings.appearance).apply()
                    guard !model.started else { return }                // the window opened again
                    #if DEBUG
                    // A developer's check without a screen: draws Controller Mode into a PNG and quits.
                    if let path = ProcessInfo.processInfo.environment["SOMMELIER_CM_SNAPSHOT"] {
                        await ControllerModeSnapshot.write(to: path, model: model)
                        NSApp.terminate(nil)
                        return
                    }
                    #endif
                    updater.isPlaying = { [model] in !model.gameStates.isEmpty }
                    appDelegate.model = model
                    InGameCounterWindow.shared.start(model: model)
                    ClipRecorder.shared.start(model: model)
                    ControllerArrival.shared.start(model: model)
                    MenuBarItem.shared.start(model: model, updater: updater) { [appDelegate] in appDelegate.openMainWindow?() }
                    await model.start()
                }
                .sheet(isPresented: $updater.showingDetails) { UpdateSheet().environment(updater) }
                .background(MainWindowOpener(delegate: appDelegate))
                .onOpenURL { url in
                    if let id = GameLink.gameID(from: url), let game = model.library.games.first(where: { $0.id == id }) {
                        Task { await model.play(game) }
                    }
                }
        }
        .defaultSize(Self.firstLaunchSize)                      // first launch only; macOS keeps the player's size after
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check() }
            }
            // Help: where players reach us (design: contacts.html). Mail and the site wait for the domain.
            CommandGroup(replacing: .help) {
                Button("Discord Community") { Links.open(Links.discord) }
                if Links.mailReady {
                    Button("Write to Us…") { Links.open(Links.mail) }
                    Divider()
                    Button("Sommelier Website") { Links.open(Links.site) }
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Library") { Task { await model.refreshLibrary() } }
                    .keyboardShortcut("r")
                Button("Open Steam") { Task { await model.openSteam() } }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Quit Steam") { model.quitSteam() }
                    .disabled(model.running["steam"] == nil)
            }
            // Every page, also with the sidebar hidden: sections on ⌘1–4, stores on ⌥⌘1…, collections by name.
            CommandMenu("Go") {
                Button("Home") { model.selection = .home }.keyboardShortcut("1")
                Button("All Games") { model.selection = .allGames }.keyboardShortcut("2")
                Button("Installed") { model.selection = .installed }.keyboardShortcut("3")
                Button("Mac Versions") { model.selection = .macVersions }.keyboardShortcut("4")
                Divider()
                Menu("Stores") {
                    ForEach(Array(model.storesInUse.enumerated()), id: \.element) { index, kind in
                        if index < 9 {
                            Button(kind.displayName) { model.selection = .store(kind) }
                                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                        } else {
                            Button(kind.displayName) { model.selection = .store(kind) }
                        }
                    }
                }
                Menu("Collections") {
                    ForEach(model.collections) { shelf in Button(shelf.name) { model.selection = .collection(shelf.id) } }
                    if model.collections.isEmpty { Text("No collections yet") }
                }
                Divider()
                Button("Back") { if !model.path.isEmpty { model.path.removeLast() } }
                    .keyboardShortcut("[")
                    .disabled(model.path.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
                .environment(model.artwork)
        }
        .windowResizability(.contentSize)      // the window takes each tab's own height, as macOS settings do
    }
}
