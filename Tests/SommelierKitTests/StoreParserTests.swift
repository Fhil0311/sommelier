// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// A fresh, not yet created folder in the temporary directory. Callers remove it when done.
private func scratchFolder(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-\(tag)-\(UUID().uuidString)", isDirectory: true)
}

private func makeFolder(_ folder: URL) throws {
    try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true, attributes: nil)
}

/// Removes a scratch folder and everything in it; a folder that is already gone is fine.
private func discard(_ folder: URL) { try? FileManager.default.removeItem(atPath: folder.path) }

private func json(_ text: String) -> Data { Data(text.utf8) }

// MARK: - GOG

@Suite("GOG answers")
struct GOGAnswerTests {
    @Test func libraryPageKeepsOnlyWindowsGames() throws {
        let page = json(#"""
        {"totalPages":3,"products":[
          {"id":1453375253,"title":"Heroes of Might and Magic 3","isGame":true,"worksOn":{"Windows":true,"Mac":true}},
          {"id":10,"title":"Soundtrack","isGame":false,"worksOn":{"Windows":true}},
          {"id":11,"title":"Linux Port","isGame":true,"worksOn":{"Windows":false,"Linux":true}},
          {"id":12,"title":"Unlabelled","isGame":true}]}
        """#)
        let parsed = try GOGParser.products(page)
        #expect(parsed.totalPages == 3)
        #expect(parsed.games.map(\.id) == ["1453375253", "12"])
        #expect(parsed.games.map(\.mac) == [true, false])
        #expect(parsed.games.first?.title == "Heroes of Might and Magic 3")
    }

    @Test func singlePageLibraryHasOnePage() throws {
        let parsed = try GOGParser.products(json(#"{"products":[]}"#))
        #expect(parsed.totalPages == 1 && parsed.games.isEmpty)
        #expect(throws: (any Error).self) { try GOGParser.products(json("[]")) }
    }

    @Test func artworkTemplatesBecomeJPEGLinks() {
        let release = json(#"""
        {"game":{"vertical_cover":{"url_format":"https://images.gog.test/cover{formatter}.{ext}"},
                 "logo":{"url_format":"https://images.gog.test/logo{formatter}.{ext}?v=2"}}}
        """#)
        let art = GOGParser.artwork(release)
        #expect(art.cover == URL(string: "https://images.gog.test/cover.jpg"))
        #expect(art.logo == URL(string: "https://images.gog.test/logo.jpg?v=2"))
        #expect(art.background == nil)
        #expect(GOGParser.artwork(json("not json")) == GOGParser.Artwork())
    }

    @Test func artworkCacheKeepsItsKeys() throws {
        let art = GOGParser.Artwork(cover: URL(string: "https://a.test/c.jpg"), background: nil, logo: nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(art)) as? [String: Any]
        #expect(encoded?["cover"] as? String == "https://a.test/c.jpg")
    }

    @Test func tokenAnswers() {
        #expect(GOGParser.credentials(json(#"{"access_token":"abc","user_id":"42","expires_in":3600}"#))?.accessToken == "abc")
        #expect(GOGParser.credentials(json(#"{"access_token":"abc","error":true}"#)) == nil)
        #expect(GOGParser.credentials(json(#"{"user_id":"42"}"#)) == nil)
        #expect(GOGParser.credentials(json("")) == nil)
    }

    @Test func downloadProgress() {
        #expect(GOGParser.progress(from: "[PROGRESS] INFO: = Progress: 7.25 1/2, Running for 00:01:00, ETA: 00:12:00") == 0.0725)
        #expect(GOGParser.progress(from: "= Progress: 100.00 9/9") == 1)
        #expect(GOGParser.progress(from: "[PROGRESS] INFO: = Download speed: 3.2 MiB/s") == nil)
        #expect(GOGParser.progress(from: "= Progress: n/a") == nil)
    }

    @Test func primaryFileTaskStartsTheGame() {
        let info = json(#"""
        {"playTasks":[
          {"type":"URLTask","isPrimary":true,"link":"https://support.example"},
          {"category":"document","type":"FileTask","path":"Manual.pdf"},
          {"isPrimary":true,"type":"FileTask","path":"bin\\Game.exe","workingDir":"bin","arguments":"-nointro \"save slot\""}]}
        """#)
        let task = GOGParser.playTask(infoJSON: info)
        #expect(task == GOGParser.PlayTask(path: #"bin\Game.exe"#, arguments: ["-nointro", "save slot"], workingDirectory: "bin"))
    }

    @Test func withoutPrimaryTheFirstFileTaskIsUsed() {
        let info = json(#"{"playTasks":[{"path":"Run.exe","workingDir":""},{"type":"FileTask","path":"Other.exe"}]}"#)
        #expect(GOGParser.playTask(infoJSON: info) == GOGParser.PlayTask(path: "Run.exe", arguments: [], workingDirectory: nil))
        #expect(GOGParser.playTask(infoJSON: json(#"{"playTasks":[]}"#)) == nil)
        #expect(GOGParser.playTask(infoJSON: json(#"{"gameId":"1"}"#)) == nil)
    }

    /// Mafia: Definitive Edition: the primary task is a .NET launcher that can't run without Mono.
    @Test func launcherTaskGivesWayToTheGame() {
        let info = json(#"""
        {"playTasks":[
          {"category": "launcher", "isPrimary": true, "type": "FileTask", "path": "launcher.exe"},
          {"category": "game", "isHidden": true, "type": "FileTask", "path": "mafiadefinitiveedition.exe"}]}
        """#)
        #expect(GOGParser.playTask(infoJSON: info)?.path == "mafiadefinitiveedition.exe")
        let launcherOnly = json(#"{"playTasks":[{"category":"launcher","isPrimary":true,"path":"launcher.exe"}]}"#)
        #expect(GOGParser.playTask(infoJSON: launcherOnly)?.path == "launcher.exe")
    }

    @Test func installRecordKeepsItsShape() throws {
        var record = GOGInstalled()
        record.games["1207658924"] = .init(title: "Unreal Tournament 2004", path: URL(fileURLWithPath: "/G/UT2004"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        let entry = (object?["games"] as? [String: Any])?["1207658924"] as? [String: Any]
        #expect(entry?["title"] as? String == "Unreal Tournament 2004")
        #expect(entry?["path"] as? String == "file:///G/UT2004")
        #expect(try JSONDecoder().decode(GOGInstalled.self, from: JSONEncoder().encode(record)) == record)
    }
}

@Suite("GOG installs")
struct GOGInstallTests {
    @Test func newFolderWinsAndUninstallStaysInside() throws {
        let scratch = scratchFolder("gog")
        defer { discard(scratch) }
        let gog = GOGProvider(paths: Paths(home: scratch), gamesFolder: scratch.appendingPathComponent("Games"))
        for name in ["Old Copy", "Fresh Copy"] {
            let folder = gog.gamesFolder.appendingPathComponent(name)
            try makeFolder(folder)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("goggame-77.info"))
        }
        #expect(gog.findInstall(id: "77", preferring: ["Old Copy"])?.lastPathComponent == "Fresh Copy")
        #expect(gog.findInstall(id: "78", preferring: []) == nil)

        // A record pointing outside the GOG folder is forgotten, but its files stay.
        let outside = scratch.appendingPathComponent("Elsewhere")
        try makeFolder(outside)
        var record = GOGInstalled()
        record.games["77"] = .init(title: "Fresh", path: gog.gamesFolder.appendingPathComponent("Fresh Copy"))
        record.games["99"] = .init(title: "Stray", path: outside)
        try gog.saveInstalled(record)

        try gog.uninstall(Game(store: .gog, storeID: "99", title: "Stray", isInstalled: true))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        try gog.uninstall(Game(store: .gog, storeID: "77", title: "Fresh", isInstalled: true))
        #expect(!FileManager.default.fileExists(atPath: gog.gamesFolder.appendingPathComponent("Fresh Copy").path))
        #expect(gog.readInstalled().games.isEmpty)
    }

    @Test func folderSizeAddsUpFiles() throws {
        let scratch = scratchFolder("size")
        defer { discard(scratch) }
        try makeFolder(scratch.appendingPathComponent("sub"))
        try Data(repeating: 1, count: 10_000).write(to: scratch.appendingPathComponent("sub/a.bin"))
        #expect((GOGProvider.folderSize(scratch) ?? 0) >= 10_000)
    }
}

// MARK: - Epic

@Suite("Legendary answers")
struct LegendaryAnswerTests {
    @Test func macReleasesAreNoted() throws {
        let owned = json(#"""
        [{"app_name":"Fennel","app_title":"Windows Only","metadata":{"releaseInfo":[{"platform":["Win32","Windows"]}]}},
         {"app_name":"Garlic","app_title":"Enter the Gungeon","metadata":{"releaseInfo":[{"platform":["Windows","Mac"]}]}},
         {"app_name":"Plain","app_title":"No Release Info","metadata":{}}]
        """#)
        let games = try LegendaryParser.games(listJSON: owned, installedJSON: json("[]"))
        let builds = Dictionary(uniqueKeysWithValues: games.map { ($0.storeID, $0.macBuild) })
        #expect(builds["Fennel"] == .some(nil))
        #expect(builds["Garlic"] == .some(.unknown))
        #expect(builds["Plain"] == .some(nil))
        #expect(games.allSatisfy { !$0.isInstalled && !$0.isNative })
    }

    @Test func pictureFallbacks() throws {
        let owned = json(#"""
        [{"app_name":"A","app_title":"A","metadata":{"keyImages":[
            {"type":"Thumbnail","url":"https://e.test/thumb.jpg"},
            {"type":"DieselGameBoxTall","url":"https://e.test/tall.jpg"},
            {"type":"OfferImageWide","url":"https://e.test/wide.jpg"}]}}]
        """#)
        let game = try #require(try LegendaryParser.games(listJSON: owned, installedJSON: json("[]")).first)
        #expect(game.coverURL?.absoluteString == "https://e.test/tall.jpg")   // the tall box art beats the thumbnail
        #expect(game.heroURL?.absoluteString == "https://e.test/wide.jpg")
    }

    @Test func duplicateInstallRecordsDontCrash() throws {
        let owned = json(#"[{"app_name":"A","app_title":"A"}]"#)
        let installed = json(#"""
        [{"app_name":"A","install_path":"/one","install_size":1},{"app_name":"A","install_path":"/two","install_size":2}]
        """#)
        let game = try #require(try LegendaryParser.games(listJSON: owned, installedJSON: installed).first)
        #expect(game.installPath?.path == "/two" && game.sizeOnDisk == 2)
    }

    @Test func brokenJSONThrows() {
        #expect(throws: (any Error).self) { try LegendaryParser.games(listJSON: json("{"), installedJSON: json("[]")) }
        #expect(throws: (any Error).self) { try LegendaryParser.games(listJSON: json("[]"), installedJSON: json("[{}]")) }
    }

    @Test func progressWithoutPercentSign() {
        #expect(LegendaryParser.progress(from: "= Progress: 40") == 0.4)
        #expect(LegendaryParser.progress(from: "= Progress: 250.0% (x)") == 1)
    }
}

// MARK: - Publisher launchers

@Suite("Ubisoft Connect")
struct UbisoftLauncherTests {
    @Test func installsComeFromTheRegistry() throws {
        let scratch = scratchFolder("ubisoft")
        defer { discard(scratch) }
        let bottle = Bottle(kind: .ubisoft, paths: Paths(home: scratch))
        let games = bottle.driveC.appendingPathComponent("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games")
        try makeFolder(games.appendingPathComponent("Anno 1800"))
        let reg = #"""
        ;; All keys relative to \\Machine

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\4553] 1710000001
        #time=1da0c3
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Anno 1800/"
        "Language"="en-US"

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\4553\\Extra] 1710000002
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Anno 1800/"

