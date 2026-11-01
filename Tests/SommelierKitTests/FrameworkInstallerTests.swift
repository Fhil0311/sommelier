// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Installing frameworks from stub archives into made-up game folders, against the fixture profiles with their
/// hashes pointed at the stubs.
struct FrameworkInstallerTests {
    /// Hands out archives made for the test by the asset name or page URL the profile names.
    private struct StubDownloader: ModDownloader {
        var archives: [String: URL]

        func download(_ download: ModDownload, into folder: URL) async throws -> URL {
            guard let source = archives[download.asset ?? download.url ?? ""] else { throw FrameworkInstallError.downloadFailed("no stub for \(download)") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
    }

    /// A game folder, a store, the deployer and a launch profile, all in temporary folders.
    private struct Bench {
        let root: URL, game: URL, tools: URL, store: ModStore, deployer: ModDeployer
        var launch = LaunchProfile()

        init(native: Bool = false) {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-frameworks-\(UUID().uuidString)", isDirectory: true)
            game = native ? root.appendingPathComponent("Stardew Valley.app/Contents/MacOS", isDirectory: true) : root.appendingPathComponent("Game", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            tools = support.appendingPathComponent("Tools", isDirectory: true)
            try? FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/test", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: tools, home: support)
            deployer = ModDeployer(roots: roots, store: store)
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

        /// A mod in the store, planned against the profile.
        func stored(_ name: String, _ files: [String: String], profile: ModProfile) throws -> StoredMod {
            let unpacked = root.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
            try FrameworkInstallerTests.layout(files, in: unpacked)
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name)
            try #require(plan.isReady, "\(plan)")
            return try store.add(name: name, plan: plan, unpacked: unpacked)
        }
    }

    static func layout(_ files: [String: String], in root: URL) throws {
        for (path, text) in files {
            let url = URL(fileURLWithPath: root.path + "/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A zip of the layout, made with `tar`, as `name` in a scratch folder of the bench.
    private func archive(_ name: String, _ files: [String: String], in bench: Bench) async throws -> URL {
        let source = bench.root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        try Self.layout(files, in: source)
        let folder = bench.root.appendingPathComponent("archives", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent(name)
        let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", archive.path, "--format", "zip", "-C", source.path, "."])
        try #require(made.succeeded, Comment(rawValue: made.output))
        return archive
    }

    /// A fixture profile with its frameworks' hashes set to the stub archives' (by framework id).
    /// The fixture's entry with the frameworks' hashes pointed at the test's archives, and `settings` edits added
    /// to a framework (by id) when the test exercises a settings file the published entry doesn't write.
    private func profile(_ id: String, hashes: [String: String], settings: [String: [[String: Any]]] = [:]) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        var games = try #require(json["games"] as? [[String: Any]])
        let index = try #require(games.firstIndex { $0["game"] as? String == id })
        var frameworks = try #require(games[index]["frameworks"] as? [[String: Any]])
        for i in frameworks.indices {
            guard let frameworkID = frameworks[i]["id"] as? String else { continue }
            if let edits = settings[frameworkID] { frameworks[i]["settings"] = edits }
            guard let hash = hashes[frameworkID], var download = frameworks[i]["download"] as? [String: Any] else { continue }
            download["sha256"] = hash
            frameworks[i]["download"] = download
        }
        games[index]["frameworks"] = frameworks
        json["games"] = games
        let list = try JSONDecoder().decode(ModsList.self, from: try JSONSerialization.data(withJSONObject: json))
        return try #require(list.profile(covering: id))
    }

    private func sha(_ url: URL) throws -> String { try #require(ModStore.sha256(of: url)) }

    /// Every file and folder below `root` with the files' bytes.
    private func snapshot(_ root: URL) -> [String: Data] {
        var tree: [String: Data] = [:]
        let top = root.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return tree }
        for case let item as URL in walker {
            let relative = String(item.resolvingSymlinksInPath().path.dropFirst(top.count + 1))
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { tree[relative + "/"] = Data() } else { tree[relative] = (try? Data(contentsOf: item)) ?? Data() }
        }
        return tree
    }

    private let ue4ssFiles = ["dwmapi.dll": "proxy", "UE4SS.dll": "ue4ss", "Mods/shared/Types.lua": "types", "Mods/mods.txt": "shared : 1\n", "README.md": "read me",
                              "UE4SS-settings.ini": "[Overrides]\nModsFolderPath =\n\n[EngineVersionOverride]\nMajorVersion = -1\nMinorVersion = -1\n\n[Debug]\nConsoleEnabled = 1\n"]

    @Test func wrongHashInstallsNothing() async throws {
        var bench = Bench()
        try Self.layout(["Phoenix/Binaries/Win64/HogwartsLegacy.exe": "MZ", "Phoenix/Binaries/Win64/xinput1_3.dll": "stale"], in: bench.game)
        let before = snapshot(bench.game)
        let zip = try await archive("UE4SS_v3.0.1.zip", ue4ssFiles, in: bench)
        let downloader = StubDownloader(archives: ["UE4SS_v3.0.1.zip": zip])

        // The fixture's placeholder hash isn't one: nothing is unpacked.
        let unpinned = FrameworkInstaller(profile: try profile("steam:990080", hashes: [:]), deployer: bench.deployer, downloader: downloader)
        await #expect(throws: FrameworkInstallError.noHash("ue4ss")) { try await unpinned.install("ue4ss", launchProfile: &bench.launch) }

        let wrong = String(repeating: "ab", count: 32)
        let installer = FrameworkInstaller(profile: try profile("steam:990080", hashes: ["ue4ss": wrong]), deployer: bench.deployer, downloader: downloader)
        await #expect(throws: FrameworkInstallError.hashMismatch(framework: "ue4ss", expected: wrong, actual: try sha(zip))) {
            try await installer.install("ue4ss", launchProfile: &bench.launch)
        }
        #expect(snapshot(bench.game) == before && !installer.isInstalled("ue4ss") && bench.launch == LaunchProfile())
        #expect(!FileManager.default.fileExists(atPath: bench.store.folder.appendingPathComponent("frameworks").path))
        #expect(bench.deployer.owners().isEmpty)
        await #expect(throws: FrameworkInstallError.unknownFramework("nope")) { try await installer.install("nope", launchProfile: &bench.launch) }
    }

    @Test func ue4ssOverrideComesAndGoesWithTheLastCodeMod() async throws {
        var bench = Bench()
        try Self.layout(["Phoenix/Binaries/Win64/HogwartsLegacy.exe": "MZ", "Phoenix/Binaries/Win64/xinput1_3.dll": "stale loader"], in: bench.game)
        let before = snapshot(bench.game)
        let zip = try await archive("UE4SS_v3.0.1.zip", ue4ssFiles, in: bench)
        let profile = try profile("steam:990080", hashes: ["ue4ss": try sha(zip)])
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["UE4SS_v3.0.1.zip": zip]))

        let installation = try await installer.install("ue4ss", launchProfile: &bench.launch, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(installation.framework == "ue4ss" && installation.alsoInstalled.isEmpty && installation.components.isEmpty && installation.overwroteForeign.isEmpty)
        #expect(installation.placed.sorted() == ["game:Phoenix/Binaries/Win64/Mods/mods.txt", "game:Phoenix/Binaries/Win64/Mods/shared/Types.lua", "game:Phoenix/Binaries/Win64/UE4SS-settings.ini",
                                                 "game:Phoenix/Binaries/Win64/UE4SS.dll", "game:Phoenix/Binaries/Win64/dwmapi.dll"], "the picks, flat, without the readme")
        #expect(bench.text("Phoenix/Binaries/Win64/dwmapi.dll") == "proxy" && !bench.exists("Phoenix/Binaries/Win64/README.md"))
        #expect(!bench.exists("Phoenix/Binaries/Win64/xinput1_3.dll"), "the stale loader is out of the way")
        #expect(bench.launch.dllOverrides == ["dwmapi": "n,b"])
        #expect(installation.fixes.map(\.ruleID) == ["framework:ue4ss"] && installation.fixes.first?.action == .overrideDLL("dwmapi", "n,b"))
        #expect(installation.fixes.first?.undo == .previousDLLOverride("dwmapi", nil))
        let ini = try #require(bench.text("Phoenix/Binaries/Win64/UE4SS-settings.ini"))
        #expect(ini.contains("MajorVersion = 4\nMinorVersion = 27\n") && ini.contains("ConsoleEnabled = 0\nGuiConsoleEnabled = 0\n") && ini.hasPrefix("[Overrides]\nModsFolderPath =\n"))
        #expect(installer.isInstalled("ue4ss") && installer.installed() == ["ue4ss"] && !installer.isInstalled("asiloader"), "the optional loader waits for a mod that needs it")
        #expect(bench.deployer.owners() == ["framework:ue4ss"] && bench.deployer.verify().isEmpty)
        // Again: nothing more happens.
        let again = try await installer.install("ue4ss", launchProfile: &bench.launch)
        #expect(again.placed.isEmpty && again.fixes.isEmpty && bench.launch.dllOverrides == ["dwmapi": "n,b"])

        // A Lua mod keeps the framework; once it is off, the framework has no reason to stay.
        var lua = try bench.stored("Cheats", ["Cheats/Scripts/main.lua": "print()", "Cheats/enabled.txt": ""], profile: profile)
        #expect(lua.frameworks == ["ue4ss"] && lua.containsCode)
        #expect(installer.unneeded(mods: [lua]).isEmpty)
        lua.enabled = false
        #expect(installer.unneeded(mods: [lua]) == ["ue4ss"])
        let pak = try bench.stored("Paks", ["zCool_P.pak": "p", "zCool_P.ucas": "c", "zCool_P.utoc": "t"], profile: profile)
        #expect(installer.unneeded(mods: [lua, pak]) == ["ue4ss"], "a pak mod needs no framework")

        let (removal, undone) = try installer.uninstall("ue4ss", fixes: installation.fixes, launchProfile: &bench.launch)
        #expect(removal.removed.count == 5 && removal.kept.isEmpty && undone == installation.fixes)
        #expect(bench.launch == LaunchProfile(), "the override is gone")
        #expect(snapshot(bench.game) == before, "the game folder is as it was, the stale loader back")
        #expect(!installer.isInstalled("ue4ss") && bench.deployer.owners().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bench.store.folder.appendingPathComponent("frameworks").path))
        #expect(throws: FrameworkInstallError.notInstalled("ue4ss")) { try installer.uninstall("ue4ss", fixes: [], launchProfile: &bench.launch) }
    }

    @Test func smapiRedirectsTheMacVersion() async throws {
        var bench = Bench(native: true)
        try Self.layout(["Stardew Valley": "#!binary", "Stardew Valley.deps.json": "{\"deps\": 1}", "Stardew Valley.dll": "game"], in: bench.game)
        let before = snapshot(bench.game)
        // The installer zip holds the Mac files as an archive of their own.
        let inner = try await archive("install.dat", ["StardewModdingAPI": "#!smapi", "StardewModdingAPI.dll": "smapi", "smapi-internal/SMAPI.Toolkit.dll": "toolkit",
                                                      "Mods/ConsoleCommands/manifest.json": "{\"Name\": \"Console Commands\"}"], in: bench)
        let source = bench.root.appendingPathComponent("smapi-src", isDirectory: true)
        try Self.layout(["README.txt": "read", "internal/windows/install.dat": "windows build"], in: source)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("internal/macOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: inner, to: source.appendingPathComponent("internal/macOS/install.dat"))
        let zip = bench.root.appendingPathComponent("archives/SMAPI-4.5.2-installer.zip")
        let made = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-cf", zip.path, "--format", "zip", "-C", source.path, "."])
        try #require(made.succeeded, Comment(rawValue: made.output))

        // A json settings file SMAPI doesn't ship (`Mods/SMAPI-config.json`), to see one made and taken out again.
        let profile = try profile("steam:413150", hashes: ["smapi": try sha(zip)],
                                  settings: ["smapi": [["file": "game:Mods/SMAPI-config.json", "format": "json", "set": ["CheckForUpdates": true]]]])
        #expect(profile.runtime == .native)
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["SMAPI-4.5.2-installer.zip": zip]))
        let installation = try await installer.install("smapi", launchProfile: &bench.launch)

        #expect(bench.launch.redirect == ExecutableRedirect(instead: "Stardew Valley", run: "StardewModdingAPI"))
        #expect(installation.fixes.map(\.action) == [.runExecutable(instead: "Stardew Valley", run: "StardewModdingAPI")])
        #expect(installation.fixes.first?.undo == .previousExecutable(instead: nil, run: nil))
        #expect(bench.text("StardewModdingAPI") == "#!smapi" && bench.text("smapi-internal/SMAPI.Toolkit.dll") == "toolkit" && bench.exists("Mods/ConsoleCommands/manifest.json"))
        #expect(!bench.exists("install.dat") && !bench.exists("README.txt"), "the installer's own files stay out")
        let mode = (FileScan.attributes(bench.url("StardewModdingAPI"))?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o111 == 0o111, "the Mac program can be run")
        #expect(bench.text("StardewModdingAPI.deps.json") == "{\"deps\": 1}", "the game's deps copied under SMAPI's name")
        let config = try #require(bench.text("Mods/SMAPI-config.json"))
        #expect(config.contains("\"CheckForUpdates\" : true"), "a settings file the framework doesn't ship is made")
        #expect(installation.placed.contains("game:StardewModdingAPI.deps.json") && installation.placed.contains("game:StardewModdingAPI"))
        #expect(bench.deployer.verify().isEmpty)

        try installer.uninstall("smapi", fixes: installation.fixes, launchProfile: &bench.launch)
        #expect(bench.launch.redirect == nil)
        #expect(snapshot(bench.game) == before, "deps copy, config and Mods folder all gone")
    }

