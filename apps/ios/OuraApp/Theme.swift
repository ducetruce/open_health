import SwiftUI
import UIKit

// Night-sky dark theme: deep navy canvas, raised cards, white type, and one accent
// hue per domain (sleep indigo, activity amber, readiness teal, heart rose). Status
// colors stay semantic: green when something is genuinely good, amber/red when not.
// The app always runs dark (`.preferredColorScheme(.dark)` on the root).

enum Obs {
    private static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: alpha))
    }
    // Kept for call sites that still pass both values; the theme is dark-only.
    private static func adaptive(light: UInt32, dark: UInt32) -> Color { hex(dark) }

    // Surfaces and type.
    static let paper = hex(0x0b0f1c)       // canvas
    static let card = hex(0x161c2e)        // raised card
    static let cardHigh = hex(0x1f2740)    // pressed / selected / inset
    static let ink = hex(0xf3f5fa)
    static let ink2 = hex(0xc3c9d8)
    static let muted = hex(0x8990a6)
    static let link = hex(0xdfe5f2)
    static let rule = hex(0x262e47)

    // Diagrams sit in a cool gray-blue; status colors are semantic.
    static let chart = hex(0x9fb0d6)
    static let good = hex(0x4fd1a5)
    static let bad = hex(0xf2a65a)
    static let alert = hex(0xef6b6b)

    // Domain accents.
    static let sleepAccent = hex(0x8f8cff)
    static let activityAccent = hex(0xf5a65b)
    static let readinessAccent = hex(0x56c6d9)
    static let heartAccent = hex(0xf27c8a)

    // Back-compat names. `teal` is the quiet chart color; `yellow` is a problem.
    static var teal: Color { chart }
    static var yellow: Color { bad }
    static var warn: Color { bad }
    static var black: Color { paper }
    static var base: Color { paper }
    static var baseLow: Color { paper }
    static var trace: Color { rule }

    static var canvas: some View {
        LinearGradient(colors: [hex(0x18203d), paper, paper], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // Sleep stages keep distinct hues (deep / light / REM / wake). Other charts
    // stay gray unless a value is actually good or a problem.
    static let deep = hex(0x5b5fe0)
    static let light = hex(0x9db4f5)
    static let rem = hex(0x58c9e6)
    static let wake = hex(0xf2c35b)
    static func stage(_ s: Int) -> Color {
        switch s { case 1: return deep; case 2: return light; case 3: return rem; default: return wake }
    }

    /// Color a delta only when it is large enough to be worth noticing.
    static func tone(delta: Double?, goodWhenPositive: Bool = true, threshold: Double = 8) -> Color {
        guard let d = delta else { return chart }
        let isGood = d >= 0 ? goodWhenPositive : !goodWhenPositive
        if abs(d) < threshold { return chart }
        return isGood ? good : bad
    }

    static func debt(_ state: String) -> Color {
        switch state {
        case "none": return good
        case "low": return chart
        case "moderate": return bad
        case "high": return alert
        default: return chart
        }
    }

    /// Display titles: clean sans, a touch heavier than body text.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight == .regular ? .semibold : weight, design: .default)
    }
    /// Numbers and compact labels: sans with tabular digits, so columns still align.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default).monospacedDigit()
    }
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static func prose(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct ObsTag: View {
    let text: String
    var icon: String? = nil
    init(_ text: String, icon: String? = nil) { self.text = text; self.icon = icon }
    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Obs.muted)
            }
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Obs.muted)
        }
    }
}

/// Hairline between home sections — the thomas.md rule, with air on both sides.
struct ObsRule: View {
    var body: some View {
        Rectangle().fill(Obs.rule).frame(height: 1)
            .padding(.top, 6).padding(.bottom, 2)
    }
}

struct ObsCard: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Obs.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
    }
}

extension View {
    func obsCard(padding: CGFloat = 18, radius: CGFloat = 18) -> some View {
        modifier(ObsCard(padding: padding, radius: radius))
    }
}

struct ObsStat: View {
    let label: String
    let value: String
    var accent: Color = Obs.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 14)).foregroundStyle(Obs.ink2)
            Spacer(minLength: 16)
            Text(value).font(Obs.mono(15, .semibold)).foregroundStyle(accent)
                .monospacedDigit()
        }
    }
}
