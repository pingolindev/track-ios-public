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

/// Pins the row-formatting rules, which match the Android app's
/// `AddressFormat.kt`.
///
/// WHY THIS IS WORTH TESTING
///   For the same query ("350 fifth ave, new york, ny") both apps must render the
///   same row: "New York, NY 10118 · 5385 mi", not "New York, NY, USA". The
///   postcode, the space-vs-comma join, the dropped home country and the distance
///   are four separate rules, and each one silently falls back to
///   plausible-looking output if it breaks, so nothing but a test notices.
final class AddressFormatTests: XCTestCase {

    private func result(
        city: String? = nil, state: String? = nil,
        postcode: String? = nil, country: String? = nil,
        lat: Double = 0, lng: Double = 0
    ) -> GeocodingResult {
        GeocodingResult(
            text: "350 5th Avenue", lat: lat, lng: lng,
            resultType: "address", confidence: 1.0,
            name: "350 5th Avenue", city: city, state: state,
            postcode: postcode, country: country, address: nil
        )
    }

    // MARK: - Locality line

    // `home:` is pinned in every case below. Without it these assertions would read
    // `Locale.current` and pass or fail depending on the simulator's region — a
    // green suite on a US machine and a red one on a European CI box.

    func testPostcodeJoinsTheRegionWithASpaceNotAComma() {
        // "NY 10118" is one postal unit; ", " between them would split it.
        XCTAssertEqual(
            AddressFormat.localityLine(
                result(city: "New York", state: "NY", postcode: "10118", country: "US"),
                home: "US"),
            "New York, NY 10118"
        )
    }

    func testHomeCountryIsOmittedInBothAlphaForms() {
        // The tiles carry whichever form the source data had, so both must drop out.
        for form in ["US", "USA", "us", "usa"] {
            XCTAssertEqual(
                AddressFormat.localityLine(
                    result(city: "New York", state: "NY", country: form), home: "US"),
                "New York, NY",
                "\(form) should have been recognised as the home country"
            )
        }
    }

    func testForeignCountryIsKept() {
        XCTAssertEqual(
            AddressFormat.localityLine(
                result(city: "Berlin", state: "Berlin", country: "DEU"), home: "US"),
            "Berlin, Berlin, DEU"
        )
    }

    /// The precise reason the check is not a prefix match: "CHN".hasPrefix("CH").
    /// A Swiss user must still see "CHN" on Chinese rows.
    func testAlphaThreeIsNotPrefixMatchedAgainstTheHomeAlphaTwo() {
        XCTAssertFalse(AddressFormat.isHomeCountryCode("CHN", home: "CH"),
                       "China must not read as domestic for a Swiss device")
        XCTAssertTrue(AddressFormat.isHomeCountryCode("CHE", home: "CH"),
                      "Switzerland's own alpha-3 must still match")
        XCTAssertTrue(AddressFormat.isHomeCountryCode("CHN", home: "CN"))
    }

    func testUnknownCodesNeverCollide() {
        // ICU maps unrecognised codes to nil rather than a shared placeholder, so
        // two different unknowns must not compare equal and hide a real country.
        XCTAssertFalse(AddressFormat.isHomeCountryCode("QQQ", home: "AAA"))
        XCTAssertFalse(AddressFormat.isHomeCountryCode("XYZ", home: "US"))
        XCTAssertFalse(AddressFormat.isHomeCountryCode(nil, home: "US"))
        XCTAssertFalse(AddressFormat.isHomeCountryCode("", home: "US"))
    }

    func testBlankFieldsCollapseRatherThanLeavingStrayCommas() {
        XCTAssertEqual(
            AddressFormat.localityLine(
                result(city: "Austin", state: "  ", country: "US"), home: "US"),
            "Austin")
        XCTAssertEqual(AddressFormat.localityLine(result(), home: "US"), "")
    }

    func testPostcodeWithoutARegionStillRenders() {
        XCTAssertEqual(
            AddressFormat.localityLine(
                result(city: "London", postcode: "SW1A 1AA", country: "GB"), home: "US"),
            "London, SW1A 1AA, GB")
    }

    // MARK: - Distance

