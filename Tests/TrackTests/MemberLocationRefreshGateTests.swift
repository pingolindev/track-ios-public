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

/// The two-tier gate every alert evaluator applies before judging a member.
///
/// WHY THE GATE IS NEEDED, AND WHY A UNIT TEST CAN SEE IT
///   `memberLocations` is a CACHE, not a snapshot: the publish loop writes per
///   key and never replaces the dictionary, so a member absent from a refresh
///   keeps their previous entry and its ageing timestamp. An evaluator reading
///   that timestamp would call it silence. Catching a failed
///   `loadMemberLocations()` is not enough, because that call throws only when
///   the whole FETCH fails; a per-member decrypt failure drops one row and
///   returns normally.
///
///   The most reachable case is not a fault at all. The server never sends a
///   paused member's location, so a member who PAUSES sharing is simply absent
///   — and after `timeoutHours` their circle would be told they might need
///   attention, from the last position they shared before pausing. Pausing is
///   the control a person reaches for when they do not want their whereabouts
///   known.
///
///   The decision is pure, so it is testable without a network, a circle key or
///   a live actor. Same reasoning as `LocationReplayGuardTests`.
final class MemberLocationRefreshGateTests: XCTestCase {

    private func refresh(
        seen: Set<String>,
        keyMissing: Int = 0,
        decryptFailed: Int = 0,
        total: Int = 3
    ) -> CircleManager.MemberLocationRefresh {
        CircleManager.MemberLocationRefresh(
            refreshedUserIds: seen,
            keyMissingCount: keyMissing,
            decryptionFailures: decryptFailed,
            totalReceived: total
        )
    }

    // MARK: - Tier 2: the member

    /// The ordinary case: this refresh produced a location, so judge them.
    func testAMemberThisRefreshProducedIsJudged() {
        XCTAssertTrue(CircleManager.shouldJudge("alice", from: refresh(seen: ["alice", "bob"])))
    }

    /// A paused member is absent from the response, so nothing about them
    /// may be inferred — least of all "they have gone quiet".
    func testAMemberAbsentFromTheRefreshIsNotJudged() {
        XCTAssertFalse(
            CircleManager.shouldJudge("carol", from: refresh(seen: ["alice", "bob"])),
            "a member this refresh said nothing about must not be judged — they are "
                + "paused, have never shared, or were filtered server-side, and all three "
                + "mean say nothing"
        )
    }

    /// A refresh that produced nothing at all judges nobody, without needing the
    /// failure counts to say so. An empty circle is not a silent circle.
    func testAnEmptyRefreshJudgesNobody() {
        XCTAssertFalse(CircleManager.shouldJudge("alice", from: refresh(seen: [], total: 0)))
    }

    // MARK: - Tier 1: the circle

    /// A row the app could not open is indistinguishable from a member who went
    /// quiet, so one unopened row disqualifies the whole refresh — including for
    /// members it DID decrypt. Matches the Android app's AlertsCheckWorker,
    /// which requires `keyMissingCount == 0 && decryptionFailures == 0`.
    func testAKeyGapDisqualifiesEvenAMemberThatDecrypted() {
        let r = refresh(seen: ["alice"], keyMissing: 1)
        XCTAssertFalse(
            CircleManager.shouldJudge("alice", from: r),
            "alice decrypted, but a key gap elsewhere means this refresh cannot tell "
                + "silence from unreadability for anyone in the circle"
        )
    }

    func testADecryptFailureDisqualifiesEvenAMemberThatDecrypted() {
        let r = refresh(seen: ["alice"], decryptFailed: 1)
        XCTAssertFalse(CircleManager.shouldJudge("alice", from: r))
    }

    /// The two counts are separate signals but have the same consequence here;
    /// neither is allowed to be the one that gets forgotten.
    func testEitherFailureKindAloneIsEnoughToDisqualify() {
        XCTAssertFalse(refresh(seen: ["a"], keyMissing: 1).isComplete)
        XCTAssertFalse(refresh(seen: ["a"], decryptFailed: 1).isComplete)
        XCTAssertFalse(refresh(seen: ["a"], keyMissing: 1, decryptFailed: 1).isComplete)
        XCTAssertTrue(refresh(seen: ["a"]).isComplete)
    }

    // MARK: - Composition

    /// Tier 1 is checked BEFORE tier 2, so a broken refresh judges nobody even
    /// for a member it never mentioned. Ordering matters only for clarity of the
    /// failure, but a later reader reversing it should be caught.
    func testAnIncompleteRefreshJudgesNobodyAtAll() {
        let r = refresh(seen: ["alice"], keyMissing: 2, decryptFailed: 1)
        for candidate in ["alice", "bob", "carol"] {
            XCTAssertFalse(CircleManager.shouldJudge(candidate, from: r), "candidate=\(candidate)")
        }
    }

    /// `totalReceived` is reporting only and must not affect the decision — a
    /// refresh that received nothing and failed nothing is complete and simply
    /// has nobody to judge.
    func testTotalReceivedDoesNotAffectTheDecision() {
        XCTAssertTrue(CircleManager.shouldJudge("alice", from: refresh(seen: ["alice"], total: 0)))
        XCTAssertTrue(CircleManager.shouldJudge("alice", from: refresh(seen: ["alice"], total: 99)))
    }
}
