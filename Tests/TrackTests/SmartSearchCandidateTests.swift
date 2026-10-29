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

/// Pins `SmartSearch.buildCandidates` — the pure half of the smart-fallback
/// search, the same as the Android app's `buildSmartCandidates`.
///
/// WHY THIS IS WORTH TESTING
///   The candidate list decides whether a query that misses the local tiles can be
///   rescued at all: each (hint, address) pair is one attempt at "resolve this city,
///   download its tiles, search the rest". Get the peeling wrong and the fallback
///   still runs, still downloads tiles, and still finds nothing — a silent
///   failure that looks exactly like "the address isn't in our data".
///
///   It is also the piece most likely to drift from Android, because it is pure
///   string handling written separately on each platform rather than shared.
///   These assertions mirror the Android app's tests for the same function and
///   extend them to the postcode behaviour.
@MainActor
final class SmartSearchCandidateTests: XCTestCase {

    private func hints(_ query: String) -> [String] {
        SmartSearch.buildCandidates(query).map(\.hint)
    }

    // MARK: - Comma form (mirrors the Android app's tests)

    func testCommaQueryPeelsTheCityHint() {
        let candidates = SmartSearch.buildCandidates("1 main street, austin, tx")
        XCTAssertEqual(candidates.first?.address, "1 main street",
                       "the address half must be everything before the first comma")
        XCTAssertTrue(candidates.contains { $0.hint == "austin tx" },
                      "most-specific hint should be tried first")
        XCTAssertTrue(candidates.contains { $0.hint == "austin" },
                      "bare city must remain reachable — alt_names does not always carry the state code")
    }

    /// The reason the ZIP-stripped variant exists at all: a postcode matches NO
    /// cities-tier column, so a hint carrying one can never resolve, and without
    /// this step the bare-city fallback loses on population sort (plain "hickman"
    /// picks KY over CA).
    func testTrailingPostcodeIsStrippedIntoItsOwnCandidate() throws {
        let h = hints("123 elm st, hickman, ca 95323")
        XCTAssertTrue(h.contains("hickman ca 95323"), "full hint is tried first")
        XCTAssertTrue(h.contains("hickman ca"), "ZIP-stripped hint must also be tried")
        // XCTUnwrap, not `!`: when this assertion fails the index is nil, and a
        // force-unwrap would crash the whole test runner instead of reporting one
        // failure.
        let full = try XCTUnwrap(h.firstIndex(of: "hickman ca 95323"))
        let stripped = try XCTUnwrap(h.firstIndex(of: "hickman ca"))
        XCTAssertLessThan(full, stripped, "most-specific must come before the stripped form")
    }

    // MARK: - An IME's comma

    /// A Japanese IME types "、" and a Chinese one "，" where an English keyboard
    /// types ",", and "､" is the halfwidth form. Each splits a place from its town
    /// as "," does, so "東京タワー、東京" takes the town path.
    func testAnIMECommaSplitsThePlaceFromItsTown() {
        for (query, place, town) in [("東京タワー、東京", "東京タワー", "東京"),
                                     ("东方明珠，上海", "东方明珠", "上海"),
                                     ("東京ﾀﾜｰ､東京", "東京ﾀﾜｰ", "東京")] {
            let candidates = SmartSearch.buildCandidates(query)
            XCTAssertEqual(candidates.map(\.address), [place], query)
            XCTAssertEqual(candidates.map(\.hint), [town], query)
            XCTAssertEqual(candidates.map(\.isPositionalGuess), [false], query)
        }
    }

    /// The ASCII comma splits a place from its town as well.
    func testTheASCIICommaIsUnchanged() {
        let candidates = SmartSearch.buildCandidates("Tokyo Tower, Tokyo")
        XCTAssertEqual(candidates.map(\.address), ["Tokyo Tower"])
        XCTAssertEqual(candidates.map(\.hint), ["Tokyo"])
    }

    /// Nothing else is a comma: "。" and a full-width space stay what they are.
    func testOnlyCommasAreCommas() {
        for comma in [",", "、", "，", "､"] {
            XCTAssertTrue(SmartSearch.isComma(Character(comma)), comma)
        }
        for other in ["。", "\u{3000}", ".", ";", " ", "・"] {
            XCTAssertFalse(SmartSearch.isComma(Character(other)), other)
        }
    }