    func testMetricTiers() {
        XCTAssertEqual(AddressFormat.distance(km: 0.4, useMiles: false), "400 m")
        XCTAssertEqual(AddressFormat.distance(km: 0.9994, useMiles: false), "999 m")
        // Boundary: exactly 1 km leaves the metres tier.
        XCTAssertEqual(AddressFormat.distance(km: 1.0, useMiles: false), "1.0 km")
        XCTAssertEqual(AddressFormat.distance(km: 9.99, useMiles: false), "10.0 km")
        // ...and exactly 10 km drops the decimal.
        XCTAssertEqual(AddressFormat.distance(km: 10.0, useMiles: false), "10 km")
        XCTAssertEqual(AddressFormat.distance(km: 8664.0, useMiles: false), "8664 km")
    }

    func testImperialTiers() {
        // Sub-tenth-of-a-mile switches UNIT rather than gaining decimals: "0.1 mi"
        // reads as a rounding artefact where "328 ft" reads as a measurement.
        XCTAssertEqual(AddressFormat.distance(km: 0.1, useMiles: true), "328 ft")
        XCTAssertEqual(AddressFormat.distance(km: 1.0, useMiles: true), "0.6 mi")
        // Past 10 miles the decimal goes: 62.1 would be false precision at that range.
        XCTAssertEqual(AddressFormat.distance(km: 100.0, useMiles: true), "62 mi")
        // The row the Android app shows for the NYC query.
        XCTAssertEqual(AddressFormat.distance(km: 8666.0, useMiles: true), "5385 mi")
    }

    func testTierSwitchesToFeetBelowATenthOfAMile() {
        let kmPerMile = 1.609344
        // Deliberately NOT testing exactly 0.1 mi: 0.1 * 1.609344 / 1.609344 is
        // 0.10000000000000002 in binary floating point, so an exact-boundary
        // assertion would be pinning an fp artefact rather than the rule.
        XCTAssertEqual(AddressFormat.distance(km: 0.11 * kmPerMile, useMiles: true), "0.1 mi")
        XCTAssertEqual(AddressFormat.distance(km: 0.09 * kmPerMile, useMiles: true), "475 ft")
    }

    // MARK: - Secondary line

    private func poi(
        _ name: String, street: String?, city: String?, state: String?, postcode: String?
    ) -> GeocodingResult {
        GeocodingResult(
            text: name, lat: 0, lng: 0, resultType: "poi", confidence: 1.0,
            name: name, city: city, state: state, postcode: postcode,
            country: "USA", address: street
        )
    }

    /// A POI leads with its street. Without this, four "Pink's Hot Dogs" rows on
    /// the server path all read "Los Angeles, CA 91602" and cannot be told
    /// apart; the Android app names each street.
    func testPoiRowLeadsWithTheStreet() {
        let r = poi("Pink's Hot Dogs", street: "630 Ventura Blvd Ste 1215",
                    city: "Camarillo", state: "CA", postcode: "93010")
        XCTAssertEqual(
            AddressFormat.secondaryLine(r, primary: "Pink's Hot Dogs", home: "US"),
            "630 Ventura Blvd Ste 1215 · Camarillo, CA 93010")
    }

    /// An ADDRESS row must not repeat the street it already shows as its primary.
    func testAddressRowKeepsOnlyTheLocality() {
        let r = result(city: "New York", state: "NY", postcode: "10118", country: "USA")
        XCTAssertEqual(
            AddressFormat.secondaryLine(r, primary: "350 5th Avenue", home: "US"),
            "New York, NY 10118")
    }

    /// A POI with no street falls back to the locality rather than rendering a
    /// stray separator.
    func testPoiWithoutAStreetIsJustTheLocality() {
        let r = poi("Togo's", street: nil, city: "Modesto", state: "CA", postcode: nil)
        XCTAssertEqual(
            AddressFormat.secondaryLine(r, primary: "Togo's", home: "US"), "Modesto, CA")
    }

    /// "Modesto" under "Modesto" is a wasted line — the part that merely repeats
    /// the primary is dropped, and the rest of the locality survives.
    func testALocalityPartRepeatingThePrimaryIsDropped() {
        let r = poi("Modesto", street: nil, city: "Modesto", state: "CA", postcode: "95354")
        XCTAssertEqual(
            AddressFormat.secondaryLine(r, primary: "Modesto", home: "US"), "CA 95354")
    }

    // MARK: - Placard line

    // The member callout, the SOS card and the place sheet render this line,
    // not `text` raw: raw `text` makes the locality a property of which
    // geocoder answered — the tile geocoder appends ", City, State",
    // ServerGeocoder leaves the street alone. The first two tests pin it:
    // same address, both wire shapes, one line out.

