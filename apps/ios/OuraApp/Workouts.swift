import Foundation
import SwiftUI

// Model-free activity tracking: workouts the wearer starts/stops or logs by hand, and
// the shared core's rule-based detection of sustained movement. The numbers for any
// workout (calories, steps, heart rate) come from the ring data via
// `oura_summary::workouts` (FFI `workoutStatsJson` / `detectedWorkoutsJson`).
// SIBLING CLIENT: iOS-only for now — see "Known gaps" in docs/clients-web-and-ios.md.

enum WorkoutKind: String, CaseIterable, Codable, Identifiable {
    case running, walking, cycling, strength = "strength training", hiit = "hiit",
         yoga, swimming, hiking, rowing, elliptical, dance, sports, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hiit: return "HIIT"
        case .strength: return "Strength training"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
    var symbol: String {
        switch self {
        case .sports: return "sportscourt"
        case .other: return "figure.mixed.cardio"
        default: return activitySymbol(rawValue)
        }
    }
}

/// A workout the wearer started and stopped, logged after the fact, or confirmed from
/// a rule detection.
struct UserWorkout: Codable, Identifiable, Equatable {
    enum Origin: String, Codable { case live, logged, confirmed }
    var id = UUID()
    var kind: WorkoutKind
    var start: Date
    var end: Date
    var origin: Origin
    var note: String? = nil

    var durationMin: Int { max(1, Int((end.timeIntervalSince(start) / 60).rounded())) }

    var session: WorkoutSession {
        WorkoutSession(start: WorkoutFormat.dayTime.string(from: start),
                       end: WorkoutFormat.time.string(from: end),
                       durationMin: durationMin, label: kind.rawValue, isWorkout: 1,
                       uid: "user.\(id.uuidString)", source: "user")
    }
}

struct ActiveWorkout: Codable, Equatable {
    var kind: WorkoutKind
    var start: Date
}

/// What the ring recorded during a workout (`oura_summary::workouts::window_stats`).
struct WorkoutStats: Codable, Equatable {
    struct HR: Codable, Equatable {
        var avg: Double; var max: Double; var min: Double; var samples: Int
        var series: [[Double]] = []
    }
    var start_unix: Int64
    var end_unix: Int64
    var duration_min: Double?
    var covered_min: Int?
    var active_min: Int?
    var met_avg: Double?
    var met_peak: Double?
    var active_kcal: Double?
    var steps: Double?
    var distance_m: Double?
    var hr: HR?

    /// Fraction of the workout the ring has synced movement for.
    var coverage: Double {
        guard let d = duration_min, d > 0 else { return 0 }
        return min(1, Double(covered_min ?? 0) / d)
    }
}

/// One rule detection from the shared core.
struct DetectedWorkout: Codable, Identifiable, Equatable {
    var start: String          // "YYYY-MM-DD HH:MM" local
    var end: String            // "HH:MM" local
    var duration_min: Int
    var label: String
    var intensity: String?
    var stats: WorkoutStats?
    var id: String { "auto.\(start)" }

    var session: WorkoutSession {
        WorkoutSession(start: start, end: end, durationMin: duration_min, label: label,
                       isWorkout: 1, uid: id, source: "auto")
    }
    var startDate: Date? { WorkoutFormat.dayTime.date(from: start) }
    var endDate: Date? {
        if let s = stats { return Date(timeIntervalSince1970: TimeInterval(s.end_unix)) }
        return startDate.map { $0.addingTimeInterval(TimeInterval(duration_min * 60)) }
    }
}

enum WorkoutFormat {
    static let dayTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "HH:mm"; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Calls into the shared core. Both are quick SQLite reads; run them off the main thread.
enum WorkoutData {
    static func stats(start: Date, end: Date) async -> WorkoutStats? {
        let path = DB.readPath()
        let s = Int64(start.timeIntervalSince1970), e = Int64(end.timeIntervalSince1970)
        return await Task.detached(priority: .userInitiated) {
            let json = workoutStatsJson(dbPath: path, startUnix: s, endUnix: e)
            return try? JSONDecoder().decode(WorkoutStats.self, from: Data(json.utf8))
        }.value
    }

    private struct DetectedPayload: Codable { var sessions: [DetectedWorkout] = [] }

    /// Synchronous: called from `Core.base()`, which already runs off the main thread.
    static func detected(dbPath: String, tzOffset: Int64, days: UInt32 = 30) -> [DetectedWorkout] {
        let json = detectedWorkoutsJson(dbPath: dbPath, tzOffset: tzOffset, days: days)
        return (try? JSONDecoder().decode(DetectedPayload.self, from: Data(json.utf8)))?.sessions ?? []
    }
}

/// The wearer's workouts and the one in progress, kept in Application Support. Lives
/// on this iPhone only (like the profile); Apple Health export copies them out.
@MainActor
final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    private struct Stored: Codable {
        var workouts: [UserWorkout] = []
        var active: ActiveWorkout?
        var dismissed: [String] = []
    }

