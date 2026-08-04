import Foundation
import Testing
@testable import HourglassCore

// A multi-device simulation of the sync protocol.
//
// Everything that carries protocol semantics is the PRODUCTION type: the
// engine, the tracker, the outbox, the hybrid stamp clock, the wire rows.
// Only the transport is simulated — a fake server that enforces the same
// `ignore_stale_writes` trigger the real schema installs, and a change feed
// standing in for realtime. The devices' sync glue mirrors SyncService's
// apply/reconcile rules line for line.
//
// The deterministic scenarios below are regression tests for the defects the
// sync audit confirmed; the randomized sweep at the end asserts the one
// property that makes sync "bulletproof": whatever interleaving of actions,
// offline stretches and reconnects occurs, once every device is online and
// quiescent they all hold identical data — nothing lost, nothing duplicated,
// nothing resurrected.

// MARK: - Fake server (trigger semantics + change feed)

@MainActor
final class FakeSyncServer {
    private(set) var live: LiveStateRow?
    private(set) var sessions: [UUID: SessionRow] = [:]
    private(set) var clocks: [UUID: ClockSessionRow] = [:]
    private(set) var breaks: [UUID: WorkBreakRow] = [:]
    private(set) var settings: SettingsRow?
    /// Accepted writes in commit order — what realtime would broadcast.
    private(set) var feed: [OutboxPayload] = []

    /// Upsert with the `ignore_stale_writes` trigger: an older `updated_at`
    /// never replaces a newer row, and a skipped write broadcasts nothing.
    /// live_state adds the origin-device tie-break the SQL trigger applies, so
    /// server and clients agree on the winner of an exact stamp tie.
    func upsert(_ payload: OutboxPayload) {
        switch payload {
        case .liveState(let row):
            guard live.map({
                row.updated_at > $0.updated_at
                    || (row.updated_at == $0.updated_at && row.origin_device >= $0.origin_device)
            }) ?? true else { return }
            live = row
        case .session(let row):
            guard sessions[row.id].map({ row.updated_at >= $0.updated_at }) ?? true else { return }
            sessions[row.id] = row
        case .clockSession(let row):
            guard clocks[row.id].map({ row.updated_at >= $0.updated_at }) ?? true else { return }
            clocks[row.id] = row
        case .workBreak(let row):
            guard breaks[row.id].map({ row.updated_at >= $0.updated_at }) ?? true else { return }
            breaks[row.id] = row
        case .settings(let row):
            guard settings.map({ row.updated_at >= $0.updated_at }) ?? true else { return }
            settings = row
        }
        feed.append(payload)
    }
}

// MARK: - Simulated device

/// One device: real local stack, SyncService-equivalent glue.
@MainActor
final class SimDevice {
    let name: String
    let clock: TestClock
    let stamps: HybridStampClock
    let settingsStore: InMemorySettingsStore
    let history = InMemoryHistoryStore()
    let workdayStore = InMemoryWorkdayStore()
    let engine: PomodoroEngine
    let tracker: WorkdayTracker
    let outbox = SyncOutbox(fileURL: nil)
    let server: FakeSyncServer

    var online = true
    private var feedCursor = 0
    private var liveStateFloor = Date.distantPast
    private var settingsChangedAt: Date?
    private var isApplyingRemote = false
    private var orphanBreaks: [UUID: [WorkBreakRow]] = [:]

