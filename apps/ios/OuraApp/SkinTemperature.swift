import SwiftUI

// Skin temperature is shown as the change from the wearer's own baseline, as Oura does:
// the ring reads finger skin (normally ~33-36 °C at night), so the absolute number says
// little, while a drift from one's own normal is what flags illness, alcohol and the like.

/// One night's skin temperature against the average of the nights before it.
struct SkinTempNight: Identifiable {
    let date: String
    /// Raw nightly skin temperature, °C.
    let celsius: Double
    /// Mean of up to the previous 14 nights, °C; nil until 3 earlier nights exist.
    let baseline: Double?
    var deviation: Double? { baseline.map { celsius - $0 } }
    var id: String { date }
}

enum SkinTemp {
    /// Nights whose average forms the baseline, and the fewest needed before it counts.
    static let baselineNights = 14
    static let minimumNights = 3
    /// Half-width of the usual range: 0.55 °C ≈ 1 °F, about where Oura flags a shift.
    static let usualRangeC = 0.55

    /// Every night with a skin temperature, oldest first, each with its causal baseline.
    static func nights(in s: Summary) -> [SkinTempNight] {
        let raw = s.nightlySeries(\.skin_temp)
        return raw.enumerated().map { i, v in
            let earlier = raw[max(0, i - baselineNights)..<i].map(\.value)
            let base = earlier.count >= minimumNights ? earlier.reduce(0, +) / Double(earlier.count) : nil
            return SkinTempNight(date: v.date, celsius: v.value, baseline: base)
        }
    }

    static func isUsual(_ deviationC: Double) -> Bool { abs(deviationC) <= usualRangeC }

    /// "+0.3" in the chosen unit (a difference, so °F is ×9/5 without the +32).
    static func signed(_ deviationC: Double, _ unit: TemperatureUnit) -> String {
        String(format: "%+.1f", Convert.temperatureDelta(deviationC, unit))
    }

    /// "±1.0 °F" / "±0.6 °C".
    static func rangeLabel(_ unit: TemperatureUnit) -> String {
        "±" + String(format: "%.1f", Convert.temperatureDelta(usualRangeC, unit)) + " " + unit.symbol
    }
}

/// The detail screen's body for skin temperature: the latest change from baseline,
/// the raw reading underneath, and each night's change as bars around zero with the
/// usual range shaded. Scrubbable.
struct SkinTemperatureSection: View {
    let nights: [SkinTempNight]     // the selected period, oldest first
    let unit: TemperatureUnit

    var body: some View {
        let scored = nights.filter { $0.deviation != nil }
        VStack(alignment: .leading, spacing: 22) {
            if let last = nights.last {
                hero(last)
            }
            if scored.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    ObsTag("Change from baseline")
                    DeviationBars(nights: scored, unit: unit)
                    HStack(spacing: 8) {
                        Rectangle().fill(Obs.signal.opacity(0.15))
                            .overlay(Rectangle().strokeBorder(Obs.signalDim, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .frame(width: 16, height: 8)
                        Text("Your usual range (\(SkinTemp.rangeLabel(unit)))")
                            .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                    }
                }
                .obsCard()
                stats(scored)
            } else if !nights.isEmpty {
                Text("Your baseline forms after \(SkinTemp.minimumNights) nights. Until then only the raw reading is shown.")
                    .font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func hero(_ last: SkinTempNight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ObsTag("Change from your baseline")
                Spacer()
                Text(Fmt.day(last.date)).font(Obs.mono(11)).foregroundStyle(Obs.muted)
            }
            if let d = last.deviation {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SkinTemp.signed(d, unit)).font(Obs.pixel(56)).foregroundStyle(Obs.ink)
                        .shadow(color: Obs.signal.opacity(0.5), radius: 8)
                    Text(unit.symbol).font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                }
                let usual = SkinTemp.isUsual(d)
                Text(usual ? "IN YOUR USUAL RANGE" : (d > 0 ? "WARMER THAN USUAL" : "COOLER THAN USUAL"))
                    .font(Obs.label(10)).tracking(1.6)
                    .foregroundStyle(usual ? Obs.signal : Obs.bad)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(Rectangle().strokeBorder(usual ? Obs.signalDim : Obs.bad.opacity(0.6), lineWidth: 1))
                Text(usual
                     ? "Within \(SkinTemp.rangeLabel(unit)) of your normal. Larger shifts can come with illness, alcohol, a late meal, a warm room or your cycle."
                     : "More than \(SkinTemp.rangeLabel(unit)) from your normal. This can come with illness, alcohol, a late meal, a warm room or your cycle.")
                    .font(Obs.prose(14)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Obs.rule).frame(height: 1)
            HStack {
                Text("Finger skin, raw").font(Obs.mono(12)).foregroundStyle(Obs.muted)
                Spacer()
                Text(rawLine(last)).font(Obs.mono(12)).foregroundStyle(Obs.ink2)
            }
        }
        .obsCard()
    }

