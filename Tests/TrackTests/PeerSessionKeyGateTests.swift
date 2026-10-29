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
import PingolinTrackSDK
@testable import Track

/// The pre-check that decides whether a session-key location row is even
/// attempted, exercised through the real SDK.
///
/// # Why this needs an iOS test and not just a Rust one
///
/// `CircleManager.decodeRow` and `HistoryView` do not decrypt a session row
/// unless `hasPeerSessionKeyFor` says the key is held FOR THE ROW'S OWN CIRCLE:
///
///     guard crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) else {
///         return .keyMissing     // dropped, counted as "key missing"
///     }
///     bound = EnvelopeDecoding.decryptSessionLocationBound(…)
///
/// `keyId` there is the row's `key_id`, which for a session row is always the
/// ROUTING form `"s:{uuid}"` — the branch is reached via `keyId.hasPrefix("s:")`.
/// The SDK cache, however, is keyed by the circle and the BARE uuid, because
/// that is what `APIService.fetchSessionKey` hands `importPeerSessionKey` (the
/// id requested, with its "s:" stripped).
///
/// So the pre-check must strip the prefix exactly as the decrypt resolver does.
/// Looking the id up verbatim, the gate would answer `false` for every id a row
/// can actually carry: the else branch would always win, every session-key row
/// would be dropped, and the diagnostics would blame a key the app was holding
/// all along. The mobile SDK's own unit test covers the resolution rule; this
/// covers the rule as the app calls it, across the UniFFI boundary, with the
/// real binding.
///
/// A "does history render" check would not notice, since session rows are a
/// tiny minority of a circle's history (the envelope path writes an EMPTY
/// `key_id` and takes the other branch entirely). Only an assertion on the
/// gate itself pins it.
final class PeerSessionKeyGateTests: XCTestCase {

    private let circleId = "099f9244-87b6-4280-8bd5-67ae5a2232fa"
    private let userId = "fb00d5f1-568a-4c8d-abde-263d0301da4c"

    /// A manager holding one circle key at version 1, built the way the app
    /// builds one: generate the identity keypair, prepare a circle, then remap
    /// the temp id onto a real circle id.
    private func managerHoldingACircleKey() throws -> CryptoManager {
        let crypto = CryptoManager()
        _ = crypto.generateKeypair()
        let creation = try crypto.prepareCircleCreation()
        try crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        XCTAssertTrue(crypto.hasCircleKey(circleId: circleId), "setup: the circle key must be installed")
        return crypto
    }

    private func sampleLocation() -> Location {
        Location(
            latitude: 37.7955,
            longitude: -122.3937,
            altitude: nil,
            speed: nil,
            heading: nil,
            accuracy: nil,
            timestamp: 1_757_246_400_000,
            batteryLevel: nil,
            isCharging: nil
        )
    }

    // MARK: - The gate

