import SwiftUI

/// Sync setup UI: turn sync on, then pair other devices with a one-time code.
/// No account, no password, no email.
struct SyncSettingsSection: View {
    @Bindable var sync: SyncService
    @State private var enteredCode = ""
    @State private var isJoining = false

    var body: some View {
        Section {
            switch sync.state {
            case .off, .failed:
                Button("Turn on sync") {
                    Task { await sync.enableSync() }
                }
                .disabled(sync.isBusy)

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

            case .syncing(let pairing):
                Label("Syncing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if let pairing {
                    pairingCode(pairing)
                } else {
                    Button("Pair another device") {
                        Task { await sync.createPairingCode() }
                    }
                    .disabled(sync.isBusy)
                }

                Button("Turn off sync", role: .destructive) {
                    Task { await sync.stopSync() }
                }
            }

            if case .failed(let message) = sync.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let writeError = sync.lastSyncError {
                Label("Couldn't save to the server — \(writeError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Sync")
        }
    }

    /// The live code, counting down, replaced by a clear notice once it lapses.
    @ViewBuilder
    private func pairingCode(_ pairing: SyncService.PairingCode) -> some View {
        // Re-renders every second so the countdown and the expiry are truthful.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if pairing.isExpired {
                Label("Code expired", systemImage: "clock.badge.xmark")
                    .foregroundStyle(.orange)
                Button("Get a new code") {
                    Task { await sync.createPairingCode() }
                }
                .disabled(sync.isBusy)
            } else {
                LabeledContent("Pairing code", value: SyncService.formatted(pairing.code))
                    .font(.system(.body, design: .monospaced))
                Text("Enter this on your other device — expires in \(timeLeft(pairing)). It works once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
