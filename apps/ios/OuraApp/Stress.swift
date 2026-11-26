import SwiftUI

// Daytime stress and resilience, from the shared core's `stress` block
// (crates/oura-summary/src/stress.rs): 15-minute windows of still, awake time judged
// by heart rate and HRV against the wearer's own daytime baseline, on Oura's scale.

// MARK: - Data

struct StressWindow: Codable, Hashable {
    let start: Int64          // unix seconds
    let value: Double         // Oura's signed scale: stress +, recovery −
    let state: String         // stressed / engaged / relaxed / restored
}

struct StressDay: Codable {
    var stressed_min: Double = 0
    var restored_min: Double = 0
    var engaged_min: Double = 0
    var relaxed_min: Double = 0
    var measured_min: Double = 0
    var verdict: String?
    var windows: [StressWindow]?
}

struct ResilienceContributors: Codable {
    var sleep_recovery: Double?
    var daytime_recovery: Double?
    var stress: Double?
}

struct ResilienceDay: Codable, Hashable {
    let date: String
    let level: String
}

struct ResilienceInfo: Codable {
    var level: String?
    var contributors: ResilienceContributors?
    var date: String?
    var days_of_stress: Int?
    var week_ago: String?
    var history: [ResilienceDay]?
}

struct StressBlock: Codable {
    var days: [String: StressDay] = [:]
    var resilience: ResilienceInfo?
    var calibrated: Bool?

    /// Days with windows, newest first.
    var dayKeys: [String] { days.keys.sorted(by: >) }
}

enum StressState: String, CaseIterable {
    case stressed, engaged, relaxed, restored

    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .stressed: return Obs.bad
        case .engaged: return Obs.light
        case .relaxed: return Obs.rem
        case .restored: return Obs.deep
        }
    }
}

enum Resilience {
    static let levels = ["limited", "adequate", "solid", "strong", "exceptional"]
    /// Days of stress the level needs before it is shown.
    static let minimumDays = 5
    static let window = 14

    static func blurb(_ level: String) -> String {
        switch level {
        case "limited": return "Daily stress is outpacing your recovery. Protect your sleep and find restful moments in the day."
        case "adequate": return "You are coping, with little room to spare. More restful time in the day would help."
        case "solid": return "You recover well from daily stress. More restored time during the day would move you toward strong."
        case "strong": return "Your body bounces back well from stress, with good sleep recovery behind it."
        default: return "Excellent recovery: your sleep and daytime rest more than balance the stress you meet."
        }
    }
}

/// Time on the wearer's clock for a window start.
private enum StressClock {
    static func minutesSinceMidnight(_ unix: Int64) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(unix)))
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    static func label(_ unix: Int64) -> String {
        Fmt.clock(hour: minutesSinceMidnight(unix) / 60, minute: minutesSinceMidnight(unix) % 60)
    }
}

/// The verdict badge text, or "MEASURING" while a day has too little still time.
private func verdictLabel(_ day: StressDay) -> String {
    (day.verdict ?? "measuring").uppercased()
}

// MARK: - Today card

/// The day so far as a strip of 15-minute windows (6 AM to midnight), the day's
/// verdict, stressed and restored time, and the resilience level.
/// Which stress screen to open.
enum StressSheetKind: String, Identifiable {
    case stress, resilience
    var id: String { rawValue }
}

struct StressCard: View {
    let block: StressBlock?
    /// The day to show; nil shows the latest day with readings.
    var day: String? = nil
    var onOpen: () -> Void
    var onResilience: () -> Void

