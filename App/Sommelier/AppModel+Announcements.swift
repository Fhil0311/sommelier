// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import UserNotifications

/// Announcements from the Sommelier team: read when Sommelier starts and every three hours, shown as banners over
/// the library until closed. The ones marked `notify` also come once as a macOS notification.
extension AppModel {
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// What to show now: for this version and these games, not closed, important ones first.
    var visibleAnnouncements: [Announcement] {
        let closed = Set(settings.dismissedAnnouncements ?? [])
        let owned = Set(library.games.map(\.id))
        let now = Date()
        return announcements
            .filter { !closed.contains($0.id) && $0.applies(now: now, appVersion: appVersion, games: owned) }
            .sorted { ($0.level == .important ? 0 : 1) < ($1.level == .important ? 0 : 1) }
    }

    func watchAnnouncements() {
        let service = AnnouncementsService(paths: paths)
        announcements = service.cached()
        Task {
            while !Task.isCancelled {
                announcements = await Task.detached { await service.refresh() }.value
                notifyNewAnnouncements()
                try? await Task.sleep(for: .seconds(3 * 3600))
            }
        }
    }

    func dismissAnnouncement(_ announcement: Announcement) {
        var closed = settings.dismissedAnnouncements ?? []
        if !closed.contains(announcement.id) { closed.append(announcement.id) }
        // Ids of announcements the service no longer lists can go, so the list doesn't grow forever.
        let listed = Set(announcements.map(\.id))
        settings.dismissedAnnouncements = closed.filter { listed.contains($0) }
    }

    /// The ones marked `notify` that this Mac hasn't been told about yet, as macOS notifications (asking once).
    private func notifyNewAnnouncements() {
        let told = Set(settings.notifiedAnnouncements ?? [])
        let new = visibleAnnouncements.filter { $0.notify == true && !told.contains($0.id) }
        guard !new.isEmpty else { return }
        settings.notifiedAnnouncements = (settings.notifiedAnnouncements ?? []).filter { id in announcements.contains { $0.id == id } }
            + new.map(\.id)
        let languages = Locale.preferredLanguages
        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            for announcement in new {
                let content = UNMutableNotificationContent()
                content.title = Announcement.text(announcement.title, languages: languages) ?? ""
                content.body = Announcement.text(announcement.body, languages: languages) ?? ""
                try? await center.add(UNNotificationRequest(identifier: "announcement-\(announcement.id)", content: content, trigger: nil))
            }
        }
    }
}
