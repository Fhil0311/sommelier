// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// The team's announcements over the pages, newest important first: at most two at a time; closing one shows the
/// next.
struct AnnouncementBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let shown = Array(model.visibleAnnouncements.prefix(2))
        if !shown.isEmpty {
            VStack(spacing: Theme.Space.s) {
                ForEach(shown) { AnnouncementBanner(announcement: $0) }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct AnnouncementBanner: View {
    @Environment(AppModel.self) private var model
    let announcement: Announcement

    private var languages: [String] {
        (AppLanguage.current == .system ? [] : [AppLanguage.current.rawValue]) + Locale.preferredLanguages
    }
    private var important: Bool { announcement.level == .important }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s + 4) {
            Image(systemName: important ? "exclamationmark.triangle.fill" : "megaphone.fill")
                .font(.title3)
                .foregroundStyle(important ? Theme.wineLight : Theme.onDark)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(Announcement.text(announcement.title, languages: languages) ?? "").font(.headline)
                if let body = Announcement.text(announcement.body, languages: languages) {
                    Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let link = announcement.link {
                    Link(destination: link.url) {
                        Text(Announcement.text(link.label, languages: languages) ?? String(localized: "Learn More"))
                    }
                    .font(.callout.weight(.medium))
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { model.dismissAnnouncement(announcement) }
            } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(Theme.Space.m - 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: Theme.shadow(0.35), radius: 12, y: 4)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(important ? Theme.wineLight.opacity(0.55) : Theme.fill(0.08))
        }
    }
}
