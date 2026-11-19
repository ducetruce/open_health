import SwiftUI

// Building blocks of the signal (terminal) look: digital rain behind hero cards,
// bar charts drawn as stacked pixel blocks, the tab bar with its + button, the
// log sheet the + opens, and the small metric tiles.

/// Faint columns of falling characters, drawn behind a hero card's content.
/// The glyphs are drawn once into a texture twice the card's height, and the whole
/// texture slides down on a slow loop, so the animation costs the GPU a transform
/// per frame instead of re-drawing hundreds of characters. Holds still when the
/// user has asked iOS to reduce motion.
struct DigitalRain: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fall = false
    private static let glyphs = Array("ﾊ7ﾐ0ﾋｰ3ｳｼﾅ1ﾓﾆ9ｻﾜﾂ5ｵﾘ4ｱﾎﾃﾏｹﾒｴｶｷﾑﾕﾗｾﾈｽﾀﾇﾍ8ｦｲｸｺｿﾁﾄﾉﾌﾔﾖﾙﾚﾛﾝ2Z:")
    private static let column: CGFloat = 16
    private static let row: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            // One period is a whole number of rows, so the loop joins seamlessly.
            let rows = max(1, Int(ceil(geo.size.height / Self.row)))
            let period = CGFloat(rows) * Self.row
            Canvas { ctx, size in
                let cols = Int(size.width / Self.column) + 1
                for c in 0..<cols {
                    for r in 0..<(rows * 2) {
                        let rr = r % rows
                        let glyph = Self.glyphs[(c * 7 + rr * 13) % Self.glyphs.count]
                        let fade = 0.03 + 0.07 * Double((rr + c * 3) % 5) / 4
                        ctx.draw(Text(String(glyph)).font(Obs.mono(12)).foregroundColor(Obs.signal.opacity(fade)),
                                 at: CGPoint(x: CGFloat(c) * Self.column + Self.column / 2,
                                             y: CGFloat(r) * Self.row + Self.row / 2))
                    }
                }
            }
            .frame(width: geo.size.width, height: period * 2)
            .drawingGroup()
            .offset(y: fall ? 0 : -period)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: Double(period) / 9).repeatForever(autoreverses: false)) { fall = true }
            }
        }
        .clipped()
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
                // With an explicit floor, a value at or below it (zero steps) draws
                // nothing; otherwise every bar keeps a small stub.
                if let floor, v <= floor { continue }
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
                    Text(name).font(Obs.mono(12)).foregroundStyle(Obs.ink2).lineLimit(1).minimumScaleFactor(0.8)
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
    /// Height of the bar above the home indicator; pages reserve this much space.
    static let height: CGFloat = 72
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
                    Text(title).font(Obs.mono(16)).foregroundStyle(Obs.ink)
                    Text(sub).font(Obs.mono(12)).foregroundStyle(Obs.muted)
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

// MARK: - Scrubbing

/// One position a chart can be scrubbed to: where it sits across the plot (0…1)
/// and what the readout says there ("Nov 12 · 62 ms").
struct ScrubPoint {
    let x: Double
    let label: String
}

/// Touch a chart and slide: a green line follows the finger, snapping to the
/// nearest data point, with that point's readout above it and a light tick each
/// time it moves to a new point. Lifting the finger clears it.
struct Scrubbable: ViewModifier {
    let points: [ScrubPoint]
    /// Horizontal space the chart leaves empty on each side of its plot.
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    @State private var index: Int?
    private static let ticker = UISelectionFeedbackGenerator()
    private let labelWidth: CGFloat = 150

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let plotW = max(1, geo.size.width - leadingInset - trailingInset)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { g in
                                    let f = Double((g.location.x - leadingInset) / plotW)
                                    guard let i = nearest(to: f) else { return }
                                    if i != index {
                                        index = i
                                        Self.ticker.selectionChanged()
                                    }
                                }
                                .onEnded { _ in index = nil }
                        )
                    if let i = index, points.indices.contains(i) {
                        let x = leadingInset + CGFloat(points[i].x) * plotW
                        Rectangle().fill(Obs.signal)
                            .frame(width: 1, height: geo.size.height)
                            .shadow(color: Obs.signal.opacity(0.6), radius: 3)
                            .offset(x: x - 0.5)
                            .allowsHitTesting(false)
                        Text(points[i].label)
                            .font(Obs.mono(11)).foregroundStyle(Obs.onSignal)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Obs.signal, in: RoundedRectangle(cornerRadius: 3))
                            .frame(width: labelWidth)
                            .offset(x: min(max(x - labelWidth / 2, 0), max(0, geo.size.width - labelWidth)), y: -24)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .accessibilityHint("Touch and slide to read values")
    }

    private func nearest(to f: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        var best = 0
        var bestD = Double.infinity
        for (i, p) in points.enumerated() {
            let d = abs(p.x - f)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }
}

extension View {
    /// Lets the user touch and slide across the chart to read each value.
    func scrubbable(_ points: [ScrubPoint], leadingInset: CGFloat = 0, trailingInset: CGFloat = 0) -> some View {
        modifier(Scrubbable(points: points, leadingInset: leadingInset, trailingInset: trailingInset))
    }
}
