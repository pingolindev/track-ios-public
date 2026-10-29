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

/// Content that opens only under a key version this device doesn't seal under
/// is HISTORY. A member removed at the last rotation still holds that key, so it
/// opens rows that look fresh. History is never live, never a "last seen",
/// never place-alert input. Also covered: a session key opens only its own
/// circle's rows, and a session key is imported under the id requested.
///
/// The real SDK throughout (the CurrentKeySealingTests pattern): an owner makes
/// v1 and gives it to this device and to a member it later leaves out; a
/// rotation to v2 without either; then v3 with this device. This device holds v1
/// and v3, and seals under v3. The one left out holds v1 alone.
final class CurrentKeyContentTests: XCTestCase {

    private let circle = "e0000000-0000-4000-8000-0000000000c1"
    private let other = "e0000000-0000-4000-8000-0000000000c2"
    private let ownerId = "e0000000-0000-4000-8000-000000000001"
    private let meId = "e0000000-0000-4000-8000-000000000002"
    private let leftOutId = "e0000000-0000-4000-8000-000000000003"

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private func base64(fromHex hex: String) -> String {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes).base64EncodedString()
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

    private struct World {
        let owner: Account
        let me: Account
        let leftOut: Account
    }

    private func install(_ bundle: MemberKeyBundle, version: Int32, from owner: Account, to member: Account,
                         circleId: String) throws {
        try member.crypto.storeCircleKey(
            circleId: circleId,
            encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey,
            keyVersion: version,
            senderUserId: owner.id,
            recipientUserId: member.id,
            wrapSignatureHex: bundle.wrapSignature,
            senderSigningPubkeyHex: owner.signing
        )
    }

    private func wrap(_ owner: Account, _ circleId: String, for member: Account) throws -> MemberKeyBundle {
        try owner.crypto.wrapCircleKeyForMemberFull(
            circleId: circleId, memberPublicKeyHex: member.sharing, senderUserId: owner.id,
            recipientUserId: member.id, recipientSigningPubkeyHex: member.signing)
    }

