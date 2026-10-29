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

/// The wire contract and the fail-closed posture around App Store purchases.
///
/// WHAT IS NOT TESTED HERE, AND WHY
///   Nothing drives StoreKit itself. `Product.purchase` needs a StoreKit test
///   session and a configured App Store Connect product; a unit test that mocked
///   it would assert against our own mock and prove nothing about a real
///   purchase. That takes a purchase in the App Store sandbox.
///
///   What IS worth pinning without a store is the part that decides whether we
///   sell at all, and the part that decides who a purchase belongs to. Both are
///   pure, both are easy to get wrong in a way no crash reveals, and both cost
///   the customer money when wrong.
final class ApplePurchaseTests: XCTestCase {

    // MARK: - Eligibility decoding

    /// The server sends snake_case; APIService decodes with
    /// `.convertFromSnakeCase`. If this drifts, the sheet silently falls into its
    /// error path and nobody can buy anything.
    func testEligibilityDecodesFromServerJSON() throws {
        let json = """
        {"can_purchase": false,
         "reason": "You already subscribe to Track on the web.",
         "existing_provider": "paddle"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let eligibility = try decoder.decode(ApplePurchaseEligibility.self, from: json)

        XCTAssertFalse(eligibility.canPurchase)
        XCTAssertEqual(eligibility.existingProvider, "paddle")
        XCTAssertEqual(eligibility.reason, "You already subscribe to Track on the web.")
    }

    /// The permitted case carries no reason and no provider. Both are optional
    /// for exactly this shape, and declaring either non-optional would fail the
    /// decode on every eligible user — i.e. block the purchase path for everyone
    /// who is actually allowed to buy.
    func testEligibilityDecodesThePermittedCase() throws {
        let json = #"{"can_purchase": true, "reason": null, "existing_provider": null}"#
            .data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let eligibility = try decoder.decode(ApplePurchaseEligibility.self, from: json)

        XCTAssertTrue(eligibility.canPurchase)
        XCTAssertNil(eligibility.reason)
        XCTAssertNil(eligibility.existingProvider)
    }

    /// Absent keys, not just null ones — an older backend, or a field dropped
    /// later, must not fail the whole decode and take the purchase path with it.
    func testEligibilityToleratesAbsentOptionalKeys() throws {
        let json = #"{"can_purchase": true}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let eligibility = try decoder.decode(ApplePurchaseEligibility.self, from: json)
        XCTAssertTrue(eligibility.canPurchase)
    }

    // MARK: - The link request

    /// `appAccountToken` is the only thing in Apple's payload that names an
    /// account. The server refuses a transaction without one and refuses one
    /// naming somebody else, so a purchase started with a non-UUID user id would
    /// charge the customer and grant nothing.
    ///
    /// `StoreKitManager.purchase` refuses before reaching StoreKit for that
    /// reason. This pins the parse it depends on.
    func testUserIDMustParseAsUUIDForTheAccountToken() {
        // The real shape: what /auth/me returns for `id`.
        XCTAssertNotNil(UUID(uuidString: "3f8c2b1a-9d4e-4c7b-8a15-2e6f0b9d7c31"))
        // Things that must NOT be silently accepted as an account token.
        XCTAssertNil(UUID(uuidString: ""))
        XCTAssertNil(UUID(uuidString: "not-a-uuid"))
        XCTAssertNil(UUID(uuidString: "3f8c2b1a9d4e4c7b8a152e6f0b9d7c31"))
    }

    /// The body must reach the server as `signed_transaction`; the server
    /// reads exactly that. APIService's encoder converts to snake_case, so
    /// this pins the conversion rather than the literal.
    func testLinkRequestEncodesToSnakeCase() throws {
        struct Body: Encodable { let signedTransaction: String }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(Body(signedTransaction: "header.payload.sig"))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["signed_transaction"] as? String, "header.payload.sig")
        XCTAssertNil(object["signedTransaction"], "camelCase would not deserialise server-side")
    }

    // MARK: - Product configuration

    /// The SKUs must match what is configured in App Store Connect, and there
    /// must be no bundle SKU: bundles are web-only by product decision.
    func testProductIdentifiers() {
        XCTAssertEqual(StoreKitManager.ProductID.all.count, 2)
        XCTAssertTrue(StoreKitManager.ProductID.all.contains("com.pingolin.track.premium.monthly"))
        XCTAssertTrue(StoreKitManager.ProductID.all.contains("com.pingolin.track.premium.yearly"))
        XCTAssertFalse(
            StoreKitManager.ProductID.all.contains { $0.contains("bundle") },
            "bundles are web-only — an iOS bundle SKU would need that decision revisited")
    }

    /// The slug sent to the eligibility endpoint has to be the one auth knows,
    /// or the lookup 404s and the sheet falls into its fail-closed path — nobody
    /// can buy, and the reason is a typo.
    func testEligibilityUsesTheServersProductSlug() {
        XCTAssertEqual(StoreKitManager.productSlug, "track")
    }
}

// MARK: - Subscription terms

/// The paywall must state the price PER PERIOD and link to terms and privacy
/// before the customer buys — Schedule 2 of the Developer Program License
/// Agreement, which guideline 3.1.2(c) points at. A missing period or a dead
/// link is one of the most routine subscription rejections there is.
extension ApplePurchaseTests {

    func testPeriodLabelReadsNaturallyNextToAPrice() {
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .month, value: 1), "month")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .year, value: 1), "year")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .week, value: 1), "week")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .day, value: 1), "day")
    }

    /// Apple allows multi-unit periods (a 3-month subscription is one product,
    /// not three). "$9.00 / 3 month" would read as a typo on a paywall.
    func testMultiUnitPeriodsPluralise() {
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .month, value: 3), "3 months")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .day, value: 14), "14 days")
        XCTAssertEqual(StoreKitManager.periodLabel(unit: .year, value: 2), "2 years")
    }

    /// The links have to be real URLs and have to be the pages we actually
    /// serve. A 404 here is a dead link on a paywall, which fails review as
    /// surely as no link at all.
    func testLegalLinksPointAtTheServedPages() {
        XCTAssertEqual(StoreKitManager.Legal.terms.absoluteString, "https://pingolin.com/terms")
        XCTAssertEqual(StoreKitManager.Legal.privacy.absoluteString, "https://pingolin.com/privacy")
        // https, not http: an insecure link on a purchase screen is its own
        // rejection reason.
        XCTAssertEqual(StoreKitManager.Legal.terms.scheme, "https")
        XCTAssertEqual(StoreKitManager.Legal.privacy.scheme, "https")
    }

    // MARK: - Restore Purchases

    /// The result the Restore Purchases button shows, decided without StoreKit.
    func testRestoreOutcomeReportsWhatWasFound() {
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 1, error: nil), .restored)
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 2, error: nil), .restored)
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 0, error: nil), .nothingToRestore)
    }

    /// A refusal outranks the count: a subscription the server will not accept
    /// (another account's purchase, a family-shared one) is not a restore, and
    /// the refusal's words (the app's, by code: `refusalText`) are what the user
    /// reads.
    func testRestoreRefusalOutranksTheCount() {
        let refusal = "This purchase belongs to a different account"
        XCTAssertEqual(StoreKitManager.restoreOutcome(found: 1, error: refusal), .failed(refusal))
        XCTAssertEqual(StoreKitManager.RestoreOutcome.failed(refusal).message, refusal)
    }

    func testRestoreMessages() {
        XCTAssertNil(StoreKitManager.RestoreOutcome.cancelled.message,
                     "dismissing the App Store sign-in is not an error and must say nothing")
        XCTAssertEqual(StoreKitManager.RestoreOutcome.restored.message,
                       "Your App Store subscription has been restored.")
        XCTAssertEqual(StoreKitManager.RestoreOutcome.nothingToRestore.message,
                       "No active App Store subscription was found for this Apple ID.")
    }
}
