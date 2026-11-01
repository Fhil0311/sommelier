// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI
import WebKit

/// Nexus Mods for one game, as the site is: a plain browser session (the player signs in once; the cookies
/// stay), nothing parsed, no key. A file the page hands out is taken by `WKDownload` into the game's store
/// folder and goes on to the mods flow, or to a loader waiting for its archive. Kept per game on the model so
/// the page and a download in progress survive a change of tab. Nexus's "Mod Manager Download" (`nxm://`)
/// needs its API, which Sommelier doesn't use: such a link is stopped with a word to use Manual download.
@MainActor @Observable final class NexusBrowser: NSObject {
    enum Status: Equatable {
        case idle
        case downloading(String)
        case managerLink
        case notArchive
        /// The loader's page gave a file that isn't the loader's (the profile's pattern), by the loader's name.
        case wrongFile(String)
    }

    let game: Game
    let webView: WKWebView
    /// Where downloads land: `<store>/.downloads/<id>/`, each in its own folder, removed once taken.
    let folder: URL
    private(set) var loading = false
    var status: Status = .idle
    /// Called with the archive and the page it came from.
    private let onDownload: @MainActor (URL, URL?) -> Void
    private var destinations: [ObjectIdentifier: URL] = [:]

    /// One cookie jar for Nexus in this app, apart from the stores' sign-in pages (which keep none).
    private static let dataStoreID = UUID(uuidString: "9B1F6E1C-2C3B-4D7E-8A6F-5E0C3A2B1D44")!

    init(game: Game, folder: URL, onDownload: @escaping @MainActor (URL, URL?) -> Void) {
        self.game = game
        self.folder = folder
        self.onDownload = onDownload
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.dataStoreID)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ url: URL) {
        status = .idle
        webView.load(URLRequest(url: url))
    }

    var canGoBack: Bool { webView.canGoBack }
    func goBack() { webView.goBack() }
    func reload() { webView.reload() }

    /// The game's Nexus front page.
    static func home(domain: String) -> URL? { URL(string: "https://www.nexusmods.com/\(domain)") }

    /// A mod's files tab on Nexus, where its downloads are.
    static func files(domain: String, mod: Int) -> URL? { URL(string: "https://www.nexusmods.com/\(domain)/mods/\(mod)?tab=files") }
}

extension NexusBrowser: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.scheme?.lowercased() == "nxm" {
            status = .managerLink
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // A file the page can't show is a download; an archive served as something the page could show
        // (octet-stream pages are rare, but zip as text happens) goes by its name.
        let name = navigationResponse.response.suggestedFilename ?? ""
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(!navigationResponse.canShowMIMEType || attachment || LocalFileSource.isArchive(name) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false }

    // A link that opens a new window stays in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let name = (suggestedFilename as NSString).lastPathComponent
        guard LocalFileSource.isArchive(name) else {
            status = .notArchive
            completionHandler(nil)
            return
        }
        let home = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) } catch { completionHandler(nil); return }
        let target = home.appendingPathComponent(name)
        destinations[ObjectIdentifier(download)] = target
        status = .downloading(name)
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let target = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        status = .idle
        onDownload(target, download.originalRequest?.url ?? webView.url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let target = destinations.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: target.deletingLastPathComponent())
        }
        status = .idle
    }
}

/// The Nexus tab: a strip saying where downloads go (or which loader the page is open for), and the site.
struct NexusTabView: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let domain: String

    var body: some View {
        let browser = model.nexusBrowser(for: game, domain: domain)
        let fetch = model.modBrowser.flatMap { $0.gameID == game.id ? $0 : nil }
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Button { browser.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(!browser.canGoBack).accessibilityLabel(Text("Back"))
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).accessibilityLabel(Text("Reload"))
                if browser.loading { LoadingGrape() }
                Group {
                    switch browser.status {
                    case .downloading(let name): Text("Downloading \(name)…")
                    case .managerLink: Text("Mod Manager download doesn't work here. Choose Manual download instead.")
                    case .notArchive: Text("Only mod archives (zip, 7z, rar) are taken from this page.")
                    case .wrongFile(let name): Text("This isn't the file Sommelier expects for \(name).")
                    case .idle:
                        if let fetch { Text("Download \(fetch.name) from this page and Sommelier will install it.") }
                        else { Text("Downloads from this page go straight into \(game.title).") }
                    }
                }
                .foregroundStyle(browser.status == .idle ? Theme.onDark : Theme.wineLight)
                .lineLimit(2)
                Spacer(minLength: 0)
                if let fetch {
                    Button("Cancel") { model.cancelBrowserFetch(fetch) }.buttonStyle(.textLink)
                } else {
                    Button("Open in Browser") { model.openNexusInBrowser(game, url: browser.webView.url ?? NexusBrowser.home(domain: domain)) }
                        .buttonStyle(.textLink)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(Theme.fill(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            NexusWebHost(browser: browser)
                .frame(height: 640)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line(0.18)))
        }
        .onAppear { if let fetch { browser.load(fetch.url) } }
        .onChange(of: fetch?.id) { _, _ in if let fetch { browser.load(fetch.url) } }
    }
}

/// Hosts the browser's web view, which lives on the model.
private struct NexusWebHost: NSViewRepresentable {
    let browser: NexusBrowser

    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
