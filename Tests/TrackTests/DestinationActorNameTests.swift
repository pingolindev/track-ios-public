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

/// A destination row names who did it only as every named row does: a member
/// this device shows, by the sealed name that opened here. A member's
/// `displayName` holds the server's PLAINTEXT name when their sealed one
/// didn't open; that name never reaches the row, which then says "Someone"
/// (and the server's own words at Generic).
final class DestinationActorNameTests: XCTestCase {
    private let circle = "a7a70000-0000-4000-8000-0000000000c1"
    private let pat = "a7a70000-0000-4000-8000-00000000000d"

    private func member(_ name: String) -> CircleMember {
        CircleMember(circleId: circle, userId: pat, displayName: name, role: .member, canSeeRealtime: true,
                     canSeeHistory: true, canRotateKeys: false, joinedAt: Date())
    }

    func testAPlaintextNameNeverNamesTheRow() {
        // Pat's sealed name didn't open here: the roster shows the server's plaintext one.
        let plaintext = [circle: [member("Plain Pat")]]
        XCTAssertNil(DestinationsManager.destinationActor(actorId: pat, circleId: circle, members: plaintext,
                                                          opened: [circle: []]))
        XCTAssertNil(DestinationsManager.destinationActor(actorId: pat, circleId: circle, members: plaintext,
                                                          opened: [:]))
        // The row's words then: "Someone", never "Plain Pat".
        for detail in [NamedNotificationCopy.Detail.full, .names] {
            for type in ["destination_shared", "destination_arrival"] {
                let body = NotificationsManager.destinationBody(type: type, actor: NamedNotificationCopy.someone,
                                                                label: "Home", isSelf: false, detail: detail)
                XCTAssertTrue(body?.hasPrefix("Someone ") == true, "\(type) at \(detail): \(body ?? "nil")")
                XCTAssertFalse(body?.contains("Plain Pat") ?? false)
            }
        }
        XCTAssertEqual(NotificationsManager.destinationBody(type: "destination_shared", actor: "Someone", label: "Home",
                                                            isSelf: false, detail: .full),
                       "Someone created a destination for Home")
        XCTAssertEqual(NotificationsManager.destinationBody(type: "destination_arrival", actor: "Someone", label: "Home",
                                                            isSelf: false, detail: .names),
                       "Someone arrived at their destination")
        XCTAssertNil(NotificationsManager.destinationBody(type: "destination_shared", actor: "Someone", label: "Home",
                                                          isSelf: false, detail: .generic), "Generic: the server's words")
    }

    func testAnOpenedNameOfAShownMemberNamesTheRow() {
        let opened = [circle: Set([pat])]
        XCTAssertEqual(DestinationsManager.destinationActor(actorId: pat, circleId: circle.uppercased(),
                                                            members: [circle: [member("Pat")]], opened: opened),
                       "Pat", "a shown member, by the name that opened, the circle in any spelling")
        XCTAssertNil(DestinationsManager.destinationActor(actorId: pat, circleId: circle, members: [circle: []],
                                                          opened: opened), "not shown here (left, or not confirmed)")
        XCTAssertNil(DestinationsManager.destinationActor(actorId: nil, circleId: circle,
                                                          members: [circle: [member("Pat")]], opened: opened),
                     "the row names nobody")
        XCTAssertNil(DestinationsManager.destinationActor(actorId: pat, circleId: "not-a-circle",
                                                          members: [circle: [member("Pat")]], opened: opened))
    }

    func testTheRowsAreNamedThroughTheRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let destinations = try String(contentsOf: root.appendingPathComponent("App/Managers/DestinationsManager.swift"),
                                      encoding: .utf8)
        let resolve = try XCTUnwrap(destinations.range(of: "func resolveNotificationCopy("))
        let end = try XCTUnwrap(destinations.range(of: "func labelForDestination(", range: resolve.upperBound..<destinations.endIndex))
        let body = destinations[resolve.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("Self.destinationActor(actorId: actorId, circleId: circleId,"))
        XCTAssertFalse(body.contains(".displayName"), "never the roster's name directly")
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/NotificationsManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(manager.contains("let actor = copy.actorName ?? (copy.actorKnown ? NamedNotificationCopy.someone : nil)"))
    }
}
