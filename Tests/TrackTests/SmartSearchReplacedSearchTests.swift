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

/// A search the next keystroke replaced stops after the gateway step, rather
/// than going on through the tiles and on to downloads for a list nobody would
/// see. Seeded on disk and offline, like SmartSearchFallbackStageTests: the
/// tile under the address and both city tiers.
@MainActor
final class SmartSearchReplacedSearchTests: XCTestCase {

    private let addrLat = 37.7666
    private let addrLng = -120.8471
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("replaced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedTile()
        try seedCities()
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw XCTSkip("could not seed fixture: \(message)")
        }
    }

    private func seedTile() throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(dir.appendingPathComponent("tile_9qdn.sqlite").path, &db) == SQLITE_OK else {
            throw XCTSkip("sqlite3_open failed")
        }
        try exec(db, """
            CREATE TABLE addresses (
                id INTEGER PRIMARY KEY, text TEXT NOT NULL, house_number TEXT, street TEXT,
                city TEXT, state TEXT, postcode TEXT, country TEXT,
                lat REAL NOT NULL, lng REAL NOT NULL, source TEXT NOT NULL, confidence REAL DEFAULT 1.0);
            CREATE TABLE pois (
                id INTEGER PRIMARY KEY, name TEXT NOT NULL, category TEXT, city TEXT, state TEXT,
                country TEXT, lat REAL NOT NULL, lng REAL NOT NULL, source TEXT);
            INSERT INTO addresses (text, house_number, street, city, state, postcode, country, lat, lng, source, confidence)
            VALUES ('267 Pinkston Avenue', '267', 'Pinkston Avenue', 'Oakdale', 'CA', '95361', 'US',
                    \(addrLat), \(addrLng), 'test', 1.0);
            """)
    }

    /// Both tiers, so the cities step reads them from disk instead of downloading.
    private func seedCities() throws {
        let citiesDir = dir.appendingPathComponent("cities")
        try FileManager.default.createDirectory(at: citiesDir, withIntermediateDirectories: true)
        for file in ["cities-country.sqlite", "cities-tier1.sqlite"] {
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open(citiesDir.appendingPathComponent(file).path, &db) == SQLITE_OK else {
                throw XCTSkip("sqlite3_open failed")
            }
            try exec(db, """
                CREATE TABLE cities (
                    geoname_id INTEGER PRIMARY KEY, name TEXT, ascii_name TEXT, alt_names TEXT,
                    country_code TEXT, admin1 TEXT, population INTEGER, lat REAL, lng REAL,
                    tile_id TEXT, tile_ids TEXT, has_shard INTEGER DEFAULT 0);
                CREATE VIRTUAL TABLE cities_fts USING fts5(
                    name, ascii_name, alt_names, admin1, country_code,
                    content='cities', content_rowid='geoname_id');
                INSERT INTO cities VALUES (5378500, 'Oakdale', 'Oakdale', '', 'US', 'CA',
                    22259, \(addrLat), \(addrLng), '9qdn', '9qdn', 0);
                INSERT INTO cities_fts(cities_fts) VALUES('rebuild');
                """)
        }
    }

    /// The gateway is on and cannot answer (nil); `replace` says whether the next
    /// keystroke lands while it is being asked.
    private func search(replacedWhileAsking replace: Bool) async -> SmartSearch.Result {
        let smart = SmartSearch(geocoder: TileGeocoder(storagePath: dir.path), storagePath: dir.path)
        let slot = TaskSlot<SmartSearch.Result>()
        smart.serverAllowed = { true }
        smart.askServer = { _, _, _, _ in
            if replace { slot.task?.cancel() }
            return nil
        }
        let addrLat = self.addrLat, addrLng = self.addrLng
        slot.task = Task {
            await smart.search(query: "pinkston avenue", limit: 8, focusLat: addrLat, focusLng: addrLng)
        }
        return await slot.task!.value
    }

    /// The control: with nobody typing, a gateway that cannot answer hands over
    /// to the tiles, which hold the address.
    func testAGatewayThatCannotAnswerHandsOverToTheTiles() async {
        let outcome = await search(replacedWhileAsking: false)
        XCTAssertFalse(outcome.fromServer)
        XCTAssertEqual(outcome.addresses.first?.text, "267 Pinkston Avenue")
    }

    func testAReplacedSearchStopsAfterTheGatewayStep() async {
        let outcome = await search(replacedWhileAsking: true)
        XCTAssertTrue(outcome.addresses.isEmpty, "the tiles were searched for a list nobody reads")
        XCTAssertNil(outcome.scopedTo)
    }
}
