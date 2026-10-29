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

/// The store behind the circle screen's claim banner.
///
/// It answers one question — "is there a live claim on this circle?" — and the
/// two ways of getting that wrong are opposites. Answering "no" when there IS
/// one hides a countdown from the person it is running against. Answering "yes"
/// when the claim is over leaves a Refuse button that can only fail.
@MainActor
final class OwnershipClaimManagerTests: XCTestCase {

    private let circleId = "circle-1"

    override func setUp() async throws {
        OwnershipClaimManager.shared.reset()
    }

    override func tearDown() async throws {
        OwnershipClaimManager.shared.reset()
    }

    private func claim(status: String?) -> OwnershipClaimResponse {
        OwnershipClaimResponse(
            claimId: "claim-1",
            circleId: circleId,
            claimantUserId: "claimant-1",
            status: status,
            requestedAt: "2026-08-23T09:00:00Z",
            resolvesAt: "2026-09-06T09:00:00Z"
        )
    }

    func testACircleNobodyHasAskedAboutHasNoClaim() {
        XCTAssertNil(OwnershipClaimManager.shared.claim(for: circleId))
        XCTAssertFalse(OwnershipClaimManager.shared.checked.contains(circleId))
    }

    func testAPendingClaimIsHeldAndReturned() {
        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "pending"))

        let held = OwnershipClaimManager.shared.claim(for: circleId)
        XCTAssertEqual(held?.claimId, "claim-1")
        XCTAssertTrue(OwnershipClaimManager.shared.checked.contains(circleId))
    }

    /// The transition the whole banner turns on: the moment a claim stops being
    /// pending it must leave the store, not linger as a countdown for something
    /// that already resolved.
    func testAResolvedClaimIsNotHeldAtAll() {
        for status in ["completed", "refused", "withdrawn", "void"] {
            OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "pending"))
            XCTAssertNotNil(OwnershipClaimManager.shared.claim(for: circleId))

            OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: status))
            XCTAssertNil(
                OwnershipClaimManager.shared.claim(for: circleId),
                "\(status) is over — the banner must go with it"
            )
        }
    }

    /// The same rule one layer down. `claim(for:)` filters on `isPending` too,
    /// so the read path alone cannot tell whether the store is also refusing to
    /// keep resolved rows — and it must, or a stale 'refused' row would sit in
    /// memory waiting for anything that reaches past the accessor.
    func testAResolvedClaimIsNotEvenKept() {
        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "pending"))
        XCTAssertNotNil(OwnershipClaimManager.shared.claims[circleId])

        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "refused"))

        XCTAssertNil(
            OwnershipClaimManager.shared.claims[circleId],
            "a resolved claim must leave the store, not merely be filtered on the way out"
        )
    }

    /// The server answering "no claim" has to clear a claim we were holding.
    /// Somebody else can refuse or withdraw between two reads.
    func testAServerAnswerOfNoneClearsAHeldClaim() {
        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "pending"))
        XCTAssertNotNil(OwnershipClaimManager.shared.claim(for: circleId))

        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: nil)

        XCTAssertNil(OwnershipClaimManager.shared.claim(for: circleId))
        XCTAssertTrue(
            OwnershipClaimManager.shared.checked.contains(circleId),
            "'we asked and there is none' is a different state from 'we never asked'"
        )
    }

    /// Claims are scoped to their circle. A claim on one must never surface on
    /// another — the Refuse button is keyed by circle id and would act on the
    /// wrong one.
    func testAClaimDoesNotLeakToAnotherCircle() {
        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "pending"))
        XCTAssertNil(OwnershipClaimManager.shared.claim(for: "circle-2"))
    }

    /// Logout. The rows name a circle and the user id of whoever is claiming
    /// it, so account B must not inherit account A's countdown — nor a Refuse
    /// control keyed to a circle they were never in.
    func testResetDropsEverything() {
        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: "pending"))

        OwnershipClaimManager.shared.reset()

        XCTAssertNil(OwnershipClaimManager.shared.claim(for: circleId))
        XCTAssertTrue(OwnershipClaimManager.shared.checked.isEmpty)
        XCTAssertTrue(OwnershipClaimManager.shared.claims.isEmpty)
        XCTAssertTrue(OwnershipClaimManager.shared.busy.isEmpty)
    }

    /// A claim whose status the server omitted is treated as live. The GET
    /// returns pending claims only, so a row that came back at all is one —
    /// and reading a missing field as "not live" is the failure that hides the
    /// countdown.
    func testAStatuslessClaimIsTreatedAsLive() {
        OwnershipClaimManager.shared.seedForTesting(circleId: circleId, claim: claim(status: nil))
        XCTAssertNotNil(OwnershipClaimManager.shared.claim(for: circleId))
    }
}
