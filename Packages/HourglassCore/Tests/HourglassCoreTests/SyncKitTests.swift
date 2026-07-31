import Foundation
import Testing
@testable import HourglassCore

// MARK: - Hybrid stamps

@MainActor
struct HybridStampClockTests {

    @Test func stampsNeverRepeatEvenWithinOneInstant() {
        var wall = Date(timeIntervalSince1970: 1_000)
        let stamps = HybridStampClock(wallClock: { wall })
        let a = stamps.next()
        let b = stamps.next()
        let c = stamps.next()
        #expect(a < b && b < c)
        // And they resume tracking the wall clock once it moves past.
        wall = wall.addingTimeInterval(60)
        #expect(stamps.next() == wall)
    }

    @Test func observedRemoteStampsBecomeAFloor() {
        let wall = Date(timeIntervalSince1970: 1_000)
        let stamps = HybridStampClock(wallClock: { wall })
        // A peer with a fast clock writes one hour ahead.
        let ahead = wall.addingTimeInterval(3_600)
        stamps.observe(ahead)
        // Our next edit must outrank it, or the peer's stale row would win
        // last-writer-wins against an edit the user made after seeing it.
        #expect(stamps.next() > ahead)
    }

    @Test func observingAnOlderStampChangesNothing() {
        let wall = Date(timeIntervalSince1970: 1_000)
        let stamps = HybridStampClock(wallClock: { wall })
        let issued = stamps.next()
        stamps.observe(issued.addingTimeInterval(-500))
        #expect(stamps.next() > issued)
        #expect(stamps.next() < wall.addingTimeInterval(1))
    }

    /// Stamps travel as ISO-8601 with millisecond precision. A stamp that
    /// doesn't survive that round-trip bitwise reads as "newer than itself"
    /// and the reconcile re-uploads the whole table on every connect.
    @Test func stampsSurviveTheWireRoundTripExactly() {
        var wall = Date(timeIntervalSince1970: 1_722_400_000.123456) // sub-ms digits
        let stamps = HybridStampClock(wallClock: { wall })
        for _ in 0..<50 {
            let stamp = stamps.next()
            // The wire's round-trip: format at ms precision, parse back.
            let milliseconds = (stamp.timeIntervalSinceReferenceDate * 1_000).rounded()
            let roundTripped = Date(timeIntervalSinceReferenceDate: milliseconds / 1_000)
            #expect(roundTripped == stamp)
            #expect(stamp.wireAligned == stamp) // aligning is idempotent
            wall = wall.addingTimeInterval(0.0007) // keep sub-ms pressure on
        }
    }

    @Test func watermarkSurvivesRelaunch() {
        var persisted: Date?
        let wall = Date(timeIntervalSince1970: 1_000)
        let first = HybridStampClock(wallClock: { wall }, persist: { persisted = $0 })
        first.observe(wall.addingTimeInterval(3_600))

        // A fresh instance — the app relaunching — restores the floor, so an
        // edit made before the first pull still stamps above what the server
        // already holds.
        let second = HybridStampClock(wallClock: { wall }, restored: persisted)
        #expect(second.next() > wall.addingTimeInterval(3_600))
    }
}

// MARK: - Outbox

@MainActor
struct SyncOutboxTests {

    private func liveRow(stamp: TimeInterval, running: Bool = true) -> LiveStateRow {
        LiveStateRow(
            user_id: "", kind: "focus",
            end_date: Date(timeIntervalSince1970: stamp + 100),
            is_running: running, paused_at: nil, cycle_position: 0,
            session_id: UUID(), origin_device: "test",
            updated_at: Date(timeIntervalSince1970: stamp)
        )
    }

    private func sessionRow(id: UUID, stamp: TimeInterval) -> SessionRow {
        var row = SessionRow(
            session: FocusSession(
                id: id, kind: .focus, plannedDuration: 1_500,
                startedAt: Date(timeIntervalSince1970: stamp - 1_500),
                endedAt: Date(timeIntervalSince1970: stamp),
                completed: true,
                updatedAt: Date(timeIntervalSince1970: stamp)
            ),
            userID: ""
        )
        row.updated_at = Date(timeIntervalSince1970: stamp)
        return row
    }

