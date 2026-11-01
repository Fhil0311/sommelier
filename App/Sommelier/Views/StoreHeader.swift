// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

extension StoreKind {
    /// A backdrop from the store's own website, for stores that have a signature one (GOG's galaxy, Ubisoft
    /// Connect's dark streaks). Steam and Epic style their pages with flat colour, so their headers do too. The
    /// pictures are the stores' own: official builds add them from the private pack (see project.yml), and a build
    /// without it shows the flat colour.
    var backgroundImage: Image? {
        let name: (String, String)? = switch self {
        case .gog: ("store-bg-gog", "jpg")
        case .ubisoft: ("store-bg-ubisoft", "png")
        default: nil
        }
        guard let name, let url = Bundle.main.url(forResource: name.0, withExtension: name.1),
              let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
    }

    /// The store's colours, close to its own branding, for the top of its page and the sidebar wash.
    var brandColors: (top: Color, bottom: Color, accent: Color) {
        switch self {
        case .steam: (Color(red: 0.11, green: 0.16, blue: 0.23), Color(red: 0.16, green: 0.28, blue: 0.37), Color(red: 0.40, green: 0.75, blue: 0.96))
        case .epic: (Color(red: 0.08, green: 0.08, blue: 0.10), Color(red: 0.05, green: 0.24, blue: 0.48), Color(red: 0.0, green: 0.47, blue: 0.95))
        case .gog: (Color(red: 0.24, green: 0.09, blue: 0.33), Color(red: 0.45, green: 0.19, blue: 0.56), Color(red: 0.78, green: 0.55, blue: 0.92))
        case .ubisoft: (Color(red: 0.04, green: 0.09, blue: 0.20), Color(red: 0.02, green: 0.30, blue: 0.62), Color(red: 0.0, green: 0.56, blue: 1.0))
        case .ea: (Color(red: 0.06, green: 0.07, blue: 0.13), Color(red: 0.16, green: 0.09, blue: 0.22), Color(red: 1.0, green: 0.30, blue: 0.30))
        case .battlenet: (Color(red: 0.03, green: 0.08, blue: 0.16), Color(red: 0.02, green: 0.25, blue: 0.48), Color(red: 0.08, green: 0.56, blue: 1.0))
        }
    }
}

