// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AVKit
import SommelierKit
import SwiftUI

// MARK: The Clips page

/// "Clips" in the sidebar: what was saved, by day, with a filter by game and by kind.
struct ClipsView: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ClipRecorder.shared
    @State private var kind = Kind.all
    @State private var opened: Clip?

    enum Kind: Hashable { case all, favorites, automatic }

    private var settings: ClipSettings { model.settings.clips ?? ClipSettings() }

    private var shown: [Clip] {
        recorder.clips.filter { clip in
            if let game = model.clipsGame, clip.gameID != game { return false }
            switch kind {
            case .all: return true
            case .favorites: return clip.favorite
            case .automatic: return clip.isAutomatic
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.top, 70)
                banners.padding(.top, 14)
                if !settings.enabled && recorder.clips.isEmpty {
                    BeforeTurningOn().padding(.top, 24)
                } else if recorder.clips.isEmpty {
                    NoClipsYet().padding(.top, 24)
                } else {
                    filters.padding(.top, 18)
                    list.padding(.top, 8)
                    footer.padding(.top, 26)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { recorder.reload() }
        .sheet(item: $opened) { clip in ClipDetailView(clip: clip).environment(model) }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Clips").font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.onDark)
            HStack(spacing: 8) {
                Text(statusText).font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary)
                SettingsLink { Text("Settings").font(.system(size: 13)) }.buttonStyle(.link)
            }
        }
    }

    private var statusText: String {
        if !settings.enabled { return String(localized: "Off") }
        if recorder.access == .denied { return String(localized: "Not recording") }
        if recorder.stoppedEarly { return String(localized: "Recording stopped") }
        return String(localized: "Keeps the last \(Int(settings.length.seconds)) seconds")
    }

    @ViewBuilder private var banners: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.enabled, recorder.access == .denied {
                ClipBanner(title: String(localized: "Sommelier needs permission to record the screen"),
                           text: String(localized: "macOS asks for it in System Settings › Privacy & Security › Screen & System Audio Recording. Without it, no clips are recorded. The game is not affected."),
                           button: String(localized: "Open System Settings")) { ClipLinks.openScreenRecording() }
                HStack(spacing: 8) {
                    Text("If you’ve already allowed it, restart Sommelier.").font(.system(size: 12.5)).foregroundStyle(Theme.onDarkSecondary)
                    Button("Restart Sommelier") { recorder.relaunch() }
                }
            }
            if settings.enabled, recorder.freeSpaceLow {
                ClipBanner(title: String(localized: "Not enough space for clips"),
                           text: String(localized: "Clips need at least 2 GB free on this Mac. Free up space, or remove some clips below."),
                           button: recorder.clips.contains { $0.isAutomatic && !$0.favorite } ? String(localized: "Remove Automatic Clips") : nil) { recorder.removeAutomaticClips() }
            }
            if settings.enabled, recorder.stoppedEarly {
                ClipBanner(title: String(localized: "Recording stopped during the last game"),
                           text: String(localized: "The game’s window changed too often, or the Mac went to sleep. Recording starts again with the next game."),
                           button: nil) {}
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { model.clipsGame ?? "" }, set: { model.clipsGame = $0.isEmpty ? nil : $0 })) {
                Text("All games").tag("")
                ForEach(games, id: \.id) { Text($0.title).tag($0.id) }
            }
            .labelsHidden().fixedSize()
            Picker("", selection: $kind) {
                Text("All").tag(Kind.all)
                Text("Favorites").tag(Kind.favorites)
                Text("Automatic").tag(Kind.automatic)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
        }
    }

    private var games: [(id: String, title: String)] {
        var seen: Set<String> = []
        return recorder.clips.compactMap { clip in
            guard !clip.gameID.isEmpty, seen.insert(clip.gameID).inserted else { return nil }
            return (clip.gameID, clip.gameTitle)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var list: some View {
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }
        let days = groups.keys.sorted(by: >)
        let columns = [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: Theme.Space.m + 4, alignment: .top)]
        return VStack(alignment: .leading, spacing: 18) {
            if shown.isEmpty {
                Text("No clips here.").font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary).padding(.top, 10)
            }
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 10) {
                    Theme.eyebrow(Self.dayName(day), color: Theme.onDarkTertiary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.m + 4) {
                        ForEach(groups[day] ?? []) { clip in
                            ClipCard(clip: clip).onTapGesture { opened = clip }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clips take \(ByteCountFormatter.string(fromByteCount: Int64(recorder.totalBytes), countStyle: .file)) in Movies › \(recorder.folder.lastPathComponent). Automatic clips use up to \(settings.automaticLimitGB) GB; the oldest go first.")
                .font(.system(size: 12)).foregroundStyle(Theme.onDarkTertiary)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recorder.folder]) }
                .buttonStyle(.link).font(.system(size: 12))
        }
    }

    static func dayName(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.day().month(.wide).year())
    }
}

enum ClipLinks {
    static func openScreenRecording() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}

