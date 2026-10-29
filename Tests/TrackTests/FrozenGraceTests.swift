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

/// The viewer's side of a rotation (`FrozenGrace`, as the Android app's
/// FrozenGraceTest): a frozen row already drawn stays drawn, at most 15
/// minutes from its first carry, until its member's phone re-seals it.
final class FrozenGraceTests: XCTestCase {

    private let circle = "e0000000-0000-4000-8000-0000000000d1"
    private let other = "e0000000-0000-4000-8000-0000000000d2"
    private let ana = "e0000000-0000-4000-8000-000000000021"
    private let ben = "e0000000-0000-4000-8000-000000000022"
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func drawn(_ userId: String, in circleId: String? = nil) -> LocationData {
        var row = LocationData(circleId: circleId ?? circle, userId: userId, deviceId: "d", latitude: 52.5, longitude: 13.4)
        row.sharingOff = true
        return row
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// One read of the circle: what was drawn before it, and who its rows say.
    private func read(_ grace: inout FrozenGrace, at now: Date, previous: [String], current: Set<String> = [],
                      stale: Set<String>, circleId: String? = nil, versionKnown: Bool = true) -> Set<String> {
        let rows = Dictionary(uniqueKeysWithValues: previous.map { ($0, drawn($0, in: circleId)) })
        return Set(grace.carried(circleId: circleId ?? circle, versionKnown: versionKnown, now: now, previous: rows,
                                 current: current, staleServed: stale).keys)
    }

    func testADrawnRowIsKeptAcrossARotationForFifteenMinutesAtMost() {
        var grace = FrozenGrace()
        XCTAssertEqual(read(&grace, at: at(0), previous: [ana], stale: [ana]), [ana])
        XCTAssertEqual(read(&grace, at: at(14 * 60 + 59), previous: [ana], stale: [ana]), [ana])
        XCTAssertEqual(read(&grace, at: at(15 * 60), previous: [ana], stale: [ana]), [])
        XCTAssertEqual(FrozenGrace.bound, 15 * 60)
    }

    /// Counted from its first carry, however many rotations follow: a read
    /// on a still older version moves nothing.
    func testALaterRotationDoesNotStretchIt() {
        var grace = FrozenGrace()
        _ = read(&grace, at: at(0), previous: [ana], stale: [ana])
        XCTAssertEqual(read(&grace, at: at(10 * 60), previous: [ana], stale: [ana]), [ana])
        XCTAssertEqual(read(&grace, at: at(15 * 60 + 1), previous: [ana], stale: [ana]), [])
    }

    /// Only one this phone drew, whose member is still served frozen and opens
    /// only under an older key: never anyone new, never one drawn current.
    func testOnlyARowAlreadyDrawnAndStillServedStale() {
        var grace = FrozenGrace()
        XCTAssertEqual(read(&grace, at: at(0), previous: [], stale: [ana]), [], "nothing new")
        XCTAssertEqual(read(&grace, at: at(0), previous: [ana], stale: []), [], "no longer served frozen")
        XCTAssertEqual(read(&grace, at: at(0), previous: [ana], current: [ana], stale: [ana]), [], "re-sealed")
        XCTAssertEqual(read(&grace, at: at(0), previous: [ana, ben], stale: [ben]), [ben])
        XCTAssertEqual(read(&grace, at: at(0), previous: [ana], stale: [ana], versionKnown: false), [],
                       "nothing while the version in use can't be read")
    }

    /// Once re-sealed, or no longer served frozen, a later rotation starts a
    /// grace of its own.
    func testANewGraceOnlyAfterTheRowWasDrawnAgain() {
        var grace = FrozenGrace()
        _ = read(&grace, at: at(0), previous: [ana], stale: [ana])
        XCTAssertEqual(read(&grace, at: at(16 * 60), previous: [ana], stale: [ana]), [])
        XCTAssertEqual(read(&grace, at: at(17 * 60), previous: [ana], stale: [ana]), [], "still the same grace")
        _ = read(&grace, at: at(18 * 60), previous: [], current: [ana], stale: [])
        XCTAssertEqual(read(&grace, at: at(60 * 60), previous: [ana], stale: [ana]), [ana], "a new rotation")
        XCTAssertEqual(read(&grace, at: at(75 * 60), previous: [ana], stale: [ana]), [])
    }

    /// Per circle, by the ids' one form; gone with the circle and at sign-out.
    func testPerCircleAndForgotten() {
        var grace = FrozenGrace()
        _ = read(&grace, at: at(0), previous: [ana], stale: [ana])
        XCTAssertEqual(read(&grace, at: at(10 * 60), previous: [ana], stale: [ana], circleId: other), [ana],
                       "another circle's grace is its own")
        XCTAssertEqual(read(&grace, at: at(16 * 60), previous: [ana.uppercased()], stale: [ana], circleId: circle.uppercased()),
                       [], "the same row in another spelling")
        grace.forget(circleId: circle)
        XCTAssertEqual(read(&grace, at: at(17 * 60), previous: [ana], stale: [ana]), [ana], "forgotten with the circle")
        XCTAssertEqual(read(&grace, at: at(24 * 60), previous: [ana], stale: [ana], circleId: other), [ana])
        XCTAssertEqual(read(&grace, at: at(26 * 60), previous: [ana], stale: [ana], circleId: other), [],
                       "the other circle's grace still runs from its own first carry")
        grace.clear()
        XCTAssertEqual(read(&grace, at: at(40 * 60), previous: [ana], stale: [ana], circleId: other), [ana], "sign-out")
    }
}
