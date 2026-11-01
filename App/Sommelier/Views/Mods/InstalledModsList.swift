// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// A game's installed mods: a switch, the name, the one chip there is ("Code"), and under a mod that is off the
/// conflict that keeps it off; a mod whose loader is missing gets Install beside it; after a check, a mod with
/// files out of place gets Repair. Rows drag into order where the game has one (top wins); pinned mods show a
/// lock instead of moving.
struct InstalledModsList: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let mods: GameMods

    var body: some View {
        let order = mods.order
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(order.items) { item in
                    if let mod = mods.mod(item.key) {
                        ModRow(game: game, mod: mod, item: item, mods: mods)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .moveDisabled(item.pin != nil || !order.canReorder)
                    }
                }
                .onMove { from, to in
                    guard order.canReorder, let first = from.first else { return }
                    // The list's "to" counts the row as removed already; `moving` wants the final position.
                    model.moveMod(order.items[first].key, to: to > first ? to - 1 : to, in: game)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: CGFloat(order.items.count) * 64 + 8)
            if order.items.contains(where: { $0.pin != nil }) {
                Text("When two mods change the same files, the higher one wins. Some mods always come first and can't be moved.")
                    .font(.system(size: 12)).foregroundStyle(Theme.onDarkTertiary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } else if order.canReorder, order.items.count > 1 {
                Text("When two mods change the same files, the higher one wins.")
                    .font(.system(size: 12)).foregroundStyle(Theme.onDarkTertiary)
                    .padding(.top, 6)
            }
        }
    }
}

/// One mod in the list.
private struct ModRow: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let mod: StoredMod
    let item: LoadOrder.Item
    let mods: GameMods

    var body: some View {
        let findings = mods.conflicts.findings(for: mod.key)
        let problems = mods.problems(of: mod.key)
        let missingLoader = findings.first { if case .needsFramework = $0.cause { true } else { false } }
        HStack(alignment: .center, spacing: Theme.Space.m - 4) {
            Toggle("", isOn: Binding(get: { mod.enabled }, set: { model.setMod(mod.key, enabled: $0, in: game) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .disabled(model.isActive(game))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(mod.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                    if mod.containsCode {
                        Text("Code").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.onDarkSecondary)
                            .padding(.horizontal, 6).frame(height: 18)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line(0.22)))
                    }
                }
                let meta = [mod.version.map { String(localized: "Version \($0)") }, mod.author].compactMap { $0 }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.onDarkTertiary).lineLimit(1)
                }
                // The conflict sits under the mod that is off; the one that is on doesn't repeat it.
                if !mod.enabled, let line = findings.lazy.compactMap({ conflictLine($0) }).first {
                    Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.wineLight).lineLimit(2)
                } else if mod.enabled, let line = findings.lazy.compactMap({ needsLine($0) }).first {
                    Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.wineLight).lineLimit(2)
                }
                if problems > 0 {
                    Text(String(localized: "\(problems) files out of place")).font(.system(size: 11.5)).foregroundStyle(Theme.wineLight)
                }
            }
            Spacer(minLength: 0)
            if let missingLoader, case .needsFramework(let id) = missingLoader.cause {
                Button("Install") { Task { await model.installFramework(id, for: game) } }
                    .buttonStyle(SheetButtonStyle(kind: .primary)).disabled(model.isBusy)
            }
            if problems > 0 {
                Button("Repair") { model.repairMod(mod.key, in: game) }.buttonStyle(SheetButtonStyle())
            }
            if item.pin != nil {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.onDarkTertiary)
                    .frame(width: 20).help("Can't be moved")
            } else if mods.order.canReorder {
                Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(Theme.onDarkTertiary).frame(width: 20)
            }
        }
        .padding(.horizontal, 14).frame(height: 56)
        .background(Theme.fill(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line(0.08)))
        .opacity(mod.enabled ? 1 : 0.75)
        .contextMenu {
            Button("Show in Finder") { model.revealMod(mod.key, in: game) }
            Divider()
            Button("Remove…", role: .destructive) { model.removeMod(mod.key, from: game) }.disabled(model.isActive(game))
        }
    }

    /// Why the mod is off, naming the other mod.
    private func conflictLine(_ finding: ModConflicts.Finding) -> String? {
        let others = finding.mods.filter { $0 != mod.key }.compactMap { mods.mod($0)?.name }
        guard let other = others.first else { return nil }
        switch finding.cause {
        case .samePath:
            return finding.severity == .block ? String(localized: "Can't be on together with \(other): both change the same files.")
                                              : String(localized: "Changes the same files as \(other).")
        case .rule(let reason, _, _):
            switch reason {
            case "regulation": return String(localized: "\(other): both replace the same core file of the game.")
            case "pakchunk": return String(localized: "\(other): both take the same place in the game's files.")
            case "duplicateMod": return String(localized: "The same mod as \(other).")
            default: return String(localized: "Can't be on together with \(other).")
            }
        case .needsFramework, .needsMod:
            return needsLine(finding)
        }
    }

    /// What the mod needs that isn't there.
    private func needsLine(_ finding: ModConflicts.Finding) -> String? {
        switch finding.cause {
        case .needsFramework: String(localized: "Its loader isn't installed.")
        case .needsMod(let name, _): String(localized: "Needs \(name)")
        default: nil
        }
    }
}
