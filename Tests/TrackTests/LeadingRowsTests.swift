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
import PingolinTrackSDK

/// The same rule in all three apps: on the local path the town matches are
/// always there, and every row whose whole name is what was typed, place or
/// town, comes ahead of the rows that only start with it: places in their
/// order, then towns in their rank. Otherwise "Hamburg" typed over San
/// Francisco would list the "Hamburger…" places on the phone's tiles first,
/// and the Hamburgs last, under "Other locations".
@MainActor
final class LeadingRowsTests: XCTestCase {

    private func city(_ name: String, ascii: String? = nil, country: String, admin1: String = "",
                      population: Int64, lat: Double, lng: Double, id: Int64) -> CityResult {
        CityResult(geonameId: id, name: name, asciiName: ascii ?? name, countryCode: country, admin1: admin1,
                   population: population, lat: lat, lng: lng, tileId: "", tileIds: [], hasShard: false)
    }

    private func place(_ name: String, _ text: String) -> GeocodingResult {
        GeocodingResult(text: text, lat: 37.7700, lng: -122.4130, resultType: "venue", confidence: 1.0,
                        name: name, city: "San Francisco", state: "CA", postcode: nil, country: "US", address: nil)
    }

    /// The towns named Hamburg as `CityRanking` ranks them from San Francisco for a
    /// US phone, and one that only starts with it.
    private var towns: [CityResult] {
        CityRanking.rank([
            city("Hamburg", country: "US", admin1: "NY", population: 56_936, lat: 42.7159, lng: -78.8295, id: 5_119_211),
            city("Hamburg", country: "DE", admin1: "04", population: 1_845_229, lat: 53.5507, lng: 9.9930, id: 2_911_298),
            city("Hamburg", country: "US", admin1: "PA", population: 4_289, lat: 40.5559, lng: -75.9824, id: 5_191_906),
            city("Hamburgsund", country: "SE", population: 834, lat: 58.5500, lng: 11.2700, id: 2_708_166),
        ], focusLat: 37.7749, focusLng: -122.4194, homeCountry: "US")
    }

    private var startsWithHamburg: [GeocodingResult] {
        [place("Hamburger Mary's", "Hamburger Mary's, 1582 Folsom St"),
         place("Hamburger Haven", "Hamburger Haven, 800 Clement St")]
    }

    func testEveryHamburgLeadsTheHamburgerPlaces() {
        let split = SmartSearch.split(addresses: startsWithHamburg, cities: towns, query: "Hamburg")
        XCTAssertEqual(split.leadingCities.map(\.countryCode), ["DE", "US", "US"],
                       "every town named Hamburg, in rank: Germany first from San Francisco")
        XCTAssertEqual(split.leadingCities.map(\.admin1), ["04", "NY", "PA"])
        XCTAssertTrue(split.leadingPlaces.isEmpty, "the Hamburger places only start with it")
        XCTAssertEqual(split.places.map(\.name), ["Hamburger Mary's", "Hamburger Haven"], "and keep their order below")
        XCTAssertEqual(split.cities.map(\.name), ["Hamburgsund"], "a town that only starts with it stays below too")
        let spaced = SmartSearch.split(addresses: startsWithHamburg, cities: towns, query: " hamburg ")
        XCTAssertEqual(spaced.leadingCities.count, 3, "any case, any spacing")
    }

    /// An exact place does not hold the exact towns down: a café named "Berlin"
    /// leads, then Berlin, DE, then the "Berliner…" places.
    func testAnExactPlaceLeadsAndTheExactTownsFollowIt() {
        let berlin = [city("Berlin", country: "DE", admin1: "16", population: 3_426_354, lat: 52.5244, lng: 13.4105,
                           id: 2_950_159)]
        let rows = [place("Berliner Weisse", "Berliner Weisse, 9 Valencia St"), place("Berlin", "Berlin, 33 Mission St")]
        let split = SmartSearch.split(addresses: rows, cities: berlin, query: "Berlin")
        XCTAssertEqual(split.leadingPlaces.map(\.name), ["Berlin"], "the café named exactly Berlin")
        XCTAssertEqual(split.leadingCities.map(\.name), ["Berlin"], "then the town, though a place is exact")
        XCTAssertEqual(split.places.map(\.name), ["Berliner Weisse"])
    }