    /// The place half the town's search and the area probe read is cut at
    /// an IME's comma too: both cuts ask `isComma`, and neither tests for
    /// a bare ",".
    func testBothPlaceHalvesAreCutAtAnyComma() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let search = try String(contentsOf: root.appendingPathComponent("App/Services/SmartSearch.swift"), encoding: .utf8)
        let cut = "        let head = q.prefix { !Self.isComma($0) }.trimmingCharacters(in: .whitespaces)\n"
        XCTAssertEqual(search.components(separatedBy: cut).count - 1, 2, "cityWideSearch and probeFocusArea")
        XCTAssertFalse(search.contains("$0 != \",\""))
        XCTAssertFalse(search.contains("query.contains(\",\")"))
        XCTAssertFalse(search.contains("split(separator: \",\")"))
    }

    // MARK: - Whitespace form

    func testThreePlusTokensPeelTheLastTwoAsHint() {
        let candidates = SmartSearch.buildCandidates("500 congress ave austin tx")
        XCTAssertTrue(candidates.contains { $0.hint == "austin tx" && $0.address == "500 congress ave" })
        XCTAssertTrue(candidates.contains { $0.hint == "austin" && $0.address == "500 congress ave" },
                      "the bare-city step is what rescues a hint whose state code does not index")
    }

    func testTwoTokensSplitIntoAddressAndCity() {
        let candidates = SmartSearch.buildCandidates("starbucks austin")
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.hint, "austin")
        XCTAssertEqual(candidates.first?.address, "starbucks")
    }

    // MARK: - Nothing to peel

    func testSingleTokenYieldsNoCandidates() {
        // One word carries no city hint, so the fallback must not run at all rather
        // than guess. Android relies on this too — its city-probe path handles the
        // single-token case separately.
        XCTAssertTrue(SmartSearch.buildCandidates("starbucks").isEmpty)
        XCTAssertTrue(SmartSearch.buildCandidates("").isEmpty)
        XCTAssertTrue(SmartSearch.buildCandidates("   ").isEmpty)
    }

    func testNoDuplicateCandidates() {
        // "austin, austin" would otherwise push the same pair twice and pay for the
        // same city resolve + tile download a second time.
        let candidates = SmartSearch.buildCandidates("main st, austin, austin")
        let pairs = candidates.map { "\($0.hint)|\($0.address)" }
        XCTAssertEqual(pairs.count, Set(pairs).count, "candidates must be de-duplicated")
    }

    // MARK: - Postcode shape

    func testPostcodeShapeRecognisesZipAndZipPlusFour() {
        XCTAssertTrue(SmartSearch.isPostcodeShaped("95323"))
        XCTAssertTrue(SmartSearch.isPostcodeShaped("95323-1234"))
        XCTAssertTrue(SmartSearch.isPostcodeShaped("123"))
    }

    func testPostcodeShapeRejectsNonPostcodes() {
        XCTAssertFalse(SmartSearch.isPostcodeShaped("tx"), "a state code is a real hint")
        XCTAssertFalse(SmartSearch.isPostcodeShaped("12"), "too short to be a postcode")
        XCTAssertFalse(SmartSearch.isPostcodeShaped("95323-"), "trailing dash is not ZIP+4")
        XCTAssertFalse(SmartSearch.isPostcodeShaped("9532a"))
        XCTAssertFalse(SmartSearch.isPostcodeShaped(""))
    }
}

/// Pins the corroboration gate that stops a positional guess becoming a header.
///
/// WHY THIS IS SEPARATE FROM THE PEELING TESTS
///   `buildCandidates` EMITS the guess — that is correct, "1 main st
///   springfield illinois" needs it, because the full state NAME does not index
///   (only the code does) so the bare token is the only thing that resolves.
///   But the guess must be corroborated before it is acted on. The two halves
///   fail differently and are worth failing separately.
@MainActor
final class CandidateCorroborationTests: XCTestCase {

    private func city(_ name: String) -> CityResult {
        CityResult(geonameId: 1, name: name, asciiName: name, countryCode: "US",
                   admin1: "", population: 1000, lat: 0, lng: 0,
                   tileId: "", tileIds: [], hasShard: false)
    }

    private func candidate(_ query: String, hint: String) throws -> SmartSearch.Candidate {
        try XCTUnwrap(SmartSearch.buildCandidates(query).first { $0.hint == hint },
                      "\(query) should still produce the hint \(hint)")
    }

    // MARK: - Only positional guesses are questioned

    func testTheSecondToLastTokenIsMarkedAsAGuess() throws {
        // "pinks hot dogs" -> the "hot" candidate is the positional one.
        XCTAssertTrue(try candidate("pinks hot dogs", hint: "hot").isPositionalGuess)
        // ...while the two-token hint it was peeled from is not.
        XCTAssertFalse(try candidate("pinks hot dogs", hint: "hot dogs").isPositionalGuess)
    }

    func testUserDelimitedAndTrailingHintsAreNotGuesses() throws {
        // A comma is the user telling us where the address stops.
        XCTAssertFalse(try candidate("350 5th ave, nyc", hint: "nyc").isPositionalGuess)
        // "<thing> <city>" is the natural two-token shape.
        XCTAssertFalse(try candidate("starbucks nyc", hint: "nyc").isPositionalGuess)
    }

