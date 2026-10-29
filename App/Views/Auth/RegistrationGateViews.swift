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

/// The words of the two screens an account not approved gets in place of the
/// app (the same words on web and Android). Static so a test can pin them.
enum RegistrationGateCopy {
    static let underReviewTitle = "Your account is under review"
    static let underReviewBody = "Your account request is checked by an admin before access is granted. "
        + "We'll email you the moment it's approved — then Track unlocks automatically."
    static let notApprovedTitle = "Your application wasn't approved"
    static let notApprovedBody = "This account can't be used with Track. "
        + "We delete it, and your application, 30 days after the decision."
    static let needHelp = "Need help?"
    static let contactSupport = "Contact support"

    static func signedInAs(_ email: String) -> String {
        "Signed in as \(email)"
    }
}

/// An assisted-lane account an admin hasn't decided yet (`registration_status`
/// "pending"): this screen and nothing of Track's, since Track refuses its
/// token. It watches /auth/me while it is in front (`startApprovalPolling`);
/// approval opens the app, a refusal the not-approved screen.
struct UnderReviewView: View {
    @StateObject private var authManager = AuthManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RegistrationGateScreen(
            systemImage: "hourglass",
            title: RegistrationGateCopy.underReviewTitle,
            message: RegistrationGateCopy.underReviewBody,
            email: authManager.currentUser?.email)
        .onAppear { authManager.startApprovalPolling() }
        .onDisappear { authManager.stopApprovalPolling() }
        .onChange(of: scenePhase) { _, phase in
            // Back in front is when an approval e-mail was probably just read.
            if phase == .active {
                authManager.startApprovalPolling()
            } else if phase == .background {
                authManager.stopApprovalPolling()
            }
        }
    }
}

/// An application an admin turned down (`registration_status` "rejected"):
/// this screen, no app behind it, nothing tracked. Auth deletes the account,
/// and the application with it, 30 days after the decision.
struct NotApprovedView: View {
    @StateObject private var authManager = AuthManager.shared

    var body: some View {
        RegistrationGateScreen(
            systemImage: "xmark.circle",
            title: RegistrationGateCopy.notApprovedTitle,
            message: RegistrationGateCopy.notApprovedBody,
            email: authManager.currentUser?.email)
    }
}

/// The shape both screens share: what happened, who is signed in, where to get
/// help (the portal's public support page, which needs no session), Sign Out.
private struct RegistrationGateScreen: View {
    @StateObject private var authManager = AuthManager.shared
    let systemImage: String
    let title: String
    let message: String
    let email: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer().frame(height: 32)

                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .padding(.top, 24)

                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                Text(message)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                if let email {
                    Text(RegistrationGateCopy.signedInAs(email))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }

                if let support = AppConfiguration.shared.publicSupportURL {
                    HStack(spacing: 4) {
                        Text(RegistrationGateCopy.needHelp)
                        Link(RegistrationGateCopy.contactSupport, destination: support)
                    }
                    .font(.system(size: 15))
                    .padding(.top, 8)
                }

                Button {
                    Task { await authManager.logout() }
                } label: {
                    Text("Sign Out")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
    }
}
