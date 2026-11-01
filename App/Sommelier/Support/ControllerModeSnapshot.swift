// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import SommelierKit
import SwiftUI

/// Draws Controller Mode off screen into a PNG (`SOMMELIER_CM_SNAPSHOT=<file>`), for checking its screens
/// without taking the display: debug builds only.
@MainActor
enum ControllerModeSnapshot {
    static func write(to path: String, model: AppModel) async {
        if ProcessInfo.processInfo.environment["SOMMELIER_CM_CARD"] != nil {
            let pads: [ControllerArrival.Pad] = [.init(name: "DualSense Wireless Controller", kind: .playStation, battery: 0.8),
                                                 .init(name: "Xbox Wireless Controller", kind: .xbox, battery: nil),
                                                 .init(name: "8BitDo Pro 2", kind: .other, battery: 0.4)]
            let view = VStack(spacing: 30) {
                ForEach(pads) { ControllerConnectCard(pad: $0) }
                ControllerConnectNote(pad: pads[0])
                HStack(spacing: 30) {
                    ForEach([ControllerKind.xbox, .playStation, .other], id: \.self) { PadIcon(kind: $0).frame(width: 80) }
                    PadIcon(kind: .playStation, disconnected: true).frame(width: 80)
                }.foregroundStyle(CM.ivory)
            }.padding(40).background(CM.ground)
            let host = NSHostingView(rootView: view.environment(model))
            host.frame = CGRect(x: 0, y: 0, width: 900, height: 1200)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; window.alphaValue = 0; window.orderBack(nil)
            try? await Task.sleep(for: .seconds(3))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        let size = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        CM.fit(size, size: model.settings.controllerMode?.size ?? .standard)
        ControllerLog.file = model.paths.logs.appendingPathComponent("Controller.log")
        model.storesWithAccount = Set(StoreKind.allCases)      // the library as it is on disk, without the stores' sign-in checks
        model.accountsChecked = true
        let host = NSHostingView(rootView: ControllerModeView(screenSize: size).environment(model).environment(model.artwork))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)            // laid out and drawn, behind everything
        window.alphaValue = 0
        try? await Task.sleep(for: .seconds(1))
        ControllerInput.shared.pretendControllerInUse()
        // Presses, as letters: b (close the note), e (next tab), arrows… (`SOMMELIER_CM_KEYS`).
        for key in ProcessInfo.processInfo.environment["SOMMELIER_CM_KEYS"] ?? "" {
            let event: ControllerEvent? = switch key {
            case "b": .b; case "a": .a; case "x": .x; case "e": .rightBumper; case "q": .leftBumper; case "g": .guide
            case "d": .move(.down); case "u": .move(.up); case "l": .move(.left); case "r": .move(.right); default: nil
            }
            if let event { ControllerLog.note("key \(key)"); ControllerInput.shared.onEvent?(event) }
            try? await Task.sleep(for: .milliseconds(400))
        }
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["SOMMELIER_CM_WAIT"] ?? "5") ?? 5))
        host.layoutSubtreeIfNeeded()
        var lines: [String] = []
        for game in model.games(for: .allGames).prefix(6) {
            let cover = model.coverURL(for: game), hero = model.heroURL(for: game)
            lines.append("\(game.title): cover \(cover?.absoluteString ?? "nil") loaded=\(model.artwork.image(cover) != nil) failed=\(model.artwork.hasFailed(cover)); hero \(hero?.absoluteString ?? "nil") loaded=\(model.artwork.image(hero) != nil) failed=\(model.artwork.hasFailed(hero))")
        }
        try? lines.joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
#endif
