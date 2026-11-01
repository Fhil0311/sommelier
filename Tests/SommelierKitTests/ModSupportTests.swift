// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

struct ModSupportTests {
    private func fixtureList() throws -> ModsList {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
    }

    private func game(_ id: String, store: StoreKind = .steam, native: Bool = false, at path: URL? = nil) -> Game {
        Game(store: store, storeID: id, title: id, isInstalled: true, installPath: path, native: native)
    }

    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-mods-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// The place a spec resolves to, as a path (a folder's trailing slash doesn't matter).
    private func place(_ roots: ModRoots, _ spec: String) -> String? { roots.resolve(spec)?.path }

    @Test func allFiveGamesDecode() throws {
        let list = try fixtureList()
        #expect(list.version == 1)
        #expect(list.games.map(\.game) == ["steam:990080", "steam:2050650", "steam:413150", "steam:1174180", "steam:1245620"])

        let hogwarts = try #require(list.profile(covering: "steam:990080"))
        #expect(hogwarts.status == .ready && hogwarts.runtime == .wine && hogwarts.sources.nexus?.domain == "hogwartslegacy")
        let ue4ss = try #require(hogwarts.framework("ue4ss"))
        #expect(ue4ss.download.kind == .github && ue4ss.download.repo == "UE4SS-RE/RE-UE4SS" && ue4ss.code)
        #expect(ue4ss.dllOverrides == ["dwmapi": "n,b"] && ue4ss.disableArgument == "--disable-ue4ss" && ue4ss.launch == nil)
        #expect(ue4ss.settings.first?.format == .ini)
        #expect(ue4ss.settings.first?.set["EngineVersionOverride"] == .object(["MajorVersion": .string("4"), "MinorVersion": .string("27")]))
        #expect(hogwarts.framework("asiloader")?.optional == true)
        #expect(hogwarts.kinds.map(\.id) == ["logic", "pak", "lua", "asi", "movie", "ini"], "LogicMods first: a `_P` triple in that folder is a Blueprint mod")
        let pak = try #require(hogwarts.kind("pak"))
        #expect(pak.unit == .triple && pak.order == .prefix && pak.to == "game:Phoenix/Content/Paks/~mods/{slot}/" && !pak.code)
        let lua = try #require(hogwarts.kind("lua"))
        #expect(lua.unit == .folder && lua.framework == "ue4ss" && lua.enable?.format == .ue4ssModsTxt && lua.code)
        #expect(hogwarts.kind("asi")?.siblings == true && hogwarts.kind("movie")?.backupOriginal == true && hogwarts.kind("ini")?.ask == true)
        #expect(hogwarts.loadOrder.format == .prefixFolder && hogwarts.loadOrder.reverse && hogwarts.loadOrder.isReorderable)
        #expect(hogwarts.conflicts.samePath == .warn && hogwarts.conflicts.rules.first?.sameStem == true)
        #expect(hogwarts.logs.count == 2 && hogwarts.logs[0].rules.map(\.action) == [.disableFramework, .disableMod] && hogwarts.logs[0].rules[1].modFrom == 1)
        #expect(hogwarts.saves == [SaveSource(root: .local, path: "Hogwarts Legacy/Saved/SaveGames"), SaveSource(root: .local, path: "Hogwarts Legacy/Saved/Config/WindowsNoEditor")])
        #expect(hogwarts.online.policy == .allowed && !hogwarts.online.forbidsPlainLaunchWithMods)
        #expect(hogwarts.notes.untouched == ["documents:Hogwarts Legacy/Mods/**"] && hogwarts.notes.cleanupOnLastCodeMod)
        #expect(hogwarts.archive.wrappers && hogwarts.archive.deny.contains("dwmapi.dll") && hogwarts.archive.ignore == ModArchiveRules.defaultIgnore)

        let re4 = try #require(list.profile(covering: "steam:2050650"))
        #expect(re4.kind("pak")?.pinned == .last && re4.kind("pak")?.to == "game:re_chunk_000.pak.patch_{next}.pak")
        #expect(re4.kind("loose")?.unit == .tree && re4.kind("loose")?.stripTo == "natives")
        #expect(re4.loadOrder.format == .deployOrder && re4.loadOrder.pinLastGroups == ["pak"])
        #expect(re4.archive.variants == "modinfo.ini" && re4.framework("reframework")?.skip.count == 2)
        #expect(re4.framework("reframework")?.settings.first?.format == .keyValue)
        // Steam Cloud keeps RE4's saves under `userdata/<account>/2050650/`, and a profile can't name the account: the
        // entry lists no saves, so the app backs up the folder the save locator found instead.
        #expect(re4.logs[1].exists?.action == .disableNewestMod && re4.saves.isEmpty)

        let stardew = try #require(list.profile(covering: "gog:1453375253"))
        #expect(stardew.game == "steam:413150" && stardew.runtime == .native)
        let smapi = try #require(stardew.framework("smapi"))
        #expect(smapi.pick.first?.unpack == true && smapi.copyAs.first?.to == "game:StardewModdingAPI.deps.json")
        #expect(smapi.launch?.redirect?.instead == "Stardew Valley" && smapi.launch?.redirect?.run == "StardewModdingAPI" && smapi.launch?.loader == nil)
        #expect(smapi.settings.isEmpty && smapi.dllOverrides.isEmpty && smapi.download.tag == "4.5.2" && smapi.download.sha256?.count == 64)
        let mod = try #require(stardew.kind("mod"))
        #expect(mod.codeIf == "manifest.EntryDll" && mod.enable?.format == .dotPrefix && mod.enable?.file == nil && mod.keepOnUpdate == ["config.json"])
        #expect(stardew.loadOrder.format == .dependencies && !stardew.loadOrder.isReorderable)
        #expect(stardew.conflicts.samePath == .block && stardew.conflicts.needs?.field == "manifest.ContentPackFor.UniqueID")
        #expect(stardew.archive.reject.map(\.onlyFile) == [false, false, false, true] && stardew.archive.reject[1].unlessNearby == "manifest.json")
        #expect(stardew.logs.first?.summary == .smapi && stardew.saves == [SaveSource(root: .home, path: ".config/StardewValley/Saves")])
        #expect(!stardew.notes.cleanupOnLastCodeMod)

        let rdr2 = try #require(list.profile(covering: "steam:1174180"))
        #expect(rdr2.status == .experimental && rdr2.sources.other.count == 2)
        #expect(rdr2.framework("scripthookrdr2")?.download.kind == .url && rdr2.framework("scripthookrdr2")?.download.viaBrowser == true)
        #expect(rdr2.framework("lml")?.requires == ["scripthookrdr2"] && rdr2.framework("lml")?.pick.last?.stripTo == "lml")
        #expect(rdr2.loadOrder.format == .lml && rdr2.loadOrder.file == "game:lml/mods.xml" && rdr2.loadOrder.pinLast == ["Online Content Unlocker", "Red Dead Offline"])
        #expect(rdr2.online.policy == .storyOnly && rdr2.online.noticeKey == "storyOnly" && rdr2.online.playWithoutModsRemoves.count == 5)

        let elden = try #require(list.profile(covering: "steam:1245620"))
        let me3 = try #require(elden.framework("me3"))
        #expect(me3.pick.count == 1 && me3.pick[0].match == "bin/**|LICENSE-*" && me3.pick[0].to == "tools:me3/" && !me3.pick[0].unpack)
        #expect(me3.download.tag == "v0.13.0" && me3.download.sha256 != nil, "the hash pins the release, so does the tag")
        #expect(me3.components == ["installVCRuntime"] && me3.componentActions == [.installVCRuntime])
        #expect(me3.launch?.loader?.exe == "tools:me3/bin/me3.exe" && me3.launch?.loader?.config == "me3" && me3.launch?.loader?.steamInBottle == true)
        #expect(me3.launch?.loader?.args.contains("{config}") == true)
        #expect(elden.kind("package")?.stripToParentOf?.hasPrefix("regulation.bin|") == true && elden.kind("me2import")?.importer == "modengine2")
        #expect(elden.kinds.allSatisfy { $0.to.hasPrefix("store:") && $0.order == .config })
        #expect(elden.loadOrder.format == .loaderConfig && elden.loadOrder.config == "me3" && elden.loadOrder.file == "store:sommelier.me3")
        #expect(elden.online.policy == .offlineOnly && elden.online.antiCheat == "eac" && elden.online.moddedLaunch == .loader)
        #expect(elden.online.forbidsPlainLaunchWithMods && elden.online.separateSave?.enabled == true && elden.online.separateSave?.file == "ER0000_sommelier.sl2")
        #expect(elden.online.cleanBeforeVanilla.count == 6 && elden.archive.deny.contains("**/SeamlessCoop/**"))
    }

