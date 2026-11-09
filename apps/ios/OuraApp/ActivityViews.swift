import SwiftUI

// Activity tab + workout tracking UI. Data layer: Workouts.swift.

// MARK: - shared bits

/// A circular progress ring with a value in the middle and a caption below.
struct ScoreRing: View {
    let value: String
    let caption: String
    var progress: Double?          // 0…1, nil draws an empty track
    var accent: Color = Obs.sleepAccent
    var size: CGFloat = 92
    var lineWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(accent.opacity(0.16), lineWidth: lineWidth)
                if let p = progress {
                    Circle()
                        .trim(from: 0, to: max(0.001, min(1, p)))
                        .stroke(accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: p)
                }
                Text(value)
                    .font(Obs.rounded(size * 0.27, .bold))
                    .foregroundStyle(progress == nil ? Obs.muted : Obs.ink)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .padding(.horizontal, lineWidth + 4)
            }
            .frame(width: size, height: size)
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .semibold)).tracking(1)
                .foregroundStyle(Obs.ink2)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal day picker, oldest on the left, scrolled to the selection.
struct DayStrip: View {
    let days: [String]            // newest first (Summary.days order)
    @Binding var selection: String

    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(days.prefix(60).reversed()), id: \.self) { day in
                        let on = day == selection
                        let date = WorkoutFormat.day.date(from: day)
                        Button { selection = day } label: {
                            VStack(spacing: 4) {
                                Text(date.map { Self.weekday.string(from: $0).uppercased() } ?? "")
                                    .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(on ? Obs.paper : Obs.muted)
                                Text(String(day.suffix(2)))
                                    .font(Obs.rounded(17, .semibold))
                                    .foregroundStyle(on ? Obs.paper : Obs.ink)
                            }
                            .frame(width: 46, height: 56)
                            .background(on ? Obs.ink : Obs.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(day)
                        .accessibilityLabel(day)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .trailing) }
            .onChange(of: selection) { _, d in withAnimation { proxy.scrollTo(d, anchor: .center) } }
        }
    }
}

/// Screen title row shared by the tabs: large title, profile and sync buttons.
struct AppHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle.uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(1.1)
                        .foregroundStyle(Obs.muted)
                }
                Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(Obs.ink)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

// MARK: - workout rows / cards

struct WorkoutRow: View {
    let session: WorkoutSession
    var kcal: Double? = nil

    private var badge: String? {
        if session.isAuto { return "detected" }
        if session.isUser { return nil }
        return "auto"
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: session.isUser ? (WorkoutKind(rawValue: session.label)?.symbol ?? activitySymbol(session.label))
                                             : activitySymbol(session.label))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Obs.activityAccent)
                .frame(width: 44, height: 44)
                .background(Obs.activityAccent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.isUser ? (WorkoutKind(rawValue: session.label)?.title ?? actLabel(session.label))
                                        : actLabel(session.label))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Obs.ink)
                    if let badge {
                        Text(badge.uppercased())
                            .font(.system(size: 9, weight: .bold)).tracking(0.8)
                            .foregroundStyle(Obs.ink2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Obs.cardHigh, in: Capsule())
                    }
                }
                Text("\(session.startHM)–\(session.end)")
                    .font(Obs.mono(13)).foregroundStyle(Obs.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(session.durationMin) min").font(Obs.mono(15, .semibold)).foregroundStyle(Obs.ink)
                if let kcal, kcal > 0 {
                    Text("\(Int(kcal)) kcal").font(Obs.mono(12)).foregroundStyle(Obs.muted)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Obs.muted)
        }
        .contentShape(Rectangle())
    }
}

