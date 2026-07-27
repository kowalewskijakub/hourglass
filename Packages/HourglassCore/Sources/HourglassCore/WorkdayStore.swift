import Foundation

extension ClockSession: FileBackedRecord {
    public static var storeFileName: String { "workdays.json" }
}

/// Storage for clock-in/out sessions (and the breaks inside them). A named seam
/// rather than a bare `RecordStoring<ClockSession>` so call sites and test
/// doubles keep speaking in domain terms.
public protocol WorkdayStoring: RecordStoring where Element == ClockSession {}

/// Persists clock sessions as JSON under Application Support.
public typealias FileWorkdayStore = FileRecordStore<ClockSession>
extension FileRecordStore: WorkdayStoring where Element == ClockSession {}

/// In-memory workday storage for tests and previews.
public typealias InMemoryWorkdayStore = InMemoryRecordStore<ClockSession>
extension InMemoryRecordStore: WorkdayStoring where Element == ClockSession {}