    @Test func unknownValuesDropOnlyTheirEntry() throws {
        let json = """
        { "version": 1, "games": [
          { "game": "steam:1", "status": "ready", "runtime": "wine", "futureField": { "x": 1 },
            "kinds": [ { "id": "pak", "unit": "file", "match": "**/*.pak", "to": "game:", "futureFlag": true } ] },
          { "game": "steam:2", "status": "ready", "runtime": "wine", "loadOrder": { "format": "witcher3" } },
          { "game": "steam:3", "status": "ready", "runtime": "wine", "kinds": [ { "id": "x", "unit": "bundle", "match": "*", "to": "game:" } ] },
          { "game": "steam:4", "status": "ready", "runtime": "wine", "online": { "policy": "sometimes" } },
          { "game": "steam:5", "status": "ready", "runtime": "wine",
            "frameworks": [ { "id": "f", "name": "F", "download": { "kind": "torrent", "url": "x" } } ] },
          { "game": "steam:6", "status": "ready", "runtime": "wine",
            "frameworks": [ { "id": "f", "name": "F", "download": { "kind": "github", "repo": "a/b", "asset": "c.zip" }, "components": ["installEverything"] } ] },
          { "game": "steam:7", "status": "beta", "runtime": "wine" },
          { "game": "steam:8" }
        ] }
        """
        let list = try JSONDecoder().decode(ModsList.self, from: Data(json.utf8))
        #expect(list.games.map(\.game) == ["steam:1", "steam:8"])
        let first = try #require(list.games.first)
        #expect(first.kinds.first?.order == ModKind.Order.none && first.loadOrder.format == LoadOrderSpec.Format.none && first.online.policy == .allowed)
        #expect(first.archive.wrappers && first.conflicts.samePath == .warn && first.notes.cleanupOnLastCodeMod)
        // An entry that says nothing is treated as still being tried out.
        #expect(list.games.last?.status == .experimental && list.games.last?.runtime == .wine)
    }

