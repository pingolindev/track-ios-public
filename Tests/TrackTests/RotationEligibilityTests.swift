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

/// Who this device is allowed to rotate a circle key for.
///
/// WHY THE RIGHT DECIDES, AND WHY A UNIT TEST CAN SEE IT
///   The server lets a member rotate by the per-member `can_rotate_keys` right,
///   not by ownership, and that right is grantable *precisely* so a dormant
///   owner cannot block rotation: a promotion to admin grants it and a demotion
///   takes it back. A sweep gated on `circle.isOwner` would leave a promoted
///   admin never rotating, with the flag set until the owner happened to open
///   the app.
///
///   That is not only about availability. Two of the four flows that raise
///   `key_rotation_needed` are leaving and revoking access, where the point of
///   rotating is to make everything written from now on unreadable to the
///   member who is gone. A rotation that never happens leaves their key current.
///
///   The field must be decoded too: `Codable` drops unknown keys in silence, so
///   a model without it would throw the server's `can_rotate_keys` away with
///   nothing failing and nothing logged.
///
///   The decision is pure once the roster row is in hand, so it is testable
///   without a network, a circle key or a live actor. Same reasoning as
///   `MemberLocationRefreshGateTests`.
final class RotationEligibilityTests: XCTestCase {

    private func row(role: CircleMember.MemberRole, canRotate: Bool) -> CircleMember {
        CircleMember(
            circleId: "c1",
            userId: "u1",
            displayName: "Member",
            role: role,
            canSeeRealtime: true,
            canSeeHistory: true,
            canRotateKeys: canRotate,
            joinedAt: Date()
        )
    }

    /// The case an owner-only gate gets wrong.
    func testGrantedAdminMayRotateEvenThoughNotOwner() {
        XCTAssertTrue(
            CircleManager.mayRotate(isOwner: false, myMemberRow: row(role: .admin, canRotate: true)),
            "an admin holding can_rotate_keys must rotate — the right exists so a dormant owner cannot block it"
        )
    }

    /// The other direction. Without this the check would pass by saying "yes"
    /// to everyone, which is exactly the looseness the server refuses.
    func testPlainMemberWithoutTheRightMayNotRotate() {
        XCTAssertFalse(
            CircleManager.mayRotate(isOwner: false, myMemberRow: row(role: .member, canRotate: false)),
            "a member without the right must not enter the rotation lottery"
        )
    }

    /// A demoted admin keeps the role string locally until the next refresh, so
    /// the RIGHT is what decides, never the role.
    func testTheRightDecidesNotTheRole() {
        XCTAssertFalse(
            CircleManager.mayRotate(isOwner: false, myMemberRow: row(role: .admin, canRotate: false)),
            "role admin with the right revoked must not rotate"
        )
        XCTAssertTrue(
            CircleManager.mayRotate(isOwner: false, myMemberRow: row(role: .member, canRotate: true)),
            "the right alone is sufficient; the server checks nothing else"
        )
    }

    /// The ordering trap. The sweep runs EARLIER in loadCircles than the
    /// loadMembers fan-out, so on a cold launch there is no roster row yet. A
    /// missing row must not read as "ineligible" or the first refresh after
    /// launch — the one that matters after a removal — would rotate nothing.
    func testUnloadedRosterFallsBackToOwnership() {
        XCTAssertTrue(
            CircleManager.mayRotate(isOwner: true, myMemberRow: nil),
            "owner with no roster loaded yet must still rotate; owners always hold the bit server-side"
        )
        XCTAssertFalse(
            CircleManager.mayRotate(isOwner: false, myMemberRow: nil),
            "non-owner with no roster loaded must wait rather than guess itself eligible"
        )
    }
}
