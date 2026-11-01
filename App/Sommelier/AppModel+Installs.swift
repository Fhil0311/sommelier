// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit

extension AppModel {
    private var apiBase: URL {
        ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:)) ?? CompatibilityReporter.defaultURL
    }

    /// Installs, for the owner's numbers (`POST /v1/installs`). Every new install says so once, with only the
    /// version: nothing kept, no id. With sharing on, once a day with the install's own random id (not the
    /// reports' id), so the owner sees who still has Sommelier: silent for 30 days counts as uninstalled, heard from
    /// again as back. Not from developer builds. Called at start and after each library refresh (noteAccounts).
    func countInstall() {
        // Only a new Mac starts the clock to the first game: one that never answered the sharing question.
        if settings.installedAt == nil, settings.shareReports == nil { settings.installedAt = Date() }
        #if !DEBUG
        if settings.installCounted != true {
            postInstall([:]) { [weak self] in self?.settings.installCounted = true }
        }
        guard sharesReports else { return }
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        guard settings.installSentDay != day else { return }
        let id: String
        if let known = settings.installID { id = known } else { id = UUID().uuidString.lowercased(); settings.installID = id }
        postInstall(["id": id]) { [weak self] in self?.settings.installSentDay = day }
        #endif
    }

    /// Sharing turned off, or "Delete my data": the install leaves the count (rather than turning up as
    /// uninstalled 30 days later), and a later one starts under a new id.
    func leaveInstallCount() {
        guard let id = settings.installID else { return }
        settings.installID = nil
        settings.installSentDay = nil
        #if !DEBUG
        let body: [String: Any] = ["id": id, "leave": true]
        postInstall(body) {}
        #endif
    }

    private func postInstall(_ body: [String: Any], done: @escaping @MainActor () -> Void) {
        var request = URLRequest(url: apiBase.appendingPathComponent("v1/installs"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Sommelier/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task {
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) || status == 429 else { return }
            done()
        }
    }

    /// The first game played: minutes since Sommelier first started, sent once with the usage note.
    func noteFirstGame() {
        guard settings.firstGameMinutes == nil, let installed = settings.installedAt else { return }
        settings.firstGameMinutes = max(0, Int(Date().timeIntervalSince(installed) / 60))
    }

    func notePad(_ kind: ControllerKind) {
        let name = switch kind { case .xbox: "xbox"; case .playStation: "playStation"; case .other: "other" }
        var seen = settings.usagePads ?? []
        if !seen.contains(name) { seen.append(name); settings.usagePads = seen }
    }

    /// Once a day, when the player shares how games run: which stores are signed in, whether Controller Mode,
    /// clips and the in-game counter are used, the kinds of controllers, and once the minutes to the first game.
    /// Under the same random id as reports; "Delete my data" deletes it too. Sent once the stores have been
    /// checked (AppModel+Stores), so they're known; not from developer builds.
    func sendUsage() {
        #if DEBUG
        return
        #else
        guard sharesReports, accountsChecked else { return }
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        guard settings.usageSentDay != day else { return }
        let client: String
        if let id = settings.reportClientID { client = id } else { client = UUID().uuidString.lowercased(); settings.reportClientID = client }
        let minutes = settings.firstGameSent == true ? nil : settings.firstGameMinutes
        let body: [String: Any?] = [
            "client": client, "app": appVersion,
            "stores": storesWithAccount.map(\.rawValue).sorted(),
            "controllerMode": settings.usageControllerMode == true,
            "clips": settings.clips?.enabled == true,
            "counter": settings.inGameCounter?.enabled == true,
            "pads": settings.usagePads ?? [],
            "firstGameMinutes": minutes,
        ]
        var request = URLRequest(url: apiBase.appendingPathComponent("v1/usage"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Sommelier/\(appVersion)", forHTTPHeaderField: ShaderShare.clientHeader)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        Task {
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 201 else { return }
            settings.usageSentDay = day
            settings.usageControllerMode = nil
            settings.usagePads = nil
            if minutes != nil { settings.firstGameSent = true }
        }
        #endif
    }
}
