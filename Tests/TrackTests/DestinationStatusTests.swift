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

/// What a destination status this build does not recognise is allowed to
/// become.
///
/// WHY THIS IS WORTH TESTING
///   The server has a fourth status, `expired`, which it sets on stale
///   destinations, and its list endpoint keeps returning those rows for seven
///   days, so every client sees them. Decoding an unknown status as `.active`
///   is the one fallback that fails OPEN: `.active` is the sole status that
///   grants a map marker, auto-arrival eligibility, and the Cancel/Arrived
///   swipe actions. An expired destination decoded that way would be filed
///   under "Active", drawn on every circle member's map, labelled "On the
///   way", and offered an "Arrived" button the server answers with a 404 (it
///   accepts an arrival only for an active destination).
///
///   Pinning `expired` alone would only buy time until the next status, so the
///   rule under test is the general one: nothing unrecognised may decode to
///   `.active`.
final class DestinationStatusTests: XCTestCase {

    private static let circleA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    private func destination(id: String, status: Destination.Status) -> Destination {
        Destination(
            id: id,
            circleId: Self.circleA,
            userId: "11111111-1111-1111-1111-111111111111",
            name: "Home",
            latitude: 37.7749,
            longitude: -122.4194,
            status: status,
            notifyArrival: true,
            estimatedArrivalAt: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            arrivedAt: nil
        )
    }

    // MARK: - The decode path

    /// `expired` is a real status the server writes; it decodes as
    /// itself, never as `.active`.
    func testAnExpiredStatusDecodesAsExpiredAndNotActive() {
        let decoded = Destination.Status.from("expired")

        XCTAssertEqual(decoded, .expired)
        XCTAssertNotEqual(decoded, .active, "an expired destination is over, not on the way")
        XCTAssertFalse(decoded.isLive)
    }

    /// The general rule. A test that pinned only `expired` would let the
    /// next status the server invents straight through to `.active`.
    func testAnUnrecognisedStatusNeverDecodesAsActive() {
        for raw in ["quarantined", "paused", "", "ACTIVE", "active ", "🙂"] {
            let decoded = Destination.Status.from(raw)
            XCTAssertNotEqual(decoded, .active, "\"\(raw)\" must not be coerced to active")
            XCTAssertFalse(decoded.isLive, "\"\(raw)\" must not be live")
            XCTAssertEqual(decoded, .unknown, "\"\(raw)\" is not a status this build knows")
        }
    }

    /// The statuses this build does know still decode to themselves — the
    /// fail-closed default must not be swallowing real values.
    func testKnownStatusesRoundTrip() {
        XCTAssertEqual(Destination.Status.from("active"), .active)
        XCTAssertEqual(Destination.Status.from("arrived"), .arrived)
        XCTAssertEqual(Destination.Status.from("cancelled"), .cancelled)
        XCTAssertEqual(Destination.Status.from("expired"), .expired)
    }

    /// Exactly one status is live. The six surfaces that discriminate on
    /// liveness all route through `isLive`, so this is the whole rule.
    func testOnlyActiveIsLive() {
        XCTAssertEqual(Destination.Status.allCases.filter(\.isLive), [.active])
    }

    /// "Expired" is what the row must read, matching the Android
    /// app's DestinationAdapter, not "On the way".
    func testExpiredReadsAsExpired() {
        XCTAssertEqual(Destination.Status.expired.displayName, "Expired")
        XCTAssertNotEqual(Destination.Status.expired.displayName,
                          Destination.Status.active.displayName)
    }

    // MARK: - What the map draws

    /// `MapView.destinationMarkers` filters `DestinationsManager
    /// .activeDestinations`, which is this. An expired destination drawing a
    /// marker would be the most visible failure: a stale travel intention on
    /// every circle member's map.
    @MainActor
    func testExpiredAndUnknownDestinationsAreNotDrawnOnTheMap() {
        let rows = [
            destination(id: "live", status: .active),
            destination(id: "expired", status: .expired),
            destination(id: "unknown", status: .unknown),
            destination(id: "arrived", status: .arrived),
            destination(id: "cancelled", status: .cancelled),
        ]

        let drawn = DestinationsManager.live(in: rows).map(\.id)

        XCTAssertEqual(drawn, ["live"])
    }

    /// A list with nothing live in it draws nothing at all, rather than
    /// falling back to showing everything.
    @MainActor
    func testAnAllTerminalListDrawsNothing() {
        let rows = [
            destination(id: "expired", status: .expired),
            destination(id: "unknown", status: .unknown),
        ]

        XCTAssertTrue(DestinationsManager.live(in: rows).isEmpty)
    }
}
