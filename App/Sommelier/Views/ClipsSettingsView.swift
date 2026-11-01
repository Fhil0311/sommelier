// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import SwiftUI

/// Settings › Clips.
struct ClipsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var recorder = ClipRecorder.shared
    @State private var choosingKey = false
    @State private var keyMonitor: Any?

    private var clips: Binding<ClipSettings> {
        Binding(get: { model.settings.clips ?? ClipSettings() }, set: { model.settings.clips = $0 })
    }

    var body: some View {
        let settings = clips.wrappedValue
        Form {
            Section {
                Toggle("Record clips while playing", isOn: Binding(
                    get: { settings.enabled },
                    set: { on in
                        var next = clips.wrappedValue; next.enabled = on; clips.wrappedValue = next
                        if on { recorder.requestAccess() }
                    }))
                Text("Sommelier keeps the last moments of the game in memory. Nothing is saved to disk until you press the key or the game crashes.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.enabled, recorder.access == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Screen recording is not allowed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Allow Sommelier in System Settings › Privacy & Security › Screen & System Audio Recording. Without it, nothing is recorded.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Open System Settings") { ClipLinks.openScreenRecording() }
                            Button("Restart Sommelier") { recorder.relaunch() }
                        }
                        Text("If you’ve already allowed it, restart Sommelier.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if settings.enabled {
                Section("Recording") {
                    LabeledContent("Save clip") {
                        HStack {
                            Text(choosingKey ? String(localized: "Press the new keys…") : settings.keyName)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            Button("Change…") { chooseKey() }.disabled(choosingKey)
                        }
                    }
                    Text("Works in any game.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Controller button", isOn: bind(\.controllerButton))
                    Text("Hold the Share or Create button for a second.").font(.caption).foregroundStyle(.secondary)
                    Picker("Length", selection: bind(\.length)) {
                        Text("30 s").tag(ClipSettings.Length.half)
                        Text("1 min").tag(ClipSettings.Length.minute)
                        Text("2 min").tag(ClipSettings.Length.twoMinutes)
                    }
                    .pickerStyle(.segmented)
                    Picker("Quality", selection: bind(\.quality)) {
                        Text("Light").tag(ClipSettings.Quality.light)
                        Text("Normal").tag(ClipSettings.Quality.normal)
                        Text("High").tag(ClipSettings.Quality.high)
                    }
                    .pickerStyle(.segmented)
                    Text("Light: 1080p, 30 fps, about \(ClipSettings.Quality.light.profile.megabytesPerMinute) MB a minute. Normal: up to 1440p, 60 fps, about \(ClipSettings.Quality.normal.profile.megabytesPerMinute) MB. High: the display’s resolution, 60 fps, about \(ClipSettings.Quality.high.profile.megabytesPerMinute) MB. In demanding games, recording can cost a few frames per second.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Game sound", isOn: bind(\.gameSound))
                    Text("Only the game. Other apps and the microphone are never recorded.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Save automatically") {
                    Toggle("When a game crashes or freezes", isOn: bind(\.saveOnCrash))
                    Text("The last 30 seconds before it happened.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    LabeledContent("Folder") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recorder.folder]) }
                    }
                    Text("Movies › \(recorder.folder.lastPathComponent). Clips are ordinary video files: move or delete them in Finder as you like.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Automatic clips take up to", selection: bind(\.automaticLimitGB)) {
                        ForEach([2, 5, 10, 20], id: \.self) { Text(verbatim: "\($0) GB").tag($0) }
                    }
                    Text("When the limit is reached, the oldest automatic clips go first. Clips you saved yourself and favorites are never removed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Only the game’s window is recorded: notifications, other apps and your desktop never get in. Clips never leave this Mac unless you share them. To turn clips off for one game, use the ⋯ menu on its page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopChoosing() }
    }

    private func bind<V>(_ path: WritableKeyPath<ClipSettings, V>) -> Binding<V> {
        Binding(get: { clips.wrappedValue[keyPath: path] }, set: { var next = clips.wrappedValue; next[keyPath: path] = $0; clips.wrappedValue = next })
    }

    // MARK: Choosing the key

    private func chooseKey() {
        choosingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopChoosing(); return nil }                    // Esc: leave it as it was
            var carbon = 0
            if event.modifierFlags.contains(.command) { carbon |= 256 }
            if event.modifierFlags.contains(.shift) { carbon |= 512 }
            if event.modifierFlags.contains(.option) { carbon |= 2048 }
            if event.modifierFlags.contains(.control) { carbon |= 4096 }
            guard ClipSettings.isValidKey(code: Int(event.keyCode), modifiers: carbon) else { NSSound.beep(); return nil }
            var next = clips.wrappedValue
            next.keyCode = Int(event.keyCode); next.keyModifiers = carbon
            clips.wrappedValue = next
            stopChoosing()
            return nil
        }
    }

    private func stopChoosing() {
        choosingKey = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
