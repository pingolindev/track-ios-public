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

/// Pins `ServerGeocoder.parsePeliasFeatures` — the boundary where a Pelias
/// response becomes rows the map will pin.
///
/// WHY THIS IS WORTH TESTING
///   Every failure mode here is silent. A swapped GeoJSON coordinate pair pins
///   results in the wrong hemisphere without erroring. A missed layer filter puts
///   unranked administrative areas above population-ranked cities. A malformed
///   body that returned nil instead of [] would flip an authoritative no-match
///   into "fall back to tiles", which is the exact distinction the whole
///   null-vs-empty contract exists to preserve — and nothing about it is visible
///   from the UI, because both look like "no results".
final class ServerGeocoderParseTests: XCTestCase {

    private func payload(_ features: String) -> Data {
        Data(#"{"type":"FeatureCollection","features":[\#(features)]}"#.utf8)
    }

    private func feature(
        layer: String, label: String, lng: Double, lat: Double, extra: String = ""
    ) -> String {
        """
        {"type":"Feature",
         "geometry":{"type":"Point","coordinates":[\(lng),\(lat)]},
         "properties":{"layer":"\(layer)","label":"\(label)","name":"\(label)"\(extra)}}
        """
    }

    // MARK: - GeoJSON coordinate order

    /// Pelias emits [lng, lat]; GeocodingResult wants them the other way round.
    /// A swap is invisible in code review and puts 350 5th Ave in the Indian
    /// Ocean, so this is asserted with a point whose two values cannot be
    /// confused for each other.
    func testCoordinatesAreReadAsLngLatNotLatLng() throws {
        let data = payload(feature(layer: "address", label: "350 5th Avenue",
                                   lng: -73.9857, lat: 40.7484))
        let rows = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.lat, 40.7484, accuracy: 0.0001)
        XCTAssertEqual(row.lng, -73.9857, accuracy: 0.0001)
    }

    // MARK: - Place-layer filter

    func testPlacesOnlyKeepsConcretePlacesAndDropsAdminAreas() {
        let data = payload([
            feature(layer: "venue", label: "In-N-Out Burger", lng: -121.0, lat: 37.6),
            feature(layer: "address", label: "1 Main St", lng: -121.1, lat: 37.7),
            feature(layer: "street", label: "Main St", lng: -121.2, lat: 37.8),
            feature(layer: "locality", label: "Birmingham", lng: -1.9, lat: 52.5),
            feature(layer: "region", label: "England", lng: -1.5, lat: 52.9),
            feature(layer: "country", label: "United Kingdom", lng: -3.4, lat: 55.4),
        ].joined(separator: ","))

        let places = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true)
        XCTAssertEqual(places.map(\.text), ["In-N-Out Burger", "1 Main St", "Main St"],
                       "venue/address/street are places; locality/region/country are not")

