import Foundation

extension Date {
    /// This date on the millisecond grid the wire carries.
    ///
    /// Stamps travel as ISO-8601 with fractional seconds — millisecond
    /// precision — while a local `Date` holds sub-millisecond digits. Without
    /// alignment, a stamp compares *greater than itself* after a server
    /// round-trip, and the connect-time reconcile re-uploads every row on
    /// every connect, forever. Nearest-rounded: that makes the operation
    /// idempotent under floating point (aligning an aligned stamp cannot creep
    /// it onto the next millisecond), which matters more than direction — the
    /// hybrid clock's one-millisecond tick dwarfs the half-millisecond shift.
    public var wireAligned: Date {
        Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate * 1_000).rounded(.toNearestOrAwayFromZero) / 1_000)
    }
}

/// Issues the `updatedAt` stamps that decide last-writer-wins between devices.
///
/// Separate from ``PomodoroClock`` on purpose: event times (when a break
/// started, when a session ended) must stay honest wall-clock readings, but
/// *conflict stamps* need two properties the wall clock can't promise —
/// they never repeat, and they never fall behind a stamp already seen from
/// another device. Mixing the two would let a fast peer clock distort the
/// times users actually see.
@MainActor
public protocol UpdateStamping: AnyObject {
    /// A stamp strictly later than any issued or observed before.
    func next() -> Date
    /// Feed in a stamp seen on a remote row, so local stamps stay ahead of it.
    func observe(_ remote: Date)
}

/// The trivial source for tests and sync-free use: plain wall clock.
@MainActor
public final class WallClockStamps: UpdateStamping {
    private let wallClock: () -> Date
    public init(wallClock: @escaping () -> Date = { Date() }) {
        self.wallClock = wallClock
    }
    public func next() -> Date { wallClock() }
    public func observe(_ remote: Date) {}
}

/// A hybrid logical clock, sized for this app.
///
/// Last-writer-wins is only as good as the clocks that stamp the writes: a
/// device whose clock runs an hour fast would silently win every conflict for
/// an hour. This clock issues wall-clock stamps, except it refuses to go
/// backwards — below its own last stamp, or below the newest stamp it has seen
/// arrive from the server. A skewed peer therefore drags logical time forward
/// (causal order survives) instead of rewriting history.
///
/// The watermark persists across launches: an edit made in the first seconds
/// after relaunch, before the first pull, must not stamp below what the server
/// already holds.
@MainActor
public final class HybridStampClock: UpdateStamping {
    /// Minimum distance between two issued stamps, and above the watermark.
    /// One millisecond: comfortably inside `timestamptz` resolution.
    private static let tick: TimeInterval = 0.001

    private let wallClock: () -> Date
    private let persist: (Date) -> Void
    private var lastIssued: Date

    public init(
        wallClock: @escaping () -> Date = { Date() },
        restored: Date? = nil,
        persist: @escaping (Date) -> Void = { _ in }
    ) {
        self.wallClock = wallClock
        self.persist = persist
        self.lastIssued = restored ?? .distantPast
    }

    /// Restores from / persists to `UserDefaults` under `key`.
    public convenience init(defaults: UserDefaults = .standard, key: String) {
        self.init(
            restored: defaults.object(forKey: key) as? Date,
            persist: { defaults.set($0, forKey: key) }
        )
    }

    public func next() -> Date {
        let stamp = max(wallClock(), lastIssued.addingTimeInterval(Self.tick)).wireAligned
        lastIssued = stamp
        persist(stamp)
        return stamp
    }

    public func observe(_ remote: Date) {
        guard remote > lastIssued else { return }
        lastIssued = remote
        persist(remote)
    }
}
