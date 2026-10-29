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

/// Search automatically after a short pause, like other apps, without
/// spending a server credit per keystroke. Half a second after the last
/// keystroke, from three characters, never the same query twice in a row, one
/// gateway ask per query however many searches want it, and a search the next
/// keystroke replaces does not lose the answer it paid for.
@MainActor
final class PlaceSearchScheduleTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("placesearch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        try super.tearDownWithError()
    }

    /// A search whose gateway is a fake that records what it was asked.
    private func makeSearch(_ asked: @escaping (String) -> Void) -> SmartSearch {
        let smart = SmartSearch(geocoder: TileGeocoder(storagePath: dir.path), storagePath: dir.path)
        smart.serverAllowed = { true }
        smart.askServer = { text, _, _, _ in
            asked(text)
            return ServerGeocoder.ServedPlaces(rows: [], ordered: false)
        }
        return smart
    }

    private var pauseMs: Int {
        let parts = SearchSchedule.pause.components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Plays keystrokes at their times (ms). A pause that runs out before the next
    /// keystroke, or after the last one, settles its query, and each settled query
    /// is searched against the gateway as the sheet would. Returns what settled.
    private func play(_ keystrokes: [(ms: Int, text: String)], on smart: SmartSearch) async -> [String] {
        var schedule = SearchSchedule()
        var due: Int?
        var settled: [String] = []
        func settle() async {
            guard let text = schedule.settle() else { return }
            settled.append(text)
            _ = await smart.serverForward(text, limit: 8, focusLat: 37.639, focusLng: -120.997)
        }
        for (ms, text) in keystrokes {
            if let pending = due, pending <= ms {
                due = nil
                await settle()
            }
            switch schedule.typed(text) {
            case .wait: due = ms + pauseMs
            case .clear, .cancelWait: due = nil
            case .unchanged: break
            }
        }
        if due != nil { await settle() }
        return settled
    }

    // MARK: - The rule, one step at a time

    func testThePauseIsHalfASecondFromThreeCharacters() {
        XCTAssertEqual(SearchSchedule.pause, .milliseconds(500))
        XCTAssertEqual(SearchSchedule.minLength, 3)
        XCTAssertGreaterThanOrEqual(SearchSchedule.minLength, SmartSearch.minServerQueryLength,
                                    "nothing shorter than the server's minimum is ever settled")
    }

    func testTooShortSearchesNothing() {
        var schedule = SearchSchedule()
        for text in ["", "p", "pi", "  pi  ", " Pi\t"] {
            XCTAssertEqual(schedule.typed(text), .clear, "'\(text)'")
            XCTAssertNil(schedule.settle(), "'\(text)' must not settle")
        }
        XCTAssertFalse(SearchSchedule.isSearchable("pi"))
        XCTAssertTrue(SearchSchedule.isSearchable("pin"))
    }

    func testANewQueryWaitsAndTheSameOneDoesNotRestartThePause() {
        var schedule = SearchSchedule()
        XCTAssertEqual(schedule.typed("pin"), .wait)
        XCTAssertEqual(schedule.typed("pink"), .wait, "a different query starts the pause again")
        XCTAssertEqual(schedule.typed("pink "), .unchanged, "a space is the same query: its pause runs on")
        XCTAssertEqual(schedule.typed("PINK"), .unchanged, "so is a capital")
        XCTAssertEqual(schedule.settle(), "PINK", "what is searched is what was typed last, trimmed")
        XCTAssertNil(schedule.settle(), "one settle per pause")
    }

    func testBackToTheQuerySearchedLastSearchesNothing() {
        var schedule = SearchSchedule()
        _ = schedule.typed("pizza")
        XCTAssertEqual(schedule.settle(), "pizza")
        XCTAssertEqual(schedule.typed("pizza "), .cancelWait, "the answer on screen is for this query")
        XCTAssertEqual(schedule.typed("pizzas"), .wait)
        XCTAssertEqual(schedule.typed("pizza"), .cancelWait, "back before the pause ran out")
        XCTAssertNil(schedule.settle(), "nothing waits")
        XCTAssertEqual(schedule.typed(""), .clear)
        XCTAssertEqual(schedule.typed("pizza"), .wait, "after a clear the same query is new again")
    }

    // MARK: - A typing session

    /// THE RULE, END TO END. Someone types "pinks hot dogs" with pauses
    /// mid-word, adds and removes a space, fixes a typo, clears, and comes back
    /// to two queries they already asked, one pasted with a double space. Four
    /// queries settle; the gateway is asked twice.
    func testOneGatewayAskPerQueryInATypingSession() async {
        var asks: [String] = []
        let smart = makeSearch { asks.append($0) }
        let settled = await play([
            (0, "p"), (180, "pi"), (360, "pin"), (700, "pink"),
            (1500, "pinks"), (1650, "pinks "), (1800, "pinks h"), (1950, "pinks ho"), (2100, "pinks hot"),
            (2250, "pinks hot "), (2400, "pinks hot d"), (2550, "pinks hot do"), (2700, "pinks hot dog"),
            (2850, "pinks hot dogs"),
            (4000, "pinks hot dogs "), (4200, "pinks hot dog"), (4350, "pinks hot dogs"), (5000, "Pinks Hot Dogs"),
            (7000, ""), (7200, "pin"), (7400, "pink"),
            (9000, ""), (9500, "pinks  hot dogs"),
        ], on: smart)

        XCTAssertEqual(settled, ["pink", "pinks hot dogs", "pink", "pinks  hot dogs"],
                       "a query settles only after half a second without a keystroke, and never twice in a row")
        XCTAssertEqual(asks, ["pink", "pinks hot dogs"],
                       "the two that came back are answered from the cache, the double space included")
    }

    // MARK: - One ask per query, however many searches want it

    func testTwoSearchesForOneQueryShareOneAsk() async {
        let gate = SearchGate()
        var asks = 0
        let smart = SmartSearch(geocoder: TileGeocoder(storagePath: dir.path), storagePath: dir.path)
        smart.serverAllowed = { true }
        smart.askServer = { _, _, _, _ in
            asks += 1
            await gate.wait()
            return ServerGeocoder.ServedPlaces(rows: [], ordered: false)
        }
        async let first = smart.serverForward("pinks hot dogs", limit: 8, focusLat: 37.639, focusLng: -120.997)
        async let second = smart.serverForward("Pinks  Hot Dogs", limit: 8, focusLat: 37.639, focusLng: -120.997)
        await gate.somethingWaits()
        // Let the second search reach the gateway step while the first is on the wire.
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        let answers = await [first, second]
        XCTAssertEqual(asks, 1, "the second search waited for the first one's ask")
        XCTAssertEqual(answers.compactMap { $0 }.count, 2, "and both got the answer")
    }

    /// A search the next keystroke replaces is cancelled. The ask it started is
    /// not: the answer is paid for, so it is cached for whoever asks next. The
    /// fake ends like a real request whose task was cancelled (nil), so if the
    /// cancellation reached it, the answer would be lost and asked for again.
    func testAReplacedSearchStillCachesTheAnswerItPaidFor() async {
        let gate = SearchGate()
        var asks = 0
        let smart = SmartSearch(geocoder: TileGeocoder(storagePath: dir.path), storagePath: dir.path)
        smart.serverAllowed = { true }
        smart.askServer = { _, _, _, _ in
            asks += 1
            await gate.wait()
            return Task.isCancelled ? nil : ServerGeocoder.ServedPlaces(rows: [], ordered: false)
        }
        let replaced = Task {
            await smart.serverForward("pinks hot dogs", limit: 8, focusLat: 37.639, focusLng: -120.997)
        }
        await gate.somethingWaits()
        replaced.cancel()
        await gate.open()
        _ = await replaced.value
        let again = await smart.serverForward("pinks hot dogs", limit: 8, focusLat: 37.639, focusLng: -120.997)
        XCTAssertNotNil(again)
        XCTAssertEqual(asks, 1, "the answer the replaced search paid for was cached")
    }

    func testAShortQueryNeverReachesTheGateway() async {
        var asks: [String] = []
        let smart = makeSearch { asks.append($0) }
        let answer = await smart.serverForward("ab", limit: 8, focusLat: nil, focusLng: nil)
        XCTAssertNil(answer)
        XCTAssertEqual(asks, [])
    }

    func testTheCacheKeyIsTheNormalisedQuery() {
        XCTAssertEqual(SmartSearch.normalised("  Pinks   Hot\tDogs "), "pinks hot dogs")
        XCTAssertEqual(
            SmartSearch.searchCacheKey(query: "Pinks  Hot Dogs ", limit: 8, focusLat: 1, focusLng: 2),
            SmartSearch.searchCacheKey(query: "pinks hot dogs", limit: 8, focusLat: 1, focusLng: 2))
    }

    // MARK: - The row and the empty list

    func testTheMoreDataRowIsOfferedOnlyWhenTilesWereLeftBehind() {
        typealias V = AddressSearchView
        XCTAssertTrue(V.offersMoreData(moreToDownload: true, isSearching: false, query: "pizza"))
        XCTAssertFalse(V.offersMoreData(moreToDownload: false, isSearching: false, query: "pizza"),
                       "an unmetered network fetched the city by itself: nothing to offer")
        XCTAssertFalse(V.offersMoreData(moreToDownload: true, isSearching: true, query: "pizza"),
                       "not while a search runs")
        XCTAssertFalse(V.offersMoreData(moreToDownload: true, isSearching: false, query: "pi"))
    }

    func testTheEmptyListAlwaysSaysSomething() {
        typealias V = AddressSearchView
        let austin = SmartSearch.Scope(city: "Austin", admin1: "TX", countryCode: "US")
        XCTAssertEqual(V.emptyText(timedOut: false, scopedTo: nil, moreToDownload: false), "No places found")
        XCTAssertEqual(V.emptyText(timedOut: false, scopedTo: .nearbyArea, moreToDownload: false), "No places found",
                       "the area under the map is not a place the query named")
        XCTAssertEqual(V.emptyText(timedOut: false, scopedTo: nil, moreToDownload: true), "No places found yet",
                       "metered: the rest of the city is one tap away")
        XCTAssertEqual(V.emptyText(timedOut: false, scopedTo: austin, moreToDownload: false),
                       "Couldn't find that address in Austin, TX. Try a different street or pick a spot on the map.")
        XCTAssertEqual(V.emptyText(timedOut: true, scopedTo: austin, moreToDownload: false),
                       "Couldn't download map data for Austin, TX.",
                       "the app retries by itself: the person is asked to do nothing")
        XCTAssertEqual(V.emptyText(timedOut: true, scopedTo: nil, moreToDownload: true),
                       "Couldn't download map data.")
    }

    func testTheSheetShowsTheRowUnderTheEmptyListAndAboveRows() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Views/Map/AddressSearchView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("Text(\"Search beyond the map view (uses more data) →\")"))
        XCTAssertTrue(text.contains("Text(Self.emptyText(timedOut: search.timedOut, scopedTo: search.scopedTo,"),
                      "the empty list says what emptyText says")
        XCTAssertEqual(text.components(separatedBy: "moreDataRow\n").count - 1, 2,
                       "the row, above the rows and under the empty list")
        XCTAssertFalse(text.contains("No matches"), "no other empty-state copy")
        XCTAssertFalse(text.lowercased().contains("try again"), "nothing asks the person to retry")
        XCTAssertTrue(text.contains("TextField(\"Address, place or city\", text: $query)"),
                      "the map search's placeholder says place, not POI")
        XCTAssertTrue(text.contains("                    search.watchNetwork()\n"
                                    + "                }\n"
                                    + "                .onDisappear { search.stopWatchingNetwork() }"),
                      "the sheet watches the network while it is up")
    }
}
