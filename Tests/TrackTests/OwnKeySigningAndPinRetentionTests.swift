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

/// Own-key signing and pin retention as the app drives them, through the real
/// SDK binding.
///
/// Own wraps: an unsigned wrap labelled "from me, to me" must never be
/// accepted without a check, or a server could install a key of its choosing
/// as our personal key or any circle's next key. So every own wrap is SIGNED:
/// the personal key when it is minted or first seen unsigned, and a circle's
/// creator wrap right after the circle exists. Pins: a sign-out that wiped
/// every member pin would re-open first contact for every member, so the pins
/// survive a same-account sign-out.
final class OwnKeySigningAndPinRetentionTests: XCTestCase {

    private let me = "b0000000-0000-4000-8000-000000000001"
    private let member = "b0000000-0000-4000-8000-000000000002"
    private let circle = "b0000000-0000-4000-8000-0000000000c1"
    private let nilUUID = "00000000-0000-0000-0000-000000000000"
    private let relayUserId = "b0000000-0000-4000-8000-0000000000ff"
    private let relayCircle = "b0000000-0000-4000-8000-0000000000fe"

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    /// Two devices of ONE account: same X25519 identity, same signing seed.
    private func twoDevicesOfOneAccount() throws -> (CryptoManager, CryptoManager) {
        let first = CryptoManager()
        let identity = first.generateKeypair()
        let signing = first.generateSigningKeypair()
        let second = CryptoManager()
        try second.importPrivateKey(privateKeyBase64: identity.privateKey)
        try second.importSigningPrivateKey(secretSeedB64: signing.secretSeedB64)
        return (first, second)
    }

