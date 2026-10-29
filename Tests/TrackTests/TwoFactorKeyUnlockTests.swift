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

/// A two-factor sign-in that opens the account's keys, and a passkey-only
/// second factor.
///
/// A two-factor sign-in must finish WITH the encryption keys: `login()` keeps
/// the password across the 2FA challenge and `verify2FA` passes it on to
/// `completeLogin`, which derives the keys, and a derivation failure reaches
/// the caller. Otherwise the user is signed in with every circle unreadable
/// and nothing ever asks for the password again.
///
/// An account whose only second factor is a passkey is never shown a code
/// box it could never answer.
///
/// The unlock step itself is exercised for real: a vault is built with the
/// SDK exactly as the portal builds one and opened with the right and the
/// wrong password. The call-site wiring (`login` → `verify2FA` →
/// `completeLogin`) is asserted on the SOURCE, as SessionExpiryRetentionTests
/// does: APIService's URLSession is not injectable, so a behavioural test of the
/// network half would need a live account, and what this guards against is an
/// edit to `password: nil`, not a runtime state.
final class TwoFactorKeyUnlockTests: XCTestCase {

    // MARK: - A real vault

    /// The smallest parameters the SDK's validator accepts (19 MiB, t=2), so
    /// the test stays fast while running the genuine Argon2id path.
    private let kdf = KdfParamsResponse(
        salt: Data((0..<16).map { UInt8($0 * 7 & 0xff) }).base64EncodedString(),
        memoryKib: 19_456,
        iterations: 2,
        parallelism: 1
    )

    /// master key under Argon2id(password), sharing private key under the
    /// master key — the layout `/auth/me` serves as `encrypted_keys`.
    private func makeVault(password: String) throws -> (keys: EncryptedKeysResponse, sharingPrivateKeyB64: String) {
        let crypto = CryptoManager()
        let master = crypto.generateMasterKey()
        let sealedMaster = try crypto.encryptWithPassword(
            plaintext: master,
            password: password,
            kdfParams: KdfParams(
                salt: kdf.salt,
                memoryKib: UInt32(kdf.memoryKib),
                iterations: UInt32(kdf.iterations),
                parallelism: UInt32(kdf.parallelism)
            )
        )
        let identity = crypto.generateKeypair()
        let sealedSharing = try crypto.encryptWithKey(plaintext: identity.privateKey, keyBase64: master)
        let keys = EncryptedKeysResponse(
            masterKey: EncryptedBlobResponse(nonce: sealedMaster.nonce, ciphertext: sealedMaster.ciphertext),
            sharingPrivateKey: EncryptedBlobResponse(nonce: sealedSharing.nonce, ciphertext: sealedSharing.ciphertext),
            signingPrivateKey: nil,
            sharingPublicKey: identity.publicKey,
            signingPublicKey: nil
        )
        return (keys, identity.privateKey)
    }

    func testTheRightPasswordUnlocksTheSharingKey() throws {
        let vault = try makeVault(password: "correct horse battery staple")
        let opened = try AuthManager.unlockVault(
            crypto: CryptoManager(),
            password: "correct horse battery staple",
            keys: vault.keys,
            kdf: kdf
        )
        XCTAssertEqual(opened.sharingPrivateKeyB64, vault.sharingPrivateKeyB64,
                       "the unlock must yield exactly the sharing private key the vault holds")
    }

    /// The failure must reach the caller: swallowed by a `catch` that prints in
    /// DEBUG, a keyless sign-in would look like a success.
    func testAWrongPasswordThrowsInsteadOfYieldingNothing() throws {
        let vault = try makeVault(password: "correct horse battery staple")
        XCTAssertThrowsError(try AuthManager.unlockVault(
            crypto: CryptoManager(),
            password: "Correct horse battery staple",
            keys: vault.keys,
            kdf: kdf
        )) { error in
            XCTAssertEqual(error as? AuthManager.VaultDerivationError, .masterKeyOpen,
                           "expected masterKeyOpen, got \(error)")
        }
    }

    // MARK: - The call sites (source)

