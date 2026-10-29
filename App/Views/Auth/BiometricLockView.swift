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
import LocalAuthentication

struct BiometricLockView: View {
    let onUnlock: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAuthenticating = false
    /// Face ID or the passcode was asked for by itself for this lock.
    @State private var asked = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("Track is Locked")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Authenticate to continue")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: authenticate) {
                if isAuthenticating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Label(biometricLabel, systemImage: biometricIcon)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isAuthenticating)

            Spacer()
        }
        .padding()
        // Asked for by itself once Track is in front. Asked while it is
        // still coming back (the lock shows before that), iOS refuses
        // with "User interaction required".
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active && !asked {
                asked = true
                authenticate()
            }
        }
        .alert("Authentication Failed", isPresented: $showError) {
            Button("Try Again") {
                authenticate()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unable to authenticate")
        }
    }

    var biometricLabel: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID: return "Unlock with Face ID"
        case .touchID: return "Unlock with Touch ID"
        case .opticID: return "Unlock with Optic ID"
        default: return "Unlock"
        }
    }

    var biometricIcon: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        switch context.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open.fill"
        }
    }

    /// Pure: an answer that isn't the person's (Track not in front, or sent
    /// away during the prompt), with no "Authentication Failed" for it.
    static func asksAgainLater(_ error: Error) -> Bool {
        guard let error = error as? LAError else { return false }
        return [LAError.Code.notInteractive, .systemCancel, .appCancel].contains(error.code)
    }

    private func authenticate() {
        isAuthenticating = true

        Task {
            do {
                let success = try await AuthManager.shared.authenticateForAppLock()
                if success {
                    await MainActor.run {
                        onUnlock()
                    }
                }
            } catch {
                await MainActor.run {
                    if Self.asksAgainLater(error) {
                        // Not the person's answer: Track wasn't in front, or
                        // went away during the prompt. Asked again next time.
                        asked = false
                    } else {
                        errorMessage = error.plainText
                        showError = true
                    }
                }
            }

            await MainActor.run {
                isAuthenticating = false
            }
        }
    }
}

#Preview {
    BiometricLockView(onUnlock: {})
}