    var body: some View {
        let key = self.day ?? block?.dayKeys.first
        let info = key.flatMap { block?.days[$0] }
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ObsTag("Daytime stress")
                        Spacer()
                        if let info { SignalBadge(text: verdictLabel(info)) }
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                    }
                    if let info {
                        if self.day == nil, let key, key != Self.todayKey {
                            Text("Latest · \(Fmt.day(key))").font(Obs.mono(11)).foregroundStyle(Obs.muted)
                        }
                        DayStressStrip(windows: info.windows ?? [])
                        HStack {
                            ForEach(["6 AM", "12 PM", "6 PM", "12 AM"], id: \.self) { t in
                                Text(t).font(Obs.mono(9)).foregroundStyle(Obs.muted)
                                if t != "12 AM" { Spacer() }
                            }
                        }
                        HStack(spacing: 0) {
                            minutes("Stressed", info.stressed_min, StressState.stressed.color)
                            minutes("Restored", info.restored_min, StressState.restored.color)
                        }
                    } else if self.day != nil, block?.days.isEmpty == false {
                        Text("No still, awake readings for this day.")
                            .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                    } else {
                        Text("Your daytime baseline is building. Stress shows up after a couple of days of wearing the ring while you sit still.")
                            .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Rectangle().fill(Obs.rule).frame(height: 1)
            Button(action: onResilience) {
                HStack {
                    Text("RESILIENCE").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                    Spacer()
                    Text(resilienceText).font(Obs.mono(14)).foregroundStyle(Obs.ink)
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .obsCard()
    }

    private var resilienceText: String {
        if let level = block?.resilience?.level { return level.capitalized }
        return "Building · \(block?.resilience?.days_of_stress ?? 0) of \(Resilience.minimumDays) days"
    }

    private func minutes(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Obs.label(9)).tracking(1.2).foregroundStyle(Obs.muted)
            Text(Fmt.duration(minutes: value)).font(Obs.pixel(24)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static var todayKey: String {
        // Oura's stress day runs from 4 AM.
        WorkoutFormat.day.string(from: Date().addingTimeInterval(-4 * 3600))
    }
}

/// A day as 72 quarter-hour cells from 6 AM to midnight, coloured by state; blank
/// where the ring had no still, awake reading.
struct DayStressStrip: View {
    let windows: [StressWindow]
    var height: CGFloat = 16

    var body: some View {
        Canvas { ctx, size in
            let slots = 72
            let gap: CGFloat = 1
            let w = (size.width - gap * CGFloat(slots - 1)) / CGFloat(slots)
            for i in 0..<slots {
                let x = CGFloat(i) * (w + gap)
                ctx.fill(Path(CGRect(x: x, y: size.height - 1, width: w, height: 1)), with: .color(Obs.rule))
            }
            for win in windows {
                let slot = (StressClock.minutesSinceMidnight(win.start) - 360) / 15
                guard (0..<slots).contains(slot), let st = StressState(rawValue: win.state) else { continue }
                let x = CGFloat(slot) * (w + gap)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: 1),
                         with: .color(st.color))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Stress screen

struct StressView: View {
    let s: Summary
    /// The day to open on (the app's picked day); the screen's own strip can move on.
    var initialDay: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var day = ""
    @State private var showResilience = false

    private var block: StressBlock? { s.stress }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let block, !block.days.isEmpty {
                            let keys = block.dayKeys
                            let key = keys.contains(day) ? day : keys[0]
                            if let d = block.days[key] {
                                Text(DayHeading.label(key).uppercased())
                                    .font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
                                timeline(d)
                                totals(d)
                            }
                            resilienceLink(block)
                            DayStrip(days: keys, selection: Binding(get: { key }, set: { day = $0 }),
                                     title: "Days · stressed time") { k in
                                block.days[k].map { $0.verdict == nil ? "–" : Fmt.duration(minutes: $0.stressed_min) }
                            }
                            .padding(.top, 8)
                        } else {
                            Text("Your daytime baseline is building. Stress shows up after a couple of days of wearing the ring while you sit still: the ring takes its daytime readings only when your hand is at rest.")
                                .font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .obsCard()
                        }
                        Text("Each 15 minutes of still, awake time is judged by your heart rate and HRV against your own daytime baseline. Time asleep or moving is left out, as Oura does."
                             + (block?.calibrated == true ? " Calibrated to your Oura history." : ""))
                            .font(Obs.mono(12)).foregroundStyle(Obs.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .onAppear { if day.isEmpty, let initialDay { day = initialDay } }
            .navigationTitle("Daytime stress")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showResilience) { ResilienceView(s: s) }
        }
    }

    private func timeline(_ d: StressDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ObsTag(d.verdict == nil ? "Measuring" : "Day")
                Spacer()
                SignalBadge(text: verdictLabel(d))
            }
            StressTimeline(windows: d.windows ?? [])
            HStack(spacing: 12) {
                ForEach(StressState.allCases, id: \.self) { st in
                    HStack(spacing: 5) {
                        Rectangle().fill(st.color).frame(width: 10, height: 8)
                        Text(st.label).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                    }
                }
            }
        }
        .obsCard()
    }

    private func totals(_ d: StressDay) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(StressState.allCases, id: \.self) { st in
                    let v: Double = switch st {
                    case .stressed: d.stressed_min
                    case .engaged: d.engaged_min
                    case .relaxed: d.relaxed_min
                    case .restored: d.restored_min
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(st.label.uppercased()).font(Obs.label(9)).tracking(1.2).foregroundStyle(Obs.muted)
                        Text(Fmt.duration(minutes: v)).font(Obs.pixel(26))
                            .foregroundStyle(st == .stressed || st == .restored ? st.color : Obs.ink)
                    }
                }
            }
            Rectangle().fill(Obs.rule).frame(height: 1)
            Text("From \(Fmt.duration(minutes: d.measured_min)) of still, awake time.")
                .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
        }
        .obsCard()
    }

    private func resilienceLink(_ block: StressBlock) -> some View {
        Button { showResilience = true } label: {
            HStack {
                Text("RESILIENCE").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                Spacer()
                Text(block.resilience?.level?.capitalized ?? "Building").font(Obs.mono(15)).foregroundStyle(Obs.ink)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .obsCard()
    }
}

/// The part of the day with readings (at least 6 hours): a pixel-block bar per
/// 15-minute window, up for stress and down for recovery, around a zero line.
/// Zooming to the measured hours keeps each bar wide. Scrubbable.
struct StressTimeline: View {
    let windows: [StressWindow]
    private let axisW: CGFloat = 34

    /// Minutes since midnight, with the small hours after midnight counted on the
    /// same (4 AM to 4 AM) day.
    private func minute(_ w: StressWindow) -> Int {
        let m = StressClock.minutesSinceMidnight(w.start)
        return m < 240 ? m + 1440 : m
    }

    /// First and last minute shown: whole hours around the readings, 6 hours at least,
    /// inside 4 AM to 4 AM.
    private var range: (start: Int, end: Int) {
        let ms = windows.map(minute)
        guard let lo = ms.min(), let hi = ms.max() else { return (360, 1440) }
        var start = lo / 60 * 60
        var end = (hi + 15 + 59) / 60 * 60
        if end - start < 360 {
            let pad = 360 - (end - start)
            start -= pad / 2
            end += pad - pad / 2
        }
        if start < 240 { end += 240 - start; start = 240 }
        if end > 1680 { start -= end - 1680; end = 1680 }
        return (max(240, start), end)
    }

    private func label(_ minute: Int) -> String {
        Fmt.clock(hour: (minute / 60) % 24, minute: minute % 60)
    }

    var body: some View {
        let r = range
        let slots = max(1, (r.end - r.start) / 15)
        let slotOf = { (w: StressWindow) in (minute(w) - r.start) / 15 }
        VStack(spacing: 6) {
            Canvas { ctx, size in
                let plotW = size.width - axisW
                let mid = size.height / 2
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: plotW, y: mid)) },
                           with: .color(Obs.ink.opacity(0.45)), lineWidth: 1)
                let gap: CGFloat = slots > 48 ? 1 : 2
                let barW = max(1, (plotW - gap * CGFloat(slots - 1)) / CGFloat(slots))
                for w in windows {
                    let i = slotOf(w)
                    guard (0..<slots).contains(i), let st = StressState(rawValue: w.state) else { continue }
                    let h = max(4, CGFloat(abs(w.value)) / 100 * (mid - 2))
                    let x = CGFloat(i) * (barW + gap)
                    var y: CGFloat = 0
                    while y < h {
                        let block = min(4, h - y)
                        let top = w.value >= 0 ? mid - y - block : mid + y
                        ctx.fill(Path(CGRect(x: x, y: top, width: barW, height: block)), with: .color(st.color))
                        y += 5
                    }
                }
                for (frac, text) in [(0.0, "Stress"), (0.5, "0"), (1.0, "Rest")] {
                    ctx.draw(Text(text).font(Obs.mono(9)).foregroundColor(Obs.muted),
                             at: CGPoint(x: size.width, y: size.height * frac),
                             anchor: frac == 0 ? .topTrailing : frac == 1 ? .bottomTrailing : .trailing)
                }
            }
            .frame(height: 200)
            .scrubbable(windows.compactMap { w in
                let i = slotOf(w)
                guard (0..<slots).contains(i) else { return nil }
                return ScrubPoint(x: (Double(i) + 0.5) / Double(slots),
                                  label: "\(StressClock.label(w.start)) · \(w.state.capitalized)")
            }, trailingInset: axisW)
            HStack {
                let span = r.end - r.start
                let marks = [r.start, r.start + span / 3 / 60 * 60, r.start + 2 * span / 3 / 60 * 60, r.end]
                ForEach(Array(marks.enumerated()), id: \.offset) { i, m in
                    Text(label(m)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                    if i < marks.count - 1 { Spacer() }
                }
            }
            .padding(.trailing, axisW)
        }
    }
}

