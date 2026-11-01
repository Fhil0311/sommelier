// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreServices
import Foundation

/// Calls a closure when anything changes in a folder tree, using FSEvents (no polling). Bursts of changes
/// are coalesced by FSEvents' `latency`. `relevant`, when given, picks the changed paths that matter: a burst of
/// only other paths (a game writing its logs inside the watched tree) calls nothing.
public final class DirectoryWatcher: @unchecked Sendable {
    private let handler: @Sendable () -> Void
    private let relevant: (@Sendable (String) -> Bool)?
    private let events = DispatchQueue(label: "sommelier.directory-watcher")
    private var eventStream: FSEventStreamRef?

    /// The folder may not exist yet; then its closest existing ancestor is watched, so creating it is noticed.
    public init(
        directory: URL, latency: TimeInterval = 1.0, relevant: (@Sendable (String) -> Bool)? = nil,
        onChange: @escaping @Sendable () -> Void
    ) {
        handler = onChange
        self.relevant = relevant
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagUseCFTypes)
        let paths = [Self.closestExisting(directory).path] as CFArray
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, Self.relay, &context, paths,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, events)
        FSEventStreamStart(created)
        eventStream = created
    }

    /// Ends watching. Safe to call more than once.
    public func stop() { teardown() }

    deinit { teardown() }

    private func teardown() {
        guard let active = eventStream else { return }
        eventStream = nil
        FSEventStreamStop(active)
        FSEventStreamInvalidate(active)
        FSEventStreamRelease(active)
    }

    /// FSEvents callback: forwards to the watcher whose pointer was put in the stream context.
    private static let relay: FSEventStreamCallback = { _, context, count, paths, _, _ in
        guard let owner = context else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(owner).takeUnretainedValue()
        if let relevant = watcher.relevant {
            let changed = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            guard changed.isEmpty || changed.prefix(count).contains(where: relevant) else { return }
        }
        watcher.handler()
    }

    /// For `relevant`: a path directly in `folder` (not deeper), e.g. Steam's `appmanifest_*.acf` in `steamapps`.
    public static func isDirectlyIn(_ folder: URL, _ path: String) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        // The parent resolved, not the path: a deleted file's own path doesn't resolve any more.
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        return parent == base
    }

    private static func closestExisting(_ url: URL) -> URL {
        var candidate = url
        while candidate.pathComponents.count > 1, !FileManager.default.fileExists(atPath: candidate.path) {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}
