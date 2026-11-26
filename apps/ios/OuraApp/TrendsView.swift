import Charts
import SwiftUI

/// The Trends tab: every metric over a chosen period, with its average, the change
/// against the period before, and a chart. Long periods are shown as weekly or
/// monthly averages so a year reads as a shape rather than 365 jittery points.
enum TrendPeriod: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", quarter = "3 Months", year = "Year", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 91
        case .year: return 365
        case .all: return nil
        }
    }
    /// What the previous-period comparison is called.
    var previousLabel: String {
        switch self {
        case .week: return "previous week"
        case .month: return "previous month"
        case .quarter: return "previous 3 months"
        case .year: return "previous year"
        case .all: return "first half"
        }
    }
}

/// How a metric's daily values are gathered and judged.
enum TrendMetric: String, CaseIterable, Identifiable {
    case readiness, sleepScore, asleep, regularity, restingHR, hrv, temperature, oxygen, breathing, stress, steps, activeKcal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .sleepScore: return "Sleep score"
        case .asleep: return "Time asleep"
        case .regularity: return "Sleep regularity"
        case .restingHR: return "Resting heart rate"
        case .hrv: return "Heart rate variability"
        case .temperature: return "Skin temperature"
        case .oxygen: return "Blood oxygen"
        case .breathing: return "Breathing rate"
        case .stress: return "Daytime stress"
        case .steps: return "Steps"
        case .activeKcal: return "Active calories"
        }
    }

    var icon: String {
        switch self {
        case .readiness: return "bolt.heart.fill"
        case .sleepScore: return "moon.stars.fill"
        case .asleep: return "bed.double.fill"
        case .regularity: return "clock.arrow.circlepath"
        case .restingHR: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .temperature: return "thermometer.medium"
        case .oxygen: return "lungs.fill"
        case .breathing: return "wind"
        case .stress: return "waveform.path"
        case .steps: return "figure.walk"
        case .activeKcal: return "flame.fill"
        }
    }

    var accent: Color {
        switch self {
        case .readiness: return Obs.readinessAccent
        case .sleepScore, .asleep, .regularity: return Obs.sleepAccent
        case .restingHR, .hrv: return Obs.heartAccent
        case .temperature, .oxygen, .breathing, .stress: return Obs.chart
        case .steps, .activeKcal: return Obs.activityAccent
        }
    }

    var unit: String {
        switch self {
        case .readiness, .sleepScore, .asleep, .steps, .stress: return ""
        case .restingHR: return "bpm"
        case .regularity: return "min"
        case .hrv: return "ms"
        case .temperature: return UnitSettings.shared.temperature.symbol
        case .oxygen: return "%"
        case .breathing: return "/min"
        case .activeKcal: return "kcal"
        }
    }

    /// Whether a higher value is the better direction; `nil` when neither is
    /// (skin temperature is judged by its distance from your usual, not its level).
    var higherIsBetter: Bool? {
        switch self {
        case .restingHR, .breathing, .stress, .regularity: return false
        case .temperature: return nil
        default: return true
        }
    }

    /// Display a value of this metric, exactly (durations in hours and minutes).
    func format(_ v: Double) -> String {
        switch self {
        case .asleep: return Fmt.duration(seconds: v)
        case .stress: return Fmt.duration(minutes: v)   // stressed time that day
        case .temperature: return String(format: "%+.1f", v)   // change from baseline
        case .breathing: return String(format: "%.1f", v)
        case .steps, .activeKcal: return Fmt.count(v)
        default: return "\(Int(v.rounded()))"
        }
    }

    /// One value per local day, oldest first: ring data, plus days from an imported
    /// Oura export that the ring data doesn't cover.
    func daily(in s: Summary) -> [DatedVital] {
        let ring = ringDaily(in: s)
        guard !s.imported_history.isEmpty else { return ring }
        let covered = Set(ring.map(\.date))
        let imported: [DatedVital] = s.imported_history.compactMap { day, entry in
            guard !covered.contains(day), let v = importedValue(entry) else { return nil }
            return DatedVital(date: day, value: v)
        }
        return (ring + imported).sorted { $0.date < $1.date }
    }

    private func importedValue(_ d: ImportedDay) -> Double? {
        switch self {
        case .readiness: return d.readiness
        case .sleepScore: return d.sleep_score
        case .asleep: return d.asleep_s
        case .restingHR: return d.rhr
        case .hrv: return d.hrv_ms
        case .breathing: return d.breath_rate
        case .stress: return d.stress_summary == nil ? nil : d.stress_min
        case .regularity: return nil   // built from midpoints across both sources, see ringDaily
        case .steps: return d.steps
        case .activeKcal: return d.active_kcal
        // Oura's export records skin temperature as a deviation (°C), the same measure
        // the ring nights are shown in.
        case .temperature: return d.temp_deviation.map { Convert.temperatureDelta($0, UnitSettings.shared.temperature) }
        case .oxygen: return nil
        }
    }

    private func ringDaily(in s: Summary) -> [DatedVital] {
        switch self {
        case .readiness: return s.nightlySeries("readiness") { $0.readiness?.score }
        case .sleepScore: return s.nightlySeries("sleepScore") { $0.mainSleepScore?.score }
        case .asleep:
            // Time asleep = time in bed × the share of it the hypnogram scored as sleep.
            return s.nightlySeries("asleep") { n in n.efficiency.map { n.durationS * $0 / 100 } }
        case .restingHR: return s.nightlySeries(\.rhr)
        case .hrv: return s.nightlySeries(\.hrv_ms)
        case .temperature:
            // Change from the wearer's baseline (see SkinTemp), not the raw finger reading.
            let unit = UnitSettings.shared.temperature
            return SkinTemp.nights(in: s).compactMap { n in
                n.deviation.map { DatedVital(date: n.date, value: Convert.temperatureDelta($0, unit)) }
            }
        case .oxygen: return s.nightlySeries(\.spo2_mean)
        case .breathing: return s.nightlySeries(\.breath_rate)
        // Stressed minutes on days with enough still time for a verdict.
        case .regularity: return SleepRegularity.series(s)
        case .stress: return s.cached("stressTrend") {
            (s.stress?.days ?? [:]).compactMap { day, d in d.verdict == nil ? nil : DatedVital(date: day, value: d.stressed_min) }
                .sorted { $0.date < $1.date }
        }
        case .steps: return s.activity_daily.compactMap { day, st in st.steps.map { DatedVital(date: day, value: $0) } }
            .sorted { $0.date < $1.date }
        case .activeKcal: return s.activity_daily.compactMap { day, st in st.active_kcal.map { DatedVital(date: day, value: $0) } }
            .sorted { $0.date < $1.date }
        }
    }
}

