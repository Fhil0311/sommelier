// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI
import WebKit

/// The store's own sign-in page in a sheet. When the page reaches its redirect, the one-time code goes to the
/// store's helper and the sheet closes. Nothing typed on the page is read, and nothing is kept between sign-ins.
struct StoreSignInView: View {
    @Environment(AppModel.self) private var model
    let kind: StoreKind
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s + 2) {
                kind.logo.resizable().scaledToFit().frame(width: 22, height: 22)
                Text("Sign In to \(kind.displayName)").font(.headline)
                if loading { LoadingGrape() }
                Spacer()
                Button("Cancel") { model.signIn = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s + 4)
            Divider()
            SignInWebView(kind: kind, loading: $loading) { code in
                Task { await model.finishSignIn(kind, code: code) }
            }
            Divider()
            Label("Your password goes only to \(kind.displayName). Sommelier keeps just the sign-in token, on this Mac.",
                  systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s + 2)
        }
        .frame(width: 540, height: 640)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let kind: StoreKind
    @Binding var loading: Bool
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()          // no cookies left behind
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Store pages turn away browsers they don't know; this is the Safari that WebKit is.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        if let url = StoreSignIn.url(for: kind) { view.load(URLRequest(url: url)) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: SignInWebView
        private var delivered = false

        init(_ parent: SignInWebView) { self.parent = parent }

        private func deliver(_ code: String) {
            guard !delivered else { return }
            delivered = true
            parent.onCode(code)
        }

        // GOG: the code is in the redirect's address; it never needs to load.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if parent.kind == .gog, let url = action.request.url, let code = StoreSignIn.gogCode(redirect: url) {
                decisionHandler(.cancel)
                deliver(code)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        // Epic: the code is in the text of the redirect page.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard parent.kind == .epic, let url = webView.url, StoreSignIn.isEpicCodePage(url) else { return }
            webView.evaluateJavaScript("document.body.innerText") { [weak self] result, _ in
                if let text = result as? String, let code = StoreSignIn.epicCode(pageText: text) { self?.deliver(code) }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        // "Sign in with Google/Apple…" opens a new window: keep it in this one.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
    }
}