/// The workout in progress: live timer, kind, end/discard.
struct LiveWorkoutCard: View {
    let active: ActiveWorkout
    let onEnd: () -> Void
    @ObservedObject private var store = WorkoutStore.shared
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(Obs.alert).frame(width: 8, height: 8)
                Text("WORKOUT IN PROGRESS")
                    .font(.system(size: 11, weight: .bold)).tracking(1.1).foregroundStyle(Obs.activityAccent)
                Spacer()
                Menu {
                    Picker("Type", selection: Binding(get: { active.kind }, set: { store.changeActiveKind($0) })) {
                        ForEach(WorkoutKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Divider()
                    Button("Discard workout", role: .destructive) { confirmDiscard = true }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(Obs.ink2)
                }
            }
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: active.kind.symbol)
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(Obs.activityAccent)
                    .frame(width: 54, height: 54)
                    .background(Obs.activityAccent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.kind.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Obs.ink)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(WorkoutFormat.clock(context.date.timeIntervalSince(active.start)))
                            .font(Obs.rounded(34, .bold)).foregroundStyle(Obs.ink)
                            .contentTransition(.numericText())
                    }
                }
            }
            Button(action: onEnd) {
                Text("End workout")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Obs.paper)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Obs.activityAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            Text("Wear your ring. Heart rate and calories fill in after the ring syncs.")
                .font(.system(size: 12)).foregroundStyle(Obs.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .obsCard()
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { store.discardActive() }
        } message: { Text("It won't be saved.") }
    }
}

