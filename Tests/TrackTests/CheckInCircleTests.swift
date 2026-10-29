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

import CoreLocation
import XCTest
@testable import Track

/// Everything a check-in carries comes from the circle it opened for: the
/// circle it goes to, taken when its sheet opens, and the place it names,
/// whose id goes in clear beside it. A personal place shared nowhere, or only
/// elsewhere, and another circle's place never ride along.
final class CheckInCircleTests: XCTestCase {

    private let family = "8b96aa7c-0000-4000-8000-0000000000f1"
    private let work = "8b96aa7c-0000-4000-8000-0000000000f2"
    private let mine = SelfKeyManager.selfCircleUuid
    private let here = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)

    private func place(_ id: String, filedUnder circleId: String, sharedTo: [String]? = nil,
                       latitude: Double = 37.3349) -> Place {
        var place = Place(id: id, circleId: circleId, name: id, latitude: latitude, longitude: -122.0090,
                          radius: 100, placeType: "place", boundaryRadius: nil, alertsEnabled: false,
                          icon: .custom, color: "#3B82F6", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                          address: nil, notes: nil, wrappedKey: nil, wrappedKeyNonce: nil, wrapTargetId: nil)
        place.sharedCircles = sharedTo
        return place
    }

    private func named(_ places: [Place], in circleId: String) -> String? {
        PlaceManager.checkInPlace(at: here, in: circleId, among: places, selfCircleUuid: mine)?.id
    }

    /// A place of this account's own rides along only where it is shared.
    func testAPersonalPlaceRidesOnlyWhereItIsShared() {
        XCTAssertNil(named([place("home", filedUnder: mine)], in: family), "shared nowhere")
        XCTAssertNil(named([place("home", filedUnder: mine, sharedTo: [work])], in: family), "shared elsewhere")
        XCTAssertEqual(named([place("home", filedUnder: mine, sharedTo: [work, family.uppercased()])], in: family),
                       "home", "shared here, in any spelling")
    }

    /// A place filed under this circle (its own, or a share received through
    /// it) is named; another circle's never.
    func testAnotherCirclesPlaceNeverRides() {
        XCTAssertEqual(named([place("park", filedUnder: family)], in: family), "park")
        XCTAssertNil(named([place("office", filedUnder: work)], in: family))
        XCTAssertEqual(named([place("office", filedUnder: work), place("park", filedUnder: family.uppercased())],
                             in: family), "park")
    }

    /// Only a place they are at.
    func testOnlyAPlaceTheyAreAt() {
        XCTAssertNil(named([place("far", filedUnder: family, latitude: 37.40)], in: family))
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The check-in asks for a place of the circle it goes to, never for any
    /// place loaded (personal ones, and the map's circle's).
    func testTheCheckInAsksForAPlaceOfItsOwnCircle() throws {
        let manager = try source("App/Managers/CheckInManager.swift")
        XCTAssertTrue(manager.contains(
            "if let place = placeManager.checkInPlace(at: location.coordinate, in: circleId) {"))
        XCTAssertFalse(manager.contains("placeManager.place(at:"))
    }

    /// What closes says why to VoiceOver too: the toast that says it is
    /// a bare Text gone in 2.5 s. At once, unless a sheet is closing
    /// (ToastAfterDismissalTests).
    func testTheMapsToastIsSpoken() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("""
                sendToast = message
                // Said to VoiceOver too: the toast is a bare Text, gone in 2.5 s,
                // so someone who can't see it would hear a sheet close, or a send
                // end, and never why.
                if afterDismissal {
                    heldToastAnnouncement = message
                } else {
                    AccessibilityNotification.Announcement(message).post()
                }
        """))
    }
}
