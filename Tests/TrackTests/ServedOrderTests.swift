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

/// Pins the three things the app does with the gateway's ranked search:
///
///   1. it recognises a reply the gateway ordered itself,
///   2. it shows those rows in the order they came, and
///   3. it tells the backend one language code and nothing more.
///
/// WHY THIS IS WORTH TESTING
///   Getting (2) wrong is invisible in every way but one: the right place is on
///   the list, lower down. The gateway puts the Eiffel Tower first for "eiffel
///   tower" typed in California; this app's own nearest-first pass puts a
///   preschool in Hayward above it, because "Tour Eiffel" does not contain the
///   words "eiffel tower". Nothing errors and nothing is missing.
final class ServedOrderTests: XCTestCase {

    private let cupertino = (37.3349, -122.0090)

    private func poi(_ name: String, lat: Double, lng: Double) -> GeocodingResult {
        GeocodingResult(
            text: name, lat: lat, lng: lng,
            resultType: "poi", confidence: 1.0,
            name: name, city: nil, state: nil,
            postcode: nil, country: nil, address: nil
        )
    }

    /// The gateway's answer to "eiffel tower" from Cupertino, in its order.
    private var eiffel: [GeocodingResult] {
        [
            poi("Tour Eiffel", lat: 48.8584, lng: 2.2945),
            poi("Eiffel Tower Montessori Preschool and Daycare", lat: 37.6330, lng: -122.0760),
            poi("Hôtel Novotel Paris Tour Eiffel", lat: 48.8500, lng: 2.2830),
        ]
    }

