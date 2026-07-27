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

    /// Uploads everything this device knows, so work done while disconnected
    /// reaches the server instead of being silently dropped.
    private func pushLocalState() async {
        guard let userID = client.auth.currentUser?.id.uuidString else { return }

        for session in model.workday.sessions() {
            await write(
                table: "clock_sessions",
                values: ClockSessionRow(session: session, userID: userID),
                onConflict: "id"
            )
        }
        for session in model.historyStore.all() where session.completed {
            await write(
                table: "sessions",
                values: SessionRow(session: session, userID: userID),
                onConflict: "id"
            )
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
            if let payload = settings.first?.payload { applyRemoteSettings(payload) }

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
                self?.applyRemoteSettings(record.payload)
            }
        })
    }

    // MARK: - Push (local → remote)

    /// Mirrors the current timer. Called on every engine transition.
    func pushLiveState() {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let engine = model.engine
        let row = LiveStateRow(
            user_id: userID,
            kind: engine.kind.rawValue,
            end_date: engine.isRunning ? Date().addingTimeInterval(engine.remaining) : nil,
            is_running: engine.isRunning,
            paused_at: engine.phase == .paused ? Date() : nil,
            cycle_position: engine.cyclePosition,
            origin_device: deviceID,
            updated_at: Date()
        )
        Task { await write(table: "live_state", values: row, onConflict: "user_id") }
    }

    func pushSession(_ session: FocusSession) {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SessionRow(session: session, userID: userID)
        Task { await write(table: "sessions", values: row, onConflict: "id") }
    }

    /// Mirrors a clocked-in stretch (and its breaks) to the other devices.
    func pushClockSession(_ session: ClockSession) {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = ClockSessionRow(session: session, userID: userID)
        Task { await write(table: "clock_sessions", values: row, onConflict: "id") }
    }

    func deleteClockSession(id: ClockSession.ID) {
        guard !isApplyingRemote, isSignedIn else { return }
        Task { [client] in
            _ = try? await client.from("clock_sessions").delete().eq("id", value: id.uuidString).execute()
        }
    }

    func pushSettings() {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SettingsRow(user_id: userID, payload: model.settings, updated_at: Date())
        Task { await write(table: "settings", values: row, onConflict: "user_id") }
    }

    // MARK: - Apply (remote → local)

    private func applyRemoteLiveState(_ row: LiveStateRow) {
        guard row.origin_device != deviceID else { return } // our own echo
        withRemoteApplication {
            model.engine.applyRemoteState(
                cyclePosition: row.cycle_position,
                isRunning: row.is_running,
                endDate: row.end_date
            )
        }
    }

    private func applyRemoteSessions(_ rows: [SessionRow]) {
        withRemoteApplication {
            let existing = Set(model.historyStore.all().map(\.id))
            for row in rows {
                let session = row.focusSession
                if existing.contains(session.id) {
                    model.historyStore.update(session)
                } else {
                    model.historyStore.add(session)
                }
            }
        }
    }

    private func applyRemoteClockSessions(_ rows: [ClockSessionRow]) {
        withRemoteApplication {
            for row in rows { model.workday.applyRemote(row.clockSession) }
        }
        // applyRemote deliberately skips the tracker's hooks to avoid echoing the
        // change back, so nudge the host directly.
        model.onWorkdayChanged?()
    }

    private func applyRemoteSettings(_ settings: TimerSettings) {
        guard settings != model.settings else { return }
        withRemoteApplication { model.settings = settings }
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

    /// Runs a write and records any failure so the UI can show it.
    private func write(
        table: String,
        values: some Codable & Sendable,
        onConflict: String
    ) async {
        if let failure = await Self.upsert(client, table: table, values: values, onConflict: onConflict) {
            lastSyncError = failure
        } else {
            lastSyncError = nil
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
