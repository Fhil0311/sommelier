// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SommelierKit

/// "It doesn't really run": the player disputes a "works" that came from playing on this Mac or from other players.
/// The game stops counting as working here, and with the player's say-so a report goes to the team: the problem,
/// their note, and the last session's diagnostics (scrubbed, as with a launch failure).
extension AppModel {
    /// Whether the game page offers to dispute: the game is rated working by this Mac's play or by players' word.
    func canDisputeStatus(_ game: Game) -> Bool {
        guard !game.isNative, library.userData[game.id]?.disputed == nil else { return false }
        let rating = compatibility(of: game)
        return rating.verdict == .works && (rating.reason == .playedHere || rating.reason == .players)
    }

    func isStatusDisputed(_ game: Game) -> Bool { library.userData[game.id]?.disputed != nil }

    /// The problem the player gave, while the game's "works" is taken back.
    func disputedProblem(_ game: Game) -> StatusDispute.Problem? {
        library.userData[game.id]?.disputed.flatMap(StatusDispute.Problem.init(rawValue:))
    }

    /// Opens "What's wrong with …?" (`DisputeSheet`): from the status card, or "Report a Problem…" in the game's menu.
    func reportProblem(with game: Game) { disputeTarget = game }

    /// Takes the "works" back for this game (`removeMark`), and with `sendReport` tells the team (the player chose
    /// to in the sheet). The session report, when the player shares them, becomes a failed run so the game's
    /// rating counts it too. Returns whether the report went out.
    @discardableResult
    func disputeStatus(of game: Game, problem: StatusDispute.Problem, note: String, sendReport: Bool, removeMark: Bool = true) async -> Bool {
        if removeMark {
            var data = library.userData[game.id] ?? UserGameData()
            data.disputed = problem.rawValue
            library.userData[game.id] = data
            libraryStore.save(library)
        }
        var sent = false
        if sendReport {
            if removeMark { reportSession(game, outcome: .crashed, seconds: nil, since: library.userData[game.id]?.lastPlayed ?? Date()) }
            let report = await disputeReport(for: game, problem: problem, note: note)
            sent = (try? await report.send(clientVersion: reporter.clientVersion)) != nil
        }
        if removeMark || sent { disputeNotice = DisputeNotice(gameID: game.id, markRemoved: removeMark, reportSent: sent) }
        return sent
    }

    /// The report "What's in the report" shows and Send sends: the problem, the note, the last session's logs.
    func disputeReport(for game: Game, problem: StatusDispute.Problem, note: String) async -> FailureReport {
        let data = library.userData[game.id] ?? UserGameData()
        // A Mac version runs without Wine: no engine and no graphics layer to name in the report.
        let engine = game.isNative ? nil : engine(for: game.store.bottleKind)
        let backend: GraphicsBackend? = game.isNative ? nil : lastLaunchBackend[game.id] ?? profile(for: game).backend.resolved()
        let logURL = lastLog[game.id]
        let launcherLogURL = launcherLog(for: game, own: logURL)
        let steamHome: SteamHome? = game.store == .steam ? SteamHome(bottle: steam.bottle) : nil
        // The last session ended at `lastPlayed`; its crash report, if any, is from the hours before.
        let since = (data.lastPlayed ?? Date()).addingTimeInterval(-3 * 3600)
        var diagnostics = await Task.detached {
            DiagnosticsCollector.collect(game: game, engine: engine, backend: backend, logURL: logURL, launcherLogURL: launcherLogURL,
                                         steamHome: steamHome, started: since, exitCode: nil, secondsRunning: nil)
        }.value
        // As after a failed launch: the mods flag set and every mod's name out of the logs; the fixes it finds
        // aren't offered here.
        _ = attachModDiagnostics(to: &diagnostics, for: game, started: since)
        diagnostics.playerNote = StatusDispute.note(note)
        let client: String
        if let id = settings.reportClientID { client = id } else { client = UUID().uuidString.lowercased(); settings.reportClientID = client }
        return FailureReport(client: client,
                             game: .init(store: game.store.rawValue, id: game.storeID, title: game.title,
                                         steamAppID: game.store == .steam ? nil : info[game.id]?.steamAppID),
                             diagnostics: diagnostics, matched: [problem.ruleID],
                             sommelier: .init(app: reporter.clientVersion, engine: diagnostics.engineVersion, backend: diagnostics.backend))
    }

    /// "Undo": the game counts as working again where it did before.
    func undoStatusDispute(of game: Game) {
        guard var data = library.userData[game.id], data.disputed != nil else { return }
        data.disputed = nil
        library.userData[game.id] = data
        libraryStore.save(library)
        if disputeNotice?.gameID == game.id { disputeNotice = nil }
    }
}

/// The short confirmation in the game page's facts line after a dispute.
struct DisputeNotice: Equatable {
    let gameID: String
    let markRemoved: Bool
    let reportSent: Bool
    let shown = Date()
}
