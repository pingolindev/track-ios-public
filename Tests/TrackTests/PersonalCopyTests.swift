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

/// Personal history repairs itself, without asking anyone to sign out and back
/// in or to repair their other devices.
///
/// The rule lives in the SDK: `checkPersonalKeyAdoption` judges the account's
/// published copy against the recorded pseudonym and this account's OWN signing
/// key, and `adoptPersonalKey` adds it without deleting the key held before. The
/// app only acts on the verdict: adopt, flag "can't open it" (only on
/// CannotOpen/Unsigned), republish its own key when the copy does not open here
/// (hourly, signed, never a mint), or show the password field. These pin that
/// mapping, and run the real SDK across two "devices" of one account.
final class PersonalCopyTests: XCTestCase {

    private let userId = "0b8e7d6c-5a4b-4c3d-9e2f-1a0b9c8d7e6f"
    private let personal = SelfKeyManager.selfCircleUuid

    // MARK: - What each verdict makes this device do

    func testEachVerdictMeansOneThing() {
        let expected: [(PersonalKeyVerdict, SelfKeyManager.CopyAction)] = [
            (.adopt, .adopt),
            (.ownCopyMatches, .none),
            (.tooSoon, .none),
            (.nothingRecorded, .none),
            (.unsigned, .flag),
            (.cannotOpen, .flag),
            (.noSigningKey, .askForPassword),
            (.retiredKey, .log),
            (.signatureInvalid, .log),
            (.pseudonymMismatch, .log),
            (.newerVersionHeld, .log),
            (.malformed, .log),
        ]
        for (verdict, action) in expected {
            XCTAssertEqual(SelfKeyManager.action(for: verdict), action, "\(verdict)")
        }
    }

    /// Only CannotOpen and Unsigned raise the flag. PseudonymMismatch only
    /// means another device sent last; a bad signature is a key someone else
    /// chose — refused, never reported as "can't open it".
    func testOnlyTwoVerdictsRaiseTheFlag() {
        let all: [PersonalKeyVerdict] = [.adopt, .ownCopyMatches, .retiredKey, .nothingRecorded, .noSigningKey,
                                         .unsigned, .signatureInvalid, .cannotOpen, .pseudonymMismatch,
                                         .newerVersionHeld, .tooSoon, .malformed]
        XCTAssertEqual(all.filter { SelfKeyManager.action(for: $0) == .flag }, [.unsigned, .cannotOpen])
    }

