import Foundation
import Observation

/// Storage for clock-in/out sessions (and the breaks inside them).
@MainActor
public protocol WorkdayStoring: AnyObject {
    func all() -> [ClockSession]
    func add(_ session: ClockSession)
    /// Replace an existing session (matched by `id`); no-op if absent.
    func update(_ session: ClockSession)
    func delete(id: ClockSession.ID)
    func clear()
}

/// Persists clock sessions as JSON under Application Support.
@MainActor
@Observable
public final class FileWorkdayStore: WorkdayStoring {
    @ObservationIgnored private let fileURL: URL
    private var sessions: [ClockSession]

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.sessions = Self.load(from: url)
    }

    public func all() -> [ClockSession] { sessions }

    public func add(_ session: ClockSession) {
        sessions.append(session)
        save()
    }

    public func update(_ session: ClockSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[index] = session
        save()
    }

    public func delete(id: ClockSession.ID) {
        sessions.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        sessions.removeAll()
        save()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Hourglass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workdays.json")
    }

    private static func load(from url: URL) -> [ClockSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ClockSession].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// In-memory workday storage for tests and previews.
@MainActor
@Observable
public final class InMemoryWorkdayStore: WorkdayStoring {
    private var sessions: [ClockSession]
    public init(sessions: [ClockSession] = []) { self.sessions = sessions }
    public func all() -> [ClockSession] { sessions }
    public func add(_ session: ClockSession) { sessions.append(session) }
    public func update(_ session: ClockSession) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i] = session
    }
    public func delete(id: ClockSession.ID) { sessions.removeAll { $0.id == id } }
    public func clear() { sessions.removeAll() }
}
