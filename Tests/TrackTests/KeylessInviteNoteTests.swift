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

/// An invitation that carries no key says when the circle opens for them,
/// never that they "had no account yet". The pending list knows of an
/// account only for an invitation bound to one (`target_user_id`), and one sent
/// to an address may still reach an account (a lookup that found no keys).
final class KeylessInviteNoteTests: XCTestCase {
    /// `GET /api/v1/circles/{id}/invites` rows as the server serves them.
    private func served(hasKey: Bool, boundTo account: String?) throws -> PendingInviteResponse {
        var row: [String: Any] = [
            "id": "a7a70000-0000-4000-8000-0000000000e1", "invite_type": "email",
            "target_email": "someone@example.com", "status": "pending", "created_day_bucket": 20_740,
            "expires_day_bucket": 20_746, "has_encrypted_key": hasKey,
            "invited_by": "a7a70000-0000-4000-8000-00000000000a",
        ]
        if let account { row["target_user_id"] = account }
        if hasKey { row["key_version"] = 1 }
        let body = try JSONSerialization.data(withJSONObject: ["success": true, "data": [row]])
        let rows: [PendingInviteResponse] = try APIService.decodeResponseBody(body)
        return try XCTUnwrap(rows.first)
    }

    func testAKeylessInvitationSaysWhenItOpensAndNothingAboutAnAccount() throws {
        let toAnAccount = try served(hasKey: false, boundTo: "a7a70000-0000-4000-8000-00000000000d")
        XCTAssertEqual(toAnAccount.targetUserId, "a7a70000-0000-4000-8000-00000000000d", "bound: they have an account")
        let toAnAddress = try served(hasKey: false, boundTo: nil)
        for invite in [toAnAccount, toAnAddress] {
            let note = try XCTUnwrap(invite.keylessNote)
            XCTAssertEqual(note, "When they join, the circle opens for them as soon as another member's app is online.")
            XCTAssertFalse(note.lowercased().contains("account"), "the list can't say, so it doesn't")
            XCTAssertFalse(note.lowercased().contains("key"))
        }
        XCTAssertNil(try served(hasKey: true, boundTo: "a7a70000-0000-4000-8000-00000000000d").keylessNote,
                     "with a key it opens as they join: nothing to explain")
    }

    func testTheInvitedListShowsTheNote() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("App/Views/Circles/CirclesView.swift"),
                              encoding: .utf8)
        XCTAssertTrue(view.contains("if let note = invite.keylessNote {"))
        XCTAssertFalse(view.contains("They had no account yet"))
    }
}
