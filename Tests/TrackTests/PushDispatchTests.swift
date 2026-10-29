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

/// How a received push decides what the app should do.
///
/// Both halves of this can fail silently on real devices, and neither failure
/// is visible from the sending side — the server records a successful delivery
/// either way, and the user simply sees nothing happen. So they are pinned
/// here rather than left to a device test nobody runs twice.
final class PushDispatchTests: XCTestCase {

    // MARK: - Which key carries the family

    func testKindFallsBackToAlertTypeOnAPNs() {
        // THE trap. `type` is an FCM-side key and is not on the APNs allowlist of
        // routing keys, so on a real iPhone it is always nil. A dispatch that read
        // only `type` would send every typed case to `default` and nothing would
        // run — no tickle refresh, no wake_location, no member_joined.
        let apnsShaped: [AnyHashable: Any] = [
            "alert_type": "place_alert_enter",
            "alert_id": "place-uuid",
            "circle_id": "circle-uuid",
        ]
        XCTAssertEqual(PushAppDelegate.pushKind(from: apnsShaped), "place_alert_enter")
    }

    func testKindPrefersTypeSoFCMShapedPayloadsAreUnchanged() {
        let fcmShaped: [AnyHashable: Any] = ["type": "tickle", "alert_type": "place_alert_enter"]
        XCTAssertEqual(PushAppDelegate.pushKind(from: fcmShaped), "tickle")
    }

    func testKindReadsTypeNestedUnderAps() {
        let nested: [AnyHashable: Any] = ["aps": ["type": "wake_location"]]
        XCTAssertEqual(PushAppDelegate.pushKind(from: nested), "wake_location")
    }

    func testKindIsNilWhenNothingIdentifiesThePush() {
        XCTAssertNil(PushAppDelegate.pushKind(from: [:]))
        XCTAssertNil(PushAppDelegate.pushKind(from: ["alert_type": 7]))
    }

    // MARK: - Which families ask the app to wake

    func testEveryBackendPlaceFormAsksForTheWake() {
        // The banner these carry is the blind server's own copy; only this device
        // can name the place and the member. A form missing from this set is not a
        // compile error and not a crash — the app just never evaluates, and the
        // user keeps reading "A family member arrived at a saved location".
        for kind in ["place_alert", "place_alert_enter", "place_alert_exit"] {
            XCTAssertTrue(
                PushAppDelegate.placeCrossingKinds.contains(kind),
                "\(kind) must wake the app"
            )
        }
    }

    func testOtherFamiliesDoNotWakeForAPlaceCrossing() {
        // These already arrive readable, so waking for them would spend the app's
        // background budget to learn nothing. Mirrors the server's own list of
        // kinds it sends a wake for — the two lists have to agree or the wake is
        // either never sent or never handled.
        for kind in ["sos_alert", "circle_invite", "destination_arrival", "tickle", "alerts_check", "wake_location"] {
            XCTAssertFalse(
                PushAppDelegate.placeCrossingKinds.contains(kind),
                "\(kind) must not be treated as a place crossing"
            )
        }
        // Near-misses must not slip through on a prefix.
        XCTAssertFalse(PushAppDelegate.placeCrossingKinds.contains("place_alert_"))
        XCTAssertFalse(PushAppDelegate.placeCrossingKinds.contains("place"))
    }
}

/// The HTTP status has to survive the error envelope.
///
/// The track API reports failures as a bare `"error": "message"` string, so the
/// envelope decoder labels every one of them "server_error" — it never sees the
/// response and cannot know better. Without the status, a 404 would be
/// indistinguishable from a 500 and every `code == "http_404"` carve-out in the
/// app would quietly never match.
final class APIErrorEnvelopeTests: XCTestCase {

    private func decodeEnvelope(_ json: String) throws -> APIError? {
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(APIResponse<EmptyResponse>.self, from: data).error
    }

    func testBareStringErrorStillDecodesToTheGenericLabel() throws {
        // Documents WHY the status has to be attached where it is known: at
        // this layer there is nothing to derive a status from.
        let error = try decodeEnvelope(#"{"success":false,"error":"Circle not found"}"#)
        XCTAssertEqual(error?.message, "Circle not found")
        XCTAssertEqual(error?.code, "server_error")
    }

    func testAServerSuppliedCodeOutranksTheGenericLabel() throws {
        // Quota gates and auth failures carry a code more specific than the
        // status, and it must keep priority when APIService rewrites the label.
        let error = try decodeEnvelope(
            #"{"success":false,"error":"Too many places","error_code":"quota_places_exceeded"}"#
        )
        XCTAssertEqual(error?.code, "quota_places_exceeded")
        XCTAssertEqual(error?.errorCode, "quota_places_exceeded")
    }

    /// `@MainActor` because CircleManager is: the seam inherits that isolation,
    /// and the alternative — making the helper nonisolated — would change
    /// production semantics to suit a test.
    @MainActor
    func testCircleNotFoundIsRecognisedOnceTheStatusSurvives() {
        // The carve-out CircleManager documents: a genuinely gone circle must not
        // be reported to the user as a connectivity problem.
        XCTAssertTrue(CircleManager.isCircleNotFoundForTesting(
            APIError(code: "http_404", message: "Circle not found")
        ))
        XCTAssertFalse(CircleManager.isCircleNotFoundForTesting(
            APIError(code: "server_error", message: "Circle not found")
        ))
        XCTAssertFalse(CircleManager.isCircleNotFoundForTesting(
            APIError(code: "http_500", message: "Internal error")
        ))
    }
}

/// Resolving a tap's routing ids from the stored notification row.
///
/// The ids do not ride on the push — they are stable identifiers, one for a
/// person, and everything on a payload reaches Apple. The push carries a
/// per-event correlation id instead, and the row repeats it.
final class TapRoutingResolutionTests: XCTestCase {

