import Foundation

extension FocusSession: FileBackedRecord {
    public static var storeFileName: String { "history.json" }
}

/// Storage for completed/abandoned sessions. A named seam rather than a bare
/// `RecordStoring<FocusSession>` so call sites and test doubles keep speaking
/// in domain terms.
public protocol HistoryStoring: RecordStoring where Element == FocusSession {}

/// Persists session history as a JSON array under Application Support.
/// Observable so statistics views refresh as sessions are recorded.
public typealias FileHistoryStore = FileRecordStore<FocusSession>
extension FileRecordStore: HistoryStoring where Element == FocusSession {}

/// In-memory history for tests and previews.
public typealias InMemoryHistoryStore = InMemoryRecordStore<FocusSession>
extension InMemoryRecordStore: HistoryStoring where Element == FocusSession {}