    @Published private(set) var workouts: [UserWorkout] = []
    @Published private(set) var active: ActiveWorkout?
    @Published private(set) var dismissed: Set<String> = []

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workouts.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            workouts = stored.workouts
            active = stored.active
            dismissed = Set(stored.dismissed)
        }
    }

    private func save() {
        let stored = Stored(workouts: workouts, active: active, dismissed: Array(dismissed).sorted())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: live workout
    func start(_ kind: WorkoutKind, at date: Date = Date()) {
        guard active == nil else { return }
        active = ActiveWorkout(kind: kind, start: date)
        save()
        dlog("workout", "start \(kind.rawValue)")
    }

    func changeActiveKind(_ kind: WorkoutKind) {
        guard var a = active else { return }
        a.kind = kind; active = a; save()
    }

    /// Ends the workout in progress. Under a minute is treated as a mis-tap and dropped.
    @discardableResult
    func finish(at date: Date = Date()) -> UserWorkout? {
        guard let a = active else { return nil }
        active = nil
        defer { save() }
        guard date.timeIntervalSince(a.start) >= 60 else {
            dlog("workout", "discarded \(a.kind.rawValue) shorter than a minute")
            return nil
        }
        let w = UserWorkout(kind: a.kind, start: a.start, end: date, origin: .live)
        workouts.append(w)
        dlog("workout", "finished \(a.kind.rawValue) \(w.durationMin) min")
        return w
    }

    func discardActive() { active = nil; save() }

    // MARK: edit
    func add(_ w: UserWorkout) { workouts.append(w); save() }

    func update(_ w: UserWorkout) {
        guard let i = workouts.firstIndex(where: { $0.id == w.id }) else { return }
        workouts[i] = w; save()
    }

    func delete(sessionID: String) {
        if sessionID.hasPrefix("user.") {
            let raw = String(sessionID.dropFirst(5))
            workouts.removeAll { $0.id.uuidString == raw }
        } else if sessionID.hasPrefix("auto.") {
            dismissed.insert(sessionID)
        }
        save()
    }

    /// Turns a rule detection into the wearer's own workout of the chosen kind.
    func confirm(_ d: DetectedWorkout, as kind: WorkoutKind) {
        guard let start = d.startDate, let end = d.endDate else { return }
        workouts.append(UserWorkout(kind: kind, start: start, end: end, origin: .confirmed))
        dismissed.insert(d.id)
        save()
    }

    func userWorkout(sessionID: String) -> UserWorkout? {
        guard sessionID.hasPrefix("user.") else { return nil }
        let raw = String(sessionID.dropFirst(5))
        return workouts.first { $0.id.uuidString == raw }
    }

    /// Sessions to merge into a summary: the wearer's workouts, plus rule detections
    /// on days the activity model found nothing, minus dismissed ones and any that
    /// overlap a workout the wearer already recorded.
    func sessions(for s: Summary) -> [WorkoutSession] {
        let mine = workouts.map(\.session)
        let modelDays = Set(s.workouts.filter { $0.isWorkout >= 0.5 }.map(\.dayLabel))
        let mineIntervals = workouts.map { ($0.start, $0.end) }
        let auto = s.detectedWorkouts.filter { d in
            guard !dismissed.contains(d.id), !modelDays.contains(String(d.start.prefix(10))),
                  let ds = d.startDate, let de = d.endDate else { return false }
            return !mineIntervals.contains { $0.0 < de && ds < $0.1 }
        }.map(\.session)
        return mine + auto
    }
}

extension Summary {
    @MainActor func withUserWorkouts(_ store: WorkoutStore) -> Summary {
        var s = self
        s.userWorkouts = store.sessions(for: self)
        return s
    }

    func detected(id: String) -> DetectedWorkout? { detectedWorkouts.first { $0.id == id } }
}

/// Daily goals the Today/Activity rings measure against. Stored per device.
enum ActivityGoals {
    static var activeKcal: Double {
        get { let v = UserDefaults.standard.double(forKey: "goal.activeKcal"); return v > 0 ? v : 400 }
        set { UserDefaults.standard.set(newValue, forKey: "goal.activeKcal") }
    }
    static var steps: Double {
        get { let v = UserDefaults.standard.double(forKey: "goal.steps"); return v > 0 ? v : 8000 }
        set { UserDefaults.standard.set(newValue, forKey: "goal.steps") }
    }
}
