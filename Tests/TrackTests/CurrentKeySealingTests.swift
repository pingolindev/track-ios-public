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

/// A member a rotation left PENDING still holds only the OLD circle key — the
/// same key the removed member holds. A phone that kept sealing its locations,
/// places and check-ins under that key would hand them to exactly the person
/// the rotation was meant to shut out. Nothing new is sealed for a circle until
/// this device holds the version `GET /circles` says the circle is at; SOS is
/// the one exception.
final class CurrentKeySealingTests: XCTestCase {

    func testOnlyTheCurrentVersionSeals() {
        XCTAssertTrue(CircleManager.holdsCurrentKey(localActiveVersion: 4, circleKeyVersion: 4))
        XCTAssertFalse(CircleManager.holdsCurrentKey(localActiveVersion: 3, circleKeyVersion: 4),
                       "left pending (or not yet imported): the old key is the removed member's key too")
        XCTAssertTrue(CircleManager.holdsCurrentKey(localActiveVersion: 5, circleKeyVersion: 4),
                      "our own rotation, not yet confirmed by the server, is ahead — not behind")
        XCTAssertFalse(CircleManager.holdsCurrentKey(localActiveVersion: nil, circleKeyVersion: 1),
                       "no key at all seals nothing")
    }

    /// A rotation may leave the NAME sealed under the old key (the server keeps
    /// the stored name when a rotation omits it), so a device that is behind can
    /// still read it. It is locked all the same, with its explanation.
    func testABehindCircleIsLockedEvenWhenItsNameOpens() {
        let body = Data("""
        {"success":true,"data":{"id":"11111111-1111-4111-8111-1111111111c1","owner_id":"u1","is_owner":false,
         "encrypted_name":{"nonce":"00","ciphertext":"00"},"day_bucket":20000,"member_count":3,
         "key_version":5,"member_key_version":4}}
        """.utf8)
        guard let response: CircleResponse = try? APIService.decodeResponseBody(body) else {
            return XCTFail("fixture did not decode")
        }
        XCTAssertLessThan(CircleManager.ownWrapVersion(response), response.keyVersion)
        XCTAssertTrue(CircleManager.isShownLocked(nameOpened: true, response),
                      "left pending: locked although the name opened")
        let current = Data("""
        {"success":true,"data":{"id":"11111111-1111-4111-8111-1111111111c2","owner_id":"u1","is_owner":false,
         "encrypted_name":{"nonce":"00","ciphertext":"00"},"day_bucket":20000,"member_count":3,
         "key_version":5,"member_key_version":5}}
        """.utf8)
        guard let currentResponse: CircleResponse = try? APIService.decodeResponseBody(current) else {
            return XCTFail("fixture did not decode")
        }
        XCTAssertFalse(CircleManager.isShownLocked(nameOpened: true, currentResponse))
        XCTAssertTrue(CircleManager.isShownLocked(nameOpened: false, currentResponse))
        let circle = response.toModel(name: "Family", lockReason: .awaitingNewerKey)
        XCTAssertEqual(circle.name, "Family", "a readable name is kept")
        XCTAssertTrue(circle.isLocked, "rotation and sealing both key off isLocked")
        // The explanation: nothing new goes out, the locations are
        // kept for the circle until it has synced.
        XCTAssertEqual(CircleLockReason.awaitingNewerKey.copy(isOwner: false).explanation,
                       "Awaiting sync for circle settings from another member. Locations will be queued until synced.")
        XCTAssertNil(response.toModel(name: "Family").lockReason, "no reason passed: not locked")
    }

    // MARK: - Recovery: the new key arriving is all it takes

