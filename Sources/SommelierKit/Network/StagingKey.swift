// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The test copy of the services (staging, on workers.dev) answers only requests that carry its password. A debug
/// build started with SOMMELIER_STAGING_KEY adds it to every request for the hosts SOMMELIER_API_URL and
/// SOMMELIER_DECANTER_URL name, whatever URLSession sends them; nothing else gets it, and without the variable this
/// does nothing.
public final class StagingKey: URLProtocol, @unchecked Sendable {
    public static let header = "X-Sommelier-Staging-Key"
    nonisolated(unsafe) static var key: String?
    nonisolated(unsafe) static var hosts: Set<String> = []
    private static let marker = "SommelierStagingKeyAdded"
    private var forwarded: URLSessionDataTask?

    /// Starts adding the key, when the environment gives one. Call once, early.
    public static func install(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let value = environment["SOMMELIER_STAGING_KEY"], !value.isEmpty else { return }
        key = value
        hosts = Set(["SOMMELIER_API_URL", "SOMMELIER_DECANTER_URL"].compactMap { environment[$0].flatMap(URL.init(string:))?.host })
        URLProtocol.registerClass(StagingKey.self)
    }

    static func wants(_ request: URLRequest) -> Bool {
        guard key != nil, let host = request.url?.host, hosts.contains(host) else { return false }
        return URLProtocol.property(forKey: marker, in: request) == nil
    }

    public override class func canInit(with request: URLRequest) -> Bool { wants(request) }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        guard let copy = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        copy.setValue(Self.key, forHTTPHeaderField: Self.header)
        URLProtocol.setProperty(true, forKey: Self.marker, in: copy)
        forwarded = URLSession.shared.dataTask(with: copy as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            if let error { self.client?.urlProtocol(self, didFailWithError: error) } else { self.client?.urlProtocolDidFinishLoading(self) }
        }
        forwarded?.resume()
    }

    public override func stopLoading() { forwarded?.cancel() }
}
