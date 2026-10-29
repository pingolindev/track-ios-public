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
import SQLite3
@testable import Track
import PingolinTrackSDK

/// Finds WHERE `SmartSearch.search` gives up, off-device.
///
/// WHY THIS EXISTS
///   When the free (tile) path answers "No matches … on this part of the map"
///   for an address that is present, the exit it took is hard to see on a
///   device. `search()` has four exits before the fallback loop, and each one is
///   separately observable if you control the inputs:
///
///     1. empty query                          → .empty
///     2. cityWide with a focus                → cityWideSearch
///     3. the opt-in server path answered      → fromServer == true
///     4. the direct tile hit survived clamping → scopedTo == nil, rows > 0
///     …otherwise the candidate fallback runs  → scopedTo != nil
///
///   Each test below pins exactly one of those, so a failure names the exit
///   rather than just saying "no results". Everything is seeded on disk and runs
///   offline.
///
/// SEEDING
///   `TileGeocoder.forwardNear` opens every `tile_<id>.sqlite` under its storage
///   directory (`load_all_cached_tiles`) and queries `addresses` with LIKE — no
///   manifest and no network. So a temp directory holding one small SQLite tile
///   exercises the real code.
@MainActor
final class SmartSearchFallbackStageTests: XCTestCase {

    // Oakdale, CA, the seeded address. Cell 9qdn.
    let addrLat = 37.7666
    let addrLng = -120.8471

    var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartsearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw XCTSkip("could not seed fixture: \(message)")
        }
    }

    /// A tile in the shape the CDN ships: `addresses` + `pois`, queried by LIKE.
    func seedTile(id: String, street: String, houseNumber: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let path = dir.appendingPathComponent("tile_\(id).sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw XCTSkip("sqlite3_open failed") }
        try exec(db, """
            CREATE TABLE addresses (
                id INTEGER PRIMARY KEY, text TEXT NOT NULL, house_number TEXT, street TEXT,
                city TEXT, state TEXT, postcode TEXT, country TEXT,
                lat REAL NOT NULL, lng REAL NOT NULL, source TEXT NOT NULL, confidence REAL DEFAULT 1.0);
            CREATE TABLE pois (
                id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT, city TEXT, state TEXT,
                country TEXT, lat REAL NOT NULL, lng REAL NOT NULL, source TEXT);
            INSERT INTO addresses (text, house_number, street, city, state, postcode, country, lat, lng, source, confidence)
            VALUES ('\(houseNumber) \(street)', '\(houseNumber)', '\(street)', 'Oakdale', 'CA', '95361', 'US',
                    \(addrLat), \(addrLng), 'test', 1.0);
            """)
    }

    func makeSearch() -> SmartSearch {
        SmartSearch(geocoder: TileGeocoder(storagePath: dir.path), storagePath: dir.path)
    }

    /// Box around the seeded address, so the clamp keeps it.
    private var boxAroundAddress: SmartSearch.SearchArea {
        .fromViewport(south: addrLat - 0.05, west: addrLng - 0.05,
                      north: addrLat + 0.05, east: addrLng + 0.05)
    }

    /// Box far away (mid-Atlantic), so the clamp discards the address.
    var boxElsewhere: SmartSearch.SearchArea {
        .fromViewport(south: 30.0, west: -40.0, north: 31.0, east: -39.0)
    }

    // MARK: - Exit 4: the direct tile hit

    /// If the tile forward runs and the clamp keeps the row, `search` must
    /// return it directly — no scope, no fallback. A failure here means the
    /// search never reached the tile query (no `forward_near` line in the log).
    func testDirectPathReturnsASeededAddress() async throws {
        try seedTile(id: "9qdn", street: "Pinkston Avenue", houseNumber: "267")
        let outcome = await makeSearch().search(
            query: "pinkston avenue", limit: 8,
            focusLat: addrLat, focusLng: addrLng, area: boxAroundAddress)

        XCTAssertFalse(outcome.fromServer, "the server path must not run with the toggle off")
        // "This area", NOT a city. The row came from the tiles under the map, and
        // Android labels that case the same way so the sheet can head it
        // "In this area" instead of leaving it unattributed. What must still
        // never happen is inventing a CITY name for a row the fallback never
        // scoped to one — that is the assertion below.
        XCTAssertEqual(outcome.scopedTo, .nearbyArea,
                       "a clamped direct hit is attributed to the current area")
        XCTAssertEqual(outcome.scopedTo?.city, "this area",
                       "a direct hit must never be attributed to a named city")
        XCTAssertEqual(outcome.addresses.count, 1,
                       "the seeded address is on disk, in the box, and matches the query")
        XCTAssertEqual(outcome.addresses.first?.text, "267 Pinkston Avenue")
    }

    /// The clamp is what empties the direct path when the map sits away from
    /// the address. Pinning it separately means a failure above can be read as
    /// "the tile query never ran" rather than "the clamp ate it".
    func testClampDiscardsAnAddressOutsideTheBox() async throws {
        try seedTile(id: "9qdn", street: "Pinkston Avenue", houseNumber: "267")
        let outcome = await makeSearch().search(
            query: "pinkston avenue", limit: 8,
            focusLat: addrLat, focusLng: addrLng, area: boxElsewhere)
        XCTAssertTrue(outcome.addresses.isEmpty, "the row is outside the viewport box")
    }

    // MARK: - Exit 3: the server path stays out of the way

    /// The free build must never take the server path. This pins the guard rather
    /// than the network: with the default (absent) preference there is nothing to
    /// opt in with, so `fromServer` must be false whatever else happens.
    func testServerPathDoesNotRunWithoutTheOptIn() async throws {
        UserDefaults.standard.removeObject(forKey: SmartSearch.useServerGeocoderKey)
        try seedTile(id: "9qdn", street: "Pinkston Avenue", houseNumber: "267")
        let outcome = await makeSearch().search(
            query: "pinkston avenue", limit: 8,
            focusLat: addrLat, focusLng: addrLng, area: boxAroundAddress)
        XCTAssertFalse(outcome.fromServer)
    }

    // MARK: - Exit 1

    func testEmptyQueryReturnsEmpty() async throws {
        let outcome = await makeSearch().search(query: "   ", limit: 8)
        XCTAssertTrue(outcome.addresses.isEmpty)
        XCTAssertNil(outcome.scopedTo)
    }
}
