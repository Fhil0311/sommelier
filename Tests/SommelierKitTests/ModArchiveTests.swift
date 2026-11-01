// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

/// Archive plans on made-up layouts, against the five profiles of the fixture.
struct ModArchiveTests {
    private func profile(_ id: String) throws -> ModProfile {
        let url = try #require(Bundle.module.url(forResource: "mods", withExtension: "json", subdirectory: "Fixtures"))
        let list = try JSONDecoder().decode(ModsList.self, from: try Data(contentsOf: url))
        return try #require(list.profile(covering: id))
    }

    private var hogwarts: ModProfile { get throws { try profile("steam:990080") } }
    private var re4: ModProfile { get throws { try profile("steam:2050650") } }
    private var stardew: ModProfile { get throws { try profile("steam:413150") } }
    private var rdr2: ModProfile { get throws { try profile("steam:1174180") } }
    private var eldenRing: ModProfile { get throws { try profile("steam:1245620") } }

    /// Source → destination of every file of a unit, for short checks.
    private func placed(_ unit: ModPlan.Unit) -> [String: String] {
        Dictionary(uniqueKeysWithValues: unit.files.map { ($0.source, $0.destination) })
    }

    @Test func wrapperFolderComesOff() throws {
        let plan = ModArchive.plan(paths: ["CoolMod/", "CoolMod/zCool_P.pak", "CoolMod/zCool_P.ucas", "CoolMod/zCool_P.utoc",
                                           "__MACOSX/CoolMod/._zCool_P.pak", "CoolMod/.DS_Store", "CoolMod/README.txt"], profile: try hogwarts)
        #expect(plan.isReady && plan.refusal == nil && plan.questions.isEmpty)
        #expect(plan.notes == [.wrapperRemoved("CoolMod")])
        let unit = try #require(plan.units.first)
        #expect(plan.units.count == 1 && unit.kind.id == "pak" && unit.name == "zCool_P" && !unit.code && unit.framework == nil)
        #expect(placed(unit) == ["zCool_P.pak": "game:Phoenix/Content/Paks/~mods/{slot}/zCool_P.pak",
                                 "zCool_P.ucas": "game:Phoenix/Content/Paks/~mods/{slot}/zCool_P.ucas",
                                 "zCool_P.utoc": "game:Phoenix/Content/Paks/~mods/{slot}/zCool_P.utoc"])
        #expect(unit.files.allSatisfy(\.needsSlot) && !plan.containsCode && plan.frameworks.isEmpty)
        #expect(plan.leftovers.isEmpty)

        // A folder the kinds look for by name is the layout, not a wrapper; a file at the root means no wrapper.
        let tree = ModArchive.plan(paths: ["reframework/autorun/_ScriptCore.lua"], profile: try re4)
        #expect(tree.notes.isEmpty && tree.units.first?.kind.id == "script" && tree.units.first?.code == true)
        #expect(tree.units.first?.files.first?.destination == "game:reframework/autorun/_ScriptCore.lua")
        let flat = ModArchive.plan(paths: ["Install notes.txt", "Mod/zX_P.pak", "Mod/zX_P.ucas", "Mod/zX_P.utoc"], profile: try hogwarts)
        #expect(flat.notes.isEmpty && flat.units.count == 1 && flat.leftovers == ["Install notes.txt"])
        // Backslashes and "./" are read as folders too.
        let windows = ModArchive.plan(paths: [".\\Mod\\zX_P.pak", "Mod\\zX_P.ucas", "./Mod/zX_P.utoc"], profile: try hogwarts)
        #expect(windows.isReady && windows.units.first?.files.map(\.source) == ["zX_P.pak", "zX_P.ucas", "zX_P.utoc"])
    }

    @Test func twoVariantsAreAQuestion() throws {
        let paths = ["Max Stacks/999/modinfo.ini", "Max Stacks/999/natives/STM/_Chainsaw/Item.user.2",
                     "Max Stacks/9999/modinfo.ini", "Max Stacks/9999/natives/STM/_Chainsaw/Item.user.2", "Max Stacks/screenshot.png"]
        let asked = ModArchive.plan(paths: paths, profile: try re4)
        #expect(asked.questions == [.variant(options: ["999", "9999"])] && asked.units.isEmpty && asked.refusal == nil && !asked.isReady)

        let answered = ModArchive.plan(paths: paths, profile: try re4, answers: .init(variant: "9999"))
        #expect(answered.isReady && answered.notes == [.wrapperRemoved("Max Stacks"), .variantChosen("9999")])
        let unit = try #require(answered.units.first)
        #expect(unit.kind.id == "loose" && unit.name == "9999" && unit.framework == "reframework" && !unit.code)
        #expect(placed(unit) == ["natives/STM/_Chainsaw/Item.user.2": "game:natives/STM/_Chainsaw/Item.user.2"])
        #expect(answered.leftovers == ["modinfo.ini"] && answered.frameworks == ["reframework"])

        // One variant marker is just the mod's own; the answer to a question not asked changes nothing.
        let single = ModArchive.plan(paths: ["No Paint/modinfo.ini", "No Paint/natives/STM/x.tex.143221028"], profile: try re4, answers: .init(variant: "nope"))
        #expect(single.isReady && single.questions.isEmpty && single.units.first?.name == "No Paint")
    }

    @Test func executableIsRefused() throws {
        let plan = ModArchive.plan(paths: ["Mod Merger/HogwartsModMerger.exe", "Mod Merger/readme.txt", "Mod Merger/zMerged_P.pak"], profile: try hogwarts)
        #expect(plan.refusal == .init(reason: .rejected("executable"), path: "HogwartsModMerger.exe"))
        #expect(plan.units.isEmpty && !plan.isReady)
        let save = ModArchive.plan(paths: ["HL-00-00.sav"], profile: try hogwarts)
        #expect(save.refusal?.reason == .rejected("saveFile"))
        // A launcher the deny list names is left out before the reject rules see it (Convergence ships one).
        let denied = ModArchive.plan(paths: ["ConvergenceER/modengine2_launcher.exe", "ConvergenceER/regulation.bin"], profile: try eldenRing)
        #expect(denied.refusal == nil && denied.notes.contains(.denied("modengine2_launcher.exe")) && denied.units.count == 1)
    }

    @Test func deniedLoaderCopyIsSkippedWithANote() throws {
        let plan = ModArchive.plan(paths: ["LST.asi", "lst.ini", "version.dll"], profile: try rdr2)
        #expect(plan.isReady && plan.notes == [.denied("version.dll")])
        let unit = try #require(plan.units.first)
        #expect(unit.kind.id == "asi" && unit.name == "LST" && unit.code && unit.framework == "scripthookrdr2")
        #expect(placed(unit) == ["LST.asi": "game:LST.asi", "lst.ini": "game:lst.ini"])
        #expect(plan.containsCode && plan.frameworks == ["scripthookrdr2"])

        // A whole denied folder, and nothing else: refused as nothing recognised, with the notes kept.
        let seamless = ModArchive.plan(paths: ["SeamlessCoop/ersc.dll", "SeamlessCoop/ersc_settings.ini", "ersc_launcher.exe"], profile: try eldenRing)
        #expect(seamless.refusal?.reason == .nothingRecognised && seamless.notes.count == 3)
    }

    @Test func tripleWithoutUtocIsAnError() throws {
        let plan = ModArchive.plan(paths: ["zOldStyle_P.pak", "zOldStyle_P.ucas"], profile: try hogwarts)
        #expect(plan.refusal == .init(reason: .incompleteTriple, path: "zOldStyle_P.pak") && plan.units.isEmpty)
        // Two triples, each complete, in one archive; a LogicMods triple goes to its own folder and needs UE4SS.
        let two = ModArchive.plan(paths: ["zA_P.pak", "zA_P.ucas", "zA_P.utoc", "LogicMods/Thing.pak", "LogicMods/Thing.ucas", "LogicMods/Thing.utoc"], profile: try hogwarts)
        #expect(two.units.map(\.kind.id) == ["logic", "pak"] && two.units.map(\.name) == ["Thing", "zA_P"])
        #expect(two.units[0].files.first?.destination == "game:Phoenix/Content/Paks/LogicMods/Thing.pak" && two.frameworks == ["ue4ss"])
    }

    @Test func pathTraversalIsRefused() throws {
        for bad in ["../zX_P.pak", "Mod/../../x.pak", "/etc/passwd", "C:\\Windows\\x.dll", "Mod/./x.pak"] {
            let plan = ModArchive.plan(paths: ["zA_P.pak", "zA_P.ucas", "zA_P.utoc", bad], profile: try hogwarts)
            #expect(plan.refusal == .init(reason: .unsafePath, path: bad), "\(bad)")
            #expect(plan.units.isEmpty)
        }
        #expect(ModArchive.plan(paths: ["__MACOSX/x", "Thumbs.db"], profile: try hogwarts).refusal?.reason == .empty)
        #expect(ModArchive.plan(paths: [], profile: try hogwarts).refusal?.reason == .empty)
    }

    @Test func siblingsComeWithAnAsi() throws {
        let plan = ModArchive.plan(paths: ["Rampage.asi", "Rampage.ini", "RampageFiles/Settings.json", "RampageFiles/Log/.keep", "Other.ini", "readme.txt"], profile: try rdr2)
        let unit = try #require(plan.units.first)
        #expect(plan.units.count == 1 && unit.name == "Rampage")
        #expect(placed(unit) == ["Rampage.asi": "game:Rampage.asi", "Rampage.ini": "game:Rampage.ini",
                                 "RampageFiles/Settings.json": "game:RampageFiles/Settings.json", "RampageFiles/Log/.keep": "game:RampageFiles/Log/.keep"])
        #expect(plan.leftovers == ["Other.ini"])

        // Hogwarts' .asi fix: the proxy inside is denied, the .asi and its ini land in Win64.
        let fix = ModArchive.plan(paths: ["version.dll", "HogwartsLegacyFix.asi", "HogwartsLegacyFix.ini"], profile: try hogwarts)
        #expect(fix.notes == [.denied("version.dll")] && fix.frameworks == ["asiloader"])
        #expect(fix.units.first?.files.map(\.destination) == ["game:Phoenix/Binaries/Win64/HogwartsLegacyFix.asi", "game:Phoenix/Binaries/Win64/HogwartsLegacyFix.ini"])

        // Without `siblings` a file kind takes just the file; a file destination takes `to` itself, with `{next}`.
        let pak = ModArchive.plan(paths: ["Mod/BetterLeon.pak", "Mod/modinfo.ini"], profile: try re4)
        let pakUnit = try #require(pak.units.first)
        #expect(pakUnit.kind.id == "pak" && pakUnit.files == [.init(source: "BetterLeon.pak", destination: "game:re_chunk_000.pak.patch_{next}.pak", skipped: false)])
        #expect(pakUnit.files.first?.needsNext == true && pak.leftovers == ["modinfo.ini"])
    }

    @Test func treeIsStrippedToItsMarkerFolder() throws {
        let plan = ModArchive.plan(paths: ["No Yellow Paint/modinfo.ini", "No Yellow Paint/screenshot.jpg",
                                           "No Yellow Paint/natives/STM/_Chainsaw/Environment/paint.tex.143221028",
                                           "No Yellow Paint/natives/STM/_Chainsaw/Environment/paint.mesh.221108797"], profile: try re4)
        #expect(plan.isReady && plan.notes == [.wrapperRemoved("No Yellow Paint")])
        let unit = try #require(plan.units.first)
        // The wrapper's name is kept for the mod when the unit sits at the archive's root.
        #expect(unit.kind.id == "loose" && unit.name == "No Yellow Paint" && unit.root.isEmpty && unit.framework == "reframework")
        #expect(unit.files.map(\.destination) == ["game:natives/STM/_Chainsaw/Environment/paint.mesh.221108797", "game:natives/STM/_Chainsaw/Environment/paint.tex.143221028"])
        #expect(plan.leftovers == ["modinfo.ini", "screenshot.jpg"])

        // Deeper: the mod folder sits two levels down; a Lua script next to it goes to its own kind.
        let nested = ModArchive.plan(paths: ["Pack/ModA/natives/STM/a.user.2", "Pack/ModB/natives/STM/b.user.2", "Pack/hud.lua"], profile: try re4)
        #expect(nested.units.map(\.name) == ["ModA", "ModB", "hud"] && nested.units.map(\.kind.id) == ["loose", "loose", "lua"])
        #expect(nested.units[2].files.first?.destination == "game:reframework/autorun/hud.lua")

        // A file the framework can't run under Wine is planned as skipped, with a note.
        let d2d = ModArchive.plan(paths: ["reframework/plugins/reframework-d2d.dll", "reframework/autorun/Health_Bars.lua"], profile: try re4)
        let script = try #require(d2d.units.first)
        #expect(script.files == [.init(source: "reframework/autorun/Health_Bars.lua", destination: "game:reframework/autorun/Health_Bars.lua", skipped: false),
                                 .init(source: "reframework/plugins/reframework-d2d.dll", destination: "game:reframework/plugins/reframework-d2d.dll", skipped: true)])
        #expect(d2d.notes == [.skipped("reframework/plugins/reframework-d2d.dll", framework: "reframework")])

        // A movie goes from `Movies/` on, with its game-folder prefix stripped, whatever the archive wraps it in.
        let movie = ModArchive.plan(paths: ["Phoenix/Content/Movies/Intro/WB_Logo.bk2"], profile: try hogwarts)
        #expect(movie.units.first?.kind.id == "movie" && movie.units.first?.files.first?.destination == "game:Phoenix/Content/Movies/Intro/WB_Logo.bk2")
        #expect(movie.units.first?.kind.backupOriginal == true)
    }

    @Test func folderUnitsByMarkerAndCodeByManifest() throws {
        let csharp = Data(#"{"Name": "SVE Code", "UniqueID": "FlashShifter.SVECode", "EntryDll": "StardewValleyExpanded.dll"}"#.utf8)
        let pack = Data(#"{"Name": "SVE", "UniqueID": "FlashShifter.StardewValleyExpandedCP", "ContentPackFor": {"UniqueID": "Pathoschild.ContentPatcher"}}"#.utf8)
        let paths = ["Stardew Valley Expanded/Stardew Valley Expanded Code/manifest.json", "Stardew Valley Expanded/Stardew Valley Expanded Code/StardewValleyExpanded.dll",
                     "Stardew Valley Expanded/[CP] Stardew Valley Expanded/manifest.json", "Stardew Valley Expanded/[CP] Stardew Valley Expanded/content.json",
                     "Stardew Valley Expanded/[CP] Stardew Valley Expanded/assets/Maps/Town.xnb",
                     "Stardew Valley Expanded/[FTM] Stardew Valley Expanded/manifest.json", "Stardew Valley Expanded/[FTM] Stardew Valley Expanded/content.json",
                     "Stardew Valley Expanded/__folder_managed_by_vortex"]
        let plan = ModArchive.plan(paths: paths, profile: try stardew,
                                   manifests: ["Stardew Valley Expanded Code/manifest.json": csharp, "[CP] Stardew Valley Expanded/manifest.json": pack])
        #expect(plan.isReady && plan.notes == [.wrapperRemoved("Stardew Valley Expanded")])
        #expect(plan.units.map(\.name) == ["Stardew Valley Expanded Code", "[CP] Stardew Valley Expanded", "[FTM] Stardew Valley Expanded"])
        // A C# mod is code, a content pack isn't, and without its manifest a mod is taken for code to be safe.
        #expect(plan.units.map(\.code) == [true, false, true])
        #expect(plan.units[1].files.map(\.destination) == ["game:Mods/[CP] Stardew Valley Expanded/assets/Maps/Town.xnb", "game:Mods/[CP] Stardew Valley Expanded/content.json",
                                                            "game:Mods/[CP] Stardew Valley Expanded/manifest.json"])
        #expect(plan.frameworks == ["smapi"] && plan.leftovers.isEmpty)

        // A single mod folder: the folder's name stays although it is the one wrapper.
        let single = ModArchive.plan(paths: ["ContentPatcher/manifest.json", "ContentPatcher/ContentPatcher.dll"], profile: try stardew, archiveName: "Content Patcher 2.9.1")
        #expect(single.units.map(\.name) == ["ContentPatcher"] && single.units.first?.files.first?.destination == "game:Mods/ContentPatcher/ContentPatcher.dll")
        // A manifest at the very root takes the archive's name; a leading dot would read as "off" to SMAPI.
        let bare = ModArchive.plan(paths: ["manifest.json", "Mod.dll"], profile: try stardew, archiveName: ".Lookup Anything 1.55.0")
        #expect(bare.units.first?.name == "Lookup Anything 1.55.0" && bare.units.first?.files.first?.destination == "game:Mods/Lookup Anything 1.55.0/Mod.dll")
        // Not mods: a config on its own, an XNB with no manifest above it; an XNB inside a mod is fine (above).
        #expect(ModArchive.plan(paths: ["config.json"], profile: try stardew).refusal?.reason == .rejected("configOnly"))
        #expect(ModArchive.plan(paths: ["Lizard Girl XNB/Characters/Abigail.xnb"], profile: try stardew).refusal == .init(reason: .rejected("legacyFormat"), path: "Characters/Abigail.xnb"))
        #expect(ModArchive.plan(paths: ["assets/Locations/Interiors.tmx"], profile: try stardew).refusal?.reason == .nothingRecognised)

        // LML: the archive already starts with `lml/`, and the marker folder is the unit.
        let lml = ModArchive.plan(paths: ["lml/WhyEm's DLC/install.xml", "lml/WhyEm's DLC/Item_Catalog/catalog.ymt"], profile: try rdr2)
        #expect(lml.units.first?.name == "WhyEm's DLC" && lml.units.first?.files.map(\.destination) == ["game:lml/WhyEm's DLC/Item_Catalog/catalog.ymt", "game:lml/WhyEm's DLC/install.xml"])
        #expect(!(lml.units.first?.code ?? true) && lml.frameworks == ["lml"])
    }

    @Test func ambiguousKindAsksFirst() throws {
        let asked = ModArchive.plan(paths: ["Engine.ini"], profile: try hogwarts)
        #expect(asked.questions == [.kind(id: "ini", files: ["Engine.ini"])] && asked.units.isEmpty && asked.refusal == nil)
        let yes = ModArchive.plan(paths: ["Engine.ini"], profile: try hogwarts, answers: .init(kinds: ["ini": true]))
        #expect(yes.isReady && yes.units.first?.files.first?.destination == "appdata:Hogwarts Legacy/Saved/Config/WindowsNoEditor/Engine.ini")
        let no = ModArchive.plan(paths: ["Engine.ini"], profile: try hogwarts, answers: .init(kinds: ["ini": false]))
        #expect(no.refusal?.reason == .nothingRecognised)

        // RDR2: bare stream files are asked about, and the question doesn't stop the other units.
        let stream = ModArchive.plan(paths: ["Horse.asi", "textures/horse.ytd"], profile: try rdr2)
        #expect(stream.units.map(\.name) == ["Horse"] && stream.questions == [.kind(id: "stream", files: ["textures/horse.ytd"])] && !stream.isReady)
    }

    @Test func eldenRingPackagesAndNatives() throws {
        let clevers = ModArchive.plan(paths: ["Clevers Moveset/regulation.bin", "Clevers Moveset/chr/c0000.anibnd.dcx", "Clevers Moveset/parts/am_m_1000.partsbnd.dcx", "Clevers Moveset/README.md"],
                                      profile: try eldenRing)
        let package = try #require(clevers.units.first)
        #expect(clevers.units.count == 1 && package.kind.id == "package" && package.name == "Clevers Moveset" && package.framework == "me3")
        // The readme is junk by the default ignore list; the rest is the whole package from its parent folder on.
        #expect(package.files.map(\.destination) == ["store:Clevers Moveset/chr/c0000.anibnd.dcx", "store:Clevers Moveset/parts/am_m_1000.partsbnd.dcx",
                                                     "store:Clevers Moveset/regulation.bin"])
        #expect(!clevers.containsCode)

        // Two regulation.bin files in variant folders: a question; the variant's folder names the mod.
        let easy = ModArchive.plan(paths: ["Easy/regulation.bin", "Easier/regulation.bin"], profile: try eldenRing)
        #expect(easy.questions == [.variant(options: ["Easier", "Easy"])])
        let easier = ModArchive.plan(paths: ["Easy/regulation.bin", "Easier/regulation.bin"], profile: try eldenRing, answers: .init(variant: "Easier"))
        #expect(easier.units.first?.name == "Easier" && easier.units.first?.files.first?.destination == "store:Easier/regulation.bin")

        // A DLL mod with its ini, a proxy copy denied; the unit's name is the file's.
        let fps = ModArchive.plan(paths: ["mods/erfps.dll", "mods/erfps.ini", "dinput8.dll"], profile: try eldenRing)
        let native = try #require(fps.units.first)
        #expect(native.kind.id == "native" && native.name == "erfps" && native.code && fps.notes.contains(.denied("dinput8.dll")))
        #expect(native.files.map(\.destination) == ["store:erfps/erfps.dll", "store:erfps/erfps.ini"])
    }

    @Test func globDialect() {
        #expect(ModGlob.matches("**/natives/**", "natives/STM/x.tex"))
        #expect(ModGlob.matches("**/natives/**", "Mod/natives/STM/x.tex"))
        #expect(!ModGlob.matches("**/natives/**", "Mod/native/x.tex"))
        #expect(ModGlob.matches("**/*_P.pak", "zCool_P.pak") && ModGlob.matches("**/*_P.pak", "a/b/zCool_P.PAK"))
        #expect(!ModGlob.matches("**/*_P.pak", "zCool.pak"))
        #expect(ModGlob.matches("*.lua", "hud.lua") && !ModGlob.matches("*.lua", "autorun/hud.lua"))
        #expect(ModGlob.matches("**/*.{ymt,ytd,ydd,yft}", "a/horse.YTD") && !ModGlob.matches("**/*.{ymt,ytd}", "a/horse.yft"))
        #expect(ModGlob.matches("**/{regulation.bin,parts,chr}/**|**/regulation.bin", "regulation.bin"))
        #expect(ModGlob.matches("**/{regulation.bin,parts,chr}/**|**/regulation.bin", "Mod/chr/c0000.anibnd.dcx"))
        #expect(!ModGlob.matches("**/{regulation.bin,parts,chr}/**|**/regulation.bin", "Mod/sfx/x"))
        #expect(ModGlob.matches("**/Movies/**/*.bk2", "Movies/Intro.bk2") && ModGlob.matches("**/Movies/**/*.bk2", "Phoenix/Content/Movies/a/b/c.bk2"))
        #expect(ModGlob.matches("dwmapi.dll|UE4SS.dll|Mods/**", "Mods/shared/x.lua") && ModGlob.matches("dwmapi.dll|UE4SS.dll|Mods/**", "ue4ss.DLL"))
        #expect(ModGlob.matches("__MACOSX/**", "__MACOSX/._x") && ModGlob.matches("**/readme*", "Mod/README.txt"))
        #expect(ModGlob.matches("Mod\\natives\\**", "Mod/natives/x") && ModGlob.matches("Mod/natives/**", "Mod\\natives\\x"))
        #expect(ModGlob.matches("?.pak", "a.pak") && !ModGlob.matches("?.pak", "ab.pak"))
        #expect(ModGlob.matchesName("version.dll", "VERSION.DLL") && !ModGlob.matchesName("version.dll", "x/version.dll"))
        #expect(ModGlob.alternatives("a/{b,c}/{d,e}.x") == ["a/b/d.x", "a/b/e.x", "a/c/d.x", "a/c/e.x"])
        #expect(ModGlob.alternatives("a/{b,c").first == "a/{b,c")
    }
}
