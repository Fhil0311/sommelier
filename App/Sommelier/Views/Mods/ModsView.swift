// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// The Mods page: the installed games that take mods, one chosen, and its mods below with what can be done to
/// them. An archive dropped anywhere on the page goes into the chosen game.
struct ModsView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        let games = model.gamesWithMods
        let game = model.modsPageGame
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 18) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 34))
                        .foregroundStyle(Theme.onDark.opacity(0.85))
                        .frame(width: 84, height: 84)
                        .background(Theme.fill(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mods").font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.onDark)
                        Text("Install mods in one click and switch them on before you play. Sommelier will check that the game still starts with them.")
                            .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 6)
                }
                .padding(.top, 70)

                if let game {
                    // Which game: a menu of the installed games with a mods profile.
                    Menu {
                        ForEach(games) { candidate in
                            Button { model.modsGame = candidate.id } label: {
                                if candidate.id == game.id { Label(candidate.title, systemImage: "checkmark") } else { Text(candidate.title) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(game.title).font(.system(size: 14, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.onDark)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(Theme.fill(0.08), in: Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .padding(.top, Theme.Space.l)
                    // The tabs: the installed mods always; the catalogue for a game with one; Nexus for a game
                    // with a domain there.
                    let profile = model.modProfile(for: game)
                    let tabs = ModsTab.allCases.filter { tab in
                        switch tab {
                        case .installed: true
                        case .catalog: profile?.sources.modio != nil
                        case .nexus: profile?.sources.nexus != nil
                        }
                    }
                    @Bindable var model = model
                    if tabs.count > 1 {
                        Picker("", selection: $model.modsTab) {
                            ForEach(tabs, id: \.self) { tab in
                                switch tab {
                                case .installed: Text("Installed").tag(tab)
                                case .catalog: Text("Catalog").tag(tab)
                                case .nexus: Text("Nexus").tag(tab)
                                }
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .padding(.top, Theme.Space.m)
                    }
                    let tab = tabs.contains(model.modsTab) ? model.modsTab : .installed
                    switch tab {
                    case .installed:
                        GameModsSection(game: game)
                            .padding(.top, Theme.Space.m)
                    case .catalog:
                        ModCatalogView(game: game, mods: model.mods(of: game))
                            .padding(.top, Theme.Space.m)
                            .task(id: game.id) { model.reloadMods(for: game) }
                    case .nexus:
                        NexusTabView(game: game, domain: profile?.sources.nexus?.domain ?? "")
                            .padding(.top, Theme.Space.m)
                    }
                } else {
                    Text("No installed game supports mods yet.")
                        .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.line(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        .padding(.top, Theme.Space.l)
                }
            }
            .padding(.horizontal, Theme.Space.margin)
            .padding(.bottom, Theme.Space.margin)
        }
        .background(Theme.surface.ignoresSafeArea())
        .overlay {
            if dropping, game != nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.wineLight, lineWidth: 2)
                    .padding(Theme.Space.m).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let game else { return false }
            return model.dropMods(providers, on: game)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("Mods")
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { model.tint = nil }
    }
}

/// One game's mods: the actions above, the policy's standing line, the loader's switch and summary, the short
/// note after a change, and the list.
private struct GameModsSection: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let mods = model.mods(of: game)
        let profile = model.modProfile(for: game)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Button("Add from file…") { model.chooseModFile(for: game) }
                    .buttonStyle(GlassPillButtonStyle()).disabled(model.isBusy || model.isActive(game))
                if let mods, !mods.mods.isEmpty {
                    Button("Check mod files") { model.checkModFiles(for: game) }.buttonStyle(.textLink)
                    Button("Play without mods") { Task { await model.playWithoutMods(game) } }.buttonStyle(.textLink)
                        .disabled(model.isActive(game) || model.isBusy)
                }
            }
            .font(.callout)
            if let line = ModPolicyLine.text(for: profile?.online.noticeKey) {
                Label { Text(line).foregroundStyle(Theme.onDark) } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(Theme.onDarkSecondary)
                }
                .font(.callout)
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.06)))
            }
            if profile?.online.separateSave != nil {
                Toggle(isOn: Binding(get: { model.separateSave(for: game) }, set: { model.setSeparateSave($0, for: game) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Separate save for mods").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onDark)
                        Text("Your usual save stays as it is.").font(.system(size: 11.5)).foregroundStyle(Theme.onDarkTertiary)
                    }
                }
                .toggleStyle(.switch).controlSize(.small)
                .disabled(model.isActive(game))
            }
            if let summary = model.modsSummary(of: game) {
                Text(summary).font(.callout).foregroundStyle(Theme.onDarkSecondary)
            }
            if let notice = model.modNotice, notice.gameID == game.id {
                HStack(spacing: 8) {
                    Text(notice.text).foregroundStyle(Theme.onDark)
                    switch notice.follow {
                    case .undo?: Button("Undo") { model.undoModNotice(notice) }.buttonStyle(.textLink)
                    case .reveal(let url)?: Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.textLink)
                    case nil: EmptyView()
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .padding(.horizontal, 12).frame(minHeight: 30)
                .background(Theme.fill(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .task(id: notice.shown) {
                    try? await Task.sleep(for: .seconds(8))
                    if model.modNotice == notice { model.modNotice = nil }
                }
            }
            if let mods {
                if mods.rootUnavailable {
                    Text("A folder the mods need can't be reached for this copy of the game.")
                        .font(.callout).foregroundStyle(Theme.wineLight)
                }
                if mods.mods.isEmpty {
                    Text("No mods yet. Add an archive from a file, or drop one here.")
                        .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.line(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                } else {
                    InstalledModsList(game: game, mods: mods)
                }
            }
        }
        .task(id: game.id) { model.reloadMods(for: game) }
    }
}
