// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import SommelierKit
import SwiftUI

extension TuningLevel {
    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .ultra: String(localized: "Ultra")
        }
    }
}

/// Shown once, before the first launch Sommelier tunes: what it does and how to turn it off.
struct TuningNoticeView: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m - 4) {
                Image(systemName: "slider.horizontal.3").font(.title).foregroundStyle(Theme.wineLight)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sommelier matches graphics to your Mac").font(.headline)
                    Text("Before a game's first launch, Sommelier sets its resolution and graphics quality for this Mac, so games run smoothly. Settings brought from a Windows PC, often far too high for a Mac, are replaced too.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("For this Mac") {
                Text(verbatim: "\(model.tuningLevel(for: game).title) · \(resolution)").monospacedDigit()
            }
            .font(.callout)
            Label("Your own settings are kept: Restore My Settings on a game's page puts them back. Turn this off for every game in Settings.", systemImage: "arrow.uturn.backward")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don't Match") { model.answerTuningNotice(tune: false) }
                Spacer()
                Button("Match and Play") { model.answerTuningNotice(tune: true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 460)
    }

    private var resolution: String {
        let r = model.macPower.resolution(for: model.tuningLevel(for: game))
        return "\(r.width)×\(r.height)"
    }
}

/// The game page's graphics button, beside "…": our grape, with speed lines while Turbo is on, plain when it's off,
/// faint when the game also plays on its own settings. Clicking opens the two switches.
struct GraphicsButton: View {
    @Environment(AppModel.self) private var model
    let game: Game
    /// HDR display and a game drawn through DXMT: the HDR switch joins the popover.
    var hdrAvailable = false
    /// A game drawn through D3DMetal (DirectX 12): Turbo is shown off, as not available.
    var directX12 = false
    @State private var open = false
    @Environment(\.pageScheme) private var pageScheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Installed Windows games only: before the files are there, nothing is known about the game's graphics
        // (DirectX 11 or 12) and nothing can be matched to the Mac; Mac versions' graphics aren't Sommelier's.
        if !game.isNative, game.isInstalled {
            let state = GraphicsState(model: model, game: game, directX12: directX12)
            Button { open.toggle() } label: {
                TurboMark(lines: state.turbo && !directX12, hdr: hdrAvailable && model.profile(for: game).hdr).frame(width: 19, height: 19).opacity((state.turbo && !directX12) || state.tuned ? 1 : 0.4)
            }
            .buttonStyle(GlassCircleButtonStyle())
            .help(state.summary)
            .accessibilityLabel(state.summary)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                GraphicsPopover(game: game, hdrAvailable: hdrAvailable, directX12: directX12)
                    .environment(\.colorScheme, pageScheme ?? scheme)       // opens over the page, not the art
            }
        }
    }
}

/// What the graphics button and its popover show for a game.
@MainActor private struct GraphicsState {
    let tuned: Bool, turbo: Bool, turboPossible: Bool, failed: Bool, canTune: Bool
    let level: TuningLevel?, summary: String

    init(model: AppModel, game: Game, directX12: Bool = false) {
        let data = model.library.userData[game.id]
        turboPossible = model.macPower.appleSilicon
        failed = data?.turboFailed == true
        turbo = AppModel.turboReady && turboPossible && model.turboWanted(for: game) && !failed && !model.profile(for: game).retina
        // A record from before that changed nothing (an older version kept those) doesn't count as matched.
        let record = data?.tuning.flatMap { $0.parts.isEmpty ? nil : $0 }
        canTune = record != nil || model.canTune(game)
        // A game already played without matching (matching was off then) keeps the player's settings.
        tuned = record != nil || (canTune && data?.tuningOff != true && model.tunesGames && data?.lastPlayed == nil)
        level = record?.level
        let quality = level.map(\.title) ?? (tuned ? String(localized: "Matched at launch") : String(localized: "Your settings"))
        summary = turbo && !directX12 ? String(localized: "Graphics: \(quality), Turbo on") : String(localized: "Graphics: \(quality)")
    }
}