    init(
        name: String,
        server: FakeSyncServer,
        settings: TimerSettings = TimerSettings(focusDuration: 1_500, shortBreakDuration: 300, longBreakDuration: 900),
        clockOffset: TimeInterval = 0
    ) {
        self.name = name
        self.server = server
        self.clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000 + clockOffset))
        self.stamps = HybridStampClock(wallClock: { [clock] in clock.now })
        self.settingsStore = InMemorySettingsStore(settings: settings)
        self.engine = PomodoroEngine(
            settingsStore: settingsStore, history: history, clock: clock, stamps: stamps
        )
        self.tracker = WorkdayTracker(store: workdayStore, clock: clock, stamps: stamps)

        // The AppModel hook wiring, verbatim.
        tracker.onSessionChanged = { [weak self] session in self?.pushClockSession(session) }
        tracker.onSessionDeleted = { [weak self] id in self?.deleteClockSession(id: id) }
        tracker.onBreakDeleted = { [weak self] sessionID, entryID in
            self?.deleteBreak(sessionID: sessionID, entryID: entryID)
        }
        engine.onSessionStarted = { [weak self] kind, _ in
            guard let self else { return }
            tracker.sessionStarted(kind: kind)
            pushLiveState()
        }
        engine.onSessionInterrupted = { [weak self] _ in self?.pushLiveState() }
        engine.onSessionCompleted = { [weak self] session in
            guard let self else { return }
            pushSession(session)
            // AppModel's rule: a completion noticed late mirrors with its
            // stamp anchored at the actual end, not at "now".
            let lateBy = session.endedAt.map { clock.now.timeIntervalSince($0) } ?? 0
            if lateBy > 60, let ended = session.endedAt {
                pushLiveState(asOf: ended)
            } else {
                pushLiveState()
            }
        }
    }

    // MARK: Local intents that AppModel would forward

    func editSession(_ session: FocusSession) {
        var session = session
        session.updatedAt = stamps.next()
        history.update(session)
        pushSession(session)
    }

    func deleteSession(id: UUID) {
        history.delete(id: id)
        guard !isApplyingRemote else { return }
        outbox.enqueue(.session(SessionRow.tombstone(id: id, userID: "", at: stamps.next())))
        drainIfOnline()
    }

    func changeSettings(_ mutate: (inout TimerSettings) -> Void) {
        var updated = settingsStore.settings
        mutate(&updated)
        guard updated != settingsStore.settings else { return }
        settingsStore.settings = updated
        let stamp = stamps.next()
        settingsChangedAt = stamp
        outbox.enqueue(.settings(SettingsRow(user_id: "u", payload: updated, updated_at: stamp)))
        drainIfOnline()
    }

    // MARK: Push (SyncService equivalents)

    func pushLiveState(asOf: Date? = nil) {
        guard !isApplyingRemote else { return }
        let now = clock.now
        let stamp = asOf?.wireAligned ?? stamps.next()
        let pausedAt: Date? = engine.phase == .paused ? now : nil
        let row = LiveStateRow(
            user_id: "u",
            kind: engine.kind.rawValue,
            end_date: engine.phase == .idle ? nil : (pausedAt ?? now).addingTimeInterval(engine.remaining),
            is_running: engine.isRunning,
            paused_at: pausedAt,
            cycle_position: engine.cyclePosition,
            session_id: engine.currentSessionID,
            origin_device: name,
            updated_at: stamp
        )
        liveStateFloor = max(liveStateFloor, stamp)
        outbox.enqueue(.liveState(row))
        drainIfOnline()
    }

    private func pushSession(_ session: FocusSession) {
        guard !isApplyingRemote else { return }
        outbox.enqueue(.session(SessionRow(session: session, userID: "")))
        drainIfOnline()
    }

    private func pushClockSession(_ session: ClockSession) {
        guard !isApplyingRemote else { return }
        outbox.enqueue(.clockSession(ClockSessionRow(session: session, userID: "")))
        for entry in session.breaks {
            outbox.enqueue(.workBreak(WorkBreakRow(entry: entry, sessionID: session.id, userID: "")))
        }
        drainIfOnline()
    }

    private func deleteClockSession(id: UUID) {
        guard !isApplyingRemote else { return }
        outbox.enqueue(.clockSession(ClockSessionRow.tombstone(id: id, userID: "", at: stamps.next())))
        drainIfOnline()
    }

    private func deleteBreak(sessionID: UUID, entryID: UUID) {
        guard !isApplyingRemote else { return }
        outbox.enqueue(.workBreak(WorkBreakRow.tombstone(id: entryID, sessionID: sessionID, userID: "", at: stamps.next())))
        drainIfOnline()
    }

    // MARK: Transport

    func drainIfOnline() {
        guard online else { return }
        while let entry = outbox.first {
            server.upsert(entry.payload.addressed(to: "u"))
            outbox.markSent(entry.id)
        }
    }

    /// Deliver pending realtime events.
    func pump() {
        guard online else { return }
        while feedCursor < server.feed.count {
            let payload = server.feed[feedCursor]
            feedCursor += 1
            apply(payload)
        }
    }

    /// The connect sequence: drain, reconcile, pull. (`subscribe` is the feed
    /// cursor, which `pump()` advances.) Events broadcast while offline are
    /// GONE — production realtime has no replay — so the cursor jumps to the
    /// present and the pull carries the catch-up, exactly as in production.
    func connect() {
        guard online else { return }
        feedCursor = server.feed.count
        drainIfOnline()
        reconcile()
        pullAll()
    }

    private func reconcile() {
        if let changedAt = settingsChangedAt {
            let theirs = server.settings?.updated_at
            if theirs == nil || changedAt > theirs! {
                outbox.enqueue(.settings(SettingsRow(user_id: "u", payload: settingsStore.settings, updated_at: changedAt)))
            }
        }
        for session in tracker.sessions() {
            if isWorthUploading(session.updatedAt, against: server.clocks[session.id]?.updated_at) {
                outbox.enqueue(.clockSession(ClockSessionRow(session: session, userID: "")))
            }
            for entry in session.breaks {
                if isWorthUploading(entry.updatedAt ?? entry.startedAt, against: server.breaks[entry.id]?.updated_at) {
                    outbox.enqueue(.workBreak(WorkBreakRow(entry: entry, sessionID: session.id, userID: "")))
                }
            }
        }
        for session in history.all() {
            if isWorthUploading(session.updatedAt, against: server.sessions[session.id]?.updated_at) {
                outbox.enqueue(.session(SessionRow(session: session, userID: "")))
            }
        }
        if engine.phase != .idle { pushLiveState() }
        drainIfOnline()
    }

    private func isWorthUploading(_ mine: Date?, against theirs: Date?) -> Bool {
        guard let theirs else { return true }
        return (mine ?? .distantPast).wireAligned > theirs
    }

    func pullAll() {
        for row in server.sessions.values { applySessionRow(row) }
        if let row = server.settings { applySettingsRow(row) }
        for row in server.clocks.values { applyClockRow(row) }
        for row in server.breaks.values { applyBreakRow(row) }
        if let row = server.live { applyLiveRow(row) }
    }

    // MARK: Apply (SyncService equivalents)

    /// Internal so tests can hand-deliver rows in adversarial orders (e.g. a
    /// break before its parent session) — realtime makes no ordering promise
    /// across tables.
    func apply(_ payload: OutboxPayload) {
        switch payload {
        case .liveState(let row): applyLiveRow(row)
        case .session(let row): applySessionRow(row)
        case .clockSession(let row): applyClockRow(row)
        case .workBreak(let row): applyBreakRow(row)
        case .settings(let row): applySettingsRow(row)
        }
    }

    private func applyLiveRow(_ row: LiveStateRow) {
        guard row.origin_device != name else { return }
        guard row.updated_at > liveStateFloor
            || (row.updated_at == liveStateFloor && row.origin_device > name)
        else { return }
        liveStateFloor = row.updated_at
        stamps.observe(row.updated_at)
        withRemoteApplication {
            engine.applyRemoteState(
                cyclePosition: row.cycle_position,
                isRunning: row.is_running,
                endDate: row.end_date,
                pausedAt: row.paused_at,
                sessionID: row.session_id
            )
        }
    }

    private func applySessionRow(_ row: SessionRow) {
        stamps.observe(row.updated_at)
        withRemoteApplication {
            let mine = history.all().first { $0.id == row.id }?.updatedAt ?? .distantPast
            guard row.updated_at >= mine else { return }
            if row.deleted_at != nil {
                history.delete(id: row.id)
            } else {
                history.upsert(row.focusSession)
            }
        }
    }

    private func applyClockRow(_ row: ClockSessionRow) {
        stamps.observe(row.updated_at)
        withRemoteApplication {
            guard row.deleted_at != nil else {
                tracker.applyRemote(row.clockSession)
                if let waiting = orphanBreaks.removeValue(forKey: row.id) {
                    for orphan in waiting {
                        tracker.applyRemoteBreak(sessionID: row.id, entry: orphan.workBreak)
                    }
                }
                return
            }
            let mine = tracker.sessions().first { $0.id == row.id }?.updatedAt ?? .distantPast
            guard row.updated_at >= mine else { return }
            tracker.deleteLocally(id: row.id)
            orphanBreaks[row.id] = nil
        }
    }

    private func applyBreakRow(_ row: WorkBreakRow) {
        stamps.observe(row.updated_at)
        withRemoteApplication {
            if row.deleted_at != nil {
                tracker.deleteBreakLocally(
                    sessionID: row.clock_session_id, entryID: row.id,
                    unlessEditedAfter: row.updated_at
                )
                orphanBreaks[row.clock_session_id]?.removeAll { $0.id == row.id }
            } else if !tracker.applyRemoteBreak(sessionID: row.clock_session_id, entry: row.workBreak) {
                orphanBreaks[row.clock_session_id, default: []].removeAll { $0.id == row.id }
                orphanBreaks[row.clock_session_id, default: []].append(row)
            }
        }
    }

    private func applySettingsRow(_ row: SettingsRow) {
        stamps.observe(row.updated_at)
        let mine = settingsChangedAt ?? .distantPast
        guard row.updated_at >= mine else { return }
        settingsChangedAt = row.updated_at
        guard row.payload != settingsStore.settings else { return }
        withRemoteApplication { settingsStore.settings = row.payload }
    }

    private func withRemoteApplication(_ body: () -> Void) {
        isApplyingRemote = true
        body()
        isApplyingRemote = false
    }
}

