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

struct LoginView: View {
    @StateObject private var authManager = AuthManager.shared
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var emailTouched = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case email, password }

    /// Shown under the field rather than in the failure alert: a malformed
    /// address is answerable before any request is made, and the alert's
    /// wording ("Couldn't sign in") cannot tell the user what to change.
    private var showEmailFormatError: Bool {
        emailTouched && !email.isEmpty && !EmailFormat.isPlausible(email)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)

                    Text("Track")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Private location sharing")
                        .font(.subheadline)
                        .foregroundStyle(Color.a11ySecondaryText)
                        // Reported by performAccessibilityAudit as clipped; without
                        // this the string loses its descenders and truncates outright
                        // at larger Dynamic Type sizes.
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Why this screen is showing when the person didn't
                // choose it (the key store's sync error): until they
                // sign in.
                if let notice = authManager.signInNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal)
                        .accessibilityIdentifier("login-sign-in-notice")
                }

                // Login Form
                VStack(spacing: 16) {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        // Only once they have moved on or pressed Sign In —
                        // marking an address invalid while it is half-typed is
                        // noise.
                        .onChange(of: focusedField) { _, new in
                            if new != .email && !email.isEmpty { emailTouched = true }
                        }

                    if showEmailFormatError {
                        Text("That doesn't look like an email address. Check for a missing \"@\" or a typo in the domain.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("login-email-format-error")
                    }

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit {
                            focusedField = nil
                            login()
                        }

                    Button(action: login) {
                        if authManager.isLoading {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text("Sign In")
                        }
                    }
                    .buttonStyle(A11yProminentButtonStyle())
                    .disabled(email.isEmpty || password.isEmpty || authManager.isLoading)
                    .frame(maxWidth: .infinity)

                    // Opens the account portal, which owns the whole reset
                    // flow. This app deliberately implements none of it: a
                    // link-out is the honest version and the one that cannot
                    // drift from the server's reset flow.
                    if let forgotURL = AppConfiguration.shared.forgotPasswordURL {
                        Link(destination: forgotURL) {
                            HStack(spacing: 4) {
                                Text("Forgot password?")
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .font(.footnote)
                    .tint(Color.a11yLink)
                        .fixedSize(horizontal: false, vertical: true)
                        // 15.7pt tall as laid out — far under the 44pt minimum
                        // target. contentShape makes the padded area actually
                        // tappable rather than just reserved.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("login-forgot-password")
                    }
                }
                .padding(.horizontal)

                Spacer()

                // Register link — OUT to the account portal, like
                // "Forgot password?" above and for the same reason. The
                // portal owns registration: the assisted lane for people
                // who cannot clear the CAPTCHA, guardian-managed signups,
                // email verification and the recovery key all live there.
                // The page opens inside the app (`InAppSafari`), never in
                // the Safari app (App Review, Guideline 4).
                if let registerURL = AppConfiguration.shared.registerURL {
                    HStack(spacing: 4) {
                        Text("Don't have an account?")
                            .foregroundStyle(Color.a11ySecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: registerURL) {
                            HStack(spacing: 4) {
                                Text("Sign Up")
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .tint(Color.a11yLink)
                        // As laid out this is well under the 44pt minimum
                        // target; the padded area has to be tappable, not just
                        // reserved.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("login-sign-up")
                    }
                    .font(.subheadline)
                }
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture { focusedField = nil }
            .sheet(isPresented: .constant(authManager.requires2FA)) {
                TwoFactorView()
            }
            .alert("Login Failed", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An error occurred")
            }
            // Signed out without asking: the address is filled in, so
            // the password is all that is asked.
            .onAppear {
                if email.isEmpty, let saved = authManager.signInEmail { email = saved }
            }
        }
    }

    private func login() {
        // Answer a malformed address here instead of spending a request and one
        // of the limiter's five attempts on it.
        emailTouched = true
        guard EmailFormat.isPlausible(email) else {
            focusedField = .email
            return
        }
        Task {
            do {
                try await authManager.login(email: email, password: password)
            } catch {
                errorMessage = Self.friendlyMessage(for: error)
                showingError = true
            }
        }
    }

    /// Translate the raw error into something a user can act on.
    /// APIError.errorDescription is a general plain line (never the
    /// server's text); sign-in has better words for its own cases.
    /// URLError lands here as the localized OS message which is
    /// inconsistent with the rest of the app's copy. We map the
    /// common cases explicitly.
    static let verifyEmailFirstText =
        "Please verify your email address first. Open the link we sent you, then sign in again."

    static func friendlyMessage(for error: Error) -> String {
        // The password was right and the keys still would not open: say that,
        // not "Couldn't sign in", which reads as a typo to retype.
        if let auth = error as? AuthManager.AuthError, case .keysUnavailable = auth,
           let text = auth.errorDescription {
            return text
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .dataNotAllowed,
                 .internationalRoamingOff:
                return "You're offline. Check your connection and try again."
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach the server. Try again in a moment."
            default:
                return "Network error. Check your connection and try again."
            }
        }
        if let api = error as? APIError {
            // The password was right, and the account's email isn't verified
            // yet: auth's SRP step 2 says so with its own code (a 403). Say what
            // to do, in the Android app's words, never "incorrect".
            if api.isServerCode("email_not_verified") {
                return Self.verifyEmailFirstText
            }
            switch api.code {
            case "rate_limited":
                return "Too many sign-in attempts. Try again in a moment."
            case "circuit_open":
                return "The sign-in service is briefly unavailable. Try again shortly."
            case "unauthorized",
                 "refresh_failed",
                 "http_401",
                 "http_403":
                return "Email or password is incorrect."
            case "http_404":
                // SRP step1 returns 200 for unknown users too (no
                // enumeration) so a 404 here would be a URL-shape
                // bug rather than bad creds — fall through to a
                // generic message instead of leaking the path.
                return "Couldn't sign in. Please try again."
            default:
                if api.code.hasPrefix("http_5") {
                    return "The sign-in service is having trouble. Try again in a moment."
                }
                return "Couldn't sign in. Please try again."
            }
        }
        return "Couldn't sign in. Please try again."
    }
}

#Preview {
    LoginView()
}