private struct GraphicsPopover: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let hdrAvailable: Bool
    let directX12: Bool

    var body: some View {
        let state = GraphicsState(model: model, game: game, directX12: directX12)
        let data = model.library.userData[game.id]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Graphics").font(.system(size: 13, weight: .bold))
                Spacer()
                Text(verbatim: MacSystem.current.chip).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            row(title: "Matched to This Mac", detail: tuningDetail(state), info: state.canTune ? TuningHint.text : nil, isOn: Binding(
                get: { state.tuned },
                set: { on in if on { Task { await model.tuneNow(game) } } else { model.restoreTuning(game) } }))
                .disabled(model.isActive(game) || (!state.tuned && !game.isInstalled) || !state.canTune)
                .opacity(state.canTune ? 1 : 0.6)
            if data?.tuning?.cloudSynced == true {
                Text("Steam Cloud syncs this game's settings file: your other computers may get these settings too.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if state.turboPossible {
                Divider()
                if !AppModel.turboReady {
                    row(title: "Turbo", detail: String(localized: "Soon"), info: TurboPlan.text, isOn: .constant(false), enabled: false)
                } else if directX12 {
                    row(title: "Turbo", detail: String(localized: "Not available: the game uses DirectX 12."), isOn: .constant(false), enabled: false)
                } else {
                    row(title: "Turbo",
                        detail: state.failed ? String(localized: "Turned off: the game didn't start with it.")
                                             : String(localized: "More frames, a slightly softer picture."),
                        isOn: Binding(get: { state.turbo }, set: { on in
                            model.setTurbo(on, for: game)
                        }))
                }
            }
            if hdrAvailable {
                let profile = model.profile(for: game)
                Divider()
                row(title: "HDR", detail: String(localized: "Lets the game see this display as HDR, so HDR can be turned on in the game's own settings."),
                    isOn: Binding(get: { profile.hdr }, set: { var p = profile; p.hdr = $0; model.setProfile(p, for: game) }))
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func tuningDetail(_ state: GraphicsState) -> String {
        if !state.canTune { return String(localized: "Sommelier can't match this game's settings yet.") }
        if let level = state.level {
            let r = model.macPower.resolution(for: level)
            return "\(level.title) · \(r.width)×\(r.height)"
        }
        return state.tuned ? String(localized: "Matched before the next launch.") : String(localized: "The game plays on your own settings.")
    }

    private func row(title: LocalizedStringKey, detail: String, info: String? = nil, isOn: Binding<Bool>, enabled: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let info { InfoIcon(text: info) }
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .opacity(enabled ? 1 : 0.6)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.wine).disabled(!enabled)
                .opacity(enabled ? 1 : 0.6)
        }
    }
}

/// Behind the ⓘ next to "Matched to This Mac": what happens to the switch when the player changes settings in the game.
enum TuningHint {
    static var text: String {
        String(localized: "Still in development: matching works for some games so far, not all. If you change settings in the game itself and want the preset back, turn this switch off and on again.")
    }
}

/// What Turbo becomes in the next version, behind an ⓘ next to its switch while it is off.
enum TurboPlan {
    static var text: String {
        String(localized: "Coming in the next version: Turbo will give more frames. For that we're reworking Sommelier's engine, the part that turns a game's graphics into Metal on your Mac.")
    }

    /// The ⓘ: its own small popover on hover or click (a plain `.help` tooltip doesn't show inside a popover).
    static func icon(_ text: String) -> some View { InfoIcon(text: text) }
}

private struct InfoIcon: View {
    let text: String
    @State private var shown = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onHover { inside in
                hoverTask?.cancel()
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(inside ? 150 : 250))
                    if !Task.isCancelled { shown = inside }
                }
            }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading).padding(12)
                    .onHover { inside in
                        hoverTask?.cancel()
                        if !inside { hoverTask = Task { try? await Task.sleep(for: .milliseconds(250)); if !Task.isCancelled { shown = false } } }
                    }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

/// The grape mark with speed lines on its left: Turbo. Without the lines the plain grape sits centred; switching
/// slides it right as the lines come in, so the mark never looks off-centre.
struct TurboMark: View {
    var lines: Bool
    /// HDR on: a leaf grows on the stem, as on the full logo.
    var hdr = false

    var body: some View {
        TurboMarkShape(progress: lines ? 1 : 0, glint: hdr ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: lines)
            .animation(.easeInOut(duration: 0.3), value: hdr)
            .accessibilityHidden(true)
    }
}