    /// Someone who knows only this account's PUBLIC key: they hold a key of
    /// their own and can seal it to anyone. A circle's: the SDK wraps a
    /// personal key for its own account only, and a wrap binds no circle id,
    /// so the server serves it as the account's personal key all the same.
    private func relayHoldingAKeyOfItsOwn() throws -> CryptoManager {
        let relay = CryptoManager()
        _ = relay.generateKeypair()
        _ = relay.generateSigningKeypair()
        let creation = try relay.prepareCircleCreation()
        try relay.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: relayCircle)
        return relay
    }

    // MARK: - Own wraps: the personal key

    /// What `SelfKeyManager` publishes: a signed wrap another device of the
    /// same account accepts and verifies.
    func testASignedPersonalKeyIsAcceptedOnTheAccountsOtherDevice() throws {
        let (phone, tablet) = try twoDevicesOfOneAccount()
        let creation = try phone.prepareCircleCreation()
        let signature = try phone.signCircleCreationWrap(creation: creation, circleId: nilUUID, userId: me)
        XCTAssertEqual(signature.count, 128, "a hex Ed25519 signature")
        try phone.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: nilUUID)

        try tablet.storeCircleKey(
            circleId: nilUUID,
            encryptedKey: creation.encryptedCircleKey.nonce + creation.encryptedCircleKey.ciphertext,
            senderPublicKey: creation.ephemeralPublicKey,
            keyVersion: 1,
            senderUserId: me,
            recipientUserId: me,
            wrapSignatureHex: signature,
            senderSigningPubkeyHex: try tablet.signingPublicKeyHex()
        )
        XCTAssertTrue(tablet.hasCircleKey(circleId: nilUUID))
    }

    /// The attack signed own wraps close: a relay seals a key of ITS choosing
    /// to our public key, labels it "from me, to me", strips any signature and
    /// offers it as the next version of a personal key we already hold.
    /// Refused.
    func testAnUnsignedSelfLabelledKeyCannotReplaceTheOneWeHold() throws {
        let (phone, _) = try twoDevicesOfOneAccount()
        let mine = try phone.prepareCircleCreation()
        try phone.finalizeCircleCreation(tempCircleId: mine.tempCircleId, realCircleId: nilUUID)

        // The relay's key, wrapped to OUR public key by someone who holds only
        // that. Made as an ordinary wrap to us (sender = the relay: with
        // sender == recipient the SDK would wrap to the relay's OWN key); the
        // "from me, to me" label is what the server attaches when serving it,
        // and nothing in the ECDH wrap binds it, nor the personal key's id.
        let relay = try relayHoldingAKeyOfItsOwn()
        let forged = try relay.wrapCircleKeyForMemberFull(
            circleId: relayCircle, memberPublicKeyHex: hex(fromBase64: try phone.exportPublicKey()),
            senderUserId: relayUserId, recipientUserId: me, recipientSigningPubkeyHex: try phone.signingPublicKeyHex()
        )
        XCTAssertThrowsError(try phone.storeCircleKey(
            circleId: nilUUID,
            encryptedKey: forged.encryptedCircleKey.nonce + forged.encryptedCircleKey.ciphertext,
            senderPublicKey: forged.ephemeralPublicKey,
            keyVersion: 2,
            senderUserId: me,
            recipientUserId: me,
            wrapSignatureHex: nil,
            senderSigningPubkeyHex: try phone.signingPublicKeyHex()
        ), "an unsigned 'own' wrap must not install a new version of a key we hold")
        XCTAssertEqual(try phone.getActiveVersion(circleId: nilUUID), 1)
    }

    /// Re-signing the server's unsigned copy: the SDK signs only a wrap that
    /// opens to the key this device already holds.
    func testOnlyAWrapOfTheKeyWeHoldGetsOurSignature() throws {
        let (phone, _) = try twoDevicesOfOneAccount()
        let mine = try phone.prepareCircleCreation()
        try phone.finalizeCircleCreation(tempCircleId: mine.tempCircleId, realCircleId: nilUUID)
        let signature = try phone.signOwnCircleKeyWrap(
            circleId: nilUUID, userId: me, keyVersion: 1,
            encryptedKey: mine.encryptedCircleKey.nonce + mine.encryptedCircleKey.ciphertext,
            senderPublicKey: mine.ephemeralPublicKey
        )
        XCTAssertEqual(signature.count, 128)

        let relay = try relayHoldingAKeyOfItsOwn()
        let foreign = try relay.wrapCircleKeyForMemberFull(
            circleId: relayCircle, memberPublicKeyHex: hex(fromBase64: try phone.exportPublicKey()),
            senderUserId: relayUserId, recipientUserId: me, recipientSigningPubkeyHex: try phone.signingPublicKeyHex()
        )
        XCTAssertThrowsError(try phone.signOwnCircleKeyWrap(
            circleId: nilUUID, userId: me, keyVersion: 1,
            encryptedKey: foreign.encryptedCircleKey.nonce + foreign.encryptedCircleKey.ciphertext,
            senderPublicKey: foreign.ephemeralPublicKey
        ), "a wrap of a key we do not hold must never be signed")
    }

    // MARK: - Own wraps: call sites (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testOwnWrapsAreSignedWhereTheyAreMade() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("cryptoManager.signCircleCreationWrap("),
                      "createCircle must sign the creator's wrap once the circle id exists")
        XCTAssertTrue(circles.contains("api.signOwnCircleWrap("))
        XCTAssertTrue(circles.contains("cryptoManager.signOwnCircleKeyWrap("),
                      "an unsigned own wrap is signed on sync")
        XCTAssertFalse(circles.contains("senderUserId: response.senderUserId ?? \"\""),
                       "a wrap with no signer on record is our own slot")
        XCTAssertFalse(circles.contains("senderUserId: keyResp.senderUserId ?? \"\""))

        let selfKey = try source("App/Services/SelfKeyManager.swift")
        // Only the SDK's publishable copy is published — signed, with its
        // pseudonym, never unsigned (the SDK throws without the key).
        XCTAssertTrue(selfKey.contains("let copy = try crypto.publishablePersonalKey(heldUnder: creation.tempCircleId, userId: userId)"),
                      "a minted personal key is published signed, with its pseudonym")
        XCTAssertTrue(selfKey.contains("userPseudonym: copy.userPseudonym"))
        XCTAssertFalse(selfKey.contains("signedWrap("), "no app-side creation signing")
        XCTAssertTrue(selfKey.contains("await signServerCopyIfUnsigned(userId: userId)"),
                      "a held personal key's unsigned server copy is signed")
        // In place, on the exact bytes read (PUT with the nil circle id) — never
        // by re-POSTing old bytes, which could replace a newer key.
        XCTAssertTrue(selfKey.contains("api.signOwnCircleWrap(\n                circleId: selfCircleUuid,"))
    }

    // MARK: - Removed members and failed rotations: call sites

    func testRemovedMembersLoseTheirPinsAndFailedRotationsAreDiscarded() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("cryptoManager.retainMemberPins(circleId: circleId, memberUserIds: Array(keepIds))"))
        // A rotation plan refuses unless its OWN roster fetch retired the pins,
        // and the plan runs before prepareKeyRotation on both paths.
        XCTAssertTrue(circles.contains("guard let retained = pinsRetainedAt[circle.id], retained >= planStartedAt else {"))
        for anchor in ["let (plan, keysById, blocked) = try await planRotation(for: circle, rotatorUserId: senderUserId)",
                       "let (plan, keysById, blocked) = try await planRotation(\n            for: circle, rotatorUserId: senderUserId, ejecting: userId"] {
            let plan = try XCTUnwrap(circles.range(of: anchor), "plan call missing: \(anchor)")
            let prepare = try XCTUnwrap(circles.range(of: "cryptoManager.prepareKeyRotation(", range: plan.upperBound..<circles.endIndex))
            XCTAssertLessThan(plan.lowerBound, prepare.lowerBound)
        }
        XCTAssertEqual(circles.components(separatedBy: "cryptoManager.discardUnconfirmedRotation(circleId: circleId)").count - 1, 2,
                       "both the rotate and the eject failure paths must drop our unconfirmed key")
    }

    /// No path regenerates the signing key; `SigningKeyRotationTests` pins
    /// that none exists.
    func testNoPathRegeneratesTheSigningKey() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertFalse(auth.contains("api.regenerateSigningKey("))
        XCTAssertFalse(auth.contains("cryptoManager.generateSigningKeypair()"),
                       "never the installing generator: it persists the seed before the server accepts it")
    }

    /// A deliberate sign-out ends the session on the server BEFORE the keychain
    /// wipe takes the token that ends it: the server revokes it and drops its
    /// push registrations, so the device id the next sign-in mints never leaves
    /// an old registration delivering every push twice. Never for a deleted
    /// account, whose sessions are gone already; and it never waits longer than
    /// a few seconds on a network that is not there.
    func testASignOutEndsTheServerSessionBeforeTheWipe() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("try await post(path: Self.logoutPath, body: LogoutRequest(refreshToken: refreshToken),"))
        XCTAssertTrue(api.contains(#"nonisolated static let logoutPath = "/api/v1/auth/logout""#))
        let logout = try XCTUnwrap(auth.range(of: "func logout(retainingTrust: Bool = true) async {"))
        let end = try XCTUnwrap(auth.range(of: "if retainingTrust { await endServerSession() }", range: logout.upperBound..<auth.endIndex))
        let wipe = try XCTUnwrap(auth.range(of: "keychain.deleteAll()", range: logout.upperBound..<auth.endIndex))
        XCTAssertLessThan(end.lowerBound, wipe.lowerBound, "ended while the token is still there")
        XCTAssertTrue(auth.contains("group.addTask { _ = try? await APIService.shared.logout(refreshToken: refreshToken) }"),
                      "named by its refresh token too (SignOutEndsTheSessionTests)")
        XCTAssertTrue(auth.contains("group.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000) }"),
                      "a sign-out offline waits four seconds at most")
        // A sign-in marks an unbound device before it writes anything.
        let complete = try XCTUnwrap(auth.range(of: "private func completeLogin(accessToken: String, refreshToken: String, password: String,"))
        let note = try XCTUnwrap(auth.range(of: "KeyDeliveryApprovals.noteSignInStarting()", range: complete.upperBound..<auth.endIndex))
        let firstWrite = try XCTUnwrap(auth.range(of: "try keychain.save(accessToken, for: .accessToken)", range: complete.upperBound..<auth.endIndex))
        XCTAssertLessThan(note.lowerBound, firstWrite.lowerBound)
    }

    func testAnUnreadableKeychainIsNotReportedAsEmpty() throws {
        let callback = try source("App/Services/KeychainKeyStorageCallback.swift")
        XCTAssertTrue(callback.contains("if status == errSecItemNotFound { return nil }"))
        XCTAssertTrue(callback.contains("guard status == errSecSuccess else { throw KeychainKeyStorageError.osStatus(status) }"))
        let sdk = try source("App/Services/SDKCrypto.swift")
        XCTAssertTrue(sdk.contains("UIApplication.protectedDataDidBecomeAvailableNotification"))
    }

    // MARK: - Pins survive a same-account sign-out

    func testPinsSurviveASignOutForTheSameAccountOnly() throws {
        defer { RetainedMemberPins.deleteAll(except: nil) }
        let before = CryptoManager()
        _ = before.generateKeypair()
        _ = before.generateSigningKeypair()
        let memberDevice = CryptoManager()
        let memberSharing = hex(fromBase64: memberDevice.generateKeypair().publicKey)
        let memberSigning = hex(fromBase64: memberDevice.generateSigningKeypair().verifyingKeyB64)
        _ = try before.pinMemberKeys(circleId: circle, userId: member,
                                     sharingPubkeyHex: memberSharing, signingPubkeyHex: memberSigning)

        // Sign-out: export, then the wipe.
        XCTAssertTrue(RetainedMemberPins.retain(owner: me, crypto: before))
        before.clearAllKeys()
        XCTAssertNil(before.pinnedSharingKey(circleId: circle, userId: member))

        // Another account signing in takes nothing of ours. Our blob stays:
        // only its sign-in's guarded tidy takes it (`SignInTidy`).
        let stranger = CryptoManager()
        XCTAssertEqual(RetainedMemberPins.restore(owner: member, crypto: stranger), 0)
        XCTAssertNil(stranger.pinnedSharingKey(circleId: circle, userId: member))
        XCTAssertNotNil(RetainedMemberPins.read(account: me), "another account's sign-in keeps it")
        RetainedMemberPins.forget(owner: me.uppercased())
        XCTAssertNil(RetainedMemberPins.read(account: me), "the tidy takes it in any case")

        // Same account, same device, later: the pins come back.
        XCTAssertTrue(RetainedMemberPins.retain(owner: me, crypto: {
            let again = CryptoManager()
            _ = again.generateKeypair()
            _ = try? again.pinMemberKeys(circleId: circle, userId: member,
                                         sharingPubkeyHex: memberSharing, signingPubkeyHex: memberSigning)
            return again
        }()))
        let after = CryptoManager()
        _ = after.generateKeypair()
        XCTAssertGreaterThan(RetainedMemberPins.restore(owner: me, crypto: after), 0)
        XCTAssertEqual(after.pinnedSharingKey(circleId: circle, userId: member), memberSharing,
                       "the member is recognised, not first contact")
        XCTAssertNil(RetainedMemberPins.read(account: me), "a restored blob is consumed")

        // A key substituted after the sign-out raises the alarm instead of
        // being trusted on first use.
        let substitute = hex(fromBase64: CryptoManager().generateKeypair().publicKey)
        let result = try after.pinMemberKeys(circleId: circle, userId: member,
                                             sharingPubkeyHex: substitute, signingPubkeyHex: memberSigning)
        XCTAssertEqual(result.state, .changedSharing)
    }

    func testVerifiedMarksFollowTheSameRule() {
        defer { MemberVerificationStore.clearAll() }
        MemberVerificationStore.clearAll()
        MemberVerificationStore.adopt(owner: me)
        MemberVerificationStore.setVerified(circleId: circle, userId: member)

        MemberVerificationStore.adopt(owner: me)
        XCTAssertNotNil(MemberVerificationStore.verifiedAt(circleId: circle, userId: member),
                        "the same account signing back in keeps its marks")

        MemberVerificationStore.adopt(owner: member)
        XCTAssertNil(MemberVerificationStore.verifiedAt(circleId: circle, userId: member),
                     "a different account never inherits a mark")
    }

    func testSignOutKeepsMarksOnlyWhenPinsWereKept() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("RetainedMemberPins.retain(owner: userId, crypto: cryptoManager)"))
        XCTAssertTrue(auth.contains("MemberVerificationStore.adopt(owner: me)"))
        XCTAssertTrue(auth.contains("RetainedMemberPins.restore(owner: me, crypto: cryptoManager)"))
        XCTAssertTrue(auth.contains("await logout(retainingTrust: false)"),
                      "a deleted account keeps nothing")
        // The restore must come before anything touches circle keys or the roster.
        let restore = try XCTUnwrap(auth.range(of: "RetainedMemberPins.restore(owner: me"))
        let selfKey = try XCTUnwrap(auth.range(of: "await SelfKeyManager.ensure()\n\n        // Register this device"))
        XCTAssertLessThan(restore.lowerBound, selfKey.lowerBound)
    }
}
