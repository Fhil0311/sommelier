// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// The sidebar's note about app updates: what "Check Now" found (for a moment), the install, and an update that
/// waits for a game to end before restarting. A waiting update itself is the toolbar reminder's (`UpdateReminder`).
struct UpdateBadge: View {
    @Environment(Updater.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            note(String(localized: "Checking for updates…"), symbol: nil)
        case .upToDate:
            note(String(localized: "Sommelier is up to date"), symbol: "checkmark.circle")
        case .failed:
            note(String(localized: "Couldn't check for updates"), symbol: "exclamationmark.triangle")
        case .available, .downloading:
            EmptyView()                // the toolbar reminder and the update sheet say it (UpdateSheet)
        case .installing(let version):
            note(String(localized: "Installing version \(version)…"), symbol: nil)
        case .readyToRestart(let version):
            let playing = !model.gameStates.isEmpty
            card(String(localized: "Version \(version) is ready")) {
                Button { updater.restart() } label: { Text("Restart").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(playing)                               // never in the middle of a game
            }
            .help(playing ? String(localized: "Restart after your game to finish the update.") : "")
        }
    }

    private func note(_ text: String, symbol: String?) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let symbol { Image(systemName: symbol) } else { LoadingGrape() }
            Text(text).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m + 2)
    }

    private func card<Action: View>(_ title: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s - 2) {
            Label {
                Text(title).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.wineLight)
            }
            action()
        }
        .padding(.horizontal, Theme.Space.m - 4).padding(.vertical, Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.07)))
        .padding(.horizontal, Theme.Space.s + 2)
    }
}