    private func row(keyVersion: Int, ownWrap: Int) throws -> CircleResponse {
        let body = Data("""
        {"success":true,"data":{"id":"11111111-1111-4111-8111-1111111111c1","owner_id":"u1","is_owner":false,
         "encrypted_name":{"nonce":"00","ciphertext":"00"},"day_bucket":20000,"member_count":2,
         "key_version":\(keyVersion),"member_key_version":\(ownWrap)}}
        """.utf8)
        return try APIService.decodeResponseBody(body)
    }

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    /// A device a rotation left behind catches up by itself. The owner's next
    /// rotation includes it; the next light poll (the foreground refresh) sees
    /// its wrap is newer than the key it holds and installs it; the circle is
    /// then unlocked and sealed for again. No restart, no sign-in — and the
    /// key it installs is the real one: the renamed circle and what it seals
    /// now open on the owner's side. Through the real SDK.
    func testABehindDeviceRecoversWhenTheNewKeyArrives() throws {
        let circle = "d0000000-0000-4000-8000-0000000000c1"
        let ownerId = "d0000000-0000-4000-8000-000000000001"
        let memberId = "d0000000-0000-4000-8000-000000000002"
        let owner = CryptoManager()
        let ownerSharing = hex(fromBase64: owner.generateKeypair().publicKey)
        let ownerSigning = hex(fromBase64: owner.generateSigningKeypair().verifyingKeyB64)
        let member = CryptoManager()
        let memberSharing = hex(fromBase64: member.generateKeypair().publicKey)
        let memberSigning = hex(fromBase64: member.generateSigningKeypair().verifyingKeyB64)
        _ = try member.pinMemberKeys(circleId: circle, userId: ownerId,
                                     sharingPubkeyHex: ownerSharing, signingPubkeyHex: ownerSigning)
        let creation = try owner.prepareCircleCreation()
        try owner.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        func install(_ bundle: MemberKeyBundle, version: Int32) throws {
            try member.storeCircleKey(
                circleId: circle,
                encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
                senderPublicKey: bundle.ephemeralPublicKey,
                keyVersion: version,
                senderUserId: ownerId,
                recipientUserId: memberId,
                wrapSignatureHex: bundle.wrapSignature,
                senderSigningPubkeyHex: ownerSigning
            )
        }
        try install(owner.wrapCircleKeyForMemberFull(
            circleId: circle, memberPublicKeyHex: memberSharing, senderUserId: ownerId,
            recipientUserId: memberId, recipientSigningPubkeyHex: memberSigning), version: 1)

        // A rotation leaves the member pending: the circle moves to v2, the member holds v1.
        let leftOut = try owner.prepareKeyRotation(
            circleId: circle, senderUserId: ownerId, memberUserIds: [ownerId],
            memberPublicKeysHex: [ownerSharing], memberSigningPubkeysHex: [ownerSigning],
            currentCircleNamePlaintext: "Family")
        XCTAssertEqual(leftOut.newKeyVersion, 2)
        let behind = try row(keyVersion: 2, ownWrap: 1)
        XCTAssertFalse(CircleManager.lightPollInstalls(heldVersion: 1, behind), "nothing newer for us yet")
        XCTAssertTrue(CircleManager.isShownLocked(nameOpened: true, behind))
        XCTAssertFalse(CircleManager.holdsCurrentKey(
            localActiveVersion: Int(try member.getActiveVersion(circleId: circle)), circleKeyVersion: 2))

        // The owner gives access: a rotation that includes the member (v3).
        let delivery = try owner.prepareKeyRotation(
            circleId: circle, senderUserId: ownerId, memberUserIds: [ownerId, memberId],
            memberPublicKeysHex: [ownerSharing, memberSharing],
            memberSigningPubkeysHex: [ownerSigning, memberSigning],
            currentCircleNamePlaintext: "Family")
        XCTAssertEqual(delivery.newKeyVersion, 3)
        let caughtUp = try row(keyVersion: 3, ownWrap: 3)
        XCTAssertTrue(CircleManager.lightPollInstalls(heldVersion: 1, caughtUp),
                      "the next light poll installs the delivered wrap")
        let wrap = try XCTUnwrap(delivery.memberKeys.first { $0.userId == memberId }).bundle
        try install(wrap, version: 3)

        let held = Int(try member.getActiveVersion(circleId: circle))
        XCTAssertEqual(held, 3)
        XCTAssertTrue(CircleManager.holdsCurrentKey(localActiveVersion: held, circleKeyVersion: 3), "sealing resumes")
        XCTAssertFalse(CircleManager.isShownLocked(nameOpened: true, caughtUp), "unlocked")
        XCTAssertFalse(CircleManager.lightPollInstalls(heldVersion: held, caughtUp), "and not re-installed every tick")
        XCTAssertEqual(try member.decryptDataV2(circleId: circle, encryptedData: delivery.encryptedName, fieldTag: "name"),
                       "Family")
        let sealed = try member.encryptDataV2(circleId: circle, plaintext: "at the park", fieldTag: "location")
        XCTAssertEqual(try owner.decryptDataV2(circleId: circle, encryptedData: sealed, fieldTag: "location"),
                       "at the park")
    }

