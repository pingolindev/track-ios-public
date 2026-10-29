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
import struct PingolinTrackSDK.CityResult

/// Pins `CityRanking`, ported from the Android app's `CityRanking.kt`.
///
/// WHY THIS IS WORTH TESTING
///   Resolving a city hint by population alone (`max(by: population)`, no focus,
///   no home country) goes wrong: on a device sitting in California it picks
///   **Ulanhot, Inner Mongolia**, purely because it is the most populous row
///   carrying the token, and the user sees "Couldn't find that address in
///   Ulanhot".
///
///   The failure is silent and directional: the search still works, still shows a
///   header, still names a real city. Only a second device in a different country
///   makes it obvious. These cases are the ones the Android app's own doc calls
///   out, so the two platforms can be compared row for row.
final class CityRankingTests: XCTestCase {

    private func city(
        _ name: String, _ country: String, pop: Int64, lat: Double, lng: Double
    ) -> CityResult {
        CityResult(geonameId: Int64(abs(name.hashValue % 100_000)), name: name,
                   asciiName: name, countryCode: country, admin1: "",
                   population: pop, lat: lat, lng: lng, tileId: "", tileIds: [],
                   hasShard: false)
    }

    /// Focus for the cases below: Akron, OH — the same reference point Android's
    /// doc uses, so the expected orders are directly comparable.
    private let akron = (41.0814, -81.5190)

    func testNearbySmallCityBeatsADistantLargerOne() {
        // "springfield" -> Springfield OH first, ahead of the bigger MA/MO/IL ones.
        let rows = [
            city("Springfield MA", "US", pop: 155_929, lat: 42.1015, lng: -72.5898),
            city("Springfield MO", "US", pop: 169_176, lat: 37.2090, lng: -93.2923),
            city("Springfield IL", "US", pop: 114_394, lat: 39.7817, lng: -89.6501),
            city("Springfield OH", "US", pop: 58_662, lat: 39.9242, lng: -83.8088),
        ]
        let ranked = CityRanking.rank(rows, focusLat: akron.0, focusLng: akron.1,
                                      homeCountry: "US")
        XCTAssertEqual(ranked.first?.name, "Springfield OH",
                       "the near one must win despite being the smallest")
    }

    func testHomeCountryBreaksAToweringPopulationLead() {
        // "birmingham" -> Birmingham AL first, Birmingham GB second.
        let rows = [
            city("Birmingham GB", "GB", pop: 1_144_919, lat: 52.4862, lng: -1.8904),
            city("Birmingham AL", "US", pop: 200_733, lat: 33.5186, lng: -86.8104),
        ]
        let ranked = CityRanking.rank(rows, focusLat: akron.0, focusLng: akron.1,
                                      homeCountry: "US")
        XCTAssertEqual(ranked.map(\.name), ["Birmingham AL", "Birmingham GB"])
    }

    /// The counterweight: the rule must not become "always pick something local",
    /// or a genuinely world-famous city stops being findable.
    func testProminenceIsNotSmothered() {
        // "delhi" -> Delhi IN first: 10.9M at ~12,000 km still beats 11k at 3,400 km.
        let rows = [
            city("Delhi CA", "US", pop: 11_565, lat: 37.4319, lng: -120.7783),
            city("Delhi IN", "IN", pop: 10_927_986, lat: 28.6519, lng: 77.2315),
        ]
        let ranked = CityRanking.rank(rows, focusLat: akron.0, focusLng: akron.1,
                                      homeCountry: "US")
        XCTAssertEqual(ranked.first?.name, "Delhi IN",
                       "a 10.9M city must not lose to an 11k namesake next door")
    }

    func testForeignCapitalStillWinsItsOwnName() {
        // "london" -> London GB, not London OH — even from Ohio, with the home
        // bonus working against it.
        let rows = [
            city("London OH", "US", pop: 10_119, lat: 39.8865, lng: -83.4482),
            city("London GB", "GB", pop: 8_866_180, lat: 51.5074, lng: -0.1278),
        ]
        let ranked = CityRanking.rank(rows, focusLat: akron.0, focusLng: akron.1,
                                      homeCountry: "US")
        XCTAssertEqual(ranked.first?.name, "London GB")
    }

    /// The concrete case this port exists for.
    func testTheUlanhotCase() {
        // A device in California resolving a token that several cities carry.
        // Population alone would pick the Chinese one.
        let modesto = (37.6391, -120.9969)
        let rows = [
            city("Ulanhot", "CN", pop: 165_846, lat: 46.0728, lng: 122.0692),
            city("Hot Springs", "US", pop: 37_930, lat: 34.5037, lng: -93.0552),
        ]
        XCTAssertEqual(rows.max(by: { $0.population < $1.population })?.name, "Ulanhot",
                       "positive control: population alone picks Ulanhot")
        let ranked = CityRanking.rank(rows, focusLat: modesto.0, focusLng: modesto.1,
                                      homeCountry: "US")
        XCTAssertEqual(ranked.first?.name, "Hot Springs",
                       "the new rule must prefer the domestic, far-closer city")
    }

    func testSingleRowAndEmptyAreReturnedUntouched() {
        let one = [city("Solo", "US", pop: 1, lat: 0, lng: 0)]
        XCTAssertEqual(CityRanking.rank(one, focusLat: 1, focusLng: 1).map(\.name), ["Solo"])
        XCTAssertTrue(CityRanking.rank([], focusLat: 1, focusLng: 1).isEmpty)
    }

    func testWithoutAFocusItFallsBackToPopulationPlusHomeCountry() {
        // The anchor path has no focus by definition; ranking must still be defined.
        let rows = [
            city("Big Foreign", "FR", pop: 5_000_000, lat: 48.85, lng: 2.35),
            city("Small Home", "US", pop: 40_000, lat: 37.0, lng: -120.0),
        ]
        XCTAssertEqual(
            CityRanking.rank(rows, focusLat: nil, focusLng: nil, homeCountry: "US").first?.name,
            "Big Foreign",
            "a 125x population gap outweighs the 10x home-country bonus")
    }
}
