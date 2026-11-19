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
}

/// What decides whether a tab must redraw: the merged summary's version, the
/// header's status line, whether a sync or analysis is running, and the display units.
struct TabInputs: Equatable {
    var version: Int
    var busyLabel: String?
    var isBusy: Bool
    var units: String
}

/// The profile and sync buttons at the right of every screen title.
struct HeaderButtons: View {
    let actions: AppActions
    var body: some View {
        Button(action: actions.profile) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22)).foregroundStyle(Obs.ink2)
        }
        .accessibilityLabel("Profile")
        SyncIndicatorButton(ring: RingSync.shared, action: actions.sync)
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

struct TodayTab: View, Equatable, TabHelpers {
    let s: Summary
    let inputs: TabInputs
    let actions: AppActions
    @ObservedObject private var store = WorkoutStore.shared
    @State private var readinessExpanded = CommandLine.arguments.contains("-expandReadiness")

    nonisolated static func == (a: Self, b: Self) -> Bool { a.inputs == b.inputs }

    private var busyLabel: String? { inputs.busyLabel }
    private var isBusy: Bool { inputs.isBusy }

    var body: some View { TabPage { todayTab(s) } }

    private func toggleContributors() {
        withAnimation(.easeOut(duration: 0.18)) { readinessExpanded.toggle() }
    }

