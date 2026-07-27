import BackgroundTasks
import Foundation

/// Opportunistic background refresh.
///
/// iOS decides when (and whether) to run these — typically minutes to hours
/// apart, based on how you use the app and the battery/network state. It is a
/// best-effort top-up, *not* a live connection: continuous updates would need
/// silent pushes, which require a paid Apple Developer account. The app still
/// reconciles on every foreground, which is what covers the common case.
@MainActor
enum BackgroundRefresh {
    static let taskIdentifier = "com.kowalewskijakub.hourglass.refresh"

    /// Registers the handler. Must be called before the app finishes launching.
    static func register(perform: @escaping @MainActor () async -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                // Always queue the next one first; a missed reschedule means the
                // app silently stops refreshing forever.
                schedule()

                let work = Task { @MainActor in
                    await perform()
                }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }

    /// Asks the system for another refresh, no sooner than 15 minutes out.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