// MARK: - Resilience screen

struct ResilienceView: View {
    let s: Summary
    @Environment(\.dismiss) private var dismiss

    private var info: ResilienceInfo? { s.stress?.resilience }

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        levelCard
                        if let c = info?.contributors, info?.level != nil {
                            contributors(c)
                        }
                        if let h = info?.history, h.count > 1 {
                            historyCard(Array(h.suffix(30)))
                        }
                        Text("Resilience weighs the last two weeks: how much stress you met in the day, how much restored time you had, and how well your body recovered during sleep (HRV, lowest heart rate and sleep score). Days before your ring's data come from your Oura history.")
                            .font(Obs.mono(12)).foregroundStyle(Obs.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Resilience")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private var levelCard: some View {
        let level = info?.level
        let index = level.flatMap { Resilience.levels.firstIndex(of: $0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                ObsTag("Your level · last 14 days")
                Spacer()
                if let change = changeText {
                    Text(change.uppercased()).font(Obs.label(10)).tracking(1.2).foregroundStyle(Obs.signal)
                }
            }
            Text(level?.capitalized ?? "Building").font(Obs.pixel(48)).foregroundStyle(Obs.ink)
                .shadow(color: Obs.signal.opacity(0.4), radius: 8)
            HStack(spacing: 4) {
                ForEach(Array(Resilience.levels.enumerated()), id: \.offset) { i, name in
                    VStack(spacing: 6) {
                        Rectangle()
                            .fill(index.map { i < $0 ? Obs.rem : i == $0 ? Obs.signal : Color.clear } ?? Color.clear)
                            .overlay(Rectangle().strokeBorder(index.map { i <= $0 ? Color.clear : Obs.rule } ?? Obs.rule, lineWidth: 1))
                            .frame(height: 10)
                        Text(name.uppercased()).font(Obs.label(8)).tracking(0.6)
                            .foregroundStyle(i == index ? Obs.signal : Obs.muted)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
            Text(level.map(Resilience.blurb) ?? "Resilience needs \(Resilience.minimumDays) days of daytime stress in the last two weeks. So far: \(info?.days_of_stress ?? 0).")
                .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .obsCard()
    }

    private var changeText: String? {
        guard let now = info?.level, let before = info?.week_ago, now != before,
              let a = Resilience.levels.firstIndex(of: now), let b = Resilience.levels.firstIndex(of: before) else { return nil }
        return (a > b ? "Up from " : "Down from ") + before
    }

    private func contributors(_ c: ResilienceContributors) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ObsTag("Contributors")
            meter("Sleep recovery", c.sleep_recovery, higherIsBetter: true)
            meter("Daytime recovery", c.daytime_recovery, higherIsBetter: true)
            meter("Stress load", c.stress, higherIsBetter: false)
        }
        .obsCard()
    }

    /// A contributor as a 0–100 bar. Stress load is better low, so its bar shows
    /// 100 minus the load and its number is the load itself.
    private func meter(_ label: String, _ value: Double?, higherIsBetter: Bool) -> some View {
        let shown = value.map { higherIsBetter ? $0 : 100 - $0 } ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                Spacer()
                Text(value.map { String(format: "%.0f", $0) } ?? "–").font(Obs.mono(13)).foregroundStyle(Obs.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Obs.rule)
                    Rectangle().fill(Obs.rem).frame(width: g.size.width * CGFloat(min(100, max(0, shown)) / 100))
                }
            }
            .frame(height: 3)
        }
    }

    private func historyCard(_ days: [ResilienceDay]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ObsTag("Last \(days.count) days")
            Canvas { ctx, size in
                let n = days.count
                let gap: CGFloat = 2
                let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
                for (i, d) in days.enumerated() {
                    let level = (Resilience.levels.firstIndex(of: d.level) ?? 0) + 1
                    let h = size.height * CGFloat(level) / 5
                    ctx.fill(Path(CGRect(x: CGFloat(i) * (w + gap), y: size.height - h, width: w, height: h)),
                             with: .color(Obs.rem.opacity(i == n - 1 ? 1 : 0.75)))
                }
            }
            .frame(height: 50)
            .scrubbable(days.enumerated().map { i, d in
                ScrubPoint(x: (Double(i) + 0.5) / Double(days.count), label: "\(Fmt.day(d.date)) · \(d.level.capitalized)")
            })
            HStack {
                Text(Fmt.day(days.first?.date)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                Spacer()
                Text(Fmt.day(days.last?.date)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
            }
        }
        .obsCard()
    }
}
