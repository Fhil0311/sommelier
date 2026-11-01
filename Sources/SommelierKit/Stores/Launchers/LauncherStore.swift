// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A store that only works through its publisher's own Windows launcher: Ubisoft Connect, the EA app or Battle.net.
/// Like Steam, the launcher lives in an environment of its own and looks after accounts, downloads and DRM.
/// Sommelier fetches the official installer, sets the launcher up, finds the games it installed, and asks it to start
/// them.
public struct LauncherStore: Sendable, StoreProvider {
    /// The stores this type handles.
    public static let kinds: [StoreKind] = [.ea, .ubisoft, .battlenet]

    public let kind: StoreKind   // one of `kinds`
    public let paths: Paths   // Sommelier's data folders
    let wine: WineRunner

    /// `kind` must be one of `kinds`; anything else is a programming error.
    public init(kind store: StoreKind, paths: Paths) {
        precondition(Self.kinds.contains(store), "LauncherStore is for Ubisoft, EA and Battle.net")
        (kind, self.paths, wine) = (store, paths, WineRunner(paths: paths))
    }

    public var bottle: Bottle { .init(kind: kind.bottleKind, paths: paths) }

    // MARK: The launcher

    /// Where each publisher serves its current Windows installer (HTTPS, fetched at setup time).
    public var installerURL: URL { URL(string: installerAddress)! }   // fixed, well-formed addresses

    private var installerAddress: String {
        switch kind {
        case .ubisoft: return "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe"
        case .battlenet: return "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe"
        default: return "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe"
        }
    }

    /// How each installer is run unattended. Ubisoft's takes `/S`. EA's runs quietly and is told not to open the
    /// app when done. Battle.net's needs a language and a folder, then shows its own progress window.
    var installerArguments: [String] {
        switch kind {
        case .ubisoft: return ["/S"]
        case .ea: return ["/quiet", "EAX_LAUNCH_CLIENT=0"]
        case .battlenet: return ["--lang=enUS", #"--installpath=C:\Program Files (x86)\Battle.net"#]
        default: return []
        }
    }

    /// Switches for the Chromium (CEF) inside each launcher, read from the launcher's own command line. With the
    /// GPU work in a separate process, Chromium paints into windows Wine's Mac driver can't show, and the window
    /// stays blank (white for Ubisoft Connect, dark blue for the EA app). Kept in-process and composited in
    /// software, it draws.
    var launcherArguments: [String] {
        #if DEBUG
        // Lets a developer try other switches by hand.
        if ProcessInfo.processInfo.environment["SOMMELIER_DEBUG_LAUNCHER_NOFLAGS"] == "1" { return [] }
        #endif
        return ["--in-process-gpu", "--disable-gpu", "--disable-gpu-compositing"]
    }

    /// The launcher program inside the environment.
    public var launcherExecutable: URL { programLocation }

    private var programLocation: URL {
        let programFiles86 = bottle.driveC.appendingPathComponent("Program Files (x86)")
        switch kind {
        case .ubisoft: return programFiles86.appendingPathComponent("Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe")
        case .battlenet: return programFiles86.appendingPathComponent("Battle.net/Battle.net Launcher.exe")
        default: return Self.eaExecutable(in: bottle)
        }
    }

    /// The EA app installs each version into `EA Desktop\<version>\EA Desktop\` and points a junction,
    /// `EA Desktop\EA Desktop`, at the newest. Wine leaves that junction an empty folder, so the newest version folder
    /// that really holds `EADesktop.exe` is looked up instead (versions compared numerically).
    static func eaExecutable(in environment: Bottle) -> URL {
        let root = environment.driveC.appendingPathComponent("Program Files/Electronic Arts/EA Desktop")
        let inside = "EA Desktop/EADesktop.exe"
        let files = FileManager.default
        var newest: String?
        for version in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard files.fileExists(atPath: root.appendingPathComponent(version + "/" + inside).path) else { continue }
            if let best = newest, best.compare(version, options: .numeric) != .orderedAscending { continue }
            newest = version
        }
        return root.appendingPathComponent((newest ?? "EA Desktop") + "/" + inside)
    }

