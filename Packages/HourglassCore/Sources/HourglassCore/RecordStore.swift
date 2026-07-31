import Foundation
import Observation

/// A record that knows which file holds it, so a store parameterised on the
/// record alone can still find its home on disk.
public protocol FileBackedRecord: Codable, Sendable, Identifiable {
    /// File name inside the app's Application Support folder.
    static var storeFileName: String { get }
}

/// Storage for a list of records: read the lot, plus the four edits the app can
/// make to it. The domain seams (`HistoryStoring`, `WorkdayStoring`) are this
/// protocol pinned to one record type, so a rule added here reaches all of them.
@MainActor
public protocol RecordStoring<Element>: AnyObject {
    associatedtype Element: Identifiable & Codable & Sendable

    func all() -> [Element]
    func add(_ record: Element)
    /// Replace an existing record (matched by `id`); no-op if not present.
    func update(_ record: Element)
    /// Remove a record by id.
    func delete(id: Element.ID)
    func clear()
}

public extension RecordStoring {
    /// Update if a record with the same id exists, otherwise add. The write
    /// path for anything that can arrive more than once — a completion seen by
    /// two devices, a remote row applied over a local copy — so "again" always
    /// means "replace", never "duplicate".
    func upsert(_ record: Element) {
        if all().contains(where: { $0.id == record.id }) {
            update(record)
        } else {
            add(record)
        }
    }
}

/// Persists records as a JSON array under Application Support.
/// Observable so statistics views refresh as records are written.
@MainActor
@Observable
public final class FileRecordStore<Element: FileBackedRecord>: RecordStoring {
    @ObservationIgnored private let fileURL: URL
    private var records: [Element]

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.records = Self.load(from: url)
    }

    public func all() -> [Element] { records }

    public func add(_ record: Element) {
        records.append(record)
        save()
    }

    public func update(_ record: Element) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        save()
    }

    public func delete(id: Element.ID) {
        records.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        records.removeAll()
        save()
    }

    // MARK: File IO

    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Hourglass", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Element.storeFileName)
    }

    /// An unreadable or unparseable file reads back as "nothing recorded yet"
    /// rather than throwing, so a bad file can never block launch.
    private static func load(from url: URL) -> [Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Element].self, from: data)) ?? []
    }

    /// Atomic, so a crash mid-write leaves the previous file intact.
    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// In-memory records for tests and previews.
@MainActor
@Observable
public final class InMemoryRecordStore<Element: Identifiable & Codable & Sendable>: RecordStoring {
    private var records: [Element]
    /// Labelled `sessions:` because every record this fake holds is a session.
    public init(sessions: [Element] = []) { self.records = sessions }
    public func all() -> [Element] { records }
    public func add(_ record: Element) { records.append(record) }
    public func update(_ record: Element) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
    }
    public func delete(id: Element.ID) { records.removeAll { $0.id == id } }
    public func clear() { records.removeAll() }
}
