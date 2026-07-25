import Foundation
import Observation

/// Storage for completed/abandoned sessions.
@MainActor
public protocol HistoryStoring: AnyObject {
    func all() -> [FocusSession]
    func add(_ session: FocusSession)
    /// Replace an existing session (matched by `id`); no-op if not present.
    func update(_ session: FocusSession)
    /// Remove a session by id.
    func delete(id: FocusSession.ID)
    func clear()
}

/// Persists session history as a JSON array under Application Support.
/// Observable so statistics views refresh as sessions are recorded.
@MainActor
@Observable
public final class FileHistoryStore: HistoryStoring {
    @ObservationIgnored private let fileURL: URL
    private var sessions: [FocusSession]

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.sessions = Self.load(from: url)
    }

    public func all() -> [FocusSession] { sessions }

    public func add(_ session: FocusSession) {
        sessions.append(session)
        save()
    }

    public func update(_ session: FocusSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
        save()
    }

    public func delete(id: FocusSession.ID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        sessions.removeAll()
        save()
    }

    // MARK: File IO

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Hourglass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private static func load(from url: URL) -> [FocusSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FocusSession].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// In-memory history for tests and previews.
@MainActor
@Observable
public final class InMemoryHistoryStore: HistoryStoring {
    private var sessions: [FocusSession]
    public init(sessions: [FocusSession] = []) {
        self.sessions = sessions
    }
    public func all() -> [FocusSession] { sessions }
    public func add(_ session: FocusSession) { sessions.append(session) }
    public func update(_ session: FocusSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
    }
    public func delete(id: FocusSession.ID) { sessions.removeAll { $0.id == id } }
    public func clear() { sessions.removeAll() }
}
