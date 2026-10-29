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
import struct PingolinTrackSDK.GeocodingResult

/// Pins `CityRanking.rankPlaces`, the same policy as the Android app's `rankPlaces`.
///
/// WHY THIS IS WORTH TESTING
///   Sorting venue and address rows by DISTANCE ALONE is not a milder version of
///   this policy, it is the specific mistake this policy exists to prevent: it
///   silently undoes the match-quality gate, so the row nearest the map wins
///   whether or not its name answers what the user typed.
///
///   Every case below is one the Android implementation's docs name, with the
///   distances recomputed for this focus point so the numbers in the comments are
///   measured rather than repeated.
///
///   `homeCountry:` is pinned in every case. Left to `Locale.current` these would
///   pass or fail depending on the simulator's region.
final class PlaceRankingTests: XCTestCase {

    /// Modesto, CA: the focus point for all the cases below.
    private let modesto = (37.6391, -120.9969)

    private func poi(
        _ name: String, lat: Double, lng: Double,
        country: String? = "USA", address: String? = nil
    ) -> GeocodingResult {
        GeocodingResult(
            text: name, lat: lat, lng: lng,
            resultType: "poi", confidence: 1.0,
            name: name, city: nil, state: nil,
            postcode: nil, country: country, address: address
        )
    }

    // MARK: - Match quality gates, geography orders

