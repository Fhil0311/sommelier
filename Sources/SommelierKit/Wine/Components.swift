// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Runtimes games need that Wine doesn't bring: Microsoft's and Nvidia's own packages, downloaded from their sites
/// onto the player's Mac and installed into the bottle with their own installers (as the D3DMetal set-up takes
/// Apple's). A closed list: a rule or recipe can only name one of these.
public enum Component: String, Codable, CaseIterable, Sendable {
    /// The DirectX 9 user runtime (June 2010): D3DX 9/10/11, the older shader compilers, XACT and XAudio. Its own
    /// `DXSETUP /silent`, ~100 MB.
    case directx
    /// Microsoft's Direct3D shader compiler (`d3dcompiler_47.dll`, from the Windows SDK), for games that compile
    /// shaders at run time and choke on Wine's.
    case d3dcompiler47
    /// Nvidia PhysX system software (legacy), for games that need its driver DLLs even on other GPUs.
    case physx
    /// Microsoft's DirectPlay (32-bit), from the February 2010 DirectX runtime: games of the early 2000s load it
    /// even for single player.
    case directplay
    /// Microsoft's DirectSound (32-bit), for older games whose sound breaks on Wine's.
    case dsound
    /// Microsoft's DirectMusic (32-bit) with DirectSound, for older games' music.
    case directmusic
    /// The Microsoft core fonts for the web (Arial, Times New Roman, Verdana…), from their original 2002 packages.
    case corefonts

    public var displayName: String {
        switch self {
        case .directx: "the DirectX 9 runtime"
        case .d3dcompiler47: "the Direct3D shader compiler"
        case .physx: "PhysX"
        case .directplay: "DirectPlay"
        case .dsound: "DirectSound"
        case .directmusic: "DirectMusic"
        case .corefonts: "the Microsoft core fonts"
        }
    }

    /// The 32-bit DLLs (and programs) a component takes from the February 2010 runtime's `dxnt.cab`, with the
    /// load order the game then uses for each.
    static let fromDxnt: [Component: [(file: String, mode: String)]] = [
        .directplay: ["dplaysvr.exe", "dplayx.dll", "dpmodemx.dll", "dpnet.dll", "dpnhpast.dll", "dpnhupnp.dll", "dpnsvr.exe", "dpwsockx.dll"].map { ($0, "n") },
        .dsound: [("dsound.dll", "n,b")],
        .directmusic: ["dmband.dll", "dmcompos.dll", "dmime.dll", "dmloader.dll", "dmscript.dll", "dmstyle.dll", "dmsynth.dll", "dmusic.dll", "dswave.dll"].map { ($0, "n") }
            + [("dsound.dll", "n,b")],
    ]
    /// The DLLs that register COM classes once they're in.
    static let registered: Set<String> = ["dplayx.dll", "dpnet.dll", "dpnhpast.dll", "dpnhupnp.dll", "dmband.dll", "dmcompos.dll", "dmime.dll",
                                          "dmloader.dll", "dmscript.dll", "dmstyle.dll", "dmsynth.dll", "dmusic.dll", "dswave.dll"]

    /// Whether the files can be taken out again (PhysX's installer spreads too far to track).
    public var isUndoable: Bool { self != .physx }

    /// The game's DLL overrides once the component is in: the native DLLs first (Wine's own second).
    public var overrides: [String: String] {
        switch self {
        case .directx:
            var dlls = (24...43).map { "d3dx9_\($0)" } + (33...43).map { "d3dx10_\($0)" } + ["d3dx11_42", "d3dx11_43"]
                + (33...43).map { "d3dcompiler_\($0)" } + (0...7).map { "xaudio2_\($0)" } + (0...7).map { "x3daudio1_\($0)" }
                + (1...5).map { "xapofx1_\($0)" } + (0...10).map { "xactengine2_\($0)" } + (0...7).map { "xactengine3_\($0)" }
            dlls.removeAll { $0 == "d3dx10_33" }                                      // never existed
            return Dictionary(uniqueKeysWithValues: dlls.map { ($0, "n,b") })
        case .d3dcompiler47: return ["d3dcompiler_47": "n"]
        case .physx, .corefonts: return [:]
        case .directplay, .dsound, .directmusic:
            var out = Dictionary(uniqueKeysWithValues: (Self.fromDxnt[self] ?? []).map { entry in
                (entry.file.hasSuffix(".dll") ? String(entry.file.dropLast(4)) : entry.file, entry.mode)
            })
            if self == .directmusic { out["streamci"] = "n" }
            return out
        }
    }

