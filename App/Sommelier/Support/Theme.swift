// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SommelierKit
import SwiftUI

/// Sommelier's design system: one place for spacing, radii, type and colour, so every screen agrees.
///
/// Follows Apple's macOS Human Interface Guidelines and the look of Apple Games in macOS 26: a neutral dark
/// surface, colour taken from the game's own art and faded into that surface, system text styles, glass for
/// controls that sit on top of artwork, and an 8-point spacing grid.
enum Theme {
    // MARK: Spacing (8-point grid)
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        /// Left and right content margin on every page.
        static let margin: CGFloat = 40
        /// Between sections on a page.
        static let section: CGFloat = 36
    }

    // MARK: Radii
    enum Radius {
        static let cover: CGFloat = 10
        static let card: CGFloat = 16
        static let thumbnail: CGFloat = 8
    }

    // MARK: Colour ("Grape": warm near-black, cream text, wine accents; in light mode the same on paper)
    // Each colour has a dark and a light value and follows the view's appearance (NSApp's, from Settings or macOS),
    // so screens don't need to know which one is on. Over a game's art everything stays light-on-dark: those views
    // keep `.environment(\.colorScheme, .dark)` and white.

    /// A colour with a dark-appearance and a light-appearance value.
    static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// The light appearance's paper, as a fixed colour: what art fades into on light pages (under the art the
    /// appearance is forced dark, so `surface` would be the dark one there).
    static let paper = Color(red: 0xf4 / 255, green: 0xed / 255, blue: 0xe3 / 255)

    /// The bottom of a header's art: into the game's colour on dark pages, into paper tinted with it on light ones.
    @ViewBuilder static func artFade(into tint: Color, page scheme: ColorScheme, from start: Double = 0.55) -> some View {
        if scheme == .dark {
            LinearGradient(stops: [.init(color: .clear, location: start), .init(color: tint, location: 1)], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(stops: [.init(color: .clear, location: start), .init(color: paper, location: 1)], startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .clear, location: start), .init(color: tint.opacity(0.10), location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Deep wine red: the accent (Turbo, switches, the filling grape). The same in both appearances.
    static let wine = Color(red: 0x8e / 255, green: 0x23 / 255, blue: 0x35 / 255)
    /// Only for "Won't run" (and wine marks that must read on dark art).
    static let wineLight = Color(red: 0xb8 / 255, green: 0x40 / 255, blue: 0x4f / 255)
    /// Cards and placeholders: graphite in the dark, milk (white over paper) in the light. Wine is a signal colour,
    /// never a fill for content.
    static let graphite = adaptive(dark: rgb(0x2c2523), light: rgb(0xfaf7f2))
    /// What stands in for a game's art when it has none: a flat card.
    static var placeholder: some View {
        graphite.overlay(Rectangle().strokeBorder(line(0.08)))
    }
    /// The neutral surface behind pages: a warm near-black, like the inside of a cellar; paper in the light.
    static let surface = adaptive(dark: rgb(0x1e1a18), light: rgb(0xf4ede3))
    /// Text on primary buttons: dark ink on cream; cream on graphite in the light.
    static let ink = adaptive(dark: rgb(0x141110), light: rgb(0xf3ece2))
    /// The fill of primary buttons (Play, Install, the chosen filter): cream; graphite in the light, where cream
    /// would vanish into the paper.
    static let cream = adaptive(dark: rgb(0xf3ece2), light: rgb(0x221b19))
    /// Text and marks over a game's art: always light, whatever the appearance.
    static let onArt = Color(red: 0xef / 255, green: 0xe6 / 255, blue: 0xda / 255)
    /// Text on the page. Secondary stays at 72% (dark) so it keeps a 4.5:1 contrast on the darkest tints; the light
    /// appearance's "stone" is graphite at about 60%.
    static let onDark = adaptive(dark: rgb(0xefe6da), light: rgb(0x221b19))
    static let onDarkSecondary = adaptive(dark: rgb(0xefe6da, 0.72), light: rgb(0x221b19, 0.62))
    static let onDarkTertiary = adaptive(dark: rgb(0xefe6da, 0.55), light: rgb(0x221b19, 0.48))
    static let hairline = adaptive(dark: rgb(0xffffff, 0.14), light: rgb(0x221b19, 0.10))
    /// A soft fill for cards, rows and chips: white `amount` over the dark surface, milk over the paper.
    static func fill(_ amount: Double) -> Color {
        guard amount > 0 else { return .clear }                 // "no fill" (an unselected row, no hover) stays none
        return adaptive(dark: rgb(0xffffff, CGFloat(amount)), light: rgb(0xffffff, CGFloat(min(0.85, 0.35 + amount * 2.5))))
    }
    /// A thin line or outline: white `amount` in the dark, graphite in the light.
    static func line(_ amount: Double) -> Color {
        adaptive(dark: rgb(0xffffff, CGFloat(amount)), light: rgb(0x221b19, CGFloat(min(0.2, amount * 0.6))))
    }
    /// Shadows: black in the dark, warm brown in the light.
    static func shadow(_ amount: Double) -> Color {
        adaptive(dark: rgb(0x000000, CGFloat(amount)), light: rgb(0x3c281e, CGFloat(amount * 0.4)))
    }

    /// A page background that starts in the game's colour and settles into the neutral surface.
    /// In the light appearance the art's colour dissolves into paper tinted with it.
    static func tintedBackground(_ tint: Color?, heroHeight: CGFloat) -> some View {
        TintedBackground(tint: tint, heroHeight: heroHeight)
    }

    // MARK: Type (system text styles wherever one fits)
    enum Font {
        /// The name of a game over its art. Fixed size: it sits on imagery, not in running text.
        static let hero = SwiftUI.Font.system(size: 34, weight: .bold)
        static let pageTitle = SwiftUI.Font.largeTitle.bold()
        static let section = SwiftUI.Font.title2.bold()
        static let cardTitle = SwiftUI.Font.callout.weight(.semibold)
        static let meta = SwiftUI.Font.caption
        static let fact = SwiftUI.Font.title3.weight(.medium)
        /// Small uppercase labels ("CONTINUE PLAYING", "DEVELOPER").
        static let eyebrow = SwiftUI.Font.system(size: 11, weight: .semibold)
    }

    /// An uppercase eyebrow label, like Apple Games' "LET'S PLAY".
    static func eyebrow(_ text: String, color: Color = onDarkSecondary) -> some View {
        Text(text.uppercased()).font(Font.eyebrow).tracking(0.9).foregroundStyle(color)
    }

    /// The bottom-of-image scrim that keeps white text readable on any artwork.
    static var scrim: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.55), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Status mark

/// Six grapes in rows of three, two and one under a stem. Filled grapes count up from the bottom, like a pour;
/// the rest are outlines. Drawn in the foreground style, on a 24-point grid.
struct GrapeMark: View {
    var filled: Int
    var dashed = false
    var struck = false
    /// The full sprig, as on the logo: a leaf on the stem. "Works" only.
    var leaf = false

    static let grapes: [CGPoint] = [.init(x: 9.5, y: 18.8), .init(x: 6.45, y: 12.7), .init(x: 12.55, y: 12.7),
                                            .init(x: 3.4, y: 6.6), .init(x: 9.5, y: 6.6), .init(x: 15.6, y: 6.6)]

    /// The stem curves to the right like the logo's own, at every size; small marks get a slightly thicker line
    /// so the curve still reads.
    static func drawStem(in ctx: inout GraphicsContext, side: CGFloat) {
        var stem = Path()
        stem.move(to: CGPoint(x: 12, y: 6.3))
        stem.addLine(to: CGPoint(x: 12, y: 4))
        stem.addCurve(to: CGPoint(x: 14.9, y: 1.3), control1: CGPoint(x: 12, y: 2.5), control2: CGPoint(x: 13.2, y: 1.3))
        ctx.stroke(stem, with: .foreground, style: StrokeStyle(lineWidth: side < 20 ? 1.8 : 1.5, lineCap: .round, lineJoin: .round))
    }

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 24
            ctx.translateBy(x: (size.width - 24 * k) / 2, y: (size.height - 24 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            GrapeMark.drawStem(in: &ctx, side: 24 * k)
            if leaf {
                var l = Path()
                l.move(to: CGPoint(x: 13.2, y: 3.6))
                l.addCurve(to: CGPoint(x: 21.4, y: 1.2), control1: CGPoint(x: 15, y: 0.9), control2: CGPoint(x: 18.4, y: 0.1))
                l.addCurve(to: CGPoint(x: 13.2, y: 3.6), control1: CGPoint(x: 19.8, y: 3.8), control2: CGPoint(x: 16.4, y: 4.8))
                ctx.fill(l, with: .foreground)
            }
            for (i, p) in Self.grapes.enumerated() {
                if i < filled {
                    ctx.fill(Path(roundedRect: CGRect(x: p.x, y: p.y, width: 5, height: 5), cornerRadius: 1.1), with: .foreground)
                } else {
                    let outline = Path(roundedRect: CGRect(x: p.x + 0.45, y: p.y + 0.45, width: 4.1, height: 4.1), cornerRadius: 0.9)
                    ctx.stroke(outline, with: .foreground, style: StrokeStyle(lineWidth: 0.9, dash: dashed ? [1.2, 1] : []))
                }
            }
            if struck {
                var line = Path()
                line.move(to: CGPoint(x: 2.5, y: 23))
                line.addLine(to: CGPoint(x: 21.5, y: 2.5))
                ctx.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The grape cluster filling as a game downloads: outlines, with wine poured in from the bottom up to `fraction`.
/// The level animates smoothly between updates instead of stepping berry by berry.
struct GrapePour: View {
    var fraction: Double

    var body: some View {
        PourLevel(fraction: fraction)
            .animation(.easeOut(duration: 0.6), value: fraction)
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

private struct PourLevel: View, @MainActor Animatable {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width, size.height) / 24
            ctx.translateBy(x: (size.width - 24 * k) / 2, y: (size.height - 24 * k) / 2)
            ctx.scaleBy(x: k, y: k)
            GrapeMark.drawStem(in: &ctx, side: 24 * k)
            var berries = Path()
            for p in GrapeMark.grapes {
                ctx.stroke(Path(roundedRect: CGRect(x: p.x + 0.45, y: p.y + 0.45, width: 4.1, height: 4.1), cornerRadius: 0.9),
                           with: .foreground, lineWidth: 0.9)
                berries.addRoundedRect(in: CGRect(x: p.x, y: p.y, width: 5, height: 5), cornerSize: CGSize(width: 1.1, height: 1.1))
            }
            // Full is the top of the top row (y 6.6), empty the bottom of the lowest berry (y 23.8).
            let level = 23.8 - max(0, min(1, fraction)) * 17.2
            ctx.clip(to: Path(CGRect(x: 0, y: level, width: 24, height: 24 - level)))
            ctx.fill(berries, with: .foreground)
        }
    }
}

// MARK: - Controls

/// The primary action: a cream capsule. Minimum 36 points tall, as the HIG asks of a prominent button.
struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.ink.opacity(isEnabled ? 1 : 0.45))
            .frame(minWidth: 110, minHeight: 36)
            .padding(.horizontal, Theme.Space.m)
            .background(Capsule().fill(Theme.cream.opacity(isEnabled ? 1 : 0.6)))
            .shadow(color: Theme.shadow(0.22), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary actions beside Play: round glass buttons (Liquid Glass on macOS 26, material before).
struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .modifier(GlassCircle(pressed: configuration.isPressed))
    }
}

/// Neutral glass: a light veil over blurred art, so the accent never tints it.
private struct GlassCircle: ViewModifier {
    let pressed: Bool
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Circle())
            .background(Circle().fill(.white.opacity(0.12)))
            .background(Circle().fill(.black.opacity(0.25)))   // keeps it neutral over light art
            .overlay(Circle().strokeBorder(.white.opacity(0.14)))
            .environment(\.colorScheme, .dark)
            .opacity(pressed ? 0.8 : 1)
    }
}

/// A large glass pill for secondary calls to action ("Open Steam", "See All").
struct GlassPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.onDark)
            .frame(minHeight: 36)
            .padding(.horizontal, Theme.Space.l)
            .modifier(GlassCapsule(pressed: configuration.isPressed))
    }
}

