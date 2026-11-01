// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Presses the buttons of Steam's Downloads page for Sommelier: pause and resume a download.
///
/// Steam's window is web pages in its own Chromium, and its buttons call `SteamClient.Downloads` in the page
/// Steam calls "SharedJSContext". Started with `-cef-enable-debugging`, Steam opens Chromium's DevTools endpoint
/// on 127.0.0.1 (`-devtools-port` picks the port; Wine's sockets are the Mac's), and a script run there calls the
/// same functions the page's own buttons do. Nothing outside this Mac can reach the endpoint. A Steam started
/// without the flag (by an older Sommelier, or before this run) has no endpoint: every call then returns false,
/// and the caller shows Steam's own Downloads page instead.
public struct SteamClientBridge: Sendable {
    /// Not Chromium's usual 8080, which local web servers often hold (Steam then fails to bind and goes without).
    public static let port = 38_721
    /// Added to Steam's command line by `SteamProvider`.
    public static let arguments = ["-cef-enable-debugging", "-devtools-port", String(port)]
    /// The page that holds `SteamClient`.
    static let contextTitle = "SharedJSContext"
    /// Steam's id for this computer in `SteamClient.Downloads` calls (the others are remote-download clients).
    static let localClient = "0"

    let base: URL
    let session: URLSession

    public init(port: Int = Self.port) {
        base = URL(string: "http://127.0.0.1:\(port)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.connectionProxyDictionary = [:]       // a system proxy must not carry localhost
        session = URLSession(configuration: configuration)
    }

    /// Pauses the game's download. Like Steam's own button: the download in progress pauses the queue (Steam
    /// doesn't move on to the next game); a game waiting in the queue is taken out of it.
    public func pause(appID: String) async -> Bool {
        guard let id = Int(appID) else { return false }
        return await run("""
            const overview = await \(Self.overviewScript);
            if (overview && overview.update_appid === \(id)) SteamClient.Downloads.EnableAllDownloads(false, "\(Self.localClient)");
            else SteamClient.Downloads.PauseAppUpdate(\(id), "\(Self.localClient)");
            """)
    }

    /// Has the running Steam show its main window (the sign-in window when nobody is signed in), as a second Steam.exe
    /// with steam://open/main does, but at once: no Windows program to start. False when Steam can't be asked (then
    /// the caller falls back to that second Steam.exe).
    public func showMainWindow() async -> Bool {
        await run(#"SteamClient.URL.ExecuteSteamURL("steam://open/main");"#)
    }

    /// Resumes it: puts it first in the queue and, if the queue was paused, lets it run again.
    public func resume(appID: String) async -> Bool {
        guard let id = Int(appID) else { return false }
        return await run("""
            const overview = await \(Self.overviewScript);
            SteamClient.Downloads.ResumeAppUpdate(\(id), "\(Self.localClient)");
            if (!overview || overview.paused) SteamClient.Downloads.EnableAllDownloads(true, "\(Self.localClient)");
            """)
    }

    /// Whether Steam still has a launch of the game going (its own `GetActiveGameActions`): false once the player
    /// declined a question Steam asked before starting it (Cancel in a cloud-sync dialog, say), which Steam's logs
    /// don't record. Nil when Steam can't be asked.
    public func isLaunching(appID: String) async -> Bool? {
        guard let id = Int(appID) else { return nil }
        return await query("""
            const actions = await SteamClient.Apps.GetActiveGameActions();
            return actions.some(a => a.strActionName === "LaunchApp" && Object.values(a).some(v => String(v) === "\(id)"));
            """)
    }

    /// Whether the endpoint is up (Steam was started with the flag and its page has loaded).
    public func isAvailable() async -> Bool { await contextSocket() != nil }

    /// Steam's download overview ({ paused, update_appid, … }), which it hands to whoever registers for it.
    static let overviewScript = """
        new Promise(resolve => {
            let registration;
            const timer = setTimeout(() => resolve(null), 1500);
            registration = SteamClient.Downloads.RegisterForDownloadOverview(overview => {
                clearTimeout(timer);
                setTimeout(() => registration && registration.unregister && registration.unregister(), 0);
                resolve(overview);
            });
        })
        """

    // MARK: DevTools

    struct Target: Decodable {
        let title: String
        let webSocketDebuggerUrl: String?
    }

    /// The SharedJSContext page's DevTools socket, from Chromium's list of pages.
    func contextSocket() async -> URL? {
        guard let (data, response) = try? await session.data(from: base.appendingPathComponent("json/list")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let targets = try? JSONDecoder().decode([Target].self, from: data) else { return nil }
        guard let socket = targets.first(where: { $0.title == Self.contextTitle })?.webSocketDebuggerUrl,
              let url = URL(string: socket), url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        return url
    }

    /// Runs `body` (statements, `await` allowed) in Steam's page; true when it ran without throwing.
    func run(_ body: String) async -> Bool { await query(body + "\n return true;") ?? false }

    /// Runs `body`, which returns a boolean; nil when Steam can't be reached or the script threw.
    func query(_ body: String) async -> Bool? {
        guard let socket = await contextSocket() else { return nil }
        let expression = "(async () => { \(body) })()"
        let message = Self.evaluateMessage(id: 1, expression: expression)
        let task = session.webSocketTask(with: socket)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        do {
            try await task.send(.string(message))
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                let reply = try await task.receive()
                let text: String
                switch reply {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: continue
                }
                if let answer = Self.value(of: 1, in: text) { return answer }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// A DevTools `Runtime.evaluate` request that waits for the script's promise.
    static func evaluateMessage(id: Int, expression: String) -> String {
        let request: [String: Any] = [
            "id": id, "method": "Runtime.evaluate",
            "params": ["expression": expression, "awaitPromise": true, "returnByValue": true],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// For the reply to request `id`: true when the script returned true, false when it threw; nil for other
    /// messages (events, other requests).
    static func answer(to id: Int, in text: String) -> Bool? {
        guard let reply = reply(to: id, in: text) else { return nil }
        return reply.value == true
    }

    /// The boolean the script returned in the reply to request `id`: `.some(nil)` when it threw or returned
    /// something else, nil for other messages.
    static func value(of id: Int, in text: String) -> Bool?? {
        guard let reply = reply(to: id, in: text) else { return nil }
        return .some(reply.value)
    }

    private static func reply(to id: Int, in text: String) -> (value: Bool?, Void)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              object["id"] as? Int == id else { return nil }
        guard let result = object["result"] as? [String: Any], result["exceptionDetails"] == nil,
              let value = result["result"] as? [String: Any] else { return (nil, ()) }
        return (value["value"] as? Bool, ())
    }
}