// MARK: - The world

@MainActor
struct SyncWorld {
    let server = FakeSyncServer()
    var devices: [SimDevice] = []

    init(deviceCount: Int, settings: TimerSettings? = nil, skews: [TimeInterval]? = nil) {
        for index in 0..<deviceCount {
            let device = SimDevice(
                name: "device-\(UnicodeScalar(65 + index)!)", // A, B, C…
                server: server,
                settings: settings ?? TimerSettings(focusDuration: 1_500, shortBreakDuration: 300, longBreakDuration: 900),
                clockOffset: skews?[index] ?? 0
            )
            devices.append(device)
        }
    }

    /// Move world time forward in lockstep; every running engine ticks once.
    func advanceAll(by seconds: TimeInterval) {
        for device in devices { device.clock.advance(by: seconds) }
        pumpAll()
    }

    /// Deliver pending feed events until nothing new appears anywhere. One
    /// application can enqueue nothing (applies are echo-free), but a pump on
    /// one device can be interleaved with another's drain, so run to fixpoint.
    func pumpAll() {
        var lastFeedCount = -1
        while lastFeedCount != server.feed.count {
            lastFeedCount = server.feed.count
            for device in devices {
                device.drainIfOnline()
                device.pump()
            }
        }
    }

    func settle() {
        for device in devices where device.online {
            device.connect()
        }
        pumpAll()
        for device in devices where device.online {
            device.pullAll()
        }
    }
}

