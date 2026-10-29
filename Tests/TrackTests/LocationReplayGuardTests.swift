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

/// Unit tests for the client-side replay/reorder guard that protects member
/// location updates in `CircleManager`. The guard's pure decision lives in
/// `CircleManager.shouldAcceptLocation(incomingAuthTs:lastAcceptedTs:)`. The
/// E2E-encrypted `timestamp` it consumes is AEAD-authenticated, so a hostile
/// or compromised server that REPLAYS or REORDERS old envelopes cannot forge
/// a newer timestamp — it can only resend an older/equal one, which the guard
/// drops so the displayed pin never rewinds.
final class LocationReplayGuardTests: XCTestCase {

    // The first-ever update for a member has no prior high-water mark → accept.
    func testFirstSeenAccepts() {
        XCTAssertTrue(CircleManager.shouldAcceptLocation(incomingAuthTs: 1_000, lastAcceptedTs: nil))
    }

    // A strictly newer authenticated timestamp is accepted.
    func testStrictlyNewerAccepts() {
        XCTAssertTrue(CircleManager.shouldAcceptLocation(incomingAuthTs: 2_000, lastAcceptedTs: 1_000))
    }

    // An exact replay (equal timestamp) is dropped.
    func testEqualTimestampDrops() {
        XCTAssertFalse(CircleManager.shouldAcceptLocation(incomingAuthTs: 1_000, lastAcceptedTs: 1_000))
    }

    // A reordered/older envelope is dropped so the map never rewinds.
    func testOlderTimestampDrops() {
        XCTAssertFalse(CircleManager.shouldAcceptLocation(incomingAuthTs: 500, lastAcceptedTs: 1_000))
    }

    // A row with no authenticated timestamp (coarse dayBucket only) is not
    // the replay vector and is always accepted, regardless of history.
    func testMissingAuthTimestampAlwaysAccepts() {
        XCTAssertTrue(CircleManager.shouldAcceptLocation(incomingAuthTs: nil, lastAcceptedTs: nil))
        XCTAssertTrue(CircleManager.shouldAcceptLocation(incomingAuthTs: nil, lastAcceptedTs: 9_999))
    }

    // Drives the same accept/record semantics the publish path uses: only an
    // accepted, authenticated timestamp advances the per-member high-water
    // mark, so a dip between two good fixes is rejected and never lowers it.
    func testMonotonicSequence() {
        var last: Int64?
        func step(_ ts: Int64?) -> Bool {
            let accept = CircleManager.shouldAcceptLocation(incomingAuthTs: ts, lastAcceptedTs: last)
            if accept, let ts = ts { last = ts }
            return accept
        }
        XCTAssertTrue(step(100))    // first-seen
        XCTAssertTrue(step(200))    // newer, advances to 200
        XCTAssertFalse(step(150))   // replay/reorder, dropped, last stays 200
        XCTAssertFalse(step(200))   // exact replay, dropped
        XCTAssertTrue(step(201))    // newer, advances to 201
        XCTAssertEqual(last, 201)
    }

    // Mirrors the publish loop's per-(circle, member) keying. A member's SAME
    // physical update is re-encrypted independently per circle with an
    // IDENTICAL authenticated timestamp, so it must be accepted in each circle
    // (first-seen per composite key) — never false-dropped as a replay. A
    // global-per-user key would drop the second circle's copy (newTs == lastTs).
    // A replay *within* one circle is still dropped.
    func testSameTimestampAcceptedAcrossCirclesButReplayDroppedWithinCircle() {
        var guardMap: [String: Int64] = [:]
        let user = "u1"
        let ts: Int64 = 1_000
        func key(_ circle: String) -> String { "\(circle):\(user)" }
        func accept(_ circle: String, _ t: Int64) -> Bool {
            let ok = CircleManager.shouldAcceptLocation(incomingAuthTs: t, lastAcceptedTs: guardMap[key(circle)])
            if ok { guardMap[key(circle)] = t }
            return ok
        }
        XCTAssertTrue(accept("circleA", ts))     // first-seen in A
        XCTAssertTrue(accept("circleB", ts))     // SAME ts, distinct key → first-seen in B, accepted
        XCTAssertFalse(accept("circleA", ts))    // replay within A → dropped
        XCTAssertFalse(accept("circleB", ts))    // replay within B → dropped
        XCTAssertTrue(accept("circleA", ts + 1)) // genuinely newer in A → accepted
    }
}
