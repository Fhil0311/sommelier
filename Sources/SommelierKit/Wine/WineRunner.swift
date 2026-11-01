// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a Windows program could not be started.
public enum WineRunnerError: LocalizedError {
    case noEngine, bottleMissing(BottleKind), launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noEngine:
            return "The game engine isn't installed yet."
        case .bottleMissing(let store):
            return "The \(store.rawValue) environment hasn't been set up yet."
        case .launchFailed(let reason):
            return "Couldn't start the program: \(reason)"
        }
    }
}

/// A handle on a program `WineRunner` started. The caller learns about the exit through the `onExit` callback it
/// passed, so nothing here polls.
public final class RunningProcess: @unchecked Sendable {
    private let child: Process
    /// The log file the program's output goes to.
    public let logURL: URL

    init(process: Process, logURL: URL) { (child, self.logURL) = (process, logURL) }

    public var pid: Int32 { child.processIdentifier }
    public var isRunning: Bool { child.isRunning }

    /// Asks the program to quit (SIGTERM). Harmless once it has exited.
    public func terminate() {
        guard child.isRunning else { return }
        child.terminate()
    }
}

/// The one place Sommelier starts Windows programs (and native helpers that need Wine's environment), so every
/// launch gets the same variables, DLL overrides and log handling.
public struct WineRunner: Sendable {
    public let paths: Paths
    public let logs: LogStore

    public init(paths: Paths) { (self.paths, logs) = (paths, LogStore(paths: paths)) }