    /// Where its own package says it's installed (nil: Sommelier tracks the files itself).
    func installedMarker(in bottle: Bottle) -> URL? {
        switch self {
        case .directx: bottle.driveC.appendingPathComponent("windows/syswow64/d3dx9_43.dll")
        case .d3dcompiler47: bottle.driveC.appendingPathComponent("windows/system32/d3dcompiler_47.dll")
        case .physx: bottle.driveC.appendingPathComponent("Program Files (x86)/NVIDIA Corporation/PhysX/Engine")
        case .directplay: bottle.driveC.appendingPathComponent("windows/syswow64/dplayx.dll")
        case .dsound: bottle.driveC.appendingPathComponent("windows/syswow64/dsound.dll")
        case .directmusic: bottle.driveC.appendingPathComponent("windows/syswow64/dmime.dll")
        case .corefonts: bottle.driveC.appendingPathComponent("windows/Fonts/arial.ttf")
        }
    }
}

/// Downloads a component's package (once, into `<Sommelier>/Components`) and installs it into a bottle.
public struct ComponentInstaller: Sendable {
    public struct Package: Sendable {
        public let url: URL
        public let sha256: String
        public var name: String { url.lastPathComponent }
    }
    public enum Failure: Error, Equatable { case download(String), checksum(String), install(String) }

    public static let directX = Package(url: URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!,
                                        sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b")
    public static let physX = Package(url: URL(string: "https://us.download.nvidia.com/Windows/9.23.1019/PhysX_9.23.1019_SystemSoftware.exe")!,
                                      sha256: "9b42b84e881769d681e09f62a1b51532616b2e6a2d5d99d0ccae6eb5fbbc208c")
    /// The Windows SDK's compiler cabinets: 32-bit and 64-bit, each holding the DLL under an opaque name.
    public static let compiler32 = Package(url: URL(string: "https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/2630bae9681db6a9f6722366f47d055c.cab")!,
                                           sha256: "d0440eb81c532dc23639c0c63f2fcde9deddb23bb4cce01c19ac6b96cc3e269d")
    public static let compiler64 = Package(url: URL(string: "https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/61d57a7a82309cd161a854a6f4619e52.cab")!,
                                           sha256: "f736e161547095bb8d98c636b85fdfeb4070fefeee3c3745db3ce88f6eb1d9de")
    static let compilerFiles = [("fila319f706acfa16d6707473ebf29bdc7f", "syswow64"), ("fil3585cb2ea5db13cc0838f8d06b5c9679", "system32")]
    /// The February 2010 DirectX runtime, the last with DirectPlay, DirectSound and DirectMusic. Microsoft no longer
    /// serves it; the Internet Archive keeps Microsoft's own file (checked against its SHA-256, as winetricks does).
    public static let directXFeb2010 = Package(url: URL(string: "https://web.archive.org/web/20100205000000id_/https://download.microsoft.com/download/E/E/1/EE17FF74-6C45-4575-9CF4-7FC2597ACD18/directx_feb2010_redist.exe")!,
                                               sha256: "f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f")
    /// Microsoft's core fonts packages (2002), from the corefonts project that keeps them as Microsoft released them.
    public static let coreFonts: [Package] = [
        ("andale32.exe", "0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970"),
        ("arial32.exe", "85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6"),
        ("arialb32.exe", "a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8"),
        ("comic32.exe", "9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e"),
        ("courie32.exe", "bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384"),
        ("georgi32.exe", "2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301"),
        ("impact32.exe", "6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb"),
        ("times32.exe", "db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab"),
        ("trebuc32.exe", "5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9"),
        ("verdan32.exe", "c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96"),
        ("webdin32.exe", "64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a"),
    ].map { Package(url: URL(string: "https://downloads.sourceforge.net/corefonts/\($0.0)")!, sha256: $0.1) }

    public let paths: Paths
    public let session: URLSession
    public init(paths: Paths, session: URLSession = .shared) { self.paths = paths; self.session = session }

    public var folder: URL { paths.home.appendingPathComponent("Components", isDirectory: true) }

    public static func packages(for component: Component) -> [Package] {
        switch component {
        case .directx: [directX]
        case .d3dcompiler47: [compiler32, compiler64]
        case .physx: [physX]
        case .directplay, .dsound, .directmusic: [directXFeb2010]
        case .corefonts: coreFonts
        }
    }

    /// The component's own file is there and isn't Wine's built-in stand-in for it (the engine keeps Wine's DLLs
    /// in the system folders as real files, each marked "Wine builtin DLL").
    public func isInstalled(_ component: Component, in bottle: Bottle) -> Bool {
        guard let marker = component.installedMarker(in: bottle), FileManager.default.fileExists(atPath: marker.path) else { return false }
        return !Self.isWineBuiltin(marker)
    }

    static func isWineBuiltin(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("Wine builtin DLL".utf8)) != nil
    }