private struct GlassCapsule: ViewModifier {
    let pressed: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .capsule).opacity(pressed ? 0.8 : 1)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line(0.18)))
                .opacity(pressed ? 0.8 : 1)
        }
    }
}

/// A text link: cream with a faint underline, as on the site. (The system link is blue, which isn't in the brand.)
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.onDark)
            .underline(true, color: Theme.onDark.opacity(0.45))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var textLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}

/// Lifts a card on hover (and on keyboard focus), unless the user asked for reduced motion.
struct HoverLift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let lifted = hovering || focused
        content
            .scaleEffect(lifted && !reduceMotion ? 1.03 : 1)
            .shadow(color: Theme.shadow(lifted ? 0.45 : 0.3), radius: lifted ? 14 : 6, y: lifted ? 8 : 3)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: lifted)
            .onHover { hovering = $0 }
            .focused($focused)
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

// MARK: - Formatting

extension Int64 {
    /// Few digits, so sizes read at a glance under covers: "70 GB", "3.7 GB", "697 MB".
    var fileSize: String {
        let gb = Double(self) / 1e9
        func measure(_ value: Double, _ unit: UnitInformationStorage, decimals: Int) -> String {
            Measurement(value: value, unit: unit).formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                                         numberFormatStyle: .number.precision(.fractionLength(decimals))))
        }
        if gb >= 10 { return measure(gb, .gigabytes, decimals: 0) }
        if gb >= 1 { return measure(gb, .gigabytes, decimals: 1) }
        if self >= 1_000_000 { return measure(Double(self) / 1e6, .megabytes, decimals: 0) }
        return ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

