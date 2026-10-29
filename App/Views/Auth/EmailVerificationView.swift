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

/// Post-registration gate that mirrors the Android app's verification
/// screen. The server has issued an access token at this point, but the
/// verification status is `email_verified=false`. We poll
/// `/api/v1/auth/email/status` via
/// AuthManager.startEmailVerificationPolling (backing off from 5 s to
/// 30 s, and only while this screen is in the foreground) — when the
/// user clicks the link in their inbox, `emailVerified` flips and the
/// caller dismisses this view.
///
/// Unlike Android there is no "Skip for now": the screen offers Sign Out
/// instead (see the button below).
struct EmailVerificationView: View {
    @StateObject private var authManager = AuthManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var resending = false
    @State private var resendStatus: String?
    @State private var resendError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 32)

                Image(systemName: "envelope.badge.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(.blue)
                    .padding(.top, 24)

                Text("Verify Your Email")
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("We've sent a verification link to your email address. Please check your inbox and click the link to verify your account.")
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if let email = authManager.currentUser?.email {
                    Text(email)
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.top, 4)
                }

                VStack(spacing: 12) {
                    Button(action: openMailApp) {
                        Text("Open Email App")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 32)

                    Button(action: resend) {
                        if resending {
                            ProgressView()
                                .controlSize(.regular)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        } else {
                            Text("Resend Verification Email")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(resending)
                }
                .padding(.horizontal)

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for verification…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                if let resendStatus = resendStatus {
                    Text(resendStatus)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
                if let resendError = resendError {
                    Text(resendError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                // Sign-out escape hatch in case the user typed the
                // wrong email — Android offers the same affordance via
                // the toolbar back arrow. Skip-for-now is deliberately
                // NOT exposed: leaving an unverified account on the
                // device strands data + breaks SRP login if the user
                // forgets they registered.
                Button(role: .destructive) {
                    Task { await authManager.logout() }
                } label: {
                    Text("Sign Out")
                        .font(.footnote)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // Re-armed on each appear (with an immediate check) so a user
            // returning to this screen picks up verification at once.
            authManager.startEmailVerificationPolling()
        }
        .onDisappear {
            // Nothing polls for a screen nobody is looking at.
            authManager.stopEmailVerificationPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            // The poll stops while the app is off-screen (in the mail
            // app, say); back in the foreground is when the link was
            // probably just tapped, so check straight away.
            if phase == .active {
                authManager.startEmailVerificationPolling()
            } else if phase == .background {
                authManager.stopEmailVerificationPolling()
            }
        }
    }

    private func openMailApp() {
        // The Mail app registers `message://` as its URL scheme;
        // canOpenURL needs an Info.plist entry to query it but
        // we just attempt the open — UIApplication silently no-ops
        // if Mail is unavailable.
        if let url = URL(string: "message://"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        } else if let url = URL(string: "mailto:") {
            UIApplication.shared.open(url)
        }
    }

    private func resend() {
        resending = true
        resendStatus = nil
        resendError = nil
        Task {
            do {
                try await authManager.resendVerificationEmail()
                await MainActor.run {
                    resendStatus = "Verification email sent."
                    resending = false
                }
            } catch {
                await MainActor.run {
                    resendError = error.plainText
                    resending = false
                }
            }
        }
    }
}

#Preview {
    EmailVerificationView()
}
