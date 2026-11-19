import SwiftUI
import UniformTypeIdentifiers

// The SwiftUI screens for OuraApp. Data types live in Models.swift, the model/FFI
// orchestration in Core.swift, the reusable charts/cells in Components.swift, and the
// full-page sleep/activity reports in Reports.swift.
// SIBLING CLIENT: the web dashboard (dashboard/web/app.js) renders the SAME summary
// JSON — a user-facing change here usually belongs there too (docs/clients-web-and-ios.md).

// The home's unified "today": last night's sleep and that day's activity as ONE unit,
// each region tappable to open its own detail (sleep → SleepDetail, activity →
// ActivityDetail). Mirrors the web dashboard's day card. Previous days live behind
// "show all days" (AllDaysView → DayDetailView, which shows the same pairing).
struct TodayCard: View {
    let s: Summary
    let day: String
    let onSleep: () -> Void
    let onActivity: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // night — tap for the hypnogram + breakdown + that night's vitals
            if let n = s.night(forDay: day) {
                Button(action: onSleep) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            ObsTag("sleep", icon: "moon.fill")
                            Spacer()
                            // Time asleep, not time in bed.
                            Text("\(Fmt.duration(seconds: asleepSeconds(n) ?? n.durationS)) asleep")
                                .font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                        }
                        Text("\(Fmt.clock(n.start)) → \(Fmt.clock(n.end))")
                            .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                        if n.hasHypnogram { Hypnogram(stages: n.hypnogram!, height: 28) }
                        else if let e = n.efficiency {
                            Text("Efficiency \(Int(e))%").font(Obs.mono(12))
                                .foregroundStyle(e >= 85 ? Obs.good : (e < 75 ? Obs.bad : Obs.ink2))
                        }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)

                Rectangle().fill(Obs.trace.opacity(0.4)).frame(height: 0.5)
                    .padding(.vertical, 16)
            }

            // activity — tap for the movement ridge + steps/kcal + this day's workouts
            Button(action: onActivity) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ObsTag("activity", icon: "figure.walk")
                        Spacer()
                        if let st = s.activity_daily[day] {
                            Text("\(Fmt.count(st.steps ?? 0)) steps").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                            Text("· \(Fmt.count(st.active_kcal ?? 0)) kcal").font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
                    }
                    MovementRidge(profile: s.activity_profile[day] ?? [])
                    ForEach(Array(s.workoutsOn(day).prefix(2))) { w in
                        SessionRow(label: w.label, durationMin: w.durationMin, startHM: w.startHM)
                    }
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .obsCard()
    }
}

// "show all days" → a page listing every day; tap one for its full report.
struct AllDaysView: View {
    let s: Summary
    @Environment(\.dayAnalysis) private var analysis
    @Environment(\.dismiss) private var dismiss

    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let month: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
    private static let number: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()

    /// Days grouped by month, newest first, keeping the summary's own order.
    private func groups(_ days: [String]) -> [(title: String, days: [String])] {
        var out: [(String, [String])] = []
        for day in days {
            let title = Self.ymd.date(from: day).map { Self.month.string(from: $0) } ?? "Undated"
            if let last = out.last, last.0 == title { out[out.count - 1].1.append(day) }
            else { out.append((title, [day])) }
        }
        return out.map { (title: $0.0, days: $0.1) }
    }

    var body: some View {
        let s = analysis?.summary ?? s
        NavigationStack {
            ZStack {
                Obs.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups(s.allBrowsableDays), id: \.title) { group in
                            Text(group.title.uppercased()).font(Obs.mono(10, .medium)).tracking(1.4)
                                .foregroundStyle(Obs.muted)
                                .padding(.top, 22).padding(.bottom, 8)
                            ForEach(group.days, id: \.self) { day in
                                if s.days.contains(day) {
                                    NavigationLink { DayReportView(s: s, day: day, tab: .sleep) } label: { row(s, day) }
                                        .buttonStyle(.plain)
                                } else if let entry = s.imported_history[day] {
                                    NavigationLink { ImportedDayView(day: day, entry: entry) } label: { importedRow(day, entry) }
                                        .buttonStyle(.plain)
                                }
                                if day != group.days.last { Rectangle().fill(Obs.rule).frame(height: 1) }
                            }
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            .navigationTitle("All days")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    /// A day from an imported Oura export: Oura's own daily figures, no ring detail.
    @ViewBuilder private func importedRow(_ day: String, _ e: ImportedDay) -> some View {
        let date = Self.ymd.date(from: day)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(date.map { Self.weekday.string(from: $0).uppercased() } ?? "")
                    .font(Obs.mono(9)).tracking(0.8).foregroundStyle(Obs.muted)
                Text(String(day.suffix(2))).font(Obs.mono(17, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
            }
            .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Fmt.duration(seconds: e.asleep_s))
                        .font(Obs.mono(12, .medium)).foregroundStyle(e.asleep_s == nil ? Obs.muted : Obs.ink)
                    if let steps = e.steps {
                        Text("·").foregroundStyle(Obs.trace)
                        Text("\(Fmt.count(steps)) steps").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                    }
                }
                Text("From your Oura history").font(Obs.mono(10)).foregroundStyle(Obs.muted)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                dayScore(e.readiness, label: "Ready", color: Obs.readinessAccent)
                dayScore(e.sleep_score, label: "Sleep", color: Obs.sleepAccent)
            }
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// A day's score with a tiny caption, or a dash when there isn't one.
    private func dayScore(_ value: Double?, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value.map { "\(Int($0))" } ?? "–")
                .font(Obs.mono(15, .semibold)).foregroundStyle(value == nil ? Obs.muted : color)
            Text(label.uppercased()).font(Obs.label(8)).tracking(0.6)
                .foregroundStyle(Obs.muted)
        }
        .frame(minWidth: 34)
    }

