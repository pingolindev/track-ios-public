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
import PingolinTrackSDK

/// Mounts a single "Is this really {name}?" question over whatever view is
/// currently on top whenever `MemberKeyPinner.alerts.first` is non-nil — a
/// member's identity changed, which in practice means they reset their
/// password. Mirrors the Android app's queue. "It's them" trusts exactly
/// the identity the question was raised for, on THIS device only; "Not now"
/// leaves the old one in place. The question shows the person's number and
/// says to check it another way when unsure; it is asked at most once a day
/// per member.
struct MemberKeyAlertHost: ViewModifier {
    @StateObject private var pinner = MemberKeyPinner.shared
    /// Nothing over App Lock: the question waits for the unlock.
    @SwiftUI.Environment(\.appLocked) private var appLocked
    /// Set when "It's them" did not take. Shown in its own alert: a failed
    /// approval must not pass silently as a block, or the person would believe
    /// they had confirmed it while the member's later deliveries are refused.
    @State private var approvalFailure: ApprovalFailure?

    private struct ApprovalFailure: Identifiable {
        let id = UUID()
        let displayName: String
        let reason: String
    }

    func body(content: Content) -> some View {
        content
            .alert(
                pinner.alerts.first.map(Self.title(for:)) ?? "",
                isPresented: Binding(
                    get: { !appLocked && pinner.alerts.first != nil },
                    set: { _ in }  // resolved through the buttons
                ),
                presenting: pinner.alerts.first
            ) { alert in
                Button("Not now", role: .cancel) { pinner.block(alert) }
                Button("It's them") { approve(alert) }
            } message: { alert in
                Text(Self.message(for: alert, circleName: circleName(for: alert)))
            }
            .alert(
                "Couldn't confirm it's them",
                isPresented: Binding(
                    get: { !appLocked && approvalFailure != nil },
                    set: { if !$0 && !appLocked { approvalFailure = nil } }
                ),
                presenting: approvalFailure
            ) { _ in
                Button("OK", role: .cancel) { approvalFailure = nil }
            } message: { failure in
                // ONE Text: SwiftUI shows only the first view of an alert message.
                Text("\(failure.reason)\n\nNothing was changed. Pingolin will ask again about \(failure.displayName) the next time the member list refreshes.")
            }
    }

    private func circleName(for alert: MemberKeyAlert) -> String? {
        CircleManager.shared.circles.first { $0.id == alert.circleId }?.readableName
    }

    /// The question's words. Static so a test can pin them.
    static func title(for alert: MemberKeyAlert) -> String {
        "Is this really \(alert.displayName)?"
    }

    /// One string: SwiftUI shows only the first view of an alert message.
    static func message(for alert: MemberKeyAlert, circleName: String?) -> String {
        var text = "\(alert.displayName) reset their password, so Pingolin can't tell on its own that it's still them. If you're sure, let them back into \(circleName ?? "this circle")."
        // Laid out as the Android app's `member_reset_check`, so all three read
        // alike.
        text += "\n\nIf you're not sure, check with \(alert.displayName) another way first."
        if let number = alert.number {
            text += " Their number: \(number)"
        }
        return text
    }

    private func approve(_ alert: MemberKeyAlert) {
        do {
            // "It's them": `CircleManager.answerItsThem`.
            try CircleManager.shared.answerItsThem(alert)
        } catch {
            approvalFailure = ApprovalFailure(
                displayName: alert.displayName,
                reason: error.plainText
            )
        }
    }
}
