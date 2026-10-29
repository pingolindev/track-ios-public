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

/// Wire-contract coverage for the inactivity "notify on return" (back-online)
/// field, as the Android app has it (`notify_on_return`).
///
/// Two invariants this port depends on:
///  1. the create request must SERIALIZE `notify_on_return` — the server reads
///     it to fire InactivityRecovered for server-evaluated self-alerts;
///  2. the response decode must TOLERATE its absence — an older backend omits
///     the key, and a non-optional field would throw and break the whole
///     alerts list. The DTO field is `Bool?` for exactly this.
final class InactivityNotifyOnReturnWireTests: XCTestCase {

    /// Mirror APIService's snake_case strategies so the test exercises the real
    /// wire mapping (`notifyOnReturn` <-> `notify_on_return`).
    private func snakeEncoder() -> JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }
    private func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    /// Full response minus the optional tail (last_triggered_day_bucket /
    /// encrypted_conditions / notify_on_return); callers append the closing `}`.
    private let baseResponseJSON = "{\"id\":\"a1\",\"user_id\":\"u1\",\"circle_id\":\"c1\",\"encrypted_target_user_id\":{\"nonce\":\"nn\",\"ciphertext\":\"cc\"},\"timeout_hours\":6,\"is_self_alert\":false,\"notify_push\":true,\"notify_email\":false,\"cooldown_minutes\":60,\"is_active\":true,\"day_bucket\":20000"

    func testCreateRequestSerializesNotifyOnReturn() throws {
        let req = CreateInactivityAlertRequest(
            circleId: "c1", targetUserId: "u1",
            encryptedTargetUserId: EncryptedBlobRequest(nonce: "nn", ciphertext: "cc"),
            timeoutMinutes: 360, isSelfAlert: true,
            notifyPush: true, notifyEmail: false, cooldownMinutes: 60,
            encryptedConditions: nil, clientOnly: false,
            targetUserPseudonym: "ps_u1", dayBucket: 20000,
            notifyOnReturn: true
        )
        let json = String(data: try snakeEncoder().encode(req), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"notify_on_return\":true"),
                      "create request must serialize notify_on_return; got \(json)")
    }

    /// The create request carries `target_user_pseudonym` so the backend
    /// cron can attribute a watched user's location rows without the raw id.
    /// Verify the camelCase field maps to snake_case on the wire.
    func testCreateRequestSerializesTargetUserPseudonym() throws {
        let req = CreateInactivityAlertRequest(
            circleId: "c1", targetUserId: "u1",
            encryptedTargetUserId: EncryptedBlobRequest(nonce: "nn", ciphertext: "cc"),
            timeoutMinutes: 360, isSelfAlert: false,
            notifyPush: true, notifyEmail: false, cooldownMinutes: 60,
            encryptedConditions: nil, clientOnly: false,
            targetUserPseudonym: "ps_u1", dayBucket: 20000,
            notifyOnReturn: false
        )
        let json = String(data: try snakeEncoder().encode(req), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"target_user_pseudonym\":\"ps_u1\""),
                      "create request must serialize target_user_pseudonym; got \(json)")
    }

    func testResponseDecodesNotifyOnReturnTrue() throws {
        let json = baseResponseJSON + ",\"notify_on_return\":true}"
        let resp = try snakeDecoder().decode(InactivityAlertResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.notifyOnReturn, true)
    }

    func testResponseToleratesMissingNotifyOnReturn() throws {
        // A backend that predates the field: the key is absent. Must decode to nil,
        // not throw.
        let json = baseResponseJSON + "}"
        let resp = try snakeDecoder().decode(InactivityAlertResponse.self, from: Data(json.utf8))
        XCTAssertNil(resp.notifyOnReturn, "missing notify_on_return must decode to nil, not throw")
    }

    // MARK: - The list envelope

    /// The inactivity-alerts list answers `{"success":true,"data":[…]}` — a
    /// BARE array, like the circle check-ins and destinations lists. Asking
    /// for `Paginated<E>` and reading `.items` would throw
    /// `keyNotFound("items")` on every 200.
    ///
    /// The damage would be upstream of any error handling:
    /// `InactivityAlertsManager` does `alerts = try await
    /// api.listInactivityAlerts()`, so a throw lands BEFORE the assignment and
    /// the published list keeps its previous value — `[]`. The Alerts screen
    /// would show no inactivity rule the user had ever created, with no error
    /// anywhere (`lastError` is read by no view).
    ///
    /// Fed the real body through the live decode, for the reason the check-in
    /// version of this test gives: an envelope this test builds itself would
    /// pass with the wrong type.
    func testTheAlertsListIsABareArrayNotAPaginationEnvelope() throws {
        let body = Data(("{\"success\":true,\"data\":[" + baseResponseJSON + "}]}").utf8)

        let alerts: [InactivityAlertResponse] = try APIService.decodeResponseBody(body)

        XCTAssertEqual(alerts.count, 1, "one rule in, one rule out")
        XCTAssertEqual(alerts.first?.id, "a1")

        XCTAssertThrowsError(
            try APIService.decodeResponseBody(body) as Paginated<InactivityAlertResponse>
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "items", "the key the pagination envelope looks for")
        }
    }

    /// The call site, which the decode test above cannot see: it asserts what
    /// `[InactivityAlertResponse]` admits, not which type `listInactivityAlerts`
    /// asks `get` for. See `APIServiceSource`.
    func testTheAlertsAccessorDoesNotAskForAPaginationEnvelope() throws {
        try APIServiceSource.assertNotPaginated(
            "listInactivityAlerts",
            reason: "GET /api/v1/inactivity-alerts answers a bare array"
        )
    }
}