extension TimeInterval {
    var playTime: String {
        let minutes = Int(self / 60)
        return minutes < 60 ? String(localized: "\(minutes) min") : String(localized: "\(minutes / 60) h \(minutes % 60) min")
    }
}

extension Date {
    /// "Today", "Yesterday", "3 days ago": how Apple Games phrases it.
    var playedAgo: String {
        if Calendar.current.isDateInToday(self) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(self) { return String(localized: "Yesterday") }
        return formatted(.relative(presentation: .named))
    }
}

// MARK: - Compatibility

extension Compatibility.Verdict {
    /// The status mark: the brand's grape cluster, fuller the surer the answer.
    var mark: GrapeMark {
        switch self {
        case .works: GrapeMark(filled: 6, leaf: true)
        case .likely: GrapeMark(filled: 3)
        case .unknown: GrapeMark(filled: 0, dashed: true)
        case .wontRun: GrapeMark(filled: 0, struck: true)
        }
    }

    var color: Color {
        switch self {
        case .works, .likely: Theme.onDark
        case .unknown: Theme.onDark.opacity(0.5)
        case .wontRun: Theme.wineLight
        }
    }

    var localizedTitle: String {
        switch self {
        case .works: String(localized: "Works")
        case .likely: String(localized: "Should work")
        case .unknown: String(localized: "Unknown")
        case .wontRun: String(localized: "Won't run")
        }
    }
}

