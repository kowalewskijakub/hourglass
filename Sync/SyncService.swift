import Foundation
import Observation
import Supabase
import HourglassCore

/// Real-time sync across devices, backed by Supabase.
///
/// The design in one paragraph: every outgoing write passes through a durable,
/// ordered ``SyncOutbox`` drained by a single worker (no fire-and-forget, no
/// reordering, nothing lost offline — deletions included, as tombstone rows).
/// Conflicts are last-writer-wins on `updated_at` stamps issued by a
/// ``HybridStampClock`` (never repeats, never behind a stamp seen from the
/// server), enforced client-side at apply time *and* server-side by a trigger
/// that ignores stale writes. The running timer mirrors through a `live_state`
/// row carrying the session's identity, so every device that witnesses a
/// completion records it under the same id and upserts collapse the copies.
@MainActor
@Observable
final class SyncService {

    enum State: Equatable {
        case off
        /// Syncing; `pairing` is a code currently on offer to another device.
        case syncing(pairing: PairingCode?)
        /// The device had access and lost it (token revoked or expired). The
        /// account and its data still exist — re-pairing from another device
        /// reconnects to them, which is why this is not `.failed`: the worst
        /// possible "recovery" here would be silently minting a fresh empty
        /// account and splitting the user's devices across two.
        case sessionLost
        case failed(String)
    }

    /// A pairing code together with the moment it stops working.
    struct PairingCode: Equatable {
        let code: String
        let expiresAt: Date

        var isExpired: Bool { Date() >= expiresAt }
        var secondsRemaining: Int { max(0, Int(expiresAt.timeIntervalSinceNow.rounded(.up))) }
    }

    /// Matches the 5-minute window enforced by `create_pairing` in the database.
    static let pairingLifetime: TimeInterval = 5 * 60

    /// The schema this build speaks. Checked against the server's
    /// `schema_version` at connect: writing v2 rows into a v1 database fails in
    /// confusing ways (rejected tombstones, missing tables), so an outdated
    /// server pauses sync with an actionable message instead.
    static let requiredSchemaVersion = 2

