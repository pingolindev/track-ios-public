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

/// The records read asks the server and trusts it with nothing. A reply
/// that doesn't hold together is no answer, never part of a chain.
final class RefreshRecordsReaderTests: XCTestCase {
    private let a = "a1a1a1a1-0000-4000-8000-000000000001"
    private let b = "b2b2b2b2-0000-4000-8000-000000000002"
    private let user = "c3c3c3c3-0000-4000-8000-000000000003"

    private func record(_ version: Int, bytes: Int = 200) -> ServedRefreshRecord {
        ServedRefreshRecord(version: version, record: String(repeating: "ab", count: bytes),
                            signature: String(repeating: "cd", count: 64))
    }

    private func head(_ userId: String) -> ServedCircleHead {
        ServedCircleHead(userId: userId, head: String(repeating: "01", count: 69), signature: String(repeating: "02", count: 64))
    }

    private func circle(_ id: String, _ records: [ServedRefreshRecord], heads: [ServedCircleHead] = [],
                        complete: Bool = true) -> CircleRefreshRecords {
        CircleRefreshRecords(circleId: id, records: records, heads: heads, complete: complete)
    }

    /// Serves `pages` in turn and keeps each `since` it was asked with.
    private final class Server {
        var pages: [RefreshRecordsPage]
        var asked: [[String: Int32]] = []
        init(_ pages: [RefreshRecordsPage]) { self.pages = pages }
        func page(_ since: [String: Int32]) throws -> RefreshRecordsPage {
            asked.append(since)
            guard !pages.isEmpty else { throw URLError(.timedOut) }
            return pages.removeFirst()
        }
    }

    private func read(_ server: Server, since: [String: Int32] = [:]) async -> [RefreshRecordsReader.Circle]? {
        await RefreshRecordsReader.read(since: since) { try server.page($0) }
    }

    func testOnePageEveryCircleWithItsHeads() async {
        let server = Server([RefreshRecordsPage(circles: [circle(a, [record(3), record(4)], heads: [head(user.uppercased())]),
                                                        circle(b, [])], more: false)])
        let got = await read(server, since: [a.uppercased(): 2])
        XCTAssertEqual(got?.map(\.circleId), [a, b])
        XCTAssertEqual(got?.first?.records.map(\.version), [3, 4])
        XCTAssertEqual(got?.first?.heads.map(\.userId), [user], "user ids lowercased")
        XCTAssertEqual(server.asked, [[a: 2]], "since sent lowercased")
    }

    /// Paged: the same map continues it, each circle raised to its last record;
    /// heads come with a circle's last page only.
    func testPagesFollowOnFromTheLastRecordServed() async {
        let server = Server([
            RefreshRecordsPage(circles: [circle(a, [record(1), record(2)], complete: false)], more: true),
            RefreshRecordsPage(circles: [circle(a, [record(3)], heads: [head(user)])], more: false),
        ])
        let got = await read(server)
        XCTAssertEqual(got?.first?.records.map(\.version), [1, 2, 3])
        XCTAssertEqual(got?.first?.heads.count, 1)
        XCTAssertEqual(server.asked, [[:], [a: 2]])
    }

    /// Anything that doesn't hold together is no answer.
    func testAReplyThatDoesntHoldTogetherIsNoAnswer() async {
        let broken: [String: [RefreshRecordsPage]] = [
            "at or below since": [RefreshRecordsPage(circles: [circle(a, [record(2)])], more: false)],
            "out of order": [RefreshRecordsPage(circles: [circle(a, [record(4), record(3)])], more: false)],
            "twice": [RefreshRecordsPage(circles: [circle(a, [record(3), record(3)])], more: false)],
            "past the highest version": [RefreshRecordsPage(circles: [circle(a, [record(1_000_001)])], more: false)],
            "too short": [RefreshRecordsPage(circles: [circle(a, [record(3, bytes: 134)])], more: false)],
            "too long": [RefreshRecordsPage(circles: [circle(a, [record(3, bytes: 103 + 66 * 200 + 65)])], more: false)],
            "not hex": [RefreshRecordsPage(circles: [circle(a, [ServedRefreshRecord(
                version: 3, record: String(repeating: "zz", count: 200), signature: String(repeating: "cd", count: 64))])],
                more: false)],
            "a short signature": [RefreshRecordsPage(circles: [circle(a, [ServedRefreshRecord(
                version: 3, record: String(repeating: "ab", count: 200), signature: String(repeating: "cd", count: 63))])],
                more: false)],
            "a bad head": [RefreshRecordsPage(circles: [circle(a, [], heads: [ServedCircleHead(
                userId: user, head: String(repeating: "01", count: 68), signature: String(repeating: "02", count: 64))])],
                more: false)],
            "heads before the last page": [RefreshRecordsPage(circles: [circle(a, [record(3)], heads: [head(user)],
                                                                               complete: false)], more: true),
                                           RefreshRecordsPage(circles: [circle(a, [record(4)], heads: [head(user)])],
                                                              more: false)],
            "a circle not complete at the end": [RefreshRecordsPage(circles: [circle(a, [record(3)], complete: false)],
                                                                    more: false)],
            "more without moving on": [RefreshRecordsPage(circles: [circle(a, [], complete: false)], more: true)],
            "not a circle id": [RefreshRecordsPage(circles: [circle("not-a-uuid", [])], more: false)],
            "no answer": [],
        ]
        for (name, pages) in broken {
            let got = await read(Server(pages), since: [a: 2])
            XCTAssertNil(got, name)
        }
    }

    /// A page that says `more` but moves nothing on ends the read at once: a
    /// loop, never followed to the page cap.
    func testMoreWithoutMovingOnEndsAtOnce() async {
        let stuck = RefreshRecordsPage(circles: [circle(a, [], complete: false)], more: true)
        let server = Server(Array(repeating: stuck, count: RefreshRecordsReader.maxPages))
        let got = await read(server, since: [a: 2])
        XCTAssertNil(got)
        XCTAssertEqual(server.asked.count, 1)
    }

    /// Never more than the page cap: a server that keeps promising more ends.
    func testAReadThatNeverEndsIsNoAnswer() async {
        let pages = (1...RefreshRecordsReader.maxPages + 1).map {
            RefreshRecordsPage(circles: [circle(a, [record($0)], complete: false)], more: true)
        }
        let server = Server(pages)
        let got = await read(server)
        XCTAssertNil(got)
        XCTAssertEqual(server.asked.count, RefreshRecordsReader.maxPages)
    }
}
