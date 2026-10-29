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

/// The Plan card's two history elements: the entitlement line and the grace
/// countdown, both driven by GET /api/v1/quota rather than by the tier.
///
/// WHY THE DECODING HALF IS TESTED AT ALL
///   `historyExpiresInDays` is the only optional field on `TrackQuotaUsage`.
///   Had it been declared non-optional, a backend that predates it would fail
///   the WHOLE quota decode — and `PremiumManager.refreshQuota` swallows the
///   error and keeps the last-known value, so the card would silently freeze
///   rather than report anything. The absent-key case below is that guarantee.
final class PlanCardHistoryTests: XCTestCase {

    private func decode(_ json: String) throws -> TrackQuotaUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TrackQuotaUsage.self, from: Data(json.utf8))
    }

    private func quotaJSON(extra: String) -> String {
        """
        {"tier":"free","source":"none",
         "max_places":2,"current_places":0,"remaining_places":2,
         "max_circles":2,"current_circles":0,"remaining_circles":2,
         "max_place_alerts":2,"current_place_alerts":0,"remaining_place_alerts":2,
         "max_destinations":1,"current_destinations":0,"remaining_destinations":1,
         "max_members":5,"history_days":2,
         "destinations_enabled":true,"smart_alerts_enabled":false,"web_push_enabled":false
         \(extra)}
        """
    }

    // MARK: - Decoding

    func testHistoryExpiryDecodesWhenPresent() throws {
        let q = try decode(quotaJSON(extra: #", "history_expires_in_days": 5"#))
        XCTAssertEqual(q.historyExpiresInDays, 5)
        XCTAssertEqual(q.historyDays, 2)
    }

    /// The server sends `null` whenever nothing is counting down — premium
    /// active, or no premium ever held.
    func testExplicitNullMeansNothingIsCountingDown() throws {
        XCTAssertNil(try decode(quotaJSON(extra: #", "history_expires_in_days": null"#)).historyExpiresInDays)
    }

    /// An older backend omits the key entirely. This must NOT fail the decode:
    /// the whole card goes stale if it does.
    func testAbsentKeyDecodesRatherThanFailingTheWholeQuota() throws {
        let q = try decode(quotaJSON(extra: ""))
        XCTAssertNil(q.historyExpiresInDays)
        XCTAssertEqual(q.historyDays, 2, "the rest of the payload must still land")
    }

    // MARK: - Copy

    func testCountdownNamesTheDeletionNotTheAlreadyEndedSubscription() {
        let msg = SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2, premiumDays: 365)
        XCTAssertEqual(
            msg,
            "Location history older than 2 days is deleted in 5 days. "
            + "Circles with a premium member keep 365 days.")
        // The premise of the divergence from android: by the time the server
        // sends this the subscription has ALREADY ended, so copy claiming it is
        // about to would be describing the past as pending.
        XCTAssertFalse(msg.contains("Premium ends"))
    }

    // MARK: - The premium retention figure

    /// THE POINT OF THE PARAMETER. The premium figure comes from the server,
    /// never from a Swift literal: with a literal, changing the tier would need
    /// an App Store build to correct the one message a user acts on to save
    /// their data.
    ///
    /// `/api/v1/quota` does not expose the premium figure, and the reader of
    /// this message is on the free tier by construction, so their `history_days`
    /// is 2 and implies nothing about premium. Unknown therefore has to mean
    /// unquantified — not a guess, and not a stale literal.
    func testNoNumberIsClaimedWhenTheServerHasNotSentOne() {
        let msg = SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2, premiumDays: nil)
        XCTAssertEqual(
            msg,
            "Location history older than 2 days is deleted in 5 days. "
            + "Circles with a premium member keep a longer history.")
        // Specifically: no digits may survive into the premium clause. A
        // hard-coded figure would contain "365".
        XCTAssertFalse(msg.contains("365"), "never a hardcoded figure: \(msg)")
    }

    /// Omitting the argument is the same as not knowing it. Every call site
    /// that has not been updated must degrade to the honest sentence rather
    /// than to a default number.
    func testDefaultingTheArgumentIsTheSameAsUnknown() {
        XCTAssertEqual(
            SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2),
            SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2, premiumDays: nil))
    }

    /// A server-sent figure is rendered verbatim, whatever it is — that is the
    /// whole reason it is read from the server instead of compiled in.
    func testAServerSentFigureIsRenderedVerbatim() {
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2, premiumDays: 90)
            .hasSuffix("Circles with a premium member keep 90 days."))
        // keptDays 0 only so that 1 is still LONGER and reaches the numeric
        // branch — the assertion is about pluralisation, not about the guard.
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 0, premiumDays: 1)
            .hasSuffix("Circles with a premium member keep 1 day."),
            "1 must not render as \"1 days\"")
    }

    /// "Premium keeps 2 days" said to someone who already keeps 2 days is an
    /// argument for nothing. A figure that is not longer falls back rather than
    /// printing a sentence that undercuts itself.
    func testAFigureThatIsNotLongerFallsBackInsteadOfUnderminingItself() {
        for premium in [2, 1, 0, -1] {
            XCTAssertTrue(
                SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2, premiumDays: premium)
                    .hasSuffix("Circles with a premium member keep a longer history."),
                "premiumDays=\(premium) must not be printed as an upgrade")
        }
    }

    /// The field is optional so a backend that does not send it decodes as nil
    /// instead of failing the whole quota, the same guarantee
    /// `history_expires_in_days` carries above.
    func testPremiumHistoryDaysIsOptionalOnTheWire() throws {
        XCTAssertNil(try decode(quotaJSON(extra: "")).premiumHistoryDays)
        XCTAssertNil(try decode(quotaJSON(extra: #", "premium_history_days": null"#)).premiumHistoryDays)
        XCTAssertEqual(
            try decode(quotaJSON(extra: #", "premium_history_days": 365"#)).premiumHistoryDays, 365)
    }

    /// The warning must not point the user OUT of the app to buy.
    ///
    /// The basis is App Store guideline 3.1.3(b): an in-app "Subscribe" is not
    /// merely allowed but is the condition on which honouring web subscriptions
    /// here is permitted. So this does not forbid an upgrade prompt; it forbids
    /// sending someone to an EXTERNAL purchase, which is restricted outside the
    /// United States storefront.
    ///
    /// Asserted separately from the equality above because the equality says
    /// nothing about why the string is what it is: a future rewording would
    /// update it without anyone noticing a website had crept back in.
    func testHistoryWarningDoesNotSteerOutOfTheApp() {
        for daysLeft in [0, 1, 5, 30] {
            let msg = SettingsView.historyExpiryMessage(daysLeft: daysLeft, keptDays: 2)
            for external in ["pingolin.com", "http", "website", "our site"] {
                XCTAssertFalse(
                    msg.localizedCaseInsensitiveContains(external),
                    "history warning must not steer outside the app, found \(external): \(msg)")
            }
        }
        // Positive control: the warning still says the useful part, so the
        // assertions above cannot be passing on an empty or truncated string.
        let msg = SettingsView.historyExpiryMessage(daysLeft: 5, keptDays: 2)
        XCTAssertTrue(msg.contains("deleted"), "the warning itself must survive: \(msg)")
        XCTAssertTrue(msg.contains("premium member"),
                      "the premium retention must still be stated: \(msg)")
    }

    /// The server clamps the countdown at zero, so the last day of the grace
    /// window really does arrive as 0 — and "in 0 days" reads as a broken
    /// template.
    func testZeroAndOneReadAsTodayAndTomorrow() {
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: 0, keptDays: 2)
            .contains("is deleted today."))
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: 1, keptDays: 2)
            .contains("is deleted tomorrow."))
        // Defensive: a negative can only come from a server error, but it
        // must still not render "in -1 days".
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: -3, keptDays: 2)
            .contains("is deleted today."))
    }

    /// `keptDays` is interpolated from the server's `history_days`, not from a
    /// hardcoded free-tier 2 — the same rule that keeps 365 out of the summary
    /// line. So a server configured differently must be reflected verbatim.
    func testKeptDaysComesFromTheServerAndPluralisesCorrectly() {
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: 3, keptDays: 7)
            .hasPrefix("Location history older than 7 days"))
        XCTAssertTrue(SettingsView.historyExpiryMessage(daysLeft: 3, keptDays: 1)
            .hasPrefix("Location history older than 1 day is"),
            "1 must not render as \"1 days\"")
    }
}