    /// This device holds v1 and v3 of `circle` (sealing under v3); the one left
    /// out holds v1 alone. `other` is a second circle at v1 that both the
    /// owner and this device hold.
    private func world() throws -> World {
        let owner = account(ownerId), me = account(meId), leftOut = account(leftOutId)
        for member in [me, leftOut] {
            for circleId in [circle, other] {
                _ = try member.crypto.pinMemberKeys(circleId: circleId, userId: owner.id,
                                                    sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
            }
        }
        for circleId in [circle, other] {
            let creation = try owner.crypto.prepareCircleCreation()
            try owner.crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
            try install(try wrap(owner, circleId, for: me), version: 1, from: owner, to: me, circleId: circleId)
        }
        try install(try wrap(owner, circle, for: leftOut), version: 1, from: owner, to: leftOut, circleId: circle)

        // v2 leaves both out; v3 brings this device back.
        _ = try owner.crypto.prepareKeyRotation(
            circleId: circle, senderUserId: owner.id, memberUserIds: [owner.id],
            memberPublicKeysHex: [owner.sharing], memberSigningPubkeysHex: [owner.signing],
            currentCircleNamePlaintext: "Family")
        let v3 = try owner.crypto.prepareKeyRotation(
            circleId: circle, senderUserId: owner.id, memberUserIds: [owner.id, me.id],
            memberPublicKeysHex: [owner.sharing, me.sharing], memberSigningPubkeysHex: [owner.signing, me.signing],
            currentCircleNamePlaintext: "Family")
        try install(try XCTUnwrap(v3.memberKeys.first { $0.userId == me.id }).bundle, version: 3,
                    from: owner, to: me, circleId: circle)
        XCTAssertEqual(try me.crypto.getActiveVersion(circleId: circle), 3)
        XCTAssertTrue(me.crypto.isCurrentKeyVersion(circleId: circle, keyVersion: 3))
        XCTAssertFalse(me.crypto.isCurrentKeyVersion(circleId: circle, keyVersion: 1))
        return World(owner: owner, me: me, leftOut: leftOut)
    }

    // MARK: - Rows, sealed as senders seal them

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    private let fixTime: Int64 = 1_727_600_000_000

    /// A latest-location row: the payload sealed by `by` for `claiming`, and,
    /// when given, the user id and the time sealed by `idBy` / `timeBy`.
    private func row(payloadBy by: CryptoManager, claiming userId: String, circleId: String? = nil,
                     sealedIdBy idBy: CryptoManager? = nil, timeBy: CryptoManager? = nil) throws -> LocationResponse {
        let circleId = circleId ?? circle
        let pseudonym = try by.deriveUserPseudonym(circleId: circleId, userId: userId)
        let envelope = try by.envelopeEncryptLocationBound(
            location: Location(latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil,
                               accuracy: 5, timestamp: fixTime, batteryLevel: 80, isCharging: nil),
            targetIds: [circleId], senderPseudonym: pseudonym)
        let keyWrap = try XCTUnwrap(envelope.keyWraps.first)
        var json: [String: Any] = [
            "day_bucket": 20_000,
            "encrypted_payload": [
                "nonce": base64(fromHex: envelope.ciphertextNonce),
                "ciphertext": base64(fromHex: envelope.ciphertext),
                "wrapped_msg_key": base64(fromHex: keyWrap.wrappedKey),
                "wrapped_msg_key_nonce": base64(fromHex: keyWrap.wrappedKeyNonce),
            ],
        ]
        if let idBy {
            json["encrypted_user_id"] = blob(try idBy.encryptDataV2(circleId: circleId, plaintext: userId, fieldTag: "user_id"))
        } else {
            json["user_id"] = userId
        }
        if let timeBy {
            json["encrypted_timestamp"] = blob(try timeBy.encryptDataV2(
                circleId: circleId, plaintext: String(fixTime), fieldTag: "timestamp"))
        }
        return try APIService.makeWireDecoder().decode(
            LocationResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func decode(_ response: LocationResponse, _ w: World, circleId: String? = nil) -> Track.CircleManager.RowDecode {
        CircleManager.decodeRow(response, circleId: circleId ?? circle, me: w.me.id, crypto: w.me.crypto)
    }

    private func isHistory(_ decoded: Track.CircleManager.RowDecode, of userId: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard case .history(let whose) = decoded else {
            return XCTFail("expected history, got \(decoded)", file: file, line: line)
        }
        XCTAssertEqual(whose, userId, file: file, line: line)
    }

    // MARK: - Which version opened a row

    func testARowUnderTheKeyInUseIsLive() throws {
        let w = try world()
        let decoded = decode(try row(payloadBy: w.owner.crypto, claiming: w.owner.id,
                                     sealedIdBy: w.owner.crypto, timeBy: w.owner.crypto), w)
        guard case .live(let location, let authenticatedTs) = decoded else {
            return XCTFail("expected live, got \(decoded)")
        }
        XCTAssertEqual(location.userId, w.owner.id)
        XCTAssertEqual(location.latitude, 52.5)
        // The sealed battery level survives the decode. The low-battery
        // evaluator reads it from this entry, so a decode that dropped it would
        // silence every low-battery rule.
        XCTAssertEqual(location.batteryLevel, 80)
        XCTAssertEqual(authenticatedTs, fixTime)
    }

    /// Opened only with a key the one left out holds (v1): each part is enough.
    func testARowOpenedUnderARetiredVersionIsHistoryWhicheverPartItIs() throws {
        let w = try world()
        // The payload itself.
        isHistory(decode(try row(payloadBy: w.leftOut.crypto, claiming: w.owner.id), w), of: w.owner.id)
        // A current payload read with a v1-sealed id.
        isHistory(decode(try row(payloadBy: w.owner.crypto, claiming: w.owner.id, sealedIdBy: w.leftOut.crypto), w),
                  of: w.owner.id)
        // A current payload and id with a v1-sealed time.
        isHistory(decode(try row(payloadBy: w.owner.crypto, claiming: w.owner.id, sealedIdBy: w.owner.crypto,
                                 timeBy: w.leftOut.crypto), w),
                  of: w.owner.id)
    }

    /// What the loop does with each: history is heard from and never live, and
    /// it is no failure (one injected row would silence every judgment).
    func testTheLoopHearsHistoryButNeverShowsOrCountsIt() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let load = try body(circles, from: "    func loadMemberLocations(for circleId: String,",
                            to: "    private func setupLocationSync() {")
        let history = try body(load, from: "                case .history(let userId):\n", to: "                case .live(")
        XCTAssertTrue(history.contains("                    heardFrom.insert(userId)\n"))
        XCTAssertFalse(history.contains("fresh["))
        XCTAssertFalse(history.contains("decryptFailed"))
        XCTAssertFalse(history.contains("keyMissing"))
        XCTAssertTrue(load.contains("            refreshedUserIds: Set(fresh.keys).union(decoded.heardFrom),\n"))
        // The version rule is the SDK's one test, over all three parts.
        let decode = try body(circles, from: "    nonisolated static func decodeRow(",
                              to: "    /// What one refresh of a circle's locations actually produced.")
        XCTAssertTrue(decode.contains("        let versions = [bound.keyVersion] + [idVersion, timeVersion].compactMap { $0 }\n"
                                      + "        guard versions.allSatisfy({ crypto.isCurrentKeyVersion(circleId: circleId, keyVersion: $0) }) else {\n"
                                      + "            return .history(resolvedUserId)\n"))
    }

    // MARK: - A row sealed straight under a circle key

    /// A latest-location row with NO wrapped msg_key: the payload sealed
    /// straight under `by`'s circle key in use, bound to `userId` (or the
    /// legacy unbound way), labelled `keyId`, and served as `servedAs`'s. Its
    /// text in hex, as a re-seal sends it and /latest serves it back, or in
    /// base64, as /latest serves a phone's streamed bytes.
    private func directRow(payloadBy by: CryptoManager, claiming userId: String, keyId: String?,
                           servedAs: String? = nil, bound: Bool = true, base64Text: Bool = false,
                           extra: [String: Any] = [:], timeBy: CryptoManager? = nil) throws -> LocationResponse {
        let location = Location(latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil,
                                accuracy: 5, timestamp: fixTime, batteryLevel: 80, isCharging: nil)
        let sealed: EncryptedData
        if bound {
            sealed = try by.encryptLocationBound(
                circleId: circle, location: location,
                senderPseudonym: try by.deriveUserPseudonym(circleId: circle, userId: userId))
        } else {
            sealed = try by.encryptLocation(circleId: circle, location: location)
        }
        var payload: [String: Any] = [
            "nonce": base64Text ? base64(fromHex: sealed.nonce) : sealed.nonce,
            "ciphertext": base64Text ? base64(fromHex: sealed.ciphertext) : sealed.ciphertext,
        ]
        if let keyId { payload["key_id"] = keyId }
        payload.merge(extra) { _, new in new }
        var json: [String: Any] = ["day_bucket": 20_000, "user_id": servedAs ?? userId, "encrypted_payload": payload]
        if let timeBy {
            json["encrypted_timestamp"] = blob(try timeBy.encryptDataV2(
                circleId: circle, plaintext: String(fixTime), fieldTag: "timestamp"))
        }
        return try APIService.makeWireDecoder().decode(
            LocationResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Under the key in use it is current, as an envelope is: a re-sealed
    /// frozen row (`c:3`) in either alphabet, and the Android app's send when
    /// its session key fails (`key_id` "", or none). Each must open: one left
    /// unopened in `locations` would make the whole refresh unusable for
    /// judging.
    func testARowSealedStraightUnderTheKeyInUseIsLive() throws {
        let w = try world()
        let shapes: [(keyId: String?, base64Text: Bool)] = [("c:3", false), ("c:3", true), ("", true), (nil, false)]
        for shape in shapes {
            let what = "key_id \(shape.keyId ?? "absent"), \(shape.base64Text ? "base64" : "hex")"
            let decoded = decode(try directRow(payloadBy: w.owner.crypto, claiming: w.owner.id, keyId: shape.keyId,
                                               base64Text: shape.base64Text, timeBy: w.owner.crypto), w)
            guard case .live(let location, let authenticatedTs) = decoded else {
                return XCTFail("\(what): expected live, got \(decoded)")
            }
            XCTAssertEqual(location.userId, w.owner.id, what)
            XCTAssertEqual(location.latitude, 52.5, what)
            XCTAssertEqual(location.batteryLevel, 80, what)
            XCTAssertEqual(authenticatedTs, fixTime, what)
        }
    }

    /// Sealed under v1, which the one left out holds: history, whatever its
    /// `key_id` says, `c:3` included. The version of the key that opened it
    /// decides, never the label.
    func testARowSealedStraightUnderARetiredVersionIsHistoryWhateverItsLabel() throws {
        let w = try world()
        for keyId in ["c:3", "3", "c:1", ""] {
            isHistory(decode(try directRow(payloadBy: w.leftOut.crypto, claiming: w.owner.id, keyId: keyId), w),
                      of: w.owner.id)
        }
    }

    /// Served as someone it wasn't sealed for, it opens nothing: the v3 tag fails
    /// under every version, and a v3 payload never opens the legacy way.
    func testARowSealedStraightForSomeoneElseDoesNotOpen() throws {
        let w = try world()
        let relabelled = try directRow(payloadBy: w.owner.crypto, claiming: w.owner.id, keyId: "c:3",
                                       servedAs: w.leftOut.id)
        let decoded = decode(relabelled, w)
        guard case .unopened = decoded else { return XCTFail("a relabelled row opens nothing, got \(decoded)") }
    }

    /// A legacy unbound one opens as a legacy envelope does: no stricter, no
    /// looser than the envelope path.
    func testALegacyRowSealedStraightOpensAsALegacyEnvelopeDoes() throws {
        let w = try world()
        let direct = decode(try directRow(payloadBy: w.owner.crypto, claiming: w.owner.id, keyId: "", bound: false), w)
        guard case .live(let location, _) = direct else { return XCTFail("legacy direct: expected live, got \(direct)") }
        XCTAssertEqual(location.latitude, 52.5)

        let envelope = try w.owner.crypto.envelopeEncryptLocationV2(
            location: Location(latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil,
                               accuracy: 5, timestamp: fixTime, batteryLevel: 80, isCharging: nil),
            targetIds: [circle])
        let keyWrap = try XCTUnwrap(envelope.keyWraps.first)
        let legacyEnvelope = try APIService.makeWireDecoder().decode(LocationResponse.self, from: JSONSerialization.data(
            withJSONObject: [
                "day_bucket": 20_000, "user_id": w.owner.id,
                "encrypted_payload": [
                    "nonce": base64(fromHex: envelope.ciphertextNonce),
                    "ciphertext": base64(fromHex: envelope.ciphertext),
                    "wrapped_msg_key": base64(fromHex: keyWrap.wrappedKey),
                    "wrapped_msg_key_nonce": base64(fromHex: keyWrap.wrappedKeyNonce),
                ],
            ] as [String: Any]))
        guard case .live = decode(legacyEnvelope, w) else { return XCTFail("the envelope path's own legacy read") }
    }

    /// One wrap field without the other is no envelope and no direct row: it
    /// stays a failure, even when the payload would open straight under the
    /// circle key.
    func testARowWithOneWrapFieldStaysUnopened() throws {
        let w = try world()
        for stray in ["wrapped_msg_key", "wrapped_msg_key_nonce"] {
            let row = try directRow(payloadBy: w.owner.crypto, claiming: w.owner.id, keyId: "c:3",
                                    extra: [stray: base64(fromHex: String(repeating: "ab", count: 24))])
            let decoded = decode(row, w)
            guard case .unopened = decoded else { return XCTFail("\(stray) alone: still a failure, got \(decoded)") }
        }
    }

    /// The frozen rows stay out of the refresh's health: one that doesn't
    /// open is only not drawn, never a failure, a missing key or history
    /// heard.
    func testAFrozenRowThatDoesntOpenIsNoFailure() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let load = try body(circles, from: "    func loadMemberLocations(for circleId: String,",
                            to: "    private func setupLocationSync() {")
        let frozen = try body(load, from: "            for response in lastKnown {\n", to: "            return (fresh: fresh,")
        XCTAssertFalse(frozen.contains("decryptFailed"))
        XCTAssertFalse(frozen.contains("keyMissing +="))
        XCTAssertFalse(frozen.contains("history +="))
        XCTAssertFalse(frozen.contains("heardFrom"))
        XCTAssertTrue(load.contains("            decryptionFailures: decoded.decryptFailed,\n"))
    }

    // MARK: - A session key opens its own circle's rows only

    func testASessionKeyOpensOnlyItsOwnCirclesRows() throws {
        let w = try world()
        // The owner's session key for `other`, imported here for `other`.
        let session = try w.owner.crypto.createSessionKey(circleId: other, sessionDurationSecs: 3_600)
        try w.me.crypto.importPeerSessionKey(
            circleId: other, sessionKeyId: session.sessionKeyId,
            encryptedSessionKey: session.encryptedSessionKey, keyNonce: session.keyNonce,
            keyVersion: session.keyVersion, expiresAtSecs: session.expiresAt)
        let sealed = try w.owner.crypto.encryptLocationWithSessionKeyBound(
            circleId: other,
            location: Location(latitude: 1, longitude: 2, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                               timestamp: fixTime, batteryLevel: nil, isCharging: nil),
            senderPseudonym: try w.owner.crypto.deriveUserPseudonym(circleId: other, userId: w.owner.id))
        let keyId = sealed.keyId.hasPrefix("s:") ? sealed.keyId : "s:\(sealed.keyId)"
        func sessionRow(_ circleId: String) throws -> LocationResponse {
            let json: [String: Any] = [
                "day_bucket": 20_000, "user_id": w.owner.id,
                "encrypted_payload": ["nonce": sealed.encrypted.nonce, "ciphertext": sealed.encrypted.ciphertext,
                                      "key_id": keyId],
            ]
            return try APIService.makeWireDecoder().decode(
                LocationResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        // In its own circle it opens.
        guard case .live = decode(try sessionRow(other), w, circleId: other) else {
            return XCTFail("the session key's own circle reads its row")
        }
        // Named as another circle's, or the personal slot's, it opens nothing.
        for circleId in [circle, CanonicalId.personalSlot] {
            guard case .keyMissing = decode(try sessionRow(circleId), w, circleId: circleId) else {
                return XCTFail("\(circleId): another circle's session key opens nothing")
            }
        }
    }

    func testEverySessionKeyReaderAsksForTheRowsOwnCircle() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertFalse(circles.contains("hasPeerSessionKey(sessionKeyId:"))
        XCTAssertTrue(circles.contains("for keyId in sessionKeyIds where !crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) {"))
        XCTAssertTrue(circles.contains("            guard crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId) else {\n"))
        let history = try source("App/Views/Map/HistoryView.swift")
        XCTAssertFalse(history.contains("hasPeerSessionKey(sessionKeyId:"))
        XCTAssertEqual(history.components(separatedBy: "crypto.hasPeerSessionKeyFor(circleId: circleId, sessionKeyId: keyId)").count - 1, 2)
    }

    // MARK: - Imported under the id requested

    func testASessionKeyIsImportedUnderTheIdRequestedOnly() {
        let id = "f0000000-0000-4000-8000-0000000000aa"
        XCTAssertEqual(APIService.sessionKeyIdToImport(requested: "s:\(id)", answered: id), id)
        XCTAssertEqual(APIService.sessionKeyIdToImport(requested: id, answered: "s:\(id)"), id)
        XCTAssertNil(APIService.sessionKeyIdToImport(requested: "s:\(id)",
                                                     answered: "f0000000-0000-4000-8000-0000000000bb"),
                     "an answer naming another id takes nobody's place")
        XCTAssertNil(APIService.sessionKeyIdToImport(requested: "s:\(id)", answered: id.uppercased()),
                     "no case folding")
        XCTAssertNil(APIService.sessionKeyIdToImport(requested: "s:", answered: ""))
    }

    func testTheFetchImportsWhatTheRowNamed() throws {
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("            guard let importId = Self.sessionKeyIdToImport(requested: sessionKeyId, answered: resp.sessionKeyId) else {\n"))
        XCTAssertTrue(api.contains("                sessionKeyId: importId,\n"))
        XCTAssertFalse(api.contains("sessionKeyId: resp.sessionKeyId,"))
    }

    // MARK: - Check-ins

    private func checkIn(_ id: String, userIdBy: CryptoManager, messageBy: CryptoManager? = nil,
                         locationBy: CryptoManager? = nil, timeBy: CryptoManager) throws -> CheckInResponse {
        var json: [String: Any] = [
            "id": id, "circle_id": circle, "check_in_type": "general", "day_bucket": 20_000,
            "encrypted_user_id": blob(try userIdBy.encryptDataV2(circleId: circle, plaintext: ownerId, fieldTag: "user_id")),
            "encrypted_device_id": ["nonce": "00", "ciphertext": "00"],
            "encrypted_timestamp": blob(try timeBy.encryptDataV2(circleId: circle, plaintext: String(fixTime),
                                                                 fieldTag: "timestamp")),
        ]
        if let messageBy {
            json["encrypted_message"] = blob(try messageBy.encryptDataV2(circleId: circle, plaintext: "I'm safe",
                                                                         fieldTag: "message"))
        }
        if let locationBy {
            json["encrypted_location"] = blob(try locationBy.encryptLocation(circleId: circle, location: Location(
                latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                timestamp: fixTime, batteryLevel: nil, isCharging: nil)))
        }
        return try APIService.makeWireDecoder().decode(
            CheckInResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testACheckInIsCurrentOnlyWhenEveryFieldOpenedUnderTheKeyInUse() throws {
        let w = try world()
        let current = try XCTUnwrap(CheckInManager.openCheckIn(
            try checkIn("k-current", userIdBy: w.owner.crypto, messageBy: w.owner.crypto,
                        locationBy: w.owner.crypto, timeBy: w.owner.crypto),
            circleId: circle, crypto: w.me.crypto))
        XCTAssertTrue(current.current)
        XCTAssertEqual(current.checkIn.message, "I'm safe")
        XCTAssertEqual(current.checkIn.userId, ownerId)
        XCTAssertEqual(current.checkIn.latitude, 52.5)

        // Any one field under v1 makes it history: the message, the place, the
        // id or the time.
        let cases: [(String, CheckInResponse)] = [
            ("message", try checkIn("k1", userIdBy: w.owner.crypto, messageBy: w.leftOut.crypto, timeBy: w.owner.crypto)),
            ("location", try checkIn("k2", userIdBy: w.owner.crypto, locationBy: w.leftOut.crypto, timeBy: w.owner.crypto)),
            ("user id", try checkIn("k3", userIdBy: w.leftOut.crypto, timeBy: w.owner.crypto)),
            ("time", try checkIn("k4", userIdBy: w.owner.crypto, timeBy: w.leftOut.crypto)),
        ]
        for (what, response) in cases {
            let opened = try XCTUnwrap(CheckInManager.openCheckIn(response, circleId: circle, crypto: w.me.crypto), what)
            XCTAssertFalse(opened.current, what)
            XCTAssertEqual(opened.checkIn.id, response.id, "\(what): still read, for the history screen")
        }
    }

    /// A check-in whose sealed time doesn't open is in neither list: the
    /// server's day bucket never dates one (as in the Android app). The
    /// others still are.
    func testACheckInWhoseTimeDoesntOpenIsDropped() throws {
        let w = try world()
        let stranger = account("c0ffee00-0000-4000-8000-0000000000ee").crypto
        let creation = try stranger.prepareCircleCreation()
        try stranger.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        XCTAssertNil(CheckInManager.openCheckIn(
            try checkIn("k-time", userIdBy: w.owner.crypto, messageBy: w.owner.crypto, timeBy: stranger),
            circleId: circle, crypto: w.me.crypto), "sealed under nothing held here")
        let sealedId = try w.owner.crypto.encryptDataV2(circleId: circle, plaintext: ownerId, fieldTag: "user_id")
        let garbled = try APIService.makeWireDecoder().decode(CheckInResponse.self, from: JSONSerialization.data(
            withJSONObject: [
                "id": "k-garbled", "circle_id": circle, "check_in_type": "general", "day_bucket": 20_000,
                "encrypted_user_id": ["nonce": sealedId.nonce, "ciphertext": sealedId.ciphertext],
                "encrypted_device_id": ["nonce": "00", "ciphertext": "00"],
                "encrypted_timestamp": ["nonce": "00", "ciphertext": "00"],
            ] as [String: Any]))
        XCTAssertNil(CheckInManager.openCheckIn(garbled, circleId: circle, crypto: w.me.crypto), "a time that doesn't open")
        let kept = try XCTUnwrap(CheckInManager.openCheckIn(
            try checkIn("k-kept", userIdBy: w.owner.crypto, timeBy: w.owner.crypto), circleId: circle, crypto: w.me.crypto))
        XCTAssertEqual(kept.checkIn.timestamp, Date(timeIntervalSince1970: TimeInterval(fixTime) / 1000))
        XCTAssertTrue(kept.current)
        XCTAssertFalse(try source("App/Managers/CheckInManager.swift").contains("response.dayBucket * 86_400_000"))
    }

    func testRecentCheckInsAreCurrentOnesAndTheHistoryKeepsEvery() throws {
        let manager = try source("App/Managers/CheckInManager.swift")
        let recent = try body(manager, from: "    func loadRecentCheckIns(for circleId: String) async throws {",
                              to: "    /// Decrypt the server-blind fields on a CheckInResponse")
        XCTAssertTrue(recent.contains("                guard let opened = Self.openCheckIn(response, circleId: circleId, crypto: crypto) else { return nil }\n"
                                      + "                return opened.current ? opened.checkIn : nil\n"))
        let history = try body(manager, from: "    func loadCheckInHistory(for circleId: String,", to: "\n    }\n")
        XCTAssertTrue(history.contains("page.compactMap { self.decryptCheckInResponse($0, circleId: circleId) }"))
        XCTAssertTrue(manager.contains("        Self.openCheckIn(response, circleId: circleId, crypto: cryptoManager)?.checkIn\n"))
    }

    // MARK: - Source helpers

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }
}