extension Compatibility.Note {
    var symbol: String {
        switch self {
        case .noOnline: "wifi.slash"
        case .macVersion: "apple.logo"
        case .demanding: "gauge.with.dots.needle.67percent"
        }
    }

    /// Notes are neutral, as on the site: only "won't run" takes the accent.
    var color: Color { Theme.onDark.opacity(0.8) }

    var localizedTitle: String {
        switch self {
        case .noOnline: String(localized: "No online play")
        case .macVersion: String(localized: "Mac version")
        case .demanding: String(localized: "Resource-heavy")
        }
    }

    var localizedExplanation: String {
        switch self {
        case .noOnline: String(localized: "Its anti-cheat blocks Macs, so online play won't work. Single-player will.")
        case .macVersion: String(localized: "Its Mac version is installed instead of the Windows one.")
        case .demanding: String(localized: "A demanding game: a recent Mac should run it well, a basic one may struggle.")
        }
    }
}

extension Compatibility {
    /// The answer and its notes in one line: "Should work · No online play".
    var summary: String { ([verdict.localizedTitle] + notes.map(\.localizedTitle)).joined(separator: " · ") }

    /// What the answer means for the player, in one line. Where outside data comes from isn't said: it doesn't
    /// change what to expect.
    var localizedExplanation: String? {
        switch reason {
        case .macVersion: String(localized: "The Mac version goes in: it's faster and easier on the battery.")
        case .playedHere: String(localized: "You've already played it on this Mac.")
        case .deckVerified: String(localized: "Should start right away, with no setup.")
        case .deckPlayable: String(localized: "Should run, though some controls or on-screen text may need adjusting.")
        case .deckTooDemanding: String(localized: "A demanding game: a recent Mac should handle it, a basic one may not.")
        case .deckFails: String(localized: "It's known not to start without Windows.")
        case .players: String(localized: "Other players run it on their Macs.")
        case .playersFail: String(localized: "Other players couldn't get it to start on a Mac.")
        case .onlineOnlyBlocked: String(localized: "It's online-only, and its anti-cheat blocks Macs.")
        case .offlineUnknown: String(localized: "Anti-cheat blocks online play. Single-player hasn't been checked yet.")
        case .noData: String(localized: "No reports yet. If it runs for you, it'll be marked as working.")
        }
    }
}

