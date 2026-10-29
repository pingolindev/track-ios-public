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

/// A place id the list serves more than once, in any spelling, drops EVERY row
/// with it. Keeping the first would let the server choose which content a place
/// id stands for, and so which geofence it registers and which alert fires.
final class PlaceDuplicateIdsTests: XCTestCase {

    private func place(_ id: String, name: String, lat: Double = 52.5) -> Place {
        Place(id: id, circleId: "circle-1", name: name, latitude: lat, longitude: 13.4, radius: 100,
              placeType: "place", boundaryRadius: 100, alertsEnabled: true, icon: .custom, color: "#3B82F6",
              createdAt: Date(timeIntervalSince1970: 0), address: nil, notes: nil, wrappedKey: nil,
              wrappedKeyNonce: nil, wrapTargetId: nil)
    }

    func testEveryRowOfADuplicatedIdGoes() {
        let home = "d3000000-0000-4000-8000-0000000000a1", work = "d3000000-0000-4000-8000-0000000000a2"
        let rows = [place(home, name: "Home"), place(work, name: "Work"), place(home, name: "Planted", lat: 1)]
        XCTAssertEqual(PlaceManager.withoutDuplicateIds(rows).map(\.name), ["Work"], "neither Home nor its twin")
        // Two spellings of one id are one id.
        let spelled = [place(home, name: "Home"), place(home.uppercased(), name: "Planted"), place(work, name: "Work")]
        XCTAssertEqual(PlaceManager.withoutDuplicateIds(spelled).map(\.name), ["Work"])
        let braced = [place(home, name: "Home"), place("{\(home)}", name: "Planted")]
        XCTAssertEqual(PlaceManager.withoutDuplicateIds(braced).map(\.name), [])
        // Nothing duplicated: nothing lost, in order, whatever the spelling.
        XCTAssertEqual(PlaceManager.withoutDuplicateIds([place(home, name: "Home"), place(work, name: "Work")]).map(\.name),
                       ["Home", "Work"])
        XCTAssertEqual(PlaceManager.withoutDuplicateIds([place(home.uppercased(), name: "Home"), place(work, name: "Work")])
                        .map(\.name), ["Home", "Work"])
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The monitored set AND the visible list both take it, at a load and when
    /// a new place's answer is added.
    func testTheMonitoredSetAndTheListBothTakeIt() throws {
        let manager = try source("App/Managers/PlaceManager.swift")
        XCTAssertTrue(manager.contains("        monitoredPlaces = Self.withoutDuplicateIds(decoded)\n        setupGeofences()"))
        // De-duplicated before the shares taken here are kept over it.
        XCTAssertTrue(manager.contains(
            "        let listed = Self.keepingTakenShares(Self.withoutDuplicateIds(decoded), takenShares, now: Date())\n"
            + "        takenShares = listed.stillTaken\n"
            + "        let unique = listed.places\n"
            + "        monitoredPlaces = unique\n"
            + "        places = Self.visibleInUI(unique, activeCircleId: circleId, selfCircleUuid: selfCircle)"))
        XCTAssertFalse(manager.contains("dedupById"))
        XCTAssertTrue(manager.contains("        places = Self.withoutDuplicateIds(places + [place])\n"
                                       + "        monitoredPlaces = Self.withoutDuplicateIds(monitoredPlaces + [place])\n"))
        XCTAssertFalse(manager.contains("places.append(place)"))
        // The log is a count only: never an id, a name or a position.
        XCTAssertTrue(manager.contains(
            "print(\"[Track] places: \\(input.count - kept.count) row(s) share an id; none of them is used\")"))
    }
}