    func testOnlyAWholeNameLeads() {
        let split = SmartSearch.split(addresses: startsWithHamburg, cities: towns, query: "Ham")
        XCTAssertTrue(split.leadingPlaces.isEmpty && split.leadingCities.isEmpty, "a prefix leads nothing")
        XCTAssertEqual(split.places.count, 2)
        XCTAssertEqual(split.cities.count, 4)
        let exactPlace = SmartSearch.split(addresses: startsWithHamburg, cities: towns, query: "Hamburger Mary's")
        XCTAssertEqual(exactPlace.leadingPlaces.map(\.name), ["Hamburger Mary's"])
        XCTAssertTrue(exactPlace.leadingCities.isEmpty)
        let zurich = [city("Zürich", ascii: "Zurich", country: "CH", admin1: "25", population: 341_730, lat: 47.3667,
                           lng: 8.55, id: 2_657_896)]
        XCTAssertEqual(SmartSearch.split(addresses: [], cities: zurich, query: "zurich").leadingCities.map(\.name),
                       ["Zürich"], "a town's ASCII name is its name too")
    }

    /// GeoNames' admin1 is a code; outside the US it is a number, which says
    /// nothing: "DE · 5,518 mi · 1.8M people", not "04, DE · …", everywhere a town
    /// is named: its row, the pin's label, a scope ("Loading addresses for Hamburg…").
    func testANumericRegionCodeIsLeftOut() {
        XCTAssertNil(AddressFormat.namedRegion("04"))
        XCTAssertNil(AddressFormat.namedRegion("16"))
        XCTAssertNil(AddressFormat.namedRegion(""))
        XCTAssertEqual(AddressFormat.namedRegion("NY"), "NY")
        XCTAssertEqual(AddressFormat.namedRegion("CA"), "CA")
        XCTAssertEqual(SmartSearch.Scope(city: "Hamburg", admin1: "04", countryCode: "DE").label, "Hamburg")
        XCTAssertEqual(SmartSearch.Scope(city: "Austin", admin1: "TX", countryCode: "US").label, "Austin, TX")
    }

    func testTheSheetPutsTheExactRowsFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Views/Map/AddressSearchView.swift"),
                              encoding: .utf8)
        let lead = try XCTUnwrap(text.range(of: "if !search.leadingPlaces.isEmpty || !search.leadingCities.isEmpty {"))
        let places = try XCTUnwrap(text.range(of: "Section(header: scopeHeader) {"))
        let others = try XCTUnwrap(text.range(of: "Section(header: Text(\"Other locations\")) {"))
        XCTAssertLessThan(lead.lowerBound, places.lowerBound, "the exact rows come before the address rows")
        XCTAssertLessThan(places.lowerBound, others.lowerBound, "and the other towns come last")
        XCTAssertTrue(text.contains("ForEach(Array(search.leadingPlaces.enumerated()), id: \\.offset) { _, result in\n"
                                    + "                                placeRow(result)\n"
                                    + "                            }\n"
                                    + "                            ForEach(Array(search.leadingCities.enumerated()), id: \\.offset) { _, city in\n"
                                    + "                                cityRow(city)"),
                      "places first, then towns")
        XCTAssertTrue(text.contains("            AddressFormat.namedRegion(city.admin1),"),
                      "the town's line drops a numeric region")
        XCTAssertTrue(text.contains("            state: AddressFormat.namedRegion(city.admin1),"),
                      "and so does a picked town's pin")
    }
}