    /// The headline case. A name that answers the query in full beats one that
    /// only partly does, at ANY distance.
    ///
    /// Measured from Modesto: Mark's 85 km, Casper's 96 km, Pink's 461 km. On
    /// distance alone Mark's leads Pink's by 0.729 of a score point, so a
    /// distance-only sort would put two hot dog stands nobody asked for above
    /// every actual Pink's.
    func testAFullNameMatchOutranksANearerPartialOne() {
        let rows = [
            poi("Mark's Hot Dogs", lat: 37.3382, lng: -121.8863),
            poi("Casper's Hot Dogs", lat: 37.6688, lng: -122.0808),
            poi("Pink's Hot Dogs", lat: 34.0983, lng: -118.3286),
        ]
        let ranked = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "pinks hot dogs")
        XCTAssertEqual(ranked.first?.name, "Pink's Hot Dogs")
    }

    /// The counterweight, and the reason the gate is COARSE. "In-N-Out" is
    /// exactly the query and "In-N-Out Burger" merely contains it, but both
    /// answer it in full, so they share a group and compete on distance:
    /// 44 km beats 2,420 km. The distance gap is 1.732 against an exact-name
    /// bonus of 0.3, which is the margin that keeps this honest.
    func testAnExactNameDoesNotBeatAFullerOneFarAway() {
        let rows = [
            poi("In-N-Out", lat: 36.9053, lng: -93.5677),            // Crane, MO
            poi("In-N-Out Burger", lat: 37.9577, lng: -121.2908),    // near Modesto
        ]
        let ranked = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "in n out")
        XCTAssertEqual(ranked.first?.name, "In-N-Out Burger")
    }

    /// Where the exact-name bonus DOES decide: same retail park, same distance,
    /// so nothing else separates them.
    func testAnExactNameWinsAtEqualDistance() {
        let rows = [
            poi("Ulta Beauty at Target", lat: 37.6500, lng: -121.0000),
            poi("Target", lat: 37.6500, lng: -121.0000),
        ]
        let ranked = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "target")
        XCTAssertEqual(ranked.first?.name, "Target")
    }

    /// Apostrophes are DELETED, not treated as separators. Split on the
    /// apostrophe and "Pink's" becomes `pink` + `s`, which matches a user typing
    /// "pinks" nowhere and drops the exact hit to the bottom tier.
    func testApostrophesDoNotBreakTheMatch() {
        XCTAssertTrue(CityRanking.isExactName(
            CityRanking.normalizeTokens("pinks hot dogs"), "Pink's Hot Dogs"))
        XCTAssertEqual(CityRanking.matchGroup(
            CityRanking.normalizeTokens("pinks hot dogs"), "Pink's Hot Dogs"), 0)
    }

    /// An empty query must not invent an order: every row lands in one group and
    /// ranking degrades to pure geography.
    func testAnEmptyQueryRanksByGeographyAlone() {
        let near = poi("Anything", lat: 37.6500, lng: -121.0000)
        let far = poi("Anything Else", lat: 34.0983, lng: -118.3286)
        let ranked = CityRanking.rankPlaces(
            [far, near], focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "")
        XCTAssertEqual(ranked.first?.name, "Anything")
    }

    // MARK: - Home country

    /// The geocoder labels rows alpha-3 ("USA") while the device region is
    /// alpha-2 ("US"). Both must count as home, and an unrelated code must not:
    /// a naive prefix test makes "CHN" home for a Swiss user.
    func testHomeCountryBonusHandlesAlpha3AndDoesNotCollide() {
        let rows = [
            poi("Cafe", lat: 37.7000, lng: -121.0000, country: "CHE"),
            poi("Cafe", lat: 37.7100, lng: -121.0000, country: "USA"),
        ]
        let ranked = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "cafe")
        // The US row is slightly FURTHER, so only the country bonus can lift it.
        XCTAssertEqual(ranked.first?.country, "USA")

        let swiss = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "CH", query: "cafe")
        XCTAssertEqual(swiss.first?.country, "CHE")
    }

    // MARK: - Duplicate collapsing

    /// The source carries genuine duplicates — "pinks hot dogs" returns two
    /// records for "201 Universal City Plaza". A row shows its street, not the
    /// neighbourhood that tells them apart, so uncollapsed they render as two
    /// identical lines.
    func testSameNameAtSameStreetCollapses() {
        let rows = [
            poi("Pink's Hot Dogs", lat: 34.1381, lng: -118.3534,
                address: "201 Universal City Plaza"),
            poi("Pink's Hot Dogs", lat: 34.1382, lng: -118.3535,
                address: "201 Universal City Plaza"),
        ]
        let ranked = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "pinks hot dogs")
        XCTAssertEqual(ranked.count, 1)
    }

    /// Deliberately narrow. With no street the address is not evidence of
    /// sameness, and collapsing would hide one of two genuinely different
    /// outlets in the same city — which is why the duplicate 350 5th Avenue rows
    /// on both platforms are left alone.
    func testRowsWithoutAStreetAreNeverCollapsed() {
        let rows = [
            poi("Pink's Hot Dogs", lat: 34.0983, lng: -118.3286),
            poi("Pink's Hot Dogs", lat: 34.1381, lng: -118.3534),
        ]
        let ranked = CityRanking.rankPlaces(
            rows, focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "pinks hot dogs")
        XCTAssertEqual(ranked.count, 2)
    }

    /// Addresses are not POIs and must never collapse, whatever their street
    /// column says.
    func testAddressRowsAreNeverCollapsed() {
        let a = GeocodingResult(
            text: "350 5th Avenue", lat: 40.7484, lng: -73.9857,
            resultType: "address", confidence: 0.8, name: nil, city: "New York",
            state: "NY", postcode: "10118", country: "USA", address: "5th Avenue")
        let b = GeocodingResult(
            text: "350 5th Avenue", lat: 40.7485, lng: -73.9858,
            resultType: "address", confidence: 0.8, name: nil, city: "New York",
            state: "NY", postcode: "10001", country: "USA", address: "5th Avenue")
        let ranked = CityRanking.rankPlaces(
            [a, b], focusLat: modesto.0, focusLng: modesto.1,
            homeCountry: "US", query: "350 fifth ave")
        XCTAssertEqual(ranked.count, 2)
    }

    /// A single row is returned untouched — there is nothing to reorder, and the
    /// dedup pass must not be able to empty a one-row list either.
    func testASingleRowIsUntouched() {
        let one = [poi("Pink's Hot Dogs", lat: 34.0983, lng: -118.3286,
                       address: "709 N La Brea Ave")]
        XCTAssertEqual(
            CityRanking.rankPlaces(one, focusLat: modesto.0, focusLng: modesto.1,
                                   homeCountry: "US", query: "pinks").count, 1)
    }
}