        [Software\\Wow6432Node\\Ubisoft\\Launcher\\Installs\\720] 1710000003
        "InstallDir"="C:/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Deleted Since/"
        """#
        let found = LauncherStore.ubisoftGames(systemReg: reg, bottle: bottle)
        #expect(found.map(\.storeID) == ["4553"])
        #expect(found.first?.title == "Anno 1800")
        #expect(found.first?.isInstalled == true)
        #expect(LauncherStore.ubisoftGames(systemReg: "", bottle: bottle).isEmpty)
    }

    /// Builds a protobuf varint, the way the launcher's configuration cache stores numbers.
    static func varint(_ value: UInt64) -> [UInt8] {
        var rest = value
        var bytes: [UInt8] = []
        while true {
            let low = UInt8(rest & 0x7F)
            rest >>= 7
            if rest == 0 { bytes.append(low); return bytes }
            bytes.append(low | 0x80)
        }
    }

    /// One cached configuration record: field 1 the Ubisoft id, 2 the install id, 3 the YAML.
    static func record(uplay: UInt64, install: UInt64, yaml: String) -> [UInt8] {
        let text = Array(yaml.utf8)
        let body = [0x08] + varint(uplay) + [0x10] + varint(install) + [0x1A] + varint(UInt64(text.count)) + text
        return [0x0A] + varint(UInt64(body.count)) + body
    }

    @Test func libraryMergesInstallsWithOwnedGames() {
        let yaml = """
        version: 2.0
        root:
          name: l1
          background_image: bg-anno.jpg
          thumb_image: l2
          start_game:
            offline:
              executables:
              - path:
                  relative: Bin/Win64/Anno1800.exe
        localizations:
          default:
            l1: Anno 1800
            l2: cover-anno.jpg
          fr-FR:
            l1: Anno 1800 FR
        """.replacingOccurrences(of: "\n", with: "\r\n")       // the launcher writes Windows line ends
        let addon = "version: 2.0\nroot:\n  name: l1\nlocalizations:\n  default:\n    l1: Season Pass\n"
        let cache = Data(Self.record(uplay: 4553, install: 4553, yaml: yaml) + Self.record(uplay: 9000, install: 9001, yaml: addon))
        let owned = UbisoftConfigurations.parse(cache)
        #expect(owned == [.init(uplayID: 4553, installID: 4553, name: "Anno 1800", thumbnail: "cover-anno.jpg", background: "bg-anno.jpg")])
        #expect(UbisoftConfigurations.assetURL("cover-anno.jpg")?.absoluteString
                == "https://ubistatic3-a.akamaihd.net/orbit/uplay_launcher_3_0/assets/cover-anno.jpg")

        let onDisk = [Game(store: .ubisoft, storeID: "4553", title: "Anno1800 folder", isInstalled: true,
                           installPath: URL(fileURLWithPath: "/games/anno"), sizeOnDisk: 5)]
        let alsoOwned = UbisoftConfigurations.Entry(uplayID: 3539, installID: 3539, name: "beyond Good and Evil",
                                                    thumbnail: nil, background: nil)
        let library = LauncherStore.ubisoftLibrary(installed: onDisk, owned: owned + [alsoOwned])
        #expect(library.map(\.title) == ["Anno 1800", "beyond Good and Evil"])
        #expect(library[0].isInstalled && library[0].sizeOnDisk == 5 && library[0].heroURL != nil)
        #expect(!library[1].isInstalled && library[1].coverURL == nil && library[1].storeID == "3539")
    }

    @Test func unknownInstallsKeepTheirFolderName() {
        let onDisk = [Game(store: .ubisoft, storeID: "1", title: "Folder Name", isInstalled: true)]
        #expect(LauncherStore.ubisoftLibrary(installed: onDisk, owned: []).map(\.title) == ["Folder Name"])
    }
}

@Suite("EA app")
struct EALauncherTests {
    @Test func contentIDFromInstallerData() {
        let xml = "<DiPManifest><contentIDs>\n  <contentID> 1035052 </contentID><contentID>71173</contentID></contentIDs></DiPManifest>"
        #expect(LauncherStore.eaContentID(installerXML: xml) == "1035052")
        #expect(LauncherStore.eaContentID(installerXML: "<contentID></contentID>") == nil)
        #expect(LauncherStore.eaContentID(installerXML: "<contentID>12") == nil)
    }

    @Test func gamesNeedAnInstallerFolder() throws {
        let scratch = scratchFolder("ea-games")
        defer { discard(scratch) }
        let bottle = Bottle(kind: .ea, paths: Paths(home: scratch))
        let gamesRoot = bottle.driveC.appendingPathComponent("Program Files/EA Games")
        try makeFolder(gamesRoot.appendingPathComponent("Unravel/__Installer"))
        try "<contentID>Origin.OFR.50.0001</contentID>".write(to: gamesRoot.appendingPathComponent("Unravel/__Installer/installerdata.xml"),
                                                             atomically: true, encoding: .utf8)
        try makeFolder(gamesRoot.appendingPathComponent("A Way Out/__Installer"))
        try makeFolder(gamesRoot.appendingPathComponent("Leftovers"))
        let games = LauncherStore.eaGames(in: bottle)
        #expect(games.map(\.title) == ["A Way Out", "Unravel"])
        #expect(games.map(\.storeID) == ["A Way Out", "Origin.OFR.50.0001"])
    }

    /// After Wine installs the EA app: version folders, and an empty stand-in where the junction should be.
    @Test func newestVersionFolderIsTheLauncher() throws {
        let scratch = scratchFolder("ea-app")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)   // nothing exists there yet
        let root = Bottle(kind: .ea, paths: paths).driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        for version in ["13.900.0.6400", "13.1100.0.2", "13.2000.0.1"] {
            try makeFolder(root.appendingPathComponent(version + "/EA Desktop"))
        }
        for version in ["13.900.0.6400", "13.1100.0.2"] {   // the newest folder lacks the program
            try Data().write(to: root.appendingPathComponent(version + "/EA Desktop/EADesktop.exe"))
        }
        try makeFolder(root.appendingPathComponent("EA Desktop?"))

        let eaStore = LauncherStore(kind: .ea, paths: paths)
        #expect(eaStore.launcherExecutable.path.hasSuffix("EA Desktop/13.1100.0.2/EA Desktop/EADesktop.exe"))
        #expect(eaStore.isLauncherInstalled)
    }

    @Test func noVersionFolderMeansNotInstalled() {
        let scratch = scratchFolder("ea-none")
        let store = LauncherStore(kind: .ea, paths: Paths(home: scratch))
        #expect(!store.isLauncherInstalled)
        #expect(store.launcherExecutable.path.hasSuffix("EA Desktop/EA Desktop/EA Desktop/EADesktop.exe"))
    }

    @Test func signedInOnceAUserSettingsFileExists() throws {
        let scratch = scratchFolder("ea-signin")
        defer { discard(scratch) }
        let store = LauncherStore(kind: .ea, paths: Paths(home: scratch))
        let settings = store.bottle.driveC.appendingPathComponent("users/player/AppData/Local/Electronic Arts/EA Desktop")
        try makeFolder(settings)
        #expect(!store.isSignedIn)
        try Data().write(to: settings.appendingPathComponent("user_1234.ini"))
        #expect(store.isSignedIn)
    }

    @Test func monoUnblocksMscoreeOnlyOnceInstalled() throws {
        let scratch = scratchFolder("ea-mono")
        defer { discard(scratch) }
        let eaBottle = Bottle(kind: .ea, paths: Paths(home: scratch))
        var settings = LaunchProfile()
        settings.backend = .wined3d                  // brings no DLL overrides of its own
        func overrides() -> String? { WineRunner.environment(bottle: eaBottle, profile: settings)["WINEDLLOVERRIDES"] }
        #expect(!eaBottle.hasMono && overrides() == "mscoree,mshtml=;winemenubuilder.exe=d")
        try makeFolder(eaBottle.driveC.appendingPathComponent("windows/mono/mono-2.0"))
        #expect(eaBottle.hasMono && overrides() == "mshtml=;winemenubuilder.exe=d")
    }

    @Test func monoDownloadIsPinned() {
        #expect(WineMono.sha256.count == 64 && WineMono.sha256.allSatisfy(\.isHexDigit))
        #expect(WineMono.downloadURL == URL(string: "https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.msi"))
    }

    @Test func gamesShippingTheEAAppNeedItSetUp() throws {
        let scratch = scratchFolder("ea-setup")
        defer { discard(scratch) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: scratch))
        let withEA = scratch.appendingPathComponent("Need for Speed"), plain = scratch.appendingPathComponent("Plain")
        let bundled = withEA.appendingPathComponent("__Installer/Origin/redist/internal")
        try makeFolder(bundled)
        try makeFolder(plain)
        try Data().write(to: bundled.appendingPathComponent("EAappInstaller.exe"))
        #expect(EAAppSetup.needsSetup(gameFolder: withEA, bottle: bottle))
        #expect(!EAAppSetup.needsSetup(gameFolder: plain, bottle: bottle))

        try makeFolder(bottle.driveC.appendingPathComponent("windows/mono/mono-2.0"))
        let app = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop/13.900.0.1/EA Desktop")
        try makeFolder(app)
        #expect(EAAppSetup.needsSetup(gameFolder: withEA, bottle: bottle))       // an empty app folder isn't enough
        try Data().write(to: app.appendingPathComponent("Link2EA.exe"))
        #expect(EAAppSetup.isInstalled(in: bottle))
        #expect(!EAAppSetup.needsSetup(gameFolder: withEA, bottle: bottle))
    }

    @Test func overlaySettingIsWrittenOff() {
        #expect(EAAppSetup.overlayOff(in: "user.userid=7\r\n") == "user.userid=7\r\nuser.igoEnabled=false\r\n")
        #expect(EAAppSetup.overlayOff(in: "user.IGOEnabled=true\r\nlocation.language=de\r\n")
                == "location.language=de\r\nuser.igoEnabled=false\r\n")
    }

    @Test func overlayFilesMoveAsideOnlyUntilFirstSignIn() throws {
        let scratch = scratchFolder("ea-overlay")
        defer { discard(scratch) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: scratch))
        let files = FileManager.default
        let app = bottle.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop/13.2/EA Desktop")
        try makeFolder(app)
        try Data().write(to: app.appendingPathComponent("IGO64.dll"))
        EAAppSetup.disableOverlay(in: bottle)
        #expect(files.fileExists(atPath: app.appendingPathComponent("IGO64.dll.off").path))
        #expect(!files.fileExists(atPath: app.appendingPathComponent("IGO64.dll").path))

        let settings = bottle.driveC.appendingPathComponent("users/player/AppData/Local/Electronic Arts/EA Desktop")
        try makeFolder(settings)
        try "user.userid=7\r\n".write(to: settings.appendingPathComponent("user_7.ini"), atomically: true, encoding: .utf8)
        try Data().write(to: app.appendingPathComponent("IGO32.dll"))
        EAAppSetup.disableOverlay(in: bottle)
        #expect(files.fileExists(atPath: app.appendingPathComponent("IGO32.dll").path))   // the setting takes over
        let ini = try String(contentsOf: settings.appendingPathComponent("user_7.ini"), encoding: .utf8)
        #expect(ini.contains("user.igoEnabled=false"))
    }
}

@Suite("Battle.net")
struct BattleNetLauncherTests {
    @Test func blizzardGamesFromTheUninstallList() throws {
        let scratch = scratchFolder("bnet")
        defer { discard(scratch) }
        let bottle = Bottle(kind: .battlenet, paths: Paths(home: scratch))
        let diablo = bottle.driveC.appendingPathComponent("Program Files (x86)/Diablo IV")
        let starcraft = bottle.driveC.appendingPathComponent("Program Files/StarCraft II")
        try makeFolder(diablo)
        try makeFolder(starcraft)
        let reg = #"""
        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Battle.net] 1
        "DisplayName"="Battle.net"
        "Publisher"="Blizzard Entertainment"
        "InstallLocation"="C:\\Program Files (x86)\\Battle.net"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Diablo IV] 1
        "DisplayName"="Diablo IV"
        "Publisher"="Blizzard Entertainment"
        "InstallLocation"="C:\\Program Files (x86)\\Diablo IV"
        "EstimatedSize"=dword:00000001

        [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\StarCraft II] 1
        "DisplayName"="StarCraft II"
        "Publisher"="Blizzard Entertainment"
        "InstallLocation"="C:\\Program Files\\StarCraft II"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\NotBlizzard] 1
        "DisplayName"="Some Tool"
        "Publisher"="Another Company"
        "InstallLocation"="C:\\Program Files (x86)\\Diablo IV"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Gone] 1
        "DisplayName"="Overwatch"
        "Publisher"="Blizzard Entertainment"
        "InstallLocation"="C:\\Program Files (x86)\\Overwatch"

        [Software\\Classes\\Blizzard] 1
        "DisplayName"="Hearthstone"
        "Publisher"="Blizzard Entertainment"
        "InstallLocation"="C:\\Program Files (x86)\\Diablo IV"
        """#
        let games = LauncherStore.blizzardGames(systemReg: reg, bottle: bottle)
        #expect(games.map(\.title) == ["Diablo IV", "StarCraft II"])
        #expect(games.map(\.storeID) == ["Fen", "S2"])
        #expect(games.first?.installPath?.standardizedFileURL.path == diablo.standardizedFileURL.path)
    }

    @Test(arguments: [
        ("World of Warcraft", "WoW"), ("World of Warcraft Classic", "WoWC"), ("Hearthstone", "WTCG"),
        ("Overwatch 2", "Pro"), ("Diablo IV", "Fen"), ("Diablo III: Reaper of Souls", "D3"),
        ("Diablo II: Resurrected", "OSI"), ("Diablo Immortal", "ANBS"), ("StarCraft II", "S2"),
        ("StarCraft Remastered", "S1"), ("Heroes of the Storm", "Hero"), ("Warcraft III: Reforged", "W3"),
        ("Warcraft II: Battle.net Edition", "W2"), ("Warcraft: Orcs & Humans", "W1"),
        ("Call of Duty: Black Ops Cold War", "ZEUS"), ("Call of Duty", "AUKS"),
    ])
    func productCodes(title: String, code: String) {
        #expect(LauncherStore.blizzardCode(for: title) == code)
    }

    @Test func unknownTitlesHaveNoCode() {
        #expect(LauncherStore.blizzardCode(for: "Crash Bandicoot 4") == nil)
    }

    @Test func ownedGamesFromTheSignInLog() {
        let log = """
        D 2026-10-25 23:41:04.963334 [GSAccountProvider] {Main} Querying program level information for program: Pro
        D 2026-10-25 23:41:04.979934 [GSAccountProvider] {Main} Querying game level information for entity: (Game: EU-WTCG-1103885913)
        D 2026-10-25 23:41:04.980455 [GSAccountProvider] {Main} Querying game time info for entity Id: (Game: EU-WTCG-1103885913)
        D 2026-10-25 23:41:04.980985 [GSAccountProvider] {Main} Querying game level information for entity: (Game: GLOBAL-Fen-1099497250)
        D 2026-10-25 23:41:04.990000 [GSAccountProvider] {Main} Querying game level information for entity: (Game: US-WTCG-42)
        """
        #expect(LauncherStore.blizzardOwned(log: log) == ["WTCG", "Fen"])
        #expect(LauncherStore.blizzardOwned(log: "Leaving because another instance of battle.net is running").isEmpty)
    }

    @Test func ownedGamesJoinTheInstalledOnes() {
        let installed = Game(store: .battlenet, storeID: "Fen", title: "Diablo IV", isInstalled: true)
        let games = LauncherStore.blizzardLibrary(installed: [installed], owned: ["Fen", "WTCG", "KELP"])
        #expect(games.map(\.title).sorted() == ["Diablo IV", "Hearthstone"])
        #expect(games.first { $0.storeID == "WTCG" }?.isInstalled == false)
        #expect(games.first { $0.storeID == "Fen" }?.isInstalled == true)
        #expect(games.first { $0.storeID == "WTCG" }?.macBuild != nil && games.first { $0.storeID == "Fen" }?.macBuild == nil)
        // Every listed title gives its own code back, so an install joins the owned entry.
        for (code, title) in LauncherStore.blizzardTitles { #expect(LauncherStore.blizzardCode(for: title) == code) }
    }
}

@Suite("Launcher stores")
struct LauncherStoreBasicsTests {
    @Test func eachStoreHasItsOwnInstaller() {
        let paths = Paths(home: scratchFolder("installers"))
        for kind in LauncherStore.kinds {
            let store = LauncherStore(kind: kind, paths: paths)
            #expect(store.installerURL.scheme == "https")
            #expect(store.bottle.kind == kind.bottleKind)
        }
        #expect(LauncherStore(kind: .ubisoft, paths: paths).installerArguments == ["/S"])
        #expect(LauncherStore(kind: .ea, paths: paths).installerArguments.contains("EAX_LAUNCH_CLIENT=0"))
        #expect(LauncherStore(kind: .battlenet, paths: paths).launcherExecutable.lastPathComponent == "Battle.net Launcher.exe")
    }

    @Test func launchersDrawWithoutTheGPUProcess() {
        let store = LauncherStore(kind: .ubisoft, paths: Paths(home: scratchFolder("flags")))
        #expect(Set(store.launcherArguments) == ["--in-process-gpu", "--disable-gpu", "--disable-gpu-compositing"])
    }

    @Test func nothingDownloadsWithoutALauncher() {
        let paths = Paths(home: scratchFolder("downloads"))
        #expect(LauncherStore(kind: .battlenet, paths: paths).downloads().isEmpty)
        #expect(LauncherStore(kind: .ubisoft, paths: paths).ubisoftSteamActivations().isEmpty)
    }
}

// MARK: - Environments

@Suite("Environments")
struct EnvironmentPreparationTests {
    @Test func runtimeDLLsAreSharedWithoutOverwriting() throws {
        let scratch = scratchFolder("runtime")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)   // nothing exists there yet
        func place(_ kind: BottleKind, _ file: String, _ text: String) throws {
            let target = Bottle(kind: kind, paths: paths).driveC.appendingPathComponent("windows/" + file)
            try makeFolder(target.deletingLastPathComponent())
            try Data(text.utf8).write(to: target)
        }
        try place(.steam, "system32/mfc140u.dll", "from steam 64")
        try place(.steam, "syswow64/mfc140u.dll", "from steam 32")
        try place(.gog, "system32/ntdll.dll", "-")              // the GOG environment exists
        try place(.gog, "syswow64/mfc140u.dll", "already there")

        #expect(BottleManager(paths: paths).provisionRuntime(in: .gog) == ["system32/mfc140u.dll"])
        let windows = Bottle(kind: .gog, paths: paths).driveC.appendingPathComponent("windows")
        #expect(try String(contentsOf: windows.appendingPathComponent("system32/mfc140u.dll"), encoding: .utf8) == "from steam 64")
        #expect(try String(contentsOf: windows.appendingPathComponent("syswow64/mfc140u.dll"), encoding: .utf8) == "already there")
    }

    /// An engine whose `wine` makes a bare prefix for `wineboot --init`, as the real one would.
    private func engineThatBuildsPrefixes(in root: URL) throws -> Engine {
        let engine = try makeTestEngine(root, version: "3.1.0", backends: ["dxvk"], d3dMetal: false)
        let script = """
        #!/bin/sh
        if [ "$1" = wineboot ]; then mkdir -p "$WINEPREFIX/drive_c/windows"; fi
        exit 0
        """
        try script.write(to: engine.wine, atomically: true, encoding: .utf8)
        return engine
    }

    @Test func epicAndGOGGetAnEnvironmentOnFirstPlay() async throws {
        let scratch = scratchFolder("first-play")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)   // nothing exists there yet
        let engine = try engineThatBuildsPrefixes(in: scratch)
        for storeKind in [StoreKind.gog, .epic] {
            #expect(!Bottle(kind: storeKind.bottleKind, paths: paths).exists)
            let prepared = try await BottleManager(paths: paths).prepareForPlay(storeKind, engine: engine)
            #expect(prepared?.exists == true)
        }
    }

    @Test func aResetEnvironmentComesBack() async throws {
        let scratch = scratchFolder("reset")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)   // nothing exists there yet
        let engine = try engineThatBuildsPrefixes(in: scratch)
        let bottles = BottleManager(paths: paths)
        try await bottles.prepareForPlay(.epic, engine: engine)
        try FileManager.default.removeItem(at: Bottle(kind: .epic, paths: paths).url)
        try await bottles.prepareForPlay(.epic, engine: engine)
        #expect(Bottle(kind: .epic, paths: paths).exists, "rebuilt after the reset")
    }

    @Test func existingEnvironmentIsUntouched() async throws {
        let scratch = scratchFolder("existing")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)   // nothing exists there yet
        let engine = try engineThatBuildsPrefixes(in: scratch)
        let keep = Bottle(kind: .gog, paths: paths).driveC.appendingPathComponent("windows/notes.txt")
        try makeFolder(keep.deletingLastPathComponent())
        try Data("mine".utf8).write(to: keep)
        try await BottleManager(paths: paths).prepareForPlay(.gog, engine: engine)
        #expect(try String(contentsOf: keep, encoding: .utf8) == "mine")
    }

    @Test func launcherStoresAreSetUpByTheirOwnInstall() async throws {
        let scratch = scratchFolder("launcher-envs")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)   // nothing exists there yet
        let engine = try engineThatBuildsPrefixes(in: scratch)
        for storeKind in [StoreKind.steam, .ea, .ubisoft] {
            #expect(try await BottleManager(paths: paths).prepareForPlay(storeKind, engine: engine) == nil)
            #expect(!Bottle(kind: storeKind.bottleKind, paths: paths).exists)
        }
    }
}

// MARK: - Library records

@Suite("Saved library entries")
struct SavedLibraryEntryTests {
    @Test func entriesFromBeforeMacVersionsStillLoad() throws {
        let saved = #"{"id":"gog:5","store":"gog","storeID":"5","title":"Five","isInstalled":true}"#
        let game = try JSONDecoder().decode(Game.self, from: json(saved))
        #expect(game.macBuild == nil && !game.isNative && game.isInstalled)
    }
}

@Suite struct GamesFolderTests {
    @Test func gogUninstallReachesGamesInAnEarlierFolderOnly() throws {
        let scratch = scratchFolder("gog-moved")
        defer { discard(scratch) }
        let old = scratch.appendingPathComponent("Old Drive/GOG/Wren"), bare = scratch.appendingPathComponent("Old Drive/GOG/Bare")
        let notGOG = scratch.appendingPathComponent("Documents/Wren")
        for folder in [old, bare, notGOG] { try makeFolder(folder) }
        for folder in [old, notGOG] { try Data("{}".utf8).write(to: folder.appendingPathComponent("goggame-5.info")) }
        let gog = GOGProvider(paths: Paths(home: scratch), gamesFolder: scratch.appendingPathComponent("New Drive"))
        var record = GOGInstalled()
        record.games["5"] = .init(title: "Wren", path: old)
        record.games["6"] = .init(title: "Bare", path: bare)                   // no info file: not gogdl's
        record.games["7"] = .init(title: "Elsewhere", path: notGOG)            // not in a GOG folder
        try gog.saveInstalled(record)
        for id in ["5", "6", "7"] { try gog.uninstall(Game(store: .gog, storeID: id, title: id, isInstalled: true)) }
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: bare.path) && FileManager.default.fileExists(atPath: notGOG.path))
        #expect(gog.readInstalled().games.isEmpty)
    }

    @Test func steamLibraryIsAddedOnceToBothLists() throws {
        let scratch = scratchFolder("steam-lib")
        defer { discard(scratch) }
        let bottle = Bottle(kind: .steam, paths: Paths(home: scratch))
        let list = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
        \t\t"apps"
        \t\t{
        \t\t\t"648800"\t\t"7773455514"
        \t\t}
        \t}
        }

        """
        for sub in ["steamapps", "config"] {
            try makeFolder(bottle.steamDirectory.appendingPathComponent(sub))
            try list.write(to: bottle.steamDirectory.appendingPathComponent("\(sub)/libraryfolders.vdf"), atomically: true, encoding: .utf8)
        }
        try makeFolder(bottle.url.appendingPathComponent("dosdevices"))
        try FileManager.default.createSymbolicLink(atPath: bottle.url.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        let drive = scratch.appendingPathComponent("External/Steam")

        #expect(try SteamLibraryFolders.add(drive, to: bottle, contentID: 42))
        #expect(try SteamLibraryFolders.add(drive, to: bottle, contentID: 43) == false)       // already there
        for sub in ["steamapps", "config"] {
            let text = try String(contentsOf: bottle.steamDirectory.appendingPathComponent("\(sub)/libraryfolders.vdf"), encoding: .utf8)
            let libraries = try #require(try VDFParser.parse(text)["libraryfolders"]?.entries)
            #expect(libraries.map(\.key) == ["0", "1"])
            #expect(libraries[1].value["path"]?.string == SteamLibraryFolders.windowsPath(of: drive))
            #expect(libraries[1].value["contentid"]?.string == "42")
            #expect(libraries[0].value["apps"]?["648800"]?.string == "7773455514")              // the rest untouched
        }
        #expect(FileManager.default.fileExists(atPath: drive.appendingPathComponent("steamapps").path))
        let marker = try String(contentsOf: drive.appendingPathComponent("libraryfolder.vdf"), encoding: .utf8)
        #expect(try VDFParser.parse(marker)["libraryfolder"]?["contentid"]?.string == "42")
        #expect(SteamLibraryFolders.windowsPath(of: URL(fileURLWithPath: "/Volumes/Big/Games")) == "Z:\\Volumes\\Big\\Games")
    }

    @Test func lastInstallFolderIsSetAtTheTopOfTheAccountConfig() throws {
        let config = "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"LastInstallFolderIndex\"\t\t\"7\"\n\t}\n\t\"FamilyGroup\"\n\t{\n\t\t\"version\"\t\t\"1\"\n\t}\n}\n"
        let added = try #require(SteamLibraryFolders.settingTopLevel("LastInstallFolderIndex", to: "1", in: config))
        let root = try #require(try VDFParser.parse(added)["UserLocalConfigStore"])
        #expect(root["LastInstallFolderIndex"]?.string == "1")
        #expect(root["Software"]?["LastInstallFolderIndex"]?.string == "7")          // a nested key isn't touched
        let replaced = try #require(SteamLibraryFolders.settingTopLevel("LastInstallFolderIndex", to: "0", in: added))
        #expect(try VDFParser.parse(replaced)["UserLocalConfigStore"]?["LastInstallFolderIndex"]?.string == "0")
        #expect(replaced.components(separatedBy: "LastInstallFolderIndex").count == 3)   // replaced, not added twice
        #expect(SteamLibraryFolders.settingTopLevel("x", to: "1", in: "garbage") == nil)
    }

    @Test func launcherSignOutRemovesTheLoginAndKeepsTheGames() throws {
        let scratch = scratchFolder("signout")
        defer { discard(scratch) }
        let paths = Paths(home: scratch)
        func profile(_ kind: StoreKind) -> URL { LauncherStore(kind: kind, paths: paths).bottle.driveC.appendingPathComponent("users/crossover/AppData") }
        func write(_ url: URL, _ text: String = "x") throws { try makeFolder(url.deletingLastPathComponent()); try text.write(to: url, atomically: true, encoding: .utf8) }

        let ea = profile(.ea).appendingPathComponent("Local/Electronic Arts/EA Desktop")
        for name in ["SEC/production/a/b", "CEF/2/EADesktop/LocalPrefs.json", "cookie.ini", "user_123.ini", "telemetry.ini"] { try write(ea.appendingPathComponent(name)) }
        let eaInstalls = LauncherStore(kind: .ea, paths: paths).bottle.driveC.appendingPathComponent("ProgramData/EA Desktop/IS")
        try write(eaInstalls)
        let ubi = profile(.ubisoft).appendingPathComponent("Local/Ubisoft Game Launcher")
        for name in ["ConnectSecureStorage.dat", "user.dat", "cache/ownership/1", "settings.yaml", "cache/configuration/2"] { try write(ubi.appendingPathComponent(name)) }
        let config = profile(.battlenet).appendingPathComponent("Roaming/Battle.net/Battle.net.config")
        try write(config, #"{"Client": {"SavedAccountNames": "a@b.c", "AutoLogin": true, "Language": "enUS"}, "Games": {"x": {"Path": "C:/G"}}}"#)
        try write(profile(.battlenet).appendingPathComponent("Local/Battle.net/BrowserCaches/c"))

        for kind: StoreKind in [.ea, .ubisoft, .battlenet] {
            let store = LauncherStore(kind: kind, paths: paths)
            if kind != .battlenet { #expect(store.isSignedIn) }
            store.forgetSignIn()
            #expect(!store.isSignedIn)
        }
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        #expect(!exists(ea.appendingPathComponent("SEC")) && !exists(ea.appendingPathComponent("user_123.ini")))
        #expect(exists(ea.appendingPathComponent("telemetry.ini")) && exists(eaInstalls))                  // games' records stay
        #expect(!exists(ubi.appendingPathComponent("ConnectSecureStorage.dat")) && !exists(ubi.appendingPathComponent("cache/ownership")))
        #expect(exists(ubi.appendingPathComponent("settings.yaml")) && exists(ubi.appendingPathComponent("cache/configuration/2")))
        let cleaned = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        #expect((cleaned["Client"] as? [String: Any])?.keys.sorted() == ["Language"])
        #expect(((cleaned["Games"] as? [String: Any])?["x"] as? [String: Any])?["Path"] as? String == "C:/G")
        #expect(!exists(profile(.battlenet).appendingPathComponent("Local/Battle.net/BrowserCaches")))
    }
}
