import SwiftUI
import UIKit

// Signal theme: a near-black terminal canvas, thin-bordered cards and one mint-green
// accent. Numbers and titles use a pixel terminal font (VT323), labels a technical
// monospace (Share Tech Mono); body copy stays in the system font for readability.
// Every domain shares the green accent. Amber and red are kept for genuine problems,
// so a warning never reads as "good". The app always runs dark.

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
    static let paper = hex(0x090b0a)       // canvas
    static let card = hex(0x0d100e)        // card
    static let cardHigh = hex(0x16201a)    // pressed / selected / inset
    static let ink = hex(0xe4f2e8)
    static let ink2 = hex(0xa9b3ac)
    static let muted = hex(0x8e9a91)
    static let link = hex(0x72f0a0)
    static let rule = hex(0x1f2b23)
    /// The one accent, plus a dimmer border shade of it.
    static let signal = hex(0x72f0a0)
    static let signalDim = hex(0x2c5a3c)
    /// Text on a filled signal-green surface.
    static let onSignal = hex(0x07140c)

    // Diagrams sit in a cool gray-blue; status colors are semantic.
    static let chart = hex(0x4fb57a)
    static let good = hex(0x72f0a0)
    static let bad = hex(0xe8b45a)
    static let alert = hex(0xef6b6b)

    // Domain accents.
    static let sleepAccent = hex(0x72f0a0)
    static let activityAccent = hex(0x72f0a0)
    static let readinessAccent = hex(0x72f0a0)
    static let heartAccent = hex(0x72f0a0)

    // Back-compat names. `teal` is the quiet chart color; `yellow` is a problem.
    static var teal: Color { chart }
    static var yellow: Color { bad }
    static var warn: Color { bad }
    static var black: Color { paper }
    static var base: Color { paper }
    static var baseLow: Color { paper }
    static var trace: Color { rule }

    static var canvas: some View {
        paper.ignoresSafeArea()
    }

    // Sleep stages are shades of the accent that differ in lightness, so they stay
    // distinguishable without relying on hue (deep brightest, light darkest, wake white).
    static let deep = hex(0x9cffc0)
    static let light = hex(0x2a6b45)
    static let rem = hex(0x4fb57a)
    static let wake = hex(0xe4f2e8)
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

    /// The pixel terminal face draws small for its point size; this scales it so a
    /// value asked for at `size` looks about as large as the system font would.
    static let pixelScale: CGFloat = 1.32

    /// Large numbers and screen titles: pixel terminal font.
    static func pixel(_ size: CGFloat) -> Font {
        .custom("VT323-Regular", fixedSize: size * pixelScale)
    }
    /// Display titles.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { pixel(size) }
    /// Numbers and compact labels: technical monospace (every glyph the same width,
    /// so columns of figures align).
    /// Large figures (22 pt and up) switch to the pixel face, so every headline
    /// number on every screen reads as the terminal display.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        size >= 22 ? pixel(size) : .custom("ShareTechMono-Regular", fixedSize: size)
    }
    /// Big headline numbers.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { pixel(size) }
    /// Small uppercase labels.
    static func label(_ size: CGFloat = 11) -> Font {
        .custom("ShareTechMono-Regular", fixedSize: size)
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
                .font(Obs.label(11))
                .tracking(1.8)
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
        // Square-ish terminal panels whatever radius a caller asks for.
        let shape = RoundedRectangle(cornerRadius: min(radius, 4), style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(Obs.card).overlay(Scanlines().clipShape(shape)) }
            .overlay(shape.strokeBorder(Obs.rule, lineWidth: 1))
    }
}

/// Faint horizontal scanlines, like an old green-screen monitor.
struct Scanlines: View {
    /// A 1 × 3 point tile: one faint green line, two clear rows. Made once.
    private static let tile: UIImage = {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 3), format: format).image { ctx in
            UIColor(Obs.signal).withAlphaComponent(0.03).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }()

    var body: some View {
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

/// Exact, readable formatting shared by every screen: durations as hours and
/// minutes, counts with thousands separators, dates as words rather than MM-DD.
enum Fmt {
    /// "7h 42m", "42m", or "–". Rounded to the nearest minute, never to tenths of an hour.
    static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–" }
        let total = Int((seconds / 60).rounded())
        if total < 60 { return "\(total)m" }
        return "\(total / 60)h \(String(format: "%02d", total % 60))m"
    }

    static func duration(minutes: Double?) -> String {
        duration(seconds: minutes.map { $0 * 60 })
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// A whole number with thousands separators: "8,437". Never abbreviated.
    static func count(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return grouped.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    private static let ymdParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// First letter capitalised, the rest untouched: "published norms" → "Published norms".
    static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Clock times follow the iPhone's 12/24-hour setting ("5:42 PM" or "17:42").
    private static let clockFormat: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    private static let hourFormat: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("j"); return f
    }()
    private static let stampFormat: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMdjmm"); return f
    }()

    private static func clockDate(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents(); c.year = 2001; c.month = 1; c.day = 1
        c.hour = ((hour % 24) + 24) % 24; c.minute = minute
        return Calendar.current.date(from: c) ?? Date()
    }

    /// A clock time: "5:42 PM".
    static func clock(hour: Int, minute: Int) -> String { clockFormat.string(from: clockDate(hour, minute)) }

    /// An hour on a chart axis: "5 PM".
    static func hour(_ hour: Int) -> String { hourFormat.string(from: clockDate(hour, 0)) }

    /// A clock time from an "HH:MM" string (the summary JSON's format); the string
    /// itself if it isn't one.
    static func clock(_ hm: String?) -> String {
        guard let hm else { return "–" }
        let parts = hm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return hm }
        return clock(hour: parts[0], minute: parts[1])
    }

    /// "5:42 PM–6:10 PM" from two "HH:MM" strings.
    static func clockRange(_ start: String?, _ end: String?) -> String { "\(clock(start))–\(clock(end))" }

    /// "Nov 9, 5:42 PM".
    static func stamp(_ date: Date) -> String { stampFormat.string(from: date) }

    /// "Nov 9" for a "2026-11-09" day key (the original string if it isn't one).
    static func day(_ ymd: String?) -> String {
        guard let ymd else { return "–" }
        guard let date = ymdParser.date(from: String(ymd.prefix(10))) else { return ymd }
        return monthDay.string(from: date)
    }
}