    /// The cache is populated under the bare uuid the server issues. Both that
    /// id and the `"s:"`-prefixed form a row carries must resolve to it — the
    /// app holds the prefixed one and has no bare id to offer.
    func testTheGateAcceptsBothIdForms() throws {
        let crypto = try managerHoldingACircleKey()
        let published = try crypto.createSessionKey(circleId: circleId, sessionDurationSecs: 3600)

        XCTAssertFalse(published.sessionKeyId.hasPrefix("s:"),
                       "the server issues a bare uuid; the prefix is a routing artefact")
        XCTAssertTrue(crypto.hasPeerSessionKey(sessionKeyId: published.sessionKeyId),
                      "the bare id must resolve — it is how the cache is keyed")
        XCTAssertTrue(crypto.hasPeerSessionKey(sessionKeyId: "s:\(published.sessionKeyId)"),
                      "the prefixed id must resolve — it is what a row's key_id carries, "
                      + "and the only form CircleManager/HistoryView ever hold")
        // The app's gate asks for the row's own circle, in either form.
        XCTAssertTrue(crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: published.sessionKeyId))
        XCTAssertTrue(crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: "s:\(published.sessionKeyId)"))
        XCTAssertTrue(crypto.hasPeerSessionKeyFor(circleId: circleId.uppercased(), sessionKeyId: published.sessionKeyId),
                      "the circle in its one spelling")
        XCTAssertFalse(crypto.hasPeerSessionKeyFor(circleId: "099f9244-87b6-4280-8bd5-67ae5a2232fb",
                                                   sessionKeyId: published.sessionKeyId),
                       "another circle's session key opens nothing here")
    }

    /// Fail-closed is preserved: an id we genuinely do not hold is still false
    /// in either form. Normalising the prefix must not turn the gate into a
    /// rubber stamp.
    func testTheGateStillRefusesAKeyWeDoNotHold() throws {
        let crypto = try managerHoldingACircleKey()
        _ = try crypto.createSessionKey(circleId: circleId, sessionDurationSecs: 3600)

        let strangerId = "deadbeef-0000-4000-8000-000000000000"
        XCTAssertFalse(crypto.hasPeerSessionKey(sessionKeyId: strangerId))
        XCTAssertFalse(crypto.hasPeerSessionKey(sessionKeyId: "s:\(strangerId)"))
        XCTAssertFalse(crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: strangerId))
        XCTAssertFalse(crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: "s:\(strangerId)"))
    }

    // MARK: - The gate agrees with the decrypt behind it

    /// The whole point of the pre-check is that it predicts the decrypt. Seal a
    /// row the way a sending client does, then run the exact `CircleManager`
    /// shape over it: gate, then decrypt with the same `keyId`. A gate that
    /// said "no key" here would skip the decrypt below, which succeeds.
    func testTheGatePredictsTheDecryptForARealSessionRow() throws {
        let crypto = try managerHoldingACircleKey()
        _ = try crypto.createSessionKey(circleId: circleId, sessionDurationSecs: 3600)

        let pseudonym = try crypto.deriveUserPseudonym(circleId: circleId, userId: userId)
        let location = sampleLocation()
        let sealed = try crypto.encryptLocationWithSessionKeyBound(
            circleId: circleId,
            location: location,
            senderPseudonym: pseudonym
        )
        XCTAssertTrue(sealed.keyId.hasPrefix("s:"),
                      "setup: expected a session row, got \(sealed.keyId)")

        // The gate, exactly as CircleManager.decodeRow and HistoryView call it.
        XCTAssertTrue(crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: sealed.keyId),
                      "the gate must pass for a row sealed under a key we hold")

        // And the decrypt it gates really does open the row.
        let bound = try crypto.decryptLocationWithSessionKeyBoundForUser(
            circleId: circleId,
            encryptedLocation: sealed.encrypted,
            keyId: sealed.keyId,
            userId: userId
        )
        XCTAssertTrue(bound.senderVerified)
        XCTAssertEqual(bound.location.latitude, location.latitude, accuracy: 0.00001)
        XCTAssertEqual(bound.location.longitude, location.longitude, accuracy: 0.00001)
    }

    /// The two calls the app makes, in the order it makes them, with the id
    /// forms it actually holds: `APIService.fetchSessionKey` imports under the
    /// id requested, bare (only when the answer names that id), and
    /// `CircleManager` then gates on the row's `key_id` (the PREFIXED form).
    /// Those two ids naming the same cache entry is the entire contract.
    ///
    /// One manager rather than two: a second `CryptoManager` cannot be given an
    /// existing circle key from Swift (`storeCircleKey` needs an ECDH wrap and
    /// no keypair-import method is exported), and what is at stake here is id
    /// handling, not key transport. The genuine two-manager import is covered
    /// in the SDK's own tests (`peer_session_key_pre_check_accepts_both_id_forms`).
    func testImportUnderTheBareIdSatisfiesTheGateForThePrefixedRow() throws {
        let crypto = try managerHoldingACircleKey()
        let published = try crypto.createSessionKey(circleId: circleId, sessionDurationSecs: 3600)

        let pseudonym = try crypto.deriveUserPseudonym(circleId: circleId, userId: userId)
        let location = sampleLocation()
        let sealed = try crypto.encryptLocationWithSessionKeyBound(
            circleId: circleId,
            location: location,
            senderPseudonym: pseudonym
        )

        // Exactly APIService.fetchSessionKey's call, with the server's bare id.
        try crypto.importPeerSessionKey(
            circleId: circleId,
            sessionKeyId: published.sessionKeyId,
            encryptedSessionKey: published.encryptedSessionKey,
            keyNonce: published.keyNonce,
            keyVersion: published.keyVersion,
            expiresAtSecs: published.expiresAt
        )

        XCTAssertTrue(crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: sealed.keyId),
                      "a key imported under the bare id must satisfy the gate for the prefixed row")
        let bound = try crypto.decryptLocationWithSessionKeyBoundForUser(
            circleId: circleId,
            encryptedLocation: sealed.encrypted,
            keyId: sealed.keyId,
            userId: userId
        )
        XCTAssertEqual(bound.location.latitude, location.latitude, accuracy: 0.00001)
    }
}