    @ViewBuilder private func row(_ s: Summary, _ day: String) -> some View {
        let date = Self.ymd.date(from: day)
        let night = s.night(forDay: day)
        let stat = s.activity_daily[day]
        HStack(spacing: 12) {
            // weekday over day-of-month, a fixed column so the rows line up
            VStack(alignment: .leading, spacing: 1) {
                Text(date.map { Self.weekday.string(from: $0).uppercased() } ?? "")
                    .font(Obs.mono(9)).tracking(0.8).foregroundStyle(Obs.muted)
                Text(String(day.suffix(2))).font(Obs.mono(17, .medium)).foregroundStyle(Obs.ink).monospacedDigit()
            }
            .frame(width: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(night.map { Fmt.duration(seconds: $0.durationS) } ?? "–")
                        .font(Obs.mono(12, .medium)).foregroundStyle(night == nil ? Obs.muted : Obs.ink)
                    if let st = stat, let steps = st.steps {
                        Text("·").foregroundStyle(Obs.trace)
                        Text("\(Self.number.string(from: NSNumber(value: Int(steps))) ?? "0") steps")
                            .font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                    }
                    if let st = stat, let kcal = st.active_kcal, kcal > 0 {
                        Text("·").foregroundStyle(Obs.trace)
                        Text("\(Fmt.count(kcal)) kcal").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                    }
                }
                if let n = night, n.hasHypnogram {
                    Hypnogram(stages: n.hypnogram!, height: 12)
                } else if let n = night, let start = n.start, let end = n.end {
                    Text("\(Fmt.clock(start)) → \(Fmt.clock(end))").font(Obs.mono(10)).foregroundStyle(Obs.muted)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                dayScore(night?.readiness?.score ?? s.imported_history[day]?.readiness,
                         label: "Ready", color: Obs.readinessAccent)
                dayScore(night?.mainSleepScore?.score ?? s.imported_history[day]?.sleep_score,
                         label: "Sleep", color: Obs.sleepAccent)
            }
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Obs.trace)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

// Pair + sync from a real ring: paste the auth key (exported on the desktop), connect
// over BLE, drain history into the writable DB. BLE only works on a physical device.
struct SyncView: View {
    @ObservedObject var ring: RingSync
    let onSynced: (SyncReport) -> Void
    let onReset: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = Keychain.loadKey() ?? ""
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var diagnosticFile: URL?
    @State private var showKey = false
    @State private var clockReport: String?
    @State private var confirmReset = false
    @State private var confirmWipeRing = false
    @State private var showRestorePicker = false
    @State private var restoreNote: String?
    @FocusState private var keyFocused: Bool

    /// Validate the chosen file before it replaces anything: a truncated download or
    /// the wrong file entirely must not destroy a working database.
    private func restore(from result: Result<[URL], Error>) -> String {
        guard case .success(let urls) = result, let picked = urls.first else { return "Restore cancelled." }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-candidate.db")
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.copyItem(at: picked, to: staging)
        } catch { return "Could not read that file: \(error.localizedDescription)" }

        do {
            let verdict = try databaseIntegrity(dbPath: staging.path)
            guard verdict.lowercased().contains("ok") else {
                return "That file is not a healthy database (\(verdict)). Nothing changed."
            }
        } catch { return "That file is not an Open Oura backup. Nothing changed." }

        do {
            try DB.resetWritableStore()
            try FileManager.default.copyItem(at: staging, to: DB.url)
            try? FileManager.default.removeItem(at: staging)
        } catch { return "Restore failed midway: \(error.localizedDescription)" }
        return "Restored. The next sync continues from where the backup left off."
    }

    private var validKey: Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf8.count == 32 && trimmed.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if ring.connectionIssue != nil { syncStatus }
                    else { preparation }
                    if !ring.busy { pairingKey }
                    connection
                    support
                    BuildStamp()
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Obs.paper)
            .navigationTitle("Your ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Obs.ink)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { keyFocused = false }
                }
            }
            .alert("Reset local sync data?", isPresented: $confirmReset) {
                Button("Cancel", role: .cancel) {}
                Button("Reset local data", role: .destructive) {
                    Task { if await ring.resetLocalDatabase() { onReset() } }
                }
            } message: {
                Text("This removes the synced data on this iPhone. Your next sync will download the history still available on your ring.")
            }
            .alert("Factory-reset \(ring.knownSerial ?? "the ring")?", isPresented: $confirmWipeRing) {
                Button("Cancel", role: .cancel) {}
                Button("Erase the ring", role: .destructive) {
                    let serial = ring.knownSerial ?? ""
                    let current = key
                    Task {
                        if await ring.factoryReset(keyHex: current, confirmSerial: serial) {
                            key = ""
                            showKey = false
                        }
                    }
                }
            } message: {
                Text("Erases the ring's pairing key, its Bluetooth bonds, any events it hasn't sent yet, and your stored body profile. Sync first if you want those events. This cannot be undone — but the ring stays yours: pair it again right here afterwards.")
            }
        }
        .tint(Obs.ink)
        // Sync belongs to RingSync and continues when this panel is dismissed.
        .sheet(isPresented: Binding(get: { diagnosticFile != nil }, set: { if !$0 { diagnosticFile = nil } })) {
            if let diagnosticFile { DiagnosticsShare(url: diagnosticFile) }
        }
        .fileImporter(isPresented: $showRestorePicker,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            restoreNote = restore(from: result)
            if restoreNote?.hasPrefix("Restored") == true { onReset() }
        }
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        Text("Pair your ring")
            .font(Obs.serif(28))
            .foregroundStyle(Obs.ink)
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupRow(icon: "bolt", title: "Put the ring on its charger, next to this iPhone", detail: nil)
            setupRow(icon: "antenna.radiowaves.left.and.right", title: "Free the Bluetooth link",
                     detail: "Turn Bluetooth off on other phones running the Oura app.")
        }
    }

    private func setupRow(icon: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Obs.muted)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Obs.mono(15)).foregroundStyle(Obs.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var pairingKey: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if showKey { TextField("Paste your pairing key", text: $key) }
                    else { SecureField("Paste your pairing key", text: $key) }
                }
                .font(.system(.subheadline, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($keyFocused)
                .accessibilityLabel("Pairing key")
                .disabled(ring.busy)
                Button { showKey.toggle() } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(showKey ? "Hide pairing key" : "Show pairing key")
            }
            .foregroundStyle(Obs.ink)
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Obs.rule.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(keyFocused ? Obs.muted : Obs.rule))
            if !key.isEmpty && !validKey {
                Text("Use all 32 characters: numbers 0–9 and letters A–F.")
                    .font(Obs.mono(13))
                    .foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            pairReset
        }
    }

    /// Adopt a factory-reset ring without a computer: mint the key on this iPhone.
    private var pairReset: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                keyFocused = false
                Task { if let minted = await ring.pair() { key = minted } }
            } label: {
                (Text("No key? ").foregroundStyle(Obs.ink2)
                 + Text("Pair a factory-reset ring").foregroundStyle(Obs.ink).underline())
                    .font(Obs.mono(13))
            }
            .buttonStyle(.plain)
            .disabled(ring.busy)
            Text("Write the new key down: it cannot be read back from the ring.")
                .font(Obs.mono(13))
                .foregroundStyle(Obs.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        if ring.busy || !ring.status.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if ring.busy {
                    ProgressView().tint(Obs.ink).frame(width: 24, height: 24)
                } else {
                    Image(systemName: ring.lastReport != nil ? "checkmark.circle" : "info.circle")
                        .font(Obs.mono(20))
                        .foregroundStyle(ring.lastReport != nil ? Obs.good : Obs.ink2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(ring.busy ? "Sync in progress" : (ring.connectionIssue ?? (ring.lastReport != nil ? "Your ring is up to date" : "Sync status")))
                        .font(Obs.mono(15)).foregroundStyle(Obs.ink)
                    Text(ring.status)
                        .font(Obs.mono(15)).foregroundStyle(Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if ring.busy {
                        Text("Keep the app open. If the connection drops, sync resumes automatically.")
                            .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if ring.connectionIssue == nil { syncStatus }
            if ring.busy {
                Button { ring.pause() } label: {
                    Label("Pause sync", systemImage: "pause")
                        .font(Obs.mono(16))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(Obs.ink)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Obs.rule))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    keyFocused = false
                    Task {
                        if let report = await ring.run(keyHex: key) { onSynced(report) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("Connect & sync")
                        Image(systemName: "arrow.right")
                    }
                    .font(Obs.mono(16))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(validKey ? Obs.paper : Obs.muted)
                    .background(validKey ? Obs.ink : Obs.rule, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!validKey)
                Text("Your first sync may take a few minutes.")
                    .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // Help & diagnostics: one quiet card of grouped rows instead of nested disclosures.
    // Everyday actions first, the technical transcript one tap deeper, destructive last.
    private var support: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Help & diagnostics")
                    .font(Obs.mono(15)).foregroundStyle(Obs.ink)
                Spacer()
                Text(appVersion).font(Obs.mono(11)).foregroundStyle(Obs.muted)
            }
            VStack(spacing: 0) {
                SupportRow(icon: "arrow.down.doc", title: "Export data",
                           detail: ring.exportStatus ?? "One file with every synced event",
                           disabled: ring.busy || ring.exportStatus != nil) {
                    Task { if let url = await ring.exportRawDatabase() { diagnosticFile = url } }
                }
                SupportDivider()
                NavigationLink {
                    ResearchExportView()
                } label: {
                    SupportRowLabel(icon: "tablecells", title: "Research export",
                                    detail: "Every heart beat and movement as CSV", trailing: "chevron.right")
                }
                .buttonStyle(.plain)
                SupportDivider()
                SupportRow(icon: "arrow.up.doc", title: "Restore from a backup",
                           detail: restoreNote ?? "Replaces what this iPhone holds",
                           disabled: ring.busy) { showRestorePicker = true }
                SupportDivider()
                NavigationLink {
                    RawDataView()
                } label: {
                    SupportRowLabel(icon: "waveform.path.ecg", title: "Raw data & charts",
                                    detail: "Every event the ring sent", trailing: "chevron.right")
                }
                .buttonStyle(.plain)
                SupportDivider()
                NavigationLink {
                    TechnicalReportsView(clockReport: $clockReport,
                                         checkDisabled: ring.busy,
                                         onCheck: { Task { await ring.checkDatabase() } },
                                         onShare: {
                                             Task {
                                                 let url = await Task.detached { DiagStore.shared.exportFile() }.value
                                                 if let url { diagnosticFile = url }
                                             }
                                         })
                } label: {
                    SupportRowLabel(icon: "doc.text.magnifyingglass", title: "Technical reports",
                                    detail: technicalSummary, trailing: "chevron.right")
                }
                .buttonStyle(.plain)
            }
            .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 0) {
                SupportRow(icon: "trash", title: "Reset local sync data",
                           detail: "The next sync fetches it again",
                           tint: Obs.alert, disabled: ring.busy) { confirmReset = true }
                SupportDivider()
                SupportRow(icon: "exclamationmark.triangle", title: "Factory-reset the ring",
                           detail: ring.knownSerial == nil
                               ? "Available after the first sync"
                               : "Wipes the ring. Pair it again afterwards",
                           tint: Obs.alert,
                           disabled: ring.busy || ring.knownSerial == nil || !validKey) { confirmWipeRing = true }
            }
            .background(Obs.alert.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Obs.alert.opacity(0.18)))
        }
    }

    private var appVersion: String {
        // The plain swiftc simulator build ships Info.plist with unexpanded $(…) values.
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        guard !short.isEmpty, !short.contains("$(") else { return "" }
        return build.isEmpty || build.contains("$(") ? "v\(short)" : "v\(short) (\(build))"
    }

    private var technicalSummary: String {
        var parts: [String] = []
        if !store.incidents.isEmpty { parts.append("\(store.incidents.count) incidents") }
        if !store.sessions.isEmpty { parts.append("\(store.sessions.count) sessions") }
        if diag.totalLines > 0 { parts.append("\(diag.totalLines) log lines") }
        return parts.isEmpty ? "Ring clock, incidents and the live log" : parts.joined(separator: " · ")
    }
}