/// A metric's values over one period, ready to show.
struct TrendSummary {
    struct Bucket: Identifiable {
        let start: Date
        let value: Double
        var id: Date { start }
    }

    let metric: TrendMetric
    let buckets: [Bucket]
    let bucketLabel: String          // "Daily", "Weekly averages", "Monthly averages"
    let average: Double?
    let previousAverage: Double?
    let low: Double?
    let high: Double?
    let count: Int

    /// Percent change of this period's average against the previous one.
    /// Not for skin temperature: it is a change from baseline that sits around zero,
    /// so a percentage of it would be meaningless.
    var changePct: Double? {
        guard metric != .temperature else { return nil }
        guard let a = average, let p = previousAverage, p != 0 else { return nil }
        return (a - p) / abs(p) * 100
    }

    enum Direction { case improving, declining, steady }

    var direction: Direction? {
        guard let change = changePct else { return nil }
        if abs(change) < 2 { return .steady }
        guard let higherIsBetter = metric.higherIsBetter else { return .steady }
        return (change > 0) == higherIsBetter ? .improving : .declining
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }()

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The same summary, built once per data load, day, period and temperature unit.
    static func cached(metric: TrendMetric, summary s: Summary, period: TrendPeriod) -> TrendSummary {
        let key = "trend|\(metric)|\(period.rawValue)|\(ymd.string(from: Date()))|\(UnitSettings.shared.temperature)|\(s.imported_history.count)|\(s.activity_daily.count)"
        return s.cached(key) { TrendSummary(metric: metric, summary: s, period: period) }
    }