/// A strip with a title, a line of explanation and maybe a button: what is wrong with clips, and what to do.
struct ClipBanner: View {
    let title: String
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.onDark)
                Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.onDarkSecondary).fixedSize(horizontal: false, vertical: true)
                if let button { Button(button, action: action).padding(.top, 4) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.fill(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// Before clips are turned on: what they are, in a few lines, and the button.
struct BeforeTurningOn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings.clips ?? ClipSettings()
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.system(size: 34)).foregroundStyle(Theme.onDarkTertiary)
            Text("Your best moments and what went wrong, saved from your games.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.onDarkSecondary)
            Text("Save the last minute of a game with one key").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.onDark)
                .multilineTextAlignment(.center)
            Text("While you play, Sommelier keeps the last 30 seconds to 2 minutes of the game in memory. Press \(settings.keyName) and they become a clip. If you don’t press it, nothing is kept.")
                .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Text("Only the game’s window is recorded: notifications and other apps never get in. Clips stay on this Mac.")
                .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Text("macOS will ask you to allow screen recording for Sommelier. It may ask again from time to time.")
                .font(.system(size: 12)).foregroundStyle(Theme.onDarkTertiary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button("Turn On Clips") { ClipSetup.turnOn(model) }
                .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

enum ClipSetup {
    @MainActor static func turnOn(_ model: AppModel) {
        var settings = model.settings.clips ?? ClipSettings()
        settings.enabled = true
        model.settings.clips = settings
        ClipRecorder.shared.requestAccess()
    }
}

struct NoClipsYet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings.clips ?? ClipSettings()
        VStack(spacing: 8) {
            Image(systemName: "film").font(.system(size: 30)).foregroundStyle(Theme.onDarkTertiary)
            Text("No clips yet").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.onDark)
            Text("Start a game and press \(settings.keyName) when something worth keeping happens. The last \(Int(settings.length.seconds)) seconds become a clip and show up here.")
                .font(.system(size: 13)).foregroundStyle(Theme.onDarkSecondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if settings.saveOnCrash {
                Text("If a game crashes, the last 30 seconds before it are saved on their own.")
                    .font(.system(size: 12)).foregroundStyle(Theme.onDarkTertiary).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: A clip in the list

struct ClipCard: View {
    let clip: Clip
    @State private var recorder = ClipRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                ClipThumbnail(url: clip.url)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line(0.1)))
                HStack(spacing: 5) {
                    if clip.origin == .crash { badge(String(localized: "Crash"), "exclamationmark.triangle.fill") }
                    if clip.origin == .controller { badge(String(localized: "Controller"), "gamecontroller.fill") }
                }
                .padding(7)
                VStack {
                    Spacer()
                    HStack {
                        if !clip.hasSound { Image(systemName: "speaker.slash.fill").help("No sound") }
                        Spacer()
                        if clip.seconds > 0 { Text(Self.length(clip.seconds)).monospacedDigit() }
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .shadow(color: .black.opacity(0.6), radius: 3)
            }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name ?? clip.gameTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.onDark).lineLimit(1)
                    Text(clip.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(Theme.onDarkTertiary)
                }
                Spacer(minLength: 0)
                Button { recorder.setFavorite(!clip.favorite, clip) } label: {
                    Image(systemName: clip.favorite ? "star.fill" : "star").foregroundStyle(clip.favorite ? Color.yellow : Theme.onDarkTertiary)
                }
                .buttonStyle(.plain).help("Favorite")
            }
        }
        .contentShape(Rectangle())
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3).background(.black.opacity(0.6), in: Capsule())
    }

    static func length(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A picture from the middle of a clip, made once and kept.
struct ClipThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            Theme.fill(0.08)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "film").foregroundStyle(Theme.onDarkTertiary) }
        }
        .clipped()
        .task(id: url) {
            guard let url else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            let made = await Task.detached(priority: .utility) { () -> NSImage? in
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 640, height: 640)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                let time = CMTime(seconds: max(0, duration / 2), preferredTimescale: 600)
                guard let cg = try? await generator.image(at: time).image else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            if let made { Self.cache.setObject(made, forKey: url as NSURL); image = made }
        }
    }
}

// MARK: One clip

