// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Network
import SwiftUI

/// A store trailer playing silently on a loop behind a banner. The art underneath shows whenever the video isn't
/// really playing: until its first frame is ready, while it stalls (a slow connection), and for good once it fails,
/// stalls again and again, or doesn't start within a few seconds. In Low Data Mode it isn't loaded at all.
struct TrailerPlayer: NSViewRepresentable {
    let url: URL
    var muted = true
    var fill = true

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.start(url: url, muted: muted, fill: fill)
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        if view.url != url { view.start(url: url, muted: muted, fill: fill) }
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: ()) { view.stop() }

    final class PlayerView: NSView {
        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var ready: NSKeyValueObservation?
        private let playerLayer = AVPlayerLayer()
        private var watchdog: Timer?
        private var started = Date(), stalledSince: Date?, stalls = 0, everPlayed = false, shown = false
        /// Give up when the first frame takes longer than this, or after this many stalls.
        private static let startLimit: TimeInterval = 8, stallLimit = 3
        private static let lowData = LowDataMode()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.opacity = 0
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        func start(url: URL, muted: Bool, fill: Bool) {
            stop()
            self.url = url
            guard !Self.lowData.isOn else { return }               // the art only: no video over a metered connection
            started = Date(); stalledSince = nil; stalls = 0; everPlayed = false
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = muted
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer.player = player
            playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
            self.player = player
            player.play()
            watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }

        /// Shows the video only while it plays; falls back to the art for good when it can't.
        private func check() {
            guard let player else { return }
            let failed = player.currentItem?.status == .failed || player.status == .failed
            let playing = player.timeControlStatus == .playing && playerLayer.isReadyForDisplay
            if playing {
                everPlayed = true; stalledSince = nil
                show(true)
                return
            }
            if failed || (!everPlayed && Date().timeIntervalSince(started) > Self.startLimit) { giveUp(); return }
            if everPlayed, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                if stalledSince == nil { stalledSince = Date(); stalls += 1 }
                if stalls > Self.stallLimit { giveUp(); return }
                if let since = stalledSince, Date().timeIntervalSince(since) > 1 { show(false) }   // frozen: the art again
            }
        }

        private func show(_ on: Bool) {
            guard on != shown else { return }
            shown = on
            CATransaction.begin(); CATransaction.setAnimationDuration(on ? 0.6 : 0.3)
            playerLayer.opacity = on ? 1 : 0
            CATransaction.commit()
        }

        /// The connection or the file can't keep up: the art stays, and nothing more is downloaded.
        private func giveUp() {
            let keep = url
            stop()
            url = keep                                             // so the same trailer isn't retried by an update
        }

        func stop() {
            watchdog?.invalidate(); watchdog = nil
            player?.pause()
            ready = nil; looper = nil; player = nil
            playerLayer.player = nil
            playerLayer.opacity = 0
            shown = false
        }
    }
}

/// Whether the Mac is on a connection the user marked to save data (Low Data Mode), watched once for the app.
private final class LowDataMode: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var constrained = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.constrained = path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "sommelier.low-data"))
    }

    var isOn: Bool { lock.withLock { constrained } }
}
