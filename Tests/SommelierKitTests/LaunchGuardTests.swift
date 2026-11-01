// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Which way a modded game starts, by the fixture profiles' online policies, and what is cleared before a launch
/// without mods.
struct LaunchGuardTests {
    private struct Bench {
        let root: URL, game: URL, tools: URL, store: ModStore, roots: ModRoots

        init() {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-guard-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("Game", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            tools = support.appendingPathComponent("Tools", isDirectory: true)
            try? FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/test", isDirectory: true))
            roots = ModRoots(game: game, store: store.folder, tools: tools, home: support)
        }

        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: game.path + "/" + relative) }
    }

    private func profile(_ id: String) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
        return try #require(list.profile(covering: id))
    }

    @Test func offlineOnlyWithAnEnabledModRefusesThePlainLaunch() throws {
        let bench = Bench()
        let elden = LaunchGuard(profile: try profile("steam:1245620"), roots: bench.roots)
        #expect(!elden.allowsPlainLaunch(modsEnabled: true) && elden.allowsPlainLaunch(modsEnabled: false))
        #expect(elden.loaderFramework?.id == "me3")
        #expect(throws: LaunchGuard.Refusal.loaderRequired(framework: "me3")) { try elden.decide(modsEnabled: true, installed: []) }
        // Installed by the record but the program isn't there: still no plain launch.
        #expect(throws: LaunchGuard.Refusal.loaderMissing("me3")) { try elden.decide(modsEnabled: true, installed: ["me3"]) }
        #expect(try elden.decide(modsEnabled: false, installed: []) == .plain(leftovers: []), "no mods on: the usual path, nothing to clear")

        // A game that allows online with mods starts the usual way, mods or not; the policy never names an engine.
        let hogwarts = LaunchGuard(profile: try profile("steam:990080"), roots: bench.roots)
        #expect(hogwarts.allowsPlainLaunch(modsEnabled: true) && hogwarts.loaderFramework == nil)
        #expect(try hogwarts.decide(modsEnabled: true, installed: ["ue4ss"]) == .plain(leftovers: []))
        #expect(try hogwarts.decide(modsEnabled: false, installed: []) == .plain(leftovers: []))
        let rdr2 = LaunchGuard(profile: try profile("steam:1174180"), roots: bench.roots)
        #expect(rdr2.allowsPlainLaunch(modsEnabled: true), "story only is a notice, not a refusal")
        #expect(try rdr2.decide(modsEnabled: true, installed: ["scripthookrdr2"]) == .plain(leftovers: []))
    }

    @Test func loaderCommandComesFromTheProfile() throws {
        let bench = Bench()
        let me3 = bench.tools.appendingPathComponent("me3/bin/me3.exe")
        try FileManager.default.createDirectory(at: me3.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("me3".utf8).write(to: me3)
        try FileManager.default.createDirectory(at: bench.game.appendingPathComponent("Game"), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: bench.game.appendingPathComponent("Game/eldenring.exe"))
        let guardian = LaunchGuard(profile: try profile("steam:1245620"), roots: bench.roots)

        guard case .loader(let command) = try guardian.decide(modsEnabled: true, installed: ["me3"]) else { Issue.record("not the loader"); return }
        #expect(command.framework == "me3" && command.executable == me3 && command.workingDirectory == me3.deletingLastPathComponent() && command.steamInBottle)
        let gamePath = "Z:" + bench.game.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
        let configPath = "Z:" + bench.store.folder.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\") + "\\sommelier.me3"
        #expect(command.arguments == ["launch", "--skip-steam-init", "--exe-path", gamePath + "\\Game\\eldenring.exe", "-p", configPath])
        #expect(command.config == bench.store.folder.appendingPathComponent("sommelier.me3"))

        // The app's own idea of the game's program, and of how the bottle sees a path, win over the defaults.
        let known = try guardian.loaderCommand(try #require(guardian.loaderFramework), gameExe: bench.game.appendingPathComponent("Game/start_protected_game.exe")) { "C:\\mapped\\" + $0.lastPathComponent }
        #expect(known.arguments == ["launch", "--skip-steam-init", "--exe-path", "C:\\mapped\\start_protected_game.exe", "-p", "C:\\mapped\\sommelier.me3"])

        #expect(LaunchGuard.expand("{gameExe:Game/x.exe}|{config}|{other}|plain") { name, fallback in
            switch name {
            case "gameExe": "G(\(fallback ?? ""))"
            case "config": "C"
            default: nil
            }
        } == "G(Game/x.exe)|C|{other}|plain")
        #expect(LaunchGuard.winePath(URL(fileURLWithPath: "/Users/me/Games/Elden Ring")) == "Z:\\Users\\me\\Games\\Elden Ring")
    }

    @Test func leftoversInTheGameFolderAreFoundAndMovedAside() throws {
        let bench = Bench()
        try FrameworkInstallerTests.layout(["Game/eldenring.exe": "MZ", "Game/dinput8.dll": "mod engine", "Game/steam_appid.txt": "1245620",
                                            "Game/mods/Convergence/regulation.bin": "reg", "Game/SeamlessCoop/ersc.dll": "coop"], in: bench.game)
        let guardian = LaunchGuard(profile: try profile("steam:1245620"), roots: bench.roots)
        let found = ["game:Game/dinput8.dll", "game:Game/SeamlessCoop/", "game:Game/steam_appid.txt", "game:Game/mods/"]
        #expect(guardian.leftovers() == found, "in the profile's order; the folders as folders")
        #expect(try guardian.decide(modsEnabled: false, installed: ["me3"]) == .plain(leftovers: found))

        let fix = FixAction.removeModLeftovers(found)
        #expect(!fix.isUndoable && fix.summary == "Remove leftover mod files")
        let decoded = try JSONDecoder().decode(FixAction.self, from: try JSONEncoder().encode(fix))
        #expect(decoded == fix)

        let moved = try LaunchGuard.removeLeftovers(found, roots: bench.roots, store: bench.store, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(moved == found)
        #expect(bench.exists("Game/eldenring.exe") && !bench.exists("Game/dinput8.dll") && !bench.exists("Game/mods") && !bench.exists("Game/SeamlessCoop") && !bench.exists("Game/steam_appid.txt"))
        let bin = bench.store.folder.appendingPathComponent(".leftovers")
        let stamps = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        #expect(stamps.count == 1)
        let kept = bin.appendingPathComponent(stamps[0])
        #expect(try String(contentsOf: kept.appendingPathComponent("game/Game/dinput8.dll"), encoding: .utf8) == "mod engine")
        #expect(try String(contentsOf: kept.appendingPathComponent("game/Game/mods/Convergence/regulation.bin"), encoding: .utf8) == "reg", "nothing is deleted")
        #expect(guardian.leftovers().isEmpty)
        #expect(try LaunchGuard.removeLeftovers(found, roots: bench.roots, store: bench.store).isEmpty)
    }

    @Test func playWithoutModsTellsOursFromTheirs() throws {
        let bench = Bench()
        try FrameworkInstallerTests.layout(["RDR2.exe": "MZ", "version.dll": "someone's asi loader", "lml/mods.xml": "<ModsManager/>", "Other.asi": "theirs"], in: bench.game)
        let deployer = ModDeployer(roots: bench.roots, store: bench.store)
        let staged = bench.store.folder.appendingPathComponent("frameworks/scripthookrdr2/files/game", isDirectory: true)
        try FrameworkInstallerTests.layout(["dinput8.dll": "hook proxy", "Rampage.asi": "ours"], in: staged)
        try deployer.deploy(owner: "framework:scripthookrdr2", [.init(from: staged.appendingPathComponent("dinput8.dll"), to: "game:dinput8.dll"),
                                                                 .init(from: staged.appendingPathComponent("Rampage.asi"), to: "game:Rampage.asi")])
        let guardian = LaunchGuard(profile: try profile("steam:1174180"), roots: bench.roots)
        let targets = guardian.playWithoutModsTargets(deployer: deployer)
        #expect(targets.ours == ["game:dinput8.dll", "game:Rampage.asi"], "the deployer takes its own out")
        #expect(targets.foreign == ["game:version.dll", "game:Other.asi", "game:lml/"], "a `*` names each file it matches")
        #expect(guardian.leftovers(["game:*.asi"], deployer: deployer) == ["game:Other.asi"])
        // Moving leftovers aside never touches what the deployer placed.
        #expect(try LaunchGuard.removeLeftovers(["game:dinput8.dll", "game:version.dll"], roots: bench.roots, store: bench.store, deployer: deployer) == ["game:version.dll"])
        #expect(bench.exists("dinput8.dll") && !bench.exists("version.dll"))
    }

    @Test func separateSaveFollowsTheProfileUnlessThePlayerChose() throws {
        let bench = Bench()
        let elden = LaunchGuard(profile: try profile("steam:1245620"), roots: bench.roots)
        #expect(elden.usesSeparateSave() && !elden.usesSeparateSave(playerChoice: false) && elden.separateSaveFile == "ER0000_sommelier.sl2")
        let hogwarts = LaunchGuard(profile: try profile("steam:990080"), roots: bench.roots)
        #expect(!hogwarts.usesSeparateSave(playerChoice: true) && hogwarts.separateSaveFile == nil, "no loader, no save of its own")
    }
}
