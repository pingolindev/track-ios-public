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

/// "Search beyond the map view" calls the SDK off the main actor, within a time
/// limit. The reverse lookup, the city index and a loop over the city's whole
/// tile set are synchronous and download what is missing, so on the main actor,
/// in a city whose tiles are not on the phone, the app could not draw until the
/// last tile arrived. The budget must bound the wait too: racing the download
/// inside a task group does not, since a task group returns only after every
/// child has ended.
final class CityWideSearchOffMainTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// cityWideSearch's body, signature to the next declaration.
    private func cityWideBody() throws -> [Substring] {
        let text = try source("App/Services/SmartSearch.swift")
        let start = try XCTUnwrap(text.range(of: "private func cityWideSearch("), "cityWideSearch is gone")
        let rest = text[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "private nonisolated static func loadEveryTile("),
                                "the blocking helpers moved: re-point this test")
        return rest[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// Blocks the thread it runs on, like an SDK download: no cancellation reaches it.
    private static func blockingWork(seconds: Double, answer: Int) async -> Int {
        await Task.detached {
            Thread.sleep(forTimeInterval: seconds)
            return answer
        }.value
    }

    // MARK: - The budget

    /// The budget: a blocking download that outlives it is left behind at
    /// the budget, rather than the race returning only when the download
    /// does.
    func testABlockingDownloadIsLeftBehindAtTheBudget() async {
        let started = Date()
        let answer = await SmartSearch.race(.milliseconds(100)) {
            await Self.blockingWork(seconds: 3, answer: 1)
        }
        let waited = Date().timeIntervalSince(started)
        XCTAssertNil(answer, "the budget ran out first: nil, never 'found nothing'")
        XCTAssertLessThan(waited, 1.5, "waited \(waited) s for a 0.1 s budget: the race waited for the download")
    }

    func testWorkThatFinishesInTimeAnswers() async {
        let answer = await SmartSearch.race(.seconds(10)) { 7 }
        XCTAssertEqual(answer, 7)
        let slower = await SmartSearch.race(.seconds(10)) {
            await Self.blockingWork(seconds: 0.2, answer: 8)
        }
        XCTAssertEqual(slower, 8, "a download that lands inside the budget is the answer")
    }

    /// A search a newer query replaced does not sit out the budget, or the download.
    func testACancelledCallerGetsNilAtOnce() async {
        let started = Date()
        let search = Task {
            await SmartSearch.race(.seconds(20)) { await Self.blockingWork(seconds: 3, answer: 1) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        search.cancel()
        let answer = await search.value
        let waited = Date().timeIntervalSince(started)
        XCTAssertNil(answer)
        XCTAssertLessThan(waited, 1.5, "waited \(waited) s after a cancel")
    }

    func testAnAnswerBeforeTheWaiterIsKept() async {
        let first = FirstAnswer<Int>()
        first.answer(3)
        first.answer(4)
        let value = await withCheckedContinuation { first.wait($0) }
        XCTAssertEqual(value, 3, "the first answer, kept for a waiter that came later; the second dropped")
    }

    // MARK: - Off the main actor

    /// Every SDK call in the city-wide path is inside an `offMain` closure on
    /// its own line: the reverse lookup, the city index and both tile loaders.
    func testTheCityWidePathCallsTheSdkOnlyOffTheMainActor() throws {
        let body = try cityWideBody()
        let sdkCall = try NSRegularExpression(pattern: #"\b(geocoder|cityIndex)\.[a-zA-Z]+\("#)
        var calls = 0
        for line in body {
            let text = String(line)
            guard sdkCall.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
            calls += 1
            XCTAssertTrue(text.contains("offMain {"), "an SDK call on the main actor: \(text)")
        }
        XCTAssertGreaterThanOrEqual(calls, 2, "the reverse lookup and the city index are called here")

        for helper in ["Self.loadEveryTile(", "Self.loadCellAndNeighbours("] {
            let index = try XCTUnwrap(body.firstIndex { $0.contains(helper) }, "\(helper) is not called")
            XCTAssertTrue(body[index].contains("offMain {"), "\(helper) runs on the main actor")
            XCTAssertTrue(body[index - 1].contains("withTimeout {"), "\(helper) runs without a budget")
        }
    }

    /// The loaders block, so they must not be able to reach main-actor state.
    func testTheTileLoadersAreNonisolated() throws {
        let text = try source("App/Services/SmartSearch.swift")
        XCTAssertTrue(text.contains("private nonisolated static func loadEveryTile("))
        XCTAssertTrue(text.contains("private nonisolated static func loadCellAndNeighbours("))
    }

    /// A replaced search stops after each step instead of loading a city nobody reads.
    func testTheCityWidePathStopsWhenReplaced() throws {
        let checks = try cityWideBody().filter { $0.contains("if Task.isCancelled { return .empty }") }
        XCTAssertGreaterThanOrEqual(checks.count, 3, "after the lookup, the index and each tile load")
    }
}