    /// The package on disk, downloaded when it isn't there yet or doesn't match its checksum.
    public func fetch(_ package: Package) async throws -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(package.name)
        if fm.fileExists(atPath: file.path), Self.sha256(of: file) == package.sha256 { return file }
        guard let (temp, response) = try? await session.download(from: package.url), (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.download(package.name)
        }
        guard Self.sha256(of: temp) == package.sha256 else { try? fm.removeItem(at: temp); throw Failure.checksum(package.name) }
        try? fm.removeItem(at: file)
        try fm.moveItem(at: temp, to: file)
        return file
    }

    /// Installs the component into the bottle with its own package. Returns the files it added under the bottle's
    /// `drive_c/windows` (for undoing); empty for a package whose files aren't tracked (PhysX).
    public func install(_ component: Component, in bottle: Bottle, engine: Engine) async throws -> [String] {
        let fm = FileManager.default
        let env = WineRunner.environment(bottle: bottle, profile: LaunchProfile(), engine: engine)
        let windows = bottle.driveC.appendingPathComponent("windows")
        let temp = windows.appendingPathComponent("temp/sommelier-\(component.rawValue)")
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let tempWindows = "C:\\windows\\temp\\sommelier-\(component.rawValue)"
        func wine(_ args: [String], in directory: URL? = nil) async -> Bool {
            (try? await ProcessRunner.run(engine.wine, args, environment: env, currentDirectory: directory))?.succeeded == true
        }
        switch component {
        case .directx:
            let package = try await fetch(Self.directX)
            let before = Self.systemFiles(in: windows)
            guard await wine([package.path, "/Q", "/T:\(tempWindows)"]), fm.fileExists(atPath: temp.appendingPathComponent("DXSETUP.exe").path) else {
                throw Failure.install("couldn't unpack the DirectX runtime")
            }
            guard await wine(["\(tempWindows)\\DXSETUP.exe", "/silent"]), isInstalled(component, in: bottle) else {
                throw Failure.install("the DirectX set-up failed")
            }
            return Self.changed(from: before, to: Self.systemFiles(in: windows))
        case .d3dcompiler47:
            var added: [String] = []
            for (package, (inner, folder)) in zip([Self.compiler32, Self.compiler64], Self.compilerFiles) {
                let cab = try await fetch(package)
                try fm.copyItem(at: cab, to: temp.appendingPathComponent(package.name))
                let out = temp.appendingPathComponent(folder)
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                _ = await wine(["extrac32.exe", "/Y", "/E", "/L", "\(tempWindows)\\\(folder)", "\(tempWindows)\\\(package.name)"], in: temp)
                let extracted = out.appendingPathComponent(inner)
                guard fm.fileExists(atPath: extracted.path) else { throw Failure.install("couldn't unpack the shader compiler") }
                let target = windows.appendingPathComponent("\(folder)/d3dcompiler_47.dll")
                try? fm.removeItem(at: target)
                try fm.moveItem(at: extracted, to: target)
                added.append("\(folder)/d3dcompiler_47.dll")
            }
            return added
        case .physx:
            let package = try await fetch(Self.physX)
            guard await wine([package.path, "/s"], in: folder), isInstalled(component, in: bottle) else { throw Failure.install("the PhysX set-up failed") }
            return []
        case .directplay, .dsound, .directmusic:
            let package = try await fetch(Self.directXFeb2010)
            guard await wine([package.path, "/Q", "/T:\(tempWindows)"]), fm.fileExists(atPath: temp.appendingPathComponent("dxnt.cab").path) else {
                throw Failure.install("couldn't unpack the DirectX runtime")
            }
            let out = temp.appendingPathComponent("nt")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            _ = await wine(["extrac32.exe", "/Y", "/E", "/L", "\(tempWindows)\\nt", "\(tempWindows)\\dxnt.cab"], in: temp)
            // 32-bit only, as these were: into the 32-bit system folder of the 64-bit environment.
            let entries = Component.fromDxnt[component] ?? []
            var added: [String] = []
            for entry in entries {
                let source = out.appendingPathComponent(entry.file)
                guard fm.fileExists(atPath: source.path) else { throw Failure.install("\(entry.file) is missing from the DirectX runtime") }
                let target = windows.appendingPathComponent("syswow64/\(entry.file)")
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
                added.append("syswow64/\(entry.file)")
            }
            // Registered with the game's overrides in force, so the native DLLs (not Wine's) take the registration.
            var profile = LaunchProfile()
            profile.dllOverrides = component.overrides
            let registering = WineRunner.environment(bottle: bottle, profile: profile, engine: engine)
            for entry in entries where Component.registered.contains(entry.file) {
                _ = try? await ProcessRunner.run(engine.wine, ["regsvr32", "/s", "C:\\windows\\syswow64\\\(entry.file)"], environment: registering)
            }
            guard isInstalled(component, in: bottle) else { throw Failure.install("\(component.displayName) didn't go in") }
            return added
        case .corefonts:
            let fonts = windows.appendingPathComponent("Fonts")
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            var added: [String] = [], registry: [String] = []
            for package in Self.coreFonts {
                // Each package is a self-extracting cabinet: the cabinet itself starts at "MSCF" inside it.
                let file = try await fetch(package)
                let data = try Data(contentsOf: file)
                guard let start = data.range(of: Data("MSCF\0\0\0\0".utf8))?.lowerBound else { throw Failure.install("\(package.name) holds no fonts") }
                let base = String(package.name.dropLast(4))
                try data[start...].write(to: temp.appendingPathComponent("\(base).cab"))
                let out = temp.appendingPathComponent(base)
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                _ = await wine(["extrac32.exe", "/Y", "/E", "/L", "\(tempWindows)\\\(base)", "\(tempWindows)\\\(base).cab"], in: temp)
                for name in (try? fm.contentsOfDirectory(atPath: out.path)) ?? [] where name.lowercased().hasSuffix(".ttf") {
                    let lower = name.lowercased()
                    let target = fonts.appendingPathComponent(lower)
                    guard !fm.fileExists(atPath: target.path) else { continue }
                    try fm.copyItem(at: out.appendingPathComponent(name), to: target)
                    added.append("Fonts/\(lower)")
                    registry.append("\"\(String(name.dropLast(4))) (TrueType)\"=\"\(lower)\"")
                }
            }
            guard isInstalled(component, in: bottle) else { throw Failure.install("the fonts didn't go in") }
            if !registry.isEmpty {
                let reg = temp.appendingPathComponent("fonts.reg")
                let text = "REGEDIT4\n\n[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts]\n" + registry.joined(separator: "\n") + "\n"
                try text.write(to: reg, atomically: true, encoding: .utf8)
                _ = await wine(["reg", "import", "\(tempWindows)\\fonts.reg"])
            }
            return added
        }
    }

    /// The files in the bottle's system folders with their sizes, relative to `windows`: a package that replaces
    /// Wine's own DLL with the real one changes the size, and that counts as a file it added.
    static func systemFiles(in windows: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        let fm = FileManager.default
        for folder in ["system32", "syswow64"] {
            let dir = windows.appendingPathComponent(folder)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                out["\(folder)/\(name)"] = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            }
        }
        return out
    }

    static func changed(from before: [String: Int], to after: [String: Int]) -> [String] {
        after.filter { before[$0.key] != $0.value }.map(\.key).sorted()
    }

    static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
