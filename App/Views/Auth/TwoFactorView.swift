// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Track.
//
// Pingolin Track is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Track is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Track. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

struct TwoFactorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authManager = AuthManager.shared
    @State private var code = ""
    /// Someone without their authenticator types one of the account's backup
    /// codes instead: 12 letters and digits.
    @State private var usingBackupCode = false
    @State private var backupCode = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    @FocusState private var isCodeFocused: Bool
    @FocusState private var isBackupCodeFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if authManager.twoFactorAcceptsCode {
                    codeEntry
                } else {
                    passkeyOnly
                }
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Only the challenge is dropped,
                        // never logout(), which wipes the
                        // keychain — nothing is signed in
                        // yet here, but a device whose
                        // session merely expired still
                        // holds the account's keys, and
                        // Cancel must not destroy them.
                        authManager.cancelTwoFactor()
                        dismiss()
                    }
                }
            }
            .alert("Verification Failed", isPresented: $showingError) {
                Button("OK", role: .cancel) {
                    code = ""
                    backupCode = ""
                    if authManager.tempToken == nil {
                        // The code was accepted, which spends the challenge, and
                        // the sign-in then failed (keys, network). There is
                        // nothing left to retry here: back to the password.
                        authManager.cancelTwoFactor()
                        dismiss()
                    } else if usingBackupCode {
                        isBackupCodeFocused = true
                    } else {
                        isCodeFocused = true
                    }
                }
            } message: {
                Text(errorMessage ?? "Invalid code")
            }
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("Two-Factor Authentication")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(usingBackupCode ? "Enter one of your backup codes"
                                     : "Enter the 6-digit code from your authenticator app")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            if usingBackupCode {
                backupCodeField
            } else {
                authenticatorCodeField
            }

            Button(action: usingBackupCode ? verifyBackupCode : verify) {
                if authManager.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Verify")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled((usingBackupCode ? Self.codeToSend(backupCode).isEmpty : code.count != 6) || authManager.isLoading)

            Spacer()

            // Help text
            VStack(spacing: 8) {
                Text("Having trouble?")
                    .foregroundStyle(.secondary)

                Button(usingBackupCode ? "Use your authenticator app" : "Use a backup code") {
                    usingBackupCode.toggle()
                    code = ""
                    backupCode = ""
                    if usingBackupCode {
                        isBackupCodeFocused = true
                    } else {
                        isCodeFocused = true
                    }
                }
                .font(.footnote)
                .accessibilityIdentifier("two-factor-use-backup-code")
            }
        }
        .onAppear {
            isCodeFocused = true
        }
    }

    /// The 6-digit authenticator code: a number pad, sent by itself at 6.
    private var authenticatorCodeField: some View {
        TextField("000000", text: $code)
            .font(.system(size: 32, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($isCodeFocused)
            .onChange(of: code) { _, newValue in
                // Limit to 6 digits
                if newValue.count > 6 {
                    code = String(newValue.prefix(6))
                }
                // Auto-submit when 6 digits entered
                if newValue.count == 6 {
                    verify()
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal, 40)
    }

    /// A backup code: letters and digits, often written in groups. Sent only
    /// when the person says so (Verify, or return), never by itself at some
    /// length, and whole (`codeToSend`).
    private var backupCodeField: some View {
        TextField("Backup code", text: $backupCode)
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .multilineTextAlignment(.center)
            .keyboardType(.asciiCapable)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isBackupCodeFocused)
            .submitLabel(.go)
            .onSubmit(verifyBackupCode)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .padding(.horizontal, 40)
            .accessibilityIdentifier("two-factor-backup-code")
    }

    /// The account's only second factor is a passkey, and this app cannot
    /// perform a passkey assertion. A code box here asks for a code the
    /// person does not have and cannot get, with no way to learn why — so
    /// say it, and point at the two ways out. No "Verify" button: nothing
    /// typed here could ever be accepted, and the app never submits a typed
    /// code as `method: "passkey"`.
    private var passkeyOnly: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Passkey Required")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(Self.passkeyOnlyMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("two-factor-passkey-only")
            }

            if let url = AppConfiguration.shared.securitySettingsURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("Open account settings")
                        Image(systemName: "arrow.up.right.square")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("two-factor-open-security-settings")
            }

            Spacer()
        }
    }

    /// The same wording in every native app. Static so a test can pin it.
    static let passkeyOnlyMessage =
        "This account's second step uses a passkey, which this app can't use yet. "
        + "Add an authenticator app in your account settings, or sign in on the web."

    private func verify() {
        guard code.count == 6 else { return }
        submit(code)
    }

    private func verifyBackupCode() {
        let sent = Self.codeToSend(backupCode)
        guard !sent.isEmpty else { return }
        submit(sent)
    }

    /// Either kind goes to the same /auth/login/2fa, as its `code`; a refusal
    /// is said, and the sheet stays or goes by what it was.
    private func submit(_ sent: String) {
        Task {
            do {
                try await authManager.verify2FA(code: sent)
                dismiss()
            } catch {
                errorMessage = error.plainText
                showingError = true
            }
        }
    }

    /// The code as auth takes it, as the portal sends it (`codeToSend`): without
    /// the spaces and dashes it was typed or pasted with. Nothing is cut, and the
    /// case is left alone (auth compares backup codes without regard to it).
    nonisolated static func codeToSend(_ typed: String) -> String {
        typed.filter { !$0.isWhitespace && $0 != "-" }
    }
}

#Preview {
    TwoFactorView()
}
