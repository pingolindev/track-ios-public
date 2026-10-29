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

/// A server-rejected refresh ends the SESSION, not the account.
///
/// A definitive 401 from `/auth/refresh` must not run the full `logout()`
/// (keychain `deleteAll()`, every manager reset, every cache purged): a
/// rotation race against a session the server still considers live would turn
/// a recoverable outage into a re-import, and leave the device dark for hours.
///
/// These are SOURCE assertions rather than behavioural ones, and deliberately
/// so: what they guard against is a call site being switched to `logout()`, or
/// the account-switch purge being dropped from `completeLogin()`. Both are
/// edits, not runtime states, and a behavioural test of `logout()` would need
/// the whole singleton graph — the manager resets it calls reach StoreKit,
/// push and CoreLocation.
final class SessionExpiryRetentionTests: XCTestCase {

    private var source: String {
        // Tests/TrackTests/ -> App/Managers/AuthManager.swift
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("App/Managers/AuthManager.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read AuthManager.swift at \(path.path)")
            return ""
        }
        return text
    }

    /// The body of one `func`, by name, up to the next declaration at the same
    /// indentation. Good enough for this file's flat member layout.
    private func body(of name: String) -> String {
        let src = source
        guard let start = src.range(of: "func \(name)(") else {
            XCTFail("\(name) not found — it was renamed or removed")
            return ""
        }
        let rest = src[start.upperBound...]
        if let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ") {
            return String(rest[..<end.lowerBound])
        }
        return String(rest)
    }

    // MARK: - The session-only path

    func testExpireSessionKeepsKeyMaterial() {
        let b = body(of: "expireSession")
        XCTAssertFalse(b.contains("deleteAll()"),
                       "expireSession must NOT wipe the keychain — that is what makes it recoverable")
        for slot in [".masterKey", ".sharingPrivateKey", ".privateKey", ".recoveryKey"] {
            XCTAssertFalse(b.contains(slot), "expireSession must not delete \(slot)")
        }
        XCTAssertFalse(b.contains("purgeAccountData"),
                       "expireSession must not purge caches — a same-user sign-in restores the app")
    }

    func testExpireSessionStillClearsTheSession() {
        let b = body(of: "expireSession")
        for slot in [".accessToken", ".refreshToken", ".tokenExpiry"] {
            XCTAssertTrue(b.contains("keychain.delete(key: \(slot))"),
                          "expireSession must clear \(slot) — they are dead")
        }
        XCTAssertTrue(b.contains("isAuthenticated = false"),
                      "isAuthenticated going false is what stands the revival paths down")
    }

    func testExpireSessionStopsLocation() {
        // A device with no session must not keep waking on location events.
        let b = body(of: "expireSession")
        XCTAssertTrue(b.contains("SDKLocationStreamer.shared.stop()"))
        XCTAssertTrue(b.contains("LocationService.shared.stopTracking()"))
    }

    // MARK: - The call sites

    func testServerRejectionsDoNotRunLogout() throws {
        // The two places the SERVER ends the session: the revoked-session
        // signal, and the definitive 401 at launch. Neither may wipe.
        let src = source
        // The revoked-session signal says so with the one "sign in
        // again" text, then expires the session.
        let handler = try XCTUnwrap(src.range(of: "private func handleSessionRevoked() async {"),
                                    "the revoked-session signal moved; re-check which teardown it runs")
        let revoked = try XCTUnwrap(src.range(of: "ErrorBanner.shared.postSignedOut()",
                                              range: handler.upperBound..<src.endIndex))
        let after = String(src[revoked.upperBound...].prefix(400))
        XCTAssertTrue(after.contains("expireSession()"),
                      "the revoked-session signal must run expireSession, not logout")
        XCTAssertFalse(after.contains("await logout()"),
                       "the revoked-session signal must not run logout")

        let definitive = try XCTUnwrap(src.range(of: "isSessionDefinitivelyExpired(error)"))
        let branch = String(src[definitive.upperBound...].prefix(600))
        XCTAssertTrue(branch.contains("expireSession()"),
                      "the definitive-401 branch must run expireSession, not logout")
    }

    func testDeliberateLogoutStillWipesEverything() {
        // The other half of the split. Deliberate sign-out and a deleted
        // account must still destroy the lot — retention is only for the
        // server-rejection path.
        let b = body(of: "logout")
        XCTAssertTrue(b.contains("keychain.deleteAll()"),
                      "logout must still wipe the keychain")
        XCTAssertTrue(b.contains("purgeAccountData()"),
                      "logout must still purge every account-scoped store")
    }

    // MARK: - The invariant that makes retention safe

    func testADifferentUserSigningInPurgesThePreviousAccount() {
        // THE load-bearing assertion. Retention means account A's keys and
        // caches outlive its session; if `completeLogin` stopped purging on a
        // switch, account B would decrypt under A's keys and read A's data.
        let b = body(of: "completeLogin")
        XCTAssertTrue(b.contains("let priorUserId = keychain.getString(for: .userId)"),
                      "completeLogin must read the outgoing user id BEFORE the new tokens land")
        XCTAssertTrue(b.contains("CanonicalId.of(prior) != me"),
                      "completeLogin must compare the outgoing and incoming user ids, in their one form")
        XCTAssertTrue(b.contains("await purgeAccountData()"),
                      "a different user must purge the previous account's stores")
        XCTAssertTrue(b.contains("deleteOutgoingKeyMaterial()"),
                      "a different user must delete the previous account's key material")
    }

    func testTheSwitchPurgeCannotDeleteTheIncomingSession() {
        // `completeLogin` has already saved the incoming tokens by the time the
        // purge runs, so the switch path must delete named slots rather than
        // call deleteAll() — which would sign the new user straight back out.
        let b = body(of: "deleteOutgoingKeyMaterial")
        XCTAssertFalse(b.contains("deleteAll()"))
        for owned in [".accessToken", ".refreshToken", ".tokenExpiry", ".userId"] {
            XCTAssertFalse(b.contains(owned),
                           "\(owned) belongs to the INCOMING account at this point")
        }
        XCTAssertTrue(b.contains(".masterKey"), "the outgoing master key must go")
        XCTAssertTrue(b.contains(".sharingPrivateKey"))
    }
}
