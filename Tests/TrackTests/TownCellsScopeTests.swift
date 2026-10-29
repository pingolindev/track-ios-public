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

/// A query that names its town after a comma ("1 Infinite Loop, Cupertino") is
/// searched in that town's own tile too, as on the web, and so is "Search the
/// whole city". The cities index's tileIds leave out a SPLIT cell: Cupertino's
/// are '9q95,9q9m' while its own cell 9q9h is split into 32 precision-5
/// children, and San Francisco's have no 9q8y child. An address in 9q9h would
/// otherwise get "Couldn't find that address in Cupertino, CA", while the same
/// street without the town is found ("San Jose, CA 95014", the data's label for
/// 95014).
///
/// So the town's own tile, as the manifest has it at the town's point, is
/// loaded and in scope; on a miss, and only then, the eight beside it at that
/// tile's precision, each resolved through the manifest from its centre and
/// nearest the town's point first, are loaded within a window (as on Android).
/// A row is in scope when a scope tile is a prefix of its own precision-5
/// geohash.
@MainActor
final class TownCellsScopeTests: XCTestCase {

    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")

    /// A manifest by its tile ids: the named cells split into all 32 children,
    /// the rest held whole.
    private func manifest(split: [String], whole: [String]) -> Set<String> {
        var tiles = Set(whole)
        for parent in split { tiles.formUnion(Self.alphabet.map { parent + String($0) }) }
        return tiles
    }

    // Cupertino as the cities index has it, two addresses in its own split
    // cell, and one in the tile beside the town's: each at the point of its rows
    // in the address data (the manifest-v4 tiles).
    private let cupertino = (lat: 37.323, lng: -122.0322, tileId: "9q9hr", tileIds: ["9q95", "9q9m"])
    private let infiniteLoop = (lat: 37.331684, lng: -122.030372)   // 9q9hr
    private let torreAvenue = (lat: 37.31772, lng: -122.0285)       // 9q9hr, Cupertino Library
    private let stevensCreek = (lat: 37.322702, lng: -122.056049)   // 9q9hq, 21810 Stevens Creek Boulevard
    private lazy var bayArea = manifest(split: ["9q9h", "9q9k"],
                                        whole: ["9q95", "9q9m", "9q97", "9q9j", "9q9e", "9q9s", "9q96", "9q9n"])
    /// The eight beside Cupertino's 9q9hr in `bayArea` (the web client loads
    /// the same set), nearest the town's point first.
    private let besideCupertino = ["9q9hq", "9q9hp", "9q9hn", "9q9k2", "9q9hx", "9q9hw", "9q9k0", "9q9k8"]

    /// The scoped search's first step for Cupertino; `shard` nil for no shard.
    private func cupertinoScoped(shard: [String]?, loader: ManifestLoader) -> (cells: Set<String>, town: String?)? {
        let shardTiles: (() -> [String])?
        if let shard { shardTiles = { shard } } else { shardTiles = nil }
        return SmartSearch.scopedCells(shardTiles: shardTiles, tileIds: cupertino.tileIds,
                                       storedTileId: cupertino.tileId, lat: cupertino.lat, lng: cupertino.lng,
                                       load: loader.load)
    }

    /// The tiles a miss widens to around Cupertino's 9q9hr.
    private func besideCupertinoLoaded(_ loader: ManifestLoader, started: Date = Date(),
                                       now: @escaping () -> Date = { Date() }) -> Set<String> {
        SmartSearch.loadNeighbourTiles(of: "9q9hr", nearLat: cupertino.lat, nearLng: cupertino.lng,
                                       load: loader.load, started: started, now: now)
    }

    // MARK: - The town's own tile, and on a miss the eight beside it

