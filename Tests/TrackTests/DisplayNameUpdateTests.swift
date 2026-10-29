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

/// `PATCH /api/v1/auth/me` — the display-name change.
///
/// WHY THIS FILE EXISTS
///   Two things must both be right for a display-name change to work:
///
///     1. The verb. The auth server accepts exactly three methods on that
///        path (`get`, `patch`, `delete`); a PUT is answered 405 and
///        nothing changes.
///     2. The response type. The server returns only `{ display_name }` —
///        no id, no email, no created_at — so decoding it as `User` throws
///        `keyNotFound(id)` on a request that in fact succeeded.
///
///   And `ProfileView.saveChanges` must not swallow a failure with `try?`,
///   or the only symptom is the name simply not changing.
///
///   The verb cannot be pinned here — `APIService` builds its own URLSession
///   with no injection seam, so there is nothing to stub without refactoring
///   the networking layer for a test. What proves the verb is the live
///   round-trip in AuthIntegrationTests, run by hand against a real server.
///   What this file pins is the response type, which a compiler would never
///   catch and a passing build would happily ship.
final class DisplayNameUpdateTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        // The strategy APIService uses; it is what maps `display_name`.
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    /// The real reply as the auth server sends it on the wire: `data` is
    /// `{ "display_name": ... }` and nothing else.
    private let realResponse = #"{"display_name":"Test-User-Renamed"}"#

    func testResponseDecodes() throws {
        let response = try decoder().decode(
            UpdateDisplayNameResponse.self, from: Data(realResponse.utf8))
        XCTAssertEqual(response.displayName, "Test-User-Renamed")
    }

    /// The server's field is nullable, and a client may restore the
    /// original name by PATCHing `null` — so null is a shape that really
    /// does come back and must not throw.
    func testNullDisplayNameDecodes() throws {
        let response = try decoder().decode(
            UpdateDisplayNameResponse.self, from: Data(#"{"display_name":null}"#.utf8))
        XCTAssertNil(response.displayName)
    }

    /// NEGATIVE CONTROL.
    ///
    /// `User` fails on the exact reply the server sends. If someone re-types
    /// the call site to `User` this test still passes (it asserts the
    /// failure), but the positive case above stops compiling — which is the
    /// intended tripwire. Kept because it is the clearest statement of why
    /// the dedicated type exists: not tidiness, but that the reused one
    /// cannot decode the response.
    func testUserCannotDecodeThisResponse() {
        XCTAssertThrowsError(
            try decoder().decode(User.self, from: Data(realResponse.utf8)),
            "User requires id/email/created_at, none of which this route returns"
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "id")
        }
    }

    /// The request body auth expects: `{"display_name": "..."}`.
    func testRequestEncodesSnakeCase() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = String(
            data: try encoder.encode(UpdateProfileRequest(displayName: "Ada")), encoding: .utf8)
        XCTAssertEqual(json, #"{"display_name":"Ada"}"#)
    }
}
