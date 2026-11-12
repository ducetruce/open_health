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
    case readiness, sleepScore, asleep, restingHR, hrv, temperature, oxygen, breathing, steps, activeKcal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .readiness: return "Readiness"
        case .sleepScore: return "Sleep score"
        case .asleep: return "Time asleep"
        case .restingHR: return "Resting heart rate"
        case .hrv: return "Heart rate variability"
        case .temperature: return "Skin temperature"
        case .oxygen: return "Blood oxygen"
        case .breathing: return "Breathing rate"
        case .steps: return "Steps"
        case .activeKcal: return "Active calories"
        }
    }

    var icon: String {
        switch self {
        case .readiness: return "bolt.heart.fill"
        case .sleepScore: return "moon.stars.fill"
        case .asleep: return "bed.double.fill"
        case .restingHR: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .temperature: return "thermometer.medium"
        case .oxygen: return "lungs.fill"
        case .breathing: return "wind"
        case .steps: return "figure.walk"
        case .activeKcal: return "flame.fill"
        }
    }

    var accent: Color {
        switch self {
        case .readiness: return Obs.readinessAccent
        case .sleepScore, .asleep: return Obs.sleepAccent
        case .restingHR, .hrv: return Obs.heartAccent
        case .temperature, .oxygen, .breathing: return Obs.chart
        case .steps, .activeKcal: return Obs.activityAccent
        }
    }

    var unit: String {
        switch self {
        case .readiness, .sleepScore, .asleep, .steps: return ""
        case .restingHR: return "bpm"
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
        case .restingHR, .breathing: return false
        case .temperature: return nil
        default: return true
        }
    }

    /// Display a value of this metric, exactly (durations in hours and minutes).
    func format(_ v: Double) -> String {
        switch self {
        case .asleep: return Fmt.duration(seconds: v)
        case .temperature: return String(format: "%.1f", v)
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
        case .steps: return d.steps
        case .activeKcal: return d.active_kcal
        case .temperature, .oxygen: return nil  // the export has a deviation, not a level
        }
    }

    private func ringDaily(in s: Summary) -> [DatedVital] {
        switch self {
        case .readiness: return s.nightlySeries { $0.readiness?.score }
        case .sleepScore: return s.nightlySeries { $0.mainSleepScore?.score }
        case .asleep:
            // Time asleep = time in bed × the share of it the hypnogram scored as sleep.
            return s.nightlySeries { n in n.efficiency.map { n.durationS * $0 / 100 } }
        case .restingHR: return s.nightlySeries(\.rhr)
        case .hrv: return s.nightlySeries(\.hrv_ms)
        case .temperature:
            let unit = UnitSettings.shared.temperature
            return s.nightlySeries(\.skin_temp).map { DatedVital(date: $0.date, value: Convert.temperature($0.value, unit)) }
        case .oxygen: return s.nightlySeries(\.spo2_mean)
        case .breathing: return s.nightlySeries(\.breath_rate)
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
    var changePct: Double? {
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
                        .map { TrendSummary(metric: $0, summary: s, period: period) }
                    let shown = summaries.filter { $0.count > 0 }
                    if shown.isEmpty {
                        Text("No data in this period yet. Sync your ring, or choose a longer period.")
                            .font(.system(size: 15)).foregroundStyle(Obs.ink2)
                            .obsCard()
                    } else {
                        TrendHighlights(summaries: shown, period: period)
                        ForEach(shown, id: \.metric) { summary in
                            Button { detail = summary.metric } label: {
                                TrendCard(summary: summary, period: period, compact: true)
                            }
                            .buttonStyle(.plain)
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
                        .font(.system(size: 15)).foregroundStyle(Obs.ink)
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
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            ForEach(items.prefix(4), id: \.metric) { item in
                HStack {
                    Text(item.metric.title).font(.system(size: 14)).foregroundStyle(Obs.ink)
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
                Text("average").font(.system(size: 12)).foregroundStyle(Obs.muted)
                Spacer()
            }
            if let direction = directionText {
                Text("\(direction.0) vs \(period.previousLabel)")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(direction.1)
            }
            TrendChart(summary: summary, height: compact ? 110 : 220)
        }
        .obsCard()
    }
}

struct TrendChart: View {
    let summary: TrendSummary
    var height: CGFloat

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
        .chartYScale(domain: .automatic(includesZero: metric == .steps || metric == .activeKcal))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Obs.rule)
                AxisValueLabel(format: unit == .month ? .dateTime.month(.abbreviated).year(.twoDigits)
                                                      : .dateTime.month(.abbreviated).day())
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
        let summary = TrendSummary(metric: metric, summary: s, period: period)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Period", selection: $period) {
                        ForEach(TrendPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if summary.count == 0 {
                        Text("No data in this period yet.")
                            .font(.system(size: 15)).foregroundStyle(Obs.ink2)
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