    private func row(id: String, eventId: String?, destinationId: String? = nil,
                     arrivedUserId: String? = nil) -> NotificationResponse {
        var meta: [String: AnyCodableValue] = [:]
        if let eventId { meta["event_id"] = .string(eventId) }
        if let destinationId { meta["destination_id"] = .string(destinationId) }
        if let arrivedUserId { meta["arrived_user_id"] = .string(arrivedUserId) }
        return NotificationResponse(
            id: id, circleId: "circle", notificationType: "destination_arrival",
            title: "Arrived", body: nil, metadata: meta, isRead: false,
            createdDayBucket: nil, createdAt: nil
        )
    }

    func testTheMatchingRowSuppliesTheIds() {
        let rows = [row(id: "n1", eventId: "evt-1", destinationId: "dest-1", arrivedUserId: "user-1")]
        let ids = PushAppDelegate.routingIds(from: rows, correlationId: "evt-1")
        XCTAssertEqual(ids.destinationId, "dest-1")
        XCTAssertEqual(ids.arrivedUserId, "user-1")
    }

    func testTwoEventsTogetherStillRouteToTheRightOne() {
        // THE reason this matches exactly rather than taking the newest row. Two
        // arrivals land together routinely — a guess opens the wrong place, which
        // is worse than opening the list.
        let rows = [
            row(id: "n2", eventId: "evt-2", destinationId: "dest-2", arrivedUserId: "user-2"),
            row(id: "n1", eventId: "evt-1", destinationId: "dest-1", arrivedUserId: "user-1"),
        ]
        let ids = PushAppDelegate.routingIds(from: rows, correlationId: "evt-1")
        XCTAssertEqual(ids.destinationId, "dest-1")
        XCTAssertEqual(ids.arrivedUserId, "user-1")
    }

    func testAnUnmatchedCorrelationResolvesNothing() {
        // Offline, or the row already read and paged out. The caller falls back to
        // the notifications list rather than routing somewhere arbitrary.
        let rows = [row(id: "n1", eventId: "evt-1", destinationId: "dest-1")]
        let ids = PushAppDelegate.routingIds(from: rows, correlationId: "evt-missing")
        XCTAssertNil(ids.destinationId)
        XCTAssertNil(ids.arrivedUserId)
    }

    func testRowsWithoutACorrelationIdAreIgnored() {
        // Older rows carry no correlation id and must not match a blank or absent
        // one.
        let rows = [row(id: "n1", eventId: nil, destinationId: "dest-1")]
        XCTAssertNil(PushAppDelegate.routingIds(from: rows, correlationId: "evt-1").destinationId)
        XCTAssertNil(PushAppDelegate.routingIds(from: rows, correlationId: "").destinationId)
    }
}

/// Resolving the CIRCLE for a tap from the stored notification row.
///
/// Everything on a push payload reaches Apple and Google. `destination_id`,
/// `arrived_user_id` and `route_id` stay off it for being stable alone, and
/// `circle_id` is weaker still: stable for the life of the circle AND shared
/// across several device tokens. A relay seeing one id beside four tokens has
/// a household, not a handle.
///
/// The tap that needs the circle most is `circle_ownership_claim`: a
/// fourteen-day notification whose tap is the owner's only way to refuse a
/// takeover, and every other branch in the tap handler lands somewhere with
/// no refuse control on it. So the assertion that matters here is that the
/// deep link resolves from a payload carrying NO circle id — a test using a
/// payload that carries one proves nothing.
///
/// The Android app reads it from the row too (`NotificationTickleFetcher`
/// puts `notif.circleId` into the alert data).
final class TapCircleResolutionTests: XCTestCase {

    private func claimRow(
        id: String,
        claimId: String?,
        circleId: String?
    ) -> NotificationResponse {
        var meta: [String: AnyCodableValue] = ["resolves_at": .string("2026-09-07T00:00:00Z")]
        if let claimId { meta["claim_id"] = .string(claimId) }
        return NotificationResponse(
            id: id, circleId: circleId, notificationType: "circle_ownership_claim",
            title: "Someone asked to take over your circle", body: "Open Pingolin to refuse",
            metadata: meta, isRead: false, createdDayBucket: nil, createdAt: nil
        )
    }