/// One tappable row of the Help & diagnostics card.
private struct SupportRow: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Obs.ink
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            SupportRowLabel(icon: icon, title: title, detail: detail, tint: tint, trailing: nil)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct SupportRowLabel: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Obs.ink
    let trailing: String?
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint == Obs.ink ? Obs.ink2 : tint)
                .frame(width: 32, height: 32)
                .background(Obs.paper.opacity(0.85), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Obs.mono(15)).foregroundStyle(tint)
                Text(detail).font(Obs.mono(13)).foregroundStyle(Obs.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 12, weight: .semibold)).foregroundStyle(Obs.trace)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

private struct SupportDivider: View {
    var body: some View { Rectangle().fill(Obs.rule).frame(height: 0.6).padding(.leading, 60) }
}

/// The technical transcript on its own page: ring clock anchors, recorded incidents,
/// previous sessions and the live log, each with a copy action.
private struct TechnicalReportsView: View {
    @Binding var clockReport: String?
    var checkDisabled: Bool = false
    var onCheck: () -> Void = {}
    var onShare: () -> Void = {}
    @ObservedObject private var diag = RingDiag.shared
    @ObservedObject private var store = DiagStore.shared
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Button { onShare() } label: {
                        Label("Share report", systemImage: "square.and.arrow.up")
                            .font(Obs.mono(15))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Obs.rule))
                    }
                    Button { onCheck() } label: {
                        Label("Check data", systemImage: "externaldrive")
                            .font(Obs.mono(15))
                            .lineLimit(1).minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Obs.rule))
                    }
                    .disabled(checkDisabled)
                }
                .buttonStyle(.plain).foregroundStyle(Obs.ink)
                section("Ring clock", copy: clockReport) {
                    Text(clockReport ?? "No summary rendered yet.")
                        .font(.caption.monospaced()).foregroundStyle(clockReport == nil ? Obs.muted : Obs.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                section("Incidents · \(store.incidents.count)", copy: nil) {
                    if store.incidents.isEmpty {
                        Text("No incidents recorded.").font(Obs.mono(12)).foregroundStyle(Obs.muted)
                    }
                    ForEach(store.incidents.prefix(8)) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(item.title).font(Obs.mono(12)).foregroundStyle(Obs.ink)
                                Spacer()
                                Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(Obs.mono(11)).foregroundStyle(Obs.muted)
                            }
                            Text(item.preview).font(.caption.monospaced()).foregroundStyle(Obs.ink2)
                                .lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                            copyButton("incident-\(item.id)", text: item.body)
                        }
                        .padding(10)
                        .background(Obs.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !store.sessions.isEmpty {
                    section("Previous sessions · \(store.sessions.count)", copy: nil) {
                        ForEach(store.sessions.prefix(4)) { item in
                            HStack {
                                Text(item.title).font(Obs.mono(11)).foregroundStyle(Obs.ink2)
                                Spacer()
                                copyButton("session-\(item.id)", text: item.body)
                            }
                        }
                    }
                }
                section("Current session · \(diag.totalLines) lines", copy: nil) {
                    HStack {
                        Spacer()
                        Button(copied == "summary" ? "Copied" : "Copy summary") {
                            Task {
                                let text = await Task.detached { DiagStore.shared.exportSummary() }.value
                                UIPasteboard.general.string = text
                                flash("summary")
                            }
                        }
                        .font(Obs.mono(12)).foregroundStyle(Obs.ink).frame(minHeight: 32)
                    }
                    if diag.totalLines > 0 {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(diag.tail.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(Obs.mono(9)).foregroundStyle(Obs.ink2)
                                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .defaultScrollAnchor(.bottom)
                        .frame(maxHeight: 260)
                        .background(Obs.paper.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("Nothing logged yet.").font(Obs.mono(12)).foregroundStyle(Obs.muted)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Obs.paper)
        .navigationTitle("Technical reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { if clockReport == nil { clockReport = await Task.detached { ClockReport.text() }.value } }
    }

    private func section<Content: View>(_ title: String, copy: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(Obs.mono(10, .medium)).foregroundStyle(Obs.muted).tracking(0.8)
                Spacer()
                if let copy { copyButton(title, text: copy) }
            }
            content()
        }
        .padding(14)
        .background(Obs.rule.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
    }

    private func copyButton(_ id: String, text: String) -> some View {
        Button(copied == id ? "Copied" : "Copy") {
            UIPasteboard.general.string = text
            flash(id)
        }
        .font(Obs.mono(12)).foregroundStyle(Obs.ink).frame(minHeight: 32)
    }

    private func flash(_ id: String) {
        copied = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == id { copied = nil } }
    }
}

/// Human-readable rendering of the shared brain's `clock` block (per-boot ring clock
/// anchors), from the last rendered summary. Shown in Technical reports and appended
/// to the shared diagnostic report so a misdated night can be diagnosed remotely.
enum ClockReport {
    static func text() -> String? {
        guard let clock = SummaryCache.load()?.clock else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm"; fmt.timeZone = .current
        let day = { (unix: Int64?) -> String in unix.map { fmt.string(from: Date(timeIntervalSince1970: Double($0))) } ?? "–" }
        var lines: [String] = []
        for (i, e) in clock.epochs.enumerated() {
            let sources = (e.anchor_sources ?? []).joined(separator: ",")
            lines.append("boot \(i + 1): ds \(e.min_ds ?? 0)…\(e.max_ds ?? 0) (\(e.span_h ?? 0)h) synced \(day(e.capture_min))…\(day(e.capture_max)) anchors=\(e.anchors ?? 0)\(sources.isEmpty ? "" : " [\(sources)]") latest=\(day(e.latest_anchor_unix))")
        }
        for n in clock.undated_nights {
            lines.append("undated night: ds \(n.start_ds ?? 0)…\(n.end_ds ?? 0) \(n.in_bed_h ?? 0)h captured \(day(n.captured_unix)) (\(n.source ?? "?"))")
        }
        lines.append(contentsOf: clock.warnings.map { "warning: \($0)" })
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

struct DiagnosticsShare: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The top-bar sync affordance doubles as a live status light and the entry point
/// to diagnostics. Motion stays quiet: one slow continuous turn only while BLE is
/// active.
struct SyncIndicatorButton: View {
    @ObservedObject var ring: RingSync
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Obs.rule, lineWidth: 0.8)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ring.busy ? Obs.ink : (ring.wasRecentlySynced ? Obs.good : Obs.ink2))
                    .rotationEffect(.degrees(rotation))
            }
            .frame(width: 31, height: 31)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ring.busy ? "Ring sync in progress" : "Ring sync and diagnostics")
        .accessibilityHint("Opens sync status, logs, and manual controls")
        .onAppear(perform: updateAnimation)
        .onChange(of: ring.busy) { _, _ in updateAnimation() }
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        if ring.busy && !reduceMotion {
            rotation = 0
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { rotation = 0 }
        }
    }
}

