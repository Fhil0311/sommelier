// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What a game is, read from its files: which launcher it starts through, its anti-cheat, its engine. Fix rules
/// ask these before they speak (`FixCondition`), so a game is never told about an EA app it doesn't use because
/// some other game's lines were in a shared log.
public struct GameFacts: Codable, Equatable, Sendable {
    public enum Launcher: String, Codable, Sendable { case ea, ubisoft, rockstar }
    public enum Engine: String, Codable, Sendable { case unreal, unity }

    public var launcher: Launcher?
    public var antiCheat: Bool
    public var engine: Engine?
    /// Ships Epic Online Services (its overlay can crash games under Wine).
    public var epicOnlineServices: Bool
    /// A program of the game is .NET (it imports `mscoree.dll`).
    public var dotNet: Bool = false
    /// A program imports MFC (the part of the Visual C++ runtime Wine doesn't have).
    public var visualCpp: Bool = false
    /// A program imports D3DX, XAudio 2.0–2.7, X3DAudio or XACT: the DirectX 9 runtime's parts.
    public var directXRuntime: Bool = false
    /// The game ships PhysX libraries.
    public var physX: Bool = false

    public init(launcher: Launcher? = nil, antiCheat: Bool = false, engine: Engine? = nil, epicOnlineServices: Bool = false,
                dotNet: Bool = false, visualCpp: Bool = false, directXRuntime: Bool = false, physX: Bool = false) {
        self.launcher = launcher; self.antiCheat = antiCheat; self.engine = engine; self.epicOnlineServices = epicOnlineServices
        self.dotNet = dotNet; self.visualCpp = visualCpp; self.directXRuntime = directXRuntime; self.physX = physX
    }

    /// What one program's imports say. Only an .exe that imports `mscoree` makes a .NET game: Unity and other
    /// engines ship managed libraries that do too, and run them on their own Mono.
    mutating func read(imports: Set<String>, program: Bool = true) {
        if program, imports.contains("mscoree.dll") { dotNet = true }
        // Wine has its own msvcp/msvcr/vcruntime; what it lacks, and Sommelier's Visual C++ fix adds, is MFC.
        if imports.contains(where: { $0.hasPrefix("mfc1") }) { visualCpp = true }
        // The June 2010 runtime's parts: D3DX, XAudio 2.0–2.7, X3DAudio, XACT. XAudio 2.9 ("xaudio2_9redist")
        // ships with the game itself.
        if imports.contains(where: { $0.hasPrefix("d3dx9_") || $0.hasPrefix("d3dx10_") || $0.hasPrefix("d3dx11_")
            || ($0.hasPrefix("xaudio2_") && ($0.dropFirst(8).first.map { "01234567".contains($0) } ?? false) && !$0.contains("redist"))
            || $0.hasPrefix("x3daudio1_") || $0.hasPrefix("xactengine") }) { directXRuntime = true }
        if imports.contains(where: { $0.hasPrefix("physx") || $0 == "physxloader.dll" }) { physX = true }
    }

    /// Looks through the game's folder (a few levels, the big data folders skipped).
    public static func scan(_ folder: URL, store: StoreKind) -> GameFacts {
        var facts = GameFacts()
        if store == .ubisoft { facts.launcher = .ubisoft }
        if store == .ea { facts.launcher = .ea }
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return facts }
        var paks = false, binaries = false, programs = 0
        for case let url as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            if name == "paks" { paks = true; walker.skipDescendants(); continue }
            if name.hasSuffix("_data"), (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Unity's data folder: its plugins say what the game needs; its managed libraries don't.
                if fm.fileExists(atPath: url.appendingPathComponent("Managed").path) { facts.engine = facts.engine ?? .unity }
            }
            if name == "managed" { walker.skipDescendants(); continue }
            if AppNames.dataFolders.contains(name), name != "content" { walker.skipDescendants(); continue }
            switch name {
            case "__installer": if facts.launcher == nil { facts.launcher = .ea }
            case "easyanticheat", "battleye", "beservice.exe", "beservice_x64.exe", "easyanticheat_eos_setup.exe": facts.antiCheat = true
            case "unityplayer.dll": facts.engine = .unity
            case "win64": binaries = binaries || url.deletingLastPathComponent().lastPathComponent.lowercased() == "binaries"
            case "playgtav.exe", "playrdr2.exe", "rockstarlauncher.exe": if facts.launcher == nil { facts.launcher = .rockstar }
            default:
                // The game's programs (and its own libraries): what they import. Headers only, so it's quick.
                if (name.hasSuffix(".exe") || name.hasSuffix(".dll")), programs < 96, !AppNames.isHelper(name),
                   let image = PEImage(url: url) {
                    programs += 1
                    facts.read(imports: image.imports, program: name.hasSuffix(".exe"))
                }
                if name.hasPrefix("physx") || name == "physxloader.dll" || name.hasPrefix("physx3") { facts.physX = true }
                if name.hasPrefix("uplay_r1_loader") || name.hasPrefix("upc_r2_loader") || name.hasPrefix("uplay_r2_loader") { if facts.launcher == nil { facts.launcher = .ubisoft } }
                if name.hasPrefix("eossdk-win") { facts.epicOnlineServices = true }
                if name == "content" { continue }
            }
        }
        if paks && binaries && facts.engine == nil { facts.engine = .unreal }
        return facts
    }
}
