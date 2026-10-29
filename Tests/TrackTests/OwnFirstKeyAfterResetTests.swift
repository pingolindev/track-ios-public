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
import Sodium
import PingolinTrackSDK
@testable import Track

/// This account's OWN signed copy of a circle key is taken through
/// `storeFirstCircleKey` (current key, with its name check), and ONLY when
/// that refuses it with SignatureInvalid through `storeCircleKey`, where a
/// copy signed before an email reset is taken once a restored identity (the
/// auth server's v2 previous-identity blob) opens and verifies it. Real SDK,
/// real keys; the v2 blob is sealed here the way the portal does (libsodium).
final class OwnFirstKeyAfterResetTests: XCTestCase {

    private let me = UUID().uuidString.lowercased()

    /// One identity of this account on its own device: keys and a CryptoManager.
    private struct Identity {
        let sdk = CryptoManager()
        let sharing: KeyPair
        let signing: SigningKeyPair
        init() {
            sharing = sdk.generateKeypair()
            signing = sdk.generateSigningKeypair()
        }
        var signingHex: String { try! sdk.signingPublicKeyHex() }

        /// The same identity on a second device (which holds no circle key).
        func secondDevice() throws -> CryptoManager {
            let other = CryptoManager()
            try other.importPrivateKey(privateKeyBase64: sharing.privateKey)
            try other.importSigningPrivateKey(secretSeedB64: signing.secretSeedB64)
            return other
        }
    }

    /// A circle created by `creator`, with its own copy of the key signed by it,
    /// and the circle's name sealed under that key.
    private struct OwnCopy {
        let circleId: String
        let encryptedKey: String
        let ephemeral: String
        let signature: String
        let name: EncryptedData
    }

    private func ownCircle(by creator: Identity) throws -> OwnCopy {
        let circleId = UUID().uuidString.lowercased()
        let creation = try creator.sdk.prepareCircleCreation()
        try creator.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        let signature = try creator.sdk.signCircleCreationWrap(creation: creation, circleId: circleId, userId: me)
        let name = try creator.sdk.encryptDataV2(circleId: circleId, plaintext: "Family", fieldTag: "name")
        return OwnCopy(circleId: circleId,
                       encryptedKey: creation.encryptedCircleKey.nonce + creation.encryptedCircleKey.ciphertext,
                       ephemeral: creation.ephemeralPublicKey, signature: signature, name: name)
    }

    /// The auth server's previous-identity blob: the OLD sharing private key,
    /// then (v2) the OLD signing public key, in crypto_secretbox_easy under
    /// crypto_generichash(32, message: the CURRENT sharing private key,
    /// key: "pingolin.previous-identity").
    private func sealed(_ old: Identity, for current: Identity, v2: Bool) throws -> SealedPreviousIdentity {
        let sodium = Sodium()
        let currentKey = [UInt8](try XCTUnwrap(Data(base64Encoded: current.sharing.privateKey)))
        let wrap = try XCTUnwrap(sodium.genericHash.hash(message: currentKey, key: Array("pingolin.previous-identity".utf8),
                                                         outputLength: 32))
        var plain = [UInt8](try XCTUnwrap(Data(base64Encoded: old.sharing.privateKey)))
        if v2 { plain += [UInt8](try XCTUnwrap(Data(base64Encoded: old.signing.verifyingKeyB64))) }
        let box: (authenticatedCipherText: Bytes, nonce: SecretBox.Nonce) = try XCTUnwrap(
            sodium.secretBox.seal(message: plain, secretKey: wrap))
        return SealedPreviousIdentity(nonce: Data(box.nonce).base64EncodedString(),
                                      ciphertext: Data(box.authenticatedCipherText).base64EncodedString())
    }

    private func store(_ copy: OwnCopy, on device: CryptoManager, signature: String? = nil,
                       name: EncryptedData? = nil) throws {
        try Track.CircleManager.storeOwnFirstKey(
            crypto: device, circleId: copy.circleId, encryptedKey: copy.encryptedKey, senderPublicKey: copy.ephemeral,
            keyVersion: 1, me: me, wrapSignatureHex: signature ?? copy.signature,
            currentSigningKeyHex: try device.signingPublicKeyHex(), sealedCircleName: name ?? copy.name)
    }

