import SwiftUI

// Building blocks of the signal (terminal) look: digital rain behind hero cards,
// bar charts drawn as stacked pixel blocks, the tab bar with its + button, the
// log sheet the + opens, and the small metric tiles.

/// Faint columns of falling characters, drawn behind a hero card's content.
/// Holds still when the user has asked iOS to reduce motion.
struct DigitalRain: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let glyphs = Array("ﾊ7ﾐ0ﾋｰ3ｳｼﾅ1ﾓﾆ9ｻﾜﾂ5ｵﾘ4ｱﾎﾃﾏｹﾒｴｶｷﾑﾕﾗｾﾈｽﾀﾇﾍ8ｦｲｸｺｿﾁﾄﾉﾌﾔﾖﾙﾚﾛﾝ2Z:")
    private let column: CGFloat = 16
    private let row: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let cols = Int(size.width / column) + 1
                let rows = Int(size.height / row) + 2
                for c in 0..<cols {
                    // Each column falls at its own speed, from its own offset.
                    let speed = 10 + Double((c * 37) % 13)
                    let shift = CGFloat((t * speed + Double(c * 53)).truncatingRemainder(dividingBy: Double(row) * Double(rows)))
                    for r in 0..<rows {
                        let y = (CGFloat(r) * row + shift).truncatingRemainder(dividingBy: CGFloat(rows) * row) - row
                        let glyph = Self.glyphs[(c * 7 + r * 13) % Self.glyphs.count]
                        let fade = 0.03 + 0.07 * Double(r % 5) / 4
                        ctx.draw(Text(String(glyph)).font(Obs.mono(12)).foregroundColor(Obs.signal.opacity(fade)),
                                 at: CGPoint(x: CGFloat(c) * column + column / 2, y: y))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A bar chart whose bars are stacks of small blocks; older bars are dimmer.
struct PixelBars: View {
    let values: [Double]
    var height: CGFloat = 30
    /// Lowest value drawn as an empty bar; defaults to a little under the minimum.
    var floor: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 0, let maxV = values.max(), let minV = values.min() else { return }
            let lo = floor ?? (minV - (maxV - minV) * 0.25 - 0.0001)
            let span = max(maxV - lo, 0.0001)
            let gap: CGFloat = 2
            let barW = (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let frac = max(0.12, (v - lo) / span)
                let h = size.height * CGFloat(frac)
                let alpha = values.count > 1 ? 0.3 + 0.7 * Double(i) / Double(values.count - 1) : 1
                var y = size.height
                while y > size.height - h {
                    let block = min(3, y - (size.height - h))
                    ctx.fill(Path(CGRect(x: CGFloat(i) * (barW + gap), y: y - block, width: barW, height: block)),
                             with: .color(Obs.signal.opacity(alpha)))
                    y -= 5
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One metric tile: name, big value, pixel bars and a short note.
struct SignalTile: View {
    let name: String
    let index: String
    let value: String
    let unit: String
    let series: [Double]
    let note: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(name).font(.system(size: 12)).foregroundStyle(Obs.ink2).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 2)
                    Text(index).font(Obs.mono(10)).foregroundStyle(Obs.muted)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(Obs.pixel(28)).foregroundStyle(Obs.ink)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(unit.uppercased()).font(Obs.mono(10)).foregroundStyle(Obs.muted)
                }
                if series.count > 1 {
                    PixelBars(values: series, height: 28)
                } else {
                    Rectangle().fill(Obs.rule).frame(height: 1).frame(height: 28, alignment: .bottom)
                }
                HStack(spacing: 6) {
                    Circle().fill(Obs.signal).frame(width: 6, height: 6)
                    Text(note).font(Obs.mono(10)).foregroundStyle(Obs.ink2).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 4).fill(Obs.card).overlay(Scanlines().clipShape(RoundedRectangle(cornerRadius: 4))) }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Obs.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(value) \(unit), \(note)")
    }
}

/// The bottom bar: five tabs and the green + button that opens the log sheet.
struct SignalTabBar: View {
    @Binding var tab: AppTab
    var onPlus: () -> Void

    private let items: [(AppTab, String, String)] = [
        (.today, "Today", "square.grid.2x2"),
        (.sleep, "Sleep", "moon"),
        (.activity, "Activity", "bolt"),
        (.trends, "Trends", "chart.xyaxis.line"),
        (.vitals, "Vitals", "waveform.path.ecg"),
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(items, id: \.0) { item in
                let on = tab == item.0
                Button { tab = item.0 } label: {
                    VStack(spacing: 5) {
                        Image(systemName: item.2).font(.system(size: 19, weight: .regular))
                        Text(item.1).font(Obs.mono(10)).lineLimit(1)
                    }
                    .foregroundStyle(on ? Obs.signal : Obs.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.1)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Button(action: onPlus) {
                Image(systemName: "plus").font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Obs.onSignal)
                    .frame(width: 50, height: 50)
                    .background(Obs.signal, in: Circle())
                    .shadow(color: Obs.signal.opacity(0.45), radius: 11)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6).padding(.trailing, 10)
            .accessibilityLabel("Log a workout or sync")
        }
        .padding(.top, 8).padding(.bottom, 2)
        .background(Obs.paper.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Obs.rule).frame(height: 1) }
    }
}

/// What the + button offers.
enum LogChoice { case startWorkout, logWorkout, sync }

struct LogMenuSheet: View {
    var lastSync: String?
    var pick: (LogChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ObsTag("Add to today")
            Text("Log").font(Obs.pixel(28)).foregroundStyle(Obs.ink).padding(.bottom, 6)
            row("Start a workout", "Live heart rate and calories from the ring", "play.fill") { pick(.startWorkout) }
            row("Log a past workout", "Type, start time and duration", "clock") { pick(.logWorkout) }
            row("Sync ring now", lastSync ?? "Fetch the latest data from your ring", "arrow.triangle.2.circlepath") { pick(.sync) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Obs.card.ignoresSafeArea())
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func row(_ title: String, _ sub: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Obs.signal)
                    .frame(width: 40, height: 40)
                    .overlay(Rectangle().strokeBorder(Obs.signalDim, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16)).foregroundStyle(Obs.ink)
                    Text(sub).font(.system(size: 12)).foregroundStyle(Obs.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Obs.muted)
            }
            .padding(12)
            .background(Obs.paper, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Obs.rule, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Small bordered status word ("GOOD", "RESTFUL"…).
struct SignalBadge: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Obs.label(10)).tracking(1.6)
            .foregroundStyle(Obs.signal)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Rectangle().strokeBorder(Obs.signalDim, lineWidth: 1))
    }
}
