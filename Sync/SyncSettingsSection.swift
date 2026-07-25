import SwiftUI

/// Sign-in / status UI for cross-device sync, shown inside Settings.
struct SyncSettingsSection: View {
    @Bindable var sync: SyncService
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        Section {
            switch sync.state {
            case .signedOut, .failed:
                TextField("Email", text: $email)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    #endif
                    .disableAutocorrection(true)
                Button("Send code") {
                    Task { await sync.sendCode(to: email.trimmingCharacters(in: .whitespaces)) }
                }
                .disabled(email.isEmpty || sync.isBusy)

            case .awaitingCode(let pending):
                Text("Code sent to \(pending)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("6-digit code", text: $code)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Verify") {
                    Task { await sync.verifyCode(code.trimmingCharacters(in: .whitespaces), email: pending) }
                }
                .disabled(code.isEmpty || sync.isBusy)

            case .syncing(let signedInEmail):
                LabeledContent("Signed in", value: signedInEmail)
                Button("Sign out", role: .destructive) {
                    Task { await sync.signOut() }
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
            Text("Signs you in with a one-time code by email, then keeps the timer, log and settings in step across your devices.")
        }
    }
}
