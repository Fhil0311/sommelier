// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Asked once, after the first-run setup: may Sommelier share how games run? One answer covers game results and
/// shaders; Settings has a switch for each afterwards.
struct SharingConsentView: View {
    @Environment(AppModel.self) private var model
    /// The Mac's specs are a separate permission.
    @State private var hardware = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m - 4) {
                Image(systemName: "person.3.fill").font(.title).foregroundStyle(Theme.wineLight).frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Help everyone's games run better").font(.headline)
                    Text("Sommelier can share how your games run. Every player then sees which games work on a Mac and how fast, before installing, and first runs stutter less.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("What is shared").font(.callout.weight(.semibold))
                item("checkmark.circle", String(localized: "Whether a game started, and how long you played"))
                item("speedometer", String(localized: "The frame rate"))
                item("slider.horizontal.3", String(localized: "The settings Sommelier ran the game with"))
                item("square.stack.3d.up", String(localized: "Shaders translated while you play"))
                item("gamecontroller", String(localized: "Which stores and features you use"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $hardware) {
                    Text("Also share my Mac's specs: chip, memory and macOS version").font(.callout)
                }
                .toggleStyle(.checkbox)
                Text("They tie your frame rates to your Mac model, so players with the same Mac know what to expect. Without them, your frame rates don't count toward any model.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            Label("Never your name, accounts, files or what's on screen. Nothing identifies you.", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("You can change this anytime in Settings.").font(.caption).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button("Don't Allow") { model.answerSharing(false, hardware: false) }.keyboardShortcut(.cancelAction)
                Button("Allow") { model.answerSharing(true, hardware: hardware) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.callout) } icon: { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20) }
    }
}