    private(set) var state: State = .off
    /// Set while a network call is in flight, so the UI can show progress.
    private(set) var isBusy = false
    /// The most recent write or read failure. Cleared when the outbox fully
    /// drains — not by the next unrelated success, which used to hide the one
    /// signal that a device was diverging.
    private(set) var lastSyncError: String?
    /// Writes waiting to reach the server (shown in Settings).
    var pendingWrites: Int { outbox.count }
    /// Whether this device has ever completed a sync — drives the recovery UI:
    /// a device that had an account must never be offered a silent fresh start.
    private(set) var hasSyncedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasSyncedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasSyncedKey) }
    }

    @ObservationIgnored private let client: SupabaseClient
    @ObservationIgnored private let model: AppModel
    /// Identifies this device so we can ignore the echo of our own writes.
    @ObservationIgnored private let deviceID = SyncService.resolveDeviceID()
    @ObservationIgnored private let outbox: SyncOutbox
    /// Shared with the engine and tracker via `AppModel` — one stamp order for
    /// the whole device.
    @ObservationIgnored private var stamps: HybridStampClock { model.stamps }

    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var listenerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var connectRetryTask: Task<Void, Never>?
    /// Whether the connect-time reconcile has fully succeeded since the last
    /// connect. Until it has, rows changed while sync was off exist on this
    /// device only — refresh and channel recovery keep retrying it.
    @ObservationIgnored private var reconciled = false

    /// Suppresses push-on-change while we're applying a remote update.
    @ObservationIgnored private var isApplyingRemote = false
    /// The newest live-state stamp this device has pushed or applied. A
    /// realtime event or pull below this floor is stale — applying it used to
    /// kill a running timer with a day-old idle row.
    @ObservationIgnored private var liveStateFloor: Date = .distantPast
    /// Break rows whose parent clock session hasn't arrived yet; flushed when
    /// it does. The two travel as separate rows and can land in either order.
    @ObservationIgnored private var orphanBreaks: [UUID: [WorkBreakRow]] = [:]

    private static let hasSyncedKey = "hourglass.hasSyncedBefore"
    private static let enabledKey = "hourglass.syncEnabled"

    /// Whether the user wants sync running. Survives relaunch, so "paused"
    /// stays paused. Distinct from `isSignedIn`: pausing keeps the session —
    /// signing out of an anonymous account would orphan the data behind it.
    private(set) var syncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    init(model: AppModel) {
        self.model = model
        self.outbox = SyncOutbox(fileURL: SyncOutbox.defaultFileURL())
        client = SupabaseClient(
            supabaseURL: SyncConfig.supabaseURL,
            supabaseKey: SyncConfig.supabaseKey,
            options: SupabaseClientOptions(
                // The SDK's own date encoder TRUNCATES fractional seconds at
                // the binary representation — about half of all stamps print
                // one millisecond low, and a stamp that doesn't survive its
                // round trip breaks every LWW equality in the protocol. Ours
                // prints the exact rounded millisecond.
                db: SupabaseClientOptions.DatabaseOptions(encoder: SyncWireEncoding.encoder()),
                // Keep the session out of the Keychain: an ad-hoc-signed Mac app
                // changes signature every build, so the Keychain re-prompts each
                // time. A file we own avoids that (and iCloud Keychain) entirely.
                auth: SupabaseClientOptions.AuthOptions(storage: FileSessionStorage())
            )
        )
        migrateLegacyPendingDeletes()
    }

    var isSignedIn: Bool { client.auth.currentSession != nil }

    // MARK: - Auth (anonymous account + device pairing)
    //
    // There is no account and no password: the first device creates an
    // anonymous user, and any other device joins it by redeeming a short-lived
    // pairing code. The code buys the joining device a **login link of its
    // own** (minted server-side by the `claim-pairing` Edge Function), so each
    // device holds an independent session. Sharing the first device's refresh
    // token — the previous design — put both devices in one rotating token
    // family, and the server's reuse detection signed them both out within the
    // hour.

    /// Turns sync on: first time by creating an anonymous account, later by
    /// resuming the account this device already holds.
    func enableSync() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if !isSignedIn {
                // A device that ever synced held the only kind of key an
                // anonymous account has. Quietly minting a fresh one here
                // would split the user's devices across two accounts, both
                // showing a green "Syncing" — recovery is re-pairing, never a
                // silent new identity.
                guard !hasSyncedBefore else {
                    state = .sessionLost
                    return
                }
                try await client.auth.signInAnonymously()
            }
            syncEnabled = true
            state = .syncing(pairing: nil)
            await startSyncing()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Publishes a one-time code another device can use to join this account.
    func createPairingCode() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if !isSignedIn { try await client.auth.signInAnonymously() }
            let code = Self.makePairingCode()
            try await client
                .rpc("create_pairing", params: ["p_code": code])
                .execute()
            state = .syncing(pairing: PairingCode(code: code, expiresAt: Date().addingTimeInterval(Self.pairingLifetime)))
            if !syncEnabled {
                syncEnabled = true
                await startSyncing()
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private struct ClaimPairingResponse: Decodable {
        var token_hash: String?
        var error: String?
    }

    /// Joins the account that produced `code`, adopting its data.
    func redeemPairingCode(_ code: String) async {
        isBusy = true
        defer { isBusy = false }
        let normalized = Self.normalize(code)
        // A failed redeem — a typo, flaky Wi-Fi — must not bury the state the
        // user is recovering FROM: demoting .sessionLost to .failed used to
        // make the re-pair UI unreachable after one mistake.
        let fallback = state
        do {
            let response: ClaimPairingResponse = try await client.functions.invoke(
                "claim-pairing",
                options: FunctionInvokeOptions(body: ["code": normalized])
            )
            guard let tokenHash = response.token_hash, !tokenHash.isEmpty else {
                lastSyncError = response.error ?? "That code is wrong, already used, or expired."
                state = fallback
                return
            }
            // The token hash verifies into a session of this device's own — its
            // own refresh-token family, unentangled from the other device's.
            try await client.auth.verifyOTP(tokenHash: tokenHash, type: .magiclink)
            syncEnabled = true
            state = .syncing(pairing: nil)
            await startSyncing()
        } catch {
            lastSyncError = error.localizedDescription
            state = fallback
        }
    }

    /// Pauses sync but keeps the session. Signing out here would orphan the
    /// account: it is anonymous, so a session is the only key that opens it.
    func pauseSync() async {
        syncEnabled = false
        await stopSyncing()
        state = .off
    }

    /// Signs this device out of the account for good. Destructive when this is
    /// the last paired device — the UI warns before calling it.
    ///
    /// `.local` scope, deliberately: the SDK's default is `.global`, which
    /// revokes EVERY session of the user — each paired device holds its own —
    /// and an anonymous account with zero sessions left is unreachable
    /// forever. Disconnecting one device must never orphan the rest.
    func disconnect() async {
        syncEnabled = false
        await stopSyncing() // cancels the auth listener BEFORE the sign-out event fires
        try? await client.auth.signOut(scope: .local)
        hasSyncedBefore = false
        outbox.clear()
        state = .off
    }

    /// Resumes an existing session at launch.
    func restore() async {
        guard syncEnabled, isSignedIn else { return }
        state = .syncing(pairing: nil)
        await startSyncing()
    }

    /// Push, then re-read. Called on foreground/wake, when realtime may have
    /// missed events. Push first — pulling first would overwrite local changes
    /// whose writes haven't landed yet with stale server state.
    func refresh() async {
        guard syncEnabled, isSignedIn else { return }
        await drainNow()
        if !reconciled { await reconcile() }
        await pullAll()
    }

    /// Clears a pairing code that has run out, so the UI stops offering it.
    func discardExpiredPairingCode() {
        guard case .syncing(let pairing) = state, let pairing, pairing.isExpired else { return }
        state = .syncing(pairing: nil)
    }

    // MARK: Pairing codes

    /// Unambiguous alphabet — no 0/O/1/I, so a code is easy to read aloud.
    private static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    private static func makePairingCode() -> String {
        String((0..<8).map { _ in codeAlphabet.randomElement()! })
    }

    /// Accepts what the user actually types: lower case, spaces, dashes.
    static func normalize(_ code: String) -> String {
        code.uppercased().filter { codeAlphabet.contains($0) }
    }

    /// `ABCD-EFGH` — easier to read off another screen.
    static func formatted(_ code: String) -> String {
        guard code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 4)
        return "\(code[code.startIndex..<mid])-\(code[mid...])"
    }

    // MARK: - Sync lifecycle

    private func startSyncing() async {
        connectRetryTask?.cancel()
        connectRetryTask = nil
        switch await checkSchema() {
        case .outdated(let message):
            state = .failed(message)
            return
        case .unreachable(let message):
            // Launching on a train must not kill sync for the whole run.
            // Surface it, keep the state, and try again shortly.
            lastSyncError = message
            scheduleConnectRetry()
            return
        case .current:
            break
        }
        startAuthListener()
        reconciled = false
        // Ordered writes first — including tombstones queued while offline —
        // so nothing local is buried by the pull that follows.
        await drainNow()
        await reconcile()
        await subscribe()
        await pullAll()
        hasSyncedBefore = true
        // A reconcile abandoned on a failed stamp read would strand every row
        // changed while sync was off — silently, behind a green "Syncing".
        if !reconciled { scheduleConnectRetry() }
    }

    /// Re-runs the connect sequence after a transient failure. One retry task
    /// at a time; each pass either completes the connect or schedules the next.
    private func scheduleConnectRetry() {
        guard connectRetryTask == nil else { return }
        connectRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self else { return }
            self.connectRetryTask = nil
            guard !Task.isCancelled, self.syncEnabled, self.isSignedIn else { return }
            await self.startSyncing()
        }
    }

    private func stopSyncing() async {
        authTask?.cancel()
        authTask = nil
        drainTask?.cancel()
        drainTask = nil
        connectRetryTask?.cancel()
        connectRetryTask = nil
        await teardownChannel()
    }

    private func teardownChannel() async {
        statusTask?.cancel()
        statusTask = nil
        listenerTasks.forEach { $0.cancel() }
        listenerTasks.removeAll()
        if let channel { await client.removeChannel(channel) }
        channel = nil
    }

    private enum SchemaCheck {
        case current
        /// The database genuinely predates this build — a user action fixes it.
        case outdated(String)
        /// The answer couldn't be read — retry, don't declare anything.
        case unreachable(String)
    }

    /// Refuses to speak v2 rows to a v1 database. The failure is loud and
    /// actionable; the old behaviour — every tombstone silently rejected —
    /// looked like "deleted things come back", for weeks. Only a definitive
    /// answer condemns the schema: a network error tells us nothing.
    private func checkSchema() async -> SchemaCheck {
        struct VersionRow: Decodable { var version: Int }
        let guidance = "Run Sync/supabase-schema.sql in the Supabase SQL editor (safe to re-run), then try again."
        do {
            let rows: [VersionRow] = try await client
                .from("schema_version").select("version").execute().value
            guard (rows.map(\.version).max() ?? 0) >= Self.requiredSchemaVersion else {
                return .outdated("The server database is outdated. \(guidance)")
            }
            return .current
        } catch let error as PostgrestError where error.code == "PGRST205" || error.code == "42P01" {
            // "Table not found" — the one error that IS a schema verdict.
            return .outdated("The server database predates this version. \(guidance)")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Watches for the session dying underneath us (revoked, expired). Without
    /// this the UI kept showing a green "Syncing" while every push silently
    /// no-opped behind the signed-in guard.
    private func startAuthListener() {
        guard authTask == nil else { return }
        authTask = Task { @MainActor [weak self] in
            guard let stream = self?.client.auth.authStateChanges else { return }
            for await (event, session) in stream {
                guard let self, !Task.isCancelled else { return }
                if event == .signedOut, session == nil, case .syncing = self.state {
                    await self.teardownChannel()
                    self.state = .sessionLost
                }
            }
        }
    }

    /// Uploads anything the server hasn't seen or that this device changed
    /// later — rows changed before sync was on, or before the outbox existed.
    /// A failed stamp read sends nothing: guessing is how tombstones get
    /// buried.
    private func reconcile() async {
        guard let userID = client.auth.currentUser?.id.uuidString else { return }

        // Settings go up only if this device is the one that changed them last.
        if let changedAt = settingsChangedAt {
            let theirs = await remoteSettingsStamp(userID: userID)
            if theirs == nil || changedAt > theirs! {
                outbox.enqueue(.settings(SettingsRow(user_id: userID, payload: model.settings, updated_at: changedAt)))
            }
        }

        guard let remoteClocks = await remoteStamps(table: "clock_sessions", userID: userID),
              let remoteSessions = await remoteStamps(table: "sessions", userID: userID),
              let remoteBreaks = await remoteStamps(table: "work_breaks", userID: userID)
        else { return } // `reconciled` stays false; the caller schedules a retry

        for session in model.workday.sessions() {
            if isWorthUploading(session.updatedAt, against: remoteClocks[session.id]) {
                outbox.enqueue(.clockSession(ClockSessionRow(session: session, userID: userID)))
            }
            for entry in session.breaks {
                if isWorthUploading(entry.updatedAt ?? entry.startedAt, against: remoteBreaks[entry.id]) {
                    outbox.enqueue(.workBreak(WorkBreakRow(entry: entry, sessionID: session.id, userID: userID)))
                }
            }
        }
        for session in model.historyStore.all() {
            if isWorthUploading(session.updatedAt, against: remoteSessions[session.id]) {
                outbox.enqueue(.session(SessionRow(session: session, userID: userID)))
            }
        }

        // A non-idle timer is a live user intention — mirror it. An idle one is
        // not pushed from here: this device may have been offline for a day,
        // and its confidently-stamped "idle" would kill a session running
        // elsewhere right now.
        if model.engine.phase != .idle { pushLiveState() }

        reconciled = true
        await drainNow()
    }

    /// When the server has no copy at all, ours is the only one there is. When
    /// it has one, only a strictly later local change may replace it: a row we
    /// merely still hold says nothing about whether it should still exist.
    /// Compared on the wire's millisecond grid — sub-millisecond dust must not
    /// read as "newer" or every connect re-uploads every row.
    private func isWorthUploading(_ mine: Date?, against theirs: Date?) -> Bool {
        guard let theirs else { return true }
        return (mine ?? .distantPast).wireAligned > theirs
    }

    /// The `id`/`updated_at` pairs the server currently holds for `table`, or
    /// nil if they couldn't be read.
    private func remoteStamps(table: String, userID: String) async -> [UUID: Date]? {
        do {
            let rows: [RowStamp] = try await client
                .from(table)
                .select("id,updated_at")
                .eq("user_id", value: userID)
                .execute()
                .value
            return Dictionary(rows.map { ($0.id, $0.updated_at) }, uniquingKeysWith: { latest, _ in latest })
        } catch {
            lastSyncError = "\(table): \(error.localizedDescription)"
            return nil
        }
    }

    /// Full fetch of every table, applied through the same staleness guards as
    /// realtime events — so pulling is always safe, however stale or fresh the
    /// server copy is relative to us.
    private func pullAll() async {
        guard let userID = client.auth.currentUser?.id.uuidString else { return }
        do {
            let rows: [SessionRow] = try await client
                .from("sessions").select().eq("user_id", value: userID).execute().value
            applyRemoteSessions(rows)

            let settings: [SettingsRow] = try await client
                .from("settings").select().eq("user_id", value: userID).execute().value
            if let row = settings.first { applyRemoteSettings(row) }

            let clocks: [ClockSessionRow] = try await client
                .from("clock_sessions").select().eq("user_id", value: userID).execute().value
            applyRemoteClockSessions(clocks)

            let breaks: [WorkBreakRow] = try await client
                .from("work_breaks").select().eq("user_id", value: userID).execute().value
            applyRemoteWorkBreaks(breaks)

            let live: [LiveStateRow] = try await client
                .from("live_state").select().eq("user_id", value: userID).execute().value
            if let row = live.first { applyRemoteLiveState(row) }

            // A pull succeeding says nothing about writes still owed: keep the
            // error visible until the queue is empty and the reconcile has run.
            if reconciled && outbox.isEmpty { lastSyncError = nil }
        } catch {
            // A failed pull degrades freshness, not the connection — realtime
            // may still be delivering. Surface it without tearing sync down.
            lastSyncError = error.localizedDescription
        }
    }

    private func subscribe() async {
        await teardownChannel() // repeated connects must not stack channels

        let channel = client.channel("hourglass-sync")
        self.channel = channel

        let liveChanges = channel.postgresChange(AnyAction.self, table: "live_state")
        let sessionChanges = channel.postgresChange(AnyAction.self, table: "sessions")
        let settingsChanges = channel.postgresChange(AnyAction.self, table: "settings")
        let clockChanges = channel.postgresChange(AnyAction.self, table: "clock_sessions")
        let breakChanges = channel.postgresChange(AnyAction.self, table: "work_breaks")

        // Watch the channel's health. Realtime silently drops events while the
        // socket is down (sleep, backgrounding, network blips); every recovery
        // to `.subscribed` therefore pushes what accumulated and re-reads what
        // was missed. The first `.subscribed` after connect resyncs too —
        // cheap, and it closes the gap between the connect pull and the
        // subscription actually being live.
        statusTask = Task { @MainActor [weak self] in
            for await status in channel.statusChange {
                guard let self, !Task.isCancelled else { return }
                if status == .subscribed {
                    // Same shape as a foreground refresh: drain what
                    // accumulated, finish any owed reconcile, re-read what the
                    // dead socket missed.
                    await self.refresh()
                }
            }
        }

        await channel.subscribe()

        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in liveChanges {
                guard let record: LiveStateRow = self?.record(from: change) else { continue }
                self?.applyRemoteLiveState(record)
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in sessionChanges {
                guard let record: SessionRow = self?.record(from: change) else { continue }
                self?.applyRemoteSessions([record])
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in clockChanges {
                guard let record: ClockSessionRow = self?.record(from: change) else { continue }
                self?.applyRemoteClockSessions([record])
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in breakChanges {
                guard let record: WorkBreakRow = self?.record(from: change) else { continue }
                self?.applyRemoteWorkBreaks([record])
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in settingsChanges {
                guard let record: SettingsRow = self?.record(from: change) else { continue }
                self?.applyRemoteSettings(record)
            }
        })
    }

    // MARK: - Push (local → outbox → remote)

    /// Mirrors the current timer. Called on every engine transition. The
    /// snapshot is taken synchronously — the engine's settled state at the
    /// moment of the transition — and the outbox guarantees order from there.
    ///
    /// `asOf` backdates the row's stamp to when the transition really
    /// happened. A completion noticed hours late (the app slept through the
    /// deadline) is not a fresh intention: stamped "now" it would bury
    /// everything the other devices genuinely did since; stamped at the
    /// session's actual end it wins exactly the arguments it should.
    func pushLiveState(asOf: Date? = nil) {
        guard !isApplyingRemote, syncEnabled else { return }
        let engine = model.engine
        let now = Date()
        let stamp = asOf?.wireAligned ?? stamps.next()
        // A paused timer has to stay distinguishable from an idle one, and
        // `is_running` is false for both — so branch on the phase. A pause
        // travels as the pair (paused_at, end_date): what is left to run is
        // their difference, so it stays frozen however long the row sits there.
        // The *actual* freeze instant, not the moment this push happened. The
        // two are usually a beat apart, and that beat mattered once the linked
        // rest started deriving its identity from `pausedAt`: a push that
        // crossed a second boundary made the two devices name the same rest
        // differently and open one each. It is also simply more truthful —
        // "paused since" now reads the same on both.
        let pausedAt: Date? = engine.phase == .paused ? (engine.pausedAt ?? now) : nil
        let deadline: Date? = {
            guard engine.phase != .idle else { return nil }
            if engine.isOverrunning { return engine.plannedEnd }
            return (pausedAt ?? now).addingTimeInterval(engine.remaining)
        }()
        let row = LiveStateRow(
            user_id: "",
            kind: engine.kind.rawValue,
            // An overrun has no time left to add, so deriving the deadline from
            // `remaining` published the push instant as the end and threw the
            // finish away — every push re-dated it and the two devices drifted
            // apart on how far over they were. The real deadline is the truth
            // and it is already in hand.
            end_date: deadline,
            is_running: engine.isRunning,
            paused_at: pausedAt,
            cycle_position: engine.cyclePosition,
            session_id: engine.currentSessionID,
            origin_device: deviceID,
            updated_at: stamp
        )
        // Our own state is the newest we know: nothing older may overwrite it.
        liveStateFloor = max(liveStateFloor, stamp)
        outbox.enqueue(.liveState(row))
        kickDrain()
    }

    func pushSession(_ session: FocusSession) {
        guard !isApplyingRemote, syncEnabled else { return }
        outbox.enqueue(.session(SessionRow(session: session, userID: "")))
        kickDrain()
    }

    /// Mirrors the removal of a recorded Pomodoro, as a tombstone row: a hard
    /// DELETE is invisible to offline peers, who re-upload their copy and the
    /// deleted session comes back. The tombstone sits in the durable outbox
    /// until the server confirms it — a deletion erases its own local evidence,
    /// so the queue entry is the only carrier of the intent.
    func deleteSession(id: FocusSession.ID) {
        guard !isApplyingRemote, syncEnabled || hasSyncedBefore else { return }
        outbox.enqueue(.session(SessionRow.tombstone(id: id, userID: "", at: stamps.next())))
        kickDrain()
    }

    /// Mirrors a clocked-in stretch and its breaks (each break as its own row,
    /// so devices editing different parts of a day merge instead of clobber).
    func pushClockSession(_ session: ClockSession) {
        guard !isApplyingRemote, syncEnabled else { return }
        outbox.enqueue(.clockSession(ClockSessionRow(session: session, userID: "")))
        for entry in session.breaks {
            outbox.enqueue(.workBreak(WorkBreakRow(entry: entry, sessionID: session.id, userID: "")))
        }
        kickDrain()
    }

    /// Mirrors the removal of a clocked-in stretch.
    func deleteClockSession(id: ClockSession.ID) {
        guard !isApplyingRemote, syncEnabled || hasSyncedBefore else { return }
        outbox.enqueue(.clockSession(ClockSessionRow.tombstone(id: id, userID: "", at: stamps.next())))
        kickDrain()
    }

    /// Mirrors the removal of a single break.
    func deleteBreak(sessionID: ClockSession.ID, entryID: WorkBreak.ID) {
        guard !isApplyingRemote, syncEnabled || hasSyncedBefore else { return }
        outbox.enqueue(.workBreak(WorkBreakRow.tombstone(id: entryID, sessionID: sessionID, userID: "", at: stamps.next())))
        kickDrain()
    }

    func pushSettings() {
        guard !isApplyingRemote else { return }
        // Stamped before the enabled check, not after: a change made while sync
        // is off is precisely the one `reconcile` must recognise as newer when
        // the device next connects.
        let stamp = stamps.next()
        settingsChangedAt = stamp
        guard syncEnabled else { return }
        outbox.enqueue(.settings(SettingsRow(user_id: "", payload: model.settings, updated_at: stamp)))
        kickDrain()
    }

    /// When this device last changed settings, or nil if it never has.
    /// `TimerSettings` carries no stamp of its own, so the device keeps its own
    /// record; without it, the connect-time comparison has nothing to compare.
    private var settingsChangedAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.settingsChangedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.settingsChangedKey) }
    }
    private static let settingsChangedKey = "hourglass.settingsChangedAt"

    /// The `updated_at` the server holds for settings, or nil if it has no row.
    /// A failed read also reads as nil — the caller only uses it to decide
    /// whether *our* newer copy goes up, so a miss costs an extra write, never
    /// a silent overwrite of someone else's change.
    private func remoteSettingsStamp(userID: String) async -> Date? {
        struct Stamp: Decodable { var updated_at: Date }
        let rows: [Stamp]? = try? await client
            .from("settings").select("updated_at").eq("user_id", value: userID).execute().value
        return rows?.first?.updated_at
    }

    // MARK: - The drain: one ordered worker

    private func kickDrain() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.runDrain()
            guard let self else { return }
            self.drainTask = nil
            // An entry enqueued between the worker's final empty-check and
            // this line would otherwise sit until the next push. These
            // statements run as one uninterrupted main-actor stretch, so the
            // re-check cannot itself be raced.
            if !self.outbox.isEmpty, self.syncEnabled, !self.isDraining { self.kickDrain() }
        }
    }

    /// Drains and *waits* — for connect and refresh paths that need the queue
    /// flushed before pulling. Interrupts a worker parked in backoff sleep so
    /// "refresh now" means now.
    private func drainNow() async {
        if let running = drainTask {
            running.cancel()
            await running.value // let the worker leave `isDraining` cleanly
        }
        await runDrain()
        if !outbox.isEmpty, syncEnabled { kickDrain() } // leftovers keep retrying
    }

    /// True while a drain worker is running — a second entrant would interleave
    /// with the first at its awaits and send the same head entry twice.
    @ObservationIgnored private var isDraining = false

    /// Sends queue entries strictly front-to-back. An entry leaves the queue
    /// only when the server confirmed it; failures retry with backoff and
    /// nothing behind the failed entry jumps the line.
    private func runDrain() async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        var backoffSeconds = 1.0
        while !Task.isCancelled, syncEnabled, let entry = outbox.first {
            guard let userID = client.auth.currentUser?.id.uuidString else { return }
            if let failure = await send(entry.payload.addressed(to: userID)) {
                lastSyncError = failure
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                backoffSeconds = min(backoffSeconds * 2, 60)
            } else {
                outbox.markSent(entry.id)
                backoffSeconds = 1
                if outbox.isEmpty { lastSyncError = nil }
            }
        }
    }

    private func send(_ payload: OutboxPayload) async -> String? {
        switch payload {
        case .liveState(let row):
            return await Self.upsert(client, table: "live_state", values: row, onConflict: "user_id")
        case .session(let row):
            return await Self.upsert(client, table: "sessions", values: row, onConflict: "user_id,id")
        case .clockSession(let row):
            return await Self.upsert(client, table: "clock_sessions", values: row, onConflict: "user_id,id")
        case .workBreak(let row):
            return await Self.upsert(client, table: "work_breaks", values: row, onConflict: "user_id,id")
        case .settings(let row):
            return await Self.upsert(client, table: "settings", values: row, onConflict: "user_id")
        }
    }

    /// One legacy shape: deletions recorded by earlier builds in UserDefaults.
    /// Fold them into the outbox so they still replay.
    private func migrateLegacyPendingDeletes() {
        let tables = ["sessions", "clock_sessions"]
        for table in tables {
            let key = "hourglass.pendingDeletes.\(table)"
            guard let pending = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] else { continue }
            for (idString, at) in pending {
                guard let id = UUID(uuidString: idString) else { continue }
                if table == "sessions" {
                    outbox.enqueue(.session(SessionRow.tombstone(id: id, userID: "", at: at)))
                } else {
                    outbox.enqueue(.clockSession(ClockSessionRow.tombstone(id: id, userID: "", at: at)))
                }
            }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Apply (remote → local)

    private func applyRemoteLiveState(_ row: LiveStateRow) {
        guard row.origin_device != deviceID else { return } // our own echo
        // Below the floor means older than what this device already pushed or
        // applied: stale. Applying it regressed running timers to whatever old
        // row a pull happened to fetch. An exact tie (two devices stamping the
        // same millisecond) breaks on the device id — deterministic and
        // symmetric, so exactly one side yields and the session ids converge.
        guard row.updated_at > liveStateFloor
            || (row.updated_at == liveStateFloor && row.origin_device > deviceID)
        else { return }
        liveStateFloor = row.updated_at
        stamps.observe(row.updated_at)
        withRemoteApplication {
            model.applyRemoteTimer(
                cyclePosition: row.cycle_position,
                isRunning: row.is_running,
                endDate: row.end_date,
                pausedAt: row.paused_at,
                sessionID: row.session_id
            )
        }
    }

    /// Adopts recorded sessions from the server, last writer winning. A row
    /// written before stamps existed carries none and reads as the oldest
    /// thing there is.
    private func applyRemoteSessions(_ rows: [SessionRow]) {
        withRemoteApplication {
            let existing = Dictionary(
                model.historyStore.all().map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for row in rows {
                stamps.observe(row.updated_at)
                let mine = existing[row.id]?.updatedAt ?? .distantPast
                guard row.updated_at >= mine else { continue }
                if row.deleted_at != nil {
                    // Through the store, not `model.deleteSession(id:)` — that
                    // is the path that pushes, and it would send the deletion
                    // we are being told about straight back out.
                    model.historyStore.delete(id: row.id)
                } else {
                    model.historyStore.upsert(row.focusSession)
                }
            }
        }
    }

    private func applyRemoteClockSessions(_ rows: [ClockSessionRow]) {
        withRemoteApplication {
            for row in rows {
                stamps.observe(row.updated_at)
                guard row.deleted_at != nil else {
                    model.workday.applyRemote(row.clockSession)
                    flushOrphanBreaks(for: row.id)
                    continue
                }
                // A tombstone older than our copy would undo an edit made
                // after it.
                let mine = model.workday.sessions().first { $0.id == row.id }?.updatedAt ?? .distantPast
                guard row.updated_at >= mine else { continue }
                model.workday.deleteLocally(id: row.id)
                orphanBreaks[row.id] = nil
            }
        }
        // applyRemote and deleteLocally deliberately skip the tracker's hooks
        // to avoid echoing the change back, so nudge the host directly.
        model.remoteWorkdayDidChange()
    }

    private func applyRemoteWorkBreaks(_ rows: [WorkBreakRow]) {
        withRemoteApplication {
            for row in rows {
                stamps.observe(row.updated_at)
                if row.deleted_at != nil {
                    model.workday.deleteBreakLocally(
                        sessionID: row.clock_session_id,
                        entryID: row.id,
                        unlessEditedAfter: row.updated_at
                    )
                    orphanBreaks[row.clock_session_id]?.removeAll { $0.id == row.id }
                } else if !model.workday.applyRemoteBreak(sessionID: row.clock_session_id, entry: row.workBreak) {
                    // Parent hasn't arrived yet; hold the row until it does.
                    orphanBreaks[row.clock_session_id, default: []].removeAll { $0.id == row.id }
                    orphanBreaks[row.clock_session_id, default: []].append(row)
                }
            }
        }
        model.remoteWorkdayDidChange()
    }

    private func flushOrphanBreaks(for sessionID: UUID) {
        guard let waiting = orphanBreaks.removeValue(forKey: sessionID) else { return }
        for row in waiting {
            model.workday.applyRemoteBreak(sessionID: sessionID, entry: row.workBreak)
        }
    }

    /// Adopts settings from the server — but only when the server's copy is at
    /// least as new as our last local change. Applying unconditionally let a
    /// pull permanently destroy a newer local change (and stamp it as adopted,
    /// so the reconcile never sent it either).
    private func applyRemoteSettings(_ row: SettingsRow) {
        stamps.observe(row.updated_at)
        let mine = settingsChangedAt ?? .distantPast
        guard row.updated_at >= mine else { return }
        settingsChangedAt = row.updated_at
        guard row.payload != model.settings else { return }
        withRemoteApplication { model.settings = row.payload }
    }

    private func withRemoteApplication(_ body: () -> Void) {
        isApplyingRemote = true
        body()
        isApplyingRemote = false
    }

    // MARK: - Helpers

    /// Decoder for Realtime payloads.
    ///
    /// Supabase does *not* emit plain `.iso8601`: JSONB values arrive as
    /// `2026-07-27T10:06:42.144` — fractional seconds, no zone — while
    /// `timestamptz` columns carry an offset. `.iso8601` rejects both, which
    /// silently dropped every realtime update, so accept each shape.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = SyncService.parseDate(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised date format: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    static func parseDate(_ string: String) -> Date? {
        // Zone-less, as written into JSONB by the SDK's encoder.
        let zoneless = Date.ISO8601FormatStyle().year().month().day()
            .dateTimeSeparator(.standard)
        if let date = try? Date(string, strategy: zoneless.time(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(string, strategy: zoneless.time(includingFractionalSeconds: false)) {
            return date
        }
        // timestamptz columns, which do carry an offset.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Pulls the new row out of an insert/update change (deletes carry no
    /// record — deletions travel as tombstone updates instead). A row that
    /// fails to decode is surfaced, not swallowed: silently dropping realtime
    /// updates is a divergence with no symptoms.
    private func record<T: Decodable>(from change: AnyAction) -> T? {
        do {
            switch change {
            case .insert(let action): return try action.decodeRecord(as: T.self, decoder: Self.decoder)
            case .update(let action): return try action.decodeRecord(as: T.self, decoder: Self.decoder)
            default: return nil
            }
        } catch {
            lastSyncError = "realtime decode: \(error.localizedDescription)"
            return nil
        }
    }

    /// Write kept in a single isolation domain, so the non-`Sendable`
    /// Postgrest response never crosses an actor boundary.
    private nonisolated static func upsert(
        _ client: SupabaseClient,
        table: String,
        values: some Codable & Sendable,
        onConflict: String
    ) async -> String? {
        do {
            _ = try await client.from(table).upsert(values, onConflict: onConflict).execute()
            return nil
        } catch {
            return "\(table): \(error.localizedDescription)"
        }
    }

    /// A stable per-install identifier used purely to ignore our own echoes.
    private static func resolveDeviceID() -> String {
        let key = "hourglass.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }
}