extension GraphicsBackend {
    /// "Automatic" in the app's language; the backends' own names aren't translated.
    var localizedName: String { self == .auto ? String(localized: "Automatic") : displayName }
}

extension GameInfo {
    /// The release year from the store's date, whatever its format ("12 Oct, 2016", "2016-10-12").
    var year: String? {
        releaseDate.map { date in date.split(whereSeparator: { !$0.isNumber }).last { $0.count == 4 }.map(String.init) ?? date }
    }
}

extension Game {
    /// The size on disk for display, or nil while Steam hasn't written it (0 during a first download).
    var knownSize: String? { sizeOnDisk.flatMap { $0 > 0 ? $0.fileSize : nil } }
}

extension FixRule {
    /// The mod a mod rule's fix turns off, by the name the player knows.
    private var modName: String {
        if case .disableMod(let key) = action { return FixAction.modName(key) }
        return String(localized: "A mod")
    }

    /// The cause in the app's language; rules from the fixes list online keep their own words.
    var localizedCause: String {
        // Rules from the fixes list online bring their own translations.
        if let causes, let text = causes[Bundle.main.preferredLocalizations.first ?? "en"] { return text }
        return switch id {
        case "anticheat": String(localized: "This game's anti-cheat (Easy Anti-Cheat or BattlEye) refuses to run under Wine on a Mac. Online play can't work; single-player modes may, if the game has them.")
        case ModDiagnostics.brokenModRule:
            String(localized: "\(modName) has an error that stops the game from starting.")
        case ModDiagnostics.loaderOutdatedRule:
            String(localized: "Mods for this game don't work with its latest update yet. Play without them until they're updated.")
        case ModDiagnostics.newestModRule:
            String(localized: "The game closed with an error while mods were on. \(modName) was added last, so it's the most likely cause.")
        case "ea-app-missing": String(localized: "The game starts through the EA app, which isn't set up in Steam's environment yet.")
        case "dotnet": String(localized: "The game, or its installer, needs the .NET runtime, which the environment doesn't have yet.")
        case "directx12": String(localized: "The game needs DirectX 12. Set up Apple's D3DMetal once, then DirectX 12 games can run.")
        case "vcruntime": String(localized: "The game needs the Visual C++ runtime, which the environment doesn't have.")
        case "ea-overlay": String(localized: "The EA app's in-game overlay crashed the game. It breaks games under Wine.")
        case "vulkan": String(localized: "The game asked for Vulkan (DXVK), which this engine doesn't have. DXMT runs Direct3D 11 games on Metal instead.")
        case "d3d11-fail": String(localized: "Direct3D 11 failed to start on Wine's own graphics. DXMT runs Direct3D 11 on Metal and works for most games.")
        case "dxmt-fail": String(localized: "The game crashed in DXMT's Metal translation. Wine's own graphics are slower but run more games.")
        case "eos-overlay": String(localized: "The Epic Online Services overlay crashed the game. It doesn't work under Wine; the game itself runs without it.")
        case "video-playback": String(localized: "The game plays a video through Windows Media Foundation, which this engine can't decode yet. Some games skip the video; others wait on it or crash.")
        case "cpu-features": String(localized: "The game checks for CPU instructions (AVX) that Rosetta doesn't fully provide. There's no fix yet; a game with a legacy or compatibility executable may run with that one.")
        case "missing-dll": String(localized: "A library the game needs is missing from the environment. The log names it; this is usually a runtime the game's installer would have added.")
        case "mac-32bit": String(localized: "This Mac version is 32-bit and can't run on today's macOS. The Windows version runs through Sommelier instead.")
        case LaunchRetry.turboRuleID: String(localized: "Turbo (MetalFX upscaling) didn't work out. Let's try without it.")
        case LaunchRetry.graphicsRuleID:
            if case .switchGraphics(let next)? = action, let previous = previousBackend {
                String(localized: "\(previous.displayName) didn't work out. Let's try \(next.displayName).")
            } else { cause }
        default: cause
        }
    }
}

