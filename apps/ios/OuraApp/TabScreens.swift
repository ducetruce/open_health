import SwiftUI

// The Today, Sleep and Vitals screens. Each is its own view with its own state and
// is compared by the data it shows (`version`, the header status, the units), so a tap
// on one screen (opening the readiness contributors, picking a night) redraws only that
// screen, and the app's own changes (sync progress, sheets, tab switches) redraw none
// of them unless what they show has changed.

/// What a screen can ask the app to do: switch tabs, open a sheet, end a workout.
struct AppActions {
    var go: (AppTab) -> Void
    var openReport: (ReportSel) -> Void
    var sleepDebt: () -> Void
    var vital: (VitalKind) -> Void
    var allDays: () -> Void
    var profile: () -> Void
    var sync: () -> Void
    var finishWorkout: () -> Void
    /// The ring sheet (battery, sync, ring details).
    var ring: () -> Void
    /// Pick a day for every daily screen; "" follows today.
    var selectDay: (String) -> Void
}

/// What decides whether a tab must redraw: the merged summary's version, the
/// header's status line, whether a sync or analysis is running, and the display units.
struct TabInputs: Equatable {
    var version: Int
    var busyLabel: String?
    var isBusy: Bool
    var units: String
    /// The day picked for every daily screen (yyyy-MM-dd); "" follows today.
    var day: String = ""
}

/// The ring's battery, profile and sync buttons at the right of every screen title.
struct HeaderButtons: View {
    let actions: AppActions
    var battery: Int? = nil
    var body: some View {
        if let battery {
            Button(action: actions.ring) {
                HStack(spacing: 4) {
                    BatteryGlyph(level: Double(battery) / 100)
                    Text("\(battery)%").font(Obs.mono(11)).foregroundStyle(battery < 20 ? Obs.bad : Obs.ink2)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(Obs.rule, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ring battery \(battery) percent")
            .accessibilityHint("Opens your ring: battery, sync and details")
        }
        Button(action: actions.profile) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22)).foregroundStyle(Obs.ink2)
        }
        .accessibilityLabel("Profile")
        SyncIndicatorButton(ring: RingSync.shared, action: actions.sync)
    }
}

/// A small battery outline filled to `level` (0…1), amber when low.
struct BatteryGlyph: View {
    let level: Double
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Obs.ink2, lineWidth: 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(level < 0.2 ? Obs.bad : Obs.signal)
                    .frame(width: max(1, 14 * min(1, max(0, level))))
                    .padding(2)
            }
            .frame(width: 18, height: 9)
            Rectangle().fill(Obs.ink2).frame(width: 2, height: 4)
        }
        .accessibilityHidden(true)
    }
}

/// The days the daily screens can show, newest first (today always included).
enum DayKeys {
    static var today: String { WorkoutFormat.day.string(from: Date()) }
    static func all(_ s: Summary) -> [String] {
        let t = today
        return s.cached("dayKeys|\(t)") {
            var d = s.days
            if !d.contains(t) { d.append(t) }
            return d.sorted(by: >)
        }
    }
    /// The picked day, or today when none is picked.
    static func resolve(_ picked: String) -> String { picked.isEmpty ? today : picked }
    /// "Monday, Nov 23".
    static func long(_ day: String) -> String {
        WorkoutFormat.day.date(from: day).map { longFormat.string(from: $0) } ?? day
    }
    private static let longFormat: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEMMMMd"); return f
    }()
}

/// The week strip every daily screen shares: picking a day here picks it for Today,
/// Sleep and Activity together. Off today, a pill (or tapping the tab again) brings
/// everything back to today.
struct DateBar: View {
    let s: Summary
    let picked: String          // resolved day
    let onSelect: (String) -> Void
    var detail: (String) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DayStrip(days: DayKeys.all(s),
                     selection: Binding(get: { picked }, set: { onSelect($0 == DayKeys.today ? "" : $0) }),
                     detail: detail)
            if picked != DayKeys.today {
                Button { withAnimation(.easeOut(duration: 0.2)) { onSelect("") } } label: {
                    Text("↺ BACK TO TODAY").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.onSignal)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Obs.signal, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to today")
            }
        }
        .padding(.horizontal, 18)
    }
}