// MARK: - Convergence assertions

@MainActor
private func expectConverged(_ world: SyncWorld, sourceLocation: SourceLocation = #_sourceLocation) {
    /// Essential content, normalized for comparison.
    func historyFingerprint(_ device: SimDevice) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: device.history.all().map {
            ($0.id, "\($0.kind.rawValue)|\($0.plannedDuration)|\($0.startedAt.timeIntervalSince1970)|\($0.endedAt?.timeIntervalSince1970 ?? -1)|\($0.completed)")
        })
    }
    func workdayFingerprint(_ device: SimDevice) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: device.tracker.sessions().map { session in
            let breaks = session.breaks
                .sorted { $0.id.uuidString < $1.id.uuidString }
                .map { "\($0.id):\($0.startedAt.timeIntervalSince1970)-\($0.endedAt?.timeIntervalSince1970 ?? -1)" }
                .joined(separator: ",")
            return (session.id, "\(session.clockedInAt.timeIntervalSince1970)|\(session.clockedOutAt?.timeIntervalSince1970 ?? -1)|[\(breaks)]")
        })
    }

    let first = world.devices[0]
    for other in world.devices.dropFirst() {
        #expect(
            historyFingerprint(first) == historyFingerprint(other),
            "history diverged between \(first.name) and \(other.name)",
            sourceLocation: sourceLocation
        )
        #expect(
            workdayFingerprint(first) == workdayFingerprint(other),
            "workdays diverged between \(first.name) and \(other.name)",
            sourceLocation: sourceLocation
        )
        #expect(
            first.settingsStore.settings == other.settingsStore.settings,
            "settings diverged between \(first.name) and \(other.name)",
            sourceLocation: sourceLocation
        )
    }

    // Devices also agree with the server's live rows.
    let liveServerSessions = Set(world.server.sessions.values.filter { $0.deleted_at == nil }.map(\.id))
    #expect(
        Set(first.history.all().map(\.id)) == liveServerSessions,
        "history diverged from the server",
        sourceLocation: sourceLocation
    )
    let liveServerClocks = Set(world.server.clocks.values.filter { $0.deleted_at == nil }.map(\.id))
    #expect(
        Set(first.tracker.sessions().map(\.id)) == liveServerClocks,
        "workdays diverged from the server",
        sourceLocation: sourceLocation
    )
}

