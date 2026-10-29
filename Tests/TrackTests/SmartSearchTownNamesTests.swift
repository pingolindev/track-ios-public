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

/// Through the app: the town index (the mobile SDK's CityIndex, the real
/// framework) finds a town whose name holds a period, an apostrophe or a hyphen,
/// typed with or without them, and a town qualified after a comma. Seeded on disk
/// and offline, like SmartSearchReplacedSearchTests: both city tiers and no tile,
/// so the search answers from the town index and returns before any download.
///
/// WHAT EACH TEST HOLDS
///   Punctuation must not reach FTS5 as typed: a period, comma or hyphen makes the
///   query an FTS5 syntax error, and dropping an apostrophe ("john's" → "johns")
///   gives a token nothing indexed starts with. A typo fallback alone (the whole
///   query against each name, within two edits) finds a town typed as its bare
///   name ("St. Louis", "St. John's", "Winston-Salem") but nothing longer ("St.
///   Louis MO", "Winston-Salem NC", "St. Louis, MO"), nor "John's" or "Johns".
///   Each test below holds one of those; the bare names are checks that the
///   simple case keeps working.
///
/// THE SEED IS THE SHIPPED INDEX'S OWN DDL, column for column, without its `--`
/// comments. The line that decides how a name is split into tokens is
///
///     CREATE VIRTUAL TABLE cities_fts USING fts5(
///         name, ascii_name, alt_names, admin1, country_code,
///         content='cities', content_rowid='geoname_id',
///         tokenize='unicode61 remove_diacritics 2'
///     )
@MainActor
final class SmartSearchTownNamesTests: XCTestCase {

    private var dir: URL!
    /// One search per test, so the tiers a query opened stay open for the next.
    private var smart: SmartSearch?

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("towns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedCities()
    }

    override func tearDownWithError() throws {
        smart = nil
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
                    geoname_id   INTEGER PRIMARY KEY,
                    name         TEXT NOT NULL,
                    ascii_name   TEXT NOT NULL,
                    alt_names    TEXT NOT NULL DEFAULT '',
                    country_code TEXT NOT NULL,
                    admin1       TEXT NOT NULL,
                    lat          REAL NOT NULL,
                    lng          REAL NOT NULL,
                    population   INTEGER NOT NULL,
                    tile_id      TEXT NOT NULL,
                    tile_ids     TEXT NOT NULL DEFAULT '',
                    has_shard    INTEGER NOT NULL DEFAULT 0
                );
                CREATE VIRTUAL TABLE cities_fts USING fts5(
                    name, ascii_name, alt_names, admin1, country_code,
                    content='cities', content_rowid='geoname_id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                INSERT INTO cities (geoname_id, name, ascii_name, country_code, admin1, lat, lng, population, tile_id)
                    VALUES (4407066, 'St. Louis', 'St. Louis', 'US', 'MO', 38.6273, -90.1979, 301578, '9yzg');
                INSERT INTO cities (geoname_id, name, ascii_name, country_code, admin1, lat, lng, population, tile_id)
                    VALUES (6324733, 'St. John''s', 'St. John''s', 'CA', '05', 47.5649, -52.7093, 108860, 'fbrp');
                INSERT INTO cities (geoname_id, name, ascii_name, country_code, admin1, lat, lng, population, tile_id)
                    VALUES (4499612, 'Winston-Salem', 'Winston-Salem', 'US', 'NC', 36.0999, -80.2442, 249545, 'dnq8');
                INSERT INTO cities_fts(cities_fts) VALUES('rebuild');
                """)
        }
    }

    /// The town rows `query` lists.
    private func towns(_ query: String) async -> [String] {
        let smart = self.smart ?? SmartSearch(geocoder: TileGeocoder(storagePath: dir.path), storagePath: dir.path)
        self.smart = smart
        return await smart.search(query: query, limit: 8).cities.map(\.name)
    }

    func testATownWithAPeriodIsFoundWithAStateCode() async {
        let bare = await towns("St. Louis")
        XCTAssertEqual(bare.first, "St. Louis", "the bare name: \(bare)")
        // Three words: tier 1 is open from the query above.
        let coded = await towns("St. Louis MO")
        XCTAssertEqual(coded.first, "St. Louis", "the period made an FTS5 syntax error: \(coded)")
    }

    func testATownWithAnApostropheIsFoundWithOrWithoutIt() async {
        let typed = await towns("St. John's")
        XCTAssertEqual(typed.first, "St. John's", "the bare name: \(typed)")
        let bare = await towns("st johns")
        XCTAssertEqual(bare.first, "St. John's", "typed without its punctuation: \(bare)")
        let possessive = await towns("John's")
        XCTAssertEqual(possessive.first, "St. John's", "indexed as john + s: \(possessive)")
        let glued = await towns("Johns")
        XCTAssertEqual(glued.first, "St. John's", "the apostrophe left out: \(glued)")
    }

    func testATownWithAHyphenIsFoundWithAStateCode() async {
        let bare = await towns("Winston-Salem")
        XCTAssertEqual(bare.first, "Winston-Salem", "the bare name: \(bare)")
        let coded = await towns("Winston-Salem NC")
        XCTAssertEqual(coded.first, "Winston-Salem", "the hyphen made an FTS5 syntax error: \(coded)")
    }

    func testATownQualifiedAfterACommaIsFound() async {
        // Two words first, so tier 1 is open whatever region the simulator reports:
        // a longer query asks the country tier only.
        _ = await towns("St. Louis")
        let code = await towns("St. Louis, MO")
        XCTAssertEqual(code.first, "St. Louis", "a state code the index holds: \(code)")
        let name = await towns("St. Louis, Missouri")
        XCTAssertEqual(name.first, "St. Louis", "a state name it does not hold: the town before the comma: \(name)")
    }
}