/// Shown in place of a screen when there is no data yet.
struct ErrorCard: View {
    let err: String
    let onConnect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ObsTag("no data yet", icon: "antenna.radiowaves.left.and.right")
            Text(err).font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onConnect) {
                Text("Connect your ring").font(Obs.mono(15))
                    .foregroundStyle(Obs.paper).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Obs.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }.buttonStyle(.plain)
        }
        .obsCard()
        .padding(.horizontal, 20)
    }
}

/// The date a screen is showing, for the line over its title: "Thu, Nov 19".
enum DayHeading {
    private static let format: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEMMMd"); return f
    }()
    static func label(_ day: String) -> String {
        WorkoutFormat.day.date(from: day).map { format.string(from: $0) } ?? day
    }
}

/// "LATEST NIGHT ›": shown when an older day is picked, jumps back to the newest.
struct LatestLink: View {
    let title: String
    let action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Text("\(title.uppercased()) ›").font(Obs.label(11)).tracking(1.4).foregroundStyle(Obs.signal)
                    .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A scrolling tab page over the app backdrop.
struct TabPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Obs.canvas)
    }
}

/// Small formatting helpers the screens share.
protocol TabHelpers {}
extension TabHelpers {
    func f(_ v: Double?, _ fallback: String = "–") -> String {
        v.map { "\(Int($0))" } ?? fallback
    }
    func relAge(_ diff: Double) -> String {
        let a = abs((diff * 10).rounded() / 10)
        if diff < -0.05 { return "\(a) yr younger" }
        if diff > 0.05 { return "\(a) yr older" }
        return "In line"
    }
    func localDay(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    func displayedDayLabel(_ day: String, now: Date = Date()) -> String {
        if day == localDay(now) { return "Today" }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
           day == localDay(yesterday) { return "Yesterday" }
        return day
    }
    func latestLabel(date: String?, time: String? = nil) -> String {
        let day = date.map { Fmt.day($0) }
        let stamp = [day, time.map { Fmt.clock($0) }].compactMap { $0 }.joined(separator: " · ")
        return stamp.isEmpty ? "Latest sync" : "Latest · \(stamp)"
    }
}

// MARK: - Today

/// Which day a sheet is about.
struct DayRef: Identifiable { let day: String; var id: String { day } }

struct TodayTab: View, Equatable, TabHelpers {
    let s: Summary
    let inputs: TabInputs
    let actions: AppActions
    @ObservedObject private var store = WorkoutStore.shared
    @State private var readinessFor: DayRef?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.inputs == b.inputs }

    private var busyLabel: String? { inputs.busyLabel }
    private var isBusy: Bool { inputs.isBusy }

    var body: some View {
        TabPage { todayTab(s) }
            .sheet(item: $readinessFor) { ref in ReadinessView(s: s, day: ref.day) }
    }

