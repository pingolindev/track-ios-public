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

/// The circle's name goes with an invitation only to an address with no
/// account, for the e-mail that is that person's only notice. An account,
/// with keys or without, reads the invitation in the app and is sent no name:
/// circle names are otherwise end-to-end encrypted, and the server keeps
/// none.
final class InvitationNameTests: XCTestCase {

    private let account = UUID().uuidString.lowercased()

    /// The lookup's answer as the server writes it (`UserPublicKeyResponse`:
    /// `user_id` and `signing_public_key` left out when absent), through the
    /// app's decoder and `canonicalLookup`, as the invitation reads it.
    private func lookup(_ data: String) throws -> UserPublicKeyResponse {
        let answer: UserPublicKeyResponse = try APIService.decodeResponseBody(
            Data(#"{"success": true, "data": \#(data)}"#.utf8))
        return try XCTUnwrap(CircleManager.canonicalLookup(answer))
    }

    private func nameSent(_ data: String) throws -> String? {
        CircleManager.circleNameForInvitation(lookupUserId: try lookup(data).userId, name: "Family")
    }

    func testOnlyAnAddressWithNoAccountIsSentTheName() throws {
        XCTAssertEqual(try nameSent(#"{"email": "new@example.com", "sharing_public_key": null}"#), "Family")
        XCTAssertNil(try nameSent(#"""
            {"email": "kim@example.com", "sharing_public_key": "\#(String(repeating: "a", count: 64))",
             "user_id": "\#(account)", "signing_public_key": "\#(String(repeating: "b", count: 64))"}
            """#))
    }

    /// An account that never published keys signs a kind-2 invitation, like an
    /// address with no account, but it is an account: no name.
    func testAnAccountWithoutKeysIsStillAnAccount() throws {
        XCTAssertNil(try nameSent(#"{"email": "kim@example.com", "sharing_public_key": null, "user_id": "\#(account.uppercased())"}"#))
    }

    /// No answer is never "no account". A lookup naming an id that isn't one,
    /// or one the server couldn't make (503 `lookup_unavailable`), keeps the
    /// invitation waiting, and no request goes out, with a name or without,
    /// until the address has answered.
    func testNoAnswerSendsNothing() throws {
        let unreadable: UserPublicKeyResponse = try APIService.decodeResponseBody(Data(
            #"{"success": true, "data": {"email": "kim@example.com", "sharing_public_key": null, "user_id": "kim"}}"#.utf8))
        XCTAssertNil(CircleManager.canonicalLookup(unreadable), "an id that isn't one is no answer")
        XCTAssertTrue(PendingChanges.addressCouldNotBeChecked(PendingChanges.AnswerNotReadable()))
        XCTAssertTrue(PendingChanges.addressCouldNotBeChecked(
            APIError(code: "http_503", message: "", errorCode: "lookup_unavailable")))
        let manager = try source("App/Managers/CircleManager.swift")
        let waits = try XCTUnwrap(manager.range(of: "        } catch where PendingChanges.addressCouldNotBeChecked(error) {\n"))
        let request = try XCTUnwrap(manager.range(of: "        var request = InviteByEmailRequest(\n"))
        XCTAssertLessThan(waits.lowerBound, request.lowerBound, "the waiting branch ends the run before any request")
    }

    /// No name is no key on the wire, never an empty one.
    func testNoNameIsLeftOutOfTheRequest() throws {
        func body(_ name: String?) throws -> [String: Any] {
            let request = InviteByEmailRequest(email: "new@example.com", encryptedCircleKey: nil,
                                               ephemeralPublicKey: nil, circleName: name, wrapSignature: nil)
            let data = try APIService.makeWireEncoder().encode(request)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertNil(try body(nil)["circle_name"])
        XCTAssertEqual(try body("Family")["circle_name"] as? String, "Family")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The one request is built from the ANSWERED lookup: a lookup that fails
    /// keeps the invitation waiting before this line, so "no answer" can never
    /// pass for "no account" here.
    func testTheInvitationTakesTheNameFromTheAnsweredLookup() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        let answered = try XCTUnwrap(manager.range(of: "            lookup = answer\n"))
        let named = try XCTUnwrap(manager.range(of: """
                    let circleName = Self.circleNameForInvitation(
                        lookupUserId: lookup.userId, name: circles.first(where: { $0.id == circleId })?.name)

            """))
        let request = try XCTUnwrap(manager.range(of: "        var request = InviteByEmailRequest(\n"))
        XCTAssertLessThan(answered.lowerBound, named.lowerBound)
        XCTAssertLessThan(named.lowerBound, request.lowerBound)
        XCTAssertTrue(manager[request.upperBound...].hasPrefix("""
                        email: email,
                        encryptedCircleKey: encryptedKeyForInvitee,
                        ephemeralPublicKey: ephemeralPublicKey,
                        circleName: circleName,

            """))
        XCTAssertEqual(manager.components(separatedBy: "InviteByEmailRequest(").count, 2, "one place builds it")
    }
}