extension FixAction {
    var localizedSummary: String {
        switch self {
        case .switchGraphics(let backend): String(localized: "Switch graphics to \(backend.displayName)")
        case .installDotNet: String(localized: "Install the .NET runtime")
        case .installVCRuntime: String(localized: "Install the Visual C++ runtime")
        case .disableEAOverlay: String(localized: "Turn off the EA app's in-game overlay")
        case .setEnvironment(let env): String(localized: "Set \(env.keys.sorted().joined(separator: ", "))")
        case .setUpDirectX12: String(localized: "Set up DirectX 12")
        case .setUpEAApp: String(localized: "Set up the EA app")
        case .turnOffTurbo: String(localized: "Turn off Turbo for this game")
        case .overrideDLL(let dll, _): String(localized: "Replace the \(dll) library")
        case .runExecutable(_, let run): String(localized: "Start \(run) instead of the launcher")
        case .setWindowsVersion(let version, _): String(localized: "Have the game see Windows \(FixAction.windowsName(version))")
        case .addArguments(let args): String(localized: "Launch with \(args.joined(separator: " "))")
        case .installComponent(let component): String(localized: "Install \(component.localizedName)")
        case .editConfig(_, _, let key, let field, let value): String(localized: "Game settings: \(field ?? key) = \(value)")
        case .editSave(_, _, let values): String(localized: "Game settings: \(FixAction.listing(values))")
        case .playStationPrompts: summary                 // never listed (kept before each launch, not a fix)
        case .removeModLeftovers: String(localized: "Set aside mod files from other tools")
        case .disableMod(let key): String(localized: "Turn off \(FixAction.modName(key))")
        case .disableFramework: String(localized: "Turn off mods for this game")      // never the loader's name
        }
    }

    /// The sheet's button: a retry says what it starts the game with.
    /// A mod's name as the player knows it, for a fix that names one: the app model looks it up in the games' mod
    /// stores. Players never see a store key or a loader's id; a key with no mod behind it is
    /// only spaced out, as a last resort.
    nonisolated(unsafe) static var modNameLookup: (String) -> String? = { _ in nil }
    static func modName(_ key: String) -> String {
        modNameLookup(key) ?? key.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    }

    var localizedButton: String {
        switch self {
        case .switchGraphics(let backend): String(localized: "Play with \(backend.displayName)")
        case .turnOffTurbo: String(localized: "Play without Turbo")
        case .disableMod(let key): String(localized: "Play without \(FixAction.modName(key))")
        case .disableFramework: String(localized: "Play without mods")
        default: String(localized: "Fix and Play Again")
        }
    }
}

extension Component {
    var localizedName: String {
        switch self {
        case .directx: String(localized: "the DirectX 9 runtime")
        case .d3dcompiler47: String(localized: "the Direct3D shader compiler")
        case .physx: String(localized: "PhysX")
        case .directplay: String(localized: "DirectPlay")
        case .dsound: String(localized: "DirectSound")
        case .directmusic: String(localized: "DirectMusic")
        case .corefonts: String(localized: "the Microsoft fonts")
        }
    }
}

/// `Theme.tintedBackground`: the game's (or store's) colour behind the header, settling into the surface. Dark: the
/// tint fades into the cellar. Light: the header stays dark (it's under the art), and below it the tint dissolves
/// into paper with a little of the game's colour in it.
private struct TintedBackground: View {
    let tint: Color?
    let heroHeight: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if scheme == .dark {
                    LinearGradient(colors: [(tint ?? Theme.graphite), (tint ?? Theme.graphite).opacity(0.85), Theme.surface],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: heroHeight + 260)
                } else {
                    // The art covers the top; below it, paper with a little of the game's colour.
                    ZStack { Theme.paper; (tint ?? .clear).opacity(0.10) }.frame(height: heroHeight + 260)
                }
                ZStack {
                    Theme.surface
                    if scheme == .light, let tint { tint.opacity(0.10) }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: geo.size.width)
        }
        .ignoresSafeArea()
    }
}

/// Settings → General → Appearance: as macOS, or always light or dark. Applied to the whole app (`NSApp.appearance`),
/// so windows, sheets, menus and the menu bar item follow at once.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    init(setting: String?) { self = setting.flatMap(AppAppearance.init(rawValue:)) ?? .system }
    var setting: String? { self == .system ? nil : rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "Same as System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        // The Dock icon while Sommelier runs: as macOS shows it (AppIcon.icon, by the system's icon style), or the
        // light or dark one when the player picked a look for the app.
        switch self {
        case .system: NSApp.applicationIconImage = nil
        case .light: NSApp.applicationIconImage = NSImage(named: "DockIconLight")
        case .dark: NSApp.applicationIconImage = NSImage(named: "DockIconDark")
        }
    }
}

extension EnvironmentValues {
    /// The page's own appearance, for popovers opened from a header that is forced dark over the art: they open
    /// over the page, so they take its look.
    @Entry var pageScheme: ColorScheme? = nil
}