    private static let headerDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f
    }()
    private func todayHeader() -> String { Self.headerDate.string(from: Date()) }

    // MARK: Today

    @ViewBuilder private func todayTab(_ s: Summary) -> some View {
        AppHeader(title: "Today", subtitle: busyLabel ?? todayHeader()) { HeaderButtons(actions: actions) }
        if let err = s.error {
            ErrorCard(err: err, onConnect: actions.sync)
        } else {
            let day = s.days.first ?? localDay()
            let night = s.night(forDay: day) ?? s.nights.first
            let st = s.activity_daily[localDay()] ?? s.activity_daily[day]
            VStack(alignment: .leading, spacing: 14) {
                readinessHero(s, night: night, st: st)

                if let active = store.active {
                    LiveWorkoutCard(active: active, onEnd: actions.finishWorkout)
                }

                reviewLink(s)

                todaySignals(s, night: night)

                if let day = s.days.first {
                    HStack(spacing: 9) {
                        ObsTag(displayedDayLabel(day)).fixedSize()
                        if displayedDayLabel(day) != day {
                            Text(Fmt.day(day)).font(Obs.mono(11)).foregroundStyle(Obs.muted)
                        }
                        if isBusy {
                            ProgressView().controlSize(.mini).tint(Obs.signal)
                        }
                    }
                    .padding(.top, 10)
                    TodayCard(s: s, day: day,
                              onSleep: { actions.openReport(ReportSel(day: day, sleep: true)) },
                              onActivity: { actions.openReport(ReportSel(day: day, sleep: false)) })
                }

                if let debt = s.sleepDebt {
                    SleepDebtCard(debt: debt) { actions.sleepDebt() }.obsCard()
                }

                weekStrip(s)
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

    /// The hero panel: the readiness ring, what it means, its contributors on demand,
    /// and a footer linking to sleep, activity and sleep debt.
    @ViewBuilder private func readinessHero(_ s: Summary, night: NightRow?, st: DailyStat?) -> some View {
        let readiness = night?.readiness
        let goal = activityGoalProgress(st)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ObsTag("Readiness")
                Spacer()
                if readiness?.provisional == true {
                    Text("PROVISIONAL").font(Obs.label(10)).tracking(1.6).foregroundStyle(Obs.signal)
                }
            }
            .padding(.horizontal, 18).padding(.top, 18)

            HStack(alignment: .center, spacing: 16) {
                Button { toggleContributors() } label: {
                    ScoreRing(value: readiness.map { "\(Int($0.score))" } ?? "–", caption: "readiness",
                              progress: readiness.map { $0.score / 100 }, size: 128, lineWidth: 7, showCaption: false)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 9) {
                    if let r = readiness {
                        SignalBadge(text: readinessBand(r.score))
                        Text(readinessHeadline(r.score))
                            .font(Obs.mono(19)).foregroundStyle(Obs.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(s.digest ?? readinessSummary(r))
                            .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        Button { toggleContributors() } label: {
                            Text(readinessExpanded ? "HIDE CONTRIBUTORS" : "VIEW CONTRIBUTORS ›")
                                .font(Obs.label(11)).tracking(1.4).foregroundStyle(Obs.ink)
                                .padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(night == nil ? "Wear your ring to bed, then sync in the morning."
                                          : "Readiness appears after a few nights have been synced: it compares each night with your own baseline.")
                            .font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)

            if readinessExpanded, let r = readiness {
                VStack(alignment: .leading, spacing: 12) {
                    SleepScoreCard(score: r, framed: false)
                    if r.provisional == true {
                        Text("Readiness compares each night with your own recent nights. It becomes settled after about two weeks of synced nights.")
                            .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 18)
                .transition(.opacity)
            }

            HStack(spacing: 0) {
                heroFooter("Sleep", night?.mainSleepScore.map { "\(Int($0.score))" }) { actions.go(.sleep) }
                Rectangle().fill(Obs.rule).frame(width: 1)
                heroFooter("Activity", goal.map { "\(Int(($0 * 100).rounded()))%" }) { actions.go(.activity) }
                Rectangle().fill(Obs.rule).frame(width: 1)
                heroFooter("Sleep debt", s.sleepDebt.map { Fmt.duration(minutes: $0.debt_min) }) { actions.sleepDebt() }
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .top) { Rectangle().fill(Obs.rule).frame(height: 1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same panel as every other card: dark green fill, scanline grid, hairline border.
        .background { RoundedRectangle(cornerRadius: 4).fill(Obs.card).overlay(Scanlines()) }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Obs.rule, lineWidth: 1))
    }

    private func heroFooter(_ label: String, _ value: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased()).font(Obs.label(10)).tracking(1.4).foregroundStyle(Obs.muted)
                Text(value ?? "–").font(Obs.mono(15)).foregroundStyle(Obs.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
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
    @ViewBuilder private func todaySignals(_ s: Summary, night: NightRow?) -> some View {
        let recent = Array(s.nights.prefix(14).reversed())
        let rhrSeries = recent.compactMap(\.rhr)
        let hrvSeries = Array(s.vitals.hrv.series.suffix(14))
        let spo2Series = recent.compactMap(\.spo2_mean)
        let spo2 = night?.spo2_mean ?? s.nights.first { $0.spo2_mean != nil }?.spo2_mean
        VStack(alignment: .leading, spacing: 6) {
            Text("OVERNIGHT · VS YOUR BASELINE").font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
            Text("Today’s signals").font(Obs.pixel(24)).foregroundStyle(Obs.ink)
        }
        .padding(.top, 16)
        HStack(spacing: 8) {
            SignalTile(name: "Resting HR", index: "01",
                       value: f(night?.rhr ?? s.vitals.rhr.latest), unit: "bpm", series: rhrSeries,
                       note: s.vitals.rhr.delta_pct.map { abs($0) < 3 ? "At baseline" : String(format: "%+.0f%% vs base", $0) } ?? "Baseline building") { actions.go(.vitals) }
            SignalTile(name: "HRV", index: "02",
                       value: f(s.vitals.hrv.latest ?? night?.hrv_ms), unit: "ms", series: hrvSeries,
                       note: signedPercent(s.vitals.hrv.delta_pct) ?? "Baseline building") { actions.vital(.hrv) }
            SignalTile(name: "Blood O₂", index: "03",
                       value: f(spo2), unit: "%", series: spo2Series,
                       note: spo2.map { $0 >= 95 ? "Normal" : "Below 95%" } ?? "No reading yet") { actions.go(.vitals) }
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

    /// The last seven days as buttons showing each day's readiness.
    @ViewBuilder private func weekStrip(_ s: Summary) -> some View {
        let days = Array(s.days.prefix(7).reversed())
        if !days.isEmpty {
            HStack {
                Text("PAST 7 DAYS · READINESS").font(Obs.label(11)).tracking(1.8).foregroundStyle(Obs.muted)
                Spacer()
                Button { actions.allDays() } label: {
                    Text("ALL \(s.days.count) DAYS ›").font(Obs.label(11)).tracking(1.4).foregroundStyle(Obs.signal)
                        .padding(.vertical, 8).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    let last = day == days.last
                    let score = s.night(forDay: day)?.readiness?.score ?? s.imported_history[day]?.readiness
                    let date = WorkoutFormat.day.date(from: day)
                    Button { actions.openReport(ReportSel(day: day, sleep: true)) } label: {
                        VStack(spacing: 6) {
                            Text(date.map { $0.formatted(.dateTime.weekday(.abbreviated)).uppercased() } ?? "")
                                .font(Obs.label(10))
                            Text(String(day.suffix(2))).font(Obs.pixel(18))
                            Text(score.map { "\(Int($0))" } ?? "–").font(Obs.mono(11))
                        }
                        .foregroundStyle(last ? Obs.onSignal : Obs.ink2)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(last ? Obs.signal : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(last ? Obs.signal : Obs.rule, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Fmt.day(day)), readiness \(score.map { "\(Int($0))" } ?? "not available")")
                }
            }
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

    /// HRV relative to its baseline, mapped so baseline sits at 75%.
    private func hrvProgress(_ s: Summary) -> Double? {
        guard let v = s.vitals.hrv.latest else { return nil }
        guard let b = s.vitals.hrv.baseline, b > 0 else { return 0.75 }
        return min(1, max(0.05, 0.75 * v / b))
    }
}

// MARK: - Sleep

struct SleepTab: View, Equatable, TabHelpers {
    let s: Summary
    let inputs: TabInputs
    let actions: AppActions
    @State private var sleepDay = ""

    nonisolated static func == (a: Self, b: Self) -> Bool { a.inputs == b.inputs }

    private var busyLabel: String? { inputs.busyLabel }

    var body: some View { TabPage { sleepTab(s) } }

    @ViewBuilder private func sleepTab(_ s: Summary) -> some View {
        AppHeader(title: "Sleep", subtitle: busyLabel) { HeaderButtons(actions: actions) }
        let nightDays = s.days.filter { s.night(forDay: $0) != nil }
        if let err = s.error {
            ErrorCard(err: err, onConnect: actions.sync)
        } else if nightDays.isEmpty {
            Text("No nights yet. Wear your ring to bed, then sync in the morning.")
                .font(Obs.mono(15)).foregroundStyle(Obs.ink2)
                .obsCard().padding(.horizontal, 20)
        } else {
            let day = nightDays.contains(sleepDay) ? sleepDay : nightDays[0]
            VStack(alignment: .leading, spacing: 18) {
                if let n = s.night(forDay: day) {
                    sleepHero(n)
                }
                VStack(alignment: .leading, spacing: 26) {
                    SleepReport(s: s, day: day)
                }
                .padding(.top, 4)
                if let debt = s.sleepDebt {
                    SleepDebtCard(debt: debt) { actions.sleepDebt() }.obsCard()
                }
                // Night picker at the end of the page, inside the card margins, as on Today.
                DayStrip(days: nightDays, selection: Binding(get: { day }, set: { sleepDay = $0 }),
                         title: "Nights · sleep score") { d in
                    s.night(forDay: d)?.mainSleepScore.map { "\(Int($0.score))" }
                }
                .padding(.top, 8)
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

struct VitalsTab: View, Equatable, TabHelpers {
    let s: Summary
    let inputs: TabInputs
    let actions: AppActions
    @ObservedObject private var units = UnitSettings.shared

    nonisolated static func == (a: Self, b: Self) -> Bool { a.inputs == b.inputs }

    private var busyLabel: String? { inputs.busyLabel }

    var body: some View { TabPage { vitalsTab(s) } }

    // MARK: Vitals

    @ViewBuilder private func vitalsTab(_ s: Summary) -> some View {
        let latestTemp = s.nights.first { $0.skin_temp != nil }
        let latestOxygen = s.nights.first { $0.spo2_mean != nil }
        let tempUnit = units.temperature
        let recentTemperatures = Array(s.nights.compactMap(\.skin_temp).prefix(14).reversed())
            .map { Convert.temperature($0, tempUnit) }
        let recentOxygen = Array(s.nights.compactMap(\.spo2_mean).prefix(14).reversed())
        let latestHR = s.vitals.hr
        AppHeader(title: "Vitals", subtitle: busyLabel) { HeaderButtons(actions: actions) }
        if let err = s.error {
            ErrorCard(err: err, onConnect: actions.sync)
        } else {
            VStack(alignment: .leading, spacing: 18) {
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

                HourlyHeartRateSection()

                // Torch build: Oura's own illness model. Otherwise the shared
                // core's baseline comparison over the same four biomarkers.
                if let radar = s.symptomRadar, radar.available {
                    IllnessCard(illness: radar).obsCard()
                }

                // Cardiovascular estimates belong together: vascular age/PWV
                // from raw PPG plus the demographic VO₂max estimate.
                if s.cardio?.vascular_age != nil || s.fitness?.vo2max != nil {
                    VStack(alignment: .leading, spacing: 12) {
                        ObsTag("cardiovascular", icon: "heart.fill")
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

                deviceCard(s)
            }
            .padding(.horizontal, 20)
        }
    }

    private func deviceCard(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ObsTag("your ring", icon: "circle.circle")
                Spacer()
                Button { actions.sync() } label: {
                    Text("Manage").font(Obs.mono(13)).foregroundStyle(Obs.ink2)
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