// ── root ─────────────────────────────────────────────────────────────────────
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var stored: Summary? = SummaryCache.load()
    /// `stored` with the wearer's workouts merged in, made once per change rather
    /// than on every redraw; `dataVersion` counts the changes so screens can tell
    /// whether they need to redraw.
    @State private var merged: Summary?
    @State private var dataVersion = 0
    /// The current summary. Setting it re-merges the workouts.
    private var s: Summary? {
        get { stored }
        nonmutating set {
            stored = newValue
            remerge(newValue)
        }
    }
    @discardableResult
    private func remerge(_ base: Summary?) -> Summary? {
        let m = base?.withUserWorkouts(workouts)
        merged = m
        dataVersion &+= 1
        return m
    }
    /// What the screens show: the merged summary (or, before the first merge, a fresh one).
    private var shown: Summary? { merged ?? stored?.withUserWorkouts(workouts) }
    @State private var report: ReportSel?
    /// QA hooks for `simctl launch … -openSync` / `-openDay YYYY-MM-DD [activity]`, so
    /// a screen can be captured without driving the UI. Ignored in normal launches.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        if args.contains("-openSync") { showSync = true }
        if args.contains("-openAllDays") { showAllDays = true }
        if args.contains("-openProfile") { showProfile = true }
        if let index = args.firstIndex(of: "-tab"), index + 1 < args.count {
            switch args[index + 1] {
            case "sleep": tab = .sleep
            case "activity": tab = .activity
            case "vitals": tab = .vitals
            case "trends": tab = .trends
            default: tab = .today
            }
        }
        if args.contains("-logWorkout") { showLogWorkout = true }
        if let index = args.firstIndex(of: "-openDay"), index + 1 < args.count {
            report = ReportSel(day: args[index + 1], sleep: !args.contains("activity"))
        }
    }
    @State private var showAllDays = false
    @State private var showSync = false
    @State private var showProfile = false
    @State private var showSleepDebt = false
    @State private var vital: VitalKind?
    @State private var loadGeneration = 0
    @State private var isRefreshingSummary = false
    @State private var automaticSyncRequested = false
    @State private var reloadPending = false
    @ObservedObject private var ring = RingSync.shared
    @StateObject private var modelProgress = ModelProgress()
    @ObservedObject private var workouts = WorkoutStore.shared
    /// Redraws every screen when a display unit changes.
    @ObservedObject private var units = UnitSettings.shared
    @State private var tab: AppTab = .today
    @State private var showStartWorkout = false
    @State private var showLogWorkout = false
    @State private var showLogMenu = false
    @State private var pendingLog: LogChoice?
    var body: some View {
        ZStack {
            // Each tab draws the backdrop (with the rain) itself; only the loading
            // screen needs one here.
            Obs.paper.ignoresSafeArea()
            if let s = shown {
                content(s)
            } else {
                Obs.canvas
                VStack(spacing: 14) {
                    ProgressView().tint(Obs.ink)
                    Text("Loading your data…").font(Obs.mono(12)).foregroundStyle(Obs.ink2)
                }
            }
        }
        .preferredColorScheme(.dark)
        // Everything without its own font (form rows, buttons, sheets) uses the terminal monospace.
        .font(Obs.mono(15))
        .fullScreenCover(item: $report) { sel in if let s = shown { DayReportView(s: s, day: sel.day, tab: sel.sleep ? .sleep : .activity) } }
        .sheet(isPresented: $showAllDays) { if let s = shown { AllDaysView(s: s) } }
        .sheet(isPresented: $showStartWorkout) { StartWorkoutSheet() }
        .sheet(isPresented: $showLogWorkout) { LogWorkoutSheet() }
        .sheet(isPresented: $showLogMenu, onDismiss: openPendingLog) {
            LogMenuSheet(lastSync: ring.lastSuccessfulSyncAt.map { "Last synced " + $0.formatted(date: .omitted, time: .shortened) }) { choice in
                pendingLog = choice
                showLogMenu = false
            }
        }
        .onChange(of: workouts.workouts) { _, _ in
            if let m = remerge(stored), m.error == nil { HealthExport.shared.push(m) }
        }
        .onChange(of: workouts.dismissed) { _, _ in remerge(stored) }
        .onAppear { if merged == nil, stored != nil { remerge(stored) } }
        .onAppear(perform: applyLaunchArguments)
        .sheet(isPresented: $showSync) {
            SyncView(ring: ring, onSynced: refreshAfterSync, onReset: resetAndReload)
        }
        .sheet(isPresented: $showProfile) { ProfileSettingsView(profile: s?.profile, ouraImport: s?.oura_import, onSaved: refreshDerivedData) }
        .sheet(isPresented: $showSleepDebt) { if let debt = s?.sleepDebt { SleepDebtDetail(debt: debt) } }
        .sheet(item: $vital) { kind in if let s { VitalTrendView(s: s, kind: kind) } }
        #if TORCH
        .environment(\.dayAnalysis, DayAnalysisContext(summary: s,
            isBusy: isRefreshingSummary || ring.busy, refresh: refreshDayAnalysis))
        #endif
        .onAppear {
            // A cached summary makes launch immediate; this forced load replaces it
            // with SQLite + model output without blanking the existing Today card.
            requestAutomaticSync()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            requestAutomaticSync()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Keychain.migrateAccessibilityIfNeeded()
                requestAutomaticSync()
            } else if phase == .background {
                WorkCoordinator.shared.invalidateAnalysis()
                BackgroundSync.schedule()
            }
        }
    }

    // re-read the DB after a sync brought in new events
    private func reload() {
        load(force: true, clearCurrent: true)
    }

    private func resetAndReload() {
        SummaryCache.clear()
        #if TORCH
        ModelCacheStore.clearAll()
        #endif
        reload()
    }

    /// Profile changes affect CVA and activity inference, but do not invalidate the
    /// summary already on screen. Keep the last complete result visible until every
    /// derived model has finished, avoiding a transient sleep-debt regression.
    private func refreshDerivedData() {
        load(force: true, clearCurrent: false)
    }

    /// New ring events invalidate every derived view. In particular this reruns AAD
    /// after the database transaction has completed, so newly accumulated movement
    /// cannot leave yesterday's activity sessions cached on screen.
    private func refreshAfterSync(_ report: SyncReport) {
        guard report.inserted > 0 else { return }
        load(force: true, clearCurrent: false)
    }

    private func requestAutomaticSync() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !automaticSyncRequested else { return }
        automaticSyncRequested = true
        Task {
            defer { automaticSyncRequested = false }
            _ = await ring.syncAutomaticallyIfNeeded()
            if WorkCoordinator.shared.available { load(force: true, clearCurrent: false) }
        }
    }

    #if TORCH
    @MainActor private func refreshDayAnalysis(_ request: DayAnalysisRequest) async -> String? {
        guard !isRefreshingSummary, !ring.busy, let previous = s else {
            return "Wait for sync and analysis to finish, then try again."
        }
        guard WorkCoordinator.shared.available else { return "Keep the app open to refresh analysis." }
        let run = WorkCoordinator.shared.newAnalysis()
        loadGeneration += 1
        let generation = loadGeneration
        isRefreshingSummary = true
        defer {
            if reloadPending {
                reloadPending = false
                load(force: true, clearCurrent: false)
            }
        }
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        await WorkGate.shared.acquire()
        guard !run.isCancelled, WorkCoordinator.shared.available else {
            await WorkGate.shared.release()
            WorkCoordinator.shared.finishAnalysis(run)
            if generation == loadGeneration { isRefreshingSummary = false }
            return "Refresh paused. Keep the app open and try again."
        }
        IdleTimerLock.acquire("models")
        dlog("models", "refresh start day=\(request.day) kind=\(request.kind.rawValue) run=\(run.id)")
        let result: (summary: Summary, error: String?) = await withCheckedContinuation { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                completion.resume(returning: run.perform {
                    Core.refreshAnalysis(previous, request: request, progress: progress)
                })
            }
        }
        let canPublish = generation == loadGeneration && !run.isCancelled && WorkCoordinator.shared.available
        if canPublish && result.error == nil {
            s = result.summary
            SummaryCache.save(result.summary)
            HealthExport.shared.push(result.summary.withUserWorkouts(workouts))
        }
        if generation == loadGeneration {
            isRefreshingSummary = false
            modelProgress.report(generation, nil)
        }
        IdleTimerLock.release("models")
        WorkCoordinator.shared.finishAnalysis(run)
        await WorkGate.shared.release()
        dlog("models", "refresh end day=\(request.day) kind=\(request.kind.rawValue) cancelled=\(run.isCancelled)")
        return canPublish ? result.error : "Refresh paused. Keep the app open and try again."
    }
    #endif

    private func load(force: Bool = false, clearCurrent: Bool = false) {
        guard force || s == nil else { return }
        // Lifecycle notifications and sync completion can request the same load.
        // Queue one refresh instead of repeatedly cancelling its predecessor.
        guard !isRefreshingSummary else { reloadPending = true; return }
        let run = WorkCoordinator.shared.newAnalysis()
        loadGeneration += 1
        let generation = loadGeneration
        let previous = clearCurrent ? nil : s
        if clearCurrent { s = nil }
        isRefreshingSummary = true
        modelProgress.begin(generation)
        let progress = modelProgress.sink(generation)
        Task {
            defer {
                if reloadPending {
                    reloadPending = false
                    load(force: true, clearCurrent: false)
                }
            }
            modelProgress.report(generation, "Waiting for ring data")
            dlog("models", "waiting for work gate run=\(run.id)")
            await WorkGate.shared.acquire()
            guard !run.isCancelled, WorkCoordinator.shared.available else {
                await WorkGate.shared.release()
                WorkCoordinator.shared.finishAnalysis(run)
                if generation == loadGeneration { isRefreshingSummary = false; modelProgress.report(generation, "Analysis paused") }
                return
            }
            modelProgress.report(generation, "Reading ring data")
            IdleTimerLock.acquire("models")
            dlog("models", "start run=\(run.id)")
            let started = ProcessInfo.processInfo.systemUptime
            let full: Summary = await withCheckedContinuation { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    let summary = run.perform {
                        let base = Core.base()
                        #if TORCH
                        return base.error == nil && !run.isCancelled
                            ? Core.withModels(base, previous: previous, progress: progress) : base
                        #else
                        return base
                        #endif
                    }
                    completion.resume(returning: summary)
                }
            }
            if generation == loadGeneration {
                if !run.isCancelled, WorkCoordinator.shared.available {
                    if full.error == nil {
                        s = full
                        SummaryCache.save(full)
                        HealthExport.shared.push(full.withUserWorkouts(workouts))
                    } else if s == nil { s = full }
                    modelProgress.report(generation, full.error == nil ? nil : "Couldn’t refresh data.")
                } else { modelProgress.report(generation, "Analysis paused") }
                isRefreshingSummary = false
            }
            dlog("models", "end run=\(run.id) cancelled=\(run.isCancelled) duration=\(Int(ProcessInfo.processInfo.systemUptime - started))s")
            IdleTimerLock.release("models")
            WorkCoordinator.shared.finishAnalysis(run)
            await WorkGate.shared.release()
        }
    }

    // MARK: - tabs

    /// Opens what was picked in the + sheet once that sheet has gone.
    private func openPendingLog() {
        guard let choice = pendingLog else { return }
        pendingLog = nil
        switch choice {
        case .startWorkout: showStartWorkout = true
        case .logWorkout: showLogWorkout = true
        case .sync: showSync = true
        }
    }

    /// The display units, as one comparable value: a change redraws every screen.
    private var unitsKey: String { "\(units.height)|\(units.weight)|\(units.temperature)|\(units.distance)" }

    private var tabInputs: TabInputs {
        TabInputs(version: dataVersion, busyLabel: busyLabel, isBusy: ring.busy || isRefreshingSummary, units: unitsKey)
    }

    private var actions: AppActions {
        AppActions(go: { tab = $0 },
                   openReport: { report = $0 },
                   sleepDebt: { showSleepDebt = true },
                   vital: { vital = $0 },
                   allDays: { showAllDays = true },
                   profile: { showProfile = true },
                   sync: { showSync = true },
                   finishWorkout: finishWorkout)
    }

    /// Each tab is compared by `tabInputs` (`.equatable()`), so the app's own state
    /// changes (a sheet, the selected tab, sync progress) skip redrawing the tabs.
    @ViewBuilder private func content(_ s: Summary) -> some View {
        let inputs = tabInputs
        let actions = actions
        TabView(selection: $tab) {
            TodayTab(s: s, inputs: inputs, actions: actions).equatable()
                .tabItem { Label("Today", systemImage: "house.fill") }.tag(AppTab.today).toolbar(.hidden, for: .tabBar).safeAreaPadding(.bottom, SignalTabBar.height)
            SleepTab(s: s, inputs: inputs, actions: actions).equatable()
                .tabItem { Label("Sleep", systemImage: "moon.fill") }.tag(AppTab.sleep).toolbar(.hidden, for: .tabBar).safeAreaPadding(.bottom, SignalTabBar.height)
            ActivityTab(s: s, inputs: inputs, onEndWorkout: finishWorkout) { date in
                AppHeader(title: "Activity", subtitle: inputs.busyLabel ?? date) { HeaderButtons(actions: actions) }
            }
            .equatable()
            .tabItem { Label("Activity", systemImage: "flame.fill") }.tag(AppTab.activity).toolbar(.hidden, for: .tabBar).safeAreaPadding(.bottom, SignalTabBar.height)
            TrendsTab(s: s, inputs: inputs) {
                AppHeader(title: "Trends", subtitle: inputs.busyLabel) { HeaderButtons(actions: actions) }
            }
            .equatable()
            .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(AppTab.trends).toolbar(.hidden, for: .tabBar).safeAreaPadding(.bottom, SignalTabBar.height)
            VitalsTab(s: s, inputs: inputs, actions: actions).equatable()
                .tabItem { Label("Vitals", systemImage: "heart.text.square.fill") }.tag(AppTab.vitals).toolbar(.hidden, for: .tabBar).safeAreaPadding(.bottom, SignalTabBar.height)
        }
        .tint(Obs.signal)
        // The bar floats over the pages; each page reserves its height (below), so the
        // end of every scrolling screen stops above it instead of underneath.
        .overlay(alignment: .bottom) {
            SignalTabBar(tab: $tab) { showLogMenu = true }
        }
    }

    private var busyLabel: String? {
        if ring.busy { return "Syncing ring…" }
        if isRefreshingSummary { return modelProgress.label ?? "Analyzing" }
        return nil
    }

    // MARK: workouts

    /// End the running workout, then pull the ring's data for it.
    private func finishWorkout() {
        guard workouts.finish() != nil else { return }
        guard !ring.busy, let key = Keychain.loadKey(), !key.isEmpty else { return }
        Task {
            if let report = await ring.run(keyHex: key, source: "workout") {
                refreshAfterSync(report)
            }
        }
    }
}

