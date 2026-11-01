// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct EALibraryTests {
    let log = """
    [2026-10-20T19:44:51.328Z]\tPID:    32\tTID:   304\tINFO    \t(eax::domain::model::content::InstallStore::updateInfos)\tIS update: set installInfo for softwareId=[e06f5056-b472-4df6-a860-77591de91b8b] baseSlug=[the-sims-4] installedStatus=[Queued]
    [2026-10-20T19:44:51.647Z]\tPID:    32\tTID:   308\tINFO    \t(eax::domain::model::content::InstallStore::updateInfos)\tIS update: set installInfo for softwareId=[Origin.SFT.50.0000848] baseSlug=[apex-legends] installedStatus=[NotInstalled]
    [2026-10-20T19:44:58.837Z]\tPID:    32\tTID:   296\tINFO    \t(eax::domain::model::content::InstallStore::updateInfos)\tIS update: set installInfo for softwareId=[e06f5056-b472-4df6-a860-77591de91b8b] baseSlug=[the-sims-4] installedStatus=[NotInstalled]
    [2026-10-20T19:45:07.657Z]\tPID:    32\tTID:   300\tINFO    \t(eax::domain::model::content::InstallStore::updateInfos)\tIS update: set installInfo for softwareId=[Origin.SFT.50.0001555] baseSlug=[glacier] installedStatus=[NotInstalled]
    [2026-10-20T19:45:07.658Z]\tPID:    32\tTID:   300\tINFO    \t(eax::domain::model::content::InstallStore::updateInfos)\tIS update: set installInfo for softwareId=[Origin.SFT.50.0001550] baseSlug=[glacier] installedStatus=[NotInstalled]
    [2026-10-20T19:45:08.000Z]\tPID:    32\tTID:   300\tINFO    \t(SPA)\tPage view event
    """

    @Test func parsesOwnedGamesFromTheLog() {
        let entries = EALibrary.parseLog(log)
        #expect(entries.map(\.slug) == ["the-sims-4", "apex-legends", "glacier"])
        #expect(entries[0].status == "NotInstalled")                       // the latest line wins
        #expect(entries[2].softwareIDs == ["Origin.SFT.50.0001555", "Origin.SFT.50.0001550"])
    }

    @Test func keepsSavedGamesAndAddsNewOnes() {
        let saved = [EALibrary.Entry(slug: "skate", softwareIDs: ["Origin.SFT.50.0001545"], status: "NotInstalled", name: "skate.™")]
        let merged = EALibrary.merged(saved, with: EALibrary.parseLog(log))
        #expect(merged.map(\.slug) == ["skate", "the-sims-4", "apex-legends", "glacier"])
        #expect(merged[0].name == "skate.™")
    }

    @Test func readsNameAndArtFromThePublicGameService() throws {
        let json = """
        {"name":"The Sims™ 4","slug":"the-sims-4",
         "packArt":{"ar2X3":"https://drop-assets.ea.com/images/a/ts4-2x3.jpg","ar16X9":"https://drop-assets.ea.com/images/a/ts4-16x9.jpg"},
         "heroImage":{"ar16X9":"https://drop-assets.ea.com/images/b/hero.jpg"}}
        """
        let info = try #require(EALibrary.parsePublicInfo(Data(json.utf8)))
        #expect(info.name == "The Sims™ 4")
        #expect(info.cover?.lastPathComponent == "ts4-2x3.jpg")
        #expect(info.hero?.lastPathComponent == "hero.jpg")
        #expect(EALibrary.parsePublicInfo(Data("{}".utf8)) == nil)
    }

    @Test func installedGamesTakeTheOwnedEntryAndTheRestAreListed() {
        let owned = [EALibrary.Entry(slug: "the-sims-4", softwareIDs: ["e06f5056"], name: "The Sims™ 4",
                                     cover: URL(string: "https://example.com/c.jpg")),
                     EALibrary.Entry(slug: "apex-legends", softwareIDs: ["Origin.SFT.50.0000848"], name: "Apex Legends")]
        let installed = [Game(store: .ea, storeID: "Origin.OFR.50.0000001", title: "The Sims 4", isInstalled: true)]
        let games = EALibrary.library(installed: installed, owned: owned)
        #expect(games.count == 2)
        let sims = games.first { $0.isInstalled }
        #expect(sims?.title == "The Sims™ 4")
        #expect(sims?.storeID == "Origin.OFR.50.0000001")                 // launch links need the installed content ID
        #expect(sims?.coverURL?.lastPathComponent == "c.jpg")
        #expect(games.first { !$0.isInstalled }?.storeID == "apex-legends")
    }

    @Test func readsTheTaskbarProgress() {
        let text = """
        [2026-10-20T19:56:40.331Z]\tPID:    32\tTID:    36\tVERBOSE \t(eax::services::windowing::ProgressManager::Impl::updateTaskbar)\tprogress: value=2, range=[0, 100], paused=false, visible=true
        [2026-10-20T19:56:45.925Z]\tPID:    32\tTID:    36\tVERBOSE \t(eax::services::windowing::ProgressManager::Impl::updateTaskbar)\tprogress: value=37, range=[0, 100], paused=true, visible=true
        [2026-10-20T19:56:46.000Z]\tPID:    32\tTID:    36\tVERBOSE \t(SPA)\tPage view event
        """
        let progress = EALibrary.parseTaskbarProgress(text)
        #expect(progress?.percent == 37)
        #expect(progress?.paused == true)
        #expect(EALibrary.parseTaskbarProgress(text + "\n(eax::services::windowing::ProgressManager::Impl::updateTaskbar)\tprogress: value=0, range=[0, 100], paused=false, visible=false") == nil)
    }

    @Test func downloadingGamesAreNotReadyToPlay() {
        let owned = [EALibrary.Entry(slug: "the-sims-4", softwareIDs: ["e06f5056"], status: "Active", name: "The Sims™ 4"),
                     EALibrary.Entry(slug: "skate", softwareIDs: ["Origin.SFT.50.0001545"], status: "Queued", name: "skate.™"),
                     EALibrary.Entry(slug: "apex-legends", softwareIDs: ["Origin.SFT.50.0000848"], status: "NotInstalled", name: "Apex Legends")]
        let installed = [Game(store: .ea, storeID: "e06f5056", title: "The Sims 4", isInstalled: true)]
        let games = EALibrary.library(installed: installed, owned: owned)
        #expect(games.allSatisfy { !$0.isInstalled })
        #expect(games.contains { $0.storeID == "the-sims-4" })

        let downloads = EALibrary.downloads(owned: owned, taskbar: (percent: 42, paused: false))
        #expect(downloads["the-sims-4"] == LauncherDownload(phase: .downloading, fraction: 0.42))
        #expect(downloads["skate"] == LauncherDownload(phase: .queued, fraction: nil))
        #expect(downloads["apex-legends"] == nil)
        #expect(EALibrary.downloads(owned: owned, taskbar: (percent: 42, paused: true))["the-sims-4"]?.phase == .paused)
    }
}
