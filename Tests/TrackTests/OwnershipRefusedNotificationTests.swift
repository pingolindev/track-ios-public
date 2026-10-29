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

import SwiftUI
import XCTest
@testable import Track

/// The claimant's notice that the owner refused their request to take over a
/// circle. The server writes the row ('circle_ownership_refused', the circle
/// in its column, metadata {claim_id}); its push carries the claim as
/// alert_id. A tap on either opens the circle itself, and the row has its own
/// mark, not the plain bell; the claim keeps its own screen, the owner's.
final class OwnershipRefusedNotificationTests: XCTestCase {

    private let circle = "8b96aa7c-0000-4000-8000-0000000000c1"
    private let claim = "0b5f5bf1-0000-4000-8000-0000000000a1"

    private func row(_ type: String, circleId: String?, claimId: String? = nil) -> NotificationResponse {
        NotificationResponse(
            id: "n-\(type)", circleId: circleId, notificationType: type,
            title: "Your request to take over was refused",
            body: "The owner refused your request to take over this circle. It stays theirs.",
            metadata: claimId.map { ["claim_id": .string($0)] }, isRead: false, createdDayBucket: nil, createdAt: nil
        )
    }

    /// The push, by `alert_type` (what the server forwards) or by `type`: the
    /// refusal opens the circle, the claim its ownership screen, and nothing
    /// else is a takeover push.
    func testTheRefusalPushOpensTheCircle() {
        XCTAssertEqual(PushAppDelegate.takeoverTap(alertType: "circle_ownership_refused", kind: nil), .circle)
        XCTAssertEqual(PushAppDelegate.takeoverTap(alertType: nil, kind: "circle_ownership_refused"), .circle)
        XCTAssertEqual(PushAppDelegate.takeoverTap(alertType: "tickle", kind: "circle_ownership_refused"), .circle)
        XCTAssertEqual(PushAppDelegate.takeoverTap(alertType: "circle_ownership_claim", kind: nil), .claimScreen)
        XCTAssertEqual(PushAppDelegate.takeoverTap(alertType: nil, kind: "circle_ownership_claim"), .claimScreen)
        XCTAssertNil(PushAppDelegate.takeoverTap(alertType: "circle_ownership_transferred", kind: nil))
        XCTAssertNil(PushAppDelegate.takeoverTap(alertType: "circle_invite", kind: "tickle"))
        XCTAssertNil(PushAppDelegate.takeoverTap(alertType: nil, kind: nil))
    }

    /// Its circle comes from its own row, by the claim the push names, so
    /// nothing stable has to ride on the push.
    func testTheRefusalNamesItsCircleThroughItsRow() {
        let rows = [row("circle_ownership_refused", circleId: circle, claimId: claim)]
        XCTAssertEqual(PushAppDelegate.circleId(from: rows, correlationId: claim), circle)
    }

    /// The bell row opens the circle, from the row's circle column. A row
    /// without one opens nothing, and the claim's row keeps its own screen.
    func testTheBellRowOpensTheCircle() {
        XCTAssertEqual(CircleScreenTarget.opened(by: row("circle_ownership_refused", circleId: circle))?.id, circle)
        XCTAssertNil(CircleScreenTarget.opened(by: row("circle_ownership_refused", circleId: nil)))
        XCTAssertNil(CircleScreenTarget.opened(by: row("circle_ownership_refused", circleId: "")))
        XCTAssertNil(CircleScreenTarget.opened(by: row("circle_ownership_claim", circleId: circle)), "the owner's screen")
        XCTAssertNil(CircleScreenTarget.opened(by: row("circle_ownership_transferred", circleId: circle)))
    }

    /// That circle in any spelling: the screen looks it up among circles kept
    /// in the one form.
    func testAnySpellingOpensThatCircle() {
        XCTAssertEqual(CircleScreenTarget(id: circle.uppercased()).id, circle)
        XCTAssertEqual(
            CircleScreenTarget.opened(by: row("circle_ownership_refused", circleId: circle.uppercased()))?.id, circle)
        XCTAssertEqual(CircleScreenTarget(id: "circle-1").id, "circle-1", "anything else as it came")
        let circles = [Circle(id: "8b96aa7c-0000-4000-8000-0000000000c2", name: "Work"), Circle(id: circle, name: "Family")]
        XCTAssertEqual(NotifiedCircleScreen.circle(circle.uppercased(), in: circles)?.name, "Family")
        XCTAssertNil(NotifiedCircleScreen.circle("8b96aa7c-0000-4000-8000-0000000000c3", in: circles))
    }

    /// Its own mark, the owner's Refuse control's, and colour: not the plain bell.
    func testTheRowHasItsMarkAndColour() {
        let refused = row("circle_ownership_refused", circleId: circle)
        XCTAssertEqual(refused.iconName, "hand.raised")
        XCTAssertEqual(refused.iconColor, .indigo)
        let unknown = row("something_new", circleId: circle)
        XCTAssertEqual(unknown.iconName, "bell")
        XCTAssertEqual(unknown.iconColor, .gray)
    }

    /// The server's words as they are: nothing here names anyone, or the circle.
    func testTheWordsAreTheServers() {
        for level in ["full", "names", "generic", nil] {
            XCTAssertNil(NamedNotificationCopy.row(
                type: "circle_ownership_refused", title: "Your request to take over was refused",
                body: "The owner refused your request to take over this circle. It stays theirs.",
                names: .init(person: "Olivia", circle: "Family"), level: level), "\(level ?? "nil")")
        }
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The push routes the refusal to the circle, and the map opens it.
    func testThePushRoutesTheRefusalToTheCircle() throws {
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("if let takeover = Self.takeoverTap(alertType: alertType, kind: kind) {\n"))
        XCTAssertFalse(push.contains("if alertType == \"circle_ownership_claim\" || kind == \"circle_ownership_claim\""))
        XCTAssertTrue(push.contains("""
                            case .circle:
                                NotificationRouteState.shared.pending = .circle(circleId: claimCircleId)
        """))
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("""
                        case .circle(let circleId):
                            circleTarget = CircleScreenTarget(id: circleId)
        """))
        XCTAssertEqual(map.components(separatedBy: "NotifiedCircleScreen(circleId: target.id)").count - 1, 1)
    }

    /// The bell row opens it the same way.
    func testTheBellRowRoutesTheRefusalToTheCircle() throws {
        let bell = try source("App/Views/Notifications/NotificationsView.swift")
        XCTAssertTrue(bell.contains("""
                                case "circle_ownership_refused":
                                    if let target = CircleScreenTarget.opened(by: row) {
                                        circleTarget = target
                                    }
        """))
        XCTAssertEqual(bell.components(separatedBy: "NotifiedCircleScreen(circleId: target.id)").count - 1, 1)
    }
}
