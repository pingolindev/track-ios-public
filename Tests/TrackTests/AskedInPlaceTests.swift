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

/// Nothing asks people to do what the app can do itself.
///
/// The password — the one thing only the person has — is asked for right
/// where it is missing, and nothing is signed out. What can be retried is
/// tried again by itself instead of asking the person to "try again later".
/// With no account keys on this device the personal notice asks for the
/// password, and a setup that did not reach the server is tried again on the
/// app's own clock.
final class AskedInPlaceTests: XCTestCase {

    // MARK: - What a failed unlock means

    /// A real vault opened with the wrong password is the person's to retype —
    /// the one failure worth telling them about.
    func testAWrongPasswordIsThePersonsToRetype() throws {
        let kdf = KdfParamsResponse(
            salt: Data((0..<16).map { UInt8($0 * 5 & 0xff) }).base64EncodedString(),
            memoryKib: 19_456,
            iterations: 2,
            parallelism: 1
        )
        let crypto = CryptoManager()
        let master = crypto.generateMasterKey()
        let sealedMaster = try crypto.encryptWithPassword(
            plaintext: master,
            password: "correct horse battery staple",
            kdfParams: KdfParams(salt: kdf.salt, memoryKib: UInt32(kdf.memoryKib),
                                 iterations: UInt32(kdf.iterations), parallelism: UInt32(kdf.parallelism))
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

        XCTAssertThrowsError(try AuthManager.unlockVault(
            crypto: CryptoManager(), password: "correct horse battery stapler", keys: keys, kdf: kdf
        )) { error in
            XCTAssertEqual(PasswordUnlockForm.outcome(of: error), .wrongPassword, "\(error)")
        }
        XCTAssertEqual(PasswordUnlockForm.wrongPasswordText, "That password isn't right.")
    }

    /// Without a connection the form keeps what was typed and tries again by
    /// itself; anything retyping cannot change is said once and left.
    func testEachFailureMeansOneThing() {
        XCTAssertEqual(PasswordUnlockForm.outcome(of: URLError(.notConnectedToInternet)), .waitForConnection)
        XCTAssertEqual(PasswordUnlockForm.outcome(of: URLError(.timedOut)), .waitForConnection)
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "http_503", message: "Request failed")),
                       .waitForConnection)
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "circuit_open", message: "paused")),
                       .waitForConnection)
        // The sign-in itself is gone: the sign-in screen follows, nothing to retry.
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "refresh_failed", message: "refused")), .failed)
        XCTAssertEqual(PasswordUnlockForm.outcome(of: AuthManager.VaultDerivationError.sharingKeyOpen), .failed)
        XCTAssertEqual(PasswordUnlockForm.outcome(of: AuthManager.AuthError.keysUnavailable), .failed)
        XCTAssertEqual(PasswordUnlockForm.outcome(of: AuthManager.AuthError.noUserId), .failed)
        // The server's answer to a wrong proof: the person's to retype, never retried.
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "invalid_credentials", message: "Invalid credentials")),
                       .wrongPassword)
        // auth's one real sign-in case (a guardian session from before credential binding).
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "http_409", message: "Please sign in again")),
                       .needsSignIn)
        // Any other answer is an answer: not retried forever.
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "http_400", message: "Bad request")), .failed)
        XCTAssertEqual(PasswordUnlockForm.waitingText, "Waiting for a connection…")
    }

    /// The unlock opens the keys as a sign-in does and keeps the session: no
    /// sign-out, no expiry, never another account's keys, then everything that
    /// needed the keys runs again.
    func testTheUnlockKeepsTheSessionAndCarriesOn() throws {
        let source = try self.source("App/Managers/AuthManager.swift")
        let start = try XCTUnwrap(source.range(of: "func unlockWithPassword(_ password: String) async throws {"))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(body.contains("try await deriveAndImportSharingKey(password: password, keys: keys, kdf: kdf)"))
        // Through re-auth on THIS session: it proves the password to the server
        // and returns what that credential opens. Never a second sign-in.
        XCTAssertTrue(body.contains("step2 = try await reauthExchange(password)"))
        XCTAssertTrue(body.contains("guard let keys = step2.keysToOpen, let kdf = step2.kdfParams"))
        let exchangeStart = try XCTUnwrap(source.range(of: "private func reauthExchange(_ password: String) async throws -> ReauthStep2Response {"))
        let exchangeEnd = try XCTUnwrap(source.range(of: "\n    }\n", range: exchangeStart.upperBound..<source.endIndex))
        let exchange = String(source[exchangeStart.upperBound..<exchangeEnd.lowerBound])
        XCTAssertTrue(exchange.contains("let step1 = try await api.reauthStep1()"))
        XCTAssertTrue(exchange.contains("let step2 = try await api.reauthStep2("))
        XCTAssertTrue(exchange.contains("guard Self.serverProofHolds(step2.serverProof, for: proof) else { throw AuthError.serverNotVerified }"),
                      "M2 checked before the reply is used")
        XCTAssertTrue(exchange.contains("if let current = step1.email {"), "the current SRP identity")
        for never in ["logout(", "expireSession(", "withdrawIncompleteSignIn(", "purgeAccountData(",
                      "keychain.delete", "deleteAll", "srpStep1(", "srpStep2(", "completeLogin(", "login("] {
            XCTAssertFalse(exchange.contains(never), never)
        }
        for call in ["RetainedMemberPins.restore(owner: me, crypto: cryptoManager)",
                     "await SelfKeyManager.ensure()", "await DeviceRegistrar.ensure()",
                     "try? await CircleManager.shared.loadCircles()"] {
            XCTAssertTrue(body.contains(call), call)
        }
        for never in ["logout(", "expireSession(", "withdrawIncompleteSignIn(", "purgeAccountData(",
                      "keychain.delete", "deleteAll", "srpStep1(", "srpStep2(", "completeLogin(", "login("] {
            XCTAssertFalse(body.contains(never), never)
        }
        let keysOpened = try XCTUnwrap(body.range(of: "deriveAndImportSharingKey"))
        let reloaded = try XCTUnwrap(body.range(of: "SelfKeyManager.ensure()"))
        XCTAssertLessThan(keysOpened.lowerBound, reloaded.lowerBound, "the keys first, then what needs them")
    }

    /// Re-auth's step 2 answers a wrong password with 401 `invalid_credentials`
    /// ("Invalid credentials"). That is not a dead token: no refresh, no retry —
    /// the person retypes it. A stale handshake (`reauth_session_expired`) is
    /// not a dead token either, and never "wrong password": it starts again at
    /// step 1, once. Anything else (the server's other 401s carry no code) is
    /// refreshed and retried.
    func testAWrongProofIsNotADeadToken() throws {
        let api = try source("App/Services/APIService.swift")
        let branch = try XCTUnwrap(api.range(of: "if request.url?.path == \"/api/v1/auth/reauth/srp/step2\", let refusal = Self.reauthRefusal(data) {"))
        let refresh = try XCTUnwrap(api.range(of: "let isRefreshEndpoint = request.url?.path == \"/api/v1/auth/refresh\""))
        XCTAssertLessThan(branch.lowerBound, refresh.lowerBound, "decided before any refresh")
        XCTAssertTrue(api[branch.upperBound...].prefix(200).contains("throw APIError(code: refusal,"))
        // By auth's code first…
        XCTAssertEqual(APIService.reauthRefusal(Data(#"{"success":false,"error":"Invalid credentials","error_code":"invalid_credentials"}"#.utf8)),
                       "invalid_credentials")
        XCTAssertEqual(APIService.reauthRefusal(Data(#"{"error":"Invalid or expired re-auth session","error_code":"reauth_session_expired"}"#.utf8)),
                       "reauth_session_expired")
        XCTAssertNil(APIService.reauthRefusal(Data(#"{"error":"Invalid credentials","error_code":"something_new"}"#.utf8)),
                     "a code is read as a code; the text is only for servers without one")
        // …else EXACTLY auth's texts, on servers that predate the codes.
        XCTAssertEqual(APIService.reauthRefusal(Data(#"{"success":false,"error":"Invalid credentials"}"#.utf8)),
                       "invalid_credentials")
        XCTAssertEqual(APIService.reauthRefusal(Data(#"{"error":"Invalid or expired re-auth session"}"#.utf8)),
                       "reauth_session_expired")
        for session in ["Missing token", "User not authenticated", "Session has been revoked", "Token expired",
                        "Invalid credentials for session"] {
            XCTAssertNil(APIService.reauthRefusal(Data("{\"error\":\"\(session)\"}".utf8)), session)
        }
        XCTAssertNil(APIService.reauthRefusal(Data("not json".utf8)))
        // Only the proof is the wrong password; a stale handshake is started again once.
        XCTAssertEqual(PasswordUnlockForm.outcome(of: APIError(code: "reauth_session_expired", message: "x")), .failed)
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("""
            do {
                step2 = try await reauthExchange(password)
            } catch let error as APIError where error.code == "reauth_session_expired" {
                step2 = try await reauthExchange(password)
            }
    """))

        // The step-2 reply carries the keys in the login reply's shapes.
        let json = #"{"server_proof":"m2","reauth_token":"t","kdf_params":{"salt":"c2FsdA==","memory_kib":65536,"iterations":3,"parallelism":4},"encrypted_keys":{"master_key":{"nonce":"n","ciphertext":"c"},"sharing_private_key":{"nonce":"n","ciphertext":"c"}}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(ReauthStep2Response.self, from: Data(json.utf8))
        XCTAssertEqual(reply.kdfParams?.memoryKib, 65536)
        XCTAssertEqual(reply.encryptedKeys?.masterKey.ciphertext, "c")
        XCTAssertNil(reply.keysToOpen?.signingPublicKey, "no public keys in encrypted_keys")
        // The public keys come at the top level, as at login.
        let withPublic = try decoder.decode(ReauthStep2Response.self, from: Data(
            #"{"server_proof":"m2","reauth_token":"t","sharing_public_key":"aa","signing_public_key":"bb","kdf_params":{"salt":"c2FsdA==","memory_kib":65536,"iterations":3,"parallelism":4},"encrypted_keys":{"master_key":{"nonce":"n","ciphertext":"c","key_id":"k"},"sharing_private_key":{"nonce":"n","ciphertext":"c","key_id":"k"}}}"#.utf8))
        XCTAssertEqual(withPublic.keysToOpen?.sharingPublicKey, "aa")
        XCTAssertEqual(withPublic.keysToOpen?.signingPublicKey, "bb")
        let step1 = try decoder.decode(SRPStep1Response.self, from: Data(
            #"{"salt":"s","server_public":"b","session_id":"x","bcrypt_salt":"y","email":"a@example.com"}"#.utf8))
        XCTAssertEqual(step1.email, "a@example.com")
    }

    /// The UI test's way into the keyless state never ships: it is compiled
    /// only into DEBUG builds.
    func testForgettingTheKeysIsADebugOnlyHook() throws {
        let source = try self.source("App/Managers/AuthManager.swift")
        let hook = try XCTUnwrap(source.range(of: "\"-UITestForgetAccountKeys\""))
        let before = source[..<hook.lowerBound]
        let opened = try XCTUnwrap(before.range(of: "#if DEBUG", options: .backwards))
        if let closed = before.range(of: "#endif", options: .backwards) {
            XCTAssertLessThan(closed.lowerBound, opened.lowerBound, "the hook sits inside #if DEBUG")
        }
    }

    /// Both places that can find no account keys ask for the password where
    /// they say so.
    func testThePasswordIsAskedWhereTheProblemIsShown() throws {
        let settings = try source("App/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("""
                if selfKeyStatus.health.asksForPassword {
                    PasswordUnlockForm()
                }
"""))
        let form = try source("App/Views/Auth/PasswordUnlockForm.swift")
        XCTAssertTrue(form.contains("try await AuthManager.shared.unlockWithPassword(typed)"))
        XCTAssertTrue(form.contains(".textContentType(.password)"), "the saved password fills it")
    }

    // MARK: - The personal check

    /// With no account keys here nothing personal can be judged: the check says
    /// so BEFORE it looks at the server's copy, which a failed unwrap would
    /// otherwise have called unreadable (and minting would have failed anyway).
    func testNoAccountKeysIsDecidedBeforeTheServersCopyIsJudged() throws {
        let source = try self.source("App/Services/SelfKeyManager.swift")
        let start = try XCTUnwrap(source.range(of: "private static func ensureOnce(mayReplace: Bool) async -> Bool {"))
        let tail = source[start.upperBound...]
        let noKeys = try XCTUnwrap(tail.range(of: "guard (try? crypto.exportPublicKey()) != nil else {\n            record(.noAccountKeys)"))
        let lookup = try XCTUnwrap(tail.range(of: "bundle = try await api.getSelfKey()"))
        XCTAssertLessThan(noKeys.lowerBound, lookup.lowerBound)
    }

    /// The passes that run by themselves never mint over a stored copy on the
    /// server's word that nothing is under it; only a launch or a sign-in may.
    func testOnlyALaunchOrASignInMayReplaceAStoredCopy() throws {
        let manager = try source("App/Services/SelfKeyManager.swift")
        XCTAssertTrue(manager.contains("if mayReplace, await personalTrackingIsEmpty() {"))
        XCTAssertTrue(manager.contains("await ensure(mayReplace: false)"), "the retry clock")
        let headless = try source("App/Services/HeadlessTrackingResume.swift")
        XCTAssertTrue(headless.contains("await SelfKeyManager.ensure(mayReplace: false)"), "a background relaunch")
        let auth = try source("App/Managers/AuthManager.swift")
        XCTAssertEqual(auth.components(separatedBy: "await SelfKeyManager.ensure()").count - 1, 3,
                       "launch, sign-in and the password typed in place")
    }

    /// One pass at a time: two passes that both found no stored key would each
    /// mint and publish, and the second upsert would replace the first's key.
    func testOnePersonalPassRunsAtATime() throws {
        let source = try self.source("App/Services/SelfKeyManager.swift")
        XCTAssertTrue(source.contains("""
        if let running = inFlight {
            runAgain = true
            runAgainMayReplace = runAgainMayReplace || mayReplace
            return await running.value
        }
"""))
    }

    func testTheRetryClock() {
        XCTAssertEqual((1...8).map { RetryClock.delay(afterFailures: $0) }, [2, 4, 8, 16, 32, 60, 60, 60])
        XCTAssertEqual(RetryClock.delay(afterFailures: 0), 2)
        XCTAssertEqual(RetryClock.delay(afterFailures: 1_000), 60)

        let now = Date(timeIntervalSince1970: 1_000_000)
        var schedule = SelfKeyManager.retrySchedule(after: .unreachable, failuresInARow: 0, now: now)
        XCTAssertEqual(schedule.at, now.addingTimeInterval(2))
        XCTAssertEqual(schedule.failures, 1)
        schedule = SelfKeyManager.retrySchedule(after: .unreachable, failuresInARow: schedule.failures, now: now)
        XCTAssertEqual(schedule.at, now.addingTimeInterval(4))
        // A failed publish, at most once an hour, however many failed before.
        for failures in [0, 1, 7] {
            XCTAssertEqual(SelfKeyManager.retrySchedule(after: .publishFailed, failuresInARow: failures, now: now).at,
                           now.addingTimeInterval(60 * 60))
        }
        // The password state waits for the person; success stops the clock.
        for settled in [SelfKeyHealth.noAccountKeys, .ok, .unknown] {
            let stopped = SelfKeyManager.retrySchedule(after: settled, failuresInARow: 5, now: now)
            XCTAssertNil(stopped.at, "\(settled)")
            XCTAssertEqual(stopped.failures, 0)
        }
    }

    /// The personal check also runs on the foreground cadence, and the retry
    /// clock is asked only by the foreground loop (never all night).
    func testThePersonalCheckRunsOnTheForegroundCadence() throws {
        let app = try source("App/TrackApp.swift")
        XCTAssertTrue(app.contains("""
                                if throttle.allow("personal.history") {
                                    await SelfKeyManager.ensure(mayReplace: false)
                                }
"""))
        let tabs = try source("App/Views/MainTabView.swift")
        let loop = try XCTUnwrap(tabs.range(of: "guard scenePhase == .active else { return }"))
        let retry = try XCTUnwrap(tabs.range(of: "await SelfKeyManager.retryIfDue()"))
        XCTAssertLessThan(loop.lowerBound, retry.lowerBound, "inside the active-only loop")
    }

    // MARK: - "{name} has been asked to update Pingolin"

    /// The roster's `update_requested` reaches the member row; absent is false.
    func testTheRosterSaysWhoHasBeenAskedToUpdate() throws {
        func member(_ extra: String) throws -> CircleMemberResponse {
            let json = """
            {"user_id":"d4c3b2a1-9f8e-4d7c-8b6a-5e4f3a2b1c0d","role":"member","status":"active",
             "encrypted_circle_key":{"nonce":"00","ciphertext":"00"},"ephemeral_public_key":"00",
             "can_see_history":true,"can_see_realtime":true,"joined_day_bucket":20000\(extra)}
            """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(CircleMemberResponse.self, from: Data(json.utf8))
        }
        let asked = try member(#","update_requested":true"#)
        XCTAssertEqual(asked.updateRequested, true)
        XCTAssertTrue(asked.toModel(in: "c").updateRequested)
        XCTAssertFalse(try member("").toModel(in: "c").updateRequested, "absent: not asked")

        let rows = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(rows.contains("private var askedToUpdate: Bool { member.updateRequested && !isCurrentUser }"))
        XCTAssertTrue(rows.contains(": askedToUpdate ? Self.askedToUpdate(member.displayName) : member.displayName)"))
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("updateRequested: response.updateRequested ?? false"),
                      "loadMembers carries it too, not only the converter")
        let ask = try XCTUnwrap(manager.range(of: "func askMemberToUpdate(circleId: String, userId: String) async {"))
        let told = try XCTUnwrap(manager.range(of: ".updateRequested == true { return }", range: ask.upperBound..<manager.endIndex))
        let post = try XCTUnwrap(manager.range(of: "api.requestMemberUpdate(", range: ask.upperBound..<manager.endIndex))
        XCTAssertLessThan(told.lowerBound, post.lowerBound, "already told: nothing sent (as in the Android app)")
    }

    // MARK: - Words that ask what the app does itself

    /// Each string that would ask people to do what the
    /// app does itself, and the file it must stay out of.
    func testNothingAsksWhatTheAppDoesItself() throws {
        let gone: [(String, String)] = [
            ("App/Views/Circles/LockedCircleNotice.swift", "Sign out, then sign in again"),
            ("App/Views/Circles/LockedCircleNotice.swift", "Members will be asked on their phones"),
            ("App/Services/SelfKeyHealth.swift", "Sign out and back in to fix this"),
            ("App/Managers/PremiumManager.swift", "Please try again later"),
            ("App/Managers/PremiumManager.swift", "Please try again in a moment"),
            ("App/Managers/PremiumManager.swift", "AuthManager.shared.currentUser?.id"),
            ("App/Managers/StoreKitManager.swift", "Could not start the purchase. Please sign in again."),
            ("App/Views/Settings/SettingsView.swift", "Button(\"Try Again\")"),
        ]
        for (file, phrase) in gone {
            XCTAssertFalse(try source(file).contains(phrase), "\(file): \(phrase)")
        }
        let premium = try source("App/Managers/PremiumManager.swift")
        XCTAssertFalse(premium.contains("eligibility.reason"), "the server's text is never shown")
        XCTAssertTrue(premium.contains("Label(\"You already have a subscription for this.\", systemImage: \"info.circle\")"))
        XCTAssertTrue(premium.contains("guard let userID = AuthManager.shared.userId else {"),
                      "the stored account id, not the one /auth/me may not have returned yet")
        XCTAssertTrue(premium.contains("waiting(productsRetrying ? \"Waiting for the App Store…\" : \"Loading…\")"))
        let settings = try source("App/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains(".task { await RetryClock.untilDone { await loadNotificationPreferences() } }"))
    }

    // MARK: -

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
