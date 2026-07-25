import Foundation
@testable import HourglassCore

/// A deterministic clock for tests: time only moves when the test says so, and
/// ticks fire only when requested. Lets us exercise the engine with no waiting.
@MainActor
final class TestClock: PomodoroClock {
    private(set) var currentDate: Date
    private var handler: (@MainActor () -> Void)?
    private(set) var scheduledInterval: TimeInterval?

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentDate = now
    }

    var now: Date { currentDate }

    func schedule(every interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) {
        self.scheduledInterval = interval
        self.handler = handler
    }

    func cancel() {
        handler = nil
        scheduledInterval = nil
    }

    var isScheduled: Bool { handler != nil }

    /// Advance time by `seconds` and fire a single tick (a normal timer firing).
    func advance(by seconds: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(seconds)
        handler?()
    }

    /// Move time forward WITHOUT firing a tick — simulates app suspension.
    func jump(by seconds: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(seconds)
    }

    /// Fire one tick without changing the time (e.g. a wake-up tick).
    func fireTick() {
        handler?()
    }
}
