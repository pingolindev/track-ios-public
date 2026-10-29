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

/// Wire-contract coverage for
/// `POST /circles/:id/members/:user_id/revoke-access` — removing somebody
/// WITHOUT re-keying the circle.
///
/// This is the fallback for when `eject-and-rotate` is refused, which happens
/// when a fresh wrap cannot be built for every remaining member: a survivor
/// whose key changed without being verified, or whose identity key the server
/// cannot resolve. Without it, that state would mean nobody could be removed
/// from the circle at all.
///
/// What is pinned here is the field the user actually reads. `warning` is the
/// server's sentence about what the removal did and did not do, and iOS shows
/// it verbatim rather than writing its own — the paraphrase everyone reaches
/// for is "they no longer have access", which is true of the API and false of
/// the data they already hold. If the field is renamed or its snake_case
/// mapping drifts, the alert falls back to the bare statement of fact and the
/// consequence goes unsaid, silently, on the one screen where it matters most.
final class RevokeAccessWireTests: XCTestCase {

    /// Mirror APIService's strategy so the test exercises the real mapping.
    private func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    private let serverWarning =
        "They can no longer reach this circle, but the circle's key was not changed, so "
        + "anything they already downloaded stays readable to them. Rotate the circle's "
        + "keys when you can."

    func testDecodesTheServerResponse() throws {
        let json = """
        {
          "revoked_user_id": "11111111-1111-1111-1111-111111111111",
          "key_rotation_needed": true,
          "warning": "\(serverWarning)"
        }
        """.data(using: .utf8)!

        let decoded = try snakeDecoder().decode(RevokeAccessResponse.self, from: json)

        XCTAssertEqual(decoded.revokedUserId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(decoded.keyRotationNeeded, true)
        XCTAssertEqual(decoded.warning, serverWarning)
    }

    /// The half that must survive a rename: the warning has to say the removal
    /// did NOT reach backwards.
    func testTheWarningStatesWhatTheRemovalDidNotDo() throws {
        let json = """
        {"revoked_user_id":"1","key_rotation_needed":true,"warning":"\(serverWarning)"}
        """.data(using: .utf8)!

        let decoded = try snakeDecoder().decode(RevokeAccessResponse.self, from: json)
        let warning = try XCTUnwrap(decoded.warning)

        XCTAssertTrue(
            warning.contains("already downloaded stays readable"),
            "must not imply the removal reached backwards: \(warning)"
        )
        XCTAssertFalse(
            warning.contains("no longer has access"),
            "overstates it — true of the API, false of the data: \(warning)"
        )
    }

    /// An older server omits `warning` entirely. That must decode, not throw,
    /// and must leave nil rather than a default — the view substitutes a plain
    /// statement of fact, never reassurance nobody verified.
    func testAMissingWarningDecodesToNil() throws {
        let json = """
        {"revoked_user_id":"11111111-1111-1111-1111-111111111111"}
        """.data(using: .utf8)!

        let decoded = try snakeDecoder().decode(RevokeAccessResponse.self, from: json)

        XCTAssertNil(decoded.warning)
        XCTAssertNil(decoded.keyRotationNeeded)
        XCTAssertEqual(decoded.revokedUserId, "11111111-1111-1111-1111-111111111111")
    }

    /// `revoked_user_id` is the one required field. Losing it should fail
    /// loudly here rather than at a call site that assumes a removal happened.
    func testAMissingUserIdIsARejection() {
        let json = #"{"key_rotation_needed": true}"#.data(using: .utf8)!
        XCTAssertThrowsError(try snakeDecoder().decode(RevokeAccessResponse.self, from: json))
    }
}
