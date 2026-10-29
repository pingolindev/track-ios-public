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

/// What the server's refusals are turned into on screen.
///
/// The client does not decide who may open or refuse a claim — the server does,
/// and it checks the caller's role precisely so no client has to guess. But its
/// refusals travel as generic strings, and iOS renders an `APIError` as
/// `message [code]`, so without this the person who tapped would read
/// "Insufficient permissions [http_403]" at the moment their circle is stuck
/// and its owner is unreachable.
///
/// Anything unrecognised gets the error's plain line, never the server's own
/// words: they can carry anything a hacked server wants shown.
final class OwnershipClaimFailureCopyTests: XCTestCase {

    private func apiError(_ code: String, _ message: String, errorCode: String? = nil) -> APIError {
        APIError(code: code, message: message, errorCode: errorCode)
    }

    // MARK: - Opening a claim

    /// The server answers a non-admin member with a bare "Insufficient
    /// permissions". The reply has to name the actual rule and leave the
    /// person somewhere to go.
    func testANonAdminIsToldWhoCanAskAndWhatToDo() {
        let copy = OwnershipClaimCopy.openFailure(apiError("http_403", "Insufficient permissions"))

        XCTAssertFalse(copy.contains("Insufficient permissions"), copy)
        XCTAssertTrue(copy.contains("Only an admin"), copy)
        XCTAssertTrue(copy.lowercased().contains("ask"), "leave them a next step: \(copy)")
    }

    /// The 409 for an existing claim — two admins racing, or one who already
    /// asked. The server puts the machine code in both the envelope's
    /// `error_code` and (through APIResponse's mapping) the APIError's
    /// `code`, so either has to match.
    func testAnExistingClaimIsExplainedFromEitherField() {
        let viaErrorCode = OwnershipClaimCopy.openFailure(
            apiError("http_409", "Somebody has already asked to take over this circle",
                     errorCode: "circle_ownership_claim_exists")
        )
        let viaCode = OwnershipClaimCopy.openFailure(
            apiError("circle_ownership_claim_exists", "Somebody has already asked to take over this circle")
        )

        for copy in [viaErrorCode, viaCode] {
            XCTAssertTrue(copy.contains("already asked"), copy)
            XCTAssertTrue(copy.contains("now shows"), "the screen re-reads the claim by itself: \(copy)")
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("pull down"),
                           "never ask for what the app does itself: \(copy)")
        }
    }

    /// The server answers "not a member" and "no such circle" identically so
    /// that membership cannot be probed by an outsider. The client must not
    /// invent certainty the server deliberately withheld.
    func testTheAmbiguous404StaysAmbiguous() {
        let copy = OwnershipClaimCopy.openFailure(
            apiError("http_404", "Circle not found or you're not a member")
        )
        XCTAssertTrue(copy.contains("isn't there any more"), copy)
        XCTAssertTrue(copy.contains("no longer a member"), copy)
    }

    /// The claim route's one 400 means the caller owns the circle: said in
    /// the app's words.
    func testTheOnlyBadRequestIsSaidInTheAppsWords() {
        XCTAssertEqual(
            OwnershipClaimCopy.openFailure(apiError("http_400", "anything at all")),
            "You already own this circle."
        )
    }

    /// A code this client has never seen gets a plain line, never the server's
    /// text.
    func testAnUnknownServerFailureIsAPlainLine() {
        XCTAssertEqual(
            OwnershipClaimCopy.openFailure(apiError("http_503", "Ownership claims are paused")),
            "Pingolin is having trouble just now. Please try again in a moment."
        )
    }

    /// A dropped connection isn't an APIError at all.
    func testANonAPIErrorFallsBackToItsOwnDescription() {
        let urlError = URLError(.notConnectedToInternet)
        XCTAssertEqual(
            OwnershipClaimCopy.openFailure(urlError),
            urlError.localizedDescription
        )
    }

    // MARK: - Refusing

    /// The refuse route answers 404 only AFTER confirming the caller is the
    /// owner, so this is the one place the client can say "the circle is still
    /// yours" as a fact rather than as reassurance — and it is exactly what
    /// somebody wants to know after tapping Refuse and getting an error.
    func testARefusalWithNothingToRefuseSaysTheCircleIsStillTheirs() {
        let copy = OwnershipClaimCopy.refuseFailure(
            apiError("http_404", "There is no live claim on this circle")
        )
        XCTAssertTrue(copy.contains("still yours"), copy)
        XCTAssertTrue(copy.contains("withdrawn"), "name the likely reason: \(copy)")
    }

    /// The server checks ownership atomically with the refusal, so a 403
    /// means the circle is not theirs at the moment they tapped — which, on
    /// this screen, most likely means it has already changed hands. Hedged,
    /// because the client cannot tell that apart from never having owned it.
    func testARefusalFromANonOwnerRaisesThePossibilityWithoutAssertingIt() {
        let copy = OwnershipClaimCopy.refuseFailure(
            apiError("http_403", "Only the owner can refuse a claim on their circle")
        )
        XCTAssertTrue(copy.contains("may have already changed"), copy)
        XCTAssertFalse(copy.contains("has already changed"), "the client cannot know that: \(copy)")
        XCTAssertFalse(copy.localizedCaseInsensitiveContains("pull down"),
                       "the screen re-reads the claim by itself: \(copy)")
    }

    func testAnUnknownRefusalFailureIsAPlainLine() {
        XCTAssertEqual(
            OwnershipClaimCopy.refuseFailure(apiError("http_500", "Failed to refuse the claim")),
            "Pingolin is having trouble just now. Please try again in a moment."
        )
    }

    // MARK: - Withdrawing

    /// A withdrawal with nothing to withdraw means the owner acted first, or
    /// the window closed. Both are worth saying: the second one means the
    /// claimant now owns the circle.
    func testAWithdrawalWithNothingToWithdrawNamesBothReasons() {
        let copy = OwnershipClaimCopy.withdrawFailure(
            apiError("http_404", "You have no live claim on this circle")
        )
        XCTAssertTrue(copy.contains("refused it"), copy)
        XCTAssertTrue(copy.contains("gone through"), copy)
    }

    func testAnUnknownWithdrawalFailureIsAPlainLine() {
        XCTAssertEqual(
            OwnershipClaimCopy.withdrawFailure(apiError("http_500", "Failed to withdraw the claim")),
            "Pingolin is having trouble just now. Please try again in a moment."
        )
    }

    // MARK: - Across all three

    /// None of these may leak the `[http_403]`-style suffix an APIError renders
    /// through `errorDescription`, which is what makes the raw form unreadable.
    func testNoMappedMessageCarriesARawErrorCode() {
        let cases: [String] = [
            OwnershipClaimCopy.openFailure(apiError("http_403", "Insufficient permissions")),
            OwnershipClaimCopy.openFailure(apiError("http_404", "Circle not found or you're not a member")),
            OwnershipClaimCopy.refuseFailure(apiError("http_404", "There is no live claim on this circle")),
            OwnershipClaimCopy.refuseFailure(apiError("http_403", "Only the owner can refuse a claim on their circle")),
            OwnershipClaimCopy.withdrawFailure(apiError("http_404", "You have no live claim on this circle")),
        ]
        for copy in cases {
            XCTAssertFalse(copy.contains("http_"), copy)
            XCTAssertFalse(copy.contains("["), copy)
        }
    }
}