    public var isLauncherInstalled: Bool { FileManager.default.fileExists(atPath: self.launcherExecutable.path) }

    /// Whether anyone signed in inside the launcher; each keeps a session file of its own. Only the presence of
    /// those files is checked, as account names aren't stored readably.
    public var isSignedIn: Bool {
        let files = FileManager.default
        let usersFolder = bottle.driveC.appendingPathComponent("users")
        let accounts = ((try? files.contentsOfDirectory(atPath: usersFolder.path)) ?? []).filter { $0 != "Public" }
        return accounts.contains { account in
            let profile = usersFolder.appendingPathComponent(account)
            let local = profile.appendingPathComponent("AppData/Local")
            func listing(_ folder: URL) -> [String] { (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] }
            switch kind {
            case .ubisoft:
                let data = local.appendingPathComponent("Ubisoft Game Launcher")
                return files.fileExists(atPath: data.appendingPathComponent("user.dat").path)
                    || !listing(data.appendingPathComponent("cache/ownership")).isEmpty
            case .ea:
                let data = local.appendingPathComponent("Electronic Arts/EA Desktop")
                return listing(data).contains { $0.hasPrefix("user_") && $0.hasSuffix(".ini") }
            default:
                let config = profile.appendingPathComponent("AppData/Roaming/Battle.net/Battle.net.config")
                let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
                return text.contains("SavedAccountNames")
            }
        }
    }

    /// Signs the launcher out on this Mac by removing what it keeps to sign in by itself, in every Windows user
    /// of its environment. The launcher must not be running (it would write them back). What lists the installed
    /// games (EA's machine data, Ubisoft's settings and install records, Battle.net's agent) stays, so the games
    /// stay installed and show up again after the next sign-in.
    /// - EA app: its secure storage (`SEC`), its web profile with the login cookies (`CEF`), `cookie.ini` and the
    ///   per-account `user_<id>.ini`.
    /// - Ubisoft Connect: `ConnectSecureStorage.dat` (the remembered login), `user.dat` and the account's cached
    ///   ownership, club and activation data.
    /// - Battle.net: the saved account names and automatic sign-in in `Battle.net.config`, and its web caches.
    /// Saved Windows credentials (Wine keeps them in the registry) are removed by the caller with `credentialsKey`.
    public func forgetSignIn() {
        let files = FileManager.default
        let usersFolder = bottle.driveC.appendingPathComponent("users")
        let accounts = ((try? files.contentsOfDirectory(atPath: usersFolder.path)) ?? []).filter { $0 != "Public" && !$0.hasPrefix(".") }
        for account in accounts {
            let profile = usersFolder.appendingPathComponent(account)
            let local = profile.appendingPathComponent("AppData/Local"), roaming = profile.appendingPathComponent("AppData/Roaming")
            var doomed: [URL] = []
            switch kind {
            case .ea:
                let data = local.appendingPathComponent("Electronic Arts/EA Desktop")
                doomed = ["SEC", "CEF", "cookie.ini"].map { data.appendingPathComponent($0) }
                doomed += ((try? files.contentsOfDirectory(atPath: data.path)) ?? [])
                    .filter { $0.hasPrefix("user_") && $0.hasSuffix(".ini") }.map { data.appendingPathComponent($0) }
            case .ubisoft:
                let data = local.appendingPathComponent("Ubisoft Game Launcher")
                doomed = ["ConnectSecureStorage.dat", "user.dat", "cache/ownership", "cache/club", "cache/activations"]
                    .map { data.appendingPathComponent($0) }
            default:
                doomed = ["BrowserCaches", "CachedData.db"].map { local.appendingPathComponent("Battle.net/\($0)") }
                let config = roaming.appendingPathComponent("Battle.net/Battle.net.config")
                if let data = try? Data(contentsOf: config), let cleaned = Self.battleNetConfigSignedOut(data) {
                    try? cleaned.write(to: config, options: .atomic)
                }
            }
            for item in doomed where (try? item.checkResourceIsReachable()) == true {
                try? files.removeItem(at: item)                  // links inside are removed, never followed
            }
        }
    }

