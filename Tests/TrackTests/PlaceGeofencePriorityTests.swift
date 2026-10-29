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
import CoreLocation
@testable import Track

/// Unit tests for `PlaceManager.nearestRegions`, the pure selector that keeps
/// the OS-registered geofence set under Core Location's 20-region cap.
/// The correctness properties: (1) when the set already fits under the cap
/// every place is kept; (2) when it exceeds the cap the `limit` NEAREST to the
/// user are chosen; (3) with no user fix yet a stable prefix is returned so a
/// cold launch still monitors something. All three are asserted here.
final class PlaceGeofencePriorityTests: XCTestCase {

    /// Minimal geofenced Place at a coordinate — only id + position matter to
    /// `nearestRegions`; the rest mirror a decoded place.
    private func makePlace(id: String, lat: Double, lng: Double) -> Place {
        Place(
            id: id,
            circleId: "circle-1",
            name: "P-\(id)",
            latitude: lat,
            longitude: lng,
            radius: 100,
            placeType: "place",
            boundaryRadius: 100,
            alertsEnabled: true,
            icon: .custom,
            color: "#3B82F6",
            createdAt: Date(timeIntervalSince1970: 0),
            address: nil,
            notes: nil,
            wrappedKey: nil,
            wrappedKeyNonce: nil,
            wrapTargetId: nil
        )
    }

    // Under the cap: every place is returned (nothing to prioritize away).
    func testUnderCapReturnsAll() {
        let places = (0..<5).map { makePlace(id: "\($0)", lat: 37.0 + Double($0), lng: -122.0) }
        let reference = CLLocation(latitude: 37.0, longitude: -122.0)
        let selected = PlaceManager.nearestRegions(from: places, to: reference, limit: 20)
        XCTAssertEqual(Set(selected.map { $0.id }), Set(places.map { $0.id }))
    }

    // Exactly at the cap: still returns all, none dropped.
    func testAtCapReturnsAll() {
        let places = (0..<20).map { makePlace(id: "\($0)", lat: 37.0 + Double($0) * 0.1, lng: -122.0) }
        let reference = CLLocation(latitude: 37.0, longitude: -122.0)
        let selected = PlaceManager.nearestRegions(from: places, to: reference, limit: 20)
        XCTAssertEqual(selected.count, 20)
    }

    // Over the cap with a fix: the nearest `limit` (by great-circle distance to
    // the reference) are chosen. Places are laid out at increasing latitude so
    // distance from the reference is strictly monotonic in the index.
    func testOverCapPicksNearest() {
        // 30 places marching north; index 0 is co-located with the reference.
        let places = (0..<30).map { makePlace(id: "\($0)", lat: 37.0 + Double($0) * 0.05, lng: -122.0) }
        let reference = CLLocation(latitude: 37.0, longitude: -122.0)
        let selected = PlaceManager.nearestRegions(from: places, to: reference, limit: 20)
        XCTAssertEqual(selected.count, 20)
        // The nearest 20 are ids 0...19; the farther 10 (20...29) are excluded.
        XCTAssertEqual(Set(selected.map { $0.id }), Set((0..<20).map { "\($0)" }))
        XCTAssertFalse(selected.contains { $0.id == "29" })
    }

    // Over the cap with NO reference fix (cold launch): a stable prefix of
    // `limit` is returned so we still monitor something until a fix arrives.
    func testOverCapNoReferenceReturnsPrefix() {
        let places = (0..<30).map { makePlace(id: "\($0)", lat: 37.0 + Double($0) * 0.05, lng: -122.0) }
        let selected = PlaceManager.nearestRegions(from: places, to: nil, limit: 20)
        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(selected.map { $0.id }, (0..<20).map { "\($0)" })
    }

    // A place co-located with (or nearest to) the user is always retained — the
    // property that keeps a just-crossed region monitored across a reprioritize.
    func testNearestIsAlwaysRetained() {
        var places = (0..<25).map { makePlace(id: "far-\($0)", lat: 40.0 + Double($0), lng: -122.0) }
        let here = makePlace(id: "here", lat: 37.0, lng: -122.0)
        places.append(here)
        let reference = CLLocation(latitude: 37.0, longitude: -122.0)
        let selected = PlaceManager.nearestRegions(from: places, to: reference, limit: 20)
        XCTAssertTrue(selected.contains { $0.id == "here" })
    }
}