    /// The whole point. The server sends `alert_id: claim_id` on the push and
    /// writes the same `claim_id` into the row's metadata, so the circle is
    /// reachable over this app's own connection with nothing stable on the
    /// payload at all.
    func testTheClaimCircleResolvesFromTheRow() {
        let rows = [claimRow(id: "n1", claimId: "claim-1", circleId: "circle-1")]
        XCTAssertEqual(
            PushAppDelegate.circleId(from: rows, correlationId: "claim-1"),
            "circle-1",
            "the refuse deep link has to survive circle_id leaving the push"
        )
    }

    /// Exact match, never the newest — the same rule `routingIds` keeps, and
    /// with more at stake: opening the refuse control for the wrong circle
    /// means the owner refuses a claim nobody made and leaves the real one
    /// running to its fourteen-day deadline.
    func testTwoClaimsAtOnceStillResolveTheRightCircle() {
        let rows = [
            claimRow(id: "n2", claimId: "claim-2", circleId: "circle-2"),
            claimRow(id: "n1", claimId: "claim-1", circleId: "circle-1"),
        ]
        XCTAssertEqual(PushAppDelegate.circleId(from: rows, correlationId: "claim-1"), "circle-1")
        XCTAssertEqual(PushAppDelegate.circleId(from: rows, correlationId: "claim-2"), "circle-2")
    }

    /// Destinations stamp `metadata.event_id` instead of `claim_id`; a row id is
    /// the last resort. Each family names its correlation differently and only
    /// the row knows which, so all three have to work.
    func testEventIdAndRowIdAlsoCorrelate() {
        let byEvent = NotificationResponse(
            id: "n9", circleId: "circle-9", notificationType: "destination_arrival",
            title: "Arrived", body: nil, metadata: ["event_id": .string("evt-9")],
            isRead: false, createdDayBucket: nil, createdAt: nil
        )
        XCTAssertEqual(PushAppDelegate.circleId(from: [byEvent], correlationId: "evt-9"), "circle-9")

        let byRowId = claimRow(id: "row-7", claimId: nil, circleId: "circle-7")
        XCTAssertEqual(PushAppDelegate.circleId(from: [byRowId], correlationId: "row-7"), "circle-7")
    }

    /// Nothing found is a real answer, and the caller has a fallback for it: the
    /// notifications list, whose own `circle_ownership_claim` row reads
    /// `circleId` off the row and opens the same refuse sheet. Resolving to some
    /// arbitrary circle would be worse than one extra tap.
    func testAnUnmatchedCorrelationResolvesNoCircle() {
        let rows = [claimRow(id: "n1", claimId: "claim-1", circleId: "circle-1")]
        XCTAssertNil(PushAppDelegate.circleId(from: rows, correlationId: "claim-missing"))
        XCTAssertNil(PushAppDelegate.circleId(from: rows, correlationId: ""))
    }

    // MARK: - What the tap handler actually does with the two sources

    /// THE assertion: a claim push carrying no `circle_id` at all still
    /// produces a circle to deep-link to. Everything else in this file is
    /// scaffolding for this one line.
    func testTheDeepLinkResolvesWithNoCircleIdOnThePayload() {
        XCTAssertEqual(
            PushAppDelegate.claimCircleId(fromPush: nil, orRow: "circle-1"),
            "circle-1",
            "circle_id is leaving the payload — the refuse tap has to route without it"
        )
    }

    /// A push that carries the id routes on it, with no round-trip to the
    /// row.
    func testAPayloadThatStillCarriesTheCircleWins() {
        XCTAssertEqual(
            PushAppDelegate.claimCircleId(fromPush: "circle-push", orRow: "circle-row"),
            "circle-push"
        )
    }

    /// An empty string is not a value, and it falls through to the row. An
    /// empty circle id refused in the branch CONDITION would not just fail to
    /// route — the tap would fall through to the pending-invite fallback,
    /// which claims unrouted taps outright and has no refuse control on it.
    func testAnEmptyPayloadValueFallsThroughToTheRow() {
        XCTAssertEqual(PushAppDelegate.claimCircleId(fromPush: "", orRow: "circle-row"), "circle-row")
        XCTAssertNil(PushAppDelegate.claimCircleId(fromPush: "", orRow: ""))
        XCTAssertNil(PushAppDelegate.claimCircleId(fromPush: nil, orRow: nil))
    }

    /// A matched row with no usable circle is the same as no match — never an
    /// empty-string circle id, which would deep-link to a circle that cannot
    /// exist and present an empty refuse sheet.
    func testAMatchedRowWithNoCircleResolvesNothing() {
        XCTAssertNil(PushAppDelegate.circleId(
            from: [claimRow(id: "n1", claimId: "claim-1", circleId: nil)],
            correlationId: "claim-1"
        ))
        XCTAssertNil(PushAppDelegate.circleId(
            from: [claimRow(id: "n1", claimId: "claim-1", circleId: "")],
            correlationId: "claim-1"
        ))
    }
}