enum AppTab: Hashable { case today, sleep, activity, trends, vitals }

/// Which build is actually on this phone. A sideloaded app has no App Store version
/// to compare against, and a failed install looks exactly like a successful one — so
/// show the version, when this binary was signed, and when its free-account
/// certificate stops launching (7 days).
struct BuildStamp: View {
    var prefix: String? = nil
    private static let signedAt: Date? = {
        guard let path = Bundle.main.executableURL?.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }()

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var line: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var out = "Open Oura \(short) (\(build)) · \(coreVersion())"
        if let prefix { out = prefix + " · " + out }
        if let signed = Self.signedAt {
            out += " · built \(Self.stampFormat.string(from: signed))"
            if let expiry = Calendar.current.date(byAdding: .day, value: 7, to: signed) {
                let days = Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0
                out += days < 0
                    ? " · signing expired"
                    : " · signing good to \(Self.dayFormat.string(from: expiry))"
            }
        }
        return out
    }

    var body: some View {
        Text(line)
            .font(Obs.mono(10))
            .foregroundStyle(Obs.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
            .textSelection(.enabled)
    }
}

@main
struct OuraApp: App {
    init() {
        DiagStore.shared.bootstrap()
        BackgroundSync.register()
        // Create the app's Files folder up front so it is there to copy an export into.
        _ = ProfileSettingsView.dropFolder
        // Segmented pickers (Trends periods, chart windows): selected segment in the
        // signal green, labels in the terminal monospace.
        let seg = UISegmentedControl.appearance()
        let segFont = UIFont(name: "ShareTechMono-Regular", size: 14) ?? .monospacedSystemFont(ofSize: 14, weight: .regular)
        seg.selectedSegmentTintColor = UIColor(Obs.signal)
        seg.backgroundColor = UIColor(Obs.card)
        seg.setTitleTextAttributes([.foregroundColor: UIColor(Obs.ink2), .font: segFont], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor(Obs.onSignal), .font: segFont], for: .selected)
        // Dark, slightly translucent bars to sit on the night-sky canvas.
        let tabs = UITabBarAppearance()
        tabs.configureWithDefaultBackground()
        tabs.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
        tabs.backgroundColor = UIColor(red: 0x0b / 255, green: 0x0f / 255, blue: 0x1c / 255, alpha: 0.75)
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        // Screen titles in the terminal fonts: pixel for large titles, monospace inline.
        let navFont = UIFont(name: "ShareTechMono-Regular", size: 17) ?? .monospacedSystemFont(ofSize: 17, weight: .regular)
        let navLarge = UIFont(name: "VT323-Regular", size: 44) ?? .monospacedSystemFont(ofSize: 34, weight: .regular)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white, .font: navFont]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white, .font: navLarge]
        let barButton = UIBarButtonItemAppearance()
        barButton.normal.titleTextAttributes = [.font: navFont]
        nav.buttonAppearance = barButton
        nav.doneButtonAppearance = barButton
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }
    var body: some Scene { WindowGroup { RootView() } }
}

