// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// A collection's page: its picture, name and count, its games (a cross takes one off), and below, games to add
/// with a plus.
struct CollectionView: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// Narrows the games to add by name.
    @State private var find = ""

    var body: some View {
        let shelf = model.collection(id)
        let games = model.gamesIn(collection: id)
        let candidates = model.games(for: .allGames).filter { !model.isIn($0, collection: id) }
            .filter { find.isEmpty || $0.title.localizedCaseInsensitiveContains(find) }
            .sorted { (model.lastPlayed($0) ?? .distantPast, $0.isInstalled ? 1 : 0) > (model.lastPlayed($1) ?? .distantPast, $1.isInstalled ? 1 : 0) }
        let columns = [GridItem(.adaptive(minimum: 140, maximum: 170), spacing: Theme.Space.m + 4, alignment: .top)]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 18) {
                    CollectionMosaic(games: games, size: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shelf?.name ?? "").font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.onDark)
                        Text(String(localized: "\(games.count) games")).font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                    }
                    .padding(.bottom, 6)
                }
                .padding(.top, 70)

                if games.isEmpty {
                    Text("Empty for now. Press + on a cover below to add a game.")
                        .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.line(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        .padding(.top, 14)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(games) { game in
                            GameCard(game: game, shelf: .remove { withAnimation { model.toggle(game, in: id) } })
                        }
                    }
                    .padding(.horizontal, Theme.Space.s).padding(.top, 18)
                }

                // Every library game not on the shelf yet: played and installed first, the rest after; a field finds one.
                SectionHeader(title: "Add Games", count: candidates.count) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                        TextField("Search games", text: $find).textFieldStyle(.plain).frame(width: 180)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Theme.fill(0.07), in: Capsule())
                }
                .padding(.top, Theme.Space.section).padding(.bottom, Theme.Space.m)
                if candidates.isEmpty, !find.isEmpty {
                    Text("Nothing matches “\(find)”.").font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(candidates) { game in
                            GameCard(game: game, shelf: .add { withAnimation { model.toggle(game, in: id) } })
                        }
                    }
                    .padding(.horizontal, Theme.Space.s)
                }
            }
            .padding(.horizontal, Theme.Space.margin)
            .padding(.bottom, Theme.Space.margin)
        }
        .background(Theme.surface.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .navigationTitle(shelf?.name ?? "")
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { model.tint = nil }
    }
}