    init(metric: TrendMetric, summary s: Summary, period: TrendPeriod, today: Date = Date()) {
        self.metric = metric
        let all: [(date: Date, value: Double)] = metric.daily(in: s).compactMap { v in
            Self.ymd.date(from: v.date).map { ($0, v.value) }
        }
        let cal = Self.calendar
        let end = cal.startOfDay(for: today)
        let start: Date
        let previousStart: Date?
        if let days = period.days {
            start = cal.date(byAdding: .day, value: -(days - 1), to: end) ?? end
            previousStart = cal.date(byAdding: .day, value: -days, to: start)
        } else {
            start = all.first?.date ?? end
            previousStart = nil
        }
        let inPeriod = all.filter { $0.date >= start && $0.date <= end }
        let values = inPeriod.map(\.value)
        average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        low = values.min()
        high = values.max()
        count = values.count

        if let previousStart {
            let previous = all.filter { $0.date >= previousStart && $0.date < start }.map(\.value)
            previousAverage = previous.isEmpty ? nil : previous.reduce(0, +) / Double(previous.count)
        } else {
            // "All": compare the second half of the history with the first.
            let half = inPeriod.count / 2
            let first = inPeriod.prefix(half).map(\.value)
            previousAverage = first.isEmpty ? nil : first.reduce(0, +) / Double(first.count)
        }

        let spanDays = (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        let component: Calendar.Component?
        if spanDays <= 92 { component = nil; bucketLabel = "Daily" }
        else if spanDays <= 730 { component = .weekOfYear; bucketLabel = "Weekly averages" }
        else { component = .month; bucketLabel = "Monthly averages" }

        if let component {
            var groups: [Date: [Double]] = [:]
            for point in inPeriod {
                let key = cal.dateInterval(of: component, for: point.date)?.start ?? point.date
                groups[key, default: []].append(point.value)
            }
            buckets = groups.keys.sorted().map { key in
                let v = groups[key]!
                return Bucket(start: key, value: v.reduce(0, +) / Double(v.count))
            }
        } else {
            buckets = inPeriod.map { Bucket(start: $0.date, value: $0.value) }
        }
    }
}

struct TrendsTab<Header: View>: View {
    let s: Summary
    /// What decides a redraw; see `TabInputs`.
    let inputs: TabInputs
    @ViewBuilder var header: () -> Header
    @AppStorage("trends.period") private var periodRaw = TrendPeriod.month.rawValue
    @State private var detail: TrendMetric?
    @ObservedObject private var units = UnitSettings.shared

    private var period: TrendPeriod { TrendPeriod(rawValue: periodRaw) ?? .month }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header()
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Period", selection: $periodRaw) {
                        ForEach(TrendPeriod.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    let summaries = TrendMetric.allCases
                        .map { TrendSummary.cached(metric: $0, summary: s, period: period) }
                    let shown = summaries.filter { $0.count > 0 }
                    if shown.isEmpty {
                        Text("No data in this period yet. Sync your ring, or choose a longer period.")
                            .font(Obs.mono(15)).foregroundStyle(Obs.ink2)
                            .obsCard()
                    } else {
                        TrendHighlights(summaries: shown, period: period)
                        ForEach(shown, id: \.metric) { summary in
                            // A tap opens the detail view; touching the chart and
                            // sliding scrubs it instead.
                            TrendCard(summary: summary, period: period, compact: true)
                                .contentShape(Rectangle())
                                .onTapGesture { detail = summary.metric }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Obs.canvas)
        .sheet(item: $detail) { metric in
            TrendDetailView(s: s, metric: metric, initialPeriod: period)
        }
    }
}

/// What improved and what slipped most over the period: the "areas to work on" view.
private struct TrendHighlights: View {
    let summaries: [TrendSummary]
    let period: TrendPeriod