    private var authManagerSource: String { source("App/Managers/AuthManager.swift") }

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
            XCTFail("could not read \(relative)")
            return ""
        }
        return text
    }

    /// The body of one `func`, by name, up to the next member declaration.
    private func body(of name: String, in src: String) -> String {
        guard let start = src.range(of: "func \(name)(") else {
            XCTFail("\(name) not found — renamed or removed")
            return ""
        }
        let rest = src[start.upperBound...]
        let ends = ["\n    /// ", "\n    func ", "\n    private func ", "\n    nonisolated static func ", "\n    // MARK"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    /// On the iOS 26 runtime `.convertFromSnakeCase` turns `requires_2fa` into
    /// `requires2Fa` (it capitalizes the first letter of "2fa"), so a property
    /// named `requires2fa` would decode as nil, `login()` would take neither
    /// branch and return, and a two-factor account could not sign in at all.
    /// The flag must decode whichever spelling the runtime makes.
    func testRequires2faDecodesThroughTheWireDecoder() throws {
        let body = Data(#"{"success":true,"data":{"server_proof":"AAAA","requires_2fa":true,"two_factor_token":"t"}}"#.utf8)
        let step2: SRPStep2Response = try APIService.decodeResponseBody(body)
        XCTAssertEqual(step2.requires2fa, true)
        XCTAssertEqual(step2.twoFactorToken, "t")
        XCTAssertNil(step2.accessToken)
    }

    /// Belt and braces for the same failure: a two-factor token with no access
    /// token is the challenge even if the flag is absent, and a response with
    /// neither must fail loudly instead of returning to a silent login screen.
    func testLoginNeverFallsThroughSilently() {
        let login = body(of: "login", in: authManagerSource)
        XCTAssertTrue(login.contains("step2.accessToken == nil && step2.twoFactorToken != nil"))
        XCTAssertTrue(login.contains("throw AuthError.unexpectedResponse"))
    }

    func testTheTwoFactorBranchKeepsThePassword() {
        let login = body(of: "login", in: authManagerSource)
        XCTAssertTrue(login.contains("self.pendingPassword = password"),
                      "login() must hold the password across the 2FA challenge — the keys are unlocked from it")
        XCTAssertTrue(login.contains("self.twoFactorMethods = step2.availableMethods"),
                      "login() must keep the offered methods so a passkey-only challenge can say so")
    }

    func testVerify2FAUnlocksTheKeys() {
        let verify = body(of: "verify2FA", in: authManagerSource)
        XCTAssertFalse(verify.contains("password: nil"),
                       "verify2FA must not finish the sign-in without the password")
        XCTAssertTrue(verify.contains("password: password"),
                      "verify2FA must hand the held password to completeLogin")
        XCTAssertTrue(verify.contains("self.pendingPassword = nil"),
                      "the password must be dropped once the code has been accepted")
    }

    func testAKeyUnlockFailureFailsTheSignIn() {
        let complete = body(of: "completeLogin", in: authManagerSource)
        XCTAssertTrue(complete.contains("throw AuthError.keysUnavailable"),
                      "a failed key unlock must fail the sign-in, as the Android app does")
        XCTAssertTrue(complete.contains("withdrawIncompleteSignIn()"),
                      "the tokens saved before the unlock must be withdrawn, or the next launch resumes a keyless session")
        XCTAssertFalse(complete.contains("vault-key derivation failed"),
                       "no DEBUG-only print that swallows the failure")
    }

    func testWithdrawingASignInKeepsTheDevicesKeys() {
        // Not logout(): a device whose session merely expired keeps the account's
        // keys and caches on purpose, and a failed re-sign-in must not destroy them.
        let withdraw = body(of: "withdrawIncompleteSignIn", in: authManagerSource)
        XCTAssertTrue(withdraw.contains("keychain.delete(key: .accessToken)"))
        XCTAssertTrue(withdraw.contains("keychain.delete(key: .refreshToken)"))
        XCTAssertFalse(withdraw.contains("deleteAll()"))
        XCTAssertFalse(withdraw.contains("purgeAccountData"))
    }

    func testCancellingTheCodeDestroysNothing() {
        let cancel = body(of: "cancelTwoFactor", in: authManagerSource)
        XCTAssertTrue(cancel.contains("pendingPassword = nil"), "cancelling must drop the held password")
        XCTAssertFalse(cancel.contains("logout"), "cancelling a code prompt must not sign anything out")
        XCTAssertFalse(cancel.contains("deleteAll"))

        let view = source("App/Views/Auth/TwoFactorView.swift")
        XCTAssertTrue(view.contains("authManager.cancelTwoFactor()"))
        XCTAssertFalse(view.contains("authManager.logout()"),
                       "TwoFactorView's Cancel never calls logout(), which wipes a same-user device's keys")
    }

    func testSignOutAndExpiryDropTheHeldPassword() {
        XCTAssertTrue(body(of: "logout", in: authManagerSource).contains("pendingPassword = nil"))
        XCTAssertTrue(body(of: "expireSession", in: authManagerSource).contains("pendingPassword = nil"))
    }

    // MARK: - The message

    @MainActor
    func testTheLoginScreenNamesAKeyUnlockFailure() {
        let text = LoginView.friendlyMessage(for: AuthManager.AuthError.keysUnavailable)
        XCTAssertTrue(text.contains("this phone couldn't open your account's data"),
                      "an unlock failure must not read as a mistyped password: \(text)")
        XCTAssertNil(text.range(of: "key", options: .caseInsensitive), "no key talk: \(text)")
        XCTAssertNotEqual(text, "Couldn't sign in. Please try again.")
    }

    // MARK: - Passkey-only second factor

    func testOnlyATotpChallengeGetsACodeBox() {
        XCTAssertFalse(AuthManager.acceptsCode(availableMethods: ["passkey"]),
                       "a passkey-only challenge cannot be answered with a typed code")
        XCTAssertTrue(AuthManager.acceptsCode(availableMethods: ["totp"]))
        XCTAssertTrue(AuthManager.acceptsCode(availableMethods: ["totp", "passkey"]))
        XCTAssertTrue(AuthManager.acceptsCode(availableMethods: ["passkey", "TOTP"]))
        XCTAssertTrue(AuthManager.acceptsCode(availableMethods: nil),
                      "an older server that does not list methods keeps the code box")
        XCTAssertTrue(AuthManager.acceptsCode(availableMethods: []))
    }

    /// The field names are the auth server's, decoded through the app's live
    /// wire decoder.
    func testTheChallengeListsItsMethodsOnTheWire() throws {
        let body = Data("""
        {"success":true,"data":{"server_proof":"AAAA","requires_2fa":true,
         "two_factor_token":"5d3c1f9e-0000-4000-8000-000000000000",
         "available_methods":["passkey"],"preferred_method":"passkey"}}
        """.utf8)
        let step2: SRPStep2Response = try APIService.decodeResponseBody(body)
        XCTAssertEqual(step2.requires2fa, true)
        XCTAssertEqual(step2.availableMethods, ["passkey"])
        XCTAssertEqual(step2.preferredMethod, "passkey")
        XCTAssertFalse(AuthManager.acceptsCode(availableMethods: step2.availableMethods))
    }

    @MainActor
    func testThePasskeyOnlyScreenSaysWhatToDo() {
        XCTAssertEqual(
            TwoFactorView.passkeyOnlyMessage,
            "This account's second step uses a passkey, which this app can't use yet. "
                + "Add an authenticator app in your account settings, or sign in on the web."
        )
        XCTAssertNotNil(AppConfiguration.shared.securitySettingsURL,
                        "the passkey-only screen links to the portal's security settings")
    }

    /// An account whose email isn't verified yet: the auth server's SRP
    /// step 2 answers a 403 with `email_not_verified` once the password
    /// proved. It is told to verify, in the Android app's words, never that
    /// the password is wrong, whichever shape the code comes in. Any other
    /// 403 keeps the ordinary message.
    @MainActor
    func testAnUnverifiedEmailIsToldToVerifyNotThatThePasswordIsWrong() {
        let verify = "Please verify your email address first. Open the link we sent you, then sign in again."
        for error in [APIError(code: "email_not_verified", message: "x", errorCode: "email_not_verified"),
                      APIError(code: "http_403", message: "x", errorCode: "email_not_verified")] {
            XCTAssertEqual(LoginView.friendlyMessage(for: error), verify)
        }
        XCTAssertEqual(LoginView.friendlyMessage(for: APIError(code: "http_403", message: "x")),
                       "Email or password is incorrect.")
    }

    /// A wrong password at the sign-in's SRP step 2 is a 401 about the proof,
    /// not a dead token: it is never refreshed (there is no session yet), and
    /// the person reads the sign-in's own line for it.
    @MainActor
    func testAWrongPasswordAtStep2IsSaidAsSuchNotRefreshed() throws {
        let api = source("App/Services/APIService.swift")
        let branch = "                if request.url?.path == Self.srpStep2Path {\n                    let serverCode = (try? decoder.decode(APIResponse<EmptyResponse>.self, from: data))?.error?.errorCode\n                    throw APIError(code: \"http_401\", message: \"Sign-in proof refused\", errorCode: serverCode)\n                }"
        XCTAssertTrue(api.contains(branch))
        let block = try XCTUnwrap(api.range(of: "            if httpResponse.statusCode == 401 {"))
        let refreshStep = try XCTUnwrap(api.range(of: "let isRefreshEndpoint = request.url?.path == \"/api/v1/auth/refresh\""))
        let at = try XCTUnwrap(api.range(of: branch))
        XCTAssertLessThan(block.lowerBound, at.lowerBound)
        XCTAssertLessThan(at.lowerBound, refreshStep.lowerBound, "decided before any refresh")
        XCTAssertTrue(api.contains("path: Self.srpStep2Path,"))
        XCTAssertEqual(APIService.srpStep2Path, "/api/v1/auth/srp/step2")
        XCTAssertEqual(LoginView.friendlyMessage(for: APIError(code: "http_401", message: "x", errorCode: "invalid_credentials")),
                       "Email or password is incorrect.")
    }

    /// The app never sends a typed code as a passkey assertion.
    func testTheCodeIsAlwaysSentAsTotp() {
        let api = source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("func verify2FA(twoFactorToken: String, code: String, method: String = \"totp\")"))
        XCTAssertFalse(authManagerSource.contains("method: \"passkey\""))
        XCTAssertFalse(authManagerSource.contains("method: step2.preferredMethod"))
    }
}