    @Test func requiredFrameworksComeFirstAndPagesNeedTheBrowser() async throws {
        var bench = Bench()
        try Self.layout(["RDR2.exe": "MZ"], in: bench.game)
        let hook = try await archive("ScriptHookRDR2_1.0.zip", ["bin/ScriptHookRDR2.dll": "hook", "bin/dinput8.dll": "proxy", "bin/NativeTrainer.asi": "trainer", "readme.txt": "r"], in: bench)
        let lml = try await archive("lml.zip", ["ModLoader/vfs.asi": "vfs", "ModLoader/ModManager.UI.exe": "ui", "ModLoader/lml/mods.xml": "<ModsManager/>"], in: bench)
        let profile = try profile("steam:1174180", hashes: ["scripthookrdr2": try sha(hook), "lml": try sha(lml)])
        let scriptHook = try #require(profile.framework("scripthookrdr2"))
        #expect(scriptHook.download.viaBrowser && URLModDownloader.directURL(of: scriptHook.download) == nil, "an author's page: the app's browser takes it")
        let plain = URLModDownloader()
        await #expect(throws: FrameworkInstallError.needsBrowser(scriptHook.download.url ?? "")) {
            _ = try await plain.download(scriptHook.download, into: bench.root.appendingPathComponent("never"))
        }
        let downloader = StubDownloader(archives: [scriptHook.download.url ?? "": hook, profile.framework("lml")?.download.url ?? "": lml])
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: downloader)