// MARK: - Deterministic regressions for the audited defects

@MainActor
struct SyncScenarioTests {

    /// Audit: "Completion pushes a stale pre-advance snapshot… every peer
    /// regresses to the phase just finished." Nothing advances at the finish any
    /// more, so what both devices must agree on is the *overrun* — and the
    /// Pomodoro must still exist exactly once.
    @Test func completionLeavesBothDevicesOverrunningAndRecordsOnce() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        a.engine.start()
        world.pumpAll()
        #expect(b.engine.isRunning)
        #expect(b.engine.isMirroring)

        world.advanceAll(by: 1_501)
        world.pumpAll()

        for device in [a, b] {
            #expect(device.engine.isOverrunning, "\(device.name) should be over its end")
            #expect(device.engine.cyclePosition == 0, "\(device.name) advanced on its own")
        }
        #expect(a.history.all().count == 1)
        #expect(b.history.all().count == 1)
        #expect(a.history.all().map(\.id) == b.history.all().map(\.id))
        #expect(world.server.sessions.count == 1)
    }

    /// Audit: "Whole-row LWW lets a stale offline device erase the other
    /// device's breaks and clock-out." The break now survives as its own row;
    /// the later clock-out wins the session row.
    @Test func offlineClockOutDoesNotEraseTheOtherDevicesBreaks() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        a.tracker.clockIn()
        world.pumpAll()
        #expect(b.tracker.isClockedIn)

        b.online = false

        // A takes a real break and clocks out at +8h.
        world.advanceAll(by: 3_600)
        a.tracker.startBreak()
        world.advanceAll(by: 900)
        a.tracker.endBreak()
        world.advanceAll(by: 6 * 3_600)
        a.tracker.clockOut()
        world.pumpAll()

        // B — still holding the breakless morning copy — clocks out later.
        world.advanceAll(by: 1_800)
        b.tracker.clockOut()

        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        expectConverged(world)
        let day = world.devices[0].tracker.sessions()[0]
        #expect(day.breaks.count == 1, "the break was erased")
        #expect(day.breaks[0].endedAt != nil)
        // B's clock-out was the later write, so it owns the session row.
        #expect(day.clockedOutAt == b.clock.now)
    }

    /// Audit: "A live-row upsert can never clear deleted_at — an edit that
    /// should beat a tombstone half-resurrects and permanently diverges."
    @Test func anEditNewerThanATombstoneResurrectsTheRowEverywhere() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        // A shared recorded session.
        a.engine.start()
        world.advanceAll(by: 1_501)
        world.pumpAll()
        let sessionID = a.history.all()[0].id

        // B goes offline still holding it; A deletes it; B edits it later.
        b.online = false
        a.deleteSession(id: sessionID)
        world.pumpAll()
        #expect(world.server.sessions[sessionID]?.deleted_at != nil)

        world.advanceAll(by: 60)
        var edited = b.history.all().first { $0.id == sessionID }!
        edited.plannedDuration = 1_200
        b.editSession(edited)

        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        // The edit outranks the tombstone: alive everywhere, deleted nowhere.
        #expect(world.server.sessions[sessionID]?.deleted_at == nil)
        #expect(a.history.all().contains { $0.id == sessionID })
        #expect(b.history.all().contains { $0.id == sessionID })
        expectConverged(world)
    }

    /// …and the mirror case: a tombstone newer than the last edit deletes
    /// everywhere, offline or not.
    @Test func aNewerTombstoneDeletesEverywhereDespiteAnOfflineCopy() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        a.engine.start()
        world.advanceAll(by: 1_501)
        world.pumpAll()
        let sessionID = a.history.all()[0].id

        // B offline edits FIRST; A deletes LATER; the deletion must win.
        b.online = false
        var edited = b.history.all().first { $0.id == sessionID }!
        edited.plannedDuration = 1_200
        b.editSession(edited)

        world.advanceAll(by: 60)
        a.deleteSession(id: sessionID)
        world.pumpAll()

        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        #expect(world.server.sessions[sessionID]?.deleted_at != nil)
        #expect(!a.history.all().contains { $0.id == sessionID })
        #expect(!b.history.all().contains { $0.id == sessionID }, "the offline copy resurrected the deleted session")
        expectConverged(world)
    }

    /// Audit: "Auto-start resets isMirroring on both devices — every
    /// subsequent session is recorded twice." With shared session ids the
    /// whole auto-advancing chain must stay single-copy.
    @Test func autoStartChainsRecordEverySessionExactlyOnce() {
        let settings = TimerSettings(
            focusDuration: 1_500, shortBreakDuration: 300, longBreakDuration: 900,
            sessionsUntilLongBreak: 4, autoStartBreaks: true, autoStartFocus: true
        )
        // A hair of clock skew, as in life; the HLC absorbs it.
        let world = SyncWorld(deviceCount: 2, settings: settings, skews: [0, 0.05])
        let (a, b) = (world.devices[0], world.devices[1])

        a.engine.start()
        world.pumpAll()
        #expect(b.engine.isRunning)

        // focus -> break -> focus -> break. Each phase runs out and waits; the
        // user continues on device A, and auto-start takes the next one from
        // there. The mirror must not record a second copy of any of them.
        for seconds in [1_501.0, 301.0, 1_501.0, 301.0] {
            world.advanceAll(by: seconds)
            world.pumpAll()
            a.engine.advance()  // the user's Continue, on one device only
            world.pumpAll()
        }

        world.settle()

        let kinds = world.devices[0].history.all().map(\.kind)
        #expect(world.server.sessions.count == 4, "auto-start duplicated sessions: \(world.server.sessions.count) recorded")
        #expect(kinds.filter { $0 == .focus }.count == 2)
        #expect(kinds.filter { $0 != .focus }.count == 2)
        expectConverged(world)
    }

    /// Audit: "live_state writes race — an older state can end up final."
    /// The outbox coalesces the burst and the floor guard drops stale rows,
    /// so a pause-then-resume flurry leaves every device running.
    @Test func rapidPauseResumeLeavesEveryDeviceRunning() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        a.engine.start()
        world.pumpAll()

        a.engine.pause()
        a.engine.resume()
        a.engine.pause()
        a.engine.resume()
        world.pumpAll()

        #expect(a.engine.isRunning)
        #expect(b.engine.isRunning, "the peer settled on a stale intermediate state")
        guard case .liveState(let last)? = world.server.feed.last(where: {
            if case .liveState = $0 { return true } else { return false }
        }) else {
            Issue.record("no live row on the server")
            return
        }
        #expect(last.is_running)
    }

    /// Audit: "LWW decided by unsynchronized wall clocks — a fast device
    /// silently reverts the other's newer edits." The hybrid clock keeps
    /// causality: an edit made after seeing a fast peer's write outranks it.
    @Test func aFastClockCannotBuryALaterEdit() {
        let world = SyncWorld(deviceCount: 2, skews: [0, 3_600]) // B runs 1h fast
        let (a, b) = (world.devices[0], world.devices[1])

        a.tracker.clockIn()
        world.pumpAll()

        // B (clock 1h ahead) edits the clock-in; A sees it, then re-edits.
        let id = b.tracker.sessions()[0].id
        b.tracker.updateClockSession(
            id: id,
            clockedInAt: b.tracker.sessions()[0].clockedInAt.addingTimeInterval(-600),
            clockedOutAt: nil
        )
        world.pumpAll()

        let intended = a.tracker.sessions()[0].clockedInAt.addingTimeInterval(300)
        a.tracker.updateClockSession(id: id, clockedInAt: intended, clockedOutAt: nil)
        world.pumpAll()
        world.settle()

        expectConverged(world)
        #expect(
            world.devices[1].tracker.sessions()[0].clockedInAt == intended,
            "the fast clock's stale edit buried the newer one"
        )
    }

    /// Break rows and their parent session can arrive in either order; a break
    /// landing first must wait for its parent, not vanish. Delivered by hand
    /// in the adversarial order — the natural feed happens to always carry the
    /// parent first, which would leave the orphan buffer untested.
    @Test func aBreakArrivingBeforeItsParentSessionIsHeldNotDropped() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        b.online = false
        a.tracker.clockIn()
        a.tracker.startBreak()
        world.advanceAll(by: 300)
        a.tracker.endBreak()

        let day = a.tracker.sessions()[0]
        let entry = day.breaks[0]

        // Deliver the break FIRST, then the session, then a second copy of the
        // break (the pull) — the first must be held, not dropped or crashed on.
        b.online = true
        b.apply(.workBreak(WorkBreakRow(entry: entry, sessionID: day.id, userID: "u")))
        #expect(b.tracker.sessions().isEmpty)
        b.apply(.clockSession(ClockSessionRow(session: day, userID: "u")))

        #expect(b.tracker.sessions().count == 1)
        #expect(b.tracker.sessions()[0].breaks.count == 1, "the break was dropped as an orphan")
        #expect(b.tracker.sessions()[0].breaks[0].endedAt != nil)
    }

    /// Deleting a workday must stick, exactly like deleting a session — the
    /// same offline-copy interleavings the audit found resurrecting rows.
    @Test func clockSessionTombstonesBeatOfflineCopiesAndLoseToNewerEdits() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        a.tracker.clockIn()
        world.advanceAll(by: 3_600)
        a.tracker.clockOut()
        world.pumpAll()
        let dayID = a.tracker.sessions()[0].id

        // B offline, holding a copy. A deletes the day. B reconnects: the
        // tombstone must win over B's mere possession.
        b.online = false
        a.tracker.delete(id: dayID)
        world.pumpAll()

        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        #expect(!a.tracker.sessions().contains { $0.id == dayID })
        #expect(!b.tracker.sessions().contains { $0.id == dayID }, "the offline copy resurrected the deleted workday")
        expectConverged(world)

        // And the reverse: an edit stamped AFTER the tombstone resurrects.
        a.tracker.clockIn()
        world.advanceAll(by: 60)
        a.tracker.clockOut()
        world.pumpAll()
        let secondID = a.tracker.sessions().first!.id

        b.online = false
        a.tracker.delete(id: secondID)
        world.pumpAll()
        world.advanceAll(by: 60)
        b.tracker.updateClockSession(
            id: secondID,
            clockedInAt: b.tracker.sessions().first!.clockedInAt,
            clockedOutAt: b.clock.now
        )
        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        #expect(a.tracker.sessions().contains { $0.id == secondID }, "the newer edit lost to an older tombstone")
        expectConverged(world)
    }

    /// A device that slept through a session's deadline completes it hours
    /// late. Its live mirror must be stamped at the session's actual end — a
    /// fresh stamp would bury everything the other device did in between.
    @Test func aLateCompletionDoesNotClobberThePeersCurrentTimer() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        // Both mirror focus X…
        a.engine.start()
        world.pumpAll()
        #expect(b.engine.isRunning)

        // …then B suspends (offline, no ticks). A completes X on time and is
        // deep into new work two hours later.
        b.online = false
        world.devices[0].clock.advance(by: 1_501) // A completes X
        a.pump()
        world.devices[0].clock.advance(by: 7_200)
        a.engine.goToNextPhase()
        a.engine.start() // A's current session, stamped ~now
        a.drainIfOnline()

        // B wakes: its clock jumps past X's deadline, the tick fires the
        // late completion, and it reconnects.
        b.clock.jump(by: 1_501 + 7_200)
        b.clock.fireTick()
        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        #expect(a.engine.isRunning, "the late completion clobbered A's current session")
        #expect(b.engine.isRunning, "B failed to adopt A's current session")
        #expect(b.engine.isMirroring)
        // X exists exactly once, ended at its deadline — not at B's wake time.
        let copies = a.history.all().filter { $0.kind == .focus && $0.plannedDuration == 1_500 }
        #expect(copies.count == 1)
        if let x = copies.first, let ended = x.endedAt {
            #expect(abs(ended.timeIntervalSince(x.startedAt) - 1_500) < 2, "X's end time drifted to the wake time")
        }
        expectConverged(world)
    }

    /// Settings changed while offline must win over the older server copy on
    /// reconnect (the pull used to clobber them, then mark them adopted).
    @Test func offlineSettingsChangesSurviveTheReconnectPull() {
        let world = SyncWorld(deviceCount: 2)
        let (a, b) = (world.devices[0], world.devices[1])

        a.changeSettings { $0.focusDuration = 2_000 }
        world.pumpAll()
        #expect(b.settingsStore.settings.focusDuration == 2_000)

        b.online = false
        world.advanceAll(by: 60)
        b.changeSettings { $0.focusDuration = 1_000 }

        b.online = true
        b.connect()
        world.pumpAll()
        a.pullAll(); b.pullAll()

        #expect(a.settingsStore.settings.focusDuration == 1_000)
        #expect(b.settingsStore.settings.focusDuration == 1_000, "the reconnect pull clobbered the offline change")
    }
}

