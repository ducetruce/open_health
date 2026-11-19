import SwiftUI

// Cardiovascular age from an imported Oura export: Oura's own readings, shown as they
// were and marked as ending when the export ends. Nothing is estimated forward: heart
// rate and HRV did not predict the wearer's vascular age better than its average.
// A live reading needs the ring's raw pulse waveforms, which `pulse_waveform` counts.

enum OuraCardio {
    struct Reading: Identifiable {
        let date: String
        let vascularAge: Double
        let pwv: Double
        var id: String { date }
    }

    /// Oura's fresh readings, oldest first.
    static func readings(_ s: Summary) -> [Reading] {
        s.cached("ouraCardio") {
            s.imported_history.compactMap { day, e in
                guard let a = e.vascular_age, let p = e.pwv else { return nil }
                return Reading(date: day, vascularAge: a, pwv: p)
            }
            .sorted { $0.date < $1.date }
        }
    }
}

struct OuraCardioSection: View {
    let s: Summary

    var body: some View {
        let all = OuraCardio.readings(s)
        VStack(alignment: .leading, spacing: 12) {
            if let last = all.last {
                // Oura's own readings jump from day to day; a 7-reading average is the
                // steadier figure, the last reading sits beside it.
                let recent = all.suffix(7)
                let avg = recent.map(\.vascularAge).reduce(0, +) / Double(recent.count)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f", avg)).font(Obs.pixel(44)).foregroundStyle(Obs.ink)
                    Text("YR VASCULAR AGE").font(Obs.label(10)).tracking(1.2).foregroundStyle(Obs.muted)
                }
                Text("Average of Oura's last \(recent.count) readings, to \(Fmt.day(last.date)). Oura measured this; the app doesn't estimate it.")
                    .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let age = s.profile?.age {
                    ObsStat(label: "Vs your age", value: relative(avg - age))
                }
                ObsStat(label: "Last reading", value: String(format: "%.0f yr · %.2f m/s", last.vascularAge, last.pwv))
                if all.count > 1 {
                    history(Array(all.suffix(120)))
                }
            }
            Rectangle().fill(Obs.rule).frame(height: 1)
            waveformStatus
        }
    }

    private func relative(_ diff: Double) -> String {
        let a = abs(diff.rounded())
        if diff <= -0.5 { return String(format: "%.0f yr younger", a) }
        if diff >= 0.5 { return String(format: "%.0f yr older", a) }
        return "In line"
    }

    /// Whether the ring is recording the raw pulse waveforms a live reading needs.
    private var waveformStatus: some View {
        let pw = s.pulse_waveform
        let days = pw?.days ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PULSE WAVEFORM").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                Spacer()
                Text(days > 0 ? "\(days) night\(days == 1 ? "" : "s") recorded" : "Not recorded yet")
                    .font(Obs.mono(12)).foregroundStyle(days > 0 ? Obs.signal : Obs.ink2)
            }
            Text(days > 0
                 ? "Your ring is recording the overnight pulse waveforms a live cardiovascular age needs\(pw?.last_day.map { "; last on \(Fmt.day($0))" } ?? "")."
                 : "The app asks your ring to record overnight pulse waveforms at every sync. They are what a live cardiovascular age would be measured from.")
                .font(Obs.mono(11)).foregroundStyle(Obs.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func history(_ readings: [OuraCardio.Reading]) -> some View {
        let lo = (readings.map(\.vascularAge).min() ?? 0) - 1
        let hi = (readings.map(\.vascularAge).max() ?? 1) + 1
        return VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                let n = readings.count
                let gap: CGFloat = n > 60 ? 1 : 2
                let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
                for (i, r) in readings.enumerated() {
                    let h = size.height * CGFloat((r.vascularAge - lo) / max(1, hi - lo))
                    var y: CGFloat = 0
                    while y < h {
                        let block = min(3, h - y)
                        ctx.fill(Path(CGRect(x: CGFloat(i) * (w + gap), y: size.height - y - block, width: w, height: block)),
                                 with: .color(Obs.signal.opacity(0.35 + 0.65 * Double(i) / Double(max(1, n - 1)))))
                        y += 5
                    }
                }
            }
            .frame(height: 60)
            .scrubbable(readings.enumerated().map { i, r in
                ScrubPoint(x: (Double(i) + 0.5) / Double(readings.count),
                           label: "\(Fmt.day(r.date)) · \(Int(r.vascularAge)) yr")
            })
            HStack {
                Text(Fmt.day(readings.first?.date)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Spacer()
                Text(Fmt.day(readings.last?.date)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
        }
    }
}
