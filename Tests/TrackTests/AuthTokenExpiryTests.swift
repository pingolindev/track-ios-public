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

/// Coverage for `AuthManager.jwtExpiry(_:)` — the offline access-token
/// expiry check that keeps the background refresh from rotating the
/// single-use refresh token while the app is suspendable (a rotation there
/// signs the person out when they close the app). The parser must be robust
/// to malformed input because a wrong "still valid" answer would re-enable
/// the very background rotation this avoids.
final class AuthTokenExpiryTests: XCTestCase {

    private func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Assemble a `header.payload.signature` JWT from a payload dict. Only the
    /// payload (segment 1) is consulted by `jwtExpiry`, but we include a real
    /// header + signature segment so the shape matches a genuine token.
    private func makeJWT(payload: [String: Any]) -> String {
        let header = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"]))
        let body = b64url(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).c2lnbmF0dXJl"
    }

    func testExtractsIntegerExp() {
        let exp: Double = 1_782_386_764
        let token = makeJWT(payload: ["sub": "u1", "exp": Int(exp)])
        XCTAssertEqual(AuthManager.jwtExpiry(token), exp)
    }

    func testExtractsExpEvenWhenBase64NeedsPadding() {
        // Vary the payload size until the base64url body length is NOT a
        // multiple of 4, exercising the padding-restore loop. Most real
        // payloads land here, so this is the common path, not an edge case.
        var token = ""
        for n in 0..<8 {
            let sub = String(repeating: "a", count: n)
            let candidate = makeJWT(payload: ["sub": sub, "exp": 1_782_386_764])
            let body = candidate.split(separator: ".")[1]
            if body.count % 4 != 0 { token = candidate; break }
        }
        XCTAssertFalse(token.isEmpty, "expected at least one payload whose base64 length needs padding")
        XCTAssertEqual(AuthManager.jwtExpiry(token), 1_782_386_764)
    }

    func testMissingExpClaimReturnsNil() {
        let token = makeJWT(payload: ["sub": "u1", "iat": 1_782_386_000])
        XCTAssertNil(AuthManager.jwtExpiry(token))
    }

    func testNonNumericExpReturnsNil() {
        let token = makeJWT(payload: ["sub": "u1", "exp": "soon"])
        XCTAssertNil(AuthManager.jwtExpiry(token))
    }

    func testGarbageStringReturnsNil() {
        XCTAssertNil(AuthManager.jwtExpiry("not-a-jwt"))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(AuthManager.jwtExpiry(""))
    }

    func testTooFewSegmentsReturnsNil() {
        // A single segment (no dots) can't carry a payload.
        let onlyHeader = b64url(try! JSONSerialization.data(withJSONObject: ["alg": "HS256"]))
        XCTAssertNil(AuthManager.jwtExpiry(onlyHeader))
    }

    func testNonBase64PayloadReturnsNil() {
        XCTAssertNil(AuthManager.jwtExpiry("header.!!!not-base64!!!.sig"))
    }
}