// MARK: - Randomized convergence sweep

/// Deterministic seeded RNG (SplitMix64), so a failure names its seed.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@MainActor
struct SyncConvergenceSweep {

    @Test(arguments: 0..<24)
    func randomInterleavingsConverge(seed: Int) {
        var rng = SeededRNG(state: UInt64(seed) &* 0x5851F42D4C957F2D &+ 1)
        let world = SyncWorld(
            deviceCount: 2 + seed % 2, // two or three devices
            skews: [0, Double(seed % 7) * 0.4, 90].map { $0 } // mild skews
        )

        for _ in 0..<60 {
            let device = world.devices.randomElement(using: &rng)!
            switch Int.random(in: 0..<14, using: &rng) {
            case 0: device.tracker.clockIn()
            case 1: device.tracker.clockOut()
            case 2: device.tracker.toggleBreak()
            case 3: device.engine.toggle()
            case 4: device.engine.reset()
            case 5: device.engine.goToNextPhase()
            case 6: // finish whatever is running
                world.advanceAll(by: 1_502)
            case 7: // a short stretch of time passing
                world.advanceAll(by: Double(Int.random(in: 10...600, using: &rng)))
            case 8: // edit a random recorded session
                if let session = device.history.all().randomElement(using: &rng) {
                    var edited = session
                    edited.plannedDuration = Double(Int.random(in: 300...3_000, using: &rng))
                    device.editSession(edited)
                }
            case 9: // delete a random recorded session
                if let session = device.history.all().randomElement(using: &rng) {
                    device.deleteSession(id: session.id)
                }
            case 10: // delete a random break — or, sometimes, a whole workday
                if Bool.random(using: &rng), let session = device.tracker.sessions().randomElement(using: &rng) {
                    device.tracker.delete(id: session.id)
                } else if let session = device.tracker.sessions().randomElement(using: &rng),
                          let entry = session.breaks.randomElement(using: &rng) {
                    device.tracker.deleteBreak(sessionID: session.id, entryID: entry.id)
                }
            case 11: // drop or restore connectivity
                if device.online {
                    device.online = false
                } else {
                    device.online = true
                    device.connect()
                }
            case 12: device.changeSettings {
                $0.focusDuration = Double(Int.random(in: 600...3_000, using: &rng))
            }
            default:
                world.pumpAll()
            }
        }

        // Everyone back online and quiescent: total convergence, no exceptions.
        for device in world.devices where !device.online {
            device.online = true
        }
        world.settle()
        world.settle() // a second round proves quiescence (no write ping-pong)

        expectConverged(world)
        #expect(world.devices[0].outbox.isEmpty)
    }
}
