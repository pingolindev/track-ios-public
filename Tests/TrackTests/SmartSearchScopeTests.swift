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

/// Pins the two pure pieces the viewport clamp and expand-to-city rest on:
/// `SearchArea` and `geohash4`.
///
/// WHY THIS IS WORTH TESTING
///   Both are silent failures. A wrong `geohash4` does not crash — it just filters
///   every hit out of `cityWideSearch`, so "search the whole city" returns nothing
///   and looks like missing data. A wrong `contains` either clamps away valid
///   results or clamps nothing at all, and both read as "the search is a bit odd"
///   rather than as a bug. Neither is visible from the UI without a second device
///   to compare against.
@MainActor
final class SmartSearchScopeTests: XCTestCase {

    // MARK: - geohash4

    /// Expected values are cross-checked two ways: against published geohashes
    /// (the u4pruydqqvj / gbsuv7ztq examples) and against an independent
    /// textbook implementation of the interleave. The algorithm in
    /// SmartSearch.swift is the same as the Android app's, so "it matches
    /// Android" would not catch a shared mistake.
    func testGeohash4MatchesPublishedValues() {
        XCTAssertEqual(SmartSearch.geohash4(lat: 57.64911, lng: 10.40744), "u4pr")
        XCTAssertEqual(SmartSearch.geohash4(lat: 48.669, lng: -4.329), "gbsu")
        XCTAssertEqual(SmartSearch.geohash4(lat: 0, lng: 0), "s000")
        XCTAssertEqual(SmartSearch.geohash4(lat: 40.7484, lng: -73.9857), "dr5r")
        XCTAssertEqual(SmartSearch.geohash4(lat: -33.8568, lng: 151.2153), "r3gx")
    }

    func testGeohash4IsAlwaysFourCharacters() {
        for (lat, lng) in [(90.0, 180.0), (-90.0, -180.0), (0.0, 179.9999)] {
            XCTAssertEqual(SmartSearch.geohash4(lat: lat, lng: lng).count, 4,
                           "precision must not vary at the poles or the antimeridian")
        }
    }

    // MARK: - SearchArea.contains

    func testContainsRejectsOutsideLatitude() {
        let box = SmartSearch.SearchArea(south: 40, west: -75, north: 41, east: -73)
        XCTAssertTrue(box.contains(lat: 40.75, lng: -73.98))
        XCTAssertFalse(box.contains(lat: 39.9, lng: -73.98))
        XCTAssertFalse(box.contains(lat: 41.1, lng: -73.98))
        XCTAssertFalse(box.contains(lat: 40.75, lng: -122.3), "Seattle is not in the box")
    }

    /// west > east means the box wraps past ±180. The inside is the UNION of
    /// [west, 180] and [-180, east]; a naive range test would check the GAP and
    /// exclude everything — and in Swift `180.0...(-179.0)` traps outright.
    func testContainsHandlesTheAntimeridian() {
        let fiji = SmartSearch.SearchArea(south: -20, west: 178, north: -16, east: -178)
        XCTAssertTrue(fiji.contains(lat: -18, lng: 179.5), "east of the dateline")
        XCTAssertTrue(fiji.contains(lat: -18, lng: -179.5), "west of the dateline")
        XCTAssertTrue(fiji.contains(lat: -18, lng: 178.0), "on the west edge")
        XCTAssertFalse(fiji.contains(lat: -18, lng: 100.0), "the gap must stay outside")
        XCTAssertFalse(fiji.contains(lat: -18, lng: 0.0))
    }

    // MARK: - SearchArea.fromViewport

    func testViewportIsPaddedNotTruncated() {
        // A 2°-tall viewport pads to 2.5° (25% each side), so a hit just past the
        // edge of the screen is still "here".
        let box = SmartSearch.SearchArea.fromViewport(
            south: 40, west: -75, north: 42, east: -73)
        XCTAssertEqual(box.south, 40 - 0.25, accuracy: 0.001)
        XCTAssertEqual(box.north, 42 + 0.25, accuracy: 0.001)
    }

    func testTinyViewportIsFlooredSoAStreetZoomStillSearchesItsNeighbourhood() {
        // ~50 m of road. Without the floor, "starbucks" at this zoom asks about one
        // block and gets nothing.
        let box = SmartSearch.SearchArea.fromViewport(
            south: 40.7480, west: -73.9860, north: 40.7485, east: -73.9855)
        let halfSpanKm = (box.north - box.south) / 2 * 111.32
        XCTAssertGreaterThanOrEqual(halfSpanKm, 1.99, "floor is 2 km of half-span")
        XCTAssertTrue(box.contains(lat: 40.7484, lng: -73.9857))
    }

    func testWholeWorldViewportDoesNotInvertIntoAnAntimeridianBox() {
        // Once the box spans every meridian, wrapping it would leave west > east,
        // which `contains` reads as a dateline box that excludes the middle of the
        // world — i.e. zoomed all the way out, nothing would match.
        let box = SmartSearch.SearchArea.fromViewport(
            south: -80, west: -180, north: 80, east: 180)
        XCTAssertEqual(box.west, -180)
        XCTAssertEqual(box.east, 180)
        XCTAssertTrue(box.contains(lat: 0, lng: 0))
        XCTAssertTrue(box.contains(lat: 40.75, lng: -73.98))
        XCTAssertTrue(box.contains(lat: -33.86, lng: 151.22))
    }

    func testPolarViewportDoesNotProduceAnInfiniteBox() {
        // cos(latitude) → ~0 at the pole; without the clamp the longitude half-span
        // divides by ~0.
        let box = SmartSearch.SearchArea.fromViewport(
            south: 89.9, west: -1, north: 89.99, east: 1)
        XCTAssertTrue(box.north.isFinite && box.south.isFinite)
        XCTAssertTrue(box.east.isFinite && box.west.isFinite)
        XCTAssertLessThanOrEqual(box.north, 90.0)
        XCTAssertGreaterThanOrEqual(box.south, -90.0)
    }

    func testViewportCrossingTheDatelineKeepsItsCentreOnTheRightSideOfThePlanet() {
        // east < west is the wrap. Halving a negative span without normalising it
        // first lands the centre at the antipode — a box over Fiji that searches
        // the Atlantic.
        let box = SmartSearch.SearchArea.fromViewport(
            south: -19, west: 179, north: -17, east: -179)
        XCTAssertTrue(box.contains(lat: -18, lng: 179.5))
        XCTAssertTrue(box.contains(lat: -18, lng: -179.5))
        XCTAssertFalse(box.contains(lat: -18, lng: 0), "the antipode must not be inside")
    }
}