/// One day from an imported Oura export. The export holds Oura's daily figures only,
/// not the ring's raw signals, so there is no hypnogram or heart-rate curve to draw.
struct ImportedDayView: View {
    let day: String
    let entry: ImportedDay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    ScoreRing(value: entry.readiness.map { "\(Int($0))" } ?? "–", caption: "readiness",
                              progress: entry.readiness.map { $0 / 100 }, accent: Obs.readinessAccent)
                    ScoreRing(value: entry.sleep_score.map { "\(Int($0))" } ?? "–", caption: "sleep",
                              progress: entry.sleep_score.map { $0 / 100 }, accent: Obs.sleepAccent)
                    ScoreRing(value: entry.activity_score.map { "\(Int($0))" } ?? "–", caption: "activity",
                              progress: entry.activity_score.map { $0 / 100 }, accent: Obs.activityAccent)
                }
                .frame(maxWidth: .infinity)
                .obsCard(padding: 20)
                VStack(spacing: 10) {
                    stat("Time asleep", entry.asleep_s.map { Fmt.duration(seconds: $0) })
                    stat("Lowest heart rate", entry.rhr.map { "\(Int($0.rounded())) bpm" })
                    stat("HRV", entry.hrv_ms.map { "\(Int($0.rounded())) ms" })
                    stat("Breathing rate", entry.breath_rate.map { String(format: "%.1f /min", $0) })
                    stat("Temperature vs usual", entry.temp_deviation.map {
                        let unit = UnitSettings.shared.temperature
                        return "\(Fmt.temperatureDelta($0, unit)) \(unit.symbol)"
                    })
                    stat("Steps", entry.steps.map { Fmt.count($0) })
                    stat("Active calories", entry.active_kcal.map { "\(Fmt.count($0)) kcal" })
                }
                .obsCard()
                Text("This day comes from your Oura export, which has Oura's daily figures but not the ring's minute-by-minute data, so there's no sleep-stage or heart-rate chart for it.")
                    .font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .background(Obs.canvas.ignoresSafeArea())
        .navigationTitle(Fmt.day(day))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func stat(_ label: String, _ value: String?) -> some View {
        if let value { ObsStat(label: label, value: value) }
    }
}