    func testARepublishWaitsAnHour() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(SelfKeyManager.mayRepublish(lastAt: nil, now: now))
        XCTAssertFalse(SelfKeyManager.mayRepublish(lastAt: now.addingTimeInterval(-59 * 60), now: now))
        XCTAssertTrue(SelfKeyManager.mayRepublish(lastAt: now.addingTimeInterval(-60 * 60), now: now))
    }

    /// The flag goes once per distinct copy: the digest is of the bytes.
    func testTheFlagIsPerDistinctCopy() throws {
        func bundle(_ ciphertext: String) throws -> CircleKeyBundleResponse {
            let json = """
            {"circle_id":"\(personal)","encrypted_circle_key":{"nonce":"AA","ciphertext":"\(ciphertext)"},
             "ephemeral_public_key":"bb","key_version":1,"user_pseudonym":"p","republish_requested":true}
            """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(CircleKeyBundleResponse.self, from: Data(json.utf8))
        }
        let one = try bundle("cc"), again = try bundle("CC"), other = try bundle("dd")
        XCTAssertEqual(SelfKeyManager.copyDigest(one), SelfKeyManager.copyDigest(again), "hex case is not a new copy")
        XCTAssertNotEqual(SelfKeyManager.copyDigest(one), SelfKeyManager.copyDigest(other))
        // The server's copy_sha256: sha256 over the RAW bytes
        // encrypted_self_key ‖ nonce ‖ ephemeral_public_key = 0xcc ‖ 0xaa ‖ 0xbb.
        XCTAssertEqual(SelfKeyManager.copyDigest(one),
                       "017e10290f4bae98482c373021a113bfdb70f3403576b127fcca2ed17a4d6425")
        XCTAssertEqual(one.userPseudonym, "p")
        XCTAssertEqual(one.republishRequested, true)
    }

    // MARK: - The real SDK across two devices of one account

    /// Two devices of one account: the same account keys (they come from the
    /// password), each with its own personal key — the divergence that two
    /// first-launch mints leave, and that adoption repairs.
    private func device(account: KeyPair, signing: SigningKeyPair) throws -> CryptoManager {
        let crypto = CryptoManager()
        try crypto.importPrivateKey(privateKeyBase64: account.privateKey)
        try crypto.importSigningPrivateKey(secretSeedB64: signing.secretSeedB64)
        let creation = try crypto.prepareCircleCreation()
        try crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: personal)
        return crypto
    }

    private func check(_ crypto: CryptoManager, _ copy: PublishablePersonalKey,
                       signature: String?? = .none) -> PersonalKeyVerdict {
        crypto.checkPersonalKeyAdoption(
            userId: userId, encryptedKey: copy.encryptedKey.nonce + copy.encryptedKey.ciphertext,
            senderPublicKey: copy.ephemeralPublicKey, keyVersion: copy.keyVersion,
            wrapSignatureHex: signature ?? copy.wrapSignature, recordedPseudonym: copy.userPseudonym)
    }

    func testTheAccountsPublishedCopyIsAdoptedAndNothingIsLost() throws {
        let seed = CryptoManager()
        let account = seed.generateKeypair(), signing = seed.generateSigningKeypair()
        let a = try device(account: account, signing: signing)
        let b = try device(account: account, signing: signing)

        // A publishes its key (what the server now holds, with its pseudonym).
        let published = try a.publishablePersonalKey(heldUnder: personal, userId: userId)
        XCTAssertFalse(published.wrapSignature.isEmpty, "a publishable copy is always signed")
        XCTAssertEqual(check(a, published), .ownCopyMatches, "the publisher has nothing to adopt")

        // B holds another key: it takes A's, and keeps its own readable.
        let before = try b.deriveUserPseudonymsAllVersions(circleId: personal, userId: userId)
        XCTAssertEqual(check(b, published), .adopt)
        XCTAssertEqual(try b.adoptPersonalKey(
            userId: userId, encryptedKey: published.encryptedKey.nonce + published.encryptedKey.ciphertext,
            senderPublicKey: published.ephemeralPublicKey, keyVersion: published.keyVersion,
            wrapSignatureHex: published.wrapSignature, recordedPseudonym: published.userPseudonym), .adopt)
        XCTAssertEqual(check(b, published), .ownCopyMatches, "now in use here")
        let after = try b.deriveUserPseudonymsAllVersions(circleId: personal, userId: userId)
        XCTAssertTrue(after.contains(published.userPseudonym))
        XCTAssertTrue(Set(before).isSubset(of: Set(after)), "the key held before is retired, not deleted")

        // An unsigned copy of the same key is never adopted: it is flagged.
        let c = try device(account: account, signing: signing)
        XCTAssertEqual(check(c, published, signature: .some(nil)), .unsigned)
        XCTAssertEqual(SelfKeyManager.action(for: .unsigned), .flag)
    }

    /// The pseudonym the record repair sends, derived directly, is exactly the
    /// one a publishable copy of the same key carries — and after an adoption,
    /// the one of the key now in use.
    func testTheDerivedPseudonymIsThePublishedCopys() throws {
        let seed = CryptoManager()
        let account = seed.generateKeypair(), signing = seed.generateSigningKeypair()
        let a = try device(account: account, signing: signing)
        let b = try device(account: account, signing: signing)
        let published = try a.publishablePersonalKey(heldUnder: personal, userId: userId)
        XCTAssertEqual(try a.deriveUserPseudonym(circleId: personal, userId: userId), published.userPseudonym)
        XCTAssertNotEqual(try b.deriveUserPseudonym(circleId: personal, userId: userId), published.userPseudonym)
        _ = try b.adoptPersonalKey(
            userId: userId, encryptedKey: published.encryptedKey.nonce + published.encryptedKey.ciphertext,
            senderPublicKey: published.ephemeralPublicKey, keyVersion: published.keyVersion,
            wrapSignatureHex: published.wrapSignature, recordedPseudonym: published.userPseudonym)
        XCTAssertEqual(try b.deriveUserPseudonym(circleId: personal, userId: userId), published.userPseudonym)
    }

    /// A copy signed by some OTHER key is a key someone else chose: refused,
    /// and not "can't open it" — no flag, and never minted over.
    func testACopySomeoneElseChoseIsRefused() throws {
        let seed = CryptoManager()
        let account = seed.generateKeypair(), signing = seed.generateSigningKeypair()
        let b = try device(account: account, signing: signing)
        let forger = try device(account: account, signing: seed.generateSigningKeypair())
        let forged = try forger.publishablePersonalKey(heldUnder: personal, userId: userId)
        XCTAssertEqual(check(b, forged), .signatureInvalid)
        XCTAssertEqual(SelfKeyManager.action(for: .signatureInvalid), .log)
    }

    /// A copy wrapped for other account keys cannot be opened here: flagged, so
    /// the device that holds the key republishes it for the current keys.
    func testACopyForOtherAccountKeysIsReported() throws {
        let seed = CryptoManager()
        let signing = seed.generateSigningKeypair()
        let here = try device(account: seed.generateKeypair(), signing: signing)
        let elsewhere = try device(account: CryptoManager().generateKeypair(), signing: signing)
        let copy = try elsewhere.publishablePersonalKey(heldUnder: personal, userId: userId)
        XCTAssertEqual(check(here, copy), .cannotOpen)
        XCTAssertEqual(SelfKeyManager.action(for: .cannotOpen), .flag)
    }

    // MARK: - The wire the server expects

    func testTheFlagAndTheRepairSayWhatTrackExpects() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let flag = String(decoding: try encoder.encode(SelfKeyUnreadableRequest(copySha256: "ab")), as: UTF8.self)
        XCTAssertEqual(flag, #"{"copy_sha256":"ab"}"#)
        let repair = String(decoding: try encoder.encode(SelfKeyPseudonymRequest(
            keyVersion: 1, encryptedCircleKey: EncryptedBlobRequest(nonce: "n", ciphertext: "c"),
            ephemeralPublicKey: "e", userPseudonym: "p")), as: UTF8.self)
        XCTAssertEqual(repair, #"{"encrypted_circle_key":{"ciphertext":"c","nonce":"n"},"ephemeral_public_key":"e","key_version":1,"user_pseudonym":"p"}"#)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let stale = try decoder.decode(SelfKeyUnreadableResponse.self,
                                       from: Data(#"{"requested":false,"woken":false,"copy_changed":true}"#.utf8))
        XCTAssertEqual(stale.copyChanged, true)
    }

    /// The record repair: only when this device's own key opens the published
    /// copy (.opens or .unsigned), never for a key taken on trust, with the
    /// pseudonym under exactly that key — on PseudonymMismatch or when nothing
    /// is recorded. A stale flag is not remembered.
    func testTheRecordIsRepairedOnlyWhenTheCopyOpensHere() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        let start = try XCTUnwrap(manager.range(of: "private static func repairRecordIfCopyOpensHere("))
        let body = String(manager[start.upperBound...].prefix(2_000))
        XCTAssertTrue(body.contains("guard status == .opens || status == .unsigned, !crypto.personalKeyTakenOnTrust(),"))
        // Derived directly: no copy is wrapped or signed just to read it.
        XCTAssertTrue(body.contains("let mine = (try? crypto.deriveUserPseudonym(circleId: selfCircleUuid, userId: userId))?.lowercased(),"))
        XCTAssertFalse(body.contains("publishablePersonalKey"))
        XCTAssertTrue(body.contains("userPseudonym: mine))"))
        XCTAssertTrue(manager.contains("""
            if verdict == .pseudonymMismatch {
                await repairRecordIfCopyOpensHere(bundle, userId: userId)
            }
"""))
        XCTAssertTrue(manager.contains("lastCopyCheck = (now, .nothingRecorded)\n            // Nothing recorded"))
        XCTAssertTrue(manager.contains("let answer = try await api.reportSelfKeyUnreadable(copySha256: digest)"))
        let stale = try XCTUnwrap(manager.range(of: "if answer.copyChanged == true {"))
        let remembered = try XCTUnwrap(manager.range(of: "UserDefaults.standard.set(digest, forKey: key)",
                                                     range: stale.upperBound..<manager.endIndex))
        XCTAssertTrue(manager[stale.upperBound..<remembered.lowerBound].contains("return\n"),
                      "a stale flag returns before anything is remembered")
    }

    // MARK: - The wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The copy check never mints, and never runs the "empty history" branch:
    /// that is only the server's word.
    func testTheCopyCheckNeverMints() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        let start = try XCTUnwrap(manager.range(of: "static func checkServerCopy(userId: String, force: Bool = false, now: Date = Date()) async {"))
        let end = try XCTUnwrap(manager.range(of: "static func adoptPending(now: Date = Date()) -> Bool {"))
        let body = manager[start.upperBound..<end.lowerBound]
        for never in ["mintAndPublish", "prepareCircleCreation", "personalTrackingIsEmpty", "storeSelfKey("] {
            XCTAssertFalse(body.contains(never), never)
        }
    }

    /// The holder's duty by the SDK's status: republish ONLY when the copy
    /// can't be opened here; nothing when it opens to a different key
    /// (divergence is adoption's, or the wrong device would win).
    func testTheHolderActsOnlyOnTheSDKsStatus() {
        let expected: [(PublishedCopyStatus, SelfKeyManager.HolderAction)] = [
            (.opens, .none), (.unsigned, .signInPlace), (.cannotOpen, .republish),
            (.opensToDifferentKey, .none), (.noKeyHere, .none), (.noSigningKey, .none), (.malformed, .none),
        ]
        for (status, action) in expected {
            XCTAssertEqual(SelfKeyManager.holderAction(for: status), action, "\(status)")
        }
    }

    /// The republish: hourly, never a key taken on trust, signed with its
    /// pseudonym, replacing — and never a mint.
    func testTheRepublishRules() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        let start = try XCTUnwrap(manager.range(of: "private static func holderDuty("))
        let body = String(manager[start.upperBound...].prefix(3_000))
        let gate = try XCTUnwrap(body.range(of: "guard mayRepublish(lastAt: lastRepublishAt, now: now), !crypto.personalKeyTakenOnTrust() else { return }"))
        let publish = try XCTUnwrap(body.range(of: "let copy = try crypto.publishablePersonalKey(heldUnder: selfCircleUuid, userId: userId)"))
        XCTAssertLessThan(gate.lowerBound, publish.lowerBound)
        XCTAssertTrue(body.contains("let status = crypto.checkPublishedPersonalCopy("))
        XCTAssertTrue(body.contains("userPseudonym: copy.userPseudonym,\n                    replace: true"))
        XCTAssertTrue(body.contains("guard !crypto.personalKeyTakenOnTrust() else { return }"), "never signs a key taken on trust")
        XCTAssertFalse(body.contains("prepareCircleCreation"), "never a mint")
        // The hourly cap survives the relaunches silent pushes cause.
        XCTAssertTrue(manager.contains("UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: key)"))
    }

    /// A held key is checked on every regular pass (5-minute throttle) and on
    /// the wake; a personal send adopts first and is never held.
    func testTheCheckRunsOnThePassTheWakeAndBeforeASend() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        let held = try XCTUnwrap(manager.range(of: "await checkServerCopy(userId: userId)"))
        let sign = try XCTUnwrap(manager.range(of: "await signServerCopyIfUnsigned(userId: userId)\n            }"))
        XCTAssertLessThan(held.lowerBound, sign.lowerBound)
        // NoSigningKey asks for the password, and so does a signing key
        // missing when the holder's check can't see it.
        XCTAssertTrue(manager.contains("record(Self.healthWithHistoryHere(verdict: lastCopyCheck?.verdict, signingKeyMissing: signingKeyMissing,"))
        let push = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("await SelfKeyManager.checkServerCopy(userId: me, force: true)"))
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertTrue(streamer.contains("""
        if circleId == SelfKeyManager.selfCircleUuid {
            SelfKeyManager.adoptPending()
        }
"""))
    }

    /// A first import refused for its signature is a key someone else chose:
    /// never minted over, and no flag.
    func testASignatureRefusalOnImportIsNotCantOpen() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        let refusal = try XCTUnwrap(manager.range(of: "if let mobile = error as? MobileError, case .SignatureInvalid = mobile {\n                    record(.undecryptable)\n                    return false\n                }"))
        let flag = try XCTUnwrap(manager.range(of: "await flagUnreadable(bundle)\n"))
        let mint = try XCTUnwrap(manager.range(of: "if mayReplace, await personalTrackingIsEmpty() {"))
        XCTAssertLessThan(refusal.lowerBound, flag.lowerBound)
        XCTAssertLessThan(flag.lowerBound, mint.lowerBound)
    }
}