    /// Host variables a Windows program may see. Everything else in the app's environment is dropped: stray tool
    /// variables otherwise end up in places like Steam's command line.
    static let inheritedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "SHELL"]

    /// The full environment for a program in `bottle`. Pure, so tests can pin it down.
    /// Resolve `profile.backend` for the game first; an unresolved `.auto` is treated as DXVK.
    public static func environment(bottle: Bottle, profile: LaunchProfile, engine: Engine? = nil,
                                   base: [String: String] = ProcessInfo.processInfo.environment, extraOverrides: [String] = [])
        -> [String: String] {
        let backend: GraphicsBackend = profile.backend.resolved()
        // DXVK/DXMT overrides only make sense on an engine that carries those DLLs. On a D3DMetal engine they'd
        // only let a game load the native Direct3D DLLs `WineD3DFallback` may have put in System32.
        let backendShipped = engine?.info.backends.contains(backend.rawValue) ?? true

        var vars = base.filter { inheritedKeys.contains($0.key) }
        vars.merge(wineBasics(bottle: bottle, verbose: profile.verboseLogs)) { _, new in new }
        vars.merge(sommelierHooks(bottle: bottle, engine: engine)) { _, new in new }
        vars["WINEDLLOVERRIDES"] = dllOverrides(bottle: bottle, profile: profile,
                                                backend: backendShipped ? backend.overrides : [], extra: extraOverrides)
        vars.merge(backend.environment) { _, new in new }
        vars.merge(graphicsVariables(backend: backend, shipped: backendShipped, profile: profile, engine: engine)) { _, new in new }
        if profile.performanceHUD { vars["MTL_HUD_ENABLED"] = "1" }
        // Only a game hears the microphone (engine/patches/winecoreaudio-no-mic.patch): macOS asks when the game opens
        // it, as with any Mac app; stores, launchers, installers and Wine's own programs never make it ask.
        if !profile.forGame { vars["SOMMELIER_NO_MIC"] = "1" }

        // The player's own variables come last and win; a DXMT_CONFIG of theirs extends Sommelier's instead.
        for (key, value) in profile.extraEnvironment {
            if key == "DXMT_CONFIG", let ours = vars[key] {
                vars[key] = "\(ours);\(value)"
            } else {
                vars[key] = value
            }
        }
        return vars
    }

    /// The variables that differ from game to game: the graphics backend's, Turbo's, SDR's, the HUD's and the
    /// player's own. Programs started by a running store inherit the store's environment, so these are given per
    /// game folder instead (`ExecutableEnvironment`): the game's values, and "" for the ones it doesn't set.
    public static func programEnvironment(bottle: Bottle, profile: LaunchProfile, engine: Engine? = nil) -> [String: String] {
        let full = environment(bottle: bottle, profile: profile, engine: engine)
        var keys: Set<String> = ["WINEDLLOVERRIDES", "WINEDEBUG", "SOMMELIER_DLL_PREPEND", "DXMT_CONFIG", "DXMT_METALFX_SPATIAL_SWAPCHAIN",
                                 "SOMMELIER_FORCE_SDR", "CX_APPLEGPTK_LIBD3DSHARED_PATH", "CX_ACTIVE_GRAPHICS_BACKEND",
                                 "D3DM_SUPPORT_DXR", "D3DM_ENABLE_METALFX", "MTL_HUD_ENABLED",
                                 "SOMMELIER_NO_MIC"]                  // a game hears the microphone, its store doesn't
        for backend in GraphicsBackend.allCases { keys.formUnion(backend.environment.keys) }
        keys.formUnion(profile.extraEnvironment.keys)
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, full[$0] ?? "") })
    }

    /// Prefix, logging and synchronisation settings every program gets.
    private static func wineBasics(bottle: Bottle, verbose: Bool) -> [String: String] {
        [
            "WINEPREFIX": bottle.url.path,
            // Errors are always logged (fix rules read the `err:` lines), each tagged with its process id so a log
            // shared by a launcher and its games can be split per game.
            "WINEDEBUG": verbose ? "err+all,warn+module,+pid" : "-all,err+all,+pid",
            "WINEESYNC": "1",
            "WINEMSYNC": "1",
            "ROSETTA_ADVERTISE_AVX": "1",
            // A 4 GB address space for 32-bit games, as 64-bit Windows (and Proton) gives them; older open-world
            // games run out of memory at 2 GB.
            "WINE_LARGE_ADDRESS_AWARE": "1",
        ]
    }

    /// Variables read by Sommelier's own engine changes. All are inherited by whatever a launcher starts.
    private static func sommelierHooks(bottle: Bottle, engine: Engine?) -> [String: String] {
        // Bottles live in <home>/Bottles/<store>, and the shared tables sit in <home>.
        let home = bottle.url.deletingLastPathComponent().deletingLastPathComponent()
        var vars = [
            "SOMMELIER_FRAME_STATS_DIR": FrameStats.windowsPath(FrameStats.folder(in: bottle)),  // DXMT's frame times
            "SOMMELIER_NO_TRAY": "1",                       // launcher tray icons stay out of the menu bar
            "SOMMELIER_APP_NAMES": AppNames.url(home: home).path,   // Dock names per program
            "SOMMELIER_EXE_REDIRECTS": ExecutableRedirects.url(home: home).path,  // recipes' launcher bypasses
            "SOMMELIER_EXE_ENV": ExecutableEnvironment.url(home: home).path,      // each game's own graphics
            "SOMMELIER_EXE_ARGS": ExecutableArguments.url(home: home).path,       // arguments a store can't pass
        ]
        guard let engine else { return vars }
        // Knowing its library folder, the engine starts each program through a link named after it, so the Dock
        // and Cmd-Tab show the game's name rather than "wine".
        vars["WINEDLLPATH"] = engine.wineRoot.appendingPathComponent("lib/wine").path
        // Media Foundation video goes through the engine's GStreamer. Plugins are scanned by a helper process
        // (a bad plugin can't crash the game) into a cache kept beside the engine.
        if let plugins = engine.gstreamerPlugins {
            vars["GST_PLUGIN_SYSTEM_PATH_1_0"] = plugins.path
            vars["GST_REGISTRY_1_0"] = engine.wineRoot.appendingPathComponent("gst-registry.bin").path
            if let scanner = engine.gstreamerScanner { vars["GST_PLUGIN_SCANNER_1_0"] = scanner.path }
        }
        return vars
    }

    /// `WINEDLLOVERRIDES`: no Mono or Gecko install prompts (Mono stays on where the bottle has it), no menu
    /// entries, then the backend's DLLs, the caller's extras and finally the game's own, sorted by name.
    private static func dllOverrides(bottle: Bottle, profile: LaunchProfile, backend: [String], extra: [String]) -> String {
        let fixed = [bottle.hasMono ? "mshtml=" : "mscoree,mshtml=", "winemenubuilder.exe=d"]
        let perGame = profile.dllOverrides.keys.sorted().map { "\($0)=\(profile.dllOverrides[$0] ?? "")" }
        return (fixed + backend + extra + perGame).joined(separator: ";")
    }

    /// D3DMetal and DXMT switches.
    private static func graphicsVariables(backend: GraphicsBackend, shipped: Bool, profile: LaunchProfile,
                                          engine: Engine?) -> [String: String] {
        var vars: [String: String] = [:]
        switch backend {
        case .d3dMetal:
            if let library = engine?.d3dMetalLibrary {
                vars["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = library.path
                vars["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"     // lets DX12 games see GPU scheduling
            }
            vars["D3DM_SUPPORT_DXR"] = profile.rayTracing ? "1" : "0"
            if profile.metalFX { vars["D3DM_ENABLE_METALFX"] = "1" }
        case .dxmt:
            if shipped, let root = engine?.dxmtRoot { vars["SOMMELIER_DLL_PREPEND"] = root.path }
            var config: [String] = []
            if profile.turbo {
                // Turbo: MetalFX scales the swap chain up 2x, from the size in points to the display's pixels.
                vars["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
                config.append("d3d11.metalSpatialUpscaleFactor=2")
            }
            if !profile.hdr {
                // Report an SDR display both to DirectX and, via the Mac driver, to Windows' HDR setting.
                config.append("dxgi.forceSDR=True")
                vars["SOMMELIER_FORCE_SDR"] = "1"
            }
            if !config.isEmpty { vars["DXMT_CONFIG"] = config.joined(separator: ";") }
        default:
            break
        }
        return vars
    }

    // MARK: Starting programs

    /// Starts a Windows program (a path inside the bottle or a program name such as `regedit`) and returns at once.
    @discardableResult public func run(
        engine: Engine, bottle: Bottle, executable: String, arguments: [String] = [], workingDirectory: URL? = nil,
        profile: LaunchProfile = LaunchProfile(), extraOverrides: [String] = [], logID: String,
        onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        try launch(program: engine.wine, arguments: [executable] + arguments, engine: engine,
                   bottle: bottle, workingDirectory: workingDirectory, profile: profile,
                   extraOverrides: extraOverrides, logID: logID, onExit: onExit)
    }

    /// Starts a native program (legendary, wine itself…) with the bottle's Wine environment, logging its output
    /// under `logID`. `extraEnvironment` is applied on top of everything else.
    @discardableResult public func launch(
        program: URL, arguments: [String], engine: Engine, bottle: Bottle, workingDirectory: URL? = nil,
        profile: LaunchProfile = LaunchProfile(), extraOverrides: [String] = [],
        extraEnvironment: [String: String] = [:], logID: String,
        onExit: (@Sendable (Int32) -> Void)? = nil) throws -> RunningProcess {
        if !bottle.exists { throw WineRunnerError.bottleMissing(bottle.kind) }
        try paths.createDirectories()
        let backend: GraphicsBackend = profile.backend.resolved()
        if backend == .dxmt, let dxmt = engine.dxmtRoot {
            try? DXMTSetup.installStubs(from: dxmt, into: bottle)
            try? ShaderCache(paths: paths).prepare()      // keeps DXMT's shader caches out of macOS's cache purges
        }

        let logFile = try logs.newLog(for: logID)
        let writer = try LogWriter(url: logFile)
        writer.note("[Sommelier] Launch \(Self.timestamp()) engine=\(engine.version) wine=\(engine.info.wineVersion) "
                    + "environment=\(bottle.kind.rawValue) backend=\(backend.rawValue)\n")

        try? FileManager.default.createDirectory(at: FrameStats.folder(in: bottle), withIntermediateDirectories: true)
        FrameStats.prune(in: bottle)
        var variables = Self.environment(bottle: bottle, profile: profile, engine: engine, extraOverrides: extraOverrides)
        variables.merge(extraEnvironment) { _, new in new }

        let child = Process()
        child.executableURL = program
        child.arguments = arguments
        child.currentDirectoryURL = workingDirectory
        child.environment = variables
        writer.attach(child)
        child.terminationHandler = { ended in
            let how = ended.terminationReason == .uncaughtSignal ? "signal" : "exit"
            writer.finish("\n[Sommelier] Exit \(Self.timestamp()) pid=\(ended.processIdentifier) "
                          + "status=\(ended.terminationStatus) reason=\(how)\n")
            onExit?(ended.terminationStatus)
        }
        do {
            try child.run()
        } catch {
            let reason = error.localizedDescription
            writer.finish("[Sommelier] couldn't start: \(reason)\n")
            throw WineRunnerError.launchFailed(reason)
        }
        return RunningProcess(process: child, logURL: logFile)
    }

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// The bottle's environment for short housekeeping commands (wineserver, reg).
    private func plainEnvironment(_ bottle: Bottle) -> [String: String] {
        Self.environment(bottle: bottle, profile: LaunchProfile())
    }

    /// Stops everything running in the bottle (`wineserver -k`).
    public func killAll(engine: Engine, bottle: Bottle) async {
        _ = try? await ProcessRunner.run(engine.wineserver, ["-k"], environment: plainEnvironment(bottle))
    }

    /// Whether the bottle's wineserver is still up, so the app can pick up where it was after a restart.
    /// `-k0` sends signal 0: it only succeeds when a server answers.
    public func isBottleActive(engine: Engine, bottle: Bottle) async -> Bool {
        let probe = try? await ProcessRunner.run(engine.wineserver, ["-k0"], environment: plainEnvironment(bottle))
        return probe?.succeeded ?? false
    }

    /// Sets bottle-wide Mac driver switches (`RetinaMode`, `LeftCommandIsCtrl`…) to `y` or `n`, in name order.
    /// Wine reads them when it next starts in the bottle.
    public func applyMacDriver(_ values: [String: Bool], engine: Engine, bottle: Bottle) async {
        let key = #"HKCU\Software\Wine\Mac Driver"#
        let env = plainEnvironment(bottle)
        for name in values.keys.sorted() {
            let data = values[name] == true ? "y" : "n"
            _ = try? await ProcessRunner.run(engine.wine, ["reg", "add", key, "/v", name, "/d", data, "/f"], environment: env)
        }
    }
}