private struct TurboMarkShape: View, @MainActor Animatable {
    var progress: Double
    var glint: Double
    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, glint) }
        set { progress = newValue.first; glint = newValue.second }
    }

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 24
            ctx.scaleBy(x: k, y: k)
            // The grape alone spans x 5.8–22.2: 2 points left of centre puts it in the middle.
            ctx.translateBy(x: -2 * (1 - progress), y: 0)
            var stem = Path()
            stem.move(to: CGPoint(x: 14, y: 6.3)); stem.addLine(to: CGPoint(x: 14, y: 4.6))
            stem.addCurve(to: CGPoint(x: 16.4, y: 2.4), control1: CGPoint(x: 14, y: 3.4), control2: CGPoint(x: 14.9, y: 2.4))
            ctx.stroke(stem, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            for (x, y) in [(11.6, 18.2), (8.7, 12.4), (14.5, 12.4), (5.8, 6.6), (11.6, 6.6), (17.4, 6.6)] {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 4.8, height: 4.8), cornerRadius: 1), with: .foreground)
            }
            if glint > 0.01 {
                // The leaf grows from where it joins the stem.
                var leaf = Path()
                leaf.move(to: CGPoint(x: 15.6, y: 4.4))
                leaf.addCurve(to: CGPoint(x: 23, y: 1.8), control1: CGPoint(x: 17.2, y: 1.4), control2: CGPoint(x: 20.2, y: 0.6))
                leaf.addCurve(to: CGPoint(x: 15.6, y: 4.4), control1: CGPoint(x: 21.4, y: 4.6), control2: CGPoint(x: 18.4, y: 5.6))
                let grow = 0.4 + 0.6 * glint
                var layer = ctx
                layer.opacity = glint
                layer.translateBy(x: 15.6, y: 4.4)
                layer.scaleBy(x: grow, y: grow)
                layer.translateBy(x: -15.6, y: -4.4)
                layer.fill(leaf, with: .foreground)
            }
            if progress > 0.01 {
                var speed = Path()
                let pull = 3 * (1 - progress)           // the lines come in from the grape's side
                speed.move(to: CGPoint(x: 1.5 + pull, y: 9)); speed.addLine(to: CGPoint(x: 4.5, y: 9))
                speed.move(to: CGPoint(x: 1 + pull, y: 14.8)); speed.addLine(to: CGPoint(x: 6, y: 14.8))
                speed.move(to: CGPoint(x: 3 + pull, y: 20.6)); speed.addLine(to: CGPoint(x: 9, y: 20.6))
                var layer = ctx
                layer.opacity = progress
                layer.stroke(speed, with: .foreground, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
    }
}

/// The loading mark: three of the grape's berries slowly dim and come back in turn, like breathing.
typealias LoadingGrape = SizedBreathingGrape

struct SizedBreathingGrape: View {
    var body: some View { BreathingGrape().frame(width: 14, height: 14) }
}

/// The breathing grape itself.
struct BreathingGrape: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let k = min(size.width, size.height) / 24
                ctx.scaleBy(x: k, y: k)
                var stem = Path()
                stem.move(to: CGPoint(x: 12, y: 6.3)); stem.addLine(to: CGPoint(x: 12, y: 4))
                stem.addCurve(to: CGPoint(x: 14.9, y: 1.3), control1: CGPoint(x: 12, y: 2.5), control2: CGPoint(x: 13.2, y: 1.3))
                ctx.stroke(stem, with: .foreground, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                let berries: [(CGFloat, CGFloat, Double?)] = [(9.5, 18.8, 0), (6.45, 12.7, 0.25), (12.55, 12.7, nil),
                                                             (3.4, 6.6, 0.5), (9.5, 6.6, nil), (15.6, 6.6, nil)]
                for (x, y, delay) in berries {
                    var layer = ctx
                    if let delay, !reduceMotion { layer.opacity = 0.675 + 0.325 * cos((t / 2 - delay) * 2 * .pi) }
                    layer.fill(Path(roundedRect: CGRect(x: x, y: y, width: 5, height: 5), cornerRadius: 1.1), with: .foreground)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The settings mark: eight berry pixels around a square, a gear made of the grape's own pixels.
/// It turns a quarter when the pointer comes over it.
struct BerryGear: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false

    /// The eight small berries round a ring, in a 24-point square. Drawn with plain shapes, not a Canvas: a Canvas in a
    /// sidebar foot sometimes didn't draw until something else made the view redraw (the icon missing at launch).
    private static let berries: [(x: CGFloat, y: CGFloat)] = [(10, 1.5), (10, 18.5), (1.5, 10), (18.5, 10), (4, 4), (16, 4), (4, 16), (16, 16)]

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width, geo.size.height) / 24
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.berries.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: k, style: .continuous)
                        .frame(width: 4 * k, height: 4 * k)
                        .offset(x: Self.berries[i].x * k, y: Self.berries[i].y * k)
                }
                RoundedRectangle(cornerRadius: 2.4 * k, style: .continuous)
                    .stroke(lineWidth: 1.8 * k)
                    .frame(width: 9 * k, height: 9 * k)
                    .offset(x: 7.5 * k, y: 7.5 * k)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .rotationEffect(.degrees(turned ? 90 : 0))
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6), value: turned)
        .onHover { if $0 { turned.toggle() } }
        .accessibilityHidden(true)
    }
}