    @Test func entriesKeepArrivalOrderAcrossRows() {
        let outbox = SyncOutbox(fileURL: nil)
        let a = UUID(), b = UUID()
        outbox.enqueue(.session(sessionRow(id: a, stamp: 1)))
        outbox.enqueue(.session(sessionRow(id: b, stamp: 2)))
        #expect(outbox.entries.map(\.payload.coalesceKey) == ["sessions:\(a.uuidString)", "sessions:\(b.uuidString)"])
    }

    @Test func aNewerWriteForTheSameRowReplacesTheQueuedOne() {
        let outbox = SyncOutbox(fileURL: nil)
        outbox.enqueue(.liveState(liveRow(stamp: 1)))
        outbox.enqueue(.liveState(liveRow(stamp: 2, running: false)))
        #expect(outbox.count == 1)
        guard case .liveState(let row)? = outbox.first?.payload else {
            Issue.record("expected the coalesced live row")
            return
        }
        // Only the final state travels; the burst's intermediate one is gone.
        #expect(row.updated_at == Date(timeIntervalSince1970: 2))
        #expect(row.is_running == false)
    }

    @Test func aTombstoneSupersedesTheQueuedEditAndViceVersa() {
        let outbox = SyncOutbox(fileURL: nil)
        let id = UUID()
        outbox.enqueue(.session(sessionRow(id: id, stamp: 1)))
        outbox.enqueue(.session(SessionRow.tombstone(id: id, userID: "", at: Date(timeIntervalSince1970: 2))))
        #expect(outbox.count == 1)
        guard case .session(let row)? = outbox.first?.payload else {
            Issue.record("expected the tombstone")
            return
        }
        #expect(row.deleted_at != nil)

        // …and an edit made after the (still queued) deletion resurrects it.
        outbox.enqueue(.session(sessionRow(id: id, stamp: 3)))
        #expect(outbox.count == 1)
        guard case .session(let resurrected)? = outbox.first?.payload else {
            Issue.record("expected the resurrected row")
            return
        }
        #expect(resurrected.deleted_at == nil)
    }

    @Test func queueSurvivesARestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = SyncOutbox(fileURL: url)
        let id = UUID()
        first.enqueue(.session(sessionRow(id: id, stamp: 1)))
        first.enqueue(.settings(SettingsRow(user_id: "", payload: .default, updated_at: Date())))

        let second = SyncOutbox(fileURL: url)
        #expect(second.count == 2)
        #expect(second.entries.map(\.payload.table) == ["sessions", "settings"])

        second.markSent(second.first!.id)
        let third = SyncOutbox(fileURL: url)
        #expect(third.entries.map(\.payload.table) == ["settings"])
    }

    @Test func addressingStampsTheUserIDAtSendTime() {
        let outbox = SyncOutbox(fileURL: nil)
        outbox.enqueue(.session(sessionRow(id: UUID(), stamp: 1)))
        let addressed = outbox.first!.payload.addressed(to: "user-123")
        guard case .session(let row) = addressed else {
            Issue.record("expected a session payload")
            return
        }
        #expect(row.user_id == "user-123")
    }
}

// MARK: - Wire encoding invariants