        let installation = try await installer.install("lml", launchProfile: &bench.launch)
        #expect(installation.alsoInstalled == ["scripthookrdr2"] && installer.installed() == ["scripthookrdr2", "lml"])
        #expect(bench.text("ScriptHookRDR2.dll") == "hook" && bench.text("dinput8.dll") == "proxy", "a literal pick places the file by its name")
        #expect(!bench.exists("NativeTrainer.asi") && !bench.exists("bin/dinput8.dll"))
        #expect(bench.text("vfs.asi") == "vfs" && bench.text("lml/mods.xml") == "<ModsManager/>", "the loader's files go next to the game's program, its folder keeps the path from the stripTo folder")
        #expect(!bench.exists("ModManager.UI.exe") && !bench.exists("ModLoader"), "the manager is a program Sommelier never runs")
        #expect(bench.launch.dllOverrides == ["dinput8": "n,b"] && installation.fixes.map(\.ruleID) == ["framework:scripthookrdr2"])

        // Taking the required one out leaves the dependant's files and undoes only its own fix.
        try installer.uninstall("scripthookrdr2", fixes: installation.fixes, launchProfile: &bench.launch)
        #expect(bench.launch.dllOverrides.isEmpty && !bench.exists("dinput8.dll") && bench.exists("vfs.asi") && installer.installed() == ["lml"])
    }

    @Test func me3GoesIntoToolsNotTheGame() async throws {
        var bench = Bench()
        try Self.layout(["Game/eldenring.exe": "MZ"], in: bench.game)
        let before = snapshot(bench.game)
        let zip = try await archive("me3-windows-amd64.zip", ["me3-windows-amd64/bin/me3.exe": "me3", "me3-windows-amd64/bin/me3-launcher.exe": "launcher",
                                                             "me3-windows-amd64/LICENSE-MIT": "mit"], in: bench)
        let profile = try profile("steam:1245620", hashes: ["me3": try sha(zip)])
        let installer = FrameworkInstaller(profile: profile, deployer: bench.deployer, downloader: StubDownloader(archives: ["me3-windows-amd64.zip": zip]))
        let installation = try await installer.install("me3", launchProfile: &bench.launch)

        #expect(installation.placed.sorted() == ["tools:me3/LICENSE-MIT", "tools:me3/bin/me3-launcher.exe", "tools:me3/bin/me3.exe"], "the release's wrapper folder comes off")
        #expect(try String(contentsOf: bench.tools.appendingPathComponent("me3/bin/me3.exe"), encoding: .utf8) == "me3")
        #expect(snapshot(bench.game) == before, "nothing in the game folder")
        #expect(installation.components == [.installVCRuntime] && installation.fixes.isEmpty && bench.launch == LaunchProfile(), "a loader changes no override; the runtime is the app's to install")
        #expect(FrameworkInstaller.launchFixes(of: try #require(profile.framework("me3"))).isEmpty)
    }

    @Test func githubReleaseURLsAndFixReplay() throws {
        let ue4ss = try #require(try profile("steam:990080", hashes: [:]).framework("ue4ss"))
        #expect(URLModDownloader.directURL(of: ue4ss.download)?.absoluteString == "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v3.0.1/UE4SS_v3.0.1.zip", "the hash pins a release, so does the tag")
        let latest = try JSONDecoder().decode(ModDownload.self, from: Data(#"{"kind":"github","repo":"UE4SS-RE/RE-UE4SS","asset":"UE4SS_v3.0.1.zip","sha256":"x"}"#.utf8))
        #expect(URLModDownloader.directURL(of: latest)?.absoluteString == "https://github.com/UE4SS-RE/RE-UE4SS/releases/latest/download/UE4SS_v3.0.1.zip")
        let page = try JSONDecoder().decode(ModDownload.self, from: Data(#"{"kind":"url","url":"https://example.org/tools/","file":"*.zip"}"#.utf8))
        #expect(URLModDownloader.directURL(of: page) == nil, "a page with a file pattern isn't a direct link")
        let direct = try JSONDecoder().decode(ModDownload.self, from: Data(#"{"kind":"url","url":"https://example.org/tools/Loader_1.2.zip","file":"Loader_*.zip"}"#.utf8))
        #expect(URLModDownloader.directURL(of: direct)?.absoluteString == "https://example.org/tools/Loader_1.2.zip")

        // The profile-only fix actions, applied and undone the way Fix Launch does, newest first.
        var launch = LaunchProfile()
        launch.dllOverrides["dinput8"] = "b"
        launch.extraArguments = ["-windowed"]
        let fixes = [FixAction.overrideDLL("dinput8", "n,b"), .overrideDLL("version", "n,b"), .addArguments(["-windowed", "--disable-ue4ss"]),
                     .runExecutable(instead: "Launcher.exe", run: "Game.exe"), .installVCRuntime]
            .enumerated().compactMap { FrameworkInstaller.apply($0.element, to: &launch, ruleID: "framework:x", now: Date(timeIntervalSince1970: Double($0.offset))) }
        #expect(fixes.count == 4, "a component install isn't a profile change")
        #expect(launch.dllOverrides == ["dinput8": "n,b", "version": "n,b"] && launch.extraArguments == ["-windowed", "--disable-ue4ss"] && launch.redirect?.run == "Game.exe")
        FrameworkInstaller.undo(fixes, in: &launch)
        #expect(launch.dllOverrides == ["dinput8": "b"] && launch.extraArguments == ["-windowed"] && launch.redirect == nil)
        #expect(FrameworkInstaller.apply(.overrideDLL("x", "evil"), to: &launch, ruleID: "r") == nil, "only the known override modes")
    }

    @Test func settingsEditorsKeepWhatTheyDontTouch() throws {
        let ini = ModSettings.ini("; UE4SS\r\n[Overrides]\r\nModsFolderPath=\r\n\r\n[EngineVersionOverride]\r\nMajorVersion=-1\r\nminorversion = -1\r\n",
                                  set: ["EngineVersionOverride": .object(["MajorVersion": .string("4"), "MinorVersion": .number(27)]), "Debug": .object(["ConsoleEnabled": .bool(false)])])
        #expect(ini == "; UE4SS\r\n[Overrides]\r\nModsFolderPath=\r\n\r\n[EngineVersionOverride]\r\nMajorVersion=4\r\nminorversion = 27\r\n\r\n[Debug]\r\nConsoleEnabled = false\r\n")
        #expect(ModSettings.ini("", set: ["Top": .string("1")]) == "Top = 1\n")
        #expect(ModSettings.keyValue("# re\nLooseFileLoader_Enabled=false\nOther=1\n", set: ["LooseFileLoader_Enabled": .string("true"), "New": .number(2)])
                == "# re\nLooseFileLoader_Enabled=true\nOther=1\nNew=2\n")
        let json = try ModSettings.json(Data(#"{"CheckForUpdates": false, "Nested": {"Keep": 1, "Set": 1}, "Other": "x"}"#.utf8),
                                        set: ["CheckForUpdates": .bool(true), "Nested": .object(["Set": .number(2)])])
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["CheckForUpdates"] as? Bool == true && object["Other"] as? String == "x")
        #expect((object["Nested"] as? [String: Any])?["Keep"] as? Int == 1 && (object["Nested"] as? [String: Any])?["Set"] as? Int == 2)
        #expect(try JSONSerialization.jsonObject(with: ModSettings.json(Data("garbage".utf8), set: ["A": .string("b")])) as? [String: String] == ["A": "b"])
    }
}
