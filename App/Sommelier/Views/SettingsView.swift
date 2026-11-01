// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// Settings, in tabs as macOS apps have them.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().settingsPane().tabItem { Label("General", systemImage: "gearshape") }
            GamesSettings().settingsPane().tabItem { Label("Games", systemImage: "gamecontroller") }
            CounterSettings().settingsPane().tabItem { Label("Counter", systemImage: "gauge.with.needle") }
            ClipsSettingsView().settingsPane().tabItem { Label("Clips", systemImage: "film") }
            ControllersSettingsView().settingsPane().tabItem { Label("Controllers", systemImage: "gamecontroller.fill") }
            AccountsSettings().settingsPane().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            PrivacySettings().settingsPane().tabItem { Label("Privacy", systemImage: "hand.raised") }
            AdvancedSettings().settingsPane().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
    }
}

extension View {
    /// A settings tab sized by its content: fixed width, and the height of what it shows, so the window
    /// grows and shrinks per tab instead of leaving empty space; a tab taller than `maxHeight` scrolls instead
    /// of running off the screen.
    func settingsPane(maxHeight: CGFloat = 620) -> some View {
        self.frame(width: 700)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    @Environment(Updater.self) private var updater
    @Environment(AppModel.self) private var model
    @State private var language = AppLanguage.current
    private let started = AppLanguage.current

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.ordered(selected: started)) { Text($0.name).tag($0) }
                }
                .onChange(of: language) { language.apply() }
                if language != started {
                    HStack {
                        Text("Restart Sommelier to use the new language.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }.buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                Text("Games keep their own language settings.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Appearance", selection: Binding(
                    get: { AppAppearance(setting: model.settings.appearance) },
                    set: { model.settings.appearance = $0.setting; $0.apply() })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Sommelier in the menu bar", isOn: Binding(
                    get: { model.settings.showInMenuBar != false },
                    set: { model.settings.showInMenuBar = $0 ? nil : false; MenuBarItem.shared.setVisible($0) }))
                Toggle("Show the last game in the sidebar", isOn: Binding(
                    get: { model.settings.showContinueCard == true },
                    set: { model.settings.showContinueCard = $0 ? true : nil }))
            }
            Section {
                LabeledContent("Version \(updater.currentVersion)") {
                    Button("Check Now") { updater.check() }
                }
            } footer: {
                Text("Sommelier checks for updates every day and installs them when you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct GamesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showingD3DMetalLicense = false

    var body: some View {
        Form {
            Section {
                Toggle("Match graphics to this Mac", isOn: Binding(
                    get: { model.tunesGames }, set: { model.settings.tuneGames = $0; model.settings.tuningNoticeShown = true }))
                Text("Once a game is installed, Sommelier sets its resolution and graphics quality for this Mac, for games whose settings it knows. Each game's page can put your own settings back. Turning this off leaves games already matched as they are.")
                    .font(.caption).foregroundStyle(.secondary)
                if AppModel.turboReady {
                    Toggle("Turbo for DirectX 10 and 11 games", isOn: Binding(
                        get: { model.turboOn }, set: { model.settings.turboGames = $0 }))
                        .disabled(!model.macPower.appleSilicon)
                    Text("The game draws a quarter of the pixels and MetalFX, Apple's upscaler, scales the picture up to your display: more frames per second, a slightly softer picture. If a game doesn't start with it, Sommelier offers to turn it off for that game.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Turbo for DirectX 10 and 11 games", isOn: .constant(false)).disabled(true)
                    HStack(spacing: 4) {
                        Text("Soon")
                        TurboPlan.icon(TurboPlan.text)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Game Mode", isOn: Binding(
                    get: { model.gameModeOn }, set: { model.settings.gameMode = $0 ? nil : false; model.applyGameMode() }))
                Text("macOS gives the game priority on the CPU and GPU, quiets background tasks and lowers the latency of wireless controllers and headphones. It turns on when the game is full screen. If sound drops out or crackles in games, turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Graphics")
            }
            Section("DirectX 12") {
                LabeledContent("Status", value: model.d3dMetalInfo.map { String(localized: "Version \($0.version)") }
                               ?? String(localized: "Not set up"))
                HStack {
                    Button(model.d3dMetalInfo == nil ? "Set Up DirectX 12…" : "Use My Own from Apple…") {
                        model.beginD3DMetalSetup(); model.d3dSetup = .intro
                    }
                    Button("License") { showingD3DMetalLicense = true }
                }
            }
            .sheet(isPresented: $showingD3DMetalLicense) { D3DMetalLicenseView() }
            Section("Saves") {
                Toggle("Sync cloud saves for Epic Games and GOG", isOn: Binding(
                    get: { model.cloudSavesOn }, set: { model.settings.cloudSaves = $0 }))
                Text("Newer cloud saves come down before a game starts; newer saves from this Mac go up after it quits. Steam games sync through Steam.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Back up saves after playing", isOn: Binding(
                    get: { model.backsUpSaves }, set: { model.settings.backUpSaves = $0 }))
                FolderRow(title: "Backups folder", folder: model.saveBackupFolder, isDefault: model.settings.backupFolder == nil,
                          choose: { model.settings.backupFolder = $0 }, reset: { model.settings.backupFolder = nil })
                Text("When you quit a game, Sommelier copies its saves if they changed and keeps the last 10 copies. To put one back, use Restore Saves in the game's ⋯ menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if AppModel.gamesFolderSetting {
            Section("Installing") {
                FolderRow(title: "Folder for new games", folder: model.gamesFolder, isDefault: model.settings.gamesFolder == nil,
                          choose: { model.chooseGamesFolder($0) }, reset: { model.chooseGamesFolder(nil) })
                Text("New games from Epic Games, GOG and Steam install here. For Steam, Sommelier adds the folder as a Steam library and makes Steam pick it. Games already installed stay where they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            Section("Steam") {
                // Unset means "ask once" while Steam for Mac isn't installed, and Steam for Mac once it is.
                Picker("Games with a Mac version", selection: Binding(
                    get: { model.settings.steamMacVersions ?? (SteamMacClient.isInstalled ? "native" : "") },
                    set: { model.settings.steamMacVersions = $0.isEmpty ? nil : $0 }
                )) {
                    if !SteamMacClient.isInstalled && model.settings.steamMacVersions == nil { Text("Ask once").tag("") }
                    Text("Through Steam for Mac").tag("native")
                    Text("Windows version in Sommelier").tag("windows")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The in-game counter, with a live preview of what each setting changes.
struct CounterSettings: View {
    @Environment(AppModel.self) private var model

    private var counter: Binding<InGameCounter> {
        Binding(get: { model.settings.inGameCounter ?? InGameCounter() }, set: { model.settings.inGameCounter = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show the in-game counter", isOn: counter.enabled)
                if counter.wrappedValue.enabled {
                    CounterPreview(settings: counter.wrappedValue)
                        .frame(maxWidth: .infinity)
                    LabeledContent("Show") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow { item(.fps); item(.gpu); item(.memory) }
                            GridRow { item(.frameTime); item(.cpu); item(.thermal) }
                        }
                    }
                    Picker("Corner", selection: counter.corner) {
                        Text("Top Left").tag(InGameCounter.Corner.topLeft)
                        Text("Top Right").tag(InGameCounter.Corner.topRight)
                        Text("Bottom Left").tag(InGameCounter.Corner.bottomLeft)
                        Text("Bottom Right").tag(InGameCounter.Corner.bottomRight)
                    }
                    Picker("Size", selection: counter.size) {
                        Text("Small").tag(InGameCounter.Size.small)
                        Text("Medium").tag(InGameCounter.Size.medium)
                        Text("Large").tag(InGameCounter.Size.large)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Background transparency") {
                        HStack {
                            Slider(value: counter.transparency, in: 0...1)
                            Text(verbatim: "\(Int((counter.wrappedValue.transparency * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                    LabeledContent("Text transparency") {
                        HStack {
                            Slider(value: counter.textTransparency, in: 0...InGameCounter.maxTextTransparency)
                            Text(verbatim: "\(Int((counter.wrappedValue.textTransparency * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("In-Game Counter")
            } footer: {
                Text("Shown over a game while it is in front. Press ⌥⌘F in a game to hide or show it. Changes apply right away. The heat warning appears only when the Mac gets hot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension CounterSettings {
    private func item(_ item: InGameCounter.Item) -> some View {
        Toggle(item.title, isOn: Binding(
            get: { counter.wrappedValue.shows(item) },
            set: { on in
                var c = counter.wrappedValue
                c.items.removeAll { $0 == item }
                if on { c.items = InGameCounter.Item.allCases.filter { c.items.contains($0) || $0 == item } }
                counter.wrappedValue = c
            }))
        .toggleStyle(.checkbox)
    }
}

extension InGameCounter.Item {
    var title: LocalizedStringKey {
        switch self {
        case .fps: "FPS"
        case .frameTime: "Frame time"
        case .gpu: "GPU load"
        case .cpu: "CPU load"
        case .memory: "Game memory"
        case .thermal: "Overheating"
        }
    }
}

/// What Sommelier may share, each with its own switch (asked once, after the first-run setup).
struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false
    @State private var copiedClient = false
    @State private var deletion: Deletion = .idle

    enum Deletion { case idle, working, done, failed }

    var body: some View {
        Form {
            Section {
                Toggle("Share how games run", isOn: Binding(
                    get: { model.sharesReports }, set: { model.settings.shareReports = $0; if !$0 { model.leaveInstallCount() } }))
                Text("Whether a game started, how long you played, the frame rate and the settings Sommelier ran it with, and which stores and features you use. Every player then sees which games work on a Mac, how fast and with which settings. Nothing identifies you.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Include my Mac's specs", isOn: Binding(
                    get: { model.sharesHardware }, set: { model.settings.shareHardware = $0 }))
                    .disabled(!model.sharesReports)
                Text("Chip, memory and macOS version. They tie your frame rates to your Mac model.")
                    .font(.caption).foregroundStyle(.secondary)
                // One switch for both directions: ready-made shaders come down, the player's own go up.
                Toggle("Ready-made shaders", isOn: Binding(
                    get: { model.usesCellar },
                    set: { model.settings.readyMadeShaders = $0; model.settings.shareShaders = $0 }))
                Text("A game's first run without stutter: ready-made shaders download in advance, and yours help other players. Only the shaders themselves, nothing personal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Reports sent from this Mac") {
                    switch deletion {
                    case .working: LoadingGrape()
                    case .done: Label("Deleted", systemImage: "checkmark").foregroundStyle(.secondary)
                    case .idle, .failed: Button("Delete…") { confirmingDelete = true }
                    }
                }
                Text(deletion == .failed
                     ? "Couldn't reach the server. Check the connection and try again."
                     : "Removes the game reports and launch failures this Mac sent. Reports you send later start fresh, under a new random id.")
                    .font(.caption).foregroundStyle(deletion == .failed ? Theme.wineLight : .secondary)
                // The random id the reports went under: what a player emails when they'd rather we delete them.
                if let client = model.settings.reportClientID {
                    LabeledContent("Install number") {
                        HStack(spacing: 8) {
                            Text(client).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            Button(copiedClient ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(client, forType: .string)
                                copiedClient = true
                            }
                        }
                    }
                    Text("To have us delete the reports instead, email this number to support@playsommelier.com.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the reports sent from this Mac?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                deletion = .working
                Task { deletion = await model.deleteSentData() ? .done : .failed }
            }
        } message: {
            Text("Games' ratings stop counting them. This can't be undone.")
        }
    }
}

/// Store accounts. Epic and GOG sign in through Sommelier; Steam signs in inside its own window, and signs out here.
struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingSignOut: StoreKind?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if let activity = model.storeActivity[.steam] {
                        HStack(spacing: 6) { LoadingGrape(); Text(activity).foregroundStyle(.secondary) }
                    } else if model.steamAccountName != nil {
                        Button("Sign Out") { confirmingSignOut = .steam }
                    } else {
                        Button(model.signInTitle(.steam, ellipsis: true)) { Task { await model.signInOrShow(.steam) } }   // in Steam's own window
                            .disabled(!model.isSteamInstalled || model.signInDisabled(.steam))
                    }
                } label: {
                    Label {
                        Text(verbatim: "Steam")
                        Text(model.steamAccountName.map { $0.isEmpty ? String(localized: "Signed in") : $0 }
                             ?? String(localized: "Not signed in"))
                    } icon: { StoreKind.steam.logo.resizable().scaledToFit().frame(width: 18, height: 18) }
                }
                ForEach(AppModel.directStores, id: \.self) { kind in
                    LabeledContent {
                        if let activity = model.storeActivity[kind] {
                            HStack(spacing: 6) { LoadingGrape(); Text(activity).foregroundStyle(.secondary) }
                        } else if model.isSignedIn(kind) {
                            Button("Sign Out") { confirmingSignOut = kind }
                        } else {
                            Button("Sign In…") { Task { await model.connect(kind) } }.disabled(model.isSigningIn(kind))
                        }
                    } label: {
                        Label {
                            Text(kind.displayName)
                            Text(model.isSignedIn(kind) ? String(localized: "\(model.games(for: .store(kind)).count) games")
                                 : String(localized: "Not signed in"))
                        } icon: { kind.logo.resizable().scaledToFit().frame(width: 18, height: 18) }
                    }
                }
                ForEach(AppModel.launcherStores, id: \.self) { kind in
                    LabeledContent {
                        if let activity = model.storeActivity[kind] {
                            HStack(spacing: 6) { LoadingGrape(); Text(activity).foregroundStyle(.secondary) }
                        } else if model.isLauncherInstalled(kind), model.isLauncherSignedIn(kind) {
                            Button("Sign Out") { confirmingSignOut = kind }.disabled(model.isPlaying(from: kind))
                        } else {
                            // Not set up yet is the same button: signing in sets the launcher up first (openLauncher), as on the
                            // signed-out screens, so every store reads "Sign In…".
                            Button(model.signInTitle(kind, ellipsis: true)) { Task { await model.signInOrShow(kind) } }
                                .disabled(model.signInDisabled(kind))
                        }
                    } label: {
                        Label {
                            Text(kind.displayName)
                            Text(!model.isLauncherSignedIn(kind) ? String(localized: "Not signed in")      // also while not set up yet
                                 : String(localized: "\(model.games(for: .store(kind)).count) games"))
                        } icon: { kind.logo.resizable().scaledToFit().frame(width: 18, height: 18) }
                    }
                }
            } footer: {
                Text("Epic Games and GOG games download straight from the store, without its launcher. The EA app, Ubisoft Connect and Battle.net run in their own environments, and you sign in inside them. Your password goes only to the store.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(confirmingSignOut.map { String(localized: "Sign out of \($0.displayName)?") } ?? "",
                            isPresented: Binding(get: { confirmingSignOut != nil }, set: { if !$0 { confirmingSignOut = nil } }),
                            presenting: confirmingSignOut) { kind in
            Button("Sign Out", role: .destructive) {
                Task {
                    if kind == .steam { await model.signOutSteam() }
                    else if AppModel.launcherStores.contains(kind) { await model.signOutLauncher(kind) }
                    else { await model.signOut(kind) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(kind == .steam
                 ? "Steam quits, and its saved login is removed from this Mac. Installed games stay; to play them, open Steam and sign in again."
                 : AppModel.launcherStores.contains(kind)
                 ? "\(kind.displayName) quits, and its saved login is removed from this Mac. Installed games stay; to play them, sign in again."
                 : "Installed games stay on this Mac. Sign in again to play them and see the rest of your library.")
        }
    }
}

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var choosingManifest = false

    var body: some View {
        @Bindable var model = model
        Form {
            #if DEBUG
            // Engines update by themselves in release builds; picking one and the engine list are for development.
            Section("Game engine") {
                if model.engines.isEmpty {
                    Text("No engine installed.").foregroundStyle(.secondary)
                } else {
                    Picker("Active engine", selection: Binding(
                        get: { model.activeEngine?.version ?? "" },
                        set: { model.settings.activeEngineVersion = $0 }
                    )) {
                        ForEach(model.engines, id: \.version) { engine in
                            Text(verbatim: "\(engine.version) · \(engine.info.backends.joined(separator: ", "))").tag(engine.version)
                        }
                    }
                }
                Button("Install Newest Engine") { Task { await model.installEngine() } }
                    .disabled(model.engineManifestURL == nil || model.isBusy)
            }
            Section("Engine source") {
                LabeledContent("Engine list") {
                    HStack {
                        Text(model.settings.engineManifestURL == nil ? String(localized: "Built in")
                             : (model.settings.engineManifestURL?.lastPathComponent ?? ""))
                            .foregroundStyle(.secondary)
                        Button("Choose…") { choosingManifest = true }
                        if model.settings.engineManifestURL != nil {
                            Button("Use Built-in") { model.settings.engineManifestURL = nil }
                        }
                    }
                }
            }
            #endif
            Section("Data") {
                LabeledContent("Folder") { Text(verbatim: model.paths.home.path).textSelection(.enabled).foregroundStyle(.secondary) }
                Button("Show in Finder") { model.revealDataFolder() }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosingManifest, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.settings.engineManifestURL = url }
        }
    }
}

/// A folder setting: where it is, Change… to pick another, and Use Default when the player picked one.
struct FolderRow: View {
    let title: LocalizedStringKey
    let folder: URL
    let isDefault: Bool
    let choose: (URL) -> Void
    let reset: () -> Void
    @State private var picking = false

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(verbatim: (folder.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(folder.path)
                Button("Change…") { picking = true }
                if !isDefault { Button("Use Default") { reset() } }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { choose(url) }
        }
    }
}
