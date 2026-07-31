import Foundation
import Observation

/// One write waiting to reach the server.
public enum OutboxPayload: Codable, Sendable, Equatable {
    case liveState(LiveStateRow)
    case session(SessionRow)
    case clockSession(ClockSessionRow)
    case workBreak(WorkBreakRow)
    case settings(SettingsRow)

    /// The table this payload upserts into.
    public var table: String {
        switch self {
        case .liveState: return "live_state"
        case .session: return "sessions"
        case .clockSession: return "clock_sessions"
        case .workBreak: return "work_breaks"
        case .settings: return "settings"
        }
    }

    /// The upsert conflict target for the table.
    public var onConflict: String {
        switch self {
        case .liveState, .settings: return "user_id"
        case .session, .clockSession, .workBreak: return "user_id,id"
        }
    }

    /// Entries with the same key describe the same server row, so a newer
    /// entry fully supersedes an older one still waiting in the queue.
    public var coalesceKey: String {
        switch self {
        case .liveState: return "live_state"
        case .settings: return "settings"
        case .session(let row): return "sessions:\(row.id.uuidString)"
        case .clockSession(let row): return "clock_sessions:\(row.id.uuidString)"
        case .workBreak(let row): return "work_breaks:\(row.id.uuidString)"
        }
    }

    /// The same payload re-addressed to `userID`. Rows are enqueued before it
    /// is known which account they will upload to — the device may be offline,
    /// signed out, or about to pair — so the address is stamped at send time.
    public func addressed(to userID: String) -> OutboxPayload {
        switch self {
        case .liveState(var row): row.user_id = userID; return .liveState(row)
        case .session(var row): row.user_id = userID; return .session(row)
        case .clockSession(var row): row.user_id = userID; return .clockSession(row)
        case .workBreak(var row): row.user_id = userID; return .workBreak(row)
        case .settings(var row): row.user_id = userID; return .settings(row)
        }
    }
}

public struct OutboxEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let payload: OutboxPayload
    public let enqueuedAt: Date

    public init(id: UUID = UUID(), payload: OutboxPayload, enqueuedAt: Date = Date()) {
        self.id = id
        self.payload = payload
        self.enqueuedAt = enqueuedAt
    }
}

/// The durable, ordered queue every outgoing write passes through.
///
/// This replaces fire-and-forget pushes, which had three failure modes the
/// audit confirmed: two rapid writes could land out of order (the server kept
/// the older state), a failed write was simply lost until the next full
/// reconcile, and a deletion — whose local evidence is erased by doing it —
/// was lost forever. The queue is drained strictly front-to-back by a single
/// worker, survives restarts on disk, and an entry leaves it only when the
/// server has confirmed the write.
///
/// Enqueueing coalesces: a payload replaces any older queued payload for the
/// same row (`coalesceKey`), since a full-row write supersedes the previous
/// one. A burst of timer transitions therefore collapses to the final state
/// instead of replaying intermediate ones.
@MainActor
@Observable
public final class SyncOutbox {
    public static let defaultFileName = "sync-outbox.json"

    @ObservationIgnored private let fileURL: URL?
    private(set) public var entries: [OutboxEntry]

    /// Pass `fileURL: nil` for an in-memory queue (tests, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([OutboxEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// The queue file next to the app's other stores.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Hourglass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(defaultFileName)
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    public var first: OutboxEntry? { entries.first }

    public func enqueue(_ payload: OutboxPayload) {
        let key = payload.coalesceKey
        entries.removeAll { $0.payload.coalesceKey == key }
        entries.append(OutboxEntry(payload: payload))
        save()
    }

    /// Forget an entry the server has confirmed.
    public func markSent(_ id: OutboxEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        guard let fileURL else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