struct SyncWireEncodingTests {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// An upsert only touches the columns its payload names, so every nil must
    /// reach the wire as an explicit null — most importantly `deleted_at`,
    /// whose omission once made any edit that outranked a tombstone
    /// half-resurrect the row instead of clearing the deletion.
    @Test func liveRowsWriteExplicitNulls() throws {
        let session = FocusSession(
            kind: .focus, plannedDuration: 10,
            startedAt: Date(), endedAt: nil, completed: false, updatedAt: Date()
        )
        let object = try json(SessionRow(session: session, userID: "u"))
        #expect(object.keys.contains("deleted_at"))
        #expect(object["deleted_at"] is NSNull)
        #expect(object.keys.contains("ended_at"))
        #expect(object["ended_at"] is NSNull)

        let clock = try json(ClockSessionRow(
            session: ClockSession(clockedInAt: Date(), updatedAt: Date()), userID: "u"
        ))
        #expect(clock["clocked_out_at"] is NSNull)
        #expect(clock["deleted_at"] is NSNull)
        #expect(clock["breaks"] == nil) // breaks travel as their own rows

        let brk = try json(WorkBreakRow(
            entry: WorkBreak(startedAt: Date(), updatedAt: Date()),
            sessionID: UUID(), userID: "u"
        ))
        #expect(brk["ended_at"] is NSNull)
        #expect(brk["deleted_at"] is NSNull)

        let idle = try json(LiveStateRow(
            user_id: "u", kind: "focus", end_date: nil, is_running: false,
            paused_at: nil, cycle_position: 0, session_id: nil,
            origin_device: "d", updated_at: Date()
        ))
        #expect(idle["end_date"] is NSNull)
        #expect(idle["paused_at"] is NSNull)
        #expect(idle["session_id"] is NSNull)
    }

    /// The reason `SyncWireEncoding` exists: Foundation's ISO-8601 formatter
    /// truncates fractional seconds at the binary level (~50% of aligned
    /// stamps print one millisecond low). Our encoder prints the exact rounded
    /// millisecond, so parse-back equals the aligned local value bit-for-bit.
    @Test func wireDateStringsRoundTripBitForBit() throws {
        let parser = Date.ISO8601FormatStyle().year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: true)
        for i in 0..<2_000 {
            let raw = Date(timeIntervalSince1970: 1_722_400_000 + Double(i) * 0.7003)
            let aligned = raw.wireAligned
            let string = SyncWireEncoding.string(for: aligned)
            let parsed = try Date(string, strategy: parser)
            #expect(parsed == aligned, "\(string) parsed to \(parsed.timeIntervalSinceReferenceDate) != \(aligned.timeIntervalSinceReferenceDate)")
        }
    }

    /// Rows that predate per-row stamps must not invent a fresh "now" stamp —
    /// that made a legacy copy outrank a genuine recent edit. They fall back to
    /// their own event times instead.
    @Test func unstampedRecordsFallBackToTheirEventTimes() {
        let ended = Date(timeIntervalSince1970: 500)
        let row = SessionRow(
            session: FocusSession(
                kind: .focus, plannedDuration: 10,
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: ended, completed: true, updatedAt: nil
            ),
            userID: "u"
        )
        #expect(row.updated_at == ended)

        let clockedIn = Date(timeIntervalSince1970: 100)
        let clock = ClockSessionRow(
            session: ClockSession(clockedInAt: clockedIn), userID: "u"
        )
        #expect(clock.updated_at == clockedIn)
    }
}

// MARK: - Per-break merge

@MainActor
struct WorkdayBreakMergeTests {

    private func makeTracker() -> (WorkdayTracker, InMemoryWorkdayStore, TestClock) {
        let store = InMemoryWorkdayStore()
        let clock = TestClock()
        return (WorkdayTracker(store: store, clock: clock), store, clock)
    }

    @Test func remoteSessionRowNeverErasesLocalBreaks() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        tracker.endBreak()
        let local = store.all()[0]
        #expect(local.breaks.count == 1)

        // The peer clocks the day out later — its row carries no breaks (they
        // travel separately), and merging it must keep ours.
        var remote = ClockSession(
            id: local.id,
            clockedInAt: local.clockedInAt,
            clockedOutAt: clock.now.addingTimeInterval(3_600),
            breaks: [],
            updatedAt: (local.updatedAt ?? clock.now).addingTimeInterval(60)
        )
        remote.breaks = []
        tracker.applyRemote(remote)

