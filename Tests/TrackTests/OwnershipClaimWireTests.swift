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

/// Wire-contract coverage for the circle ownership claim routes.
///
/// A claim is a dead man's switch: an admin asks to take over a circle, the
/// owner is told, and SILENCE for fourteen days hands the circle over. The
/// client's only job on the safety-critical half is to render a refuse control
/// with a real date on it — which means a decode that throws is not a blank
/// row, it is a circle that quietly changes hands.
///
/// The way this goes wrong is a Swift return type that does not match what the
/// server serializes, throwing AFTER the server has already committed. So the
/// shapes are pinned against what the server actually sends.
final class OwnershipClaimWireTests: XCTestCase {

    /// Mirror APIService's strategy so the test exercises the real mapping.
    private func snakeDecoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }

    /// The claim as the server sends it, field for field:
    /// claim_id, circle_id, claimant_user_id, status, requested_at, resolves_at.
    private let claimJSON = """
    {
      "claim_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "circle_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      "claimant_user_id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
      "status": "pending",
      "requested_at": "2026-08-23T09:15:00.123456Z",
      "resolves_at": "2026-09-06T09:15:00.123456Z"
    }
    """

    // MARK: - The claim itself

    func testDecodesTheServerResponse() throws {
        let claim = try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(claimJSON.utf8))

        XCTAssertEqual(claim.claimId, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        XCTAssertEqual(claim.circleId, "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
        XCTAssertEqual(claim.claimantUserId, "cccccccc-cccc-cccc-cccc-cccccccccccc")
        XCTAssertEqual(claim.status, "pending")
        XCTAssertTrue(claim.isPending)
    }

    /// The one number the owner needs in order to act in time. The server reads
    /// it from the stored row rather than recomputing it, precisely so the
    /// countdown cannot move under them — losing it on this side would undo
    /// that.
    func testTheDeadlineSurvivesTheDecode() throws {
        let claim = try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(claimJSON.utf8))

        let deadline = try XCTUnwrap(claim.deadline, "resolves_at must reach the UI as a real instant")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day, .hour], from: deadline)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 6)
        XCTAssertEqual(parts.hour, 9, "the wire value is UTC and must not be shifted at decode time")
    }

    /// The server emits sub-second digits ONLY when they are nonzero, so a
    /// claim that lands on an exact second arrives without them. APIService's
    /// own date strategy demands fractional seconds and would throw on this —
    /// which is why the timestamps are raw Strings parsed here instead.
    func testATimestampWithoutFractionalSecondsStillParses() throws {
        let json = """
        {"claim_id":"a","status":"pending","resolves_at":"2026-09-06T09:15:00Z"}
        """
        let claim = try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(claim.deadline, "a whole-second deadline must not read as 'no deadline'")
    }

    func testATimestampWithFractionalSecondsStillParses() throws {
        let json = """
        {"claim_id":"a","status":"pending","resolves_at":"2026-09-06T09:15:00.7Z"}
        """
        let claim = try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(json.utf8))
        XCTAssertNotNil(claim.deadline)
    }

    /// An unparseable timestamp costs the date in the sentence and nothing
    /// else. Throwing here would blank the whole refuse screen over a
    /// formatting difference.
    func testAnUnparseableDeadlineIsNilRatherThanAThrow() throws {
        let json = #"{"claim_id":"a","status":"pending","resolves_at":"next tuesday"}"#
        let claim = try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(json.utf8))
        XCTAssertNil(claim.deadline)
    }

    /// Every display field is optional on purpose. A server that drops one must
    /// cost the client a word in a sentence, not the refuse control.
    func testAClaimWithOnlyItsIdStillDecodes() throws {
        let claim = try snakeDecoder().decode(
            OwnershipClaimResponse.self,
            from: Data(#"{"claim_id":"aaaa"}"#.utf8)
        )
        XCTAssertEqual(claim.claimId, "aaaa")
        XCTAssertNil(claim.circleId)
        XCTAssertNil(claim.claimantUserId)
        XCTAssertNil(claim.deadline)
        XCTAssertTrue(
            claim.isPending,
            "the GET filters on status='pending', so a row that came back at all is live"
        )
    }

    /// `claimId` is the one required field, and it is required so that an
    /// all-optional struct cannot decode from an envelope carrying no claim —
    /// see `testTheEnvelopeCannotDecodeFromAnEmptyBody`.
    func testAMissingClaimIdIsARejection() {
        XCTAssertThrowsError(
            try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data("{}".utf8))
        )
    }

    // MARK: - "There is no claim" is a SUCCESSFUL answer

    /// The ordinary case — no claim on this circle, which is nearly every
    /// circle nearly all the time — is a 200 carrying `data: null`. If that
    /// threw, every circle screen in the app would raise an error.
    func testNullDataIsNoLiveClaim() throws {
        let body = Data(#"{"success":true,"data":null}"#.utf8)
        let envelope = try snakeDecoder().decode(APIService.OwnershipClaimEnvelope.self, from: body)
        XCTAssertTrue(envelope.success)
        XCTAssertNil(envelope.data)
    }

    /// The same answer with the key omitted rather than nulled. Whether the
    /// server spells "no claim" as `data: null` or leaves the key out is an
    /// implementation detail a client should not depend on: both spellings
    /// have to mean "no claim".
    func testAnOmittedDataKeyIsAlsoNoLiveClaim() throws {
        let envelope = try snakeDecoder().decode(
            APIService.OwnershipClaimEnvelope.self,
            from: Data(#"{"success":true}"#.utf8)
        )
        XCTAssertTrue(envelope.success)
        XCTAssertNil(envelope.data)
    }

    func testAPresentClaimDecodesThroughTheEnvelope() throws {
        let body = Data(#"{"success":true,"data":\#(claimJSON)}"#.utf8)
        let envelope = try snakeDecoder().decode(APIService.OwnershipClaimEnvelope.self, from: body)
        let claim = try XCTUnwrap(envelope.data)
        XCTAssertEqual(claim.claimId, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        XCTAssertNotNil(claim.deadline)
    }

    /// The trap that makes the fallback decode safe. `decodeResponse` tries
    /// `APIResponse<T>` FIRST, which hands `T` the inner `data` object; if the
    /// envelope could decode from that, it would report "no claim" for a claim
    /// that is live — an owner shown nothing to refuse while the clock runs.
    /// It can't, because `success` is required.
    ///
    /// If someone ever makes `success` optional, this test is what fails.
    func testTheEnvelopeCannotDecodeFromTheInnerClaim() {
        XCTAssertThrowsError(
            try snakeDecoder().decode(APIService.OwnershipClaimEnvelope.self, from: Data(claimJSON.utf8))
        ) { error in
            guard case DecodingError.keyNotFound(let key, _)? = error as? DecodingError else {
                return XCTFail("expected keyNotFound(success), got \(error)")
            }
            XCTAssertEqual(key.stringValue, "success")
        }
    }

    /// The other half of the same guard, from the claim's side: a body with no
    /// claim in it must not decode AS a claim. This is why `claimId` is
    /// required rather than optional like everything else.
    func testTheEnvelopeCannotDecodeFromAnEmptyBody() {
        XCTAssertThrowsError(
            try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(#"{"success":true,"data":null}"#.utf8))
        )
    }

    /// A truncated body or an HTML error page must throw, not read as "no
    /// claim" — the reading that hides a live countdown.
    func testGarbageThrowsRatherThanReadingAsNoClaim() {
        XCTAssertThrowsError(
            try snakeDecoder().decode(APIService.OwnershipClaimEnvelope.self, from: Data("{}".utf8))
        )
        XCTAssertThrowsError(
            try snakeDecoder().decode(APIService.OwnershipClaimEnvelope.self, from: Data("<html>502</html>".utf8))
        )
    }

    // MARK: - The POST's own shape

    /// Opening a claim answers 201 with the claim wrapped in the ordinary
    /// response envelope, which `decodeResponse` unwraps. Pinned because the
    /// POST is the only route that returns the claim directly.
    func testTheOpenClaimResponseUnwrapsFromTheApiEnvelope() throws {
        let body = Data(#"{"success":true,"data":\#(claimJSON)}"#.utf8)
        let wrapped = try snakeDecoder().decode(APIResponse<OwnershipClaimResponse>.self, from: body)
        XCTAssertEqual(wrapped.data?.claimId, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        XCTAssertEqual(wrapped.data?.status, "pending")
    }

    /// `refuse` and `withdraw` answer `{"success":true,"data":null}`.
    /// `EmptyResponse` has to swallow that — a throw would tell the owner
    /// their refusal failed when the server had already recorded it.
    func testARefusalDecodesFromANullDataEnvelope() throws {
        XCTAssertNoThrow(
            try snakeDecoder().decode(EmptyResponse.self, from: Data(#"{"success":true,"data":null}"#.utf8))
        )
    }

    // MARK: - Statuses

    /// The server's five claim statuses. Only 'pending' is live; anything else
    /// is over and must not leave a countdown on screen. `refused` and
    /// `withdrawn` stay distinct forever after — "the owner said no" and "the
    /// admin thought better of it" are different facts about the same circle.
    func testOnlyPendingIsLive() throws {
        for status in ["completed", "refused", "withdrawn", "void"] {
            let json = #"{"claim_id":"a","status":"\#(status)"}"#
            let claim = try snakeDecoder().decode(OwnershipClaimResponse.self, from: Data(json.utf8))
            XCTAssertFalse(claim.isPending, "\(status) is resolved, not live")
        }
        let pending = try snakeDecoder().decode(
            OwnershipClaimResponse.self,
            from: Data(#"{"claim_id":"a","status":"pending"}"#.utf8)
        )
        XCTAssertTrue(pending.isPending)
    }
}
