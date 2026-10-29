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

/// Promoting a member to admin signs an admission for ONLY the keys this
/// device holds for them — a receive-only (kind-2) member's recorded pair,
/// else the pinned one — and only while the member list shows exactly those,
/// and they are the keys the person decided on (the dialog's number was
/// worked out from them). Anything else signs nothing and changes no role.
/// The admission is stored before the role changes.
final class PromotionKeysTests: XCTestCase {

    private let a = MemberKeyPair(sharingKeyHex: "aa11", signingKeyHex: "aa22")
    private let b = MemberKeyPair(sharingKeyHex: "bb11", signingKeyHex: "bb22")

    func testSwappedKeysAreNeverSigned() {
        typealias C = CircleManager
        // The server shows other keys than the ones held: nothing signed.
        XCTAssertNil(C.promotionAdmissionKeys(held: a, listed: b, decided: nil))
        XCTAssertNil(C.promotionAdmissionKeys(held: a, listed: b, decided: a))
        // Nothing held, or nothing listed: nothing signed.
        XCTAssertNil(C.promotionAdmissionKeys(held: nil, listed: a, decided: nil))
        XCTAssertNil(C.promotionAdmissionKeys(held: a, listed: nil, decided: a))
    }

    /// The number was shown for A; the list changed to B before the tap: nothing
    /// is signed for B (nor for A, which the list no longer shows).
    func testTheNumberShownIsTheKeysSigned() {
        typealias C = CircleManager
        XCTAssertNil(C.promotionAdmissionKeys(held: b, listed: b, decided: a), "decided on A, now B: nothing")
        XCTAssertNil(C.promotionAdmissionKeys(held: a, listed: b, decided: a), "the list moved: nothing")
        XCTAssertEqual(C.promotionAdmissionKeys(held: a, listed: a, decided: a), a)
        XCTAssertEqual(C.promotionAdmissionKeys(held: a, listed: MemberKeyPair(sharingKeyHex: "AA11", signingKeyHex: "AA22"),
                                                decided: nil), a, "hex case does not matter")
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The wiring: the dialog fixes the held keys and works the number out from
    /// them; the tap passes those keys through; the admission for exactly the
    /// decided keys is stored BEFORE the role changes, and a failed one changes
    /// nothing.
    func testTheAdmissionComesFirstForTheDecidedKeys() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let role = try XCTUnwrap(circles.range(of: "func updateMemberRole(in circleId: String, userId: String, role: CircleMember.MemberRole,"))
        let body = circles[role.upperBound...].prefix(5_000)
        let decide = try XCTUnwrap(body.range(of: "Self.promotionAdmissionKeys(held: promotionKeys(for: userId, in: circleId),"))
        let admit = try XCTUnwrap(body.range(of: "guard await admit(userId: userId, circleId: circleId,\n                                  sharingKeyHex: signed.sharingKeyHex, signingKeyHex: signed.signingKeyHex) else {"))
        let change = try XCTUnwrap(body.range(of: "_ = try await api.updateMemberRole("))
        XCTAssertLessThan(decide.lowerBound, admit.lowerBound)
        XCTAssertLessThan(admit.lowerBound, change.lowerBound, "the admission is stored before the role changes")
        // A waiting promotion's run stores its admission first too, and skips
        // one the server already holds.
        let waiting = try XCTUnwrap(body.range(of: "if waiting.heldStatementId == nil {\n                    try await admitWaiting(waiting, userId: userId, circleId: circleId, keys: signed)"))
        XCTAssertLessThan(decide.lowerBound, waiting.lowerBound)
        XCTAssertLessThan(waiting.lowerBound, change.lowerBound)
        XCTAssertFalse(body.prefix(upTo: change.lowerBound).contains("oweAdmission"), "nothing owed: a person's tap bounds the retries")
        XCTAssertTrue(body.contains("throw CircleError.promotionDetailsChanged"))
        XCTAssertTrue(body.contains("throw CircleError.promotionNotDone"))
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("let keys = circleManager.promotionKeys(for: member.userId, in: circle.id)"))
        XCTAssertTrue(view.contains("keys: keys, number: keys.flatMap { circleManager.securityCode(for: member.userId, keys: $0) })"))
        XCTAssertTrue(view.contains("let keys = promotion?.keys\n                    promotion = nil\n                    promote(keys: keys)"))
        XCTAssertFalse(view.contains("securityCode(for: member.userId, in: circle.id)"), "never the list's keys for the number")
        XCTAssertEqual(CircleManager.CircleError.promotionDetailsChanged.errorDescription,
                       "Their details changed, so they weren't made an admin.")
    }
}