    private func addressRow(_ text: String) -> GeocodingResult {
        GeocodingResult(
            text: text, lat: 0, lng: 0, resultType: "address", confidence: 1.0,
            name: nil, city: "North Hollywood", state: "CA",
            postcode: "91601", country: "USA", address: nil
        )
    }

    /// Server geocoder shape — the street alone in `text`.
    func testAddressRowTakesItsLocalityFromTheStructuredFields() {
        XCTAssertEqual(
            AddressFormat.placardAddress(addressRow("709 N La Brea Ave"), home: "US"),
            "709 N La Brea Ave, North Hollywood, CA")
    }

    /// Tile geocoder shape — `text` already carries it. Not twice.
    func testALocalityAlreadyBakedIntoTextIsNotRepeated() {
        XCTAssertEqual(
            AddressFormat.placardAddress(
                addressRow("709 N La Brea Ave, North Hollywood, CA"), home: "US"),
            "709 N La Brea Ave, North Hollywood, CA")
    }

    /// Deduping by substring — which is what the tile geocoder itself does —
    /// eats a city that appears inside the street name. Segment-wise matching is
    /// why this line still says where it is.
    func testACityEchoedInsideTheStreetNameIsStillPrinted() {
        let r = GeocodingResult(
            text: "1 York Street", lat: 0, lng: 0, resultType: "address",
            confidence: 1.0, name: nil, city: "York", state: "ENG",
            postcode: "YO1", country: "GBR", address: nil
        )
        XCTAssertEqual(
            AddressFormat.placardAddress(r, home: "US"), "1 York Street, York, ENG, GBR")
    }

    /// The one-line placards lead with the POI name; it has nowhere else to go.
    func testThePOINameLeadsOnAOneLinePlacard() {
        let r = poi("Pink's Hot Dogs", street: "709 N La Brea Ave",
                    city: "North Hollywood", state: "CA", postcode: "91601")
        XCTAssertEqual(
            AddressFormat.placardAddress(r, withPOIName: true, home: "US"),
            "Pink's Hot Dogs, 709 N La Brea Ave, North Hollywood, CA")
        // Without it — the dropped-pin sheet, which titles the name separately.
        XCTAssertEqual(
            AddressFormat.placardAddress(r, home: "US"),
            "709 N La Brea Ave, North Hollywood, CA")
    }

    /// No postcode on a placard: the callout already shows coordinates, and the
    /// tiles store the zip float-formatted — 324,683 of the 344,371 postcodes in
    /// the San Francisco tile end in ".0".
    func testThePlacardOmitsThePostcodeTheLocalityLineKeeps() {
        let r = addressRow("709 N La Brea Ave")
        XCTAssertEqual(AddressFormat.localityLine(r, home: "US"), "North Hollywood, CA 91601")
        XCTAssertEqual(
            AddressFormat.placardAddress(r, home: "US"), "709 N La Brea Ave, North Hollywood, CA")
    }

    /// A row with no structured columns falls back to `text`.
    func testABareRowFallsBackToText() {
        let bare = GeocodingResult(
            text: "Somewhere, Someplace", lat: 0, lng: 0, resultType: "address",
            confidence: 0.5, name: nil, city: nil, state: nil,
            postcode: nil, country: nil, address: nil
        )
        XCTAssertEqual(AddressFormat.placardAddress(bare, home: "US"), "Somewhere, Someplace")
    }

    /// The dropped-pin sheet renders the name in its own title line, so a POI
    /// carrying nothing else must yield no address line — falling back to `text`
    /// there would print the name once per row.
    func testANameOnlyPOIYieldsNoLineForTheSheetThatTitlesItSeparately() {
        let r = poiWithNoCountry("Yosemite Falls")
        XCTAssertNil(AddressFormat.placardAddress(r, home: "US"))
        XCTAssertEqual(
            AddressFormat.placardAddress(r, withPOIName: true, home: "US"), "Yosemite Falls")
    }

    private func poiWithNoCountry(_ name: String) -> GeocodingResult {
        GeocodingResult(
            text: name, lat: 0, lng: 0, resultType: "poi", confidence: 0.5,
            name: name, city: nil, state: nil, postcode: nil, country: nil, address: nil
        )
    }
}