    /// The reason the gate is narrow: "nyc" resolves through `alt_names`, so the
    /// city's own name is "New York City" and an exact-name rule would reject it.
    /// Applying the bar to these would break a very common input.
    func testAnAliasSurvivesWhenItIsNotAGuess() throws {
        let nyc = city("New York City")
        XCTAssertTrue(SmartSearch.cityCorroborates(nyc, try candidate("starbucks nyc", hint: "nyc")))
        XCTAssertTrue(SmartSearch.cityCorroborates(nyc, try candidate("350 5th ave, nyc", hint: "nyc")))
    }

    // MARK: - The bar for a guess

    func testAGuessIsRejectedWhenItMerelyPrefixesTheCityName() throws {
        // THE case. "hot" is a real prefix of the real city Hot Springs, which is
        // why the index alone cannot reject it: nothing in the cities data
        // distinguishes a hot dog from a town.
        let hotSprings = city("Hot Springs")
        XCTAssertFalse(
            SmartSearch.cityCorroborates(hotSprings, try candidate("pinks hot dogs", hint: "hot")),
            "a one-word guess must NAME a city, not merely start one")
    }

    func testAGuessIsRejectedWhenTheNameMerelyContainsIt() throws {
        XCTAssertFalse(SmartSearch.cityCorroborates(city("Desert Hot Springs"),
                                                    try candidate("pinks hot dogs", hint: "hot")))
        XCTAssertFalse(SmartSearch.cityCorroborates(city("Ulanhot"),
                                                    try candidate("pinks hot dogs", hint: "hot")))
    }

    func testAGuessIsAcceptedWhenItNamesTheCityOutright() throws {
        // The rescue this candidate exists for must keep working: the full state
        // NAME does not index, so "springfield" alone is the only thing that
        // resolves "1 main st springfield illinois".
        let c = try candidate("1 main st springfield illinois", hint: "springfield")
        XCTAssertTrue(c.isPositionalGuess)
        XCTAssertTrue(SmartSearch.cityCorroborates(city("Springfield"), c))
        XCTAssertTrue(SmartSearch.cityCorroborates(city("springfield"), c),
                      "comparison must be case-insensitive")
    }

    func testTheStateCodeShapeStillResolves() throws {
        let c = try candidate("500 congress ave austin tx", hint: "austin")
        XCTAssertTrue(SmartSearch.cityCorroborates(city("Austin"), c))
    }

    func testAsciiNameAlsoCorroborates() throws {
        // Diacritics: the display name and the ascii name differ, and the hint the
        // user typed will usually be the ascii one.
        let c = try candidate("1 rue de la paix zurich ch", hint: "zurich")
        let zurich = CityResult(geonameId: 1, name: "Zürich", asciiName: "Zurich",
                                countryCode: "CH", admin1: "", population: 1000,
                                lat: 0, lng: 0, tileId: "", tileIds: [], hasShard: false)
        XCTAssertTrue(SmartSearch.cityCorroborates(zurich, c))
    }

    // MARK: - Server cache key

    /// The key must change when the user pans a MEANINGFUL distance and stay put
    /// when the camera drifts. 3 decimals is ~100 m — same rule as Android's
    /// `searchCacheKey`, and the reason a cached answer cannot follow the map
    /// somewhere it no longer applies.
    func testCacheKeyIgnoresSubHundredMetreDrift() {
        let a = SmartSearch.searchCacheKey(query: "pinks hot dogs", limit: 8,
                                           focusLat: 37.63912, focusLng: -120.99687)
        let b = SmartSearch.searchCacheKey(query: "pinks hot dogs", limit: 8,
                                           focusLat: 37.63915, focusLng: -120.99689)
        XCTAssertEqual(a, b, "a few metres of camera drift must not miss the cache")

        let panned = SmartSearch.searchCacheKey(query: "pinks hot dogs", limit: 8,
                                                focusLat: 37.6500, focusLng: -120.99687)
        XCTAssertNotEqual(a, panned, "a real pan must miss the cache")
    }

    /// Case-insensitive on the query, and the limit is part of the key: asking
    /// for more rows than last time must not be served the shorter answer.
    func testCacheKeyFoldsCaseAndKeepsTheLimit() {
        XCTAssertEqual(
            SmartSearch.searchCacheKey(query: "Pinks Hot Dogs", limit: 8, focusLat: nil, focusLng: nil),
            SmartSearch.searchCacheKey(query: "pinks hot dogs", limit: 8, focusLat: nil, focusLng: nil))
        XCTAssertNotEqual(
            SmartSearch.searchCacheKey(query: "pinks", limit: 8, focusLat: nil, focusLng: nil),
            SmartSearch.searchCacheKey(query: "pinks", limit: 20, focusLat: nil, focusLng: nil))
    }
}
