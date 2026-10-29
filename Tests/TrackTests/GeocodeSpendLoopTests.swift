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

/// Pins `GeocodeTokenManager.runSpendLoop`: what happens to the anonymous
/// credits, and how many requests leave the phone, for each reply the backend
/// can give to a redemption.
///
/// WHY THIS IS WORTH TESTING
///   In Swift a `break` inside a `switch` leaves the `switch`, not the loop. A
///   loop that kept going there would look fine: a search the geocoder could
///   not answer still falls back to the tiles in the end — just after
///   presenting the same credit again and then burning a second one, each
///   against a 10 s upstream timeout. The only visible symptom is "search is
///   slow when the server is", which is exactly when nobody suspects the
///   client.
final class GeocodeSpendLoopTests: XCTestCase {

    private let answer = Data("{\"features\":[]}".utf8)

    /// A scripted backend: replies in order, and records what it was sent.
    private final class Backend {
        var replies: [Result<Int, Error>]
        var sent: [Int] = []
        init(_ replies: [Result<Int, Error>]) { self.replies = replies }
        func send(_ credit: Int, body: Data) throws -> (data: Data, status: Int) {
            sent.append(credit)
            switch replies.isEmpty ? .success(500) : replies.removeFirst() {
            case .success(let status): return (body, status)
            case .failure(let error): throw error
            }
        }
    }

    private func run(_ pool: inout [Int], _ backend: Backend, maxAttempts: Int = 4)
        async -> GeocodeTokenManager.SpendLoopResult {
        let body = answer
        return await GeocodeTokenManager.runSpendLoop(pool: &pool, maxAttempts: maxAttempts) { credit in
            try backend.send(credit, body: body)
        }
    }

    // MARK: - An unanswered redemption

    /// The geocoder could not answer (502): ONE request, and the caller is told
    /// to fall back.
    ///
    /// The credit is DROPPED, although the server gives back a credit the
    /// geocoder did not answer: the server saw it, and a credit presented again
    /// goes out with the next query, which lets the gateway link the two.
    func testAnUnansweredRedemptionStopsAfterOneRequestAndDropsTheCredit() async {
        for status in [502, 503, 500, 504, 429, 400, 403, 404] {
            var pool = [1, 2, 3]
            let backend = Backend(Array(repeating: .success(status), count: 8))
            let out = await run(&pool, backend)

            XCTAssertEqual(backend.sent, [3], "HTTP \(status): exactly one request, with the last credit")
            XCTAssertEqual(pool, [1, 2], "HTTP \(status): the server saw it, so it is never presented again")
            XCTAssertNil(out.data, "HTTP \(status): nil tells the caller to use the tiles")
            XCTAssertEqual(out.attempts, 1)
            XCTAssertFalse(out.keyRotated)
        }
    }

    // MARK: - the rest of the rule

    func testAnAnswerConsumesExactlyOneCredit() async {
        var pool = [1, 2, 3]
        let backend = Backend([.success(200)])
        let out = await run(&pool, backend)

        XCTAssertEqual(out.data, answer)
        XCTAssertEqual(pool, [1, 2], "single-use: the credit that was answered is gone")
        XCTAssertEqual(backend.sent, [3])
    }

    func testACreditTheServerHasAsSpentIsDroppedAndTheNextOneIsTried() async {
        var pool = [1, 2, 3]
        let backend = Backend([.success(409), .success(409), .success(200)])
        let out = await run(&pool, backend)

        XCTAssertEqual(backend.sent, [3, 2, 1], "each 409 moves on to the next credit")
        XCTAssertEqual(pool, [], "two dropped as spent, one consumed")
        XCTAssertEqual(out.data, answer)
        XCTAssertEqual(out.attempts, 3)
    }

    func testSpentCreditsAreOnlyChasedUpToTheAttemptLimit() async {
        var pool = [1, 2, 3, 4, 5, 6]
        let backend = Backend(Array(repeating: .success(409), count: 10))
        let out = await run(&pool, backend, maxAttempts: 4)

        XCTAssertEqual(backend.sent, [6, 5, 4, 3])
        XCTAssertEqual(pool, [1, 2], "four dropped, the rest untouched")
        XCTAssertNil(out.data)
        XCTAssertEqual(out.attempts, 4)
    }

