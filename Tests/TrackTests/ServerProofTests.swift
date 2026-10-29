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
import CryptoKit
import PingolinTrackSDK
@testable import Track

/// The server's SRP proof M2 is checked at sign-in (both branches of step 2)
/// and at every re-auth, with the SDK's own call, BEFORE anything in the
/// reply is used. A wrong or missing M2 stops the attempt and fails it as a
/// sign-in or re-auth that didn't work — never "wrong password".
///
/// The M2 the auth server would send is built the way it builds it:
/// SHA-256(A | M1 | S), in the minimal encoding, and checked by the real SDK.
@MainActor
final class ServerProofTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// A proof whose own values are all there, and an M2 that cannot match it.
    func testAWrongOrMissingProofIsRefused() throws {
        let proof = SrpLoginProof(clientPublic: Data(repeating: 1, count: 256).base64EncodedString(),
                                  clientProof: Data(repeating: 2, count: 32).base64EncodedString(),
                                  sessionKey: Data(repeating: 3, count: 256).base64EncodedString())
        XCTAssertFalse(AuthManager.serverProofHolds(nil, for: proof), "missing")
        XCTAssertFalse(AuthManager.serverProofHolds("", for: proof), "empty")
        XCTAssertFalse(AuthManager.serverProofHolds(Data(repeating: 9, count: 32).base64EncodedString(), for: proof),
                       "not H(A | M1 | S)")
        XCTAssertFalse(AuthManager.serverProofHolds("not base64 at all", for: proof), "unreadable: refused, not thrown")
        // This device's own values malformed (a programming error): the SDK
        // throws, and it counts as not holding.
        let broken = SrpLoginProof(clientPublic: "", clientProof: proof.clientProof, sessionKey: proof.sessionKey)
        XCTAssertFalse(AuthManager.serverProofHolds(Data(repeating: 9, count: 32).base64EncodedString(), for: broken))
    }

    /// The M2 the auth server would send for this very attempt is accepted,
    /// and one flipped byte of it is not.
    func testTheRightProofHoldsAndOneFlippedByteDoesNot() throws {
        let proof = SrpLoginProof(clientPublic: Data((0..<256).map { UInt8(($0 * 7 + 1) & 0xff) }).base64EncodedString(),
                                  clientProof: Data((0..<32).map { UInt8(($0 * 13 + 5) & 0xff) }).base64EncodedString(),
                                  sessionKey: Data((0..<256).map { UInt8(($0 * 11 + 3) & 0xff) }).base64EncodedString())
        // The auth server's M2 = SHA-256(A | M1 | S), each as sent (full-length
        // values here, so the minimal and padded encodings agree).
        let a = Data(base64Encoded: proof.clientPublic)!, m1 = Data(base64Encoded: proof.clientProof)!
        let s = Data(base64Encoded: proof.sessionKey)!
        var m2 = Data(CryptoKit.SHA256.hash(data: a + m1 + s))
        XCTAssertTrue(AuthManager.serverProofHolds(m2.base64EncodedString(), for: proof))
        m2[0] ^= 0x01
        XCTAssertFalse(AuthManager.serverProofHolds(m2.base64EncodedString(), for: proof))
    }

    /// The wiring: sign-in checks M2 right after step 2 — before the 2FA branch
    /// and before any token, key or challenge is used — and so does every
    /// re-auth (the password asked in place, and the account deletion's step-up).
    func testM2IsCheckedBeforeTheReplyIsUsed() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let login = try XCTUnwrap(auth.range(of: "func login(email: String, password: String) async throws {"))
        let body = auth[login.upperBound...].prefix(3_500)
        let step2 = try XCTUnwrap(body.range(of: "let step2 = try await api.srpStep2("))
        let check = try XCTUnwrap(body.range(of: "guard Self.serverProofHolds(step2.serverProof, for: proof) else { throw AuthError.serverNotVerified }"))
        let twoFactor = try XCTUnwrap(body.range(of: "if step2.requires2fa == true"))
        let tokens = try XCTUnwrap(body.range(of: "try await completeLogin("))
        XCTAssertLessThan(step2.lowerBound, check.lowerBound)
        XCTAssertLessThan(check.lowerBound, twoFactor.lowerBound, "before a 2FA challenge is started")
        XCTAssertLessThan(check.lowerBound, tokens.lowerBound, "before any token or key is used")
        XCTAssertTrue(auth.contains("try await reauthExchange(password).reauthToken"), "the deletion step-up too")
        XCTAssertTrue(auth.contains("encoding: .minimal"), "the SDK client's own encoding")
        XCTAssertEqual(AuthManager.AuthError.serverNotVerified.errorDescription, "Couldn't sign in. Please try again.")
        XCTAssertEqual(PasswordUnlockForm.outcome(of: AuthManager.AuthError.serverNotVerified), .failed,
                       "never \"That password isn't right.\"")
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("case serverProof, kdfParams, encryptedKeys, sharingPublicKey, signingPublicKey"))
    }
}