struct ClipDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = ClipRecorder.shared
    let clip: Clip
    @State private var player = AVPlayer()
    @State private var name = ""
    @State private var favorite = false
    @State private var sound = true
    @State private var duration: Double = 0
    @State private var from: Double = 0
    @State private var to: Double = 0
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField(clip.gameTitle, text: $name).textFieldStyle(.plain).font(.system(size: 18, weight: .bold))
                    .onSubmit { recorder.rename(clip, to: name) }
                Button { favorite.toggle(); recorder.setFavorite(favorite, clip) } label: {
                    Image(systemName: favorite ? "star.fill" : "star").foregroundStyle(favorite ? Color.yellow : .secondary).font(.system(size: 16))
                }
                .buttonStyle(.plain).help("Favorite")
            }
            VideoPlayer(player: player)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !clip.hasSound {
                Label("No sound", systemImage: "speaker.slash").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Toggle("Sound", isOn: $sound).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: sound) { _, on in player.isMuted = !on }
            }
            if duration > 4 {
                VStack(alignment: .leading, spacing: 6) {
                    TrimBar(duration: duration, from: $from, to: $to) { player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }
                        .frame(height: 38)
                    Text("Drag the edges to trim.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Cuts snap to the ticks (every 2 seconds), so the copy saves at once and loses no quality.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    HStack {
                        Text(verbatim: "\(ClipCard.length(from)) – \(ClipCard.length(to))").monospacedDigit().font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Trimmed Copy") { saveTrimmed() }
                            .disabled(saving || (from < 0.5 && to > duration - 0.5) || to - from < 2)
                    }
                }
            }
            if clip.origin == .crash {
                Text("Saved before the game stopped responding").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else if clip.isAutomatic {
                Text("Automatic clips make room for new ones when they reach the limit, oldest first. A favorite is never removed.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            info
            if failed { Text("The copy couldn’t be saved.").font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                if let url = clip.url { ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") } }
                Button("Show in Finder") { if let url = clip.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Button("Move to Trash", role: .destructive) { trash() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            name = clip.name ?? ""
            favorite = clip.favorite
            guard let url = clip.url else { return }
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            let asset = AVURLAsset(url: url)
            duration = (try? await asset.load(.duration).seconds) ?? clip.seconds
            to = duration
        }
        .onDisappear {
            player.pause()
            if (clip.name ?? "") != name { recorder.rename(clip, to: name) }
        }
    }

    private var info: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            row(String(localized: "Game"), clip.gameTitle)
            row(String(localized: "Saved"), origin)
            if duration > 0 { row(String(localized: "Length"), ClipCard.length(duration)) }
            if !clip.quality.isEmpty { row(String(localized: "Quality"), clip.quality) }
            row(String(localized: "Size"), ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file))
        }
        .font(.system(size: 12))
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow { Text(key).foregroundStyle(.secondary); Text(value) }
    }

    private var origin: String {
        let when = clip.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        switch clip.origin {
        case .key: return "\((model.settings.clips ?? ClipSettings()).keyName) · \(when)"
        case .controller: return String(localized: "Controller · \(when)")
        case .crash: return String(localized: "Before the crash · \(when)")
        }
    }

    private func saveTrimmed() {
        guard let source = clip.url else { return }
        saving = true; failed = false
        let target = ClipStore(folder: recorder.folder).newURL(game: clip.gameTitle, at: Date())
        let start = from, end = to
        let kept = clip
        Task {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await ClipCapture.trim(source, from: start, to: end, into: target)
                var note = kept
                note.id = target.deletingPathExtension().lastPathComponent
                note.date = Date(); note.seconds = end - start; note.origin = .key; note.favorite = false
                ClipStore(folder: recorder.folder).save(note, for: target)
                recorder.reload()
                dismiss()
            } catch { failed = true }
            saving = false
        }
    }

    private func trash() {
        guard let url = clip.url else { return }
        player.pause()
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        let note = url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.trashItem(at: note, resultingItemURL: nil)
        recorder.reload()
        dismiss()
    }
}

/// The two edges of a cut over a strip with a tick every two seconds; each snaps to a tick.
struct TrimBar: View {
    let duration: Double
    @Binding var from: Double
    @Binding var to: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }
            let time: (CGFloat) -> Double = { ClipStore.snapped(Double($0 / width) * duration, duration: duration) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                ForEach(0...Int(duration / 2), id: \.self) { tick in
                    Rectangle().fill(.tertiary).frame(width: 1, height: tick % 5 == 0 ? 14 : 8)
                        .position(x: x(Double(tick) * 2), y: geo.size.height - 10)
                }
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                    .frame(width: max(2, x(to) - x(from)))
                    .offset(x: x(from))
                handle.position(x: x(from), y: geo.size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        from = min(time(value.location.x), to - 2); seek(from)
                    })
                handle.position(x: x(to), y: geo.size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        to = max(time(value.location.x), from + 2); seek(max(0, to - 0.5))
                    })
            }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: 8, height: 34)
    }
}

// MARK: On a game's page

/// "Clips" beside Saves on a game's page: how many there are and the way to them, or how to make one.
struct ClipsCard: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ClipRecorder.shared
    let game: Game

    var body: some View {
        let settings = model.settings.clips ?? ClipSettings()
        let count = recorder.clips.filter { $0.gameID == game.id }.count
        if settings.enabled || count > 0 {
            VStack(alignment: .leading, spacing: 7) {
                Theme.eyebrow(String(localized: "Clips"), color: Theme.onDarkTertiary)
                if count > 0 {
                    Button {
                        model.clipsGame = game.id
                        model.path = NavigationPath()
                        model.selection = .clips
                    } label: { Text("All \(count)").font(.system(size: 12.5, weight: .semibold)) }
                        .buttonStyle(.link)
                } else {
                    Text("Press \(settings.keyName) in the game to save the last \(Int(settings.length.seconds)) seconds.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.onDarkSecondary)
                }
            }
        }
    }
}