    func testARejectedKeyStopsAtOnceAndIsReported() async {
        var pool = [1, 2, 3]
        let backend = Backend([.success(401), .success(200)])
        let out = await run(&pool, backend)

        XCTAssertTrue(out.keyRotated, "the caller must wipe the pin and the pool")
        XCTAssertNil(out.data)
        XCTAssertEqual(backend.sent, [3], "nothing more is sent under a key the server rejected")
        XCTAssertEqual(pool, [1, 2], "a 401 is a reply like any other: its credit is consumed")
    }

    /// Offline, no DNS answer, no connection to the host, cellular data or
    /// roaming refused by the system, a body never built: the request never
    /// left, so nobody saw the credit and it is kept.
    func testARequestThatNeverLeftKeepsTheCredit() async {
        for code in [URLError.Code.notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                     .dataNotAllowed, .internationalRoamingOff] {
            var pool = [1, 2, 3]
            let backend = Backend([.failure(URLError(code)), .success(200)])
            let out = await run(&pool, backend)

            XCTAssertEqual(backend.sent, [3], "\(code.rawValue): one try, then the tiles")
            XCTAssertEqual(pool, [1, 2, 3], "\(code.rawValue): never sent, so kept")
            XCTAssertNil(out.data)
        }
        var pool = [1, 2, 3]
        let unencodable = Backend([.failure(EncodingError.invalidValue(Double.nan, .init(codingPath: [],
                                                                                        debugDescription: "test"))),
                                   .success(200)])
        _ = await run(&pool, unencodable)
        XCTAssertEqual(pool, [1, 2, 3], "a body that could not be encoded was never sent")
    }

    /// A timeout, or a connection that dropped, may have delivered the request:
    /// the credit is dropped like any reply the server could have seen.
    func testARequestThatMayHaveLeftDropsTheCredit() async {
        let mayHaveLeft: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.cancelled),
                                    URLError(.secureConnectionFailed), URLError(.badServerResponse),
                                    APIError(code: "network_error", message: "Invalid response")]
        for error in mayHaveLeft {
            var pool = [1, 2, 3]
            let backend = Backend([.failure(error), .success(200)])
            let out = await run(&pool, backend)

            XCTAssertEqual(backend.sent, [3], "\(error): one try, then the tiles")
            XCTAssertEqual(pool, [1, 2], "\(error): it may have reached the server, so it is dropped")
            XCTAssertNil(out.data)
        }
    }

    func testAnUnansweredRedemptionAfterASpentCreditStillStops() async {
        var pool = [1, 2, 3]
        let backend = Backend([.success(409), .success(502), .success(200)])
        let out = await run(&pool, backend)

        XCTAssertEqual(backend.sent, [3, 2], "409 moves on, 502 stops")
        XCTAssertEqual(pool, [1], "the spent one is dropped, and so is the unanswered one: the server saw it")
        XCTAssertNil(out.data)
    }

    func testAnEmptyPoolSendsNothing() async {
        var pool: [Int] = []
        let backend = Backend([.success(200)])
        let out = await run(&pool, backend)

        XCTAssertEqual(backend.sent, [])
        XCTAssertEqual(out.attempts, 0)
        XCTAssertNil(out.data)
    }

    // MARK: - the mapping

    func testEveryStatusMapsToOneStep() {
        XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(status: 200), .answered)
        XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(status: 204), .answered)
        XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(status: 409), .alreadySpent)
        XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(status: 401), .keyRotated)
        for status in [400, 403, 404, 429, 500, 502, 503, 504] {
            XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(status: status), .unanswered, "HTTP \(status)")
        }
        XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(error: URLError(.notConnectedToInternet)), .neverLeft)
        XCTAssertEqual(GeocodeTokenManager.RedeemStep.of(error: URLError(.timedOut)), .unanswered)
    }
}