    @ViewBuilder private func todayTab(_ s: Summary) -> some View {
        let key = DayKeys.resolve(inputs.day)
        let isToday = key == DayKeys.today
        AppHeader(title: "Today", subtitle: busyLabel ?? DayKeys.long(key)) {
            HeaderButtons(actions: actions, battery: s.device?.battery_pct)
        }
        if let err = s.error {
            ErrorCard(err: err, onConnect: actions.sync)
        } else {
            let night = s.night(forDay: key)
            DateBar(s: s, picked: key, onSelect: actions.selectDay) { d in
                (s.night(forDay: d)?.readiness?.score ?? s.imported_history[d]?.readiness).map { "\(Int($0))" }
            }
            VStack(alignment: .leading, spacing: 14) {
                readinessCard(s, night: night, day: key)
                if isToday, let active = store.active {
                    LiveWorkoutCard(active: active, onEnd: actions.finishWorkout)
                }
                if isToday { reviewLink(s) }
                lastNightCard(s, night: night, day: key, isToday: isToday)
                todaySignals(s, night: night, isToday: isToday)
                VStack(alignment: .leading, spacing: 6) {
                    Text(isToday ? "SO FAR TODAY" : "THAT DAY").font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
                    Text(isToday ? "Activity & stress" : DayKeys.long(key)).font(Obs.pixel(24)).foregroundStyle(Obs.ink)
                }
                .padding(.top, 16)
                HStack(alignment: .top, spacing: 8) {
                    activityMini(s, day: key)
                    stressMini(s, day: key)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: Today pieces

    private func readinessBand(_ score: Double) -> String {
        switch score {
        case 85...: return "Optimal"
        case 70..<85: return "Good"
        case 60..<70: return "Fair"
        default: return "Pay attention"
        }
    }

    private func readinessHeadline(_ score: Double) -> String {
        switch score {
        case 85...: return "Ready for a harder day"
        case 70..<85: return "Ready for a normal day"
        case 60..<70: return "Take it a bit easier"
        default: return "Put recovery first today"
        }
    }

    /// Readiness for the picked day: the ring, what it means, and a way into every
    /// contributor (the Readiness page).
    @ViewBuilder private func readinessCard(_ s: Summary, night: NightRow?, day: String) -> some View {
        let readiness = night?.readiness
        Button { readinessFor = DayRef(day: day) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ObsTag("Readiness")
                    Spacer()
                    if readiness?.provisional == true {
                        Text("PROVISIONAL").font(Obs.label(10)).tracking(1.6).foregroundStyle(Obs.signal)
                    }
                }
                HStack(alignment: .center, spacing: 16) {
                    ScoreRing(value: readiness.map { "\(Int($0.score))" } ?? "–", caption: "readiness",
                              progress: readiness.map { $0.score / 100 }, size: 112, lineWidth: 7, showCaption: false)
                    VStack(alignment: .leading, spacing: 8) {
                        if let r = readiness {
                            SignalBadge(text: readinessBand(r.score))
                            Text(readinessHeadline(r.score))
                                .font(Obs.mono(18)).foregroundStyle(Obs.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(day == DayKeys.today ? (s.digest ?? readinessSummary(r)) : readinessSummary(r))
                                .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("CONTRIBUTORS ›").font(Obs.label(11)).tracking(1.4).foregroundStyle(Obs.ink)
                        } else {
                            Text(night == nil ? "No night recorded for this day. Wear your ring to bed, then sync in the morning."
                                              : "Readiness appears after a few nights have been synced: it compares each night with your own baseline.")
                                .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .obsCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(readiness == nil)
    }

    /// The night before the picked day: time asleep, bed and wake times, stages and
    /// sleep score (opens Sleep), with the running sleep debt.
    @ViewBuilder private func lastNightCard(_ s: Summary, night: NightRow?, day: String, isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { actions.go(.sleep) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ObsTag(isToday ? "Last night" : "That night", icon: "moon.fill")
                        Spacer()
                        if let score = night?.mainSleepScore {
                            Text("Sleep score \(Int(score.score))").font(Obs.mono(12)).foregroundStyle(Obs.ink)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                    }
                    if let n = night {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Fmt.duration(seconds: asleepSeconds(n) ?? n.durationS)).font(Obs.pixel(30)).foregroundStyle(Obs.ink)
                            Text("ASLEEP").font(Obs.label(10)).tracking(1.2).foregroundStyle(Obs.muted)
                            Spacer()
                            Text("\(Fmt.clock(n.start)) → \(Fmt.clock(n.end))").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                        }
                        if n.hasHypnogram { Hypnogram(stages: n.hypnogram!, height: 28) }
                    } else {
                        Text("No sleep recorded for this night.").font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isToday, let debt = s.sleepDebt {
                Rectangle().fill(Obs.rule).frame(height: 1)
                Button { actions.sleepDebt() } label: {
                    HStack {
                        Text("SLEEP DEBT").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                        Spacer()
                        Text(Fmt.duration(minutes: debt.debt_min)).font(Obs.mono(13)).foregroundStyle(Obs.ink)
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .obsCard()
    }

    /// Steps and active calories for the day, with progress toward the goals.
    private func activityMini(_ s: Summary, day: String) -> some View {
        let st = s.activity_daily[day]
        let goal = activityGoalProgress(st) ?? 0
        return Button { actions.go(.activity) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("ACTIVITY").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                }
                Text(Fmt.count(st?.steps)).font(Obs.pixel(28)).foregroundStyle(Obs.ink)
                Text("steps · \(Fmt.count(st?.active_kcal)) kcal").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Obs.rule)
                        Rectangle().fill(Obs.signal).frame(width: g.size.width * CGFloat(goal))
                    }
                }
                .frame(height: 3)
            }
            .obsCard(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The day's stressed time and verdict.
    private func stressMini(_ s: Summary, day: String) -> some View {
        let d = s.stress?.days[day]
        return Button { actions.go(.activity) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("STRESS").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                }
                Text(d.map { Fmt.duration(minutes: $0.stressed_min) } ?? "–").font(Obs.pixel(28))
                    .foregroundStyle(d == nil ? Obs.ink : StressState.stressed.color)
                Text(d.map { "stressed · \(($0.verdict ?? "measuring").capitalized)" } ?? "no still readings yet")
                    .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                DayStressStrip(windows: d?.windows ?? [], height: 6)
            }
            .obsCard(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func signedPercent(_ v: Double?) -> String? {
        guard let v else { return nil }
        return String(format: "%+.0f%% vs base", v)
    }

    /// Resting heart rate, HRV and blood oxygen for the latest night, with the last
    /// two weeks as pixel bars.
    @ViewBuilder private func todaySignals(_ s: Summary, night: NightRow?, isToday: Bool) -> some View {
        let recent = Array(s.nights.prefix(14).reversed())
        let rhrSeries = recent.compactMap(\.rhr)
        let hrvSeries = Array(s.vitals.hrv.series.suffix(14))
        let spo2Series = recent.compactMap(\.spo2_mean)
        let spo2 = night?.spo2_mean ?? s.nights.first { $0.spo2_mean != nil }?.spo2_mean
        VStack(alignment: .leading, spacing: 6) {
            Text("OVERNIGHT · VS YOUR BASELINE").font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
            Text(isToday ? "Today’s signals" : "That night’s signals").font(Obs.pixel(24)).foregroundStyle(Obs.ink)
        }
        .padding(.top, 16)
        HStack(spacing: 8) {
            SignalTile(name: "Resting HR", index: "01",
                       value: f(night?.rhr ?? s.vitals.rhr.latest), unit: "bpm", series: rhrSeries,
                       note: s.vitals.rhr.delta_pct.map { abs($0) < 3 ? "At baseline" : String(format: "%+.0f%% vs base", $0) } ?? "Baseline building") { actions.vital(.heartRate) }
            SignalTile(name: "HRV", index: "02",
                       value: f(s.vitals.hrv.latest ?? night?.hrv_ms), unit: "ms", series: hrvSeries,
                       note: signedPercent(s.vitals.hrv.delta_pct) ?? "Baseline building") { actions.vital(.hrv) }
            SignalTile(name: "Blood O₂", index: "03",
                       value: f(spo2), unit: "%", series: spo2Series,
                       note: spo2.map { $0 >= 95 ? "Normal" : "Below 95%" } ?? "No reading yet") { actions.vital(.oxygen) }
        }
    }

    /// "2 detected workouts to review ›", linking to the review group on Activity.
    @ViewBuilder private func reviewLink(_ s: Summary) -> some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()).map { WorkoutFormat.day.string(from: $0) } ?? ""
        let count = s.allWorkouts.filter { $0.isAuto && $0.dayLabel >= cutoff }.count
        if count > 0 {
            Button { actions.go(.activity) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Obs.signal)
                    Text(count == 1 ? "1 detected workout to review" : "\(count) detected workouts to review")
                        .font(Obs.mono(15)).foregroundStyle(Obs.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Obs.muted)
                }
                .padding(14)
                .background(Obs.card, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Obs.signalDim, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Average progress toward the daily calorie and step goals, 0…1 (capped).
    private func activityGoalProgress(_ st: DailyStat?) -> Double? {
        guard let st else { return nil }
        let kcal = (st.active_kcal ?? 0) / ActivityGoals.activeKcal
        let steps = (st.steps ?? 0) / ActivityGoals.steps
        return min(1, (min(1, kcal) + min(1, steps)) / 2)
    }

    /// One line naming the strongest and weakest readiness contributors.
    private func readinessSummary(_ r: SleepScore) -> String {
        let sorted = r.components.sorted { $0.score > $1.score }
        guard let best = sorted.first, let worst = sorted.last else { return scoreBasisLabel(r) }
        if worst.score >= 80 { return "Everything looks on track. Strongest: \(best.label) (\(Int(best.score)))." }
        return "Strongest: \(best.label) (\(Int(best.score))). Needs attention: \(worst.label) (\(Int(worst.score)))."
    }

}

// MARK: - Readiness page

/// Readiness for one day: score, every contributor, the measurements behind them,
/// and the two weeks around it.
struct ReadinessView: View {
    let s: Summary
    let day: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let night = s.night(forDay: day)
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(DayKeys.long(day).uppercased()).font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
                        if let r = night?.readiness {
                            SleepScoreCard(score: r)
                            if r.provisional == true {
                                Text("Provisional: readiness compares each night with your own recent nights, and settles after about two weeks of them.")
                                    .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            inputs(night!)
                        } else {
                            Text("No readiness for this day.").font(Obs.mono(14)).foregroundStyle(Obs.ink2).obsCard()
                        }
                        history
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Readiness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    /// The measurements the contributors were scored from, beside your usual.
    private func inputs(_ n: NightRow) -> some View {
        let earlier = s.nights.filter { ($0.end_unix ?? 0) < (n.start_unix ?? 0) }.prefix(14)
        let usual = { (pick: (NightRow) -> Double?) -> Double? in
            let v = earlier.compactMap(pick)
            return v.count >= 3 ? v.reduce(0, +) / Double(v.count) : nil
        }
        let temp = SkinTemp.nights(in: s).first { $0.date == day }?.deviation
        let unit = UnitSettings.shared.temperature
        return VStack(alignment: .leading, spacing: 10) {
            ObsTag("What went in")
            ObsStat(label: "Lowest heart rate", value: line(n.rhr, usual(\.rhr), "bpm"))
            ObsStat(label: "Average HRV", value: line(n.hrv_ms, usual(\.hrv_ms), "ms"))
            ObsStat(label: "Skin temperature", value: temp.map { "\(SkinTemp.signed($0, unit)) \(unit.symbol)" } ?? "–")
            ObsStat(label: "Time asleep", value: Fmt.duration(seconds: asleepSeconds(n) ?? n.durationS))
            ObsStat(label: "Sleep, nights before", value: {
                let v = s.nights.drop(while: { $0.id != n.id }).prefix(14).compactMap { asleepSeconds($0) }
                return v.isEmpty ? "–" : Fmt.duration(seconds: v.reduce(0, +) / Double(v.count)) + " avg"
            }())
        }
        .obsCard()
    }

    private func line(_ value: Double?, _ usual: Double?, _ unit: String) -> String {
        guard let value else { return "–" }
        let now = "\(Int(value.rounded())) \(unit)"
        return usual.map { now + " · usual \(Int($0.rounded()))" } ?? now
    }

    /// Readiness for the 14 days ending on this one.
    @ViewBuilder private var history: some View {
        let keys = DayKeys.all(s).filter { $0 <= day }.prefix(14).reversed()
        let values: [(String, Double)] = keys.compactMap { d in
            (s.night(forDay: d)?.readiness?.score ?? s.imported_history[d]?.readiness).map { (d, $0) }
        }
        if values.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                ObsTag("Last \(values.count) days")
                PixelBars(values: values.map(\.1), height: 60, floor: 40)
                    .scrubbable(values.enumerated().map { i, v in
                        ScrubPoint(x: (Double(i) + 0.5) / Double(values.count), label: "\(Fmt.day(v.0)) · \(Int(v.1))")
                    })
                HStack {
                    Text(Fmt.day(values.first?.0)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                    Spacer()
                    Text(Fmt.day(values.last?.0)).font(Obs.mono(10)).foregroundStyle(Obs.ink2)
                }
            }
            .obsCard()
        }
    }
}

// MARK: - Sleep

struct SleepTab: View, Equatable, TabHelpers {
    let s: Summary
    let inputs: TabInputs
    let actions: AppActions
    @State private var readinessFor: DayRef?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.inputs == b.inputs }

    private var busyLabel: String? { inputs.busyLabel }

    var body: some View {
        TabPage { sleepTab(s) }
            .sheet(item: $readinessFor) { ref in ReadinessView(s: s, day: ref.day) }
    }

    @ViewBuilder private func sleepTab(_ s: Summary) -> some View {
        let key = DayKeys.resolve(inputs.day)
        AppHeader(title: "Sleep", subtitle: busyLabel ?? DayKeys.long(key)) {
            HeaderButtons(actions: actions, battery: s.device?.battery_pct)
        }
        if let err = s.error {
            ErrorCard(err: err, onConnect: actions.sync)
        } else {
            DateBar(s: s, picked: key, onSelect: actions.selectDay) { d in
                s.night(forDay: d)?.mainSleepScore.map { "\(Int($0.score))" }
            }
            VStack(alignment: .leading, spacing: 18) {
                if let n = s.night(forDay: key) {
                    sleepHero(n)
                    if let r = n.readiness {
                        Button { readinessFor = DayRef(day: key) } label: {
                            HStack {
                                Text("READINESS THAT MORNING").font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                                Spacer()
                                Text("\(Int(r.score))").font(Obs.mono(15)).foregroundStyle(Obs.ink)
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                            }
                            .obsCard(padding: 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        SleepReport(s: s, day: key)
                    }
                    .padding(.top, 4)
                } else {
                    Text("No sleep recorded for the night ending \(DayKeys.long(key)).")
                        .font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .obsCard()
                }
                if let debt = s.sleepDebt {
                    SleepDebtCard(debt: debt) { actions.sleepDebt() }.obsCard()
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func sleepHero(_ n: NightRow) -> some View {
        HStack(spacing: 20) {
            ScoreRing(value: n.mainSleepScore.map { "\(Int($0.score))" } ?? "–", caption: "sleep score",
                      progress: n.mainSleepScore.map { $0.score / 100 }, accent: Obs.sleepAccent, size: 108, lineWidth: 10)
            VStack(alignment: .leading, spacing: 10) {
                heroStat("Time in bed", Fmt.duration(seconds: n.durationS))
                heroStat("Efficiency", n.efficiency.map { "\(Int($0))%" })
                heroStat("Resting HR", n.rhr.map { "\(Int($0)) bpm" })
                heroStat("HRV", n.hrv_ms.map { "\(Int($0)) ms" })
            }
        }
        .obsCard(padding: 20)
    }

    private func heroStat(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).font(Obs.mono(13)).foregroundStyle(Obs.muted)
            Spacer()
            Text(value ?? "–").font(Obs.mono(15, .semibold)).foregroundStyle(Obs.ink)
        }
    }
}

// MARK: - Vitals

/// The body and health measures (formerly the Vitals tab), shown at the end of
/// Trends: nightly HRV, heart rate, skin temperature and blood oxygen, then the
/// symptom radar and cardiovascular estimates.
struct BodyHealthSections: View, TabHelpers {
    let s: Summary
    let actions: AppActions
    @ObservedObject private var units = UnitSettings.shared

    var body: some View {
        let latestTemp = s.nights.first { $0.skin_temp != nil }
        let latestOxygen = s.nights.first { $0.spo2_mean != nil }
        let tempUnit = units.temperature
        let recentTemperatures = Array(s.nights.compactMap(\.skin_temp).prefix(14).reversed())
            .map { Convert.temperature($0, tempUnit) }
        let recentOxygen = Array(s.nights.compactMap(\.spo2_mean).prefix(14).reversed())
        let latestHR = s.vitals.hr
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("Body", "Latest · vs your baseline")
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 24) {
                        VitalCell(tag: "nightly hrv", value: f(s.vitals.hrv.latest), unit: "ms",
                                  delta: s.vitals.hrv.delta_pct, series: s.vitals.hrv.series,
                                  baseline: s.vitals.hrv.baseline,
                                  action: { actions.vital(.hrv) })
                        VitalCell(tag: "heart rate",
                                  value: f(latestHR?.latest ?? s.vitals.rhr.latest), unit: "bpm",
                                  series: s.vitals.rhr.series,
                                  baseline: s.vitals.rhr.baseline,
                                  deltaGoodWhenPositive: false,
                                  detail: latestHR.map { latestLabel(date: $0.date, time: $0.hm) }
                                      ?? "Nightly minimum",
                                  action: { actions.vital(.heartRate) })
                    }
                    Rectangle().fill(Obs.rule).frame(height: 1)
                    HStack(alignment: .top, spacing: 24) {
                        // Skin temperature as the change from the baseline; the raw reading
                        // moves to the detail line (and stays the value until a baseline exists).
                        let tempNights = SkinTemp.nights(in: s)
                        let lastTemp = tempNights.last
                        VitalCell(tag: "skin temp",
                                  value: lastTemp?.deviation.map { SkinTemp.signed($0, tempUnit) }
                                      ?? Fmt.temperature(latestTemp?.skin_temp, tempUnit),
                                  unit: tempUnit.symbol,
                                  series: lastTemp?.deviation == nil ? recentTemperatures
                                      : tempNights.suffix(14).compactMap(\.deviation).map { Convert.temperatureDelta($0, tempUnit) },
                                  detail: lastTemp.map { n in
                                      n.deviation == nil ? latestLabel(date: n.date)
                                          : "vs baseline · \(Fmt.temperature(n.celsius, tempUnit)) \(tempUnit.symbol) skin"
                                  },
                                  action: { actions.vital(.temp) })
                        VitalCell(tag: "blood o₂", value: f(latestOxygen?.spo2_mean), unit: "%",
                                  series: recentOxygen,
                                  detail: latestOxygen.map { latestLabel(date: s.wakeYmd($0)) },
                                  action: { actions.vital(.oxygen) })
                    }
                }
                .obsCard()

            sectionTitle("Health", "Long term")
                // Torch build: Oura's own illness model. Otherwise the shared
                // core's baseline comparison over the same four biomarkers.
                if let radar = s.symptomRadar, radar.available {
                    IllnessCard(illness: radar).obsCard()
                }

                // Cardiovascular estimates belong together: vascular age/PWV
                // from raw PPG plus the demographic VO₂max estimate.
                if s.cardio?.vascular_age != nil || s.fitness?.vo2max != nil || !OuraCardio.readings(s).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ObsTag("cardiovascular", icon: "heart.fill")
                        if s.cardio?.vascular_age == nil {
                            OuraCardioSection(s: s)
                        }
                        if let cv = s.cardio, let va = cv.vascular_age {
                            ObsStat(label: "Vascular age", value: String(format: "%.1f yr", va))
                            if let ca = cv.chronological_age { ObsStat(label: "Vs your age", value: relAge(va - ca)) }
                            if let pwv = cv.pwv_ms { ObsStat(label: "Pulse-wave velocity", value: String(format: "%.2f m/s", pwv)) }
                            if let seg = cv.segments { ObsStat(label: "Segments analysed", value: "\(seg)") }
                        }
                        if let vo = s.fitness?.vo2max {
                            ObsStat(label: "VO₂max estimate", value: String(format: "%.1f ml/kg/min", vo))
                        }
                    }
                    .obsCard()
                }

        }
    }

    private func sectionTitle(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption.uppercased()).font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
            Text(title).font(Obs.pixel(24)).foregroundStyle(Obs.ink)
        }
        .padding(.top, 10)
    }
}

/// The ring: battery, last sync, serial and firmware, and any problems (ring clock
/// warnings, on-device model errors), with the way into sync and diagnostics.
/// Opened from the battery in every screen's header.
struct RingSheet: View {
    let s: Summary
    let onSync: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        deviceCard(s)
                // nights the shared brain withheld because the ring clock could not
                // be resolved unambiguously (missing anchor, accelerated counter, or
                // multi-reboot stall)
                if let warnings = s.clock?.warnings, !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ObsTag("ring clock", icon: "clock.badge.exclamationmark")
                        ForEach(warnings, id: \.self) { w in
                            Text("• \(w)").font(Obs.mono(13)).foregroundStyle(Obs.bad)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .obsCard()
                }

                // on-device model failures (empty unless a torch model genuinely
                // failed — a missing bundle or an inference error, not just no data)
                if !s.modelErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ObsTag("on-device models", icon: "exclamationmark.triangle")
                        ForEach(s.modelErrors, id: \.self) { e in
                            Text("• \(e)").font(Obs.mono(13)).foregroundStyle(Obs.bad)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .obsCard()
                }

                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Your ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func deviceCard(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ObsTag("your ring", icon: "circle.circle")
                Spacer()
                Button(action: onSync) {
                    Text("Sync & diagnostics ›").font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                }.buttonStyle(.plain)
            }
            ObsStat(label: "Battery",
                    value: s.device?.battery_pct.map { pct in
                        if let rec = s.device?.battery_recorded {
                            return "\(pct)% (\(rec))"
                        }
                        return "\(pct)%"
                    } ?? "–",
                    accent: (s.device?.battery_pct ?? 100) < 20 ? Obs.bad : Obs.ink)
            ObsStat(label: "Last synced",
                    value: s.device.flatMap { d in d.synced.map { "\(Fmt.day($0)) \(d.synced_hm.map { Fmt.clock($0) } ?? "")" } } ?? "–")
            ObsStat(label: "Serial", value: s.device?.serial ?? "–")
            ObsStat(label: "Firmware", value: s.device?.firmware ?? "–")
            if let raw = s.device?.raw_events ?? s.device?.total_events {
                ObsStat(label: "Events",
                        value: s.device?.decoded_events.map { "\(raw) raw · \($0) decoded" } ?? "\(raw)")
            }
            BuildStamp(prefix: s.device?.days_of_data.map { span in
                let obs = s.device?.observed_days.map { " (\($0) observed)" } ?? ""
                return "\(String(format: "%.0f", span)) days\(obs) · \(s.device?.nights ?? s.nights.count) nights"
            })
        }
        .obsCard()
    }
}
