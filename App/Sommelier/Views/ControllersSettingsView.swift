// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
@preconcurrency import GameController
import SommelierKit
import SwiftUI

/// Settings › Controllers: what is connected, how PlayStation pads reach games, and Controller Mode's settings
/// (the same ones its own settings screen has).
struct ControllersSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ControllerInput.shared
    @State private var pads: [PadRow] = []

    struct PadRow: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: ControllerKind
        let battery: Double?
        let charging: Bool
    }

    private var mode: Binding<ControllerModeSettings> {
        Binding(get: { model.settings.controllerMode ?? ControllerModeSettings() }, set: { model.settings.controllerMode = $0 })
    }

    var body: some View {
        Form {
            Section("Connected Controllers") {
                if pads.isEmpty {
                    Text("No controller connected. Turn one on or plug it in.").foregroundStyle(.secondary)
                }
                ForEach(pads) { pad in
                    HStack(spacing: 12) {
                        PadIcon(kind: pad.kind).frame(width: 28, height: 28).foregroundStyle(.primary)
                        Text(pad.name)
                        Spacer()
                        if let battery = pad.battery {
                            if pad.charging { Image(systemName: "bolt.fill").foregroundStyle(.secondary) }
                            Text(verbatim: "\(Int((battery * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Games") {
                Toggle("PlayStation controllers as Xbox controllers", isOn: Binding(
                    get: { model.playStationAsXbox },
                    set: { model.settings.playStationAsXbox = $0; model.applyControllerChoice() }))
                Text("Most Windows games only look for Xbox controllers. On: a DualSense or DualShock works in every game, with Xbox button prompts. Off: games made for PlayStation show its buttons and use the adaptive triggers, but some games won’t see the controller. Takes effect when the game’s store next starts.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("PlayStation button prompts in games that have them", isOn: Binding(
                    get: { model.playStationPrompts }, set: { model.settings.playStationPrompts = $0 }))
                Text("While a PlayStation controller is connected, these games show its buttons instead of Xbox ones.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Controller Mode") {
                HStack {
                    Text("The whole library in full screen, for a controller and a TV.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Controller Mode") { ControllerModeWindow.shared.enter(model: model) }
                }
                Toggle("Open in Controller Mode when a controller connects", isOn: bind(\.openWhenControllerConnects))
                Picker("Interface size", selection: bind(\.size)) {
                    Text("Standard").tag(ControllerModeSettings.Size.standard)
                    Text("Large").tag(ControllerModeSettings.Size.large)
                    Text("Extra Large").tag(ControllerModeSettings.Size.extraLarge)
                }
                Picker("Display", selection: Binding(get: { mode.wrappedValue.display ?? "" }, set: { var m = mode.wrappedValue; m.display = $0.isEmpty ? nil : $0; mode.wrappedValue = m })) {
                    Text(verbatim: NSScreen.main?.localizedName ?? "—").tag("")
                    ForEach(NSScreen.screens.dropFirst().map(\.localizedName), id: \.self) { Text($0).tag($0) }
                }
                Picker("Background", selection: bind(\.background)) {
                    Text("Warm").tag(ControllerModeSettings.Background.warm)
                    Text("Cool").tag(ControllerModeSettings.Background.cool)
                }
                Picker("Button labels", selection: bind(\.labels)) {
                    Text("Automatic").tag(ControllerModeSettings.Labels.automatic)
                    Text(verbatim: "Xbox").tag(ControllerModeSettings.Labels.xbox)
                    Text(verbatim: "PlayStation").tag(ControllerModeSettings.Labels.playStation)
                }
                Picker("PS / Xbox button", selection: bind(\.guideButton)) {
                    Text("Opens Controller Mode while Sommelier is in front").tag(ControllerModeSettings.GuideButton.whileInFront)
                    Text("Opens Controller Mode from anywhere, even over a game").tag(ControllerModeSettings.GuideButton.anywhere)
                    Text("Does nothing").tag(ControllerModeSettings.GuideButton.nothing)
                }
                Toggle("Sounds", isOn: bind(\.sounds))
                Toggle("Keep the display awake", isOn: bind(\.keepDisplayAwake))
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refresh() }
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private func bind<V>(_ path: WritableKeyPath<ControllerModeSettings, V>) -> Binding<V> {
        Binding(get: { mode.wrappedValue[keyPath: path] }, set: { var m = mode.wrappedValue; m[keyPath: path] = $0; mode.wrappedValue = m })
    }

    private func refresh() {
        pads = GCController.controllers().enumerated().map { index, pad in
            let level = pad.battery.flatMap { $0.batteryState == .unknown ? nil : $0 }
            return PadRow(id: "\(index):\(pad.vendorName ?? "")", name: pad.vendorName ?? pad.productCategory, kind: ControllerInput.kind(of: pad),
                          battery: level.map { Double($0.batteryLevel) }, charging: level?.batteryState == .charging || level?.batteryState == .full)
        }
    }
}
