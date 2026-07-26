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
        case signedOut
        case awaitingCode(email: String)
        case syncing(email: String)
        case failed(String)
    }

    private(set) var state: State = .signedOut
    /// Set while a network call is in flight, so the UI can show progress.
    private(set) var isBusy = false

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
            supabaseKey: SyncConfig.supabaseKey
        )
    }

    var userEmail: String? { client.auth.currentUser?.email }
    var isSignedIn: Bool { client.auth.currentSession != nil }

    // MARK: - Auth (email one-time code)

    /// Sends a 6-digit code to the address.
    func sendCode(to email: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.auth.signInWithOTP(email: email)
            state = .awaitingCode(email: email)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Verifies the emailed code and starts syncing.
    ///
    /// The code's OTP type depends on the account's history — a brand-new
    /// address confirms via `signup`, later sign-ins via `magiclink`/`email` —
    /// so we try each rather than making the user care which one they got.
    func verifyCode(_ code: String, email: String) async {
        isBusy = true
        defer { isBusy = false }

        var lastError: Error?
        for type in [EmailOTPType.email, .signup, .magiclink] {
            do {
                try await client.auth.verifyOTP(email: email, token: code, type: type)
                state = .syncing(email: email)
                await startSyncing()
                return
            } catch {
                lastError = error
            }
        }
        state = .failed(lastError?.localizedDescription ?? "That code didn't work. Try sending a new one.")
    }

    func signOut() async {
        await stopSyncing()
        try? await client.auth.signOut()
        state = .signedOut
    }

    /// Resumes an existing session at launch.
    func restore() async {
        guard let email = client.auth.currentUser?.email else { return }
        state = .syncing(email: email)
        await startSyncing()
    }

    // MARK: - Sync lifecycle

    private func startSyncing() async {
        await pullAll()
        await subscribe()
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
        Task { [client] in await Self.upsert(client, table: "live_state", values: row, onConflict: "user_id") }
    }

    func pushSession(_ session: FocusSession) {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SessionRow(session: session, userID: userID)
        Task { [client] in await Self.upsert(client, table: "sessions", values: row, onConflict: "id") }
    }

    func pushSettings() {
        guard !isApplyingRemote, isSignedIn,
              let userID = client.auth.currentUser?.id.uuidString else { return }
        let row = SettingsRow(user_id: userID, payload: model.settings, updated_at: Date())
        Task { [client] in await Self.upsert(client, table: "settings", values: row, onConflict: "user_id") }
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

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

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
    ) async {
        _ = try? await client.from(table).upsert(values, onConflict: onConflict).execute()
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