    /// The owner's own circle, signed before an email reset, on the device
    /// after it: the reset state first (DecryptionFailed, never
    /// SignatureInvalid), and once the v2 blob is imported it is stored and
    /// marked as having come through the old identity, which triggers the
    /// rotation step.
    func testAnOwnCopySignedBeforeTheResetOpensOnceV2IsRestored() throws {
        let (old, current) = (Identity(), Identity())
        let copy = try ownCircle(by: old)

        XCTAssertThrowsError(try store(copy, on: current.sdk)) { error in
            guard case .DecryptionFailed? = error as? MobileError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(current.sdk.hasCircleKey(circleId: copy.circleId))
        XCTAssertEqual(Track.CircleManager.lockReason(
            deviceHasAccountKeys: true, hasWrapForUs: true, wrapRefused: false, wrapFailedToOpen: true,
            holdsSomeKey: false, accountHasPreResetData: true, previousReason: nil), .sealedBeforeReset,
            "DecryptionFailed is an unopened copy: the reset state, which looks for a restored identity")

        XCTAssertEqual(try current.sdk.importPreviousIdentitiesV2(sealed: [try sealed(old, for: current, v2: true)]), 1)
        try store(copy, on: current.sdk)
        XCTAssertTrue(current.sdk.hasCircleKey(circleId: copy.circleId))
        XCTAssertEqual(try current.sdk.decryptDataV2(circleId: copy.circleId, encryptedData: copy.name, fieldTag: "name"),
                       "Family")
        XCTAssertTrue(current.sdk.activeKeyCameViaPreviousIdentity(circleId: copy.circleId), "the rotation step's trigger")
        XCTAssertTrue(Track.CircleManager.rotationStepDue(cameViaPreviousIdentity: true, takenOnTrust: false, mayRotate: true))
    }

    /// v1 only: the old identity opens it, but no signing key it holds
    /// verifies it: refused.
    func testAV1OnlyRestoreIsRefused() throws {
        let (old, current) = (Identity(), Identity())
        let copy = try ownCircle(by: old)
        XCTAssertEqual(try current.sdk.importPreviousIdentitiesV2(sealed: [try sealed(old, for: current, v2: false)]), 1)
        XCTAssertThrowsError(try store(copy, on: current.sdk)) { error in
            guard case .SignatureInvalid? = error as? MobileError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(current.sdk.hasCircleKey(circleId: copy.circleId))
    }

    /// A copy for the CURRENT identity with a bad signature is still refused
    /// by the fallback, and nothing is stored.
    func testACurrentIdentityCopyWithABadSignatureIsStillRefused() throws {
        let current = Identity()
        let copy = try ownCircle(by: current)
        var bytes = Array(copy.signature)
        bytes[0] = bytes[0] == "0" ? "1" : "0"
        let otherDevice = try current.secondDevice()
        XCTAssertThrowsError(try store(copy, on: otherDevice, signature: String(bytes))) { error in
            guard case .SignatureInvalid? = error as? MobileError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(otherDevice.hasCircleKey(circleId: copy.circleId))
    }

    /// A copy signed with the CURRENT key still goes through
    /// `storeFirstCircleKey` WITH the name check: a name sealed under another
    /// key refuses it, and the fallback is not tried.
    func testACurrentKeyCopyKeepsTheNameCheck() throws {
        let current = Identity()
        let copy = try ownCircle(by: current)
        let elsewhere = try ownCircle(by: current)
        let otherDevice = try current.secondDevice()
        XCTAssertThrowsError(try store(copy, on: otherDevice, name: elsewhere.name)) { error in
            guard case .DecryptionFailed? = error as? MobileError else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(otherDevice.hasCircleKey(circleId: copy.circleId))
        try store(copy, on: otherDevice)
        XCTAssertTrue(otherDevice.hasCircleKey(circleId: copy.circleId))
        XCTAssertFalse(otherDevice.activeKeyCameViaPreviousIdentity(circleId: copy.circleId))
    }

    /// The personal key after a reset: the old copy opens only through the
    /// restored identity and is kept RETIRED, never in use, which is exactly
    /// when a new personal key is minted.
    func testAnOldPersonalCopyIsKeptRetiredAndSupersededByTheReset() throws {
        let (old, current) = (Identity(), Identity())
        let creation = try old.sdk.prepareCircleCreation()
        let copy = try old.sdk.publishablePersonalKey(heldUnder: creation.tempCircleId, userId: me)
        try old.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: SelfKeyManager.selfCircleUuid)
        let history = try old.sdk.encryptDataV2(circleId: SelfKeyManager.selfCircleUuid, plaintext: "home", fieldTag: "name")
        let encryptedKey = copy.encryptedKey.nonce + copy.encryptedKey.ciphertext
        func take() throws {
            try current.sdk.storeCircleKey(
                circleId: SelfKeyManager.selfCircleUuid, encryptedKey: encryptedKey,
                senderPublicKey: copy.ephemeralPublicKey, keyVersion: 1, senderUserId: me, recipientUserId: me,
                wrapSignatureHex: copy.wrapSignature, senderSigningPubkeyHex: try current.sdk.signingPublicKeyHex())
        }
        XCTAssertThrowsError(try take(), "before the restore: the reset state")
        XCTAssertFalse(current.sdk.personalCopySupersededByReset(encryptedKey: encryptedKey,
                                                                 senderPublicKey: copy.ephemeralPublicKey))

        _ = try current.sdk.importPreviousIdentitiesV2(sealed: [try sealed(old, for: current, v2: true)])
        try take()
        try take()
        XCTAssertTrue(current.sdk.hasCircleKey(circleId: SelfKeyManager.selfCircleUuid), "held, for old history")
        XCTAssertEqual(try current.sdk.decryptDataV2(circleId: SelfKeyManager.selfCircleUuid, encryptedData: history,
                                                     fieldTag: "name"), "home")
        XCTAssertFalse(SelfKeyManager.personalKeyInUse(current.sdk), "retired, never in use")
        XCTAssertTrue(current.sdk.personalCopySupersededByReset(encryptedKey: encryptedKey,
                                                                senderPublicKey: copy.ephemeralPublicKey))

        // The personal-key mint puts a new key in use beside the retired one;
        // then there is nothing more to mint, and the old history still reads.
        let mint = try current.sdk.prepareCircleCreation()
        _ = try current.sdk.publishablePersonalKey(heldUnder: mint.tempCircleId, userId: me)
        try current.sdk.finalizeCircleCreation(tempCircleId: mint.tempCircleId, realCircleId: SelfKeyManager.selfCircleUuid)
        XCTAssertTrue(SelfKeyManager.personalKeyInUse(current.sdk))
        XCTAssertFalse(current.sdk.personalCopySupersededByReset(encryptedKey: encryptedKey,
                                                                 senderPublicKey: copy.ephemeralPublicKey))
        XCTAssertEqual(try current.sdk.decryptDataV2(circleId: SelfKeyManager.selfCircleUuid, encryptedData: history,
                                                     fieldTag: "name"), "home")

        // The wiring: that is what sends SelfKeyManager to mint, replacing the
        // server's copy; otherwise it keeps the copy.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Services/SelfKeyManager.swift"), encoding: .utf8)
        XCTAssertTrue(manager.contains("supersededByReset = crypto.personalCopySupersededByReset(\n                    encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,"))
        XCTAssertTrue(manager.contains("if !supersededByReset {"))
        XCTAssertTrue(manager.contains("replace: supersededByReset ? true : nil"))
        // A slot holding only the retired key is no personal key in use, so a
        // later pass (after a failed publish, or a restart) still mints.
        XCTAssertTrue(manager.contains("private static func ensureOnce(mayReplace: Bool) async -> Bool {\n        if personalKeyInUse(crypto) {"))
        XCTAssertTrue(manager.contains("crypto.hasCircleKeyInUse(circleId: selfCircleUuid)"))
        // A restore in the portal looks at the personal copy again, without a
        // restart.
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("onOpened: {\n            try? await CircleManager.shared.loadCircles()\n"))
        XCTAssertTrue(circles.contains("if !SelfKeyManager.personalKeyInUse(SDKCrypto.cryptoManager) {\n                await SelfKeyManager.ensure(mayReplace: false)\n            }"))
    }

    /// The personal slot's gates: what SEALS, wraps or mints needs a key in
    /// use; what READS keeps `hasCircleKey`, so a slot holding only the
    /// retired key still opens old rows (the data export) and still runs the
    /// adoption check that brings the account's new key.
    func testWritesNeedAKeyInUseReadsDoNot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let writes = [
            ("App/Services/DeviceRegistrar.swift", "guard SelfKeyManager.personalKeyInUse(crypto) else {"),
            ("App/Managers/PlaceManager.swift", "guard SelfKeyManager.personalKeyInUse(cryptoManager) else {"),
            // Variable ids that can name the personal slot.
            ("App/Managers/PlaceManager.swift", "guard holdsKeyInUse(circleId) else {"),
            ("App/Managers/PlaceManager.swift", "guard holdsKeyInUse(place.circleId) else {"),
            ("App/Managers/PlaceManager.swift", "cryptoManager.hasCircleKeyInUse(circleId: circleId)"),
            ("App/Services/SelfKeyManager.swift", "if personalKeyInUse(crypto) {"),
        ]
        for (path, gate) in writes {
            XCTAssertTrue(try source(path).contains(gate), "\(path): a write needs a key in use")
        }
        let reads = [
            ("App/Services/DataExportService.swift", "if crypto.hasCircleKey(circleId: Self.selfCircleUUID) {"),
            ("App/Services/DataExportService.swift", "crypto.hasCircleKey(circleId: Self.selfCircleUUID) {\n            // A populated wrap"),
            ("App/Managers/PushNotificationManager.swift", "SDKCrypto.cryptoManager.hasCircleKey(circleId: SelfKeyManager.selfCircleUuid) {"),
            ("App/Services/HeadlessTrackingResume.swift", "guard !crypto.hasCircleKey(circleId: SelfKeyManager.selfCircleUuid) else { return }"),
        ]
        for (path, gate) in reads {
            XCTAssertTrue(try source(path).contains(gate), "\(path): a read keeps hasCircleKey")
        }
    }

    /// The rotation step: due on an owner's or admin's device whose active key
    /// came through a restored identity or was taken on trust; seals wait for
    /// it; the sweep runs it; the own-wrap signing never signs a key taken on
    /// trust.
    func testTheRotationStepRunsFirstAndSealsWait() throws {
        typealias C = Track.CircleManager
        XCTAssertTrue(C.rotationStepDue(cameViaPreviousIdentity: true, takenOnTrust: false, mayRotate: true))
        XCTAssertTrue(C.rotationStepDue(cameViaPreviousIdentity: false, takenOnTrust: true, mayRotate: true))
        XCTAssertFalse(C.rotationStepDue(cameViaPreviousIdentity: true, takenOnTrust: true, mayRotate: false),
                       "a plain member waits for someone who may rotate")
        XCTAssertFalse(C.rotationStepDue(cameViaPreviousIdentity: false, takenOnTrust: false, mayRotate: true))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("Self.holdsCurrentKey(currentVersion: holdsCurrentVersion(for: circleId),\n"
                                       + "                             rotationStepDue: rotationStepPending(circleId), behind: isBehind(circleId))"),
                      "nothing new is sealed or delivered before the step")
        XCTAssertFalse(C.holdsCurrentKey(currentVersion: true, rotationStepDue: true, behind: false))
        XCTAssertTrue(circles.contains("|| rotationStepPending($0.id) || recordedRotationDue($0))\n"
                                       + "                && !nameHoldsBack($0, due: repairsDue[CanonicalId.key($0.id)]) && holdsWhatItRotates($0)"),
                      "the sweep runs it, on the version alone")
        XCTAssertTrue(circles.contains("        return holdsCurrentVersion(for: circle.id)\n    }\n\n"
                                       + "    /// Pure, for tests: whether this device holds what a repair needs."),
                      "every rotation but a repair needs the current version")
        XCTAssertTrue(circles.contains("return !circle.keyRotationNeeded && !rotationStepPending(circleId)"))
        XCTAssertTrue(circles.contains("cameViaPreviousIdentity: cryptoManager.activeKeyCameViaPreviousIdentity(circleId: circleId),\n            takenOnTrust: cryptoManager.activeKeyTakenOnTrust(circleId: circleId),\n            mayRotate: isOwnerOrAdmin(circle) && mayRotate(circle)\n                && !selfIsReceiveOnly(circleId))"),
                      "due only where rotateCircleKey rotates, so nothing waits for a rotation that never comes")
        XCTAssertTrue(circles.contains("if plan.skip && !rotationStepPending(circleId) && !recordedRotationDue(circle) {"),
                      "a keyless join's skip never cancels the step")
        let s1 = try XCTUnwrap(circles.range(of: "private func signOwnUnsignedWraps("))
        let body = circles[s1.upperBound...].prefix(2_000)
        let skip = try XCTUnwrap(body.range(of: "if cryptoManager.circleKeyTakenOnTrust(circleId: response.id, keyVersion: Int32(version)) {"))
        let sign = try XCTUnwrap(body.range(of: "let signature = try cryptoManager.signOwnCircleKeyWrap("))
        XCTAssertLessThan(skip.lowerBound, sign.lowerBound)
    }

