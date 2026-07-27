import Foundation

/// A single recorded session (focus or break). Persisted to history.
public struct FocusSession: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var kind: SessionKind
    /// The intended duration when the session started, in seconds.
    public var plannedDuration: TimeInterval
    public var startedAt: Date
    public var endedAt: Date?
    /// True if the session ran to completion (as opposed to being skipped/reset).
    public var completed: Bool
    /// Optional label describing what was worked on (focus sessions only).
    public var taskLabel: String?
    /// When this session last changed. Optional so files written before this
    /// existed still decode; treated as "oldest" when absent.
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: SessionKind,
        plannedDuration: TimeInterval,
        startedAt: Date,
        endedAt: Date? = nil,
        completed: Bool = false,
        taskLabel: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.plannedDuration = plannedDuration
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.completed = completed
        self.taskLabel = taskLabel
        self.updatedAt = updatedAt
    }

    /// Wall-clock time actually elapsed between start and end.
    public var actualDuration: TimeInterval {
        guard let endedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}