    @Test func rootsOfAWineCopy() throws {
        let home = scratch("wine")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let bottle = Bottle(kind: .steam, paths: paths)
        let profile = bottle.driveC.appendingPathComponent("users/crossover")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let install = home.appendingPathComponent("Games/Hogwarts Legacy")
        let macHome = home.appendingPathComponent("mac-home")
        let roots = ModRoots(game: game("990080", at: install), bottle: bottle, paths: paths, home: macHome)

        #expect(place(roots, "game:Phoenix/Binaries/Win64/") == install.appendingPathComponent("Phoenix/Binaries/Win64").path)
        #expect(place(roots, "game:") == install.path)
        #expect(place(roots, "game:Phoenix\\Content\\Paks\\~mods\\{slot}\\") == install.appendingPathComponent("Phoenix/Content/Paks/~mods/{slot}").path)
        #expect(place(roots, "appdata:Hogwarts Legacy/Saved/Logs/Phoenix.log") == profile.appendingPathComponent("AppData/Local/Hogwarts Legacy/Saved/Logs/Phoenix.log").path)
        #expect(place(roots, "roaming:EldenRing") == profile.appendingPathComponent("AppData/Roaming/EldenRing").path)
        #expect(place(roots, "documents:Hogwarts Legacy/Mods") == profile.appendingPathComponent("Documents/Hogwarts Legacy/Mods").path)
        #expect(place(roots, "tools:me3/bin/me3.exe") == home.appendingPathComponent("Tools/me3/bin/me3.exe").path)
        #expect(place(roots, "store:sommelier.me3") == home.appendingPathComponent("Mods/steam-990080/sommelier.me3").path)
        #expect(place(roots, "home:.config/StardewValley") == macHome.appendingPathComponent(".config/StardewValley").path)
        #expect(roots.resolve("appdata:garyttierney/me3/logs/*.log")?.lastPathComponent == "*.log")

        // Nothing leaves a root, and only the roots the profile knows are accepted.
        #expect(roots.resolve("game:../../Library/x.dll") == nil)
        #expect(roots.resolve("game:Phoenix/./Binaries") == nil)
        #expect(roots.resolve("game:/etc/passwd") == nil)
        #expect(roots.resolve("game:C:\\Windows\\x.dll") == nil)
        #expect(roots.resolve("steam:x") == nil)
        #expect(roots.resolve("Phoenix/Binaries") == nil)
        #expect(ModPath("game:a/b")?.spec == "game:a/b" && ModPath("store:")?.components.isEmpty == true)

        // A copy that isn't installed, or has no bottle, has no game folder and no Windows folders.
        let bare = ModRoots(game: game("990080"), bottle: nil, paths: paths, home: macHome)
        #expect(bare.resolve("game:") == nil && bare.resolve("appdata:x") == nil && bare.resolve("tools:me3") != nil)
    }