        let merged = store.all()[0]
        #expect(merged.clockedOutAt != nil)      // the newer clock-out applied
        #expect(merged.breaks.count == 1)        // the local break survived
    }

    @Test func remoteBreaksMergeByIdWithLastWriterWins() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        let session = store.all()[0]

        let breakID = UUID()
        let older = WorkBreak(
            id: breakID, startedAt: clock.now, endedAt: nil,
            updatedAt: clock.now
        )
        #expect(tracker.applyRemoteBreak(sessionID: session.id, entry: older))
        #expect(store.all()[0].breaks.count == 1)

        // A newer copy of the same break (the peer ended it) replaces ours…
        let newer = WorkBreak(
            id: breakID, startedAt: clock.now,
            endedAt: clock.now.addingTimeInterval(300),
            updatedAt: clock.now.addingTimeInterval(300)
        )
        #expect(tracker.applyRemoteBreak(sessionID: session.id, entry: newer))
        #expect(store.all()[0].breaks == [newer])

        // …but the stale copy arriving afterwards does not undo it.
        #expect(tracker.applyRemoteBreak(sessionID: session.id, entry: older))
        #expect(store.all()[0].breaks == [newer])
    }

    @Test func aBreakForAnUnknownSessionIsReportedNotDropped() {
        let (tracker, _, clock) = makeTracker()
        let applied = tracker.applyRemoteBreak(
            sessionID: UUID(),
            entry: WorkBreak(startedAt: clock.now, updatedAt: clock.now)
        )
        #expect(applied == false) // the caller buffers it until the parent lands
    }

    @Test func aStaleBreakTombstoneDoesNotEraseANewerEdit() {
        let (tracker, store, clock) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        let session = store.all()[0]
        let entry = session.breaks[0]

        // Deletion stamped before our local edit: the edit stands.
        tracker.deleteBreakLocally(
            sessionID: session.id, entryID: entry.id,
            unlessEditedAfter: (entry.updatedAt ?? clock.now).addingTimeInterval(-60)
        )
        #expect(store.all()[0].breaks.count == 1)

        // Deletion stamped after it: the break goes.
        tracker.deleteBreakLocally(
            sessionID: session.id, entryID: entry.id,
            unlessEditedAfter: (entry.updatedAt ?? clock.now).addingTimeInterval(60)
        )
        #expect(store.all()[0].breaks.isEmpty)
    }

    @Test func deletingABreakAnnouncesTheTombstone() {
        let (tracker, store, _) = makeTracker()
        tracker.clockIn()
        tracker.startBreak()
        let session = store.all()[0]

        var announced: (ClockSession.ID, WorkBreak.ID)?
        tracker.onBreakDeleted = { announced = ($0, $1) }
        tracker.deleteBreak(sessionID: session.id, entryID: session.breaks[0].id)

        #expect(announced?.0 == session.id)
        #expect(announced?.1 == session.breaks[0].id)
        #expect(store.all()[0].breaks.isEmpty)
    }
}

// MARK: - Completion publishes the settled state

@MainActor
struct CompletionOrderingTests {

    @Test func completionCallbackSeesTheAdvancedIdleEngine() {
        let store = InMemorySettingsStore(settings: TimerSettings(
            focusDuration: 100, shortBreakDuration: 20, longBreakDuration: 40,
            sessionsUntilLongBreak: 4
        ))
        let clock = TestClock()
        let engine = PomodoroEngine(
            settingsStore: store, history: InMemoryHistoryStore(), clock: clock
        )

        // The sync layer snapshots the engine inside this callback and mirrors
        // the snapshot. It must therefore see the SETTLED state — idle at the
        // next phase — or the wire carries "running, ends right now, old
        // position" as the final row and every peer regresses a phase.
        var seen: (phase: PomodoroEngine.Phase, position: Int, remaining: TimeInterval)?
        engine.onSessionCompleted = { [weak engine] _ in
            guard let engine else { return }
            seen = (engine.phase, engine.cyclePosition, engine.remaining)
        }

        engine.start()
        clock.advance(by: 101)

        #expect(seen?.phase == .idle)
        #expect(seen?.position == 1)
        #expect(seen?.remaining == 20)
    }
}