    /// Where Wine keeps the environment's saved Windows credentials (`CredWrite`); the launchers' own
    /// environments hold nothing else there.
    public static let credentialsKey = #"HKCU\Software\Wine\Credential Manager"#

    /// Battle.net's config with the saved account names and automatic sign-in taken out wherever they sit,
    /// everything else (install paths, language, window) left as it was. Nil when it isn't the expected JSON.
    static func battleNetConfigSignedOut(_ data: Data) -> Data? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func clean(_ value: Any) -> Any {
            guard let block = value as? [String: Any] else { return value }
            var kept = [String: Any]()
            for (key, inner) in block where key != "SavedAccountNames" && key != "AutoLogin" { kept[key] = clean(inner) }
            return kept
        }
        return try? JSONSerialization.data(withJSONObject: clean(root), options: [.prettyPrinted, .sortedKeys])
    }

    /// Battle.net's config for running under Sommelier: signing in automatically (with it off, Battle.net deletes its
    /// sign-in token at once, so every start asked again), and quitting when its window closes rather than hiding
    /// in the tray (tray icons stay out of the menu bar, and a second Battle.net only exits, so a hidden one could
    /// never be brought back). Values are strings, as Battle.net writes them.
    static func battleNetConfigPrepared(_ data: Data?) -> Data? {
        var root = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        var client = root["Client"] as? [String: Any] ?? [:]
        guard client["AutoLogin"] as? String != "true" || client["HideOnClose"] as? String != "false" else { return nil }
        client["AutoLogin"] = "true"
        client["HideOnClose"] = "false"
        root["Client"] = client
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private func prepareBattleNetConfig() {
        let files = FileManager.default, users = bottle.driveC.appendingPathComponent("users")
        for account in ((try? files.contentsOfDirectory(atPath: users.path)) ?? []) where account != "Public" {
            let config = users.appendingPathComponent(account).appendingPathComponent("AppData/Roaming/Battle.net/Battle.net.config")
            guard let updated = Self.battleNetConfigPrepared(try? Data(contentsOf: config)) else { continue }
            try? files.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? updated.write(to: config, options: .atomic)
        }
    }

    // MARK: Setup

    /// Longest wait for an installer, in seconds.
    static let installTimeout: TimeInterval = 900

    /// Makes the environment, downloads the official installer and runs it. Returns once the launcher's files are
    /// there; the launcher may still update itself on its first start.
    public func installLauncher(engine chosen: Engine) async throws {
        let bottles = BottleManager(paths: paths)
        try await bottles.ensure(kind.bottleKind, engine: chosen)
        // The EA app's installer runs a .NET step; without Wine Mono it stops with error 1603.
        let mono = WineMono(paths: paths)
        try await mono.ensureInstalled(in: bottle, engine: chosen)

        let (download, response) = try await URLSession.shared.download(from: installerURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let problem = "couldn't download the \(kind.displayName) installer"
            throw WineRunnerError.launchFailed(problem)
        }
        let files = FileManager.default
        let setup = paths.home.appendingPathComponent(kind.rawValue + "-setup.exe")
        try? files.removeItem(at: setup)
        try files.moveItem(at: download, to: setup)
        defer { try? files.removeItem(at: setup) }

        // Some installers never exit on their own: Battle.net's starts the client and stays, the EA app's may go
        // on to update itself. So the launcher's own files decide when the install is done. Whatever the installer
        // left running is then stopped; Sommelier starts the launcher again itself, with the switches it needs.
        let variables = WineRunner.environment(bottle: bottle, profile: LaunchProfile())
        let command = [setup.path] + installerArguments
        let installer = Task { try await ProcessRunner.run(chosen.wine, command, environment: variables) }
        let deadline = Date().addingTimeInterval(Self.installTimeout)
        while Date() < deadline {
            if isLauncherInstalled {
                try? await Task.sleep(for: .seconds(15))   // give it time to finish writing
                break
            }
            if await hasEnded(installer) { break }
            try? await Task.sleep(for: .seconds(2))
        }
        if !isLauncherInstalled { throw WineRunnerError.launchFailed("\(kind.displayName) did not install") }
        await wine.killAll(engine: chosen, bottle: bottle)
        installer.cancel()
    }

    /// Whether the installer has exited, checked without waiting more than a moment.
    private func hasEnded(_ installer: Task<ProcessResult, Error>) async -> Bool {
        await withTaskGroup(of: Bool.self) { race in
            race.addTask {
                _ = try? await installer.value
                return true
            }
            race.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            let winner = await race.next() ?? false
            race.cancelAll()
            return winner
        }
    }

    // MARK: Library

    public func refresh() async throws -> [Game] { await library() }

    private func library() async -> [Game] {
        switch kind {
        case .ubisoft:
            let registered = Self.ubisoftGames(systemReg: registry("system.reg"), bottle: bottle)
            // A registered game isn't installed until all its files are there: neither while it downloads nor
            // after a cancelled download, which leaves its files behind.
            return Self.ubisoftLibrary(installed: registered, owned: ubisoftConfigurations()).map { game in
                guard game.isInstalled, let folder = game.installPath,
                      let download = UbisoftDownloads.progress(in: folder), !download.isComplete else { return game }
                var unfinished = game
                unfinished.isInstalled = false
                return unfinished
            }
        case .battlenet:
            let installed = Self.blizzardGames(systemReg: registry("system.reg"), bottle: bottle)
            return Self.blizzardLibrary(installed: installed, owned: isSignedIn ? blizzardOwned() : [])
        default:
            let owned = await EALibrary.resolve(EALibrary.owned(in: bottle), in: bottle)
            return EALibrary.library(installed: Self.eaGames(in: bottle), owned: owned)
        }
    }

    /// One of the environment's registry files as text; empty when it can't be read.
    private func registry(_ file: String) -> String {
        (try? String(contentsOf: bottle.url.appendingPathComponent(file), encoding: .utf8)) ?? ""
    }

    /// The downloads the launcher is running, keyed by game id (Ubisoft Connect and the EA app; Battle.net shows
    /// none).
    public func downloads() -> [String: LauncherDownload] {
        var running: [String: LauncherDownload] = [:]
        switch kind {
        case .ubisoft:
            for (product, progress) in ubisoftDownloads() {
                running["\(StoreKind.ubisoft.rawValue):\(product)"] = LauncherDownload(phase: .downloading, fraction: progress.fraction)
            }
        case .ea:
            let owned = EALibrary.owned(in: bottle)
            for (slug, download) in EALibrary.downloads(owned: owned, taskbar: EALibrary.taskbarProgress(in: bottle)) {
                running["\(StoreKind.ea.rawValue):\(slug)"] = download
            }
        default:
            break
        }
        return running
    }

    /// Ubisoft Connect's unfinished downloads in its default games folder, by product id.
    func ubisoftDownloads() -> [Int: UbisoftDownloads.Progress] {
        let games = bottle.driveC.appendingPathComponent("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games")
        let states = UbisoftDownloads.installStates(userReg: registry("user.reg"))
        return UbisoftDownloads.inProgress(gamesFolder: games, installStates: states)
    }

    /// Ubisoft games bought on Steam, by Ubisoft id: the Steam app that activates each.
    public func ubisoftSteamActivations() -> [String: String] {
        guard kind == .ubisoft else { return [:] }
        var activations: [String: String] = [:]
        for entry in ubisoftConfigurations() {
            guard let steamApp = entry.steamAppID else { continue }
            activations[String(entry.uplayID)] = steamApp
        }
        return activations
    }

    /// The game configurations Ubisoft Connect cached for the first account that has any (see
    /// `UbisoftConfigurations`).
    func ubisoftConfigurations() -> [UbisoftConfigurations.Entry] {
        let usersFolder = bottle.driveC.appendingPathComponent("users")
        let relative = "AppData/Local/Ubisoft Game Launcher/cache/configuration/configurations"
        let accounts = (try? FileManager.default.contentsOfDirectory(atPath: usersFolder.path)) ?? []
        for account in accounts where account != "Public" {
            if let data = try? Data(contentsOf: usersFolder.appendingPathComponent(account + "/" + relative)) {
                return UbisoftConfigurations.parse(data)
            }
        }
        return []
    }

    /// Merges what is installed (from the registry, keyed by install id) with what the account owns (from the
    /// configurations). Installed games take the configuration's Ubisoft id, name and art; owned games that
    /// aren't installed are listed as such.
    static func ubisoftLibrary(installed: [Game], owned: [UbisoftConfigurations.Entry]) -> [Game] {
        var configurationFor: [String: UbisoftConfigurations.Entry] = [:]
        for entry in owned where configurationFor[String(entry.installID)] == nil {
            configurationFor[String(entry.installID)] = entry
        }
        func art(_ name: String?) -> URL? { name.flatMap(UbisoftConfigurations.assetURL) }

        var games: [Game] = installed.map { local in
            guard let entry = configurationFor[local.storeID] else { return local }
            return Game(store: .ubisoft, storeID: String(entry.uplayID), title: entry.name, isInstalled: true,
                        installPath: local.installPath, sizeOnDisk: local.sizeOnDisk,
                        coverURL: art(entry.thumbnail), heroURL: art(entry.background))
        }
        let installedIDs = Set(installed.map(\.storeID))
        for entry in owned where !installedIDs.contains(String(entry.installID)) {
            games.append(Game(store: .ubisoft, storeID: String(entry.uplayID), title: entry.name, isInstalled: false,
                              coverURL: art(entry.thumbnail), heroURL: art(entry.background)))
        }
        return games.inLibraryOrder()
    }

    // MARK: Reading the registry

    /// One `[key]` section of a Wine `.reg` file: its key (as written, with doubled backslashes) and its string
    /// values by lower-cased name, unescaped.
    private struct RegistrySection {
        var key: String
        var values: [String: String] = [:]
    }

    /// Splits a Wine `.reg` file into sections. Only `"name"="text"` values are kept; dwords and the like are not
    /// needed here.
    private static func sections(of reg: String) -> [RegistrySection] {
        var found: [RegistrySection] = []
        for row in reg.split(whereSeparator: \.isNewline) {
            if row.hasPrefix("[") {
                found.append(RegistrySection(key: String(row)))
                continue
            }
            guard !found.isEmpty, row.hasPrefix("\""), let separator = row.range(of: "\"=\"") else { continue }
            let name = row[row.index(after: row.startIndex)..<separator.lowerBound].lowercased()
            var text = row[separator.upperBound...]
            if text.hasSuffix("\"") { text = text.dropLast() }
            found[found.count - 1].values[name] = text.replacingOccurrences(of: #"\\"#, with: #"\"#)
        }
        return found
    }

    /// Ubisoft Connect files each install under `HKLM\Software\Wow6432Node\Ubisoft\Launcher\Installs\<id>` with an
    /// `InstallDir`. Only folders that still exist count; the title is the folder's name until the configurations
    /// supply the real one.
    static func ubisoftGames(systemReg reg: String, bottle environment: Bottle) -> [Game] {
        let prefix = #"[software\\wow6432node\\ubisoft\\launcher\\installs\\"#
        var games = [Game]()
        for section in sections(of: reg) {
            let key = section.key.lowercased()
            guard key.hasPrefix(prefix) else { continue }
            let id = section.key.dropFirst(prefix.count).prefix { $0 != "]" }
            guard !id.isEmpty, !id.contains("\\"), let installDir = section.values["installdir"],
                  let folder = environment.unixURL(forWindowsPath: installDir) else { continue }
            let title = folder.lastPathComponent
            guard !title.isEmpty, FileManager.default.fileExists(atPath: folder.path) else { continue }
            games.append(Game(store: .ubisoft, storeID: String(id), title: title, isInstalled: true,
                              installPath: folder, sizeOnDisk: GOGProvider.folderSize(folder)))
        }
        return games.inLibraryOrder()
    }

    /// Battle.net registers every game in Windows' uninstall list (`...\CurrentVersion\Uninstall\<name>`, 32- or
    /// 64-bit view) with Publisher "Blizzard Entertainment" and an InstallLocation. The Battle.net client itself is
    /// listed the same way and skipped.
    static func blizzardGames(systemReg: String, bottle: Bottle) -> [Game] {
        let uninstallKeys = [
            #"[software\\wow6432node\\microsoft\\windows\\currentversion\\uninstall\\"#,
            #"[software\\microsoft\\windows\\currentversion\\uninstall\\"#,
        ]
        var games = [Game]()
        for section in sections(of: systemReg) {
            let key = section.key.lowercased()
            guard uninstallKeys.contains(where: { key.hasPrefix($0) }),
                  section.values["publisher"]?.contains("Blizzard") == true,
                  let title = section.values["displayname"], !title.isEmpty, title != "Battle.net",
                  let location = section.values["installlocation"],
                  let folder = bottle.unixURL(forWindowsPath: location),
                  FileManager.default.fileExists(atPath: folder.path) else { continue }
            let code = blizzardCode(for: title) ?? title
            games.append(Game(store: .battlenet, storeID: code, title: title,
                              isInstalled: true, installPath: folder, sizeOnDisk: GOGProvider.folderSize(folder),
                              macBuild: blizzardMacGames.contains(code) ? .unknown : nil))
        }
        return games.inLibraryOrder()
    }

    /// The games the account owns, by product code. Battle.net keeps them only in its encrypted account database,
    /// but after each sign-in its log asks for every game account on the account ("Querying game level information
    /// for entity: (Game: EU-WTCG-<id>)"); the newest log that does is read.
    func blizzardOwned() -> [String] {
        let files = FileManager.default
        let usersFolder = bottle.driveC.appendingPathComponent("users")
        var logs: [(URL, Date)] = []
        for account in (try? files.contentsOfDirectory(atPath: usersFolder.path)) ?? [] where account != "Public" {
            let folder = usersFolder.appendingPathComponent(account + "/AppData/Local/Battle.net/Logs")
            let found = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for log in found where log.lastPathComponent.hasPrefix("battle.net-") && log.pathExtension == "log" {
                logs.append((log, (try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast))
            }
        }
        for (log, _) in logs.sorted(by: { $0.1 > $1.1 }) {
            let owned = Self.blizzardOwned(log: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
            if !owned.isEmpty { return owned }
        }
        return []
    }

    /// The product codes of the game accounts a Battle.net log asks about, in order, once each.
    static func blizzardOwned(log: String) -> [String] {
        let marker = "Querying game level information for entity: (Game: "
        var codes: [String] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: marker)?.upperBound else { continue }
            // <region>-<code>-<number>)
            let parts = line[start...].prefix { $0 != ")" }.split(separator: "-")
            guard parts.count >= 3 else { continue }
            let code = String(parts[1])
            if !codes.contains(code) { codes.append(code) }
        }
        return codes
    }

    /// Installed games plus the owned ones that aren't, which Battle.net installs from the game's page. Only games
    /// with a known title are listed.
    static func blizzardLibrary(installed: [Game], owned: [String]) -> [Game] {
        var games = installed
        let installedCodes = Set(installed.map(\.storeID))
        for code in owned where !installedCodes.contains(code) {
            guard let title = blizzardTitles[code] else { continue }
            games.append(Game(store: .battlenet, storeID: code, title: title, isInstalled: false,
                              macBuild: blizzardMacGames.contains(code) ? .unknown : nil))
        }
        return games.inLibraryOrder()
    }

    /// Blizzard games that have a Mac version (the Windows Battle.net doesn't tell which): World of Warcraft,
    /// Hearthstone, Diablo III, StarCraft, Heroes of the Storm and Warcraft III: Reforged.
    static let blizzardMacGames: Set<String> = ["WoW", "WoWC", "WTCG", "D3", "S2", "S1", "Hero", "W3"]

    /// Titles of the product codes `blizzardCode(for:)` gives back, for owned games that aren't installed.
    static let blizzardTitles: [String: String] = [
        "WoW": "World of Warcraft", "WTCG": "Hearthstone", "Pro": "Overwatch 2", "Fen": "Diablo IV",
        "D3": "Diablo III", "OSI": "Diablo II: Resurrected", "ANBS": "Diablo Immortal", "S2": "StarCraft II",
        "S1": "StarCraft: Remastered", "Hero": "Heroes of the Storm", "W3": "Warcraft III: Reforged",
        "ZEUS": "Call of Duty: Black Ops Cold War",
    ]

    /// Battle.net's product code for a game title: what `--exec="launch <code>"` (and `battlenet://<code>`) take.
    /// The checks run in order, so the more specific titles come first.
    static func blizzardCode(for title: String) -> String? {
        let name = title.lowercased()
        func mentions(_ phrases: String...) -> Bool { phrases.contains { name.contains($0) } }
        switch true {
        case mentions("world of warcraft"): return mentions("classic") ? "WoWC" : "WoW"
        case mentions("hearthstone"): return "WTCG"
        case mentions("overwatch"): return "Pro"
        case mentions("diablo iv", "diablo 4"): return "Fen"
        case mentions("diablo iii", "diablo 3"): return "D3"
        case mentions("diablo ii", "diablo 2"): return "OSI"
        case mentions("diablo immortal"): return "ANBS"
        case mentions("starcraft ii", "starcraft 2"): return "S2"
        case mentions("starcraft"): return "S1"
        case mentions("heroes of the storm"): return "Hero"
        case mentions("warcraft iii", "warcraft 3"): return "W3"
        case mentions("warcraft ii"): return "W2"
        case mentions("warcraft") && mentions("orcs"): return "W1"
        case mentions("call of duty"): return mentions("cold war") ? "ZEUS" : "AUKS"
        default: return nil
        }
    }

    // MARK: EA app games

    /// The EA app puts games in `C:\Program Files\EA Games\<Game>`, each with an `__Installer` folder whose
    /// `installerdata.xml` names the content id the app launches it by (the folder name stands in without one).
    static func eaGames(in environment: Bottle) -> [Game] {
        let root = environment.driveC.appendingPathComponent("Program Files/EA Games")
        let files = FileManager.default
        let children = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var games = [Game]()
        for folder in children {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  files.fileExists(atPath: folder.appendingPathComponent("__Installer").path) else { continue }
            let manifest = folder.appendingPathComponent("__Installer/installerdata.xml")
            let xml = (try? String(contentsOf: manifest, encoding: .utf8)) ?? ""
            games.append(Game(store: .ea, storeID: eaContentID(installerXML: xml) ?? folder.lastPathComponent,
                              title: folder.lastPathComponent, isInstalled: true,
                              installPath: folder, sizeOnDisk: GOGProvider.folderSize(folder)))
        }
        return games.inLibraryOrder()
    }

    /// The first `<contentID>` in an EA installer manifest, which the EA app accepts in launch links.
    static func eaContentID(installerXML xml: String) -> String? {
        let open = "<contentID>", close = "</contentID>"
        guard let start = xml.range(of: open)?.upperBound,
              let end = xml.range(of: close, range: start..<xml.endIndex)?.lowerBound else { return nil }
        let id = xml[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return id
    }

    // MARK: Starting the launcher

    /// Opens the launcher's window. `arguments` go after the drawing switches.
    @discardableResult public func launchLauncher(engine: Engine, profile: LaunchProfile = LaunchProfile(), arguments: [String] = [],
                                                  onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        try startLauncher(arguments, engine: engine, profile: profile, logID: kind.rawValue, onExit: onExit)
    }

    /// Opens the launcher on the game's install page where it has one (Ubisoft Connect's `uplay://install`;
    /// Battle.net shows a game that isn't installed with its Install button when asked to launch it), and on its
    /// main window otherwise.
    @discardableResult public func openInstall(_ game: Game, engine: Engine, profile: LaunchProfile = LaunchProfile(),
                                               onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        let link: [String]
        switch kind {
        case .ubisoft: link = ["uplay://install/" + game.storeID]
        case .battlenet: link = ["--exec=launch \(game.storeID)"]
        default: link = []
        }
        return try startLauncher(link, engine: engine, profile: profile, logID: kind.rawValue, onExit: onExit)
    }

    /// Asks the launcher to start the game. It signs in, checks for updates, then runs it.
    @discardableResult public func play(_ game: Game, engine: Engine, profile: LaunchProfile,
                                        onExit: (@Sendable (_ status: Int32) -> Void)? = nil) throws -> RunningProcess {
        let request: String
        switch kind {
        case .ubisoft: request = "uplay://launch/\(game.storeID)/0"
        case .battlenet: request = "--exec=launch \(game.storeID)"
        default: request = "link2ea://launchgame/\(game.storeID)?platform=PCWIN"
        }
        let command = [request] + profile.extraArguments
        return try startLauncher(command, engine: engine, profile: profile, logID: game.id, onExit: onExit)
    }

    /// Battle.net's Chromium (CEF 108) checks the old protection VirtualProtect reports for a copy-on-write page and
    /// stops its page process (a breakpoint at a fixed place in libcef.dll) on Wine's answer, so the login page
    /// restarted every 5 seconds and never showed. CrossOver's Wine answers as Windows does with this switch.
    static let battleNetEnvironment = ["WINE_SIMULATE_WRITECOPY": "1"]

    /// Every launcher start goes through here. Ubisoft's overlay is switched off first, as it blacks out games
    /// (see `UbisoftSettings`), and the Chromium settings Steam's web helper needs are added under the player's
    /// own environment.
    private func startLauncher(_ extra: [String], engine: Engine, profile: LaunchProfile, logID: String,
                               onExit: (@Sendable (_ status: Int32) -> Void)?) throws -> RunningProcess {
        if !isLauncherInstalled { throw WineRunnerError.launchFailed("\(kind.displayName) isn't installed") }
        if kind == .ubisoft { UbisoftSettings.disableOverlay(in: bottle) }
        if kind == .battlenet { prepareBattleNetConfig() }
        var tuned = profile
        tuned.extraEnvironment = SteamProvider.webEngineEnvironment.merging(SteamProvider.noMicrophone) { a, _ in a }
            .merging(kind == .battlenet ? Self.battleNetEnvironment : [:]) { a, _ in a }
            .merging(profile.extraEnvironment) { _, mine in mine }
        let program = launcherExecutable
        return try wine.run(engine: engine, bottle: bottle, executable: program.path,
                            arguments: launcherArguments + extra,
                            workingDirectory: program.deletingLastPathComponent(), profile: tuned, logID: logID,
                            onExit: onExit)
    }
}

/// A download a store's own launcher is running; Sommelier only follows it.
public struct LauncherDownload: Sendable, Equatable {
    /// `opening`: Install was clicked in Sommelier and the launcher is still bringing up its install window, which
    /// takes a while. `confirm`: that window is up, waiting for the player to confirm.
    public enum Phase: Sendable, Equatable { case opening, confirm, queued, downloading, paused }

    public var phase: Phase
    /// Done so far, 0...1, when the launcher reveals it.
    public var fraction: Double?

    public init(phase: Phase, fraction: Double? = nil) {
        self.phase = phase
        self.fraction = fraction
    }
}