        // Reverse keeps every layer — naming a point legitimately falls back to
        // its locality, so the filter must be opt-in rather than baked in.
        let all = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: false)
        XCTAssertEqual(all.count, 6)
    }

    /// The concrete case the filter exists for: the gateway answers
    /// "birmingham" with localities, and those are rows the on-device city index
    /// owns BETTER because it has population and the server does not.
    func testLocalitiesCannotOutrankTheCityChannel() {
        let data = payload(feature(layer: "locality", label: "Birmingham, England",
                                   lng: -1.9, lat: 52.5))
        XCTAssertTrue(ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true).isEmpty)
    }

    // MARK: - Malformed input returns [], never a crash

    func testMalformedBodiesParseToEmptyRatherThanThrowing() {
        for body in ["", "not json", "{}", #"{"features":null}"#, #"{"features":"nope"}"#, "[]"] {
            XCTAssertEqual(
                ServerGeocoder.parsePeliasFeatures(data: Data(body.utf8), placesOnly: true).count, 0,
                "\(body.isEmpty ? "<empty>" : body) should parse to no rows")
        }
    }

    func testAnAnswerWithNoFeaturesIsEmptyNotAFailure() {
        // This is the authoritative no-match. It must be distinguishable from the
        // server being unreachable, which is signalled by nil one level up in
        // `forward` — parse never returns nil.
        let rows = ServerGeocoder.parsePeliasFeatures(
            data: Data(#"{"type":"FeatureCollection","features":[]}"#.utf8), placesOnly: true)
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - Unplaceable rows

    func testFeaturesWithoutGeometryAreDroppedNotPinnedAtNullIsland() {
        // A forward hit with no coordinates cannot be placed. Dropping it beats
        // substituting (0, 0), which is in the Gulf of Guinea and would sort
        // first under proximity ranking from almost anywhere.
        let data = Data("""
        {"features":[
          {"type":"Feature","properties":{"layer":"venue","label":"Ghost Venue"}},
          \(feature(layer: "venue", label: "Real Venue", lng: -121.0, lat: 37.6))
        ]}
        """.utf8)
        let rows = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true)
        XCTAssertEqual(rows.map(\.text), ["Real Venue"])
    }

    func testFeatureWithoutALabelOrNameIsDropped() {
        let data = Data("""
        {"features":[{"type":"Feature",
          "geometry":{"type":"Point","coordinates":[-121.0,37.6]},
          "properties":{"layer":"venue"}}]}
        """.utf8)
        XCTAssertTrue(ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true).isEmpty)
    }

    // MARK: - Locality fields feed the row's secondary line

    func testLocalityFieldsAreMappedForTheSecondaryLine() throws {
        // Raw string: a bare `"""` here opens a multi-line literal, not a quote.
        let extra = #","locality":"New York","region_a":"NY","postalcode":"10118","country_a":"USA","street":"5th Avenue""#
        let data = payload(feature(layer: "address", label: "350 5th Avenue",
                                   lng: -73.9857, lat: 40.7484, extra: extra))
        let row = try XCTUnwrap(
            ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true).first)
        XCTAssertEqual(row.city, "New York")
        XCTAssertEqual(row.state, "NY")
        XCTAssertEqual(row.postcode, "10118")
        XCTAssertEqual(row.country, "USA")
        // Same renderer as tile rows, so a server row reads identically.
        XCTAssertEqual(AddressFormat.localityLine(row, home: "US"), "New York, NY 10118")
    }

    // MARK: - Layer mapping

    /// A venue must become `"poi"`, not the raw Pelias layer `"venue"`.
    ///
    /// This is load-bearing rather than cosmetic: every POI-specific behaviour
    /// tests for `"poi"`, so a `"venue"` row would silently skip the street line
    /// AND the same-address dedup. It would also disagree with the tile
    /// geocoder, whose rows are `"poi"`/`"address"` — and both land in one list.
    func testVenueLayerBecomesPoiWithItsStreet() {
        let data = payload(feature(
            layer: "venue", label: "Pink's Hot Dogs", lng: -119.0, lat: 34.2,
            extra: #","housenumber":"630","street":"Ventura Blvd Ste 1215","locality":"Camarillo""#))
        let row = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true).first
        XCTAssertEqual(row?.resultType, "poi")
        XCTAssertEqual(row?.address, "630 Ventura Blvd Ste 1215",
                       "housenumber and street are joined, as Android does")
        XCTAssertEqual(row?.city, "Camarillo")
    }

    /// Address and street layers become `"address"` and carry NO street of their
    /// own — their primary line already is the street.
    func testAddressLayerCarriesNoSeparateStreet() {
        let data = payload(feature(
            layer: "address", label: "1 Main St", lng: -121.1, lat: 37.7,
            extra: #","housenumber":"1","street":"Main St""#))
        let row = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true).first
        XCTAssertEqual(row?.resultType, "address")
        XCTAssertNil(row?.address)
    }

    /// An address row's `text` is the street line from `name`, NOT `label`.
    /// Pelias appends ", Los Angeles, CA, USA" to the label, and the row's
    /// secondary line adds the locality again — so using the label would
    /// print it twice.
    func testAddressRowTextIsTheStreetLineNotTheLabel() {
        let data = payload("""
        {"type":"Feature",
         "geometry":{"type":"Point","coordinates":[-118.3,34.0]},
         "properties":{"layer":"address","name":"715 North La Brea Avenue",
                       "label":"715 North La Brea Avenue, Los Angeles, CA, USA",
                       "locality":"Los Angeles"}}
        """)
        let row = ServerGeocoder.parsePeliasFeatures(data: data, placesOnly: true).first
        XCTAssertEqual(row?.text, "715 North La Brea Avenue")
    }

    /// A venue with NO street keeps the neighbourhood, because that is the only
    /// thing distinguishing five "Pink's Hot Dogs / Los Angeles, CA" rows that
    /// are genuinely different outlets. Once a row HAS a street, the street does
    /// the job better and the neighbourhood yields — the line fits only one.
    func testStreetlessVenueKeepsTheNeighbourhood() {
        let withoutStreet = payload(feature(
            layer: "venue", label: "Pink's Hot Dogs", lng: -118.3, lat: 34.1,
            extra: #","neighbourhood":"Fairfax District","locality":"Los Angeles""#))
        XCTAssertEqual(
            ServerGeocoder.parsePeliasFeatures(data: withoutStreet, placesOnly: true).first?.city,
            "Fairfax District, Los Angeles")

        let withStreet = payload(feature(
            layer: "venue", label: "Pink's Hot Dogs", lng: -118.3, lat: 34.1,
            extra: #","housenumber":"709","street":"N La Brea Ave","neighbourhood":"Fairfax District","locality":"Los Angeles""#))
        XCTAssertEqual(
            ServerGeocoder.parsePeliasFeatures(data: withStreet, placesOnly: true).first?.city,
            "Los Angeles")
    }
}
