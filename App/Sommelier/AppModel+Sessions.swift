// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit

/// Play sessions survive Sommelier quitting, crashing or restarting for an update in the middle of a game: the
/// games being played are kept in `ActiveSessions.json`, and on the next start Sommelier follows the ones still
/// running and records the ones that ended meanwhile (up to the last moment it saw them).
extension AppModel {
    func resumeSessions() async {
        let store = ActiveSessionStore(paths: paths)
        let engines = paths.engines.path
        for session in store.load() {
            let game = library.games.first { $0.id == session.gameID }
            let pid = await Task.detached { game.flatMap { Self.runningProcess(of: $0, enginesFolder: engines) } }.value
            switch session.recovery(isRunning: pid != nil, gameKnown: game != nil) {
            case .resume(let since):
                guard let game, gameStates[game.id] == nil else { continue }
                gameStates[game.id] = .playing(since: since)
                Task { await followResumed(game, since: since) }
            case .record(let start, let end):
                guard let game else { continue }
                record(game, start: start, end: end)
                if game.store == .epic || game.store == .gog { Task { await syncSavesAfterPlay(game) } }
            case .drop:
                store.remove(gameID: session.gameID)
            }
        }
        keepSessions()
        yieldToWineApps()
        adoptRunningGames()
    }

    /// A game running that Sommelier isn't following: started from Steam itself or the Dock, or one that quit and
    /// started again after its session ended (some games restart themselves). Every 5 seconds the installed
    /// Windows games are checked for a process from their folder; one found becomes a session followed as a
    /// resumed one, so "In game" and the play time are right.
    private func adoptRunningGames() {
        let engines = paths.engines.path
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let candidates = self.library.games.filter { $0.isInstalled && !$0.isNative && self.gameStates[$0.id] == nil }
                guard !candidates.isEmpty else { continue }
                let running = await Task.detached {
                    let programs = WineWindows.programs(enginesFolder: engines).map { $0.commandLine.lowercased() }
                    return candidates.filter { game in
                        guard let name = game.installPath?.lastPathComponent.lowercased(), !name.isEmpty else { return false }
                        return programs.contains { $0.contains("\\\(name)\\") || $0.contains("/\(name)/") }
                    }
                }.value
                for game in running where self.gameStates[game.id] == nil {
                    let since = Date()
                    self.gameStates[game.id] = .playing(since: since)
                    Task { await self.followResumed(game, since: since) }
                }
            }
        }
    }

    /// The game's process, if it runs: by its executable's folder for a Mac version, by its command line for a
    /// Windows game.
    nonisolated static func runningProcess(of game: Game, enginesFolder: String) -> Int32? {
        guard let folder = game.installPath else { return nil }
        if game.isNative { return NativeProcesses.pid(runningFrom: folder) }
        return WineWindows.gameProcess(enginesFolder: enginesFolder, folderName: folder.lastPathComponent)
    }

    /// Follows a game found running at start-up until its process is gone, then records the whole session.
    private func followResumed(_ game: Game, since: Date) async {
        let engines = paths.engines.path
        var gone = 0
        while gameStates[game.id] != nil {
            try? await Task.sleep(for: .seconds(2))
            let pid = await Task.detached { Self.runningProcess(of: game, enginesFolder: engines) }.value
            gone = pid == nil ? gone + 1 : 0
            if gone >= 3 { break }                     // gone for a few seconds: it quit (not a hand-over between processes)
        }
        gameStates[game.id] = nil
        record(game, start: since, end: Date())
        if game.store == .epic || game.store == .gog { await syncSavesAfterPlay(game) }
    }

    /// A game's window asks for the front through Wine's own handshake (the Mac driver posts
    /// "WineAppWillActivateNotification" and then activates itself). macOS only lets an app come forward when the
    /// active one yields, so Sommelier yields when it is the active app: otherwise a game launched from Sommelier
    /// stays under the menu bar and the Dock until Cmd-Tab.
    func yieldToWineApps() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("WineAppWillActivateNotification"),
                                                            object: nil, queue: .main) { note in
            guard NSApp.isActive, let pid = (note.userInfo?["ActivatingAppPID"] as? NSNumber)?.int32Value,
                  let app = NSRunningApplication(processIdentifier: pid) else { return }
            NSApp.yieldActivation(to: app)
        }
    }

    /// Keeps `ActiveSessions.json` in step with the games being played: every 15 seconds, and when Sommelier quits.
    private func keepSessions() {
        let store = ActiveSessionStore(paths: paths)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSessions(store) }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                self?.saveSessions(store)
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func saveSessions(_ store: ActiveSessionStore) {
        var playing: Set<String> = []
        for (id, state) in gameStates {
            guard case .playing(let since) = state else { continue }
            playing.insert(id)
            store.update(gameID: id, start: since)
        }
        for session in store.load() where !playing.contains(session.gameID) { store.remove(gameID: session.gameID) }
    }
}
