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

/// Where a sign-in takes its keys from, and a lost signing key.
///
/// A sign-in takes the keys it opens from its OWN reply — SRP step 2's
/// success branch, or the 2FA step after it — never from /auth/me. The reply's
/// keys are those of the credential that proved; /me's copy opens only for
/// whichever credential last set it, and it serves a password-wrapped key to
/// any session holder.
///
/// A device that holds the account's keys but lost its signing key asks for
/// the password in place, once.
final class SignInKeySourceTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The auth server's login reply, flattened into the step-2 success
    /// reply: the wrapped keys, their KDF, and the public keys at the top
    /// level.
    private let loginFields = #"""
        "kdf_params":{"salt":"c2FsdA==","memory_kib":65536,"iterations":3,"parallelism":4},
        "encrypted_keys":{"master_key":{"nonce":"n1","ciphertext":"c1","key_id":"v1"},
                          "sharing_private_key":{"nonce":"n2","ciphertext":"c2","key_id":"v1"},
                          "signing_private_key":{"nonce":"n3","ciphertext":"c3","key_id":"v1"}},
        "sharing_public_key":"U0hBUklORw==","signing_public_key":"U0lHTklORw==",
        "access_token":"a","refresh_token":"r"
        """#

    func testStepTwoCarriesTheKeysToOpen() throws {
        let body = Data((#"{"success":true,"data":{"server_proof":"AAAA","user":{"id":"u","email":"e","status":"active"},"#
                         + loginFields + "}}").utf8)
        let step2: SRPStep2Response = try APIService.decodeResponseBody(body)
        let keys = try XCTUnwrap(step2.keysToOpen)
        XCTAssertEqual(keys.kdf.memoryKib, 65536)
        XCTAssertEqual(keys.keys.masterKey.ciphertext, "c1")
        XCTAssertEqual(keys.keys.signingPrivateKey?.ciphertext, "c3")
        XCTAssertEqual(keys.keys.sharingPublicKey, "U0hBUklORw==", "the top-level public keys ride along")
        XCTAssertEqual(keys.keys.signingPublicKey, "U0lHTklORw==")
        XCTAssertEqual(step2.accessToken, "a")
    }

    func testTheTwoFactorStepCarriesTheKeysToOpen() throws {
        let body = Data((#"{"success":true,"data":{"user":{"id":"u","email":"e","status":"active"},"#
                         + loginFields + "}}").utf8)
        let reply: TwoFactorLoginResponse = try APIService.decodeResponseBody(body)
        let keys = try XCTUnwrap(reply.keysToOpen)
        XCTAssertEqual(keys.keys.sharingPrivateKey.ciphertext, "c2")
        XCTAssertEqual(keys.keys.signingPublicKey, "U0lHTklORw==")
        XCTAssertEqual(reply.accessToken, "a")
        XCTAssertEqual(reply.refreshToken, "r")
    }

    /// The challenge branch has no keys, and none are made up.
    func testAChallengeHasNoKeys() throws {
        let body = Data(#"{"success":true,"data":{"server_proof":"AAAA","requires_2fa":true,"two_factor_token":"t"}}"#.utf8)
        let step2: SRPStep2Response = try APIService.decodeResponseBody(body)
        XCTAssertNil(step2.keysToOpen)
    }

    /// The wiring: step 2 and the 2FA step hand their own keys to the sign-in,
    /// which never reads keys from /auth/me.
    func testTheSignInNeverOpensKeysFromAuthMe() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("password: password,\n                keys: step2.keysToOpen"))
        XCTAssertTrue(auth.contains("password: password, keys: response.keysToOpen, typedEmail: typedEmail)"))
        XCTAssertTrue(auth.contains("try await deriveAndImportSharingKey(password: password, keys: signInKeys.keys, kdf: signInKeys.kdf)"))
        for never in ["user.encryptedKeys", "user.kdfParams", ".encryptedKeys,\n           let kdf = user"] {
            XCTAssertFalse(auth.contains(never), never)
        }
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("func verify2FA(twoFactorToken: String, code: String, method: String = \"totp\") async throws -> TwoFactorLoginResponse {"))
    }

    /// The account's public keys are the ones its opened private keys derive;
    /// the reply's are only compared, and a difference is logged — never used.
    func testThePublicKeysAreDerivedNeverTaken() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("let derivedSharing = try cryptoManager.exportPublicKey()"))
        XCTAssertTrue(auth.contains("try keychain.save(derivedSharing, for: .sharingPublicKey)"))
        XCTAssertFalse(auth.contains("try keychain.save(pubKey, for: .sharingPublicKey)"), "the served key was stored")
        let importIt = try XCTUnwrap(auth.range(of: "try cryptoManager.importPrivateKey(privateKeyBase64: sharingPrivateKeyB64)"))
        let derive = try XCTUnwrap(auth.range(of: "let derivedSharing = try cryptoManager.exportPublicKey()"))
        XCTAssertLessThan(importIt.lowerBound, derive.lowerBound, "derived from the key just imported")
        // The signing key's served value is only compared too (the verdict).
        XCTAssertTrue(auth.contains("serverVerifyingKeyHex: serverSigningPublicKey.flatMap(Self.normalizeToHex)"))

        let key = Data((0..<32).map { UInt8($0 * 3 & 0xff) })
        let hex = key.map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(AuthManager.samePublicKey(key.base64EncodedString(), hex))
        XCTAssertTrue(AuthManager.samePublicKey(hex.uppercased(), key.base64EncodedString()))
        XCTAssertFalse(AuthManager.samePublicKey(key.base64EncodedString(), Data(repeating: 1, count: 32).base64EncodedString()))
        XCTAssertFalse(AuthManager.samePublicKey("", ""))
    }

    // MARK: - A lost signing key

    func testALostSigningKeyAsksForThePasswordOnce() {
        XCTAssertEqual(SelfKeyManager.healthWithHistoryHere(verdict: nil, signingKeyMissing: true, passwordTried: false),
                       .needsPassword)
        XCTAssertEqual(SelfKeyManager.healthWithHistoryHere(verdict: .ownCopyMatches, signingKeyMissing: true,
                                                            passwordTried: false),
                       .needsPassword, "the holder's check can't see it, so it is looked for directly")
        XCTAssertEqual(SelfKeyManager.healthWithHistoryHere(verdict: .noSigningKey, signingKeyMissing: false,
                                                            passwordTried: false), .needsPassword)
        XCTAssertEqual(SelfKeyManager.healthWithHistoryHere(verdict: nil, signingKeyMissing: true, passwordTried: true),
                       .ok, "typed once and the key did not come back: not asked again this session")
        XCTAssertEqual(SelfKeyManager.healthWithHistoryHere(verdict: .noSigningKey, signingKeyMissing: true,
                                                            passwordTried: true), .ok)
        XCTAssertEqual(SelfKeyManager.healthWithHistoryHere(verdict: .ownCopyMatches, signingKeyMissing: false,
                                                            passwordTried: false), .ok)
        XCTAssertTrue(SelfKeyHealth.needsPassword.asksForPassword)
        XCTAssertFalse(SelfKeyHealth.needsPassword.retriesItself, "only the password changes it")
    }

    /// The password goes through re-auth on this session and reinstalls the
    /// signing key; whether it came back is noted, so it is asked for once.
    /// Nothing is minted without it, and a sign-out forgets the note.
    func testTheLostSigningKeyWiring() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        XCTAssertTrue(manager.contains("(try? crypto.exportPublicKey()) != nil && (try? crypto.signingPublicKeyHex()) == nil"))
        XCTAssertTrue(manager.contains("if signingKeyMissing, !passwordDidNotRestoreSigningKey {\n            record(.noAccountKeys)\n            return false\n        }"))
        let reset = try XCTUnwrap(manager.range(of: "static func reset() {"))
        XCTAssertTrue(manager[reset.upperBound...].prefix(300).contains("passwordDidNotRestoreSigningKey = false"))
        let auth = try source("App/Managers/AuthManager.swift")
        let unlock = try XCTUnwrap(auth.range(of: "func unlockWithPassword(_ password: String) async throws {"))
        let body = auth[unlock.upperBound...].prefix(2_500)
        let imported = try XCTUnwrap(body.range(of: "try await deriveAndImportSharingKey(password: password, keys: keys, kdf: kdf)"))
        let noted = try XCTUnwrap(body.range(of: "SelfKeyManager.passwordDidNotRestoreSigningKey = (try? cryptoManager.signingPublicKeyHex()) == nil"))
        let ensured = try XCTUnwrap(body.range(of: "await SelfKeyManager.ensure()"))
        XCTAssertLessThan(imported.lowerBound, noted.lowerBound)
        XCTAssertLessThan(noted.lowerBound, ensured.lowerBound)
    }
}
