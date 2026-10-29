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

import XCTest
@testable import Track

/// What a failed place-alert save turns into.
///
/// A free user who hits the place-alert limit gets the upgrade sheet, just as
/// the place-CREATE path in the same file calls `PremiumPrompt.forGate` —
/// never the raw server sentence in the red inline row, which would present a
/// quota as a fault, with no offer and nothing to tap. Both halves of one
/// screen agree about what a 402 means.
final class PlaceAlertSaveOutcomeTests: XCTestCase {

    private func outcome(_ error: APIError) -> PlaceAlertEditorSheet.SaveOutcome {
        PlaceAlertEditorSheet.outcome(for: error)
    }

    // MARK: - Gates become upgrade prompts

    /// A structured quota 402 must reach the upgrade sheet.
    func testAQuotaGateBecomesAnUpgradePrompt() {
        let error = APIError(
            code: "payment_required",
            message: "Place alert limit reached",
            errorCode: "quota_place_alerts_exceeded",
            quota: QuotaError(resource: "place_alerts", isCountLimit: true, current: 2, limit: 2, tier: "free")
        )

        guard case .upgrade(let prompt) = outcome(error) else {
            return XCTFail("a 402 quota must offer an upgrade, not render as an error")
        }
        XCTAssertEqual(prompt.title, "Unlimited place alerts")
        XCTAssertEqual(prompt.usage, "2 of 2 place alerts used",
                       "the counts are the whole point of the structured quota")
    }

    /// A feature gate arrives without a quota envelope — only an `error_code`.
    /// `isPremiumGate` accepts the `premium_required` prefix, and this path has
    /// to accept it too or the same failure mode returns for feature gates.
    func testAFeatureGateWithNoQuotaObjectStillPrompts() {
        let error = APIError(
            code: "payment_required",
            message: "Premium required",
            errorCode: "premium_required_place_alerts",
            quota: nil
        )

        guard case .upgrade = outcome(error) else {
            return XCTFail("a premium_required gate must offer an upgrade")
        }
    }

    /// The raw server sentence must NOT be what a gated user reads.
    func testTheRawServerMessageIsNotWhatAGatedUserSees() {
        let error = APIError(
            code: "payment_required",
            message: "quota exceeded: place_alerts 2/2",
            errorCode: "quota_place_alerts_exceeded",
            quota: QuotaError(resource: "place_alerts", isCountLimit: true, current: 2, limit: 2, tier: "free")
        )

        if case .message(let text) = outcome(error) {
            XCTFail("gated save rendered as an inline error: \(text)")
        }
    }

    // MARK: - What must NOT become an upgrade prompt

    /// A 403 about somebody else's privacy choice. No subscription changes it,
    /// so an upgrade sheet here would be selling a fix that does not exist.
    /// Checked before the gate arm for exactly that reason.
    func testAnOptedOutTargetStaysAnExplanation() {
        let error = APIError(
            code: "ALERT_RECIPIENT_OPTED_OUT",
            message: "recipient opted out",
            errorCode: nil,
            quota: nil
        )

        guard case .message(let text) = outcome(error) else {
            return XCTFail("a privacy refusal must not be sold as an upgrade")
        }
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Allow alerts on me"),
                      "must name the setting the other person turned off; got: \(text)")
        XCTAssertNotEqual(text, "recipient opted out",
                          "must not echo the server code at the user")
    }

    /// Precedence, stated. Even carrying a quota envelope, the opted-out code
    /// wins — the ordering is the thing being pinned, not today's server shape.
    func testTheOptedOutCodeWinsOverAGate() {
        let error = APIError(
            code: "ALERT_RECIPIENT_OPTED_OUT",
            message: "recipient opted out",
            errorCode: "quota_place_alerts_exceeded",
            quota: QuotaError(resource: "place_alerts", isCountLimit: true, current: 2, limit: 2, tier: "free")
        )

        guard case .message = outcome(error) else {
            return XCTFail("opted-out must be checked before the premium gate")
        }
    }

    /// An ordinary failure keeps the inline row, in the app's words (never the
    /// server's). Fails safe: an error with no `error_code` and no quota is not
    /// a gate, so routing it to the upgrade sheet would hide a real problem
    /// behind a sales pitch.
    func testAnOrdinaryFailureStaysInline() {
        let error = APIError(
            code: "internal_error",
            message: "Failed to save place alert",
            errorCode: nil,
            quota: nil
        )

        guard case .message(let text) = outcome(error) else {
            return XCTFail("a 500 is not an upgrade opportunity")
        }
        XCTAssertEqual(text, "That didn't work. Please try again.")
    }
}