/// Start / log buttons shown when no workout is running.
struct WorkoutActions: View {
    let onStart: () -> Void
    let onLog: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Button(action: onStart) {
                Label("Start workout", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Obs.paper)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Obs.activityAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Button(action: onLog) {
                Label("Log past", systemImage: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Obs.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Obs.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - sheets

struct StartWorkoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WorkoutStore.shared
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose an activity. The timer runs until you end it, even if you leave the app.")
                        .font(.system(size: 14)).foregroundStyle(Obs.ink2)
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(WorkoutKind.allCases) { kind in
                            Button {
                                store.start(kind)
                                dismiss()
                            } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: kind.symbol)
                                        .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(Obs.activityAccent)
                                    Text(kind.title).font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Obs.ink).lineLimit(1).minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity).frame(height: 92)
                                .background(Obs.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(Obs.canvas)
            .navigationTitle("Start workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Add a workout after the fact, or edit one the wearer recorded.
struct LogWorkoutSheet: View {
    var editing: UserWorkout? = nil
    var day: String? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WorkoutStore.shared
    @State private var kind: WorkoutKind = .running
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var minutes = 30
    @State private var note = ""

    private var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
    private var valid: Bool { minutes >= 1 && end <= Date().addingTimeInterval(60) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Activity", selection: $kind) {
                        ForEach(WorkoutKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    Stepper(value: $minutes, in: 1...600, step: minutes < 10 ? 1 : 5) {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(minutes) min").foregroundStyle(Obs.ink2).monospacedDigit()
                        }
                    }
                    HStack {
                        Text("Ended")
                        Spacer()
                        Text(end.formatted(date: .omitted, time: .shortened)).foregroundStyle(Obs.ink2)
                    }
                }
                Section("Note") {
                    TextField("Optional", text: $note, axis: .vertical)
                }
                if !valid {
                    Section { Text("A workout can't end in the future.").foregroundStyle(Obs.bad) }
                }
                Section {
                    Text("Calories, steps and heart rate come from what your ring recorded during this time.")
                        .font(.footnote).foregroundStyle(Obs.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Obs.canvas)
            .navigationTitle(editing == nil ? "Log workout" : "Edit workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!valid).fontWeight(.semibold)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private func prefill() {
        if let w = editing {
            kind = w.kind; start = w.start; minutes = w.durationMin; note = w.note ?? ""
        } else if let day, let d = WorkoutFormat.day.date(from: day),
                  !Calendar.current.isDateInToday(d) {
            start = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: d) ?? start
        }
    }

    private func save() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if var w = editing {
            w.kind = kind; w.start = start; w.end = end; w.note = trimmed.isEmpty ? nil : trimmed
            store.update(w)
        } else {
            store.add(UserWorkout(kind: kind, start: start, end: end, origin: .logged,
                                  note: trimmed.isEmpty ? nil : trimmed))
        }
        dismiss()
    }
}

struct GoalsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kcal = ActivityGoals.activeKcal
    @State private var steps = ActivityGoals.steps
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $kcal, in: 100...2000, step: 50) {
                        HStack { Text("Active calories"); Spacer(); Text("\(Int(kcal)) kcal").foregroundStyle(Obs.ink2) }
                    }
                    Stepper(value: $steps, in: 1000...30000, step: 500) {
                        HStack { Text("Steps"); Spacer(); Text("\(Int(steps))").foregroundStyle(Obs.ink2) }
                    }
                } footer: {
                    Text("Steps are estimated from your ring's movement intensity, not counted step by step.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Obs.canvas)
            .navigationTitle("Daily goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        ActivityGoals.activeKcal = kcal; ActivityGoals.steps = steps
                        onSave(); dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - workout detail

struct WorkoutDetailView: View {
    let session: WorkoutSession
    let summary: Summary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = WorkoutStore.shared
    @State private var stats: WorkoutStats?
    @State private var loading = true
    @State private var editing: UserWorkout?
    @State private var confirmDelete = false

    private var interval: (Date, Date)? {
        guard let start = WorkoutFormat.dayTime.date(from: session.start) else { return nil }
        guard var end = WorkoutFormat.dayTime.date(from: "\(session.dayLabel) \(session.end)") else { return nil }
        if end <= start { end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end }
        return (start, end)
    }

    private var title: String {
        session.isUser ? (WorkoutKind(rawValue: session.label)?.title ?? actLabel(session.label)) : actLabel(session.label)
    }

    private var sourceText: String {
        if session.isUser {
            switch store.userWorkout(sessionID: session.id)?.origin {
            case .live: return "Recorded with the workout timer"
            case .confirmed: return "Detected from movement, confirmed by you"
            default: return "Logged by you"
            }
        }
        if session.isAuto { return "Detected from sustained movement (at least 3 MET for 10+ minutes)" }
        return "Detected by the activity model"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: session.isUser ? (WorkoutKind(rawValue: session.label)?.symbol ?? activitySymbol(session.label)) : activitySymbol(session.label))
                            .font(.system(size: 26, weight: .medium)).foregroundStyle(Obs.activityAccent)
                            .frame(width: 60, height: 60)
                            .background(Obs.activityAccent.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title).font(.system(size: 24, weight: .bold)).foregroundStyle(Obs.ink)
                            Text("\(session.dayLabel) · \(session.startHM)–\(session.end)")
                                .font(Obs.mono(14)).foregroundStyle(Obs.ink2)
                        }
                    }
                    Text(sourceText).font(.system(size: 13)).foregroundStyle(Obs.muted)

                    statsGrid

                    if let hr = stats?.hr, hr.series.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            ObsTag("heart rate", icon: "heart.fill")
                            WorkoutHRChart(series: hr.series).frame(height: 140)
                        }
                        .obsCard()
                    }

                    if let note = store.userWorkout(sessionID: session.id)?.note {
                        VStack(alignment: .leading, spacing: 6) {
                            ObsTag("note", icon: "text.alignleft")
                            Text(note).font(.system(size: 15)).foregroundStyle(Obs.ink)
                        }.obsCard()
                    }