    private func reply(_ geocoding: String, features: String = "") -> Data {
        Data(#"{"geocoding":\#(geocoding),"type":"FeatureCollection","features":[\#(features)]}"#.utf8)
    }

    // MARK: - 1. Recognising the gateway's order

    func testAReplyTheGatewayMarkedIsOrdered() {
        XCTAssertTrue(ServerGeocoder.isOrdered(data: reply(#"{"ranking":{"version":1}}"#)))
        XCTAssertTrue(ServerGeocoder.isOrdered(data: reply(#"{"ranking":{"version":2}}"#)),
                      "a later version orders differently, but it is still the gateway's order")
        XCTAssertTrue(ServerGeocoder.isOrdered(
            data: reply(#"{"version":"0.2","ranking":{"version":1,"debug":{"rounds":2}}}"#)))
    }

    /// An older backend, a search without a focus point, and the gateway's own
    /// fallback all answer WITHOUT the mark, in Pelias's order.
    func testAReplyWithoutTheMarkIsNotOrdered() {
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"version":"0.2"}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":{}}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":{"version":0}}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":null}"#)))
    }

    /// Only a number is a version. `true` in particular reads as the number 1
    /// through NSNumber, and must not pass for one.
    func testOnlyANumberIsAVersion() {
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":{"version":true}}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":{"version":"1"}}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":1}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: reply(#"{"ranking":[1]}"#)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: Data("not json".utf8)))
        XCTAssertFalse(ServerGeocoder.isOrdered(data: Data()))
    }

    func testAForwardAnswerIsItsRowsAndTheGatewaysWordOnTheirOrder() {
        let feature = """
        {"type":"Feature","geometry":{"type":"Point","coordinates":[2.2945,48.8584]},
         "properties":{"layer":"venue","label":"Tour Eiffel, Paris, France","name":"Tour Eiffel"}}
        """
        let marked = ServerGeocoder.parseForward(
            data: reply(#"{"ranking":{"version":1}}"#, features: feature))
        XCTAssertTrue(marked.ordered)
        XCTAssertEqual(marked.rows.map(\.name), ["Tour Eiffel"])

        let unmarked = ServerGeocoder.parseForward(data: reply(#"{}"#, features: feature))
        XCTAssertFalse(unmarked.ordered)
        XCTAssertEqual(unmarked.rows.map(\.name), ["Tour Eiffel"])

        let empty = ServerGeocoder.parseForward(data: reply(#"{"ranking":{"version":1}}"#))
        XCTAssertTrue(empty.ordered)
        XCTAssertTrue(empty.rows.isEmpty, "an ordered nothing is still an answer")
    }

    // MARK: - 2. Showing it in that order

    /// The whole point. This app's own ranking would move the preschool up:
    /// that is asserted first, so the test cannot pass by the two orders
    /// happening to agree.
    func testRowsTheGatewayOrderedAreShownAsTheyCame() {
        let own = CityRanking.rankPlaces(eiffel, focusLat: cupertino.0, focusLng: cupertino.1,
                                         query: "eiffel tower")
        XCTAssertEqual(own.first?.name, "Eiffel Tower Montessori Preschool and Daycare",
                       "the app's own pass puts the preschool first")

        let shown = SmartSearch.arrange(
            ServerGeocoder.ServedPlaces(rows: eiffel, ordered: true), limit: 8,
            focusLat: cupertino.0, focusLng: cupertino.1, query: "eiffel tower")
        XCTAssertEqual(shown.map(\.name), eiffel.map(\.name))
    }

    /// Without the mark the app ranks the rows itself.
    func testRowsWithoutTheMarkAreStillRankedByTheApp() {
        let shown = SmartSearch.arrange(
            ServerGeocoder.ServedPlaces(rows: eiffel, ordered: false), limit: 8,
            focusLat: cupertino.0, focusLng: cupertino.1, query: "eiffel tower")
        let own = CityRanking.rankPlaces(eiffel, focusLat: cupertino.0, focusLng: cupertino.1,
                                         query: "eiffel tower")
        XCTAssertEqual(shown.map(\.name), own.map(\.name))
        XCTAssertEqual(shown.first?.name, "Eiffel Tower Montessori Preschool and Daycare")
    }

    /// The list is cut to its length either way, from the front.
    func testTheListIsCutToItsLengthFromTheFront() {
        for ordered in [true, false] {
            let shown = SmartSearch.arrange(
                ServerGeocoder.ServedPlaces(rows: eiffel, ordered: ordered), limit: 2,
                focusLat: cupertino.0, focusLng: cupertino.1, query: "eiffel tower")
            XCTAssertEqual(shown.count, 2)
        }
        let first = SmartSearch.arrange(
            ServerGeocoder.ServedPlaces(rows: eiffel, ordered: true), limit: 1,
            focusLat: nil, focusLng: nil, query: "eiffel tower")
        XCTAssertEqual(first.map(\.name), ["Tour Eiffel"])
        let none = SmartSearch.arrange(
            ServerGeocoder.ServedPlaces(rows: [], ordered: true), limit: 8,
            focusLat: nil, focusLng: nil, query: "zzyzx")
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - 3. One language code

    func testTheLanguageIsThePrimaryCodeOfTheFirstLanguage() {
        XCTAssertEqual(APIService.anonymousLanguage(preferred: ["de-CH", "fr-CH", "en"]), "de")
        XCTAssertEqual(APIService.anonymousLanguage(preferred: ["en-US"]), "en")
        XCTAssertEqual(APIService.anonymousLanguage(preferred: ["zh-Hans-CN"]), "zh")
        XCTAssertEqual(APIService.anonymousLanguage(preferred: ["fil-PH"]), "fil")
        XCTAssertEqual(APIService.anonymousLanguage(preferred: ["pt_BR"]), "pt")
        XCTAssertEqual(APIService.anonymousLanguage(preferred: ["JA"]), "ja")
    }

    func testSomethingThatIsNotALanguageCodeIsNotSent() {
        XCTAssertNil(APIService.anonymousLanguage(preferred: []))
        XCTAssertNil(APIService.anonymousLanguage(preferred: [""]))
        XCTAssertNil(APIService.anonymousLanguage(preferred: ["x"]))
        XCTAssertNil(APIService.anonymousLanguage(preferred: ["12-AB"]))
        XCTAssertNil(APIService.anonymousLanguage(preferred: ["german"]))
        XCTAssertNil(APIService.anonymousLanguage(preferred: ["dé"]))
        // Only the FIRST language counts: a bad first one is not skipped.
        XCTAssertNil(APIService.anonymousLanguage(preferred: ["*", "de"]))
    }

    /// The header replaces what URLSession would write on its own (the whole
    /// language list, with regions and weights): one code, nothing else.
    func testTheRequestCarriesThatCodeAndNothingElseAboutLanguage() {
        var request = URLRequest(url: URL(string: "https://example.invalid/api/v1/geocode/search")!)
        APIService.applyAnonymousLanguage(to: &request, preferred: ["de-CH", "fr-CH", "en"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "de")

        var untouched = URLRequest(url: URL(string: "https://example.invalid/api/v1/geocode/search")!)
        APIService.applyAnonymousLanguage(to: &untouched, preferred: [])
        XCTAssertNil(untouched.value(forHTTPHeaderField: "Accept-Language"))
    }
}
