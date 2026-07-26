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

            case .syncing(let code):
                Label("Syncing", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if let code {
                    LabeledContent("Pairing code", value: SyncService.formatted(code))
                        .font(.system(.body, design: .monospaced))
                    Text("Enter this on your other device within 5 minutes. It works once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        } header: {
            Text("Sync")
        } footer: {
            Text("Keeps the timer, log and settings in step across your devices. No account or password — pair a device with a one-time code.")
        }
    }
}