    var body: some View {
        let judged = summaries.filter { $0.direction != nil && $0.metric.higherIsBetter != nil }
        let improving = judged.filter { $0.direction == .improving }
            .sorted { abs($0.changePct ?? 0) > abs($1.changePct ?? 0) }
        let declining = judged.filter { $0.direction == .declining }
            .sorted { abs($0.changePct ?? 0) > abs($1.changePct ?? 0) }
        if !judged.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ObsTag("compared with the \(period.previousLabel)", icon: "arrow.up.arrow.down")
                if declining.isEmpty && improving.isEmpty {
                    Text("Everything is holding steady.")
                        .font(Obs.mono(15)).foregroundStyle(Obs.ink)
                }
                if !declining.isEmpty {
                    highlightRow(title: "Needs attention", items: declining, color: Obs.bad,
                                 icon: "exclamationmark.circle.fill")
                }
                if !improving.isEmpty {
                    highlightRow(title: "Improving", items: improving, color: Obs.good,
                                 icon: "checkmark.circle.fill")
                }
            }
            .obsCard()
        }
    }

    private func highlightRow(title: String, items: [TrendSummary], color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(Obs.mono(14)).foregroundStyle(color)
            ForEach(items.prefix(4), id: \.metric) { item in
                HStack {
                    Text(item.metric.title).font(Obs.mono(14)).foregroundStyle(Obs.ink)
                    Spacer()
                    Text(changeText(item)).font(Obs.mono(13, .medium)).foregroundStyle(color)
                }
            }
        }
    }
}

private func changeText(_ s: TrendSummary) -> String {
    guard let c = s.changePct else { return "–" }
    return String(format: "%@%.0f%%", c >= 0 ? "+" : "−", abs(c))
}

/// One metric: headline average, change, and its chart.
struct TrendCard: View {
    let summary: TrendSummary
    let period: TrendPeriod
    var compact: Bool

    private var directionText: (String, Color)? {
        guard let d = summary.direction else { return nil }
        let change = changeText(summary)
        switch d {
        case .improving: return ("\(change) · improving", Obs.good)
        case .declining: return ("\(change) · needs attention", Obs.bad)
        case .steady: return ("\(change) · steady", Obs.ink2)
        }
    }

    var body: some View {
        let metric = summary.metric
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ObsTag(metric.title, icon: metric.icon)
                Spacer()
                if compact {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.average.map { metric.format($0) } ?? "–")
                    .font(Obs.mono(28, .medium)).foregroundStyle(Obs.ink)
                if !metric.unit.isEmpty {
                    Text(metric.unit).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                }
                Text("average").font(Obs.mono(12)).foregroundStyle(Obs.muted)
                Spacer()
            }
            if let direction = directionText {
                Text("\(direction.0) vs \(period.previousLabel)")
                    .font(Obs.mono(12)).foregroundStyle(direction.1)
            }
            TrendChart(summary: summary, height: compact ? 110 : 220)
        }
        .obsCard()
    }
}

struct TrendChart: View {
    let summary: TrendSummary
    var height: CGFloat

