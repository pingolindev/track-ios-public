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

/// The words on an invite banner, per detail level, and which pending invite a
/// push is about. Shared by the app and the Notification Service Extension, so
/// these pin what BOTH show: the lock screen must say no more than the level
/// allows and no less than it can.
final class InviteNotificationCopyTests: XCTestCase {

    // MARK: - Body per level

    func testNamesAndPlacesSaysWhoAndWhichCircle() {
        XCTAssertEqual(
            InviteNotificationCopy.body(inviter: "Sam Rivera", circle: "Friends", level: "full"),
            "Sam Rivera invited you to join Friends.")
    }

    func testNamesOnlyKeepsTheInviterAndDropsTheCircle() {
        XCTAssertEqual(
            InviteNotificationCopy.body(inviter: "Sam Rivera", circle: "Friends", level: "names"),
            "Sam Rivera invited you to a circle.")
    }

    func testGenericShowsNothingButTapToView() {
        XCTAssertEqual(
            InviteNotificationCopy.body(inviter: "Sam Rivera", circle: "Friends", level: "generic"),
            "Tap to view")
        XCTAssertEqual(InviteNotificationCopy.genericBody, NotificationDetailLevel.genericBody)
    }

    /// An unset or unknown level is full — exactly what
    /// `UserSettings.notificationDetailLevel` does with an unset key.
    func testAnUnknownLevelReadsAsFull() {
        XCTAssertEqual(
            InviteNotificationCopy.body(inviter: "Sam", circle: "Friends", level: nil),
            "Sam invited you to join Friends.")
        XCTAssertEqual(
            InviteNotificationCopy.body(inviter: "Sam", circle: "Friends", level: "loud"),
            "Sam invited you to join Friends.")
    }

    func testMissingNamesDegradeOneAtATime() {
        XCTAssertEqual(InviteNotificationCopy.body(inviter: "Sam", circle: nil, level: "full"),
                       "Sam invited you to a circle.")
        XCTAssertEqual(InviteNotificationCopy.body(inviter: nil, circle: "Friends", level: "full"),
                       "You've been invited to join Friends.")
        XCTAssertEqual(InviteNotificationCopy.body(inviter: nil, circle: nil, level: "full"),
                       "You've been invited to join a circle.")
        XCTAssertEqual(InviteNotificationCopy.body(inviter: "", circle: "", level: "names"),
                       "You've been invited to join a circle.")
    }

    /// The title matches the server's generic invite title, so a
    /// rewritten banner and an un-rewritten one read as the same event.
    func testTheTitleIsTheServersGenericTitle() {
        XCTAssertEqual(InviteNotificationCopy.title, "Circle invitation")
    }

    /// What the app may replace: any nameless body, and nothing that names someone.
    func testOnlyNamelessBodiesCountAsGeneric() {
        XCTAssertTrue(InviteNotificationCopy.isGeneric(body: "You've been invited to join a circle"))
        XCTAssertTrue(InviteNotificationCopy.isGeneric(body: "You've been invited to join a circle."))
        XCTAssertTrue(InviteNotificationCopy.isGeneric(body: "Tap to view"))
        XCTAssertTrue(InviteNotificationCopy.isGeneric(body: "  tap to view \n"))
        XCTAssertFalse(InviteNotificationCopy.isGeneric(body: "Sam invited you to join Friends."))
        XCTAssertFalse(InviteNotificationCopy.isGeneric(body: "Sam invited you to a circle."))
        XCTAssertFalse(InviteNotificationCopy.isGeneric(body: "You've been invited to join Friends."))
    }

    // MARK: - Which invite

    private func invite(_ id: String, circle: String, name: String? = nil, by: String? = nil)
        -> InviteNotificationCopy.PendingInvite
    {
        InviteNotificationCopy.PendingInvite(id: id, circleId: circle, circleName: name, inviterDisplayName: by)
    }

    func testThePushesCircleWins() {
        let picked = InviteNotificationCopy.pick(
            from: [invite("a", circle: "c-work"), invite("b", circle: "c-friends")],
            circleId: "c-friends")
        XCTAssertEqual(picked?.id, "b")
    }

    func testALoneInviteIsTakenEvenWithoutACircleMatch() {
        XCTAssertEqual(
            InviteNotificationCopy.pick(from: [invite("a", circle: "c-work")], circleId: "c-other")?.id, "a")
        XCTAssertEqual(
            InviteNotificationCopy.pick(from: [invite("a", circle: "c-work")], circleId: nil)?.id, "a")
    }

    /// Naming the wrong inviter would be worse than naming none.
    func testSeveralInvitesAndNoMatchNamesNobody() {
        XCTAssertNil(InviteNotificationCopy.pick(
            from: [invite("a", circle: "c-work"), invite("b", circle: "c-friends")], circleId: "c-other"))
        XCTAssertNil(InviteNotificationCopy.pick(from: [], circleId: "c-work"))
    }

    /// An invite push names its notification ROW, not the circle: the
    /// row's circle picks the invite when several are pending.
    func testTheRowAPushNamesPicksTheInvite() throws {
        let row = Data(#"{"success":true,"data":{"id":"r-1","circle_id":"c-friends","notification_type":"circle_invite","title":"Circle Invite","metadata":{},"is_read":false,"created_at":"2026-09-24T07:00:00Z"}}"#.utf8)
        let circle = try XCTUnwrap(InviteNotificationCopy.decodeRowCircle(row))
        XCTAssertEqual(InviteNotificationCopy.pick(
            from: [invite("a", circle: "c-work"), invite("b", circle: "c-friends")], circleId: circle)?.id, "b")
        XCTAssertNil(InviteNotificationCopy.decodeRowCircle(Data(#"{"success":false,"error":"Notification not found"}"#.utf8)))
        XCTAssertNil(InviteNotificationCopy.decodeRowCircle(Data(#"{"success":true,"data":{"circle_id":""}}"#.utf8)))
    }

    // MARK: - Decoding the server envelope

    func testDecodesTheReceivedInvitesEnvelope() {
        let json = """
        {"success":true,"data":[{"id":"inv-1","circle_id":"c-1","invited_by":"u-1","invite_type":"email",
          "created_day_bucket":20699,"expires_day_bucket":20706,"has_encrypted_key":true,
          "circle_name":"Friends","inviter_display_name":"Sam Rivera"}]}
        """.data(using: .utf8)!
        let decoded = InviteNotificationCopy.decodePending(json)
        XCTAssertEqual(decoded, [invite("inv-1", circle: "c-1", name: "Friends", by: "Sam Rivera")])
    }

    func testAMalformedEnvelopeIsAnEmptyListNotACrash() {
        XCTAssertEqual(InviteNotificationCopy.decodePending("nope".data(using: .utf8)!), [])
        XCTAssertEqual(InviteNotificationCopy.decodePending("{\"success\":false}".data(using: .utf8)!), [])
    }
}
