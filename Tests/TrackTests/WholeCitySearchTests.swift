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

/// The whole-city search ("beyond the map view") follows the map-view search by
/// itself, with no tap. Its downloads follow the rule all three apps share: an
/// unrequested download waits for an unmetered network; a tap, or a city typed
/// into the query, is a request. On a metered network the search covers the
/// city's tiles already on the phone and leaves the rest to a tap.
@MainActor
final class WholeCitySearchTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func cityWideBody() throws -> String {
        let text = try source("App/Services/SmartSearch.swift")
        let start = try XCTUnwrap(text.range(of: "private func cityWideSearch("))
        let end = try XCTUnwrap(text.range(of: "nonisolated static func mayDownload(", range: start.upperBound..<text.endIndex))
        return String(text[start.upperBound..<end.lowerBound])
    }

    private func row(_ text: String, _ lat: Double, _ lng: Double) -> GeocodingResult {
        GeocodingResult(text: text, lat: lat, lng: lng, resultType: "address", confidence: 1.0,
                        name: nil, city: nil, state: nil, postcode: nil, country: nil, address: nil)
    }

    // MARK: - When it may download

    func testAnUnrequestedDownloadWaitsForAnUnmeteredNetwork() {
        XCTAssertTrue(SmartSearch.mayDownload(.always, unmetered: false), "a tap is a request")
        XCTAssertTrue(SmartSearch.mayDownload(.always, unmetered: true))
        XCTAssertTrue(SmartSearch.mayDownload(.ifUnmetered, unmetered: true))
        XCTAssertFalse(SmartSearch.mayDownload(.ifUnmetered, unmetered: false),
                       "on a metered network the city's tiles wait for a tap")
    }

    /// The city tiles, the city index and the neighbours are each fetched only
    /// when the search may download.
    func testTheCityWidePathFetchesNothingItMayNot() throws {
        let body = try cityWideBody()
        XCTAssertTrue(body.contains("if mayDownload { await ensureCityTiers(for: cityName, onProgress: onProgress) }"))
        XCTAssertTrue(body.contains("                if mayDownload {\n"
                                    + "                    onProgress?(.loadingTiles(resolved))\n"
                                    + "                    let loaded = await withTimeout {\n"
                                    + "                        await self.offMain { Self.loadEveryTile(tileIds, town: town, geocoder: geocoder) }"),
                      "the city's tiles are loaded only when it may download")
        XCTAssertTrue(body.contains("moreToDownload = !Self.missingCells(tileIds, onDisk: onDisk).isEmpty"),
                      "and otherwise it says what it left")
        XCTAssertTrue(body.contains("            guard mayDownload else {\n"
                                    + "                return Result(addresses: [], cities: [], scopedTo: nil, moreToDownload: true)"),
                      "no city: the neighbours are the tap's to fetch")
        XCTAssertTrue(body.contains("guard Self.cellOnDisk(Self.geohash4(lat: focusLat, lng: focusLng), in: onDisk) else {"),
                      "the reverse lookup would fetch the cell under the map")
        XCTAssertTrue(body.contains("if downloads == .ifUnmetered { unmetered = await isUnmetered() }"))
    }

    // MARK: - What is on the phone

    func testTheTilesOnDiskAreTheSdksTileFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["tile_9qdn.sqlite", "tile_9q8yx.sqlite", "tile_9qdn.meta", "poi_9qde.sqlite", "notes.txt"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        XCTAssertEqual(SmartSearch.tilesOnDisk(in: dir.path), ["9qdn", "9q8yx"])
        XCTAssertEqual(SmartSearch.tilesOnDisk(in: dir.appendingPathComponent("missing").path), [])
    }

    func testACellIsOnThePhoneWholeOrSplit() {
        let onDisk: Set<String> = ["9qdn", "9q8yx"]
        XCTAssertTrue(SmartSearch.cellOnDisk("9qdn", in: onDisk))
        XCTAssertTrue(SmartSearch.cellOnDisk("9q8y", in: onDisk), "a metro cell split to precision 5")
        XCTAssertFalse(SmartSearch.cellOnDisk("9qde", in: onDisk))
        XCTAssertFalse(SmartSearch.cellOnDisk("9q8", in: onDisk), "a precision-5 tile is not its grandparent")
        XCTAssertEqual(SmartSearch.missingCells(["9qdn", "9qde", "9q8y", "9qdq"], onDisk: onDisk), ["9qde", "9qdq"])
    }

    // MARK: - When it follows the map-view search

    func testItFollowsAMapViewAnswerButNotAChoiceTheQueryMade() {
        let austin = SmartSearch.Scope(city: "Austin", admin1: "TX", countryCode: "US")
        let plain = SmartSearch.Result(addresses: [], cities: [], scopedTo: nil)
        XCTAssertTrue(SmartSearch.widens(after: plain, hasFocus: true))
        XCTAssertTrue(SmartSearch.widens(after: .init(addresses: [], cities: [], scopedTo: .nearbyArea), hasFocus: true))
        XCTAssertFalse(SmartSearch.widens(after: plain, hasFocus: false), "no map to search around")
        XCTAssertFalse(SmartSearch.widens(after: .init(addresses: [], cities: [], scopedTo: nil, fromServer: true),
                                          hasFocus: true), "the gateway searched the planet")
        XCTAssertFalse(SmartSearch.widens(after: .init(addresses: [], cities: [], scopedTo: austin), hasFocus: true),
                       "the query named the city to look in")
        XCTAssertFalse(SmartSearch.widens(after: .init(addresses: [], cities: [], scopedTo: nil, timedOut: true),
                                          hasFocus: true), "a download already timed out")
    }

    // MARK: - One list

    func testTheWholeCityAddsRowsOnceAndKeepsTheFirstSearchsCities() {
        let near = row("1 Main St", 37.7666, -120.8471)
        let far = row("900 Main St", 37.80, -120.80)
        let modesto = SmartSearch.Scope(city: "Modesto", admin1: "CA", countryCode: "US")
        let first = SmartSearch.Result(addresses: [near], cities: [], scopedTo: .nearbyArea)
        let wide = SmartSearch.Result(addresses: [far, near], cities: [], scopedTo: modesto, moreToDownload: true)
        let one = SmartSearch.widened(first, by: wide, limit: 8, focusLat: 37.7666, focusLng: -120.8471, query: "main st")
        XCTAssertEqual(one.addresses.map(\.text).sorted(), ["1 Main St", "900 Main St"], "each row once")
        XCTAssertEqual(one.addresses.first?.text, "1 Main St", "nearest the map first")
        XCTAssertEqual(one.scopedTo, modesto, "the city heads a list it added to")
        XCTAssertTrue(one.moreToDownload)

        let nothingNew = SmartSearch.widened(first, by: .init(addresses: [near], cities: [], scopedTo: modesto),
                                             limit: 8, focusLat: 37.7666, focusLng: -120.8471, query: "main st")
        XCTAssertEqual(nothingNew.scopedTo, .nearbyArea, "a city that added nothing does not head the list")
        XCTAssertFalse(nothingNew.moreToDownload)

        let stalled = SmartSearch.widened(.empty, by: .init(addresses: [], cities: [], scopedTo: modesto, timedOut: true),
                                          limit: 8, focusLat: 37.7666, focusLng: -120.8471, query: "main st")
        XCTAssertTrue(stalled.timedOut)
        XCTAssertEqual(stalled.scopedTo, modesto, "so the sheet can say which city it could not fetch")
    }
}
