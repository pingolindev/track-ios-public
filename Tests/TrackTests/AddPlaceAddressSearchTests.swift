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
import MapKit
@testable import Track
import PingolinTrackSDK

/// Add Place's Location section has the map search's field (PlaceSearchModel,
/// with the same rules as the Map tab's search), and a pick moves the place
/// and the map there — so a typed address is reachable from the form itself,
/// not only through the Map tab's search and its pin card.
@MainActor
final class AddPlaceAddressSearchTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// AddPlaceSheet's source, from its declaration to the next type.
    private func sheet() throws -> String {
        let text = try source("App/Views/Places/PlacesView.swift")
        let start = try XCTUnwrap(text.range(of: "struct AddPlaceSheet: View {"))
        let end = text.range(of: "\nstruct ", range: start.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return String(text[start.lowerBound..<end])
    }

    func testAPickedAddressPutsThePlaceAndTheMapThere() throws {
        let result = GeocodingResult(text: "267 Pinkston Avenue", lat: 37.7666, lng: -120.8471, resultType: "address",
                                     confidence: 1.0, name: nil, city: "Oakdale", state: "CA", postcode: "95361",
                                     country: "US", address: nil)
        let (pin, camera) = AddPlaceSheet.mapAt(result)
        XCTAssertEqual(pin.latitude, 37.7666, accuracy: 1e-9)
        XCTAssertEqual(pin.longitude, -120.8471, accuracy: 1e-9)
        let mapCamera = try XCTUnwrap(camera.camera, "the map is moved, not left where it was")
        XCTAssertEqual(mapCamera.centerCoordinate.latitude, 37.7666, accuracy: 1e-9)
        XCTAssertEqual(mapCamera.centerCoordinate.longitude, -120.8471, accuracy: 1e-9)
        XCTAssertEqual(mapCamera.distance, 1000, accuracy: 0.5, "the same camera as Use Current Location")
    }

    private func result(_ text: String, name: String?) -> GeocodingResult {
        GeocodingResult(text: text, lat: 37.7666, lng: -120.8471, resultType: name == nil ? "address" : "venue",
                        confidence: 1.0, name: name, city: "Oakdale", state: "CA", postcode: nil,
                        country: "US", address: nil)
    }

    // MARK: - The name a pick leaves

    private func assertName(_ after: (name: String, fromPick: Bool), _ name: String, fromPick: Bool,
                            _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(after.name, name, message, line: line)
        XCTAssertEqual(after.fromPick, fromPick, message, line: line)
    }

    func testAPickNamesAnEmptyPlace() {
        let cafe = result("1 F St, Oakdale, CA", name: "Corner Cafe")
        assertName(AddPlaceSheet.nameAfterPick(current: "", fromPick: false, picked: cafe), "Corner Cafe", fromPick: true)
        assertName(AddPlaceSheet.nameAfterPick(current: "  ", fromPick: false, picked: cafe), "Corner Cafe", fromPick: true,
                   "blank is empty")
        let street = result("267 Pinkston Avenue", name: nil)
        assertName(AddPlaceSheet.nameAfterPick(current: "", fromPick: false, picked: street), "267 Pinkston Avenue",
                   fromPick: true, "a bare address is named as its row is")
    }

    func testAPickNeverReplacesATypedName() {
        let cafe = result("1 F St, Oakdale, CA", name: "Corner Cafe")
        assertName(AddPlaceSheet.nameAfterPick(current: "Grandma's", fromPick: false, picked: cafe), "Grandma's",
                   fromPick: false)
    }

    func testALaterPickReplacesAnEarlierPicksName() {
        let bakery = result("9 E St, Oakdale, CA", name: "Main Bakery")
        assertName(AddPlaceSheet.nameAfterPick(current: "Corner Cafe", fromPick: true, picked: bakery), "Main Bakery",
                   fromPick: true)
    }

    /// A keystroke in the name field makes the name the person's: the flag a pick
    /// sets clears on a real change, through the field's own binding.
    func testTypingMakesTheNameThePersonsOwn() throws {
        let text = try sheet()
        XCTAssertTrue(text.contains("if typed != name {\n"
                                    + "                                name = typed\n"
                                    + "                                nameFromPick = false\n"),
                      "a keystroke clears the pick's claim on the name")
        XCTAssertTrue(text.contains(
            "(name, nameFromPick) = Self.nameAfterPick(current: name, fromPick: nameFromPick, picked: result)"))
    }

    func testTheFieldRunsTheMapsSearchAroundWhatTheMapShows() throws {
        let text = try sheet()
        XCTAssertTrue(text.contains("@StateObject private var search = PlaceSearchModel()"))
        XCTAssertTrue(text.contains("TextField(\"Address, place or city\", text: $addressQuery)"))
        XCTAssertTrue(text.contains(".onChange(of: addressQuery) { _, query in\n                search.queryChanged(query)\n"),
                      "every edit goes to the search")
        XCTAssertTrue(text.contains("search.focus = (context.camera.centerCoordinate.latitude,"),
                      "searched around the map, wherever it was dragged")
        XCTAssertTrue(text.contains("let (pin, camera) = Self.mapAt(result)\n                coordinate = pin\n                cameraPosition = camera\n"),
                      "a pick moves the place and the map")
        XCTAssertTrue(text.contains("search.searchMore(addressQuery)"), "the metered row works here too")
        XCTAssertTrue(text.contains(".onAppear { search.watchNetwork() }\n"
                                    + "            .onDisappear { search.stopWatchingNetwork() }"),
                      "a stalled search runs again when the network is back, here too")
    }
}
