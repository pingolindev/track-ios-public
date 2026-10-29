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

/// A circle this account just made is selected when none is.
///
/// WHY THIS IS WORTH TESTING
///   Only a load picks the active circle (`activeAfterLoad`: none picked, the
///   first), so a `createCircle` that only appended the new circle would
///   leave nothing selected until the next load, up to three minutes: the map
///   would say "Select Circle" and "Notify my circle" would fail with "No
///   active circle".
final class NewCircleIsActiveTests: XCTestCase {
    private let made = "a7a70000-0000-4000-8000-0000000000d1"
    private let other = "a7a70000-0000-4000-8000-0000000000d2"

    func testTheNewCircleIsSelectedWhenNoneIs() {
        let created = Circle(id: made, name: "Family")
        XCTAssertEqual(CircleManager.activeAfterCreate(nil, created: created), created)
    }

    func testASelectedCircleStaysSelected() {
        let picked = Circle(id: other, name: "Work")
        XCTAssertNil(CircleManager.activeAfterCreate(picked, created: Circle(id: made, name: "Family")),
                     "making a circle never moves the person off the one they picked")
    }

    /// Selected as soon as it is listed: before the first roster pass and the
    /// records import, which wait on the network. (The name sealing right
    /// after the append is a task of its own, NamedNotificationsTests.)
    func testCreateCircleSelectsItAtOnce() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(manager.contains("""
                let circle = response.toModel(name: name)
                circles.append(circle)
        """))
        let create = try XCTUnwrap(manager.range(of: "    func createCircle(name: String, consent: ShownNotice?) async throws -> Circle {"))
        let end = try XCTUnwrap(manager.range(of: "        return circle\n    }\n", range: create.upperBound..<manager.endIndex))
        let body = String(manager[create.upperBound..<end.lowerBound])
        let appended = try XCTUnwrap(body.range(of: "        circles.append(circle)\n"))
        let selected = try XCTUnwrap(body.range(of: """
                if let picked = Self.activeAfterCreate(activeCircle, created: circle) {
                    setActiveCircle(picked)
                }
        """), "createCircle selects the new circle")
        let roster = try XCTUnwrap(body.range(of: "        _ = try? await loadMembers(for: circle.id)\n"))
        XCTAssertLessThan(selected.lowerBound, roster.lowerBound, "selected before anything waits")
        guard appended.upperBound <= selected.lowerBound else { return XCTFail("selected before it is listed") }
        let between = body[appended.upperBound..<selected.lowerBound]
        for awaited in ["        await ", "        _ = try? await ", "try await "] {
            XCTAssertFalse(between.contains(awaited), "nothing awaited between the append and the selection")
        }
    }
}