    /// Nothing but the periodic refresh is needed: the foreground loop runs the
    /// light poll, the poll installs through `lightPollInstalls`, and a refused
    /// send restarts nothing.
    func testRecoveryNeedsNoRestart() throws {
        let tab = try source("App/Views/MainTabView.swift")
        XCTAssertTrue(tab.contains("try? await circleManager.loadCircles(light: true)"))
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("return Self.lightPollInstalls(heldVersion: held, response) ? response.id : nil"))
        // Fed the newest version HELD, never the one sealed under: a
        // version waiting for its record isn't installed again every tick.
        XCTAssertTrue(circles.contains("let held: Int? = cryptoManager.newestHeldVersion(circleId: response.id).map { Int($0) }\n                return Self.lightPollInstalls(heldVersion: held, response) ? response.id : nil"))
        // Thrown in exactly one place, and `send`'s catch does one thing with it:
        // keeps the fix for the circle. Then it falls to `default`, which
        // neither restarts the stream nor reloads keys.
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertEqual(streamer.components(separatedBy: "throw SendError.keyNotCurrent").count - 1, 1)
        XCTAssertEqual(streamer.components(separatedBy: "SendError.keyNotCurrent").count - 1, 3,
                       "a refusal for a key not yet delivered must not restart the stream or reload keys")
        XCTAssertTrue(streamer.contains("if case SendError.keyNotCurrent = error, kind == .history,"))
        // The past point's send keeps it the same way, and only that (`sendPastHistory`);
        // so does a wait for a row read since it was taken.
        XCTAssertTrue(streamer.contains("            switch error {\n"
                                        + "            case SendError.keyNotCurrent, SendError.waitingForSharingRecord:\n"
                                        + "                if let owner = AuthManager.shared.userId {\n"
                                        + "                    PendingCircleLocations.shared.keep(\n"
                                        + "                        privacyApplied(location, circleId: circleId), circleId: circleId, owner: owner)\n"
                                        + "                }\n"
                                        + "            default:\n"
                                        + "                break\n"
                                        + "            }\n"
                                        + "            appendStreamerDiag(\"send FAILED kind=pastHistory circle=\\(circleId.prefix(8)) error=\\(error)\")\n"
                                        + "            throw error\n"))
        XCTAssertTrue(streamer.contains("case SendError.transportFailed, SendError.notRunning:\n"))
        XCTAssertTrue(streamer.contains("case SendError.encryptionFailed:\n"))
    }

    // MARK: - Every sealing path is gated (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The body of one `func`, by name, up to the next member declaration.
    private func body(of name: String, in src: String) -> String {
        guard let start = src.range(of: "func \(name)(") else {
            XCTFail("\(name) not found — renamed or removed")
            return ""
        }
        let rest = src[start.upperBound...]
        let ends = ["\n    /// ", "\n    func ", "\n    private func ", "\n    // MARK"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    func testLocationsAreGatedWhereEverySendConverges() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let inner = body(of: "sendInner", in: streamer)
        XCTAssertTrue(inner.contains("CircleManager.shared.holdsCurrentKey(for: circleId)"))
        XCTAssertTrue(inner.contains("throw SendError.keyNotCurrent"))
        XCTAssertTrue(inner.contains("LocationService.shared.emergencyMode"),
                      "an active SOS keeps streaming — the SOS exception")
    }

    func testEveryCircleSealingActionChecksTheKeyFirst() throws {
        let gated: [(file: String, function: String)] = [
            ("App/Managers/CheckInManager.swift", "createCheckInOverWire"),
            ("App/Managers/DestinationsManager.swift", "createDestination"),
            ("App/Managers/DestinationsManager.swift", "reportArrival"),
            ("App/Managers/AlertRulesManager.swift", "createBatteryRule"),
            ("App/Managers/AlertRulesManager.swift", "updateRule"),
            ("App/Managers/InactivityAlertsManager.swift", "createAlert"),
            ("App/Managers/PlaceManager.swift", "sharePlaceWithCircle"),
            ("App/Managers/PlaceManager.swift", "updatePlace"),
            ("App/Managers/PlaceManager.swift", "encryptAlertTarget"),
            ("App/Managers/CircleManager.swift", "updateCircle"),
        ]
        for entry in gated {
            let b = body(of: entry.function, in: try source(entry.file))
            XCTAssertTrue(b.contains("CircleManager.shared.requireCurrentKey(for:") || b.contains("try requireCurrentKey(for:"),
                          "\(entry.function) seals for a circle without checking it holds the current key")
        }
        let crossing = body(of: "reportCrossing", in: try source("App/Managers/PlaceManager.swift"))
        XCTAssertTrue(crossing.contains("guard await CircleManager.shared.holdsCurrentKeyPrimed(for: circleId) else {"),
                      "a crossing is held (and queued), not sealed under the old key")
        let primed = body(of: "holdsCurrentKeyPrimed", in: try source("App/Managers/CircleManager.swift"))
        XCTAssertTrue(primed.contains("try? await loadCircles(light: true)"),
                      "a region wake of a cold app lists the circles before judging one")
        let invite = body(of: "inviteMember", in: try source("App/Managers/CircleManager.swift"))
        XCTAssertTrue(invite.contains("holdsCurrentKey(for: circleId)"),
                      "an invite from a device that is behind must not hand over the old key")
    }

    func testSOSIsTheDocumentedException() throws {
        let sos = body(of: "triggerSOSOverWire", in: try source("App/Managers/SOSManager.swift"))
        XCTAssertFalse(sos.contains("requireCurrentKey"))
        XCTAssertTrue(sos.contains("Deliberately NOT gated"))
    }
}
