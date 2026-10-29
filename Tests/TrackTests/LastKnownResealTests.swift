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

/// Re-sealing the last known location, the phone's half (`LastKnownReseal`),
/// with the real SDK: this account's frozen last location, found by the bytes
/// this phone sealed and sealed again from its own record under the circle's
/// current key (as the Android app's LastKnownResealTest).
///
/// The world: an owner makes v1 and gives it to this account, which seals a
/// send under it; `rotate` then brings v2 (and v3) with this account in it.
@MainActor
final class LastKnownResealTests: XCTestCase {

    private let circle = "e0000000-0000-4000-8000-0000000000d1"
    private let ownerId = "e0000000-0000-4000-8000-000000000011"
    private let meId = "e0000000-0000-4000-8000-000000000012"
    private let otherId = "e0000000-0000-4000-8000-000000000013"
    private let device = "d0000000-0000-4000-8000-0000000000d2"
    private let fixTime: Int64 = 1_727_600_000_000
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("last-known-reseal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - The real SDK

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private func base64(fromHex hex: String) -> String {
        LastKnownReseal.hexBytes(hex)!.base64EncodedString()
    }

    private struct Account {
        let id: String
        let crypto: CryptoManager
        let sharing: String
        let signing: String
    }

    private func account(_ id: String) -> Account {
        let crypto = CryptoManager()
        let sharing = hex(fromBase64: crypto.generateKeypair().publicKey)
        let signing = hex(fromBase64: crypto.generateSigningKeypair().verifyingKeyB64)
        return Account(id: id, crypto: crypto, sharing: sharing, signing: signing)
    }

    private func install(_ bundle: MemberKeyBundle, version: Int32, from owner: Account, to member: Account) throws {
        try member.crypto.storeCircleKey(
            circleId: circle,
            encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey,
            keyVersion: version,
            senderUserId: owner.id,
            recipientUserId: member.id,
            wrapSignatureHex: bundle.wrapSignature,
            senderSigningPubkeyHex: owner.signing
        )
    }

    private struct World {
        let owner: Account
        let me: Account
    }

    /// The owner makes v1 and gives it to this account.
    private func world() throws -> World {
        let owner = account(ownerId), me = account(meId)
        _ = try me.crypto.pinMemberKeys(circleId: circle, userId: owner.id,
                                        sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let creation = try owner.crypto.prepareCircleCreation()
        try owner.crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        let bundle = try owner.crypto.wrapCircleKeyForMemberFull(
            circleId: circle, memberPublicKeyHex: me.sharing, senderUserId: owner.id,
            recipientUserId: me.id, recipientSigningPubkeyHex: me.signing)
        try install(bundle, version: 1, from: owner, to: me)
        XCTAssertEqual(try me.crypto.getActiveVersion(circleId: circle), 1)
        return World(owner: owner, me: me)
    }

    /// The owner rotates, with this account in the circle: it then seals under
    /// `version`.
    private func rotate(_ w: World, to version: Int32) throws {
        let next = try w.owner.crypto.prepareKeyRotation(
            circleId: circle, senderUserId: w.owner.id, memberUserIds: [w.owner.id, w.me.id],
            memberPublicKeysHex: [w.owner.sharing, w.me.sharing], memberSigningPubkeysHex: [w.owner.signing, w.me.signing],
            currentCircleNamePlaintext: "Family")
        try install(try XCTUnwrap(next.memberKeys.first { $0.userId == w.me.id }).bundle,
                    version: version, from: w.owner, to: w.me)
        XCTAssertEqual(try w.me.crypto.getActiveVersion(circleId: circle), version)
    }

    /// This phone's send under the key it holds now, sealed as
    /// `SDKLocationStreamer.sendInner` seals one, and what it records of it.
    private struct Sent {
        let record: OwnLastSent
        let envelope: EnvelopeEncryptedLocation
        let wrap: KeyWrap
    }

    private func send(_ w: World, kind: OwnLastSent.Kind = .live, coarsenedToMiles: Double? = nil) throws -> Sent {
        let point = Location(latitude: 52.5, longitude: 13.4, altitude: 30, speed: 1.5, heading: 90, accuracy: 5,
                             timestamp: fixTime, batteryLevel: 80, isCharging: true)
        let envelope = try w.me.crypto.envelopeEncryptLocationBound(
            location: point, targetIds: [circle],
            senderPseudonym: try w.me.crypto.deriveUserPseudonym(circleId: circle, userId: w.me.id))
        let wrap = try XCTUnwrap(envelope.keyWraps.first)
        let record = OwnLastSent(
            sent: kind, envelope: envelope, wrap: wrap, point: point, coarsenedToMiles: coarsenedToMiles,
            keyVersion: try w.me.crypto.getActiveVersion(circleId: circle),
            devicePseudonym: try w.me.crypto.deriveDevicePseudonym(circleId: circle, deviceId: device))
        return Sent(record: record, envelope: envelope, wrap: wrap)
    }

    /// `payload` and, when given, `time` as one `last_known` row of a `/latest`
    /// answer, decoded as the live path decodes it.
    private func served(payload: [String: Any], time: [String: Any]? = nil,
                        userId: String? = nil) throws -> ServedFrozenBlobs {
        var row: [String: Any] = ["day_bucket": 20_000, "user_id": userId ?? meId, "encrypted_payload": payload]
        if let time { row["encrypted_timestamp"] = time }
        let body: [String: Any] = ["success": true, "data": ["locations": [Any](), "last_known": [row]] as [String: Any]]
        let latest: LatestLocationsResponse = try APIService.decodeResponseBody(
            try JSONSerialization.data(withJSONObject: body))
        XCTAssertEqual(latest.lastKnown?.count, 1, "the typed rows still read")
        return try XCTUnwrap(latest.lastKnownServed?.first)
    }

    /// The envelope as /latest serves a streamed row: base64, no key named.
    private func envelopeRow(_ sent: Sent) -> [String: Any] {
        [
            "nonce": base64(fromHex: sent.envelope.ciphertextNonce),
            "ciphertext": base64(fromHex: sent.envelope.ciphertext),
            "key_id": "",
            "wrapped_msg_key": base64(fromHex: sent.wrap.wrappedKey),
            "wrapped_msg_key_nonce": base64(fromHex: sent.wrap.wrappedKeyNonce),
        ]
    }

    /// The time the SDK sealed beside the send, under the key it was sent with.
    private func sentTime(_ w: World, _ ms: Int64? = nil) throws -> [String: Any] {
        let sealed = try w.me.crypto.encryptTimestamp(circleId: circle, timestampMs: ms ?? fixTime)
        return ["nonce": sealed.nonce, "ciphertext": sealed.ciphertext]
    }

    private func privacy(realtime: Bool = false, mode: String = "exact", until: Date? = nil,
                         bubbleRadius: Double = 1) -> PrivacySettings {
        PrivacySettings(circleId: circle, sharingMode: mode, shareRealtime: realtime, shareHistory: true,
                        shareBattery: true, bubbleEnabled: mode == "approximate", bubbleRadius: bubbleRadius,
                        pausedUntil: until, updatedAt: t0)
    }

    /// A run's world: the store, the posture, the gate and the requests sent.
    private final class Harness {
        var privacy: PrivacySettings?
        var access = true
        var me: String?
        var requests: [ResealLastKnownRequest] = []
        var answer: Error?
        var duringSend: (() -> Void)?
    }

    private func reseal(_ w: World, _ store: OwnLastSentStore, _ harness: Harness) -> LastKnownReseal {
        LastKnownReseal(
            store: store, crypto: w.me.crypto,
            privacyOf: { _ in harness.privacy }, me: { harness.me }, accessOpen: { harness.access },
            now: { self.t0 },
            send: { _, request in
                harness.requests.append(request)
                harness.duringSend?()
                if let answer = harness.answer { throw answer }
            })
    }

    private func setUpSent(_ w: World, kind: OwnLastSent.Kind = .live, coarsenedToMiles: Double? = nil)
        throws -> (Sent, OwnLastSentStore, Harness) {
        let sent = try send(w, kind: kind, coarsenedToMiles: coarsenedToMiles)
        let store = OwnLastSentStore(directory: directory)
        store.put(sent.record, circleId: circle, owner: meId)
        let harness = Harness()
        harness.privacy = privacy()
        harness.me = meId
        return (sent, store, harness)
    }

    /// The point a re-seal sealed, opened as a viewer holding the new key opens
    /// it, bound to this account.
    private func opened(_ blob: ResealBlob, by viewer: CryptoManager) throws -> BoundLocation {
        try viewer.decryptLocationBoundForUser(
            circleId: circle, encryptedLocation: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
            userId: meId)
    }

    // MARK: - The re-seal

    func testMyFrozenRowIsSealedAgainFromTheRecordUnderTheCurrentKey() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        let row = try served(payload: envelopeRow(sent), time: try sentTime(w))

        let outcome = await reseal(w, store, harness).run(circleId: circle, served: [row])
        XCTAssertEqual(outcome, .resealed)
        let request = try XCTUnwrap(harness.requests.first)
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(request.encryptedPayload.keyId, "c:2")
        XCTAssertEqual(request.devicePseudonym, sent.record.devicePseudonym, "the row keeps its device")
        XCTAssertEqual(request.previousEncryptedPayload, row.encryptedPayload, "as served, untouched")
        XCTAssertEqual(request.previousEncryptedTimestamp, row.encryptedTimestamp)

        // The record's point and time, under v2, bound to this account; nothing else.
        let point = try opened(request.encryptedPayload, by: w.owner.crypto)
        XCTAssertTrue(point.senderVerified)
        XCTAssertEqual(point.keyVersion, 2)
        XCTAssertEqual(point.location.latitude, 52.5)
        XCTAssertEqual(point.location.longitude, 13.4)
        XCTAssertEqual(point.location.accuracy, 5)
        XCTAssertEqual(point.location.timestamp, fixTime)
        XCTAssertNil(point.location.batteryLevel, "a frozen row is never judged: no battery")
        XCTAssertNil(point.location.isCharging)
        XCTAssertNil(point.location.altitude)
        XCTAssertNil(point.location.speed)
        XCTAssertNil(point.location.heading)
        let time = try XCTUnwrap(request.encryptedTimestamp)
        XCTAssertNil(time.keyId)
        let openedTime = try w.owner.crypto.decryptDataV2Opened(
            circleId: circle, encryptedData: EncryptedData(nonce: time.nonce, ciphertext: time.ciphertext),
            fieldTag: "timestamp")
        XCTAssertEqual(openedTime.text, String(fixTime))
        XCTAssertEqual(openedTime.keyVersion, 2)

        // The record follows the request, never the answer.
        let now = try XCTUnwrap(store.record(circleId: circle, owner: meId))
        XCTAssertEqual(now.nonce, request.encryptedPayload.nonce)
        XCTAssertEqual(now.ciphertext, request.encryptedPayload.ciphertext)
        XCTAssertEqual(now.keyId, "c:2")
        XCTAssertNil(now.wrappedKey)
        XCTAssertNil(now.wrappedKeyNonce)
        XCTAssertEqual(now.keyVersion, 2)
        XCTAssertNil(now.triedVersion)
        XCTAssertEqual(now.devicePseudonym, sent.record.devicePseudonym)
        XCTAssertEqual(now.latitude, sent.record.latitude)
        XCTAssertEqual(now.timestampMs, fixTime)

        // As /latest then serves it, a viewer holding v2 draws it, current.
        let resealedRow = try APIService.makeWireDecoder().decode(LocationResponse.self, from: JSONSerialization.data(
            withJSONObject: [
                "day_bucket": 20_000, "user_id": meId,
                "encrypted_payload": ["nonce": request.encryptedPayload.nonce,
                                      "ciphertext": request.encryptedPayload.ciphertext, "key_id": "c:2"],
                "encrypted_timestamp": ["nonce": time.nonce, "ciphertext": time.ciphertext],
            ] as [String: Any]))
        guard case .live(let drawn, let authenticatedTs) = CircleManager.decodeRow(
            resealedRow, circleId: circle, me: ownerId, crypto: w.owner.crypto) else {
            return XCTFail("a viewer holding the new key reads the re-sealed row as current")
        }
        XCTAssertEqual(drawn.latitude, 52.5)
        XCTAssertEqual(authenticatedTs, fixTime)
    }

    /// A record re-sealed once is found again at the next rotation in ITS
    /// shape, `c:<version>` and no wrap (absent or null).
    func testARecordSealedAgainIsFoundAgainAtTheNextRotation() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        let first = await reseal(w, store, harness)
            .run(circleId: circle, served: [try served(payload: envelopeRow(sent), time: try sentTime(w))])
        XCTAssertEqual(first, .resealed)
        let resealed = try XCTUnwrap(harness.requests.last)
        try rotate(w, to: 3)

        for wrapFields in [[:], ["wrapped_msg_key": NSNull(), "wrapped_msg_key_nonce": NSNull()]] as [[String: Any]] {
            var payload: [String: Any] = ["nonce": resealed.encryptedPayload.nonce,
                                          "ciphertext": resealed.encryptedPayload.ciphertext, "key_id": "c:2"]
            payload.merge(wrapFields) { _, new in new }
            let row = try served(payload: payload)
            XCTAssertTrue(LastKnownReseal.payloadIsRecord(row.encryptedPayload,
                                                          try XCTUnwrap(store.record(circleId: circle, owner: meId))),
                          "wraps \(wrapFields.isEmpty ? "absent" : "null")")
        }
        let row = try served(payload: ["nonce": resealed.encryptedPayload.nonce,
                                       "ciphertext": resealed.encryptedPayload.ciphertext, "key_id": "c:2"])
        let second = await reseal(w, store, harness).run(circleId: circle, served: [row])
        XCTAssertEqual(second, .resealed)
        XCTAssertEqual(harness.requests.last?.encryptedPayload.keyId, "c:3")
        XCTAssertEqual(try opened(try XCTUnwrap(harness.requests.last).encryptedPayload, by: w.owner.crypto).keyVersion, 3)
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.keyId, "c:3")
    }

    /// Each shape matches only itself: an envelope never a wrapless row or one
    /// naming a key, a re-seal never a row with a wrap or another key id.
    func testTheTwoShapesNeverMatchEachOther() throws {
        let w = try world()
        let sent = try send(w)
        let envelope = sent.record
        func object(_ fields: [String: AnyCodableValue]) -> AnyCodableValue { .object(fields) }
        let bytes: [String: AnyCodableValue] = ["nonce": .string(envelope.nonce), "ciphertext": .string(envelope.ciphertext)]
        let wraps: [String: AnyCodableValue] = ["wrapped_msg_key": .string(envelope.wrappedKey!),
                                                "wrapped_msg_key_nonce": .string(envelope.wrappedKeyNonce!)]
        XCTAssertTrue(LastKnownReseal.payloadIsRecord(object(bytes.merging(wraps) { a, _ in a }), envelope))
        XCTAssertTrue(LastKnownReseal.payloadIsRecord(object(bytes.merging(wraps) { a, _ in a }
            .merging(["key_id": .string("")]) { a, _ in a }), envelope))
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes), envelope), "an envelope's row has its wrap")
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes.merging(["key_id": .string("c:1")]) { a, _ in a }),
                                                       envelope), "nor a wrapless c:1 row")
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes.merging(wraps) { a, _ in a }
            .merging(["key_id": .string("c:1")]) { a, _ in a }), envelope), "an envelope names no key")
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes.merging(["wrapped_msg_key": wraps["wrapped_msg_key"]!]) { a, _ in a }),
                                                       envelope), "both wrap fields")

        var resealed = envelope
        resealed.keyId = "c:2"
        resealed.wrappedKey = nil
        resealed.wrappedKeyNonce = nil
        let named = bytes.merging(["key_id": .string("c:2")]) { a, _ in a }
        XCTAssertTrue(LastKnownReseal.payloadIsRecord(object(named), resealed))
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(named.merging(wraps) { a, _ in a }), resealed),
                       "a re-seal's row has no wrap")
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(named.merging(["wrapped_msg_key_nonce": wraps["wrapped_msg_key_nonce"]!]) { a, _ in a }),
                                                       resealed), "not even one field")
        for other in ["c:3", "c:1", "", "2", "s:2"] {
            XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes.merging(["key_id": .string(other)]) { a, _ in a }),
                                                           resealed), other)
        }
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes), resealed), "the key it named, named")
        var unnamed = resealed
        unnamed.keyId = nil
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(object(bytes), unnamed), "a record of neither shape matches nothing")
        XCTAssertFalse(LastKnownReseal.payloadIsRecord(.string("x"), envelope))
    }

    /// Nothing served is ever taken for this account's own: another member's id
    /// on my bytes, or my id on bytes I never sealed. Tried for the version.
    func testAForgeryOrMyBytesUnderAnotherIdIsNoMatchAndTriedOnce() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        let stranger = try send(w)   // sealed by this phone, never sent
        try rotate(w, to: 2)
        let rows = [
            try served(payload: envelopeRow(sent), userId: otherId),
            try served(payload: envelopeRow(stranger)),
        ]
        let outcome = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(outcome, .noMatch)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.triedVersion, 2)
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.nonce, sent.record.nonce, "nothing else moved")
        let again = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
        XCTAssertEqual(again, .notDue, "once per version")
        XCTAssertTrue(harness.requests.isEmpty)
        let none = await reseal(w, store, harness).run(circleId: circle, served: [])
        XCTAssertEqual(none, .notDue)
    }

    func testBytesCompareAsBytesInEitherAlphabet() {
        let hexText = "00ff10ab"
        XCTAssertTrue(LastKnownReseal.sameBytes(hexText, hexText))
        XCTAssertTrue(LastKnownReseal.sameBytes(hexText, "00FF10AB"))
        XCTAssertTrue(LastKnownReseal.sameBytes(hexText, Data([0x00, 0xff, 0x10, 0xab]).base64EncodedString()))
        XCTAssertFalse(LastKnownReseal.sameBytes(hexText, "00ff10ac"))
        XCTAssertFalse(LastKnownReseal.sameBytes(hexText, Data([0x00, 0xff, 0x10]).base64EncodedString()))
        XCTAssertFalse(LastKnownReseal.sameBytes(hexText, nil))
        XCTAssertFalse(LastKnownReseal.sameBytes(nil, nil))
        XCTAssertFalse(LastKnownReseal.sameBytes("", ""), "no bytes are nobody's")
        XCTAssertNil(LastKnownReseal.hexBytes("abc"))
        XCTAssertNil(LastKnownReseal.hexBytes("zz"))
    }

    /// The served time is never read or used: a row whose time blob says
    /// something else is sealed again with the record's own time. No time
    /// served, none sent.
    func testTheTimeIsTheRecordsAndOnlyWhenTheRowHasOne() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        let swapped = try served(payload: envelopeRow(sent), time: try sentTime(w, fixTime + 86_400_000))
        let outcome = await reseal(w, store, harness).run(circleId: circle, served: [swapped])
        XCTAssertEqual(outcome, .resealed)
        let time = try XCTUnwrap(harness.requests.last?.encryptedTimestamp)
        XCTAssertEqual(try w.owner.crypto.decryptDataV2Opened(
            circleId: circle, encryptedData: EncryptedData(nonce: time.nonce, ciphertext: time.ciphertext),
            fieldTag: "timestamp").text, String(fixTime))

        let w2 = try world()
        let (sent2, store2, harness2) = try setUpSent(w2)
        try rotate(w2, to: 2)
        let untimed = await reseal(w2, store2, harness2).run(circleId: circle,
                                                            served: [try served(payload: envelopeRow(sent2))])
        XCTAssertEqual(untimed, .resealed)
        let request = try XCTUnwrap(harness2.requests.last)
        XCTAssertNil(request.encryptedTimestamp)
        XCTAssertNil(request.previousEncryptedTimestamp)
    }

    // MARK: - When it is due

    func testNotDueWhileRealTimeIsOnPausedClosedSignedOutOrTheKeyHasNotMoved() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        let rows = [try served(payload: envelopeRow(sent))]
        // The key hasn't moved.
        let unmoved = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(unmoved, .notDue)
        try rotate(w, to: 2)
        let rowsNow = [try served(payload: envelopeRow(sent))]
        for (what, change) in [
            ("real time on", { (h: Harness) in h.privacy = self.privacy(realtime: true) }),
            ("paused, no end", { (h: Harness) in h.privacy = self.privacy(mode: "paused") }),
            ("paused until later", { (h: Harness) in h.privacy = self.privacy(mode: "paused", until: self.t0.addingTimeInterval(60)) }),
            ("no privacy row", { (h: Harness) in h.privacy = nil }),
            ("access closed", { (h: Harness) in h.access = false }),
            ("signed out", { (h: Harness) in h.me = nil }),
        ] as [(String, (Harness) -> Void)] {
            let h = Harness()
            h.privacy = privacy()
            h.me = meId
            change(h)
            let outcome = await reseal(w, store, h).run(circleId: circle, served: rowsNow)
            XCTAssertEqual(outcome, .notDue, what)
            XCTAssertTrue(h.requests.isEmpty, what)
        }
        XCTAssertNil(store.record(circleId: circle, owner: meId)?.triedVersion, "none of those counts as tried")
        // Another account's record is no record.
        let h = Harness()
        h.privacy = privacy()
        h.me = otherId
        let someoneElse = await reseal(w, store, h).run(circleId: circle, served: rowsNow)
        XCTAssertEqual(someoneElse, .notDue)
        // A pause that has ended holds nothing back.
        harness.privacy = privacy(mode: "paused", until: t0.addingTimeInterval(-60))
        let lapsed = await reseal(w, store, harness).run(circleId: circle, served: rowsNow)
        XCTAssertEqual(lapsed, .resealed)
    }

    /// Never finer than the circle gets now: a precise point is not sealed
    /// again while the circle shares approximately, and isn't counted as
    /// tried, so it is once the circle is exact again. A coarse one may be,
    /// at the same bubble or a smaller one.
    func testNeverFinerThanTheCircleGetsNow() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        let rows = [try served(payload: envelopeRow(sent))]
        harness.privacy = privacy(mode: "approximate", bubbleRadius: 2)
        let approximate = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(approximate, .notDue)
        XCTAssertNil(store.record(circleId: circle, owner: meId)?.triedVersion)
        var paused = privacy(mode: "paused", until: t0.addingTimeInterval(-60))
        paused.modeBeforePause = "approximate"
        harness.privacy = paused
        let returning = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(returning, .notDue, "a lapsed pause shares as the mode it returns to")
        harness.privacy = privacy()
        let exact = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(exact, .resealed)

        for (sealedAt, now, due) in [(2.0, 2.0, true), (2.0, 1.0, true), (1.0, 2.0, false)] {
            let wc = try world()
            let (sentC, storeC, harnessC) = try setUpSent(wc, coarsenedToMiles: sealedAt)
            try rotate(wc, to: 2)
            harnessC.privacy = privacy(mode: "approximate", bubbleRadius: now)
            let outcome = await reseal(wc, storeC, harnessC).run(circleId: circle,
                                                                 served: [try served(payload: envelopeRow(sentC))])
            XCTAssertEqual(outcome, due ? LastKnownReseal.Outcome.resealed : .notDue,
                           "sealed at \(sealedAt) mi, the circle at \(now) mi")
        }
    }

    // MARK: - What comes of it

    func testARefusalIsFinalForItsVersionAndANewVersionIsTriedOnce() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        harness.answer = APIError(code: "http_404", message: "There is no last location to re-seal")
        let rows = [try served(payload: envelopeRow(sent))]
        let refused = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(refused, .refused)
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.triedVersion, 2)
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.nonce, sent.record.nonce)
        let again = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(again, .notDue, "never looped")
        XCTAssertEqual(harness.requests.count, 1)
        try rotate(w, to: 3)
        harness.answer = nil
        let next = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(next, .resealed)
        XCTAssertEqual(harness.requests.last?.encryptedPayload.keyId, "c:3")
    }

    /// No network, a 5xx, a 429: nothing changes, and the next refresh tries.
    func testAFailureLeavesTheRecordForTheNextRefresh() async throws {
        for answer in [APIError(code: "http_500", message: "x"), APIError(code: "rate_limited", message: "x"),
                       URLError(.notConnectedToInternet)] as [Error] {
            let w = try world()
            let (sent, store, harness) = try setUpSent(w)
            try rotate(w, to: 2)
            harness.answer = answer
            let rows = [try served(payload: envelopeRow(sent))]
            let failed = await reseal(w, store, harness).run(circleId: circle, served: rows)
            XCTAssertEqual(failed, .failed, "\(answer)")
            var kept = try XCTUnwrap(store.record(circleId: circle, owner: meId))
            XCTAssertNotNil(kept.pending, "what was sent is kept: \(answer)")
            kept.pending = nil
            XCTAssertEqual(kept, sent.record, "otherwise unchanged: \(answer)")
            harness.answer = nil
            let retried = await reseal(w, store, harness).run(circleId: circle, served: rows)
            XCTAssertEqual(retried, .resealed, "\(answer)")
        }
    }

    /// A send that lands while a re-seal is on its way is newer: it stays.
    func testASendDuringTheReSealIsKept() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        let newer = try send(w)
        harness.duringSend = { store.put(newer.record, circleId: self.circle, owner: self.meId) }
        let outcome = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
        XCTAssertEqual(outcome, .resealed)
        XCTAssertEqual(store.record(circleId: circle, owner: meId), newer.record)
    }

    /// One run at a time per circle: a second one while the first waits on the
    /// server does nothing.
    func testOneRunAtATimePerCircle() async throws {
        let w = try world()
        let (sent, store, _) = try setUpSent(w)
        try rotate(w, to: 2)
        var release: CheckedContinuation<Void, Never>?
        var sends = 0
        let reseal = LastKnownReseal(
            store: store, crypto: w.me.crypto, privacyOf: { _ in self.privacy() }, me: { self.meId },
            accessOpen: { true }, now: { self.t0 },
            send: { _, _ in
                sends += 1
                if release == nil { await withCheckedContinuation { release = $0 } }
            })
        let rows = [try served(payload: envelopeRow(sent))]
        let circleId = circle
        let first = Task { await reseal.run(circleId: circleId, served: rows) }
        var spins = 0
        while release == nil, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        let held = try XCTUnwrap(release, "the first run is waiting on the server")
        let second = await reseal.run(circleId: circle.uppercased(), served: rows)
        XCTAssertEqual(second, .notDue)
        held.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .resealed)
        XCTAssertEqual(sends, 1)
    }

    // MARK: - A lost answer

    /// The row a re-seal leaves, as /latest serves it: its blob as sent, `c:N`.
    private func resealedRow(_ request: ResealLastKnownRequest, keyId: String? = nil,
                             extra: [String: Any] = [:]) throws -> ServedFrozenBlobs {
        var payload: [String: Any] = ["nonce": request.encryptedPayload.nonce,
                                      "ciphertext": request.encryptedPayload.ciphertext,
                                      "key_id": keyId ?? request.encryptedPayload.keyId ?? ""]
        payload.merge(extra) { _, new in new }
        return try served(payload: payload)
    }

    /// A 200 that never came back: what was sent is kept, and once it is
    /// served the record takes it, untried, with nothing sent again.
    func testALostAnswerIsTakenAsDoneOnceItsRowIsServed() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        harness.answer = URLError(.networkConnectionLost)
        let lost = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
        XCTAssertEqual(lost, .failed)
        let request = try XCTUnwrap(harness.requests.last)
        let kept = try XCTUnwrap(store.record(circleId: circle, owner: meId))
        XCTAssertEqual(kept.pending, OwnLastSent.Pending(nonce: request.encryptedPayload.nonce,
                                                         ciphertext: request.encryptedPayload.ciphertext,
                                                         keyId: "c:2", keyVersion: 2), "kept before the request went")
        XCTAssertEqual(kept.nonce, sent.record.nonce, "the record itself is unchanged")
        harness.answer = nil
        let next = await reseal(w, store, harness).run(circleId: circle, served: [try resealedRow(request)])
        XCTAssertEqual(next, .notDue, "landed: nothing left to do for v2")
        XCTAssertEqual(harness.requests.count, 1, "nothing sent again")
        let now = try XCTUnwrap(store.record(circleId: circle, owner: meId))
        XCTAssertEqual(now.nonce, request.encryptedPayload.nonce)
        XCTAssertEqual(now.ciphertext, request.encryptedPayload.ciphertext)
        XCTAssertEqual(now.keyId, "c:2")
        XCTAssertNil(now.wrappedKey)
        XCTAssertNil(now.wrappedKeyNonce)
        XCTAssertEqual(now.keyVersion, 2)
        XCTAssertNil(now.triedVersion)
        XCTAssertNil(now.pending)
    }

    /// Taken as done, then sealed again under the newer version, from the row
    /// it left.
    func testALostAnswerTakenAsDoneIsSealedAgainAtTheNextVersion() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        harness.answer = URLError(.timedOut)
        _ = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
        let lostRequest = try XCTUnwrap(harness.requests.last)
        try rotate(w, to: 3)
        harness.answer = nil
        let row = try resealedRow(lostRequest)
        let outcome = await reseal(w, store, harness).run(circleId: circle, served: [row])
        XCTAssertEqual(outcome, .resealed)
        let request = try XCTUnwrap(harness.requests.last)
        XCTAssertEqual(harness.requests.count, 2)
        XCTAssertEqual(request.encryptedPayload.keyId, "c:3")
        XCTAssertEqual(request.previousEncryptedPayload, row.encryptedPayload)
        XCTAssertEqual(try opened(request.encryptedPayload, by: w.owner.crypto).location.latitude, 52.5)
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.keyId, "c:3")
        XCTAssertNil(store.record(circleId: circle, owner: meId)?.pending)
    }

    /// Dropped by a refusal, and by any newer send.
    func testWhatWasSentIsDroppedOnARefusalAndOnANewerSend() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        harness.answer = URLError(.networkConnectionLost)
        _ = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
        XCTAssertNotNil(store.record(circleId: circle, owner: meId)?.pending)
        harness.answer = APIError(code: "http_404", message: "There is no last location to re-seal")
        let refused = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
        XCTAssertEqual(refused, .refused)
        XCTAssertNil(store.record(circleId: circle, owner: meId)?.pending, "a refusal drops it")
        XCTAssertEqual(store.record(circleId: circle, owner: meId)?.triedVersion, 2)

        let w2 = try world()
        let (sent2, store2, harness2) = try setUpSent(w2)
        try rotate(w2, to: 2)
        harness2.answer = URLError(.networkConnectionLost)
        _ = await reseal(w2, store2, harness2).run(circleId: circle, served: [try served(payload: envelopeRow(sent2))])
        XCTAssertNotNil(store2.record(circleId: circle, owner: meId)?.pending)
        let newer = try send(w2)
        store2.put(newer.record, circleId: circle, owner: meId)
        XCTAssertNil(store2.record(circleId: circle, owner: meId)?.pending, "a newer send drops it")
    }

    /// Only the very blob sent, in its own `c:N` shape and under my id, is taken:
    /// not with a wrap, not under another key id, not as someone else's.
    func testWhatWasSentIsTakenOnlyAsSentInItsOwnShape() async throws {
        let wrap: [String: Any] = ["wrapped_msg_key": String(repeating: "ab", count: 32),
                                   "wrapped_msg_key_nonce": String(repeating: "cd", count: 24)]
        for (what, variant) in [
            ("with a wrap", { (r: ResealLastKnownRequest) in try self.resealedRow(r, extra: wrap) }),
            ("under another key id", { (r: ResealLastKnownRequest) in try self.resealedRow(r, keyId: "c:3") }),
            ("naming no key", { (r: ResealLastKnownRequest) in try self.resealedRow(r, keyId: "") }),
            ("as someone else's", { (r: ResealLastKnownRequest) in
                try self.served(payload: ["nonce": r.encryptedPayload.nonce, "ciphertext": r.encryptedPayload.ciphertext,
                                          "key_id": "c:2"], userId: self.otherId) }),
        ] as [(String, (ResealLastKnownRequest) throws -> ServedFrozenBlobs)] {
            let w = try world()
            let (sent, store, harness) = try setUpSent(w)
            try rotate(w, to: 2)
            harness.answer = URLError(.networkConnectionLost)
            _ = await reseal(w, store, harness).run(circleId: circle, served: [try served(payload: envelopeRow(sent))])
            let request = try XCTUnwrap(harness.requests.last)
            harness.answer = nil
            let outcome = await reseal(w, store, harness).run(circleId: circle, served: [try variant(request)])
            XCTAssertEqual(outcome, .noMatch, what)
            let now = try XCTUnwrap(store.record(circleId: circle, owner: meId))
            XCTAssertNil(now.keyId, "\(what): not taken")
            XCTAssertEqual(now.keyVersion, 1, what)
            XCTAssertEqual(now.nonce, sent.record.nonce, what)
        }
    }

    // MARK: - The wire

    /// The served blobs go back as they came, a field this app doesn't
    /// model and the server's own key order included; what is new is
    /// exactly the route's fields.
    func testTheServedBlobsGoBackAsTheyCame() async throws {
        let w = try world()
        let (sent, store, harness) = try setUpSent(w)
        try rotate(w, to: 2)
        var payload = envelopeRow(sent)
        payload["future_field"] = "kept"
        let time: [String: Any] = try sentTime(w).merging(["key_id": "", "later": ["n": "v"]]) { a, _ in a }
        let timeJSON = try json(time), payloadJSON = try json(payload), user = meId.uppercased()
        let rawRow = """
            {"success": true, "data": {"locations": [], "last_known": [{"encrypted_timestamp": \(timeJSON), \
            "day_bucket": 20000, "encrypted_payload": \(payloadJSON), "user_id": "\(user)"}]}}
            """
        let latest: LatestLocationsResponse = try APIService.decodeResponseBody(Data(rawRow.utf8))
        let rows = try XCTUnwrap(latest.lastKnownServed)
        let outcome = await reseal(w, store, harness).run(circleId: circle, served: rows)
        XCTAssertEqual(outcome, .resealed, "my id in any spelling")
        let request = try XCTUnwrap(harness.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: APIService.encodeRequestBody(request)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["device_pseudonym", "previous_encrypted_payload", "previous_encrypted_timestamp",
                                        "encrypted_payload", "encrypted_timestamp"])
        XCTAssertEqual(body["previous_encrypted_payload"] as? NSDictionary, payload as NSDictionary)
        XCTAssertEqual(body["previous_encrypted_timestamp"] as? NSDictionary, time as NSDictionary)
        let new = try XCTUnwrap(body["encrypted_payload"] as? [String: Any])
        XCTAssertEqual(Set(new.keys), ["nonce", "ciphertext", "key_id"], "no wrap")
        XCTAssertEqual(new["key_id"] as? String, "c:2")
        XCTAssertEqual(Set(try XCTUnwrap(body["encrypted_timestamp"] as? [String: Any]).keys), ["nonce", "ciphertext"])
        XCTAssertEqual(body["device_pseudonym"] as? String, sent.record.devicePseudonym)
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    // MARK: - The record of a send

    /// What a send records is what /latest serves back of it: found, in its
    /// envelope's shape.
    func testASendsRecordIsWhatItSealed() throws {
        let w = try world()
        let sent = try send(w, kind: .liveness, coarsenedToMiles: 2)
        let record = sent.record
        XCTAssertEqual(record.kind, .liveness)
        XCTAssertEqual(record.nonce, sent.envelope.ciphertextNonce)
        XCTAssertEqual(record.ciphertext, sent.envelope.ciphertext)
        XCTAssertNil(record.keyId)
        XCTAssertEqual(record.wrappedKey, sent.wrap.wrappedKey)
        XCTAssertEqual(record.wrappedKeyNonce, sent.wrap.wrappedKeyNonce)
        XCTAssertEqual(record.timestampMs, sent.envelope.timestamp, "the envelope's own time")
        XCTAssertEqual(record.coarsenedToMiles, 2)
        XCTAssertEqual(record.keyVersion, 1)
        XCTAssertNil(record.triedVersion)
        XCTAssertTrue(LastKnownReseal.payloadIsRecord(try served(payload: envelopeRow(sent)).encryptedPayload, record))
    }

    func testOnlyASendThatLeavesTheLatestRowIsRecorded() {
        XCTAssertEqual(SDKLocationStreamer.recordKind(.history, circleId: circle), .live)
        XCTAssertEqual(SDKLocationStreamer.recordKind(.liveness, circleId: circle), .liveness)
        XCTAssertNil(SDKLocationStreamer.recordKind(.keptHistory, circleId: circle), "history only")
        XCTAssertNil(SDKLocationStreamer.recordKind(.history, circleId: SelfKeyManager.selfCircleUuid),
                     "the personal history is nobody else's")
    }
}
