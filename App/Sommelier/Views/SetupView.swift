// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI
import UniformTypeIdentifiers

/// First run: check the Mac, install a game engine (DirectX 12 comes with it), install Steam.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingManifest = false
    @State private var showingLicense = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: Theme.Space.m) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Welcome to Sommelier").font(Theme.Font.pageTitle)
                        Text("Three steps and your Windows games are ready to play.").foregroundStyle(.secondary)
                    }
                }
                step(1, "Your Mac", done: model.system?.canContinue == true) { systemSection }
                step(2, "Game engine", done: !model.engines.isEmpty) { engineSection }
                step(3, "Steam", done: model.isSteamInstalled) { steamSection }
            }
            .padding(Theme.Space.margin)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingLicense) { D3DMetalLicenseView() }
        .fileImporter(isPresented: $choosingManifest, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { model.settings.engineManifestURL = url }
        }
    }

    @ViewBuilder private var systemSection: some View {
        if let report = model.system {
            VStack(alignment: .leading, spacing: 6) {
                StatusRow(title: String(localized: "Apple Silicon"), status: report.appleSilicon,
                          problem: String(localized: "Sommelier needs a Mac with Apple Silicon."))
                StatusRow(title: String(localized: "macOS version"), status: report.macOS,
                          problem: String(localized: "Sommelier needs macOS 15 or later."))
                StatusRow(title: String(localized: "Rosetta 2"), status: report.rosetta,
                          problem: String(localized: "Rosetta 2 is not installed."))
                StatusRow(title: String(localized: "Free disk space"), status: report.disk,
                          problem: String(localized: "Less than 30 GB free. Games may not fit."))
                StatusRow(title: String(localized: "Memory"), status: report.memory,
                          problem: String(localized: "16 GB or more memory is recommended for demanding games."))
            }
            if case .failed = report.rosetta {
                Button("Install Rosetta 2") { Task { await model.installRosetta() } }.disabled(model.isBusy)
            }
        } else {
            LoadingGrape()
        }
    }

    @ViewBuilder private var engineSection: some View {
        if let engine = model.activeEngine {
            Label("Engine \(engine.version) installed: \(engine.info.wineDescription)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.onDark)
        } else {
            Text("The engine is Wine plus the graphics layers that translate DirectX to Metal.")
                .foregroundStyle(.secondary)
            if model.engineManifestURL == nil {
                // Only when the build has no engine source: a release build before engines are published.
                Button("Choose Engine List…") { choosingManifest = true }
            }
            if model.isBusy && model.engines.isEmpty {
                Label("Downloading the engine…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            } else if model.autoSetupFailed || model.engineManifestURL == nil {
                Button("Try Again") { Task { await model.continueSetup() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.engineManifestURL == nil || model.system?.canContinue != true)
            } else {
                Text("Starts by itself once your Mac is ready.").font(.callout).foregroundStyle(.secondary)
            }
        }
        HStack(spacing: Theme.Space.s) {
            Text("Includes Apple's D3DMetal for DirectX 12 games, covered by Apple's license.")
                .font(.callout).foregroundStyle(.secondary)
            Button("License") { showingLicense = true }.buttonStyle(.link).font(.callout)
        }
    }

    @ViewBuilder private var steamSection: some View {
        if model.isSteamInstalled {
            Label("Steam is installed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.onDark)
        } else {
            Text("Sommelier installs the Windows version of Steam in its own environment. You sign in once.")
                .foregroundStyle(.secondary)
            if model.isBusy && !model.engines.isEmpty {
                Label("Installing Steam…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
            } else if model.autoSetupFailed && !model.engines.isEmpty {
                Button("Try Again") { Task { await model.continueSetup() } }.buttonStyle(.borderedProminent)
            } else {
                Text("Installs by itself after the engine.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func step<Content: View>(_ number: Int, _ title: LocalizedStringKey, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(done ? Theme.cream : Color.accentColor.opacity(0.15)).frame(width: 32, height: 32)
                if done { Image(systemName: "checkmark").foregroundStyle(Theme.ink).bold() }
                else { Text("\(number)").bold().foregroundStyle(Color.accentColor) }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.bold())
                content()
            }
        }
    }
}

/// One line of the Mac check. The problem text is Sommelier's own, in the app's language.
struct StatusRow: View {
    let title: String
    let status: SystemReport.Status
    let problem: String

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .ok:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.onDark)
                Text(title)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.wineLight)
                Text(verbatim: "\(title): \(problem)")
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.wineLight)
                Text(verbatim: "\(title): \(problem)")
            }
        }
        .font(.callout)
    }
}
