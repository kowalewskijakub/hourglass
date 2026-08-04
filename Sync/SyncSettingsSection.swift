import SwiftUI

/// Sync setup UI: turn sync on, pair other devices with a one-time code, and —
/// crucially — recover without data loss. A device that ever synced is never
/// silently handed a fresh empty account: that used to split the user's
/// devices across two accounts, both showing a green "Syncing" while nothing
/// crossed.
struct SyncSettingsSection: View {
    @Bindable var sync: SyncService
    @State private var enteredCode = ""
    @State private var isJoining = false
    @State private var confirmingDisconnect = false
    @State private var confirmingStartOver = false

    /// A stack rather than a `Section`: Settings is built from cards now (see
    /// `OrbitCard`), and this is the content of the Sync one. The card supplies
    /// the title the section header used to.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch sync.state {
            case .off where !sync.hasSyncedBefore, .failed where !sync.hasSyncedBefore:
                firstRun

            case .off, .failed:
                paused

            case .sessionLost:
                sessionLost

            case .syncing(let pairing):
                syncing(pairing)
            }

            if case .failed(let message) = sync.state {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }

            if let writeError = sync.lastSyncError {
                Label("Couldn't reach the server — \(writeError)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.small)
        .confirmationDialog(
            "Disconnect this device?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await sync.disconnect() }
            }
        } message: {
            Text("If no other device is paired to this account, its synced data becomes unreachable. Pair another device first to keep it.")
        }
        .confirmationDialog(
            "Start over with a new sync account?",
            isPresented: $confirmingStartOver,
            titleVisibility: .visible
        ) {
            Button("Start over", role: .destructive) {
                Task {
                    await sync.disconnect()
                    await sync.enableSync()
                }
            }
        } message: {
            Text("This device keeps its local data and uploads it to a fresh account. Other devices stay on the old account until they join this one.")
        }
    }

    // MARK: States

    /// Never synced here: enable fresh, or join an existing account.
    @ViewBuilder private var firstRun: some View {
        Button("Turn on sync") {
            Task { await sync.enableSync() }
        }
        .disabled(sync.isBusy)

        joinField
    }

    /// Synced before and still holding the account — sync is just switched off.
    /// (If the session turns out to be gone, Resume lands in `.sessionLost`
    /// rather than silently minting a fresh account.)
    @ViewBuilder private var paused: some View {
        Label("Sync is paused", systemImage: "pause.circle")
            .foregroundStyle(.secondary)

        Button("Resume sync") {
            Task { await sync.enableSync() }
        }
        .disabled(sync.isBusy)

        joinField

        Button("Disconnect this device…", role: .destructive) {
            confirmingDisconnect = true
        }
        .disabled(sync.isBusy)
    }

    /// The session died underneath us (revoked or expired). The account and
    /// its data still exist — rejoining from another paired device is the
    /// recovery that keeps them.
    @ViewBuilder private var sessionLost: some View {
        Label("This device was signed out of sync", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        Text("Your data is still on the server. On a device that still syncs, choose “Pair another device” and enter the code here.")
            .font(.caption)
            .foregroundStyle(.secondary)

        joinField

        Button("Start over with a new account…", role: .destructive) {
            confirmingStartOver = true
        }
        .disabled(sync.isBusy)
    }

    @ViewBuilder private func syncing(_ pairing: SyncService.PairingCode?) -> some View {
        HStack {
            Label("Syncing", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if sync.pendingWrites > 0 {
                Spacer()
                Text("\(sync.pendingWrites) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let pairing {
            pairingCode(pairing)
        } else {
            Button("Pair another device") {
                Task { await sync.createPairingCode() }
            }
            .disabled(sync.isBusy)
        }

        Button("Pause sync") {
            Task { await sync.pauseSync() }
        }
        .disabled(sync.isBusy)

        Button("Disconnect this device…", role: .destructive) {
            confirmingDisconnect = true
        }
        .disabled(sync.isBusy)
    }

    // MARK: Pieces

    @ViewBuilder private var joinField: some View {
        if isJoining {
            TextField("Pairing code", text: $enteredCode)
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .disableAutocorrection(true)
            Button("Join") {
                Task { await sync.redeemPairingCode(enteredCode) }
            }
            .disabled(enteredCode.isEmpty || sync.isBusy)
        } else {
            Button("Join another device instead") { isJoining = true }
        }
    }

    /// The live code, counting down, replaced by a clear notice once it lapses.
    @ViewBuilder
    private func pairingCode(_ pairing: SyncService.PairingCode) -> some View {
        // Re-renders every second so the countdown and the expiry are truthful.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if pairing.isExpired {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Code expired", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.orange)
                    Button("Get a new code") {
                        Task { await sync.createPairingCode() }
                    }
                    .disabled(sync.isBusy)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // The code is the thing to read off and type in, so it is
                    // set as the largest thing in the card rather than as the
                    // value half of a labelled row.
                    Text(SyncService.formatted(pairing.code))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Enter this on your other device — expires in \(timeLeft(pairing)). It works once.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func timeLeft(_ pairing: SyncService.PairingCode) -> String {
        let seconds = pairing.secondsRemaining
        return seconds >= 60
            ? "\(seconds / 60)m \(seconds % 60)s"
            : "\(seconds)s"
    }
}
