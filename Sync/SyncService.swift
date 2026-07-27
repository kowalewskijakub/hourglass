import Foundation
import Observation
import Supabase
import HourglassCore

/// Real-time sync across devices, backed by Supabase.
///
/// The running timer is mirrored by exchanging a tiny `live_state` row
/// (`kind`, `end_date`, `is_running`, …) rather than streaming ticks — each
/// device computes the countdown locally from `end_date`, exactly as the engine
/// already does. Echoes of our own writes are filtered by `origin_device`.
@MainActor
@Observable
final class SyncService {

    enum State: Equatable {
        case off
        /// Syncing; `pairing` is a code currently on offer to another device.
        case syncing(pairing: PairingCode?)
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

    private(set) var state: State = .off
    /// Set while a network call is in flight, so the UI can show progress.
    private(set) var isBusy = false
    /// Last write that failed. Pushes are fire-and-forget, so without this a
    /// rejected write (say, RLS refusing a row owned by another account) would
    /// vanish silently and sync would look fine while diverging.
    private(set) var lastSyncError: String?

    @ObservationIgnored private let client: SupabaseClient
    @ObservationIgnored private let model: AppModel
    /// Identifies this device so we can ignore the echo of our own writes.
    @ObservationIgnored private let deviceID = SyncService.resolveDeviceID()
    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var listenerTasks: [Task<Void, Never>] = []
    /// Suppresses push-on-change while we're applying a remote update.
    @ObservationIgnored private var isApplyingRemote = false

    init(model: AppModel) {
        self.model = model
        client = SupabaseClient(
            supabaseURL: SyncConfig.supabaseURL,
            supabaseKey: SyncConfig.supabaseKey,
            options: SupabaseClientOptions(
                // Keep the session out of the Keychain: an ad-hoc-signed Mac app
                // changes signature every build, so the Keychain re-prompts each
                // time. A file we own avoids that (and iCloud Keychain) entirely.
                auth: SupabaseClientOptions.AuthOptions(storage: FileSessionStorage())
            )
        )
    }

    var isSignedIn: Bool { client.auth.currentSession != nil }

    // MARK: - Auth (anonymous account + device pairing)
    //
    // There is no account and no password: the first device creates an anonymous
    // user, and any other device joins it by redeeming a short-lived pairing
    // code. The code is exchanged for that user's refresh token via a
    // SECURITY DEFINER function, so the token store itself is never readable.

