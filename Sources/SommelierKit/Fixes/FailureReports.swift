// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A launch failure the player chose to send from the "didn't start" sheet, after seeing exactly what goes:
/// the scrubbed diagnostics (`LaunchDiagnostics`), which known problems they matched, and the app's version
/// (`POST /v1/failures`). The client id is the install's random id; the service keeps only a salted hash of it.
public struct FailureReport: Codable, Equatable, Sendable {
    public var client: String
    public var game: CompatibilityReport.GameRef
    public var diagnostics: LaunchDiagnostics
    public var matched: [String]
    public var sommelier: CompatibilityReport.Setup

    public init(client: String, game: CompatibilityReport.GameRef, diagnostics: LaunchDiagnostics, matched: [String],
                sommelier: CompatibilityReport.Setup) {
        self.client = client; self.game = game; self.diagnostics = diagnostics; self.matched = matched; self.sommelier = sommelier
        // The mod loader's log stays on the Mac: it lists every mod it loads, those put in by hand too, whose names
        // no scrub can know. The fixes have read it already; the report carries the `mods` flag.
        self.diagnostics.modLogTail = nil
    }

    /// Exactly what is sent, for the preview.
    public var preview: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public enum SendError: Error, Equatable { case refused(Int), unreachable }

    public func send(to baseURL: URL? = nil, session: URLSession = .shared, clientVersion: String) async throws {
        let override = ProcessInfo.processInfo.environment["SOMMELIER_API_URL"].flatMap(URL.init(string:))
        var request = URLRequest(url: (baseURL ?? override ?? CompatibilityReporter.defaultURL).appendingPathComponent("v1/failures"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Sommelier/\(clientVersion)", forHTTPHeaderField: ShaderShare.clientHeader)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(self)
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { throw SendError.unreachable }
        guard (200..<300).contains(http.statusCode) else { throw SendError.refused(http.statusCode) }
    }
}
