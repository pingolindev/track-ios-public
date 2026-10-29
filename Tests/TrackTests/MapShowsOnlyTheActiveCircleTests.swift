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

/// The held member rows are keyed by member, and survive a circle switch.
/// Drawn on the new circle's map as they are, someone only in the last circle
/// would show at their old position as a grey "Member", and a member of both
/// would show the last circle's position until the new one's refresh landed.
/// So the map, its card and a member focus take the circle on the map's rows
/// alone.
@MainActor
final class MapShowsOnlyTheActiveCircleTests: XCTestCase {

    private let circleA = "aaaaaaaa-1111-4111-8111-111111111111"
    private let circleB = "bbbbbbbb-2222-4222-8222-222222222222"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func row(_ userId: String, in circleId: String) -> LocationData {
        LocationData(circleId: circleId, userId: userId, deviceId: "d", latitude: 37.3349, longitude: -122.009,
                     timestamp: now)
    }

    func testOnlyTheCircleOnTheMapIsDrawn() {
        let onlyInA = row("cccccccc-0000-4000-8000-000000000003", in: circleA)
        let inB = row("dddddddd-0000-4000-8000-000000000004", in: circleB)
        XCTAssertEqual(MapView.inCircle([onlyInA, inB], circleB).map(\.userId), [inB.userId])
        XCTAssertEqual(MapView.inCircle([onlyInA, inB], circleB.uppercased()).count, 1, "the circle in any spelling")
        XCTAssertTrue(MapView.inCircle([onlyInA, inB], nil).isEmpty, "no circle on the map: no rows")
        XCTAssertEqual(MapView.heldRow(inB, in: circleB), inB)
        XCTAssertNil(MapView.heldRow(onlyInA, in: circleB), "the card and a focus take no other circle's row")
        XCTAssertNil(MapView.heldRow(nil, in: circleB))
    }

    func testTheMapItsCardAndAFocusReadTheActiveCircle() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains(
            "Self.inCircle(circleManager.memberLocations.values, circleManager.activeCircle?.id), roster: memberList),"))
        XCTAssertFalse(map.contains("Array(circleManager.memberLocations.values)"))
        XCTAssertTrue(map.contains(
            "return MapView.heldRow(circleManager.memberLocations[member.userId], in: circleManager.activeCircle?.id)"))
        XCTAssertEqual(map.components(separatedBy:
            "Self.heldRow(circleManager.memberLocations[userId], in: circleManager.activeCircle?.id)").count - 1, 2,
                       "a focus waits for, and flies to, the active circle's row")
        // No screen reads a member's row across circles: the roster row's
        // "last seen" takes its own circle's.
        let circles = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(circles.contains(
            "return MapView.heldRow(circleManager.memberLocations[member.userId], in: circle.id)"))
        XCTAssertFalse(circles.contains("return circleManager.memberLocations[member.userId]"))
    }
}