/// The top of a store's page: its colours, its logo large and faint, a fan of the user's own covers from that store,
/// and the one thing to do there (open the launcher, sign in, or go to the store).
struct StoreHeader: View {
    @Environment(AppModel.self) private var model
    let kind: StoreKind
    let games: [Game]
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let brand = kind.brandColors
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [brand.top, brand.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let background = kind.backgroundImage {
                // The store's own backdrop, from its website, under a wash of its colour.
                Color.clear.overlay { background.resizable().scaledToFill() }.clipped()
                LinearGradient(colors: [brand.top.opacity(0.55), brand.bottom.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
            }
            covers
            kind.logo.resizable().scaledToFit()
                .frame(height: height * 0.62)
                .foregroundStyle(.white.opacity(0.06))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, Theme.Space.margin)
                .allowsHitTesting(false)
            Theme.scrim
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s + 2) {
                    kind.logo.resizable().scaledToFit().frame(width: 28, height: 28).foregroundStyle(Theme.onDark)
                    Text(kind.displayName).font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.onDark)
                }
                Text(status).font(.callout).foregroundStyle(Theme.onDarkSecondary)
                action.padding(.top, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Space.margin)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
    }

    /// Up to five covers from the store, the ones the user plays first, leaning like a hand of cards on the right,
    /// clear of the title.
    private var covers: some View {
        let shown = Array(games.sorted { (model.lastPlayed($0) ?? .distantPast) > (model.lastPlayed($1) ?? .distantPast) }
            .sorted { $0.isInstalled && !$1.isInstalled }.prefix(width > 900 ? 5 : 4))
        let coverHeight = height * 0.66
        return HStack(spacing: -coverHeight * 0.22) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, game in
                Artwork(url: model.coverURL(for: game), title: game.title, titleOnPlaceholder: false, fallback: model.headerURL(for: game))
                    .frame(width: coverHeight * 2 / 3, height: coverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 8)
                    .rotationEffect(.degrees(Double(index - shown.count / 2) * 4))
                    .offset(y: CGFloat(abs(index - shown.count / 2)) * 6)
                    .zIndex(Double(shown.count - index))
            }
        }
        .frame(width: width * 0.5, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, Theme.Space.margin)
        .padding(.bottom, Theme.Space.l)
        .opacity(0.92)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Not signed in to (design: signed-out.html): the same status and button for every store.
    private var signedOut: Bool { model.accountsChecked && !model.storesWithAccount.contains(kind) }

    private var status: String {
        if signedOut { return String(localized: "You're not signed in") }
        var parts: [String] = []
        let installed = games.filter(\.isInstalled).count
        if !games.isEmpty { parts.append(String(localized: "\(games.count) games")) }
        if installed > 0 { parts.append(String(localized: "\(installed) installed")) }
        switch kind {
        case .steam:
            if let name = model.steamAccountName, !name.isEmpty { parts.append(String(localized: "Signed in as \(name)")) }
            else if !model.isSteamInstalled { parts.append(String(localized: "Not set up")) }
        case .epic, .gog:
            parts.append(model.isSignedIn(kind) ? String(localized: "Signed in") : String(localized: "Not signed in"))
        default:
            if !model.isLauncherInstalled(kind) { parts.append(String(localized: "Not set up")) }
            else { parts.append(model.isLauncherSignedIn(kind) ? String(localized: "Signed in") : String(localized: "Not signed in")) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var action: some View {
        if signedOut {
            if let activity = model.storeActivity[kind] {
                HStack(spacing: 6) { LoadingGrape().foregroundStyle(.white); Text(activity) }.foregroundStyle(Theme.onDark)
            } else {
                HStack(spacing: Theme.Space.s + 4) {
                    Button { Task { await model.signInOrShow(kind) } } label: { Text(model.signInTitle(kind)) }
                        .buttonStyle(PlayButtonStyle())
                        .disabled(model.signInDisabled(kind))
                    Text(model.signInHint(kind)).font(.callout).foregroundStyle(Theme.onDarkSecondary)
                }
            }
        } else {
            signedInAction
        }
    }

    @ViewBuilder private var signedInAction: some View {
        switch kind {
        case .steam:
            Button { Task { await model.openSteam() } } label: { OpenSteamLabel() }
                .buttonStyle(PlayButtonStyle()).disabled(model.steamLaunch != .idle)
        case .epic, .gog:
            if model.storeActivity[kind] != nil {
                HStack(spacing: 6) { LoadingGrape().foregroundStyle(.white); Text(model.storeActivity[kind] ?? "") }
                    .foregroundStyle(Theme.onDark)
            } else if model.isSignedIn(kind) {
                Button { model.openStoreWebsite(kind) } label: { Label("Open \(kind.displayName)", systemImage: "safari") }
                    .buttonStyle(PlayButtonStyle())
            } else {
                Button { Task { await model.connect(kind) } } label: { Label("Sign In…", systemImage: "person.crop.circle") }
                    .buttonStyle(PlayButtonStyle())
                    .disabled(model.signInDisabled(kind))
            }
        default:
            if let activity = model.storeActivity[kind] {
                HStack(spacing: 6) { LoadingGrape().foregroundStyle(.white); Text(activity) }.foregroundStyle(Theme.onDark)
            } else {
                Button { Task { await model.openLauncher(kind) } } label: {
                    Label(model.isLauncherInstalled(kind) ? String(localized: "Open \(kind.displayName)") : String(localized: "Set Up \(kind.displayName)"),
                          systemImage: "macwindow")
                }
                .buttonStyle(PlayButtonStyle())
            }
        }
    }
}
