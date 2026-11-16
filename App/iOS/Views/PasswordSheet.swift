import SwiftUI

/// Asks for the password of an encrypted archive. Stays up with the error until the
/// password opens the archive or the user cancels.
struct PasswordSheet: View {
    let name: String
    /// Why the last password was rejected.
    let error: String?
    /// Shown under the error, in secondary text (a 7z that may be damaged).
    let hint: String?
    /// The password and whether to remember it in the Keychain.
    let unlock: @MainActor (_ password: String, _ remember: Bool) async -> Void
    let cancel: @MainActor () -> Void

    @State private var password = ""
    @State private var remember = false
    @State private var isUnlocking = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($isFieldFocused)
                        .submitLabel(.go)
                        .onSubmit(open)
                    Toggle("Remember in Keychain", isOn: $remember)
                } header: {
                    Text("“\(name)” is password protected.")
                } footer: {
                    if error != nil || hint != nil {
                        VStack(alignment: .leading, spacing: 4) {
                            if let error {
                                Text(error).foregroundStyle(.red)
                            }
                            if let hint {
                                Text(hint).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Enter Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Closing mid-unlock would leave the unlock to finish on a closed document.
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isUnlocking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", role: Self.confirmRole, action: open)
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty || isUnlocking)
                }
            }
        }
        // Opens at medium; large is there when a long name, a longer language or a large
        // Dynamic Type size pushes the error or the hint below the fold (or in landscape).
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .onAppear { isFieldFocused = true }
    }

    /// Open draws as the prominent confirm button on iOS 26. The title initializer keeps the
    /// "Open" label: the label-less `Button(role:action:)` would draw a checkmark instead.
    static var confirmRole: ButtonRole? {
        if #available(iOS 26.0, *) { .confirm } else { nil }
    }

    private func open() {
        guard !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        Task {
            await unlock(password, remember)
            // Still here means it was rejected: clear the field for the next try.
            password = ""
            isUnlocking = false
            isFieldFocused = true
        }
    }
}