    @Test func rootsOfANativeApp() throws {
        let home = scratch("native")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let install = home.appendingPathComponent("steamapps/common/Stardew Valley")
        let binaries = install.appendingPathComponent("Stardew Valley.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let macHome = home.appendingPathComponent("mac-home")
        let roots = ModRoots(game: game("413150", native: true, at: install), bottle: nil, paths: paths, home: macHome)

        #expect(place(roots, "game:") == binaries.path)
        #expect(place(roots, "game:Mods/{name}/") == binaries.appendingPathComponent("Mods/{name}").path)
        #expect(place(roots, "game:StardewModdingAPI.deps.json") == binaries.appendingPathComponent("StardewModdingAPI.deps.json").path)
        #expect(place(roots, "home:.config/StardewValley/ErrorLogs/SMAPI-latest.txt") == macHome.appendingPathComponent(".config/StardewValley/ErrorLogs/SMAPI-latest.txt").path)
        #expect(place(roots, "documents:x") == macHome.appendingPathComponent("Documents/x").path)
        #expect(roots.resolve("appdata:x") == nil && roots.resolve("roaming:x") == nil)
        #expect(place(roots, "store:") == home.appendingPathComponent("Mods/steam-413150").path)

        // The .app itself as the install path works too; a folder without one has no game root.
        let direct = ModRoots(game: game("413150", native: true, at: install.appendingPathComponent("Stardew Valley.app")), bottle: nil, paths: paths, home: macHome)
        #expect(place(direct, "game:") == binaries.path)
        let empty = ModRoots(game: game("413150", native: true, at: home), bottle: nil, paths: paths, home: macHome)
        #expect(empty.resolve("game:") == nil)
    }

    @Test func runtimeDecidesWhichCopyAProfileServes() throws {
        let list = try fixtureList()
        let stardew = try #require(list.profile(covering: "steam:413150"))
        #expect(stardew.applies(to: game("413150", native: true)))
        #expect(stardew.applies(to: game("1453375253", store: .gog, native: true)))
        #expect(!stardew.applies(to: game("413150")))
        #expect(!stardew.applies(to: game("990080", native: true)))

        let hogwarts = try #require(list.profile(covering: "steam:990080"))
        #expect(hogwarts.applies(to: game("990080")))
        #expect(!hogwarts.applies(to: game("990080", native: true)))

        #expect(list.profile(for: game("413150", native: true))?.game == "steam:413150")
        #expect(list.profile(for: game("413150")) == nil)
        #expect(list.profile(for: game("990080", native: true)) == nil)
        #expect(list.profile(for: game("1245620"))?.game == "steam:1245620")

        #expect(ModProfile.Runtime.any.serves(native: true) && ModProfile.Runtime.any.serves(native: false))
        #expect(ModProfile.Runtime.wine.serves(native: false) && !ModProfile.Runtime.wine.serves(native: true))
    }

    @Test func homeIsASaveRootAndAConfigRoot() throws {
        let box = try SaveSandbox()
        let roots = SaveRoots(profile: box.url("users/me"), steamUserdata: box.url("steam/userdata"), install: box.url("game"), home: box.url("mac-home"))
        let saves = SaveSource(root: .home, path: ".config/StardewValley/Saves")
        #expect(roots.base(.home) == box.url("mac-home"))
        #expect(roots.resolve(saves)?.path == box.url("mac-home/.config/StardewValley/Saves").path)
        #expect(saves.displayPath == "Home folder/.config/StardewValley/Saves")
        #expect(SaveSource(root: .roaming, path: "EldenRing").displayPath == "AppData\\Roaming\\EldenRing")
        // Only a profile names a home source: a folder the player picks is never anchored to the whole home.
        try box.folder("mac-home/Desktop/Saves")
        #expect(roots.source(for: box.url("mac-home/Desktop/Saves")) == nil)
        #expect(try JSONDecoder().decode(SaveRoot.self, from: Data("\"home\"".utf8)) == .home)

        #expect(GameConfigFile("home:.config/StardewValley/x.ini")?.root == .home)
        #expect(GameConfigFile("home:../x.ini") == nil)
    }
}