    /// The wiring: only our own copy goes through the fallback, and only on
    /// SignatureInvalid; every other sender keeps `storeFirstCircleKey` alone.
    func testOnlyOurOwnCopyFallsBack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("                            if senderIsMe {\n                                try Self.storeOwnFirstKey("))
        let helper = try XCTUnwrap(circles.range(of: "nonisolated static func storeOwnFirstKey("))
        let body = circles[helper.upperBound...].prefix(1_200)
        XCTAssertTrue(body.contains("} catch MobileError.SignatureInvalid(_) {"))
        XCTAssertTrue(body.contains("keyVersion: keyVersion, senderUserId: me, recipientUserId: me,\n                wrapSignatureHex: wrapSignatureHex, senderSigningPubkeyHex: nil)"),
                      "sender and recipient us, the same signature, no signer hint")
    }

    /// As on Android and the web: the admission a waiting "Let them in" signs
    /// after the reset (the late joiner's question, "It's them" for a member
    /// the chain doesn't count) verifies under this account's CURRENT signing
    /// key, never under the restored one, whatever the SDK holds.
    func testALetInAdmissionAfterTheResetVerifiesOnlyUnderTheCurrentKey() throws {
        let (old, current, member) = (Identity(), Identity(), Identity())
        XCTAssertEqual(try current.sdk.importPreviousIdentitiesV2(sealed: [try sealed(old, for: current, v2: true)]), 1)
        XCTAssertEqual(current.sdk.previousSigningPublicKeys(), [old.signingHex.lowercased()], "the restored key is held")
        let circleId = UUID().uuidString.lowercased()
        let creation = try current.sdk.prepareCircleCreation()
        try current.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        let sharing = try XCTUnwrap(Data(base64Encoded: member.sharing.publicKey)).map { String(format: "%02x", $0) }.joined()
        // The run's call (`admitWaiting`), for the keys the question showed.
        let signed = try current.sdk.signMembershipAdmission(
            circleId: circleId, signerUserId: me, subjectUserId: UUID().uuidString.lowercased(),
            subjectSharingPublicKeyHex: sharing, subjectSigningPublicKeyHex: member.signingHex)
        XCTAssertTrue(try current.sdk.verify(statementHex: signed.statementHex, signatureHex: signed.signatureHex,
                                             signerKeyHex: current.signingHex))
        XCTAssertFalse((try? current.sdk.verify(statementHex: signed.statementHex, signatureHex: signed.signatureHex,
                                                signerKeyHex: old.signingHex)) == true, "never the restored key")
        XCTAssertEqual(current.sdk.ownSigner(statementHex: signed.statementHex, signatureHex: signed.signatureHex), .currentKey)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let run = try XCTUnwrap(circles.range(of: "    func admitWaiting(_ change: PendingChange, userId: String, circleId: String, keys: MemberKeyPair) async throws {"))
        XCTAssertTrue(circles[run.upperBound...].prefix(700).contains(
            "        let signed = try cryptoManager.signMembershipAdmission(\n"
            + "            circleId: circleId, signerUserId: me, subjectUserId: userId,\n"
            + "            subjectSharingPublicKeyHex: keys.sharingKeyHex, subjectSigningPublicKeyHex: keys.signingKeyHex)\n"),
            "that is the call the run makes")
    }
}