    private func readout(_ b: TrendSummary.Bucket) -> String {
        let metric = summary.metric
        let when = summary.bucketLabel == "Daily" ? b.start.formatted(.dateTime.month(.abbreviated).day())
            : summary.bucketLabel == "Weekly averages" ? "Week of " + b.start.formatted(.dateTime.month(.abbreviated).day())
            : b.start.formatted(.dateTime.month(.abbreviated).year())
        let value = metric == .asleep ? Fmt.duration(seconds: b.value) : metric.format(b.value)
        return "\(when) · \(value)\(metric.unit.isEmpty ? "" : " " + metric.unit)"
    }

    var body: some View {
        let metric = summary.metric
        let unit: Calendar.Component = summary.bucketLabel == "Daily" ? .day
            : summary.bucketLabel == "Weekly averages" ? .weekOfYear : .month
        Chart {
            ForEach(summary.buckets) { b in
                if metric == .steps || metric == .activeKcal {
                    BarMark(x: .value("Date", b.start, unit: unit), y: .value(metric.title, b.value))
                        .foregroundStyle(metric.accent.opacity(0.85))
                } else {
                    LineMark(x: .value("Date", b.start, unit: unit), y: .value(metric.title, b.value))
                        .foregroundStyle(metric.accent)
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", b.start, unit: unit), y: .value(metric.title, b.value))
                        .foregroundStyle(metric.accent)
                        .symbolSize(summary.buckets.count > 40 ? 8 : 22)
                }
            }
            if let avg = summary.average {
                RuleMark(y: .value("Average", avg))
                    .foregroundStyle(Obs.ink.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        // Scrubbing lives in its own overlay view with its own state, so moving the
        // finger redraws only the line and label, never the marks.
        .chartOverlay { proxy in
            TrendScrub(proxy: proxy, buckets: summary.buckets, unit: unit, readout: readout)
        }
        .chartYScale(domain: .automatic(includesZero: metric == .steps || metric == .activeKcal))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Obs.rule)
                AxisValueLabel(format: unit == .month ? .dateTime.month(.abbreviated).year(.twoDigits)
                                                      : .dateTime.month(.defaultDigits).day())
                    .foregroundStyle(Obs.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Obs.rule)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric == .asleep ? Fmt.duration(seconds: v) : metric.format(v))
                            .foregroundStyle(Obs.muted)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(metric.title), \(summary.bucketLabel.lowercased())")
    }
}

/// Full-screen view of one metric with its own period picker and statistics.
struct TrendDetailView: View {
    let s: Summary
    let metric: TrendMetric
    @State private var period: TrendPeriod
    @Environment(\.dismiss) private var dismiss

    init(s: Summary, metric: TrendMetric, initialPeriod: TrendPeriod) {
        self.s = s
        self.metric = metric
        _period = State(initialValue: initialPeriod)
    }

    var body: some View {
        let summary = TrendSummary.cached(metric: metric, summary: s, period: period)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Period", selection: $period) {
                        ForEach(TrendPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if summary.count == 0 {
                        Text("No data in this period yet.")
                            .font(Obs.mono(15)).foregroundStyle(Obs.ink2)
                    } else {
                        TrendCard(summary: summary, period: period, compact: false)
                        VStack(spacing: 10) {
                            ObsStat(label: "Average", value: stat(summary.average))
                            ObsStat(label: "Lowest", value: stat(summary.low))
                            ObsStat(label: "Highest", value: stat(summary.high))
                            ObsStat(label: "Previous period average", value: stat(summary.previousAverage))
                            ObsStat(label: "Days with data", value: "\(summary.count)")
                            ObsStat(label: "Chart shows", value: summary.bucketLabel)
                        }
                        .obsCard()
                    }
                }
                .padding(20)
            }
            .background(Obs.canvas.ignoresSafeArea())
            .navigationTitle(metric.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func stat(_ v: Double?) -> String {
        guard let v else { return "–" }
        return metric.unit.isEmpty ? metric.format(v) : "\(metric.format(v)) \(metric.unit)"
    }
}

extension TrendsTab: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool { a.inputs == b.inputs }
}

/// The scrub line and readout over a trend chart. Follows a sideways drag only, so a
/// drag up or down that starts on the chart still scrolls the page.
private struct TrendScrub: View {
    let proxy: ChartProxy
    let buckets: [TrendSummary.Bucket]
    let unit: Calendar.Component
    let readout: (TrendSummary.Bucket) -> String
    @State private var selected: Int?
    @State private var direction: Axis?
    private static let ticker = UISelectionFeedbackGenerator()
    private let labelWidth: CGFloat = 170

