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

/// The device-local "I compared this member's safety number out of band" marker.
///
/// WHY THIS IS WORTH TESTING
///   Two of these properties are load-bearing for what the marker MEANS, and
///   both are easy to break silently.
///
///   `clearVerified` has to actually remove the marker: it is what
///   `MemberKeyPinner.approve` calls when a member's pin is overwritten with new
///   keys, and if it no-ops the toggle keeps vouching for a key the user never
///   compared.
///
///   `clearAll` has to remove OURS and only ours. Android gets this for free —
///   its markers live in a dedicated `member_verification` SharedPreferences
///   FILE it can wipe wholesale. UserDefaults is one flat namespace shared with
///   every other preference in the app, so the iOS port sweeps by key prefix
///   instead, and a prefix that is too broad silently resets unrelated settings
///   on every logout. Nothing else in the app would fail loudly if it did.
final class MemberVerificationStoreTests: XCTestCase {

    // Namespaced per-run so a crashed test can't leave a marker that flips a
    // later assertion, and so this never collides with a real circle.
    private let circleId = "test-circle-\(UUID().uuidString)"
    private let userId = "test-user-\(UUID().uuidString)"
    private let otherUserId = "test-user-\(UUID().uuidString)"

    private let unrelatedKey = "circles.userOrder"

    override func tearDown() {
        MemberVerificationStore.clearAll()
        UserDefaults.standard.removeObject(forKey: unrelatedKey)
        super.tearDown()
    }

    func testRoundTripsAMarker() throws {
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId))

        let when = Date(timeIntervalSince1970: 1_760_000_000)
        MemberVerificationStore.setVerified(circleId: circleId, userId: userId, at: when)

        // Unwrapped before the accuracy comparison: XCTAssertEqual's accuracy
        // overload takes non-optional operands.
        let read = try XCTUnwrap(
            MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId)
        )
        XCTAssertEqual(read.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
    }

    func testClearingRemovesIt() {
        MemberVerificationStore.setVerified(circleId: circleId, userId: userId)
        XCTAssertNotNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId))

        MemberVerificationStore.clearVerified(circleId: circleId, userId: userId)
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId))
    }

    func testMarkersArePerCircleAndMember() {
        MemberVerificationStore.setVerified(circleId: circleId, userId: userId)
        MemberVerificationStore.setVerified(circleId: circleId, userId: otherUserId)

        MemberVerificationStore.clearVerified(circleId: circleId, userId: userId)

        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId))
        XCTAssertNotNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: otherUserId))
    }

    /// The epoch-0 sentinel. `UserDefaults.double(forKey:)` returns 0 for an
    /// ABSENT key, which is indistinguishable from a genuine 1970 timestamp —
    /// so 0 must read as "never verified", matching android's
    /// `getLong(..., 0L)`. Without the guard, every member reads as verified at
    /// 1 Jan 1970.
    func testEpochZeroReadsAsNotVerified() {
        MemberVerificationStore.setVerified(
            circleId: circleId, userId: userId, at: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId))
    }

    /// The logout sweep. Wipes every marker and NOTHING else — `circles.userOrder`
    /// stands in for the rest of the app's UserDefaults, which share the domain.
    func testClearAllRemovesOnlyVerificationMarkers() {
        MemberVerificationStore.setVerified(circleId: circleId, userId: userId)
        MemberVerificationStore.setVerified(circleId: circleId, userId: otherUserId)
        UserDefaults.standard.set(["circle-a", "circle-b"], forKey: unrelatedKey)

        MemberVerificationStore.clearAll()

        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: userId))
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circleId, userId: otherUserId))
        XCTAssertEqual(
            UserDefaults.standard.array(forKey: unrelatedKey) as? [String],
            ["circle-a", "circle-b"],
            "clearAll swept a key that is not a verification marker"
        )
    }
}
