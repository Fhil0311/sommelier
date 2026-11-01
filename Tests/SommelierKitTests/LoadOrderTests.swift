// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// The load order list and every way it is written into a game and read back, against the fixture profiles.
struct LoadOrderTests {
    /// A game folder, a store and the deployer joining them, all in temporary folders.
    private struct Bench {
        let game: URL, store: ModStore, deployer: ModDeployer, profile: ModProfile, files: LoadOrderFiles

        init(_ profile: ModProfile) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-order-\(UUID().uuidString)", isDirectory: true)
            game = root.appendingPathComponent("Game", isDirectory: true)
            let support = root.appendingPathComponent("Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
            store = ModStore(folder: support.appendingPathComponent("Mods/test", isDirectory: true))
            let roots = ModRoots(game: game, store: store.folder, tools: support.appendingPathComponent("Tools", isDirectory: true), home: support)
            deployer = ModDeployer(roots: roots, store: store)
            self.profile = profile
            files = LoadOrderFiles(profile: profile, deployer: deployer)
        }

        func url(_ relative: String) -> URL { URL(fileURLWithPath: game.path + "/" + relative) }
        func text(_ relative: String) -> String? { try? String(contentsOf: url(relative), encoding: .utf8) }
        func folders(_ relative: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url(relative).path)) ?? []).sorted() }

        /// A mod in the store, made from a layout planned against the profile.
        func stored(_ name: String, _ files: [String: String], enabled: Bool = true) throws -> StoredMod {
            let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("sommelier-unpacked-\(UUID().uuidString)", isDirectory: true)
            for (path, text) in files {
                let url = URL(fileURLWithPath: unpacked.path + "/" + path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let plan = ModArchive.plan(paths: Array(files.keys), profile: profile, archiveName: name)
            try #require(plan.isReady, "\(plan)")
            var mod = try store.add(name: name, plan: plan, unpacked: unpacked)
            if !enabled {
                mod.enabled = false
                try store.save(mod)
            }
            return mod
        }
    }

    /// A fixture profile, with its `loadOrder` replaced when a test wants another format on the same kinds.
    private func profile(_ id: String, loadOrder: [String: Any]? = nil) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        var data = try Data(contentsOf: url)
        if let loadOrder {
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var games = try #require(json["games"] as? [[String: Any]])
            let index = try #require(games.firstIndex { $0["game"] as? String == id })
            games[index]["loadOrder"] = loadOrder
            json["games"] = games
            data = try JSONSerialization.data(withJSONObject: json)
        }
        let list = try JSONDecoder().decode(ModsList.self, from: data)
        return try #require(list.profile(covering: id))
    }

    private func triple(_ name: String) -> [String: String] { ["\(name).pak": "pak \(name)", "\(name).ucas": "ucas", "\(name).utoc": "utoc"] }

    @Test func prefixFoldersCarryTheOrderAndReadBack() throws {
        let bench = Bench(try profile("steam:990080"))
        let a = try bench.stored("A", triple("zA_P")), b = try bench.stored("B", triple("zB_P")), c = try bench.stored("C", triple("zC_P"))
        let mods = [a, b, c]
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        #expect(order.keys == [a.key, b.key, c.key] && order.canReorder && order.items.allSatisfy { $0.pin == nil && $0.enabled })

        // The top of the list gets the highest number: Unreal mounts alphabetically and the later pak wins.
        let slots = LoadOrder.PrefixFolder.slots(for: order, mods: mods)
        #expect(slots == [a.key: "020_" + a.key, b.key: "010_" + b.key, c.key: "000_" + c.key])
        for mod in mods { try bench.deployer.deploy(mod, slot: slots[mod.key]) }
        #expect(bench.folders("Phoenix/Content/Paks/~mods") == ["000_" + c.key, "010_" + b.key, "020_" + a.key])
        #expect(LoadOrder.PrefixFolder.read(order: bench.profile.loadOrder, mods: mods, roots: bench.deployer.roots) == [a.key, b.key, c.key])
        #expect(bench.files.read(mods: mods).keys == [a.key, b.key, c.key])

        // C to the top: folders renumbered through the deployer, whose records follow.
        let moved = try #require(order.moving(c.key, to: 0))
        #expect(moved.keys == [c.key, a.key, b.key])
        try bench.files.apply(moved, mods: mods)
        #expect(bench.folders("Phoenix/Content/Paks/~mods") == ["000_" + b.key, "010_" + a.key, "020_" + c.key])
        #expect(bench.text("Phoenix/Content/Paks/~mods/020_\(c.key)/zC_P.pak") == "pak zC_P")
        #expect(bench.deployer.deployed(c.key).first == "game:Phoenix/Content/Paks/~mods/020_\(c.key)/zC_P.pak")
        #expect(bench.deployer.verify().isEmpty && LoadOrder.PrefixFolder.current(mods: mods, deployer: bench.deployer)[a.key] == "010_" + a.key)
        #expect(LoadOrder.PrefixFolder.read(order: bench.profile.loadOrder, mods: mods, roots: bench.deployer.roots) == [c.key, a.key, b.key])
        #expect(bench.files.read(mods: mods).keys == [c.key, a.key, b.key] && LoadOrder.saved(in: bench.store) == [c.key, a.key, b.key])
        // Applying the same order again changes nothing; a folder of someone else's is ignored.
        #expect(try LoadOrder.PrefixFolder.apply(moved, mods: mods, deployer: bench.deployer).isEmpty)
        try FileManager.default.createDirectory(at: bench.url("Phoenix/Content/Paks/~mods/zVortexMod"), withIntermediateDirectories: true)
        #expect(bench.files.read(mods: mods).keys == [c.key, a.key, b.key])

        // A mod installed later lands at the bottom, not on top of what the player arranged.
        let d = try bench.stored("D", triple("zD_P"))
        let withD = bench.files.read(mods: mods + [d])
        #expect(withD.keys == [c.key, a.key, b.key, d.key])
        #expect(LoadOrder.PrefixFolder.slots(for: withD, mods: mods + [d])[d.key] == "000_" + d.key)

        // Moving out of range, or a mod that isn't there, is refused.
        #expect(order.moving(a.key, to: 3) == nil && order.moving("nobody", to: 0) == nil)
        // The uninstall is still exact after the renames: only the stranger's folder is left.
        for mod in mods { try bench.deployer.remove(owner: mod.key) }
        #expect(bench.folders("Phoenix/Content/Paks/~mods") == ["zVortexMod"] && bench.deployer.owners().isEmpty)
    }

    @Test func modsTxtKeepsForeignLinesInPlace() throws {
        let bench = Bench(try profile("steam:990080"))
        let x = try bench.stored("X", ["X/Scripts/main.lua": "x", "X/enabled.txt": ""])
        let y = try bench.stored("Y", ["Y/Scripts/main.lua": "y"])
        let mods = [x, y]
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods).setting(y.key, enabled: false)

        let text = "; UE4SS mods\r\nCheatManagerEnablerMod : 1\r\nY : 1\r\nKeybinds : 1\r\nx : 0\r\n"
        let written = LoadOrder.UE4SSModsTxt.write(text, order: order, mods: mods)
        #expect(written == "; UE4SS mods\r\nCheatManagerEnablerMod : 1\r\nX : 1\r\nY : 0\r\nKeybinds : 1\r\n", "ours in order where the first of ours stood, the rest untouched")
        let read = LoadOrder.UE4SSModsTxt.read(written, mods: mods)
        #expect(read.map(\.key) == [x.key, y.key] && read.map(\.enabled) == [true, false])

        // No file yet: just our lines. Nothing of ours in it: ours go at the end.
        #expect(LoadOrder.UE4SSModsTxt.write("", order: order, mods: mods) == "X : 1\nY : 0\n")
        #expect(LoadOrder.UE4SSModsTxt.write("Keybinds : 1\n", order: order, mods: mods) == "Keybinds : 1\nX : 1\nY : 0\n")
        #expect(LoadOrder.UE4SSModsTxt.file(in: bench.profile) == "game:Phoenix/Binaries/Win64/Mods/mods.txt")

        // Through the game's file, for a profile ordered by it (Hogwarts' own format is the pak folders).
        let byFile = Bench(try profile("steam:990080", loadOrder: ["format": "ue4ssModsTxt"]))
        let modsTxt = "Phoenix/Binaries/Win64/Mods/mods.txt"
        let x2 = try byFile.stored("X", ["X/Scripts/main.lua": "x"]), y2 = try byFile.stored("Y", ["Y/Scripts/main.lua": "y"])
        try FileManager.default.createDirectory(at: byFile.url("Phoenix/Binaries/Win64/Mods"), withIntermediateDirectories: true)
        try text.write(to: byFile.url(modsTxt), atomically: true, encoding: .utf8)
        let fromFile = byFile.files.read(mods: [x2, y2])
        #expect(fromFile.keys == [y2.key, x2.key] && fromFile.canReorder, "the file's order wins over the install order")
        let flipped = try #require(fromFile.moving(x2.key, to: 0))
        try byFile.files.apply(flipped, mods: [x2, y2])
        #expect(byFile.text(modsTxt) == "; UE4SS mods\r\nCheatManagerEnablerMod : 1\r\nX : 1\r\nY : 1\r\nKeybinds : 1\r\n")
        #expect(byFile.files.read(mods: [x2, y2]).keys == [x2.key, y2.key])
    }

    @Test func deployOrderPlacesBottomFirstAndPinsPaks() throws {
        let bench = Bench(try profile("steam:2050650"))
        let path = "natives/STM/_Chainsaw/Item.user.2"
        let a = try bench.stored("A", [path: "aaa"]), b = try bench.stored("B", [path: "bbb"]), pak = try bench.stored("P", ["Cool.pak": "pak"])
        let mods = [a, b, pak]
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: [pak, a, b])
        #expect(order.keys == [a.key, b.key, pak.key] && order.item(pak.key)?.pin == .last, "the pak group is held at the bottom")
        #expect(order.moving(pak.key, to: 0) == nil && order.moving(a.key, to: 2) == nil)
        #expect(LoadOrder.DeployOrder.sequence(order) == [pak.key, b.key, a.key])

        try bench.files.apply(order, mods: mods)
        #expect(bench.deployer.owners() == [pak.key, b.key, a.key] && bench.text(path) == "aaa")
        #expect(bench.deployer.shadowed(b.key) == ["game:" + path] && bench.deployer.shadowed(a.key).isEmpty)
        #expect(bench.files.read(mods: mods).keys == [a.key, b.key, pak.key])

        // B above A: only what is out of place is placed again; the pak stays where it was.
        let swapped = try #require(order.moving(b.key, to: 0))
        #expect(try LoadOrder.DeployOrder.apply(swapped, mods: mods, deployer: bench.deployer) == [a.key, b.key])
        #expect(bench.deployer.owners() == [pak.key, a.key, b.key] && bench.text(path) == "bbb")
        #expect(bench.deployer.deployed(pak.key) == ["game:re_chunk_000.pak.patch_001.pak"] && bench.deployer.verify().isEmpty)
        #expect(bench.files.read(mods: mods).keys == [b.key, a.key, pak.key])
        #expect(try LoadOrder.DeployOrder.apply(swapped, mods: mods, deployer: bench.deployer).isEmpty)

        // A mod turned off drops out of the sequence and its file gives way.
        let off = swapped.setting(b.key, enabled: false)
        try bench.deployer.setEnabled(b, false)
        try bench.files.apply(off, mods: mods)
        #expect(bench.text(path) == "aaa" && bench.deployer.owners() == [pak.key, a.key])
    }

    @Test func lmlFileIsReversedWithPinnedModsLast() throws {
        let bench = Bench(try profile("steam:1174180"))
        let whyem = try bench.stored("WhyEm's DLC", ["WhyEmsDLC/install.xml": "<Mod/>", "WhyEmsDLC/replace/weapons.ymt": "w"])
        let unlocker = try bench.stored("Online Content Unlocker", ["Online Content Unlocker/install.xml": "<Mod/>", "Online Content Unlocker/stream/x.ytd": "y"])
        let bounties = try bench.stored("Bounties", ["Bounties/install.xml": "<Mod/>"])
        let mods = [whyem, unlocker, bounties]
        let spec = bench.profile.loadOrder
        #expect(spec.format == .lml && spec.reverse && spec.pinLast.contains("Online Content Unlocker"))

        // "Goes last" is the game's order; with later-wins that is the top of our list, pinned.
        let order = LoadOrder(spec: spec, mods: mods).setting(bounties.key, enabled: false)
        #expect(order.keys == [unlocker.key, whyem.key, bounties.key] && order.item(unlocker.key)?.pin == .first)
        #expect(order.moving(unlocker.key, to: 2) == nil && order.moving(bounties.key, to: 0) == nil)
        let moved = try #require(order.moving(bounties.key, to: 1))
        #expect(moved.keys == [unlocker.key, bounties.key, whyem.key])

        let existing = """
        <?xml version="1.0" encoding="utf-8"?>
        <ModsManager>
          <Mods>
            <Mod folder="SomeoneElse"><Name>Someone Else</Name><Enabled>true</Enabled></Mod>
            <Mod folder="WhyEmsDLC"><Name>WhyEm's DLC</Name><Enabled>true</Enabled><Overwrite>false</Overwrite></Mod>
          </Mods>
          <LoadOrder>
            <Mod>SomeoneElse</Mod>
            <Mod>WhyEmsDLC</Mod>
          </LoadOrder>
        </ModsManager>
        """
        let written = try LoadOrder.LML.write(existing, order: moved, mods: mods)
        let document = try XMLDocument(xmlString: written, options: [])
        let listed = document.rootElement()?.elements(forName: "LoadOrder").first?.elements(forName: "Mod").compactMap(\.stringValue)
        #expect(listed == ["SomeoneElse", "WhyEmsDLC", "Bounties", "Online Content Unlocker"], "ours reversed, the unlocker last, the stranger left in front")
        #expect(LoadOrder.LML.read(written, reverse: true, mods: mods) == [unlocker.key, bounties.key, whyem.key])
        #expect(LoadOrder.LML.enabled(written, folder: "Bounties") == false && LoadOrder.LML.enabled(written, folder: "WhyEmsDLC") == true)
        #expect(LoadOrder.LML.enabled(written, folder: "SomeoneElse") == true && written.contains("<Name>Someone Else</Name>"))
        #expect(document.rootElement()?.elements(forName: "Mods").first?.elements(forName: "Mod").count == 4)

        // From nothing, and through the game's file.
        let fresh = try LoadOrder.LML.write(nil, order: moved, mods: mods)
        #expect(LoadOrder.LML.read(fresh, reverse: true, mods: mods) == [unlocker.key, bounties.key, whyem.key] && fresh.hasPrefix("<?xml"))
        try bench.files.apply(moved, mods: mods)
        #expect(bench.text("lml/mods.xml") == fresh && bench.files.read(mods: mods).keys == [unlocker.key, bounties.key, whyem.key])
    }

    @Test func me3ProfileListsModsInOrderOfflineWithItsOwnSave() throws {
        let bench = Bench(try profile("steam:1245620"))
        let clevers = try bench.stored("Clever's Moveset", ["Clevers Moveset/regulation.bin": "reg", "Clevers Moveset/parts/am_m_1000.partsbnd.dcx": "parts"])
        let fps = try bench.stored("Unlock the FPS", ["erfps.dll": "MZ", "erfps.ini": "[fps]"])
        let toml = """
        [modengine]
        debug = false
        external_dlls = [ "ConvergenceDLL.dll", "D:\\\\Tools\\\\elsewhere.dll" ]

        [extension.mod_loader]
        enabled = true
        loose_params = false
        mods = [
            { enabled = true, name = "convergence", path = "mod" },
            { enabled = false, name = "old", path = "mod_old" }
        ]
        """
        let convergence = try bench.stored("The Convergence", ["ConvergenceER/config_eldenring.toml": toml, "ConvergenceER/mod/regulation.bin": "creg",
                                                               "ConvergenceER/mod/parts/x.dcx": "p", "ConvergenceER/ConvergenceDLL.dll": "MZ",
                                                               "ConvergenceER/modengine2_launcher.exe": "MZ"])
        #expect(convergence.units.map(\.kind.id) == ["me2import"] && convergence.units.first?.name == "ConvergenceER")
        let mods = [clevers, fps, convergence]

        #expect(bench.files.me3Entries(clevers) == [.init(kind: .package, id: "Clevers Moveset", path: "Clevers Moveset/")])
        #expect(bench.files.me3Entries(fps) == [.init(kind: .native, path: "erfps/erfps.dll")])
        #expect(bench.files.me3Entries(convergence) == [.init(kind: .package, id: "convergence", path: "ConvergenceER/mod/"),
                                                       .init(kind: .native, path: "ConvergenceER/ConvergenceDLL.dll")], "the disabled and the absolute entries are left out")

        let order = LoadOrder(spec: bench.profile.loadOrder, mods: mods)
        try bench.files.apply(order, mods: mods)
        let written = try #require(try? String(contentsOf: bench.store.folder.appendingPathComponent("sommelier.me3"), encoding: .utf8))
        let parsed = LoadOrder.Me3.read(written)
        #expect(parsed.values["savefile"] == "ER0000_sommelier.sl2" && parsed.values["start_online"] == "false" && parsed.values["profileVersion"] == "v1")
        #expect(written.contains("[[supports]]\ngame = \"eldenring\""))
        #expect(parsed.entries == [.init(kind: .package, id: "Clevers Moveset", path: "Clevers Moveset/"), .init(kind: .native, path: "erfps/erfps.dll"),
                                   .init(kind: .package, id: "convergence", path: "ConvergenceER/mod/"), .init(kind: .native, path: "ConvergenceER/ConvergenceDLL.dll")])
        #expect(bench.files.read(mods: mods).keys == [clevers.key, fps.key, convergence.key])

        // Convergence on top, the FPS mod off: the profile follows, the list remembers the mod that isn't in it.
        let moved = try #require(order.moving(convergence.key, to: 0)).setting(fps.key, enabled: false)
        try bench.files.apply(moved, mods: mods, separateSave: false)
        let again = try #require(try? String(contentsOf: bench.store.folder.appendingPathComponent("sommelier.me3"), encoding: .utf8))
        #expect(LoadOrder.Me3.read(again).values["savefile"] == nil && LoadOrder.Me3.read(again).values["start_online"] == "false")
        #expect(LoadOrder.Me3.read(again).entries.map(\.path) == ["ConvergenceER/mod/", "ConvergenceER/ConvergenceDLL.dll", "Clevers Moveset/"])
        #expect(bench.files.read(mods: mods).keys == [convergence.key, clevers.key, fps.key])
        #expect(LoadOrder.Me3.game(for: bench.profile) == "eldenring")
    }

    @Test func modEngine2ConfigIsImported() throws {
        let toml = """
        # Mod Engine 2 config
        [modengine]
        debug = false
        external_dlls = [
            'plugins\\\\cool.dll',   # relative to the launcher
            "C:\\\\Absolute\\\\nope.dll",
            "./also/fine.dll"
        ]

        [extension.mod_loader]
        enabled = true
        mods = [
            { enabled = true, name = "first", path = "mod" },
            { enabled = true, name = "second, with a comma", path = 'other\\\\mod' },
            { enabled = false, name = "off", path = "off" },
            { enabled = true, name = "escape", path = "../outside" }
        ]
        """
        let entries = LoadOrder.Me3.importModEngine2(toml, under: "ConvergenceER/")
        #expect(entries == [.init(kind: .package, id: "first", path: "ConvergenceER/mod/"),
                            .init(kind: .package, id: "second, with a comma", path: "ConvergenceER/other/mod/"),
                            .init(kind: .native, path: "ConvergenceER/plugins/cool.dll"),
                            .init(kind: .native, path: "ConvergenceER/also/fine.dll")])
        #expect(LoadOrder.Me3.importModEngine2("[modengine]\ndebug = true\n", under: "X/").isEmpty)
        #expect(LoadOrder.Me3.importModEngine2(toml, under: "").first?.path == "mod/")
    }

    @Test func pinsFollowTheProfileAndTheListIsRemembered() throws {
        let bench = Bench(try profile("steam:413150"))
        let a = try bench.stored("A", ["A/manifest.json": "{}"]), b = try bench.stored("B", ["B/manifest.json": "{}"])
        let order = LoadOrder(spec: bench.profile.loadOrder, mods: [a, b])
        #expect(!order.canReorder && order.moving(a.key, to: 1) == nil, "SMAPI sorts by dependencies itself")
        try bench.files.apply(order, mods: [a, b])
        #expect(LoadOrder.saved(in: bench.store) == [a.key, b.key])
        // A remembered order survives the mods being listed differently, and a key that is gone drops out.
        #expect(LoadOrder(spec: bench.profile.loadOrder, mods: [b, a], saved: [a.key, "gone", b.key]).keys == [a.key, b.key])
        #expect(bench.files.read(mods: [b, a]).keys == [a.key, b.key])

        // Pins by name on a reversed format put "last" on top; without reverse they stay at the bottom.
        var spec = LoadOrderSpec()
        spec.pinLast = ["a"]
        #expect(LoadOrder.pin(of: a, spec: spec) == .last && LoadOrder.pin(of: b, spec: spec) == nil)
        spec.reverse = true
        #expect(LoadOrder.pin(of: a, spec: spec) == .first)
        spec.pinFirst = ["a"]
        #expect(LoadOrder.pin(of: a, spec: spec) == .last, "pinFirst is looked at before pinLast")
    }
}
