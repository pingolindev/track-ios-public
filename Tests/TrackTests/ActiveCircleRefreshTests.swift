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

/// The map's circle button shows `CircleManager.activeCircle`, a copy.
/// Every load hands it the loaded circle, so a circle picked while it was
/// still locked is named once the load that opens it lands, without being
/// picked again.
final class ActiveCircleRefreshTests: XCTestCase {
    private let joined = "a7a70000-0000-4000-8000-0000000000c1"
    private let other = "a7a70000-0000-4000-8000-0000000000c2"

    func testALockedActiveCircleIsNamedByTheLoadThatOpensIt() {
        let locked = Circle(id: joined, name: Circle.lockedPlaceholderName, lockReason: .awaitingKey)
        XCTAssertNil(locked.readableName)
        let opened = Circle(id: joined, name: "Book Club", keyVersion: 2)
        let after = CircleManager.activeAfterLoad(locked, loaded: [Circle(id: other, name: "Family"), opened])
        XCTAssertEqual(after, opened)
        XCTAssertEqual(after?.readableName, "Book Club")
        XCTAssertEqual(after?.isLocked, false)
        XCTAssertEqual(after?.keyVersion, 2, "the whole copy, not just the name")
    }

    func testTheLoadedCopyIsMatchedByIdInAnySpelling() {
        let picked = Circle(id: joined.uppercased(), name: "Old name")
        let fresh = Circle(id: joined, name: "New name")
        XCTAssertEqual(CircleManager.activeAfterLoad(picked, loaded: [fresh]), fresh)
    }

    func testNonePickedTakesTheFirstAndOneNoLongerListedStays() {
        let first = Circle(id: other, name: "Family")
        XCTAssertEqual(CircleManager.activeAfterLoad(nil, loaded: [first]), first)
        XCTAssertNil(CircleManager.activeAfterLoad(nil, loaded: []))
        let gone = Circle(id: joined, name: "Left")
        XCTAssertEqual(CircleManager.activeAfterLoad(gone, loaded: [first]), gone,
                       "leaving and deleting move it on themselves")
    }

    /// The load asks on every pass, light polls included: the step sits after
    /// the full-only work, where both end.
    func testEveryLoadHandsTheActiveCircleItsLoadedCopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(manager.contains("""
                if let active = Self.activeAfterLoad(activeCircle, loaded: circles), active != activeCircle {
                    setActiveCircle(active)
                }
        """))
        XCTAssertFalse(manager.contains("if activeCircle == nil, let first = circles.first {"))
    }
}
