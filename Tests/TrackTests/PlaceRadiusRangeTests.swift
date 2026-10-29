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

/// The range a place's alert radius may be set to, and what happens to a place
/// that is already outside it.
///
/// WHY ONE RANGE
///   A place has ONE geofence radius and that radius IS its alert ring, so the
///   places screen and the map screen offer the same range: `PlaceRadius.range`,
///   in steps of `PlaceRadius.step`.
///
///   That is not cosmetic, because `EditPlaceSheet` binds the LIVE
///   `$place.radius` and `saveChanges()` re-registers the geofence. A Slider
///   clamps a bound value that falls outside its bounds, so with a range
///   narrower than the radii in use, a 2 km place — perfectly ordinary, set on
///   the map screen or on another platform — would be rewritten by the act of
///   opening the editor, and saved with nobody having dragged anything.
final class PlaceRadiusRangeTests: XCTestCase {

    // MARK: - One range

    /// The bounds the server will accept: 50 to 25000 m on both create and
    /// update, answering 400 outside that. A UI range wider than the server's
    /// turns a legal-looking drag into a rejected save.
    func testTheRangeFitsInsideWhatTheServerAccepts() {
        XCTAssertGreaterThanOrEqual(PlaceRadius.range.lowerBound, 50)
        XCTAssertLessThanOrEqual(PlaceRadius.range.upperBound, 25_000)
    }

    /// The floor is deliberately ABOVE the server's 50 m: 50 m is inside
    /// typical GPS error, so a ring that small fires on noise rather than on
    /// movement. What the server accepts and what is usable are different
    /// numbers.
    func testTheFloorIsAboveGPSNoise() {
        XCTAssertGreaterThanOrEqual(
            PlaceRadius.range.lowerBound, 100,
            "a sub-100 m geofence fires on GPS jitter, not on arrivals"
        )
    }

    /// The ceiling stays well above 500 m: a ceiling that low would shrink
    /// every larger place just by opening the edit sheet.
    func testTheCeilingStaysWellAbove500Metres() {
        XCTAssertGreaterThan(
            PlaceRadius.range.upperBound, 500,
            "a 500 m ceiling would silently shrink larger places"
        )
    }

    func testTheStepDividesTheRangeEvenly() {
        let span = PlaceRadius.range.upperBound - PlaceRadius.range.lowerBound
        XCTAssertEqual(
            span.truncatingRemainder(dividingBy: PlaceRadius.step), 0,
            "a step that does not divide the span makes the top value unreachable"
        )
    }

    /// A default outside the range would be clamped on first render, so the
    /// slider would open somewhere the code never asked for.
    func testTheDefaultSitsInsideTheRange() {
        XCTAssertTrue(PlaceRadius.range.contains(PlaceRadius.defaultMeters))
    }

    // MARK: - Editing a place that is already out of range

    /// The whole point. A place larger than the ceiling must keep its size when
    /// its editor opens — the range stretches to admit it rather than the value
    /// being clamped down to fit.
    func testAnOversizePlaceKeepsItsRadius() {
        let existing = 12_000.0
        let range = PlaceRadius.editableRange(for: existing)

        XCTAssertTrue(
            range.contains(existing),
            "opening the editor must not resize the place; \(existing) not in \(range)"
        )
        XCTAssertEqual(range.lowerBound, PlaceRadius.range.lowerBound,
                       "only the end that needs to move should move")
    }

    /// The same hazard at the other end. The server's floor is 50 m, so a 50 m
    /// place can exist; clamping it UP to 100 is a silent resize too, just in
    /// the other direction.
    func testAnUndersizePlaceKeepsItsRadius() {
        let existing = 50.0
        let range = PlaceRadius.editableRange(for: existing)

        XCTAssertTrue(range.contains(existing), "\(existing) not in \(range)")
        XCTAssertEqual(range.upperBound, PlaceRadius.range.upperBound)
    }

    /// A place already inside the range must not widen it — otherwise every
    /// editor would quietly offer a different scale from the create screen.
    func testAnInRangePlaceGetsTheOrdinaryRange() {
        XCTAssertEqual(PlaceRadius.editableRange(for: 1_500), PlaceRadius.range)
        XCTAssertEqual(PlaceRadius.editableRange(for: PlaceRadius.range.lowerBound), PlaceRadius.range)
        XCTAssertEqual(PlaceRadius.editableRange(for: PlaceRadius.range.upperBound), PlaceRadius.range)
    }

    /// A `ClosedRange` traps on lower > upper, and this one is built from a
    /// value that arrived over the wire. NaN from a malformed decode must not
    /// take the edit sheet down with it.
    func testANonFiniteRadiusFallsBackRatherThanTrapping() {
        XCTAssertEqual(PlaceRadius.editableRange(for: .nan), PlaceRadius.range)
        XCTAssertEqual(PlaceRadius.editableRange(for: .infinity), PlaceRadius.range)
        XCTAssertEqual(PlaceRadius.editableRange(for: -.infinity), PlaceRadius.range)
    }

    // MARK: - The label

    /// Both screens read the same value the same way, in km from 1000 up, so
    /// one place never reads "2000 meters" on one screen and "2.0 km" on the
    /// other.
    func testFormattingSwitchesToKilometresAtAThousand() {
        XCTAssertEqual(PlaceRadius.formatted(150), "150 m")
        XCTAssertEqual(PlaceRadius.formatted(999), "999 m")
        XCTAssertEqual(PlaceRadius.formatted(1_000), "1.0 km")
        XCTAssertEqual(PlaceRadius.formatted(5_000), "5.0 km")
    }
}
