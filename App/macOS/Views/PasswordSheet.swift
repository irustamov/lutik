import Accessibility
import SwiftUI

/// Asks for the password of an archive whose listing is encrypted.
struct PasswordSheet: View {
    let name: String
    /// Set after a wrong password.
    let error: String?
    /// Also say the archive may be damaged (a repeated wrong 7z password).
    var showsDamagedHint = false
    let open: (_ password: String, _ remember: Bool) async -> Void
    let cancel: () -> Void

    @State private var password = ""
    @State private var remember = false
    @State private var isOpening = false
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Text("“\(name)” is password-protected.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                    .focused($isPasswordFocused)
                if let error {
                    Text(error)
                        .foregroundStyle(.secondary)
                    if showsDamagedHint {
                        Text("If the password is right, the archive may be damaged.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle("Remember in Keychain", isOn: $remember)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    // An attempt in flight finishes first: it may still open or close the document.
                    .disabled(isOpening)
                Button("Open") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty || isOpening)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
        .onAppear { isPasswordFocused = true }
        // Focus goes back to the empty field after a wrong password; say why.
        .onChange(of: isOpening) { _, isOpening in
            if !isOpening, let error {
                AccessibilityNotification.Announcement(error).post()
            }
        }
    }

    private func submit() {
        isOpening = true
        Task {
            await open(password, remember)
            isOpening = false
            // Runs after every attempt. If the password was wrong the sheet is still up, so this
            // clears and refocuses the field for another try; otherwise the sheet is going away.
            password = ""
            isPasswordFocused = true
        }
    }
}