    /// Where a bucket's mark sits: the middle of its day, week or month.
    private func center(_ b: TrendSummary.Bucket) -> Date {
        let next = TrendSummary.calendar.date(byAdding: unit, value: 1, to: b.start) ?? b.start
        return b.start.addingTimeInterval(next.timeIntervalSince(b.start) / 2)
    }

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { g in
                                if direction == nil {
                                    direction = abs(g.translation.width) > abs(g.translation.height) ? .horizontal : .vertical
                                }
                                guard direction == .horizontal,
                                      let date: Date = proxy.value(atX: g.location.x - plot.minX) else { return }
                                let i = buckets.indices.min {
                                    abs(center(buckets[$0]).timeIntervalSince(date)) < abs(center(buckets[$1]).timeIntervalSince(date))
                                }
                                if let i, i != selected {
                                    selected = i
                                    Self.ticker.selectionChanged()
                                }
                            }
                            .onEnded { _ in
                                direction = nil
                                selected = nil
                            }
                    )
                if let i = selected, buckets.indices.contains(i),
                   let px = proxy.position(forX: center(buckets[i])) {
                    let x = plot.minX + px
                    Rectangle().fill(Obs.signal)
                        .frame(width: 1, height: plot.height)
                        .offset(x: x - 0.5, y: plot.minY)
                        .allowsHitTesting(false)
                    Text(readout(buckets[i]))
                        .font(Obs.mono(11)).foregroundStyle(Obs.onSignal)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Obs.signal, in: RoundedRectangle(cornerRadius: 3))
                        .frame(width: labelWidth)
                        .offset(x: min(max(x - labelWidth / 2, 0), max(0, geo.size.width - labelWidth)),
                                y: plot.minY - 22)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// How regular your sleep timing is: for each night, the spread (standard deviation)
/// of the sleep midpoint over that night and the six before it, in minutes. Lower is
/// steadier; Oura's sleep-regularity contributor is built on the same idea. Nights
/// come from the ring, and from an imported Oura export before it.
enum SleepRegularity {
    static func series(_ s: Summary) -> [DatedVital] {
        s.cached("sleepRegularity") {
            var mids: [String: Double] = [:]
            for (day, e) in s.imported_history { if let m = e.mid_hour { mids[day] = m } }
            for day in s.days {
                guard let n = s.night(forDay: day), let a = n.start_unix, let b = n.end_unix else { continue }
                let mid = Date(timeIntervalSince1970: TimeInterval(a + b) / 2)
                let c = Calendar.current.dateComponents([.hour, .minute], from: mid)
                let h = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
                mids[day] = h < 12 ? h + 24 : h   // small hours after midnight count past 24
            }
            let days = mids.keys.sorted()
            var out: [DatedVital] = []
            for (i, day) in days.enumerated() {
                guard let date = WorkoutFormat.day.date(from: day) else { continue }
                // The nights within the 7 days ending on this one.
                let window = days[max(0, i - 6)...i].filter { d in
                    guard let dd = WorkoutFormat.day.date(from: d) else { return false }
                    return date.timeIntervalSince(dd) < 7 * 86_400
                }.compactMap { mids[$0] }
                guard window.count >= 4 else { continue }
                let mean = window.reduce(0, +) / Double(window.count)
                let sd = (window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(window.count)).squareRoot()
                out.append(DatedVital(date: day, value: (sd * 60).rounded()))
            }
            return out
        }
    }
}
