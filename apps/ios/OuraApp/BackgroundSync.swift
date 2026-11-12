import BackgroundTasks
import Foundation

/// Syncs the ring while the app is closed, using the time iOS hands out to apps in
/// the background:
///
/// - **App refresh** (`…sync.refresh`): short runs (around 30 s) that iOS spreads
///   through the day, more often for apps that are opened often.
/// - **Processing** (`…sync.processing`): longer runs, typically overnight while the
///   phone is charging, for when a lot of history has built up on the ring.
///
/// Both connect straight to the remembered ring (no scan, which iOS restricts in the
/// background) and checkpoint after every batch, so a run cut short keeps its data.
/// iOS decides when these run; they stop if the app is force-quit from the app
/// switcher, until it is opened again.
enum BackgroundSync {
    static let refreshID = "md.thomas.openoura.sync.refresh"
    static let processingID = "md.thomas.openoura.sync.processing"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { task in
            handle(task)
        }
    }

    /// Ask iOS for the next background runs. Safe to call repeatedly: a new request
    /// replaces the pending one with the same identifier.
    static func schedule() {
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: RingSync.backgroundSyncInterval)
        submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = false
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        submit(processing)
    }

    private static func submit(_ request: BGTaskRequest) {
        do { try BGTaskScheduler.shared.submit(request) }
        catch { dlog("sync", "background request \(request.identifier) not scheduled: \(error)") }
    }

    private static func handle(_ task: BGTask) {
        schedule() // keep the chain going whatever happens to this run
        let work = Task { @MainActor in
            let report = await RingSync.shared.syncInBackground()
            dlog("sync", "background \(task.identifier) finished: \(report.map { "\($0.eventsSynced) events" } ?? "nothing to do")")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            Task { @MainActor in RingSync.shared.stopBackgroundSync() }
            work.cancel()
        }
    }
}
