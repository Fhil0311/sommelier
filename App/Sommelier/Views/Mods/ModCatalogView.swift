// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// The game's mod.io catalogue (through our Worker): a search field and cards with Install. Shown only for a
/// game whose profile names a mod.io catalogue, so for now no game shows it; it is here for the ones to come.
struct ModCatalogView: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let mods: GameMods?
    @State private var query = ""
    @State private var page: ModPage?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.onDarkTertiary)
                TextField("Search mods", text: $query).textFieldStyle(.plain).foregroundStyle(Theme.onDark)
                if loading { LoadingGrape() }
            }
            .font(.callout)
            .padding(.horizontal, 12).frame(height: 34)
            .background(Theme.fill(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let problem {
                Text(problem).font(.callout).foregroundStyle(Theme.wineLight)
            } else if let page {
                if page.cards.isEmpty {
                    Text("No mods found.").font(.callout).foregroundStyle(Theme.onDarkSecondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(page.cards) { card in ModCardRow(game: game, card: card, installed: isInstalled(card)) }
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 350))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func isInstalled(_ card: ModCard) -> Bool {
        mods?.mods.contains { $0.origin.kind == .modio && $0.origin.modID == card.id } ?? false
    }

    private func load() async {
        guard let client = model.modIOClient(for: game) else { return }
        loading = true
        defer { loading = false }
        do {
            page = try await client.search(query)
            problem = nil
        } catch {
            problem = AppModel.errorText(error) ?? error.localizedDescription
        }
    }
}

/// One card: the picture, the name and author, a line of its summary, and Install (or the word Installed).
private struct ModCardRow: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let card: ModCard
    let installed: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            AsyncImage(url: card.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(Theme.onDarkTertiary)
            }
            .frame(width: 96, height: 54)
            .background(Theme.fill(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                    if let version = card.version { Text(version).font(.system(size: 11)).foregroundStyle(Theme.onDarkTertiary) }
                }
                if !card.summary.isEmpty {
                    Text(card.summary).font(.system(size: 12)).foregroundStyle(Theme.onDarkSecondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let author = card.author { Text(author) }
                    if let updated = card.updated { Text(updated, style: .date) }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.onDarkTertiary)
            }
            Spacer(minLength: 0)
            if installed {
                Text("Already installed").font(.callout).foregroundStyle(Theme.onDarkTertiary)
            } else {
                Button("Install") { Task { await model.installFromCatalog(card, in: game) } }
                    .buttonStyle(GlassPillButtonStyle()).disabled(model.isBusy || model.isActive(game) || card.fileToInstall == nil)
            }
        }
        .padding(10)
        .background(Theme.fill(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
