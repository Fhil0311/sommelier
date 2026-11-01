// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// "This mod contains code": one sheet for every game and kind, shown once per mod before it goes in, with the
/// profile's line about the online policy when it has one. Cancel is the default answer. With
/// no mod named it is the policy's notice alone, with OK.
struct CodeConsentSheet: View {
    let consent: ModConsent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m - 4) {
                Image(systemName: consent.noticeOnly ? "info.circle.fill" : "exclamationmark.shield.fill")
                    .font(.title).foregroundStyle(consent.noticeOnly ? Theme.onDark : Theme.wineLight)
                VStack(alignment: .leading, spacing: 4) {
                    if !consent.noticeOnly, consent.hasCode {
                        Text(consent.names.count > 1 ? String(localized: "These mods contain code") : String(localized: "This mod contains code"))
                            .font(.headline)
                        Text("It runs its own code inside the game. Sommelier will add the loader it needs to the game folder. Install it only if you trust the author.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if !consent.noticeOnly {
                        // No code of its own, only a loader that has: the loader is a known tool Sommelier picks.
                        Text(consent.names.count > 1 ? String(localized: "These mods need a loader that runs code")
                                                     : String(localized: "This mod needs a loader that runs code"))
                            .font(.headline)
                        Text(consent.names.count > 1
                             ? String(localized: "They have no code of their own, but they work through a loader that runs inside the game. Sommelier will add the loader to the game folder.")
                             : String(localized: "It has no code of its own, but it works through a loader that runs inside the game. Sommelier will add the loader to the game folder."))
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !consent.noticeOnly {
                        if consent.names.count > 1 {
                            Text(consent.names.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                    } else {
                        Text(consent.game.title).font(.headline)
                    }
                    if let line = ModPolicyLine.text(for: consent.noticeKey) {
                        Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, consent.noticeOnly ? 0 : 4)
                    }
                }
            }
            HStack {
                Spacer()
                if consent.noticeOnly {
                    Button("OK") { consent.answer(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else if consent.hasCode {
                    Button("Install") { consent.answer(true) }
                    Button("Cancel") { consent.answer(false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    // Trusting the author is about code; a known loader is Sommelier's own choice, so Install leads.
                    Button("Cancel") { consent.answer(false) }.keyboardShortcut(.cancelAction)
                    Button("Install") { consent.answer(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 460)
    }
}

/// The policy's standing line: offline for a game with an anti-cheat, Story Mode only for one with an online
/// mode. Nil for a key the app doesn't know.
enum ModPolicyLine {
    static func text(for key: String?) -> String? {
        switch key {
        case "offline": String(localized: "With mods on, the game starts offline.")
        case "storyOnly": String(localized: "Mods work in Story Mode only. Before Red Dead Online, choose Play without mods.")
        default: nil
        }
    }
}

/// A plan's question before the archive goes in: which of several variants, or whether some files of an
/// uncertain kind are part of the mod.
struct ModQuestionSheet: View {
    let question: ModQuestion
    @State private var variant: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            switch question.question {
            case .variant(let options):
                Text("This mod comes in several versions").font(.headline)
                Text("Pick one. The mod's page says what they are.").font(.callout).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button { variant = option } label: {
                            HStack(spacing: 8) {
                                Image(systemName: (variant ?? options.first) == option ? "largecircle.fill.circle" : "circle")
                                Text(option.split(separator: "/").last.map(String.init) ?? option).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .font(.callout)
                HStack {
                    Spacer()
                    Button("Cancel") { question.answer(nil) }.keyboardShortcut(.cancelAction)
                    Button("Install") { question.answer(ModArchive.Answers(variant: variant ?? options.first)) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            case .kind(let id, let files):
                Text("Install these files as part of the mod?").font(.headline)
                ScrollView {
                    Text(files.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
                HStack {
                    Spacer()
                    Button("Cancel") { question.answer(nil) }.keyboardShortcut(.cancelAction)
                    Button("Leave Out") { question.answer(ModArchive.Answers(kinds: [id: false])) }
                    Button("Install") { question.answer(ModArchive.Answers(kinds: [id: true])) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 460)
    }
}

/// Other tools' loader files in the game folder before a launch without mods: the game doesn't start with
/// them (an anti-cheat would meet them), so they are set aside, with a backup, before the game starts.
struct ModLeftoversSheet: View {
    @Environment(AppModel.self) private var model
    let leftovers: ModLeftovers

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m - 4) {
                Image(systemName: "wrench.and.screwdriver.fill").font(.title).foregroundStyle(Theme.onDark)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set aside mod files from other tools").font(.headline)
                    Text("The game folder has mod files from another tool, and the game doesn't start with them.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(leftovers.specs.map { ModPath($0)?.components.last ?? $0 }.joined(separator: ", "))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Label(FixAction.removeModLeftovers(leftovers.specs).localizedSummary, systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.modLeftovers = nil }.keyboardShortcut(.cancelAction)
                Button("Fix and Play Again") { Task { await model.setAsideLeftoversAndPlay(leftovers) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 460)
    }
}