    private func rawLine(_ n: SkinTempNight) -> String {
        let now = Fmt.temperature(n.celsius, unit) + " " + unit.symbol
        guard let b = n.baseline else { return now }
        return now + " · baseline " + Fmt.temperature(b, unit) + " " + unit.symbol
    }

    private func stats(_ scored: [SkinTempNight]) -> some View {
        let devs = scored.compactMap(\.deviation)
        let outside = devs.filter { !SkinTemp.isUsual($0) }.count
        return VStack(spacing: 10) {
            if let hi = devs.max() { ObsStat(label: "Warmest night", value: "\(SkinTemp.signed(hi, unit)) \(unit.symbol)") }
            if let lo = devs.min() { ObsStat(label: "Coolest night", value: "\(SkinTemp.signed(lo, unit)) \(unit.symbol)") }
            ObsStat(label: "Outside your usual range", value: "\(outside) of \(devs.count) nights",
                    accent: outside > 0 ? Obs.bad : Obs.ink)
        }
        .obsCard()
    }
}

/// Nightly change from baseline as pixel-block bars above and below a zero line, the
/// usual range shaded; nights outside it turn amber.
private struct DeviationBars: View {
    let nights: [SkinTempNight]
    let unit: TemperatureUnit
    private let axisW: CGFloat = 30

    /// Half the chart's height in °C: at least 2 °F (1.1 °C), more if a night went further.
    private var spanC: Double {
        max(1.1, (nights.compactMap(\.deviation).map(abs).max() ?? 0) * 1.1)
    }

    var body: some View {
        let span = spanC
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let w = size.width - axisW
                let mid = size.height / 2
                let perC = mid / span
                // usual range band and zero line
                let band = CGFloat(SkinTemp.usualRangeC) * perC
                ctx.fill(Path(CGRect(x: 0, y: mid - band, width: w, height: band * 2)), with: .color(Obs.signal.opacity(0.06)))
                for y in [mid - band, mid + band] {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: w, y: y)) },
                               with: .color(Obs.signalDim), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: w, y: mid)) },
                           with: .color(Obs.ink.opacity(0.45)), lineWidth: 1)
                // bars
                let gap: CGFloat = nights.count > 60 ? 1 : 2
                let barW = max(1, (w - gap * CGFloat(nights.count - 1)) / CGFloat(nights.count))
                for (i, n) in nights.enumerated() {
                    guard let d = n.deviation else { continue }
                    let h = max(2, CGFloat(abs(d)) * perC)
                    let x = CGFloat(i) * (barW + gap)
                    let color = SkinTemp.isUsual(d) ? Obs.signal.opacity(0.8) : Obs.bad
                    var y: CGFloat = 0
                    while y < h {   // pixel blocks, outward from zero
                        let block = min(3, h - y)
                        let top = d >= 0 ? mid - y - block : mid + y
                        ctx.fill(Path(CGRect(x: x, y: top, width: barW, height: block)), with: .color(color))
                        y += 5
                    }
                }
                // axis labels, in the chosen unit
                let spanU = Convert.temperatureDelta(span, unit)
                for (frac, value) in [(0.0, spanU), (0.5, 0.0), (1.0, -spanU)] {
                    let label = value == 0 ? "0" : String(format: "%+.1f", value)
                    ctx.draw(Text(label).font(Obs.mono(9)).foregroundColor(Obs.muted),
                             at: CGPoint(x: size.width - 2, y: size.height * CGFloat(frac)),
                             anchor: frac == 0 ? .topTrailing : frac == 1 ? .bottomTrailing : .trailing)
                }
            }
            .frame(height: 170)
            .scrubbable(nights.enumerated().compactMap { i, n in
                n.deviation.map {
                    ScrubPoint(x: (Double(i) + 0.5) / Double(nights.count),
                               label: "\(Fmt.day(n.date)) · \(SkinTemp.signed($0, unit)) \(unit.symbol)")
                }
            }, trailingInset: axisW)
            HStack {
                Text(Fmt.day(nights.first?.date)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Spacer()
                Text(Fmt.day(nights.last?.date)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
            .padding(.trailing, axisW)
        }
    }
}