    /// Turns sync on for the first device by creating an anonymous account.
    func enableSync() async {
        isBusy = true
        defer { isBusy = false }
        do {
            if !isSignedIn { try await client.auth.signInAnonymously() }
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
            guard let refreshToken = client.auth.currentSession?.refreshToken else {
                state = .failed("Sync isn't ready yet — try again in a moment.")
                return
            }
            let code = Self.makePairingCode()
            try await client
                .rpc("create_pairing", params: ["p_code": code, "p_refresh_token": refreshToken])
                .execute()
            state = .syncing(pairing: PairingCode(code: code, expiresAt: Date().addingTimeInterval(Self.pairingLifetime)))
            await startSyncing()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Joins the account that produced `code`, adopting its data.
    func redeemPairingCode(_ code: String) async {
        isBusy = true
        defer { isBusy = false }
        let normalized = Self.normalize(code)
        do {
            let token: String? = try await client
                .rpc("claim_pairing", params: ["p_code": normalized])
                .execute()
                .value
            guard let token, !token.isEmpty else {
                state = .failed("That code is wrong, already used, or expired.")
                return
            }
            try await client.auth.refreshSession(refreshToken: token)
            state = .syncing(pairing: nil)
            await startSyncing()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stopSync() async {
        await stopSyncing()
        try? await client.auth.signOut()
        state = .off
    }

    /// Resumes an existing session at launch.
    func restore() async {
        guard isSignedIn else { return }
        state = .syncing(pairing: nil)
        await startSyncing()
    }

    /// Re-reads everything from the server. Realtime can miss events while a
    /// device is asleep or backgrounded, so reconcile whenever we come forward
    /// rather than trusting the stream alone.
    func refresh() async {
        guard isSignedIn else { return }
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
        // Push before pulling. Anything changed while signed out or offline was
        // never sent — pulling first would overwrite it with stale server state
        // and lose the change for good.
        await pushLocalState()
        await pullAll()
        await subscribe()
    }

    /// Uploads what this device knows, so work done while disconnected reaches
    /// the server instead of being silently dropped.
    ///
    /// Rows are reconciled rather than blind-upserted. Uploading every local row
    /// resurrects whatever another device deleted while we were away: our copy
    /// isn't newer, it is merely still here, and re-writing it buries the
    /// tombstone that was carrying the deletion. So read what the server holds
    /// first and send only what it has never seen or what we changed later.
    private func pushLocalState() async {
        guard let userID = client.auth.currentUser?.id.uuidString else { return }

        // Settings go up only if this device is the one that changed them last.
        // Holding a different copy is not evidence of holding a newer one: a
        // device that changed nothing for a week would otherwise overwrite the
        // change another device made yesterday, and neither side would show a
        // trace of it.
        if let changedAt = settingsChangedAt {
            let theirs = await remoteSettingsStamp(userID: userID)
            if theirs == nil || changedAt > theirs! {
                await write(
                    table: "settings",
                    values: SettingsRow(user_id: userID, payload: model.settings, updated_at: changedAt),
                    onConflict: "user_id"
                )
            }
        }

        // Deletions first: a tombstone that lands here is part of what the
        // reconcile reads back, so this device stops re-uploading the row it is
        // trying to delete.
        await replayPendingDeletes(userID: userID)

        // A failed read tells us nothing about what the server holds, and
        // guessing is exactly how a tombstone gets undone — so send nothing.
        guard let remoteClocks = await remoteStamps(table: "clock_sessions", userID: userID),
              let remoteSessions = await remoteStamps(table: "sessions", userID: userID)
        else { return }

        for session in model.workday.sessions() {
            guard isWorthUploading(session.updatedAt, against: remoteClocks[session.id]) else { continue }
            await write(
                table: "clock_sessions",
                values: ClockSessionRow(session: session, userID: userID),
                onConflict: "user_id,id"
            )
        }
        for session in model.historyStore.all() where session.completed {
            guard isWorthUploading(session.updatedAt, against: remoteSessions[session.id]) else { continue }
            await write(
                table: "sessions",
                values: SessionRow(session: session, userID: userID),
                onConflict: "user_id,id"
            )
        }
    }

    /// When the server has no copy at all, ours is the only one there is. When
    /// it has one, only a strictly later local change may replace it: a row we
    /// merely still hold says nothing about whether it should still exist.
    private func isWorthUploading(_ mine: Date?, against theirs: Date?) -> Bool {
        guard let theirs else { return true }
        return (mine ?? .distantPast) > theirs
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

    private func stopSyncing() async {
        listenerTasks.forEach { $0.cancel() }
        listenerTasks.removeAll()
        if let channel { await client.removeChannel(channel) }
        channel = nil
    }

    /// Initial fetch so a fresh device catches up before listening for changes.
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

            let live: [LiveStateRow] = try await client
                .from("live_state").select().eq("user_id", value: userID).execute().value
            if let row = live.first { applyRemoteLiveState(row) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func subscribe() async {
        let channel = client.channel("hourglass-sync")
        self.channel = channel

        let liveChanges = channel.postgresChange(AnyAction.self, table: "live_state")
        let sessionChanges = channel.postgresChange(AnyAction.self, table: "sessions")
        let settingsChanges = channel.postgresChange(AnyAction.self, table: "settings")
        let clockChanges = channel.postgresChange(AnyAction.self, table: "clock_sessions")

        await channel.subscribe()

        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in liveChanges {
                guard let record: LiveStateRow = Self.record(from: change) else { continue }
                self?.applyRemoteLiveState(record)
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in sessionChanges {
                guard let record: SessionRow = Self.record(from: change) else { continue }
                self?.applyRemoteSessions([record])
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in clockChanges {
                guard let record: ClockSessionRow = Self.record(from: change) else { continue }
                self?.applyRemoteClockSessions([record])
            }
        })
        listenerTasks.append(Task { @MainActor [weak self] in
            for await change in settingsChanges {
                guard let record: SettingsRow = Self.record(from: change) else { continue }
                self?.applyRemoteSettings(record)
            }
        })
    }

    // MARK: - Push (local → remote)

    /// Mirrors the current timer. Called on every engine transition.
    func pushLiveState() {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let engine = model.engine
        let now = Date()
        // A paused timer has to stay distinguishable from an idle one, and
        // `is_running` is false for both — so branch on the phase. Sending no
        // end_date for a pause made the receiving device read it as idle and
        // reset its countdown to a full session.
        //
        // A pause travels as the pair (paused_at, end_date): what is left to run
        // is their difference, so it stays frozen however long the row sits
        // there, and re-sending it later moves both stamps together.
        let pausedAt: Date? = engine.phase == .paused ? now : nil
        let row = LiveStateRow(
            user_id: userID,
            kind: engine.kind.rawValue,
            end_date: engine.phase == .idle ? nil : (pausedAt ?? now).addingTimeInterval(engine.remaining),
            is_running: engine.isRunning,
            paused_at: pausedAt,
            cycle_position: engine.cyclePosition,
            origin_device: deviceID,
            updated_at: now
        )
        Task { await write(table: "live_state", values: row, onConflict: "user_id") }
    }

    func pushSession(_ session: FocusSession) {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SessionRow(session: session, userID: userID)
        Task { await write(table: "sessions", values: row, onConflict: "user_id,id") }
    }

    /// Mirrors the removal of a recorded Pomodoro. Without this a session
    /// deleted in the log came straight back on the next pull, because the
    /// server's copy was still there and nothing had told it otherwise.
    func deleteSession(id: FocusSession.ID) {
        guard !isApplyingRemote else { return }
        // Remembered before the write is attempted, and kept until the server
        // confirms it — including when we aren't signed in yet, so a deletion
        // made with sync off still travels once it's on.
        let at = Date()
        setPendingDelete(id.uuidString, in: "sessions", at: at)
        guard isSignedIn, let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SessionRow.tombstone(id: id, userID: userID, at: at)
        Task { await sendTombstone(table: "sessions", values: row, id: id.uuidString) }
    }

    /// Mirrors a clocked-in stretch (and its breaks) to the other devices.
    func pushClockSession(_ session: ClockSession) {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = ClockSessionRow(session: session, userID: userID)
        Task { await write(table: "clock_sessions", values: row, onConflict: "user_id,id") }
    }

    /// Mirrors the removal of a clocked-in stretch. This used to be a hard
    /// DELETE, which Realtime can only report as a bare primary key the peers
    /// have nothing to match — so the row simply reappeared, uploaded again by
    /// the first device to connect that still held it.
    func deleteClockSession(id: ClockSession.ID) {
        guard !isApplyingRemote else { return }
        let at = Date()
        setPendingDelete(id.uuidString, in: "clock_sessions", at: at)
        guard isSignedIn, let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = ClockSessionRow.tombstone(id: id, userID: userID, at: at)
        Task { await sendTombstone(table: "clock_sessions", values: row, id: id.uuidString) }
    }

    func pushSettings() {
        guard !isApplyingRemote else { return }
        // Stamped before the signed-in check, not after: a change made while
        // sync is off is precisely the one `pushLocalState` must recognise as
        // newer when the device next connects.
        let now = Date()
        settingsChangedAt = now
        guard isSignedIn, let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SettingsRow(user_id: userID, payload: model.settings, updated_at: now)
        Task { await write(table: "settings", values: row, onConflict: "user_id") }
    }

    /// When this device last changed settings, or nil if it never has.
    ///
    /// `TimerSettings` carries no stamp of its own and `UserDefaultsSettingsStore`
    /// records no change time, so without this the `updated_at` invented at push
    /// time is always the newest thing on the server and every launch wins an
    /// argument it should have lost. Persisted because the comparison happens at
    /// connect, before anything has been changed in memory.
    private var settingsChangedAt: Date? {
        get { UserDefaults.standard.object(forKey: Self.settingsChangedKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.settingsChangedKey) }
    }
    private static let settingsChangedKey = "hourglass.settingsChangedAt"

    /// The `updated_at` the server holds for settings, or nil if it has no row.
    /// A failed read also reads as nil — but the caller only uses it to decide
    /// whether *our* newer copy goes up, so a miss costs an extra write, never a
    /// silent overwrite of someone else's change.
    private func remoteSettingsStamp(userID: String) async -> Date? {
        struct Stamp: Decodable { var updated_at: Date }
        let rows: [Stamp]? = try? await client
            .from("settings").select("updated_at").eq("user_id", value: userID).execute().value
        return rows?.first?.updated_at
    }

    // MARK: - Apply (remote → local)

    private func applyRemoteLiveState(_ row: LiveStateRow) {
        guard row.origin_device != deviceID else { return } // our own echo
        withRemoteApplication {
            model.engine.applyRemoteState(
                cyclePosition: row.cycle_position,
                isRunning: row.is_running,
                endDate: row.end_date,
                pausedAt: row.paused_at
            )
        }
    }

    /// Adopts recorded sessions from the server, last writer winning — the same
    /// rule `WorkdayTracker.applyRemote` applies to clock sessions. Without it
    /// an edit made here is undone by the server's older copy the moment it
    /// arrives; a row written before stamps existed carries none, and reads as
    /// the oldest thing there is.
    private func applyRemoteSessions(_ rows: [SessionRow]) {
        withRemoteApplication {
            let existing = Dictionary(
                model.historyStore.all().map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for row in rows {
                let mine = existing[row.id]?.updatedAt ?? .distantPast
                guard row.updated_at >= mine else { continue }
                if row.deleted_at != nil {
                    // Through the store, not `model.deleteSession(id:)` — that
                    // is the path that pushes, and it would send the deletion
                    // we are being told about straight back out.
                    model.historyStore.delete(id: row.id)
                } else if existing[row.id] != nil {
                    model.historyStore.update(row.focusSession)
                } else {
                    model.historyStore.add(row.focusSession)
                }
            }
        }
    }

    private func applyRemoteClockSessions(_ rows: [ClockSessionRow]) {
        withRemoteApplication {
            for row in rows {
                guard row.deleted_at != nil else {
                    model.workday.applyRemote(row.clockSession)
                    continue
                }
                // A tombstone is held to the same rule `applyRemote` enforces:
                // one older than our copy would undo an edit made after it.
                let mine = model.workday.sessions().first { $0.id == row.id }?.updatedAt ?? .distantPast
                guard row.updated_at >= mine else { continue }
                model.workday.deleteLocally(id: row.id)
            }
        }
        // applyRemote and deleteLocally deliberately skip the tracker's hooks to
        // avoid echoing the change back, so nudge the host directly.
        model.onWorkdayChanged?()
    }

    /// Adopts settings from the server and, either way, records that our copy is
    /// no newer than theirs — otherwise the next connect would push what we just
    /// took back over the device it came from.
    private func applyRemoteSettings(_ row: SettingsRow) {
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

    /// Pulls the new row out of an insert/update change (deletes carry no record).
    private static func record<T: Decodable>(from change: AnyAction) -> T? {
        switch change {
        case .insert(let action): return try? action.decodeRecord(as: T.self, decoder: decoder)
        case .update(let action): return try? action.decodeRecord(as: T.self, decoder: decoder)
        default: return nil
        }
    }

    /// Fire-and-forget write kept in a single isolation domain, so the
    /// non-`Sendable` Postgrest response never crosses an actor boundary.
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

    /// Runs a write and records any failure so the UI can show it. Reports
    /// whether the server took it, so a caller holding an intent that cannot be
    /// reconstructed later — a deletion — knows whether it may forget it.
    @discardableResult
    private func write(
        table: String,
        values: some Codable & Sendable,
        onConflict: String
    ) async -> Bool {
        if let failure = await Self.upsert(client, table: table, values: values, onConflict: onConflict) {
            lastSyncError = failure
            return false
        }
        lastSyncError = nil
        return true
    }

    // MARK: Deletions awaiting the server
    //
    // Every other local change survives a failed write because the row is still
    // on the device to re-upload: `pushLocalState` walks what we hold. A
    // deletion erases its own evidence, so its intent lives only in a network
    // call — and if that call never lands (offline, suspended mid-flight, or the
    // `deleted_at` column not yet migrated) the next pull hands the row back and
    // the deletion is undone. Remembering it locally is what closes that gap.

    private static func pendingDeletesKey(_ table: String) -> String {
        "hourglass.pendingDeletes.\(table)"
    }

    /// Row id → the instant it was deleted here.
    private func pendingDeletes(in table: String) -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: Self.pendingDeletesKey(table)) as? [String: Date] ?? [:]
    }

    private func setPendingDelete(_ id: String, in table: String, at instant: Date?) {
        var pending = pendingDeletes(in: table)
        pending[id] = instant
        UserDefaults.standard.set(pending, forKey: Self.pendingDeletesKey(table))
    }

    /// Sends a tombstone, forgetting it only once the server has confirmed it.
    private func sendTombstone(
        table: String,
        values: some Codable & Sendable,
        id: String
    ) async {
        if await write(table: table, values: values, onConflict: "user_id,id") {
            setPendingDelete(id, in: table, at: nil)
        }
    }

    /// Re-sends deletions that never reached the server.
    ///
    /// Runs before the reconcile reads what the server holds, so a tombstone
    /// landing here becomes the stamp the reconcile compares against — the other
    /// order would have this device upload the very row it is trying to delete.
    /// Each replay carries the ORIGINAL deletion instant, never the retry time,
    /// so a late-arriving tombstone cannot outrank a genuine later edit made on
    /// another device.
    private func replayPendingDeletes(userID: String) async {
        for (key, at) in pendingDeletes(in: "sessions") {
            guard let id = UUID(uuidString: key) else {
                setPendingDelete(key, in: "sessions", at: nil)
                continue
            }
            await sendTombstone(
                table: "sessions",
                values: SessionRow.tombstone(id: id, userID: userID, at: at),
                id: key
            )
        }
        for (key, at) in pendingDeletes(in: "clock_sessions") {
            guard let id = UUID(uuidString: key) else {
                setPendingDelete(key, in: "clock_sessions", at: nil)
                continue
            }
            await sendTombstone(
                table: "clock_sessions",
                values: ClockSessionRow.tombstone(id: id, userID: userID, at: at),
                id: key
            )
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