    /// The town's tile through the manifest, and the eight beside it at the same
    /// precision: the very set the web loads for Cupertino.
    func testCupertinosOwnTileAndTheEightBesideIt() {
        let town = SmartSearch.townTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: cupertino.tileId,
                                        has: bayArea.contains)
        XCTAssertEqual(town, "9q9hr")
        let beside = SmartSearch.neighbourTiles(of: "9q9hr", nearLat: cupertino.lat, nearLng: cupertino.lng,
                                                has: bayArea.contains)
        XCTAssertEqual(Set(beside), ["9q9hx", "9q9k8", "9q9k2", "9q9k0", "9q9hp", "9q9hn", "9q9hq", "9q9hw"])
        XCTAssertEqual(beside.count, 8, "each once")
    }

    /// Two Cupertino addresses are found by the first search: the address data
    /// has both in the town's own 9q9hr. It labels both San Jose (95014), so
    /// Cupertino's shard has neither street and the index's tiles alone leave
    /// both out. 21810 Stevens Creek Boulevard is in 9q9hq beside it, so a
    /// miss widens to it.
    func testBothCupertinoAddressesAreFound() throws {
        let first = try XCTUnwrap(cupertinoScoped(shard: [], loader: ManifestLoader(bayArea)))
        XCTAssertEqual(first.cells, ["9q9hr", "9q95", "9q9m"])
        XCTAssertEqual(first.town, "9q9hr")
        for (what, point) in [("1 Infinite Loop", infiniteLoop), ("10800 Torre Avenue", torreAvenue)] {
            XCTAssertTrue(SmartSearch.inCells(first.cells, lat: point.lat, lng: point.lng), "\(what): the first search")
            XCTAssertFalse(SmartSearch.inCells(Set(cupertino.tileIds), lat: point.lat, lng: point.lng),
                           "\(what): the index's tiles alone leave it out")
            XCTAssertFalse(Set(cupertino.tileIds).contains(SmartSearch.geohash4(lat: point.lat, lng: point.lng)),
                           "\(what): nor is its precision-4 cell one of the index's tiles")
        }
        XCTAssertFalse(SmartSearch.inCells(first.cells, lat: stevensCreek.lat, lng: stevensCreek.lng), "a miss")
        let wider = first.cells.union(besideCupertinoLoaded(ManifestLoader(bayArea)))
        XCTAssertTrue(SmartSearch.inCells(wider, lat: stevensCreek.lat, lng: stevensCreek.lng), "found once widened")
        XCTAssertFalse(SmartSearch.inCells(Set(cupertino.tileIds), lat: stevensCreek.lat, lng: stevensCreek.lng))
    }

    /// San Francisco: its own tile 9q8yy holds City Hall; 1 Market Street is in
    /// 9q8zn beside it. The index's tiles have no 9q8y child.
    func testAnSFStreetDowntownIsFound() throws {
        let sf = manifest(split: ["9q8y", "9q8z"], whole: ["9q8v", "9q8w", "9q8x", "9q8t", "9qbb", "9qc0", "9q8u", "9qbp"])
        let tileIds = ["9q8v", "9qbb", "9qc0"]
        let town = (lat: 37.77493, lng: -122.41942)
        let first = try XCTUnwrap(SmartSearch.scopedCells(shardTiles: nil, tileIds: tileIds, storedTileId: "9q8yy",
                                                          lat: town.lat, lng: town.lng, load: ManifestLoader(sf).load))
        XCTAssertEqual(first.town, "9q8yy")
        let marketStreet = (lat: 37.7941, lng: -122.3951)   // 1 Market Street, 9q8zn
        XCTAssertTrue(SmartSearch.inCells(first.cells, lat: 37.77927, lng: -122.41924), "City Hall, the town's own tile")
        XCTAssertFalse(SmartSearch.inCells(first.cells, lat: marketStreet.lat, lng: marketStreet.lng), "a miss")
        let wider = first.cells.union(SmartSearch.loadNeighbourTiles(of: "9q8yy", nearLat: town.lat, nearLng: town.lng,
                                                                     load: ManifestLoader(sf).load, started: Date()))
        XCTAssertTrue(SmartSearch.inCells(wider, lat: marketStreet.lat, lng: marketStreet.lng), "found once widened")
        XCTAssertFalse(SmartSearch.inCells(Set(tileIds), lat: marketStreet.lat, lng: marketStreet.lng))
        XCTAssertFalse(SmartSearch.inCells(wider, lat: 47.6062, lng: -122.3321), "Seattle stays out")
    }

    /// A town whose cell is held whole: its tile is the index's, every row the
    /// index's tile puts in scope still is, and the cell test answers as a
    /// plain geohash test over the same ids. A miss widens to the eight whole
    /// cells beside it.
    func testAnUnsplitTownIsUnchanged() throws {
        let valley = manifest(split: [], whole: ["9qdn", "9q9v", "9qdj", "9qdm", "9q9y", "9qdq", "9q9z", "9qdp", "9qdr"])
        let first = try XCTUnwrap(SmartSearch.scopedCells(shardTiles: nil, tileIds: ["9qdn"], storedTileId: "9qdn",
                                                          lat: 37.62354, lng: -120.75326,
                                                          load: ManifestLoader(valley).load))
        XCTAssertEqual(first.cells, ["9qdn"])
        XCTAssertEqual(first.town, "9qdn")
        for point in [(37.62354, -120.75326), (37.70, -120.80), (37.55, -120.70)] {
            let before = ["9qdn"].contains(SmartSearch.geohash4(lat: point.0, lng: point.1))
            XCTAssertEqual(SmartSearch.inCells(first.cells, lat: point.0, lng: point.1), before, "\(point)")
        }
        XCTAssertEqual(SmartSearch.loadNeighbourTiles(of: "9qdn", nearLat: 37.62354, nearLng: -120.75326,
                                                      load: ManifestLoader(valley).load, started: Date()),
                       ["9q9v", "9qdj", "9qdm", "9q9y", "9qdq", "9q9z", "9qdp", "9qdr"], "the eight whole cells beside it")
    }

    // MARK: - The first step of the scoped search

    /// A hit costs nothing extra: the first step asks for the town's tile and
    /// the index's, never a tile beside the town.
    func testTheFirstStepLoadsNoNeighbour() throws {
        let loader = ManifestLoader(bayArea)
        _ = try XCTUnwrap(cupertinoScoped(shard: [], loader: loader))
        XCTAssertEqual(loader.asked, ["9q9h", "9q9hr", "9q95", "9q9m"],
                       "the town's tile first (its precision-4 id a soft miss, the cell being split), then the index's")
    }

    /// A shard that holds the term keeps its tiles, with the index's (not
    /// loaded: they only widen the scope) and the town's.
    func testAShardHitKeepsItsTilesTheIndexsAndTheTowns() throws {
        let loader = ManifestLoader(bayArea)
        let first = try XCTUnwrap(cupertinoScoped(shard: ["9q97"], loader: loader))
        XCTAssertEqual(first.cells, ["9q97", "9q95", "9q9m", "9q9hr"])
        XCTAssertFalse(loader.asked.contains("9q95"), "the index's tiles aren't loaded after a shard hit")
    }

    /// Nothing loaded is no scope, so the caller falls back to the centroid's
    /// cells: the town's id alone would have turned "couldn't load" into "not in
    /// Cupertino".
    func testNothingLoadedIsNoScopeSoTheSearchFallsBack() {
        XCTAssertNil(cupertinoScoped(shard: [], loader: ManifestLoader([])))
        XCTAssertNil(cupertinoScoped(shard: ["9q97"], loader: ManifestLoader([])))
    }

    /// The town's tile is a scope on its own when the index's tiles fail.
    func testTheTownsTileAloneIsAScope() throws {
        let first = try XCTUnwrap(cupertinoScoped(shard: [], loader: ManifestLoader(["9q9hr"])))
        XCTAssertEqual(first.cells, ["9q9hr"])
        XCTAssertEqual(first.town, "9q9hr")
    }

    /// The index's stored id is loaded when the manifest had nothing at the
    /// town's point, counted only if it loads, and never asked for twice.
    func testTheStoredIdIsLoadedOnlyWhenTheManifestHadNothingAtThePoint() {
        let other = ManifestLoader(["9q9hx"])
        XCTAssertEqual(SmartSearch.loadTownTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "9q9hx",
                                                load: other.load), "9q9hx")
        XCTAssertEqual(other.asked, ["9q9h", "9q9hr", "9q9", "9q9hx"])

        let failing = ManifestLoader([])
        XCTAssertNil(SmartSearch.loadTownTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "9q9hx",
                                              load: failing.load), "a stored id that doesn't load")
        let tried = ManifestLoader([])
        XCTAssertNil(SmartSearch.loadTownTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "9q9hr",
                                              load: tried.load))
        XCTAssertEqual(tried.asked, ["9q9h", "9q9hr", "9q9"], "the stored 9q9hr was tried at the point already")
    }

    // MARK: - A miss widens

    /// The eight beside the town's tile, nearest its point first: 9q9hq (21810
    /// Stevens Creek Boulevard's) 2.5 km from Cupertino's point, 9q9k8 8 km.
    func testAMissWidensToTheEightNearestFirst() {
        let loader = ManifestLoader(bayArea)
        XCTAssertEqual(besideCupertinoLoaded(loader), Set(besideCupertino))
        XCTAssertEqual(loader.asked.filter(bayArea.contains), besideCupertino)
    }

    /// A slow connection spends the window on the likeliest cells: at 4 s a
    /// tile, the three nearest are started inside the 10 s.
    func testASlowConnectionSpendsTheWindowOnTheNearest() {
        let start = Date()
        var spent: TimeInterval = 0
        let tiles = bayArea
        let slow = ManifestLoader(tiles) { id in if tiles.contains(id) { spent += 4 } }
        let loaded = besideCupertinoLoaded(slow, started: start, now: { start.addingTimeInterval(spent) })
        XCTAssertEqual(loaded, Set(besideCupertino.prefix(3)))
    }

    /// No tile beside the town is started once the window is over.
    func testNoNeighbourIsStartedAfterTheWindow() {
        let loader = ManifestLoader(bayArea)
        XCTAssertEqual(besideCupertinoLoaded(loader, started: Date(timeIntervalSinceNow: -(SmartSearch.neighbourWindow + 1))),
                       [])
        XCTAssertEqual(loader.asked, [])
    }

    func testTheNeighbourWindowIsInsideTheStepsBudget() {
        XCTAssertEqual(SmartSearch.neighbourWindow, 10)
        XCTAssertLessThan(SmartSearch.neighbourWindow, TimeInterval(SmartSearch.downloadTimeout.components.seconds),
                          "the neighbours stop being started inside the widening step's budget")
    }

    // MARK: - The whole city

    /// "Search the whole city" loads the town's tile first, then every index
    /// tile, and no tile beside the town until a miss.
    func testTheWholeCityLoadsTheTownsTileFirstAndNoNeighbour() {
        let loader = ManifestLoader(bayArea)
        XCTAssertEqual(SmartSearch.cityTiles(cupertino.tileIds, storedTileId: cupertino.tileId,
                                             lat: cupertino.lat, lng: cupertino.lng, load: loader.load), "9q9hr")
        XCTAssertEqual(loader.asked, ["9q9h", "9q9hr", "9q95", "9q9m"])
    }

    /// On a metered network the whole city fetches nothing, so the town's tile
    /// and the eight beside it are the ones on the phone, and a town tile that
    /// isn't is a tap's to fetch.
    func testOnAMeteredNetworkTheTownsTilesAreTheOnesOnThePhone() {
        let held = SmartSearch.townTilesOnPhone(lat: cupertino.lat, lng: cupertino.lng, storedTileId: cupertino.tileId,
                                                onDisk: ["9q95", "9q9m", "9q9hr", "9q9hq"])
        XCTAssertEqual(held.tile, "9q9hr")
        XCTAssertEqual(held.beside, ["9q9hq"])
        XCTAssertFalse(held.missing)
        let scope = Set(cupertino.tileIds + ["9q9hr"])
        XCTAssertTrue(SmartSearch.inCells(scope, lat: infiniteLoop.lat, lng: infiniteLoop.lng))
        XCTAssertTrue(SmartSearch.inCells(scope, lat: torreAvenue.lat, lng: torreAvenue.lng))
        XCTAssertTrue(SmartSearch.inCells(scope.union(held.beside), lat: stevensCreek.lat, lng: stevensCreek.lng),
                      "on a miss")

        let notHeld = SmartSearch.townTilesOnPhone(lat: cupertino.lat, lng: cupertino.lng,
                                                   storedTileId: cupertino.tileId, onDisk: ["9q95", "9q9m"])
        XCTAssertEqual(notHeld.tile, "9q9hr", "the stored id, in scope though not on the phone")
        XCTAssertEqual(notHeld.beside, [])
        XCTAssertTrue(notHeld.missing, "so the tap has it to fetch")

        let nothing = SmartSearch.townTilesOnPhone(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "",
                                                   onDisk: [])
        XCTAssertNil(nothing.tile)
        XCTAssertFalse(nothing.missing)
    }

    /// A town with no index tiles is still a city, scoped by its own tile; with
    /// neither, the whole city falls back to the area under the map.
    func testATownWithNoIndexTilesIsScopedByItsOwnTile() {
        XCTAssertEqual(SmartSearch.cityCells(tileIds: [], townTile: "9q9hr"), ["9q9hr"])
        XCTAssertEqual(SmartSearch.cityCells(tileIds: cupertino.tileIds, townTile: nil), Set(cupertino.tileIds))
        XCTAssertEqual(SmartSearch.cityCells(tileIds: cupertino.tileIds, townTile: "9q9hr"), ["9q95", "9q9m", "9q9hr"])
        XCTAssertNil(SmartSearch.cityCells(tileIds: [], townTile: nil))
    }

    // MARK: - The rows asked for

    private func row(_ text: String, _ lat: Double, _ lng: Double, confidence: Double) -> GeocodingResult {
        GeocodingResult(text: text, lat: lat, lng: lng, resultType: "poi", confidence: confidence,
                        name: text, city: nil, state: nil, postcode: nil, country: nil, address: nil)
    }

    /// The SDK keeps the most confident rows over every loaded tile before the
    /// town's filter runs (forward_near's last step: sort by confidence, cut to
    /// the limit), so the rows asked for decide whether the town's own match
    /// survives. 40 more confident stores of a chain in a Seattle tile would
    /// cut Cupertino's out of `limit * 3`; not out of `townRows`.
    func testEnoughRowsAreAskedForTheTownsMatchToSurviveTheSDKsCut() {
        func sdkCut(_ rows: [GeocodingResult], _ limit: Int) -> [GeocodingResult] {
            Array(rows.sorted { $0.confidence > $1.confidence }.prefix(limit))
        }
        let elsewhere = (0..<40).map { row("Safeway \($0)", 47.6062, -122.3321, confidence: 1.0) }
        let rows = elsewhere + [row("Safeway", infiniteLoop.lat, infiniteLoop.lng, confidence: 0.9)]
        let cells: Set<String> = ["9q9hr", "9q95", "9q9m"]
        func inTown(_ kept: [GeocodingResult]) -> [GeocodingResult] {
            kept.filter { SmartSearch.inCells(cells, lat: $0.lat, lng: $0.lng) }
        }
        let sheet = 8   // `search`'s default limit
        XCTAssertTrue(inTown(sdkCut(rows, sheet * 3)).isEmpty, "a small multiple of the sheet: the town's match cut")
        XCTAssertEqual(inTown(sdkCut(rows, SmartSearch.townRows)).map(\.text), ["Safeway"])
        XCTAssertEqual(SmartSearch.townRows, 100, "the web client's AREA_ROWS, the Android app's TOWN_ROWS")
    }

    // MARK: - The rules underneath

    /// A scope tile is a prefix of the row's own precision-5 geohash: a split
    /// cell's child, a whole cell, a merged parent. Never an empty id.
    func testTheScopeTestIsAPrefixTest() {
        let loop = infiniteLoop
        XCTAssertEqual(SmartSearch.geohash(lat: loop.lat, lng: loop.lng, precision: 5), "9q9hr")
        XCTAssertTrue(SmartSearch.inCells(["9q9hr"], lat: loop.lat, lng: loop.lng), "a split cell's child")
        XCTAssertTrue(SmartSearch.inCells(["9q9h"], lat: loop.lat, lng: loop.lng), "a whole cell")
        XCTAssertTrue(SmartSearch.inCells(["9q9"], lat: loop.lat, lng: loop.lng), "a merged parent")
        XCTAssertFalse(SmartSearch.inCells(["9q9hq"], lat: loop.lat, lng: loop.lng), "the child beside it")
        XCTAssertFalse(SmartSearch.inCells([""], lat: loop.lat, lng: loop.lng), "an empty id is no tile")
        XCTAssertFalse(SmartSearch.inCells([], lat: loop.lat, lng: loop.lng))
        XCTAssertFalse(["9q9hr"].contains(SmartSearch.geohash4(lat: loop.lat, lng: loop.lng)),
                       "equality with the precision-4 geohash never matched a child")
    }

    /// The town's tile comes from its point through the manifest, so a split or
    /// a rebuild since the index was made is followed; the index's stored id
    /// only when the manifest has nothing there.
    func testTheTownsTileComesThroughTheManifestElseTheStoredId() {
        XCTAssertEqual(SmartSearch.townTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "9q9h",
                                            has: bayArea.contains), "9q9hr", "a split since the index was made")
        XCTAssertEqual(SmartSearch.townTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "9q9hr",
                                            has: { _ in false }), "9q9hr", "nothing in the manifest there")
        XCTAssertNil(SmartSearch.townTile(lat: cupertino.lat, lng: cupertino.lng, storedTileId: "",
                                          has: { _ in false }))
        XCTAssertEqual(SmartSearch.manifestTile(lat: 37.62354, lng: -120.75326, has: { $0 == "9qd" }), "9qd",
                       "a merged region's parent")
    }

    /// A neighbour is resolved from its centre: one in a cell held whole gives
    /// that cell, never a child id the manifest doesn't have.
    func testANeighbourInAWholeCellGivesThatCell() {
        let partly = manifest(split: ["9q9h"], whole: ["9q9k", "9q95", "9q9m", "9q97", "9q9j", "9q9e", "9q9s"])
        let beside = SmartSearch.neighbourTiles(of: "9q9hr", nearLat: cupertino.lat, nearLng: cupertino.lng,
                                                has: partly.contains)
        XCTAssertTrue(beside.contains("9q9k"), "\(beside)")
        XCTAssertFalse(beside.contains { $0.hasPrefix("9q9k") && $0.count == 5 }, "\(beside)")
        XCTAssertEqual(beside.filter { $0 == "9q9k" }.count, 1, "each once")
        XCTAssertEqual(Set(beside.filter { $0.hasPrefix("9q9h") }), ["9q9hx", "9q9hp", "9q9hn", "9q9hq", "9q9hw"])
    }

    func testTheGeohashCellsBox() {
        guard let box = SmartSearch.geohashBox("9q9hr") else { return XCTFail("no box for 9q9hr") }
        XCTAssertEqual(SmartSearch.geohash(lat: box.centreLat, lng: box.centreLng, precision: 5), "9q9hr")
        XCTAssertEqual(box.height, 180.0 / 4096, accuracy: 1e-12)
        XCTAssertEqual(box.width, 360.0 / 8192, accuracy: 1e-12)
        XCTAssertNil(SmartSearch.geohashBox("9q9ha"), "'a' is not in the alphabet")
        XCTAssertEqual(SmartSearch.geohash4(lat: 37.331684, lng: -122.030372), "9q9h")
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The scoped path keeps its rows to `scopedCells` by the prefix test, and
    /// widens only on a miss, in a step of its own, searching again.
    func testTheScopedPathWidensOnlyOnAMiss() throws {
        let search = try source("App/Services/SmartSearch.swift")
        XCTAssertTrue(search.contains("""
                        var hits = await forward(address, limit: Self.townRows, focusLat: city.lat, focusLng: city.lng)
                        var inScope = loaded.cells.map { cells in
                            hits.filter { Self.inCells(cells, lat: $0.lat, lng: $0.lng) }
                        } ?? hits
            """))
        XCTAssertTrue(search.contains("""
                        if inScope.isEmpty, let cells = loaded.cells, let town = loaded.town {
                            let geocoder = self.geocoder
                            let widening = Widening(tile: town, lat: city.lat, lng: city.lng)
                            let widened = await withTimeout {
                                await self.offMain { Self.loadNeighbours(of: widening, geocoder: geocoder) }
                            }
                            if Task.isCancelled { return .empty }
                            guard let around = widened else {
                                onProgress?(nil)
                                return Result(addresses: [], cities: [], scopedTo: scope, timedOut: true)
                            }
                            if !around.isEmpty {
                                let wider = cells.union(around)
                                hits = await forward(address, limit: Self.townRows, focusLat: city.lat, focusLng: city.lng)
                                inScope = hits.filter { Self.inCells(wider, lat: $0.lat, lng: $0.lng) }
                            }
                        }
            """))
        XCTAssertTrue(search.contains("""
                    if let first = Self.scopedCells(shardTiles: shardTiles, tileIds: tileIds, storedTileId: storedTileId,
                                                    lat: lat, lng: lng, load: { Self.loadTile($0, geocoder: geocoder) }) {
                        return LoadedTiles(cells: first.cells, town: first.town)
                    }
            """))
        XCTAssertTrue(search.contains("""
                    let shardTiles: (() -> [String])? = hasShard && !term.isEmpty
                        ? { geocoder.lookupCityShardTiles(geonameId: geonameId, term: term) }
                        : nil
            """))
        XCTAssertTrue(search.contains("        let storedTileId = city.tileId\n"))
        XCTAssertTrue(search.contains("hasShard: hasShard, tileIds: tileIds, storedTileId: storedTileId,\n"))
        XCTAssertTrue(search.contains("""
                    loadNeighbourTiles(of: widening.tile, nearLat: widening.lat, nearLng: widening.lng,
                                       load: { Self.loadTile($0, geocoder: geocoder) }, started: Date())
            """), "the window starts with the widening step")
    }

    /// A typed city is a request on any network (step 3 downloads it on cellular
    /// too), and so are its town's tile and, on a miss, the eight beside it:
    /// 21810 Stevens Creek Boulevard is found on cellular. Nothing in the comma
    /// path asks what network it is on.
    func testTheCommaPathDownloadsOnAnyNetworkTheWideningToo() throws {
        let search = try source("App/Services/SmartSearch.swift")
        let start = try XCTUnwrap(search.range(of: "        for candidate in Self.buildCandidates(q) {\n"))
        let end = try XCTUnwrap(search.range(of: "            if triedScope == nil { triedScope = scope }\n",
                                             range: start.upperBound..<search.endIndex))
        let loop = search[start.upperBound..<end.lowerBound]
        XCTAssertTrue(loop.contains("await self.offMain { Self.loadNeighbours(of: widening, geocoder: geocoder) }"),
                      "the widening is the comma path's")
        XCTAssertFalse(loop.contains("isUnmetered"), "no metered gate")
        XCTAssertFalse(loop.contains("mayDownload"), "no metered gate")
    }

    /// The whole city keeps its rows to the index's tiles and the town's, loaded
    /// when it may download, else the ones on the phone (a missing town tile is
    /// the tap's), and widens only on a miss: loading and searching again, or on
    /// a metered network to the tiles on the phone.
    func testTheWholeCityWidensOnlyOnAMiss() throws {
        let search = try source("App/Services/SmartSearch.swift")
        XCTAssertTrue(search.contains("""
                            let town = (lat: top.lat, lng: top.lng, storedTileId: top.tileId)
                            if mayDownload {
                                onProgress?(.loadingTiles(resolved))
                                let loaded = await withTimeout {
                                    await self.offMain { Self.loadEveryTile(tileIds, town: town, geocoder: geocoder) }
                                }
                                if Task.isCancelled { return .empty }
                                guard let townTile = loaded else {
                                    onProgress?(nil)
                                    return Result(addresses: [], cities: [], scopedTo: resolved, timedOut: true)
                                }
                                if let cells = Self.cityCells(tileIds: tileIds, townTile: townTile) {
                                    scope = resolved
                                    scopeTiles = cells
                                    widening = townTile.map { Widening(tile: $0, lat: town.lat, lng: town.lng) }
                                }
                            } else {
                                let onPhone = Self.townTilesOnPhone(lat: town.lat, lng: town.lng,
                                                                    storedTileId: town.storedTileId, onDisk: onDisk)
                                if let cells = Self.cityCells(tileIds: tileIds, townTile: onPhone.tile) {
                                    scope = resolved
                                    scopeTiles = cells
                                    widening = onPhone.tile.map {
                                        Widening(tile: $0, lat: town.lat, lng: town.lng, onPhone: onPhone.beside)
                                    }
                                }
                                moreToDownload = !Self.missingCells(tileIds, onDisk: onDisk).isEmpty || onPhone.missing
                            }
            """))
        XCTAssertTrue(search.contains("""
                        let top = await offMain { cityIndex.search(query: cityName, limit: 3).first }
                        if Task.isCancelled { return .empty }
                        if let top {
                            let resolved = Scope(city: top.name, admin1: top.admin1,
                                                 countryCode: top.countryCode)
                            let tileIds = top.tileIds
            """), "a town with no index tiles is still a city")
        XCTAssertTrue(search.contains(
            "        var hits = await forward(local, limit: Self.townRows, focusLat: focusLat, focusLng: focusLng)\n"))
        XCTAssertTrue(search.contains("""
                    var inScope = scopeTiles.map { tiles in
                        hits.filter { Self.inCells(tiles, lat: $0.lat, lng: $0.lng) }
                    } ?? hits
            """))
        XCTAssertTrue(search.contains("""
                    if inScope.isEmpty, let tiles = scopeTiles, let widening {
                        var around = widening.onPhone ?? []
                        if widening.onPhone == nil {
                            let widened = await withTimeout {
                                await self.offMain { Self.loadNeighbours(of: widening, geocoder: geocoder) }
                            }
                            if Task.isCancelled { return .empty }
                            guard let loaded = widened else {
                                onProgress?(nil)
                                return Result(addresses: [], cities: [], scopedTo: scope, timedOut: true)
                            }
                            around = loaded
                            if !around.isEmpty {
                                hits = await forward(local, limit: Self.townRows, focusLat: focusLat, focusLng: focusLng)
                            }
                        }
                        let wider = tiles.union(around)
                        inScope = hits.filter { Self.inCells(wider, lat: $0.lat, lng: $0.lng) }
                    }
            """))
        XCTAssertTrue(search.contains("""
                    cityTiles(tileIds, storedTileId: town.storedTileId, lat: town.lat, lng: town.lng,
                              load: { Self.loadTile($0, geocoder: geocoder) })
            """))
    }
}

/// Loads from a manifest as the SDK does (an id it doesn't have is a soft miss)
/// and keeps every id it was asked for, in order. `onLoad` runs for each.
private final class ManifestLoader {
    let manifest: Set<String>
    private let onLoad: (String) -> Void
    private(set) var asked: [String] = []

    init(_ manifest: Set<String>, onLoad: @escaping (String) -> Void = { _ in }) {
        self.manifest = manifest
        self.onLoad = onLoad
    }

    func load(_ id: String) -> Bool {
        asked.append(id)
        onLoad(id)
        return manifest.contains(id)
    }
}
