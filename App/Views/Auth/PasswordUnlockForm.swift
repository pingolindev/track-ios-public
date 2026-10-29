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

/// The password, asked for right where something needs it — a locked
/// circle, the personal-history notice — instead of "sign out, then sign
/// in again". Typing it opens the account on this device
/// (`AuthManager.unlockWithPassword`) and everything carries on: nothing is
/// signed out and nothing is lost.
///
/// The password is the one thing only the person has, so it is the one thing
/// asked. Without a connection the form keeps what was typed and tries again by
/// itself while it is on screen.
struct PasswordUnlockForm: View {
    @State private var password = ""
    @State private var working = false
    @State private var message: String?
    @State private var attempt: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.continue)
                .onSubmit(unlock)
                .disabled(working)
                .accessibilityIdentifier("unlock-password")
            HStack(spacing: 10) {
                Button("Continue", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || working)
                    .accessibilityIdentifier("unlock-continue")
                if working {
                    ProgressView()
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("unlock-message")
            }
        }
        .padding(.vertical, 4)
        .onDisappear {
            attempt?.cancel()
            attempt = nil
        }
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        let typed = password
        working = true
        message = nil
        attempt = Task { @MainActor in
            var failures = 0
            tries: while !Task.isCancelled {
                do {
                    try await AuthManager.shared.unlockWithPassword(typed)
                    password = ""
                    message = nil
                    break tries
                } catch {
                    switch Self.outcome(of: error) {
                    case .waitForConnection:
                        message = Self.waitingText
                        failures += 1
                        try? await Task.sleep(nanoseconds: UInt64(RetryClock.delay(afterFailures: failures) * 1_000_000_000))
                    case .wrongPassword:
                        message = Self.wrongPasswordText
                        password = ""
                        break tries
                    case .needsSignIn:
                        message = Self.needsSignInText
                        break tries
                    case .failed:
                        message = Self.failedText
                        break tries
                    }
                }
            }
            working = false
        }
    }

    // MARK: - What each failure means

    enum Outcome: Equatable {
        /// The password did not open the account: the person's to retype.
        case wrongPassword
        /// No answer came back: tried again by itself.
        case waitForConnection
        /// The one case auth says only a sign-in fixes: a two-credential
        /// (guardian) account whose session predates credential binding (409).
        case needsSignIn
        /// Anything else. Nothing typed again would change it.
        case failed
    }

    nonisolated static func outcome(of error: Error) -> Outcome {
        if let api = error as? APIError {
            // The server's answer to the proof (re-auth step 2).
            if api.isServerCode("invalid_credentials") { return .wrongPassword }
            // A refused session ends it; the sign-in screen follows.
            if APIError.isSessionDefinitivelyExpired(api) { return .failed }
            if api.code == "http_409" { return .needsSignIn }
        }
        if let vault = error as? AuthManager.VaultDerivationError {
            return vault == .masterKeyOpen ? .wrongPassword : .failed
        }
        if error is AuthManager.AuthError { return .failed }
        return RetryClock.nothingAnswered(error) ? .waitForConnection : .failed
    }

    static let wrongPasswordText = "That password isn't right."
    static let waitingText = "Waiting for a connection…"
    static let needsSignInText = "To open your account on this iPhone, sign in again with your password."
    static let failedText = "Something went wrong opening your account."
}
