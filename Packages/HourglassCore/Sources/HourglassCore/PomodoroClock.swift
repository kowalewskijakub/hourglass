import Foundation

/// Abstraction over "the current time" and "call me periodically".
///
/// The engine never reads `Date()` or creates a `Timer` directly — it goes
/// through this seam so tests can drive time forward deterministically without
/// waiting in real life.
@MainActor
public protocol PomodoroClock: AnyObject {
    /// The current instant.
    var now: Date { get }
    /// Begin calling `handler` every `interval` seconds. Replaces any existing schedule.
    func schedule(every interval: TimeInterval, _ handler: @escaping @MainActor () -> Void)
    /// Stop calling the handler.
    func cancel()
}

/// Production clock backed by the wall clock and a run-loop `Timer`.
@MainActor
public final class SystemClock: PomodoroClock {
    // Only ever mutated on the main actor; `nonisolated(unsafe)` lets `deinit`
    // invalidate it without a data race (deinit runs after all main-actor use).
    nonisolated(unsafe) private var timer: Timer?

    public init() {}

    public var now: Date { Date() }

    public func schedule(every interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) {
        cancel()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { handler() }
        }
        // .common so it keeps firing while menus/tracking loops are active.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
