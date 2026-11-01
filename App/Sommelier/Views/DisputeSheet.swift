// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

/// "What's wrong with …?": the player says a game doesn't really run here (design: dispute-status.html). From the
/// status card, while the game counts as working, it takes the "Works" mark off for this Mac; from the game's menu
/// at any other time it only sends a report, so it can't be sent without one.
struct DisputeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var problem: StatusDispute.Problem = .doesNotStart
    @State private var note = ""
    @State private var sendReport = false
    @State private var removesMark = false
    @State private var preview: FailureReport?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's wrong with \(game.title)?").font(.headline)
                if removesMark {
                    Text("We'll take the “Works” mark off for this Mac.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $problem) {
                ForEach(StatusDispute.Problem.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            TextField("What happened (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Send a report to the Sommelier team", isOn: $sendReport).toggleStyle(.checkbox)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("The report includes the last launch's log, without your name, accounts or personal folders.")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("What's in the report") { togglePreview() }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
            }
            if let preview { DisputeReportPreview(report: preview) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    if sending { LoadingGrape() } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(sending || (!removesMark && !sendReport))
            }
        }
        .padding(Theme.Space.l)
        .frame(width: preview == nil ? 440 : 600)
        .animation(.easeInOut(duration: 0.2), value: preview != nil)
        .onAppear {
            removesMark = model.canDisputeStatus(game)
            sendReport = model.sharesReports
        }
    }

    private func togglePreview() {
        if preview != nil { preview = nil; return }
        Task { preview = await model.disputeReport(for: game, problem: problem, note: note) }
    }

    private func send() {
        sending = true
        Task {
            await model.disputeStatus(of: game, problem: problem, note: note, sendReport: sendReport, removeMark: removesMark)
            sending = false
            dismiss()
        }
    }
}

/// What the dispute report holds, in plain words, with the end of the log.
private struct DisputeReportPreview: View {
    let report: FailureReport

    var body: some View {
        let d = report.diagnostics
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: 3) {
                row(String(localized: "Game"), report.game.title ?? report.game.id)
                row("Sommelier", [report.sommelier.app, d.engineVersion.map { String(localized: "engine \($0)") }].compactMap { $0 }.joined(separator: ", "))
                if let backend = d.backend { row(String(localized: "Graphics"), GraphicsBackend(rawValue: backend)?.localizedName ?? backend) }
                row("Mac", [d.chip, d.macOS.isEmpty ? "" : "macOS \(d.macOS)"].filter { !$0.isEmpty }.joined(separator: ", "))
                row(String(localized: "What happened"), report.matched.first.flatMap(StatusDispute.Problem.init(ruleID:))?.localizedTitle ?? "—")
                if let note = d.playerNote { row(String(localized: "Your note"), note) }
            }
            .font(.callout)
            Text("Game log (the end)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(d.logTail.isEmpty ? String(localized: "No log") : d.logTail)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

extension StatusDispute.Problem {
    init?(ruleID: String) { self.init(rawValue: Self.allCases.first { $0.ruleID == ruleID }?.rawValue ?? "") }

    var localizedTitle: String {
        switch self {
        case .doesNotStart: String(localized: "Doesn't start")
        case .blackScreen: String(localized: "Black screen")
        case .crashes: String(localized: "Crashes")
        case .tooSlow: String(localized: "Too slow to play")
        case .other: String(localized: "Other")
        }
    }

    /// The same, inside a sentence ("…doesn't work for you: black screen.").
    var localizedInSentence: String {
        switch self {
        case .doesNotStart: String(localized: "doesn't start")
        case .blackScreen: String(localized: "black screen")
        case .crashes: String(localized: "crashes")
        case .tooSlow: String(localized: "too slow to play")
        case .other: ""
        }
    }
}
