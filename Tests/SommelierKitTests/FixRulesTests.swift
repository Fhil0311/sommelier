// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct FixRulesTests {
    static func diagnostics(_ log: String, steam: String? = nil) -> LaunchDiagnostics {
        LaunchDiagnostics(gameID: "steam:1", title: "G", store: "steam", logTail: log, steamLogTail: steam)
    }
    static let wine = FixContext(backend: .wined3d, store: .steam, native: false, d3dMetalReady: false,
                                 facts: GameFacts(launcher: .ea, antiCheat: true, epicOnlineServices: true))

    @Test func recognisesWhatWeHaveSeen() {
        // The EA installer without .NET (NFS Most Wanted), and Steam failing to hand the game to the EA app.
        #expect(FixRules.match(Self.diagnostics("Execution halted, action L\"JunoInitializeSession\" returned 1603"), context: Self.wine).first?.id == "dotnet")
        #expect(FixRules.match(Self.diagnostics("", steam: "Failed running GameID 1262560: \"steam2ea://launchgame/1262560\" (OS Error 2)"), context: Self.wine).first?.id == "ea-app-missing")
        #expect(FixRules.match(Self.diagnostics("err:module:import_dll Library mfc140u.dll (which is needed by L\"C:\\\\game\\\\plugin.dll\") not found"), context: Self.wine).first?.action == .installVCRuntime)
        #expect(FixRules.match(Self.diagnostics("Unhandled exception: page fault in 32-bit code ... IGO32.dll"), context: Self.wine).first?.action == .disableEAOverlay)
        #expect(FixRules.match(Self.diagnostics("err:d3d:wined3d_adapter_init failed"), context: Self.wine).first?.action == .switchGraphics(.dxmt))
    }

    @Test func conditionsAndAppliedRulesNarrowIt() {
        let dxmt = FixContext(backend: .dxmt, store: .steam, native: false, d3dMetalReady: false)
        #expect(FixRules.match(Self.diagnostics("err:d3d:something"), context: dxmt).isEmpty)        // already on DXMT
        #expect(FixRules.match(Self.diagnostics("winemetal: fatal error in command buffer"), context: dxmt).first?.action == .switchGraphics(.wined3d))
        let ready = FixContext(backend: .wined3d, store: .steam, native: false, d3dMetalReady: true)
        #expect(FixRules.match(Self.diagnostics("D3D12CreateDevice failed"), context: ready).isEmpty)
        var applied = Self.wine; applied.appliedRuleIDs = ["dotnet"]
        #expect(FixRules.match(Self.diagnostics("returned 1603"), context: applied).isEmpty)
        let native = FixContext(backend: .auto, store: .epic, native: true, d3dMetalReady: false)
        #expect(FixRules.match(Self.diagnostics("Bad CPU type in executable"), context: native).first?.id == "mac-32bit")
        #expect(FixRules.match(Self.diagnostics("import_dll Library foo.dll"), context: native).isEmpty)   // Wine rules don't apply to Mac apps
    }

    @Test func steamsOwnMissingLibraryIsNotTheGames() {
        let steam = "0240:err:module:import_dll Library SDL2.dll (which is needed by L\"C:\\\\Program Files (x86)\\\\Steam\\\\bin\\\\gldriverquery.exe\") not found"
        #expect(FixRules.match(Self.diagnostics(steam), context: Self.wine).isEmpty)
        let game = "0240:err:module:import_dll Library xinput1_3.dll (which is needed by L\"C:\\\\Games\\\\x\\\\game.exe\") not found"
        #expect(FixRules.match(Self.diagnostics(game), context: Self.wine).first?.id == "missing-dll")
    }

    @Test func anotherGamesLinesAreNotThisGamesEvidence() {
        // Steam's session log, started by an EA game: its overlay lines, then Raft's own.
        let shared = """
        0540:0024:err:module:import_dll Library IGO32.dll (which is needed by L"C:\\EA\\NFS13.exe") not found
        0024:err:seh:old line without a process
        0554:0030:err:module:import_dll Library mfc140u.dll (which is needed by L"C:\\Raft\\Raft.exe") not found
        info: Turbo: MetalFX swap chain 1440x900 -> 2880x1800
        """
        let own = LaunchEvidence.ownLines(shared, processIDs: [0x554])
        #expect(!own.contains("IGO32") && !own.contains("old line") && own.contains("mfc140u") && own.contains("Turbo: MetalFX"))

        let steam = """
        [2026-10-21 20:35:51] Game process added : AppID 1262560 ""steam2ea://launchgame/1262560"", ProcID 1344
        [2026-10-22 20:20:02] Game process added : AppID 648800 ""C:\\Raft\\Raft.exe"", ProcID 1364
        [2026-10-22 20:20:04] AppID 648800 adding PID 1380 as a tracked process ""C:\\Raft\\Raft.exe""
        """
        let since = LaunchEvidence.stamp.date(from: "2026-10-22 20:20:00")!
        #expect(LaunchEvidence.steamProcessIDs(appID: "648800", logs: [steam], since: since) == [1364, 1380])
        #expect(LaunchEvidence.appLines(steam, appID: "1262560", since: since).isEmpty)        // yesterday's, another game

        // Even if EA lines get through, the EA rules need an EA game.
        let d = Self.diagnostics("0540:0024:err:x IGO32.dll", steam: "steam2ea://launchgame/1262560")
        let raft = FixContext(gameID: "steam:648800", backend: .dxmt, store: .steam, native: false, d3dMetalReady: true, facts: GameFacts(engine: .unity))
        #expect(!FixRules.match(d, context: raft).contains { $0.id == "ea-overlay" || $0.id == "ea-app-missing" })
        let nfs = FixContext(gameID: "steam:1262560", backend: .dxmt, store: .steam, native: false, d3dMetalReady: true, facts: GameFacts(launcher: .ea))
        #expect(FixRules.match(d, context: nfs).map(\.id).contains("ea-overlay"))
        #expect(FixRules.match(Self.diagnostics("EasyAntiCheat failed"), context: raft).isEmpty)
    }

    @Test func needsComeFromWhatTheProgramsImport() {
        var facts = GameFacts()
        facts.read(imports: ["kernel32.dll", "mscoree.dll"])
        #expect(facts.dotNet && !facts.visualCpp)
        facts.read(imports: ["mfc140u.dll", "d3dx9_43.dll", "physxloader.dll"])
        #expect(facts.visualCpp && facts.directXRuntime && facts.physX)
        var plain = GameFacts(); plain.read(imports: ["kernel32.dll", "d3d11.dll", "xinput1_3.dll", "msvcp140.dll", "vcruntime140.dll", "xaudio2_9redist.dll", "xaudio2_9.dll"]); plain.read(imports: ["mscoree.dll"], program: false)
        #expect(plain == GameFacts())
    }

    @Test func theCrashReportOutweighsTheLog() {
        var d = Self.diagnostics("0554:0030:err:module:import_dll Library foo.dll (which is needed by L\"C:\\\\g\\\\g.exe\") not found")
        d.crashReport = "Thread 0 Crashed: winemetal.so dxmt fatal error"
        let dxmt = FixContext(backend: .dxmt, store: .epic, native: false, d3dMetalReady: true, facts: GameFacts())
        let ranked = FixRules.ranked(d, context: dxmt)
        #expect(ranked.map(\.rule.id) == ["dxmt-fail", "missing-dll"])
        #expect(ranked.first?.evidence.contains("winemetal") == true && ranked.first?.weight == 3)
    }

    @Test func factsComeFromTheGamesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ paths: [String]) throws -> URL {
            let g = root.appendingPathComponent(UUID().uuidString)
            for p in paths {
                let url = g.appendingPathComponent(p)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            }
            return g
        }
        #expect(GameFacts.scan(try make(["__Installer/Origin/redist/internal/EAappInstaller.exe", "NFS13.exe"]), store: .steam).launcher == .ea)
        #expect(GameFacts.scan(try make(["bin/uplay_r1_loader64.dll", "EasyAntiCheat/x.sys"]), store: .steam) == GameFacts(launcher: .ubisoft, antiCheat: true))
        #expect(GameFacts.scan(try make(["Raft.exe", "UnityPlayer.dll"]), store: .steam).engine == .unity)
        #expect(GameFacts.scan(try make(["G/Binaries/Win64/G-Win64-Shipping.exe", "G/Content/Paks/a.pak", "EOSSDK-Win64-Shipping.dll"]), store: .epic)
                == GameFacts(engine: .unreal, epicOnlineServices: true))
    }

    @Test func explainsWhatCantBeFixedYet() {
        #expect(FixRules.match(Self.diagnostics("Unhandled exception: page fault on read access in 64-bit code ... EOSOVH-Win64-Shipping.dll"), context: Self.wine).first?.id == "eos-overlay")
        #expect(FixRules.match(Self.diagnostics("0024:err:mfplat:MFCreateSourceResolver stub"), context: Self.wine).first?.id == "video-playback")
        #expect(FixRules.match(Self.diagnostics("This game requires a CPU with AVX support"), context: Self.wine).first?.id == "cpu-features")
        #expect(FixRules.match(Self.diagnostics("Unsupported CPU detected"), context: Self.wine).first?.id == "cpu-features")
    }

    @Test func unknownLogsMatchNothing() {
        #expect(FixRules.match(Self.diagnostics("[Sommelier] Launch\n[Sommelier] Exit status=0"), context: Self.wine).isEmpty)
        for rule in FixRules.builtIn { for p in rule.patterns { #expect((try? NSRegularExpression(pattern: p)) != nil, "bad pattern in \(rule.id)") } }
    }

    @Test func remoteRulesReplaceBuiltInOnes() {
        let remote = [FixRule(id: "dotnet", cause: "new words", patterns: ["x"], action: .installDotNet), FixRule(id: "new", cause: "n", patterns: ["y"])]
        let merged = FixRules.merged(remote: remote)
        #expect(merged.first?.id == "dotnet" && merged.first?.cause == "new words")
        #expect(merged.filter { $0.id == "dotnet" }.count == 1 && merged.contains { $0.id == "new" })
    }

    @Test func scrubbingHidesTheUser() {
        let text = #"/Users/rowan/Games/x C:\users\rowan\AppData 76561190000000001 "AccountName"  "rowan_k" -AUTH_PASSWORD=abc123 Z:\Users\rowan\y"#
        let out = DiagnosticsCollector.scrub(text)
        #expect(!out.contains("rowan"))
        #expect(!out.contains("76561190000000001") && !out.contains("abc123"))
        #expect(out.contains("/Users/…/Games/x") && out.contains("<steamid>"))
    }

    @Test func appliedFixesRoundTripInUserData() throws {
        var data = UserGameData()
        data.appliedFixes = [AppliedFix(ruleID: "d3d11-fail", action: .switchGraphics(.dxmt), undo: .previousBackend(.wined3d))]
        let decoded = try JSONDecoder().decode(UserGameData.self, from: JSONEncoder().encode(data))
        #expect(decoded.appliedFixes?.first?.undo == .previousBackend(.wined3d))
        #expect(try JSONDecoder().decode(UserGameData.self, from: Data(#"{"profile":{},"playTime":0}"#.utf8)).appliedFixes == nil)
    }
}

/// Runs the rules over real logs on this Mac (`SOMMELIER_REAL_LOGS=<Sommelier home>`): what each game's last
/// launch would be told, with the text that matched. For looking at false matches, not for CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_REAL_LOGS"] != nil))
struct FixRulesRealLogs {
    @Test func whatEachGameWouldBeTold() throws {
        let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMMELIER_REAL_LOGS"]!)
        let logs = home.appendingPathComponent("Logs")
        let content = home.appendingPathComponent("Bottles/steam/drive_c/Program Files (x86)/Steam/logs/content_log.txt")
        let steamTail = DiagnosticsCollector.tail(of: content, bytes: 32 * 1024)
        let fm = FileManager.default
        let steamLogs = ((try? fm.contentsOfDirectory(at: logs.appendingPathComponent("steam"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        // The biggest Steam session log: the one a launch would share with the most other programs.
        let biggest = steamLogs.max { ((try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) < ((try? fm.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
        let launcher = biggest.map { DiagnosticsCollector.tail(of: $0) } ?? ""
        for folder in (try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)) ?? [] where folder.lastPathComponent.contains("-") {
            for last in ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter({ $0.pathExtension == "log" }) {
            let id = folder.lastPathComponent.replacingOccurrences(of: "-", with: ":", options: [], range: folder.lastPathComponent.range(of: "-"))
            let store = String(id.split(separator: ":")[0])
            var d = LaunchDiagnostics(gameID: id, title: id, store: store, logTail: DiagnosticsCollector.tail(of: last))
            if store == "steam" { d.launcherLogTail = launcher; d.steamLogTail = steamTail }
            for backend in [GraphicsBackend.dxmt, .d3dMetal] {
                let context = FixContext(gameID: id, backend: backend, store: StoreKind(rawValue: store) ?? .steam, native: false, d3dMetalReady: true)
                let matched = FixRules.match(d, context: context)
                let why = matched.map { rule -> String in
                    let text = d.searchableText
                    let hit = rule.patterns.compactMap { p -> String? in
                        guard let r = try? NSRegularExpression(pattern: p), let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                              let range = Range(m.range, in: text) else { return nil }
                        let line = text[text.lineRange(for: range)].trimmingCharacters(in: .whitespacesAndNewlines)
                        let source = d.logTail.contains(line) ? "game" : (d.launcherLogTail?.contains(line) == true ? "launcher" : "steam")
                        return "[\(source)] " + String(line.prefix(110))
                    }.first ?? ""
                    return "\(rule.id): \(hit)"
                }
                if !why.isEmpty { print("RULES \(id) \(last.lastPathComponent) \(backend.rawValue): " + why.joined(separator: " | ")) }
            }
            }
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SOMMELIER_FACTS_ROOT"] != nil))
struct GameFactsRealFolders {
    @Test func whatEachInstalledGameIs() {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOMMELIER_FACTS_ROOT"]!)
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            print("FACTS \(folder.lastPathComponent): \(GameFacts.scan(folder, store: .steam))")
            if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
                for case let url as URL in walker where ["exe", "dll"].contains(url.pathExtension.lowercased()) {
                    guard let image = PEImage(url: url) else { continue }
                    var one = GameFacts(); one.read(imports: image.imports, program: url.pathExtension.lowercased() == "exe")
                    if one.directXRuntime || one.visualCpp && folder.lastPathComponent == "Raft" {
                        print("  WHY \(url.lastPathComponent): \(image.imports.filter { $0.hasPrefix("d3dx") || $0.hasPrefix("xaudio") || $0.hasPrefix("x3daudio") || $0.hasPrefix("xact") || $0.hasPrefix("msvc") || $0.hasPrefix("vcruntime") }.sorted())")
                    }
                }
            }
        }
    }
}