/// "Sommelier 1.4 is available" (design: update2.html): the version, what's in it, and the choice; after "Update"
/// the download's progress takes the buttons' place, then "Restarting…". A big release gets up to three points and
/// wine pixels falling behind the header; a small one, one line.
struct UpdateSheet: View {
    @Environment(Updater.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The release the sheet is about, kept when the state moves on to the download.
    @State private var release: Updater.Available?

    var body: some View {
        if let item = release ?? available {
            let big = Updater.isMajorRelease(item.version, over: updater.currentVersion)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .center, spacing: Theme.Space.m - 4) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sommelier \(item.version) is available").font(.headline).foregroundStyle(Theme.onDark)
                        Text(subtitle(item)).font(.callout).foregroundStyle(Theme.onDarkSecondary)
                    }
                }
                notes(item, big: big)
                footer(item)
            }
            .padding(20)
            .frame(width: 440)
            .background {
                ZStack(alignment: .top) {
                    Theme.graphite
                    if big && !reduceMotion { FallingGrapes().frame(height: 110).allowsHitTesting(false) }
                }
            }
            .environment(\.colorScheme, .dark)
            .interactiveDismissDisabled(item.critical || isUpdating)
            .onAppear { release = available }
        }
    }

    private var available: Updater.Available? {
        if case .available(let item) = updater.state { return item }
        return nil
    }

    private var isUpdating: Bool {
        switch updater.state {
        case .downloading, .installing, .readyToRestart: true
        default: false
        }
    }

    private func subtitle(_ item: Updater.Available) -> String {
        if item.critical { return String(localized: "You have \(updater.currentVersion). This update is required to keep Sommelier working.") }
        guard item.bytes > 0 else { return String(localized: "You have \(updater.currentVersion).") }
        return String(localized: "You have \(updater.currentVersion) · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
    }

    @ViewBuilder private func notes(_ item: Updater.Available, big: Bool) -> some View {
        let points = ReleaseNotes.points(item.notes)
        if big, !points.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(points.prefix(3), id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.wineLight).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout).foregroundStyle(Theme.onDark)
        } else {
            Text(ReleaseNotes.line(item.notes) ?? String(localized: "Bug fixes and stability improvements."))
                .font(.callout).foregroundStyle(Theme.onDark).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func footer(_ item: Updater.Available) -> some View {
        switch updater.state {
        case .downloading(_, let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? 0).tint(Theme.wineLight)
                Text(progressLine(progress)).font(.caption).monospacedDigit().foregroundStyle(Theme.onDarkSecondary)
            }
        case .installing:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: 1).tint(Theme.wineLight)
                Text("Restarting…").font(.caption).foregroundStyle(Theme.onDarkSecondary)
            }
        case .readyToRestart:
            HStack {
                Text("Restart after your game to finish the update.").font(.caption).foregroundStyle(Theme.onDarkSecondary)
                Spacer()
                Button("Later") { updater.showingDetails = false }.buttonStyle(SheetButtonStyle()).keyboardShortcut(.cancelAction)
            }
        default:
            HStack {
                Text("Games and saves aren't affected.").font(.caption).foregroundStyle(Theme.onDarkTertiary)
                Spacer()
                if !item.critical { Button("Later") { updater.later() }.buttonStyle(SheetButtonStyle()).keyboardShortcut(.cancelAction) }
                Button("Update") { updater.update() }.buttonStyle(SheetButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// "37% · 18 of 48 MB".
    private func progressLine(_ progress: Double?) -> String {
        let percent = Int(((progress ?? 0) * 100).rounded(.down))
        guard updater.totalBytes > 0 else { return "\(percent)%" }
        let done = ByteCountFormatter.string(fromByteCount: updater.downloadedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: updater.totalBytes, countStyle: .file)
        return String(localized: "\(percent)% · \(done) of \(total)")
    }
}

/// What the appcast says about a release, cut down for the sheet.
enum ReleaseNotes {
    /// The list items of the notes, as plain text.
    static func points(_ html: String) -> [String] {
        matches(of: #"<li[^>]*>(.*?)</li>"#, in: html).map(plain).filter { !$0.isEmpty }
    }

    /// The notes as one plain line (a small release: "Fixes: …"), nil when there's nothing.
    static func line(_ html: String) -> String? {
        let text = plain(html)
        return text.isEmpty ? nil : text
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

/// Wine pixels drizzling down behind a big release's header, like berries falling into the vat: no glow, no
/// gradient, a slow loop.
private struct FallingGrapes: View {
    private struct Pixel { let x: Double, delay: Double, size: Double, light: Bool }
    private let pixels: [Pixel] = {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            Pixel(x: .random(in: 0.03...0.97, using: &generator), delay: .random(in: 0...3.6, using: &generator),
                  size: Double.random(in: 0...1, using: &generator) < 0.35 ? 5 : 7, light: Double.random(in: 0...1, using: &generator) < 0.25)
        }
    }()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for pixel in pixels {
                    let t = ((now + pixel.delay).truncatingRemainder(dividingBy: 3.6)) / 3.6
                    let y = -12 + t * (size.height + 12)
                    // In quickly, out as it reaches the bottom of the header.
                    let opacity = t < 0.15 ? t / 0.15 : max(0, 1 - (t - 0.15) / 0.85)
                    let rect = CGRect(x: pixel.x * size.width, y: y, width: pixel.size, height: pixel.size)
                    context.opacity = opacity * 0.9
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(pixel.light ? Theme.wineLight : Theme.wine))
                }
            }
        }
    }
}

/// The toolbar's reminder that an update waits (after "Later"): a round button with the grape and a small wine
/// square on its corner; it opens the sheet again, and stays until the update is installed.
struct UpdateReminder: View {
    @Environment(Updater.self) private var updater
    @State private var landed = false

    var body: some View {
        if let version = updater.reminderVersion {
            Button { updater.showingDetails = true } label: {
                ZStack(alignment: .topTrailing) {
                    GrapeMark(filled: 6).foregroundStyle(Theme.onDark).frame(width: 15, height: 15)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                    RoundedRectangle(cornerRadius: 2).fill(Theme.wineLight).frame(width: 9, height: 9)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: 1, y: -1)
                }
            }
            .buttonStyle(.plain)
            .help(String(localized: "Update available: Sommelier \(version)"))
            .scaleEffect(landed ? 1 : 0.4).opacity(landed ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { landed = true } }
            .onChange(of: updater.putOff) {
                landed = false
                withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.15)) { landed = true }
            }
        }
    }
}
