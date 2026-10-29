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

/// Unit tests for `LocationCoarsener.coarsenLocation`, the sender-side
/// snap-to-grid applied to outgoing coordinates for "approximate" (bubble)
/// circles before encryption. The privacy guarantee rests on two properties:
/// the output is quantized to a grid cell (so nearby fixes collapse together)
/// and the displacement is bounded by the requested radius (so the reported
/// point stays near the truth). Both are asserted here.
final class LocationCoarsenerTests: XCTestCase {

    private let oneMileMeters = 1609.344
    private let metersPerDegLat = 111320.0

    // A non-positive radius means "coarsening disabled" → exact passthrough.
    func testNonPositiveRadiusIsIdentity() {
        let (lat0, lng0) = LocationCoarsener.coarsenLocation(lat: 37.7749, lng: -122.4194, radiusMeters: 0)
        XCTAssertEqual(lat0, 37.7749, accuracy: 0)
        XCTAssertEqual(lng0, -122.4194, accuracy: 0)

        let (latN, lngN) = LocationCoarsener.coarsenLocation(lat: 37.7749, lng: -122.4194, radiusMeters: -5)
        XCTAssertEqual(latN, 37.7749, accuracy: 0)
        XCTAssertEqual(lngN, -122.4194, accuracy: 0)
    }

    // Deterministic: the same input must always map to the same cell, so an
    // observer can't average repeated samples back to the true point.
    func testDeterministic() {
        let a = LocationCoarsener.coarsenLocation(lat: 37.7749, lng: -122.4194, radiusMeters: oneMileMeters)
        let b = LocationCoarsener.coarsenLocation(lat: 37.7749, lng: -122.4194, radiusMeters: oneMileMeters)
        XCTAssertEqual(a.0, b.0)
        XCTAssertEqual(a.1, b.1)
    }

    // Idempotent: re-snapping an already-snapped coordinate leaves it unchanged,
    // proving the output genuinely lands on the grid. The longitude grid width
    // depends on the latitude argument (meters-per-degree-lng scales by cos lat),
    // so longitude idempotence is asserted with the SAME latitude reused — which
    // is exactly how the real send path calls it (one call, original lat).
    func testIdempotent() {
        let lat = 37.7749, lng = -122.4194
        let once = LocationCoarsener.coarsenLocation(lat: lat, lng: lng, radiusMeters: oneMileMeters)
        // Latitude grid is independent of longitude → stable under re-snap.
        let latAgain = LocationCoarsener.coarsenLocation(lat: once.0, lng: lng, radiusMeters: oneMileMeters).0
        XCTAssertEqual(once.0, latAgain, accuracy: 1e-9)
        // Longitude grid depends on the latitude arg → stable when lat is reused.
        let lngAgain = LocationCoarsener.coarsenLocation(lat: lat, lng: once.1, radiusMeters: oneMileMeters).1
        XCTAssertEqual(once.1, lngAgain, accuracy: 1e-9)
    }

    // The snapped latitude is an exact multiple of the latitude cell size.
    func testSnappedLatIsOnGrid() {
        let cellLatDeg = oneMileMeters / metersPerDegLat
        let (lat, _) = LocationCoarsener.coarsenLocation(lat: 37.7749, lng: -122.4194, radiusMeters: oneMileMeters)
        let ratio = lat / cellLatDeg
        XCTAssertEqual(ratio, ratio.rounded(), accuracy: 1e-6)
    }

    // Displacement is bounded by half a cell (== radius/2 meters) on each axis:
    // rounding to the nearest grid center can move a point at most half a cell.
    func testDisplacementWithinRadius() {
        let lat = 37.7749, lng = -122.4194
        let (sLat, sLng) = LocationCoarsener.coarsenLocation(lat: lat, lng: lng, radiusMeters: oneMileMeters)
        let latMeters = abs(sLat - lat) * metersPerDegLat
        let metersPerDegLng = metersPerDegLat * cos(lat * .pi / 180.0)
        let lngMeters = abs(sLng - lng) * metersPerDegLng
        XCTAssertLessThanOrEqual(latMeters, oneMileMeters / 2 + 1e-6)
        XCTAssertLessThanOrEqual(lngMeters, oneMileMeters / 2 + 1e-6)
    }

    // Two fixes inside the same cell collapse to an identical coarse point, so a
    // recipient can't distinguish sub-cell movement. Checked per axis: a small
    // latitude nudge (fixed lng) collapses the latitude; a small longitude nudge
    // (fixed lat, so the lng grid is constant) collapses the longitude.
    func testNearbyPointsCollapse() {
        let lat = 37.7749
        let cellLatDeg = oneMileMeters / metersPerDegLat
        // Latitude axis: two fixes 0.05 cell apart, mid-cell so neither straddles
        // a grid line, share a latitude cell → identical snapped latitude.
        let baseLat = cellLatDeg * (2613 + 0.25)
        let latA = LocationCoarsener.coarsenLocation(lat: baseLat, lng: -122.0, radiusMeters: oneMileMeters).0
        let latB = LocationCoarsener.coarsenLocation(lat: baseLat + cellLatDeg * 0.05, lng: -122.0, radiusMeters: oneMileMeters).0
        XCTAssertEqual(latA, latB, accuracy: 1e-9)

        // Longitude axis: fixed latitude (constant lng grid), two fixes 0.05 cell
        // apart in longitude → identical snapped longitude.
        let cellLngDeg = oneMileMeters / (metersPerDegLat * cos(lat * .pi / 180.0))
        let baseLng = cellLngDeg * (5.0 + 0.25)
        let lngA = LocationCoarsener.coarsenLocation(lat: lat, lng: baseLng, radiusMeters: oneMileMeters).1
        let lngB = LocationCoarsener.coarsenLocation(lat: lat, lng: baseLng + cellLngDeg * 0.05, radiusMeters: oneMileMeters).1
        XCTAssertEqual(lngA, lngB, accuracy: 1e-9)
        // ...and the snap actually moved the raw input (not a no-op passthrough).
        XCTAssertNotEqual(lngB, baseLng + cellLngDeg * 0.05)
    }

    // Near the poles the meters-per-degree-of-longitude collapses toward zero;
    // the guard leaves longitude untouched rather than dividing by ~0.
    func testPolarLongitudeUntouched() {
        let lng = 123.456
        let (_, sLng) = LocationCoarsener.coarsenLocation(lat: 89.99999, lng: lng, radiusMeters: 100)
        XCTAssertEqual(sLng, lng, accuracy: 0)
    }
}