                    coverageNote
                    actions
                }
                .padding(20)
            }
            .background(Obs.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $editing) { w in LogWorkoutSheet(editing: w) }
            .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.delete(sessionID: session.id); dismiss() }
            }
        }
    }

    private func load() async {
        if session.isAuto, let d = summary.detected(id: session.id), let s = d.stats {
            stats = s; loading = false; return
        }
        if let (start, end) = interval { stats = await WorkoutData.stats(start: start, end: end) }
        loading = false
    }

    @ViewBuilder private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 12) {
            StatTile(label: "Duration", value: "\(session.durationMin)", unit: "min", icon: "timer")
            StatTile(label: "Active calories", value: stats?.active_kcal.map { "\(Int($0))" }, unit: "kcal",
                     icon: "flame.fill", loading: loading)
            StatTile(label: "Avg heart rate", value: stats?.hr.map { "\(Int($0.avg))" }, unit: "bpm",
                     icon: "heart.fill", loading: loading, accent: Obs.heartAccent)
            StatTile(label: "Max heart rate", value: stats?.hr.map { "\(Int($0.max))" }, unit: "bpm",
                     icon: "bolt.heart.fill", loading: loading, accent: Obs.heartAccent)
            StatTile(label: "Steps (est.)", value: stats?.steps.map { "\(Int($0))" }, unit: "",
                     icon: "shoeprints.fill", loading: loading)
            StatTile(label: "Avg intensity", value: stats?.met_avg.map { String(format: "%.1f", $0) }, unit: "MET",
                     icon: "speedometer", loading: loading)
        }
    }

    @ViewBuilder private var coverageNote: some View {
        if !loading, let s = stats {
            if (s.covered_min ?? 0) == 0 {
                note("Your ring hasn't sent data for this time yet. Sync your ring, then open this workout again.")
            } else if s.coverage < 0.8 {
                note("The ring has sent \(s.covered_min ?? 0) of \(Int(s.duration_min ?? 0)) minutes so far. Sync again for complete numbers.")
            } else if s.hr == nil {
                note("No heart rate was recorded during this workout. The ring measures heart rate only occasionally while you move.")
            }
        } else if !loading {
            note("No ring data for this time yet.")
        }
    }

    private func note(_ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
            .font(.system(size: 13)).foregroundStyle(Obs.ink2)
    }

    @ViewBuilder private var actions: some View {
        if session.isAuto, let d = summary.detected(id: session.id) {
            VStack(spacing: 10) {
                Menu {
                    ForEach(WorkoutKind.allCases) { kind in
                        Button { store.confirm(d, as: kind); dismiss() } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Text("Save as workout…").font(.system(size: 16, weight: .semibold)).foregroundStyle(Obs.paper)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Obs.activityAccent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Button { store.delete(sessionID: session.id); dismiss() } label: {
                    Text("Not a workout").font(.system(size: 15, weight: .medium)).foregroundStyle(Obs.ink2)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
        } else if session.isUser, let w = store.userWorkout(sessionID: session.id) {
            HStack(spacing: 10) {
                Button { editing = w } label: {
                    Label("Edit", systemImage: "pencil").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Obs.ink).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Obs.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Button { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Obs.alert).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Obs.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String?
    let unit: String
    var icon: String
    var loading = false
    var accent: Color = Obs.activityAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Obs.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let value {
                    Text(value).font(Obs.rounded(26, .bold)).foregroundStyle(Obs.ink)
                    if !unit.isEmpty { Text(unit).font(.system(size: 13)).foregroundStyle(Obs.ink2) }
                } else if loading {
                    ProgressView().controlSize(.small).tint(Obs.ink2)
                } else {
                    Text("–").font(Obs.rounded(26, .bold)).foregroundStyle(Obs.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Obs.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Heart rate over a workout: `[[unix, bpm]]` points.
struct WorkoutHRChart: View {
    let series: [[Double]]
    var body: some View {
        Canvas { ctx, size in
            let pts = series.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
            guard pts.count > 1, let t0 = pts.first?.0, let t1 = pts.last?.0, t1 > t0 else { return }
            let lo = (pts.map(\.1).min() ?? 60) - 5, hi = (pts.map(\.1).max() ?? 160) + 5
            func p(_ t: Double, _ v: Double) -> CGPoint {
                CGPoint(x: size.width * CGFloat((t - t0) / (t1 - t0)),
                        y: size.height * (1 - CGFloat((v - lo) / max(1, hi - lo))))
            }
            var line = Path(); line.move(to: p(pts[0].0, pts[0].1))
            for q in pts.dropFirst() { line.addLine(to: p(q.0, q.1)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height)); area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Obs.heartAccent.opacity(0.35), Obs.heartAccent.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Obs.heartAccent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Activity tab

struct ActivityTab<Header: View>: View {
    let s: Summary
    let onEndWorkout: () -> Void
    @ViewBuilder var header: () -> Header
    @ObservedObject private var store = WorkoutStore.shared
    @State private var day: String = ""
    @State private var showStart = false
    @State private var showLog = false
    @State private var showGoals = false
    @State private var selected: WorkoutSession?
    @State private var goalsVersion = 0

    private var today: String { WorkoutFormat.day.string(from: Date()) }
    private var days: [String] {
        var d = s.days
        if !d.contains(today) { d.insert(today, at: 0) }
        return d
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header()
                DayStrip(days: days, selection: $day)
                VStack(alignment: .leading, spacing: 18) {
                    rings
                    if let active = store.active {
                        LiveWorkoutCard(active: active, onEnd: onEndWorkout)
                    } else {
                        WorkoutActions(onStart: { showStart = true }, onLog: { showLog = true })
                    }
                    workouts
                    VStack(alignment: .leading, spacing: 22) {
                        ActivityReport(s: s, day: day, showSessions: false)
                    }
                    .obsCard()
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 30)
        }
        .onAppear { if day.isEmpty { day = days.first ?? today } }
        .sheet(isPresented: $showStart) { StartWorkoutSheet() }
        .sheet(isPresented: $showLog) { LogWorkoutSheet(day: day) }
        .sheet(isPresented: $showGoals) { GoalsSheet { goalsVersion += 1 } }
        .sheet(item: $selected) { w in WorkoutDetailView(session: w, summary: s) }
    }

    private var rings: some View {
        let st = s.activity_daily[day]
        let kcal = st?.active_kcal
        let steps = st?.steps
        let mins = s.workoutsOn(day).reduce(0) { $0 + $1.durationMin }
        return VStack(spacing: 12) {
            HStack {
                ScoreRing(value: kcal.map { "\(Int($0))" } ?? "–", caption: "active kcal",
                          progress: kcal.map { $0 / ActivityGoals.activeKcal }, accent: Obs.activityAccent, size: 96)
                Spacer()
                ScoreRing(value: steps.map { $0 >= 10_000 ? String(format: "%.1fk", $0 / 1000) : "\(Int($0))" } ?? "–",
                          caption: "steps (est.)",
                          progress: steps.map { $0 / ActivityGoals.steps }, accent: Obs.readinessAccent, size: 96)
                Spacer()
                ScoreRing(value: "\(mins)", caption: "workout min",
                          progress: Double(mins) / 30, accent: Obs.heartAccent, size: 96)
            }
            Button { showGoals = true } label: {
                Text("Goals: \(Int(ActivityGoals.activeKcal)) kcal · \(Int(ActivityGoals.steps)) steps")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Obs.muted)
            }
            .buttonStyle(.plain)
            .id(goalsVersion)
        }
        .obsCard(padding: 20)
    }

    @ViewBuilder private var workouts: some View {
        let ws = s.workoutsOn(day)
        VStack(alignment: .leading, spacing: 12) {
            ObsTag("workouts", icon: "figure.run")
            if ws.isEmpty {
                Text(day == today ? "No workouts yet today. Start one above, or log one you've done."
                                  : "No workouts on this day.")
                    .font(.system(size: 14)).foregroundStyle(Obs.ink2)
            } else {
                ForEach(ws) { w in
                    Button { selected = w } label: {
                        WorkoutRow(session: w, kcal: s.detected(id: w.id)?.stats?.active_kcal)
                    }
                    .buttonStyle(.plain)
                    if w.id != ws.last?.id { Rectangle().fill(Obs.rule).frame(height: 1) }
                }
            }
        }
        .obsCard()
    }
}
