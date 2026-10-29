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

/// A query value reaches the server exactly as sent. A query string decodes
/// `+` as a space, so an unescaped key lookup for a plus address asks the
/// server about a different address, finds no account, and the invitation is
/// signed as one to an EMAIL for an address that has an account — which the
/// server refuses.
final class QueryEscapingTests: XCTestCase {

    func testAPlusAddressSurvivesTheQueryString() {
        XCTAssertEqual(APIService.queryValue("test-user1+tag2@example.test"),
                       "test-user1%2Btag2@example.test")
        let decoded = URLComponents(string: "https://x.test/?email=" + APIService.queryValue("a+b@c.com"))?
            .queryItems?.first?.value?.removingPercentEncoding
        XCTAssertEqual(decoded, "a+b@c.com")
    }

    func testTheSeparatorsAreEscapedToo() {
        XCTAssertEqual(APIService.queryValue("a&b=c#d"), "a%26b%3Dc%23d")
        XCTAssertEqual(APIService.queryValue("plain-value_1.2~"), "plain-value_1.2~", "nothing else changes")
    }

    /// Every query value in APIService goes through it — the lookup above, the
    /// cursors, and the generic builder.
    func testEveryQueryValueIsEscapedTheSameWay() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let api = try String(contentsOf: root.appendingPathComponent("App/Services/APIService.swift"), encoding: .utf8)
        XCTAssertTrue(api.contains(#"/api/v1/users/public-key?email=\(Self.queryValue(email))"#))
        XCTAssertTrue(api.contains("components.percentEncodedQueryItems = params.map {"))
        XCTAssertFalse(api.contains("addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)"),
                       "`.urlQueryAllowed` leaves `+` as it is; use queryValue")
    }
}
