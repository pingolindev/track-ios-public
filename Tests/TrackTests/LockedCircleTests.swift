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

/// An unreadable circle is one "Locked circle" with a reason chosen from what
/// the device observed, and wording chosen by that reason. A bare "Encrypted
/// Circle", explained nowhere, reads as "my data is gone" after an email
/// password reset, and the recovery key that could restore it gets thrown
/// away.
final class LockedCircleTests: XCTestCase {

    // MARK: - Which cause

    private func reason(
        deviceHasAccountKeys: Bool = true,
        hasWrapForUs: Bool = true,
        wrapRefused: Bool = false,
        wrapFailedToOpen: Bool = false,
        holdsSomeKey: Bool = false,
        leftPending: Bool = false,
        accountHasPreResetData: Bool? = nil,
        previousReason: CircleLockReason? = nil
    ) -> CircleLockReason {
        CircleManager.lockReason(
            deviceHasAccountKeys: deviceHasAccountKeys,
            hasWrapForUs: hasWrapForUs,
            wrapRefused: wrapRefused,
            wrapFailedToOpen: wrapFailedToOpen,
            holdsSomeKey: holdsSomeKey,
            leftPending: leftPending,
            accountHasPreResetData: accountHasPreResetData,
            previousReason: previousReason
        )
    }

    /// No account keys on the device outranks everything: every wrap fails to
    /// open then, and the fix is signing in again, not anything per circle.
    func testNoAccountKeysIsTheCauseWhateverElseFailed() {
        XCTAssertEqual(reason(deviceHasAccountKeys: false, wrapFailedToOpen: true), .keysNotUnlocked)
        XCTAssertEqual(reason(deviceHasAccountKeys: false, wrapRefused: true), .keysNotUnlocked)
        XCTAssertEqual(reason(deviceHasAccountKeys: false, hasWrapForUs: false), .keysNotUnlocked)
    }

    func testARefusedWrapIsAVerificationProblem() {
        XCTAssertEqual(reason(wrapRefused: true, holdsSomeKey: true), .keyNotVerified)
    }

    func testAnUnopenableWrapPointsAtTheResetOnlyWhenThereIsPreResetData() {
        XCTAssertEqual(reason(wrapFailedToOpen: true, accountHasPreResetData: true), .sealedBeforeReset)
        XCTAssertEqual(reason(wrapFailedToOpen: true, accountHasPreResetData: false), .keyUnreadable)
        XCTAssertEqual(reason(wrapFailedToOpen: true, accountHasPreResetData: nil), .keyUnreadable,
                       "not knowing is not a reset — the probe refines it later")
    }

    /// A rotation that left us pending: we hold an older key, the name is
    /// under the new one, and only an owner/admin's approval brings it.
    func testARotationThatLeftUsOutIsNotAMinuteAway() {
        XCTAssertEqual(reason(holdsSomeKey: true, leftPending: true), .awaitingNewerKey)
        XCTAssertEqual(reason(wrapRefused: true, holdsSomeKey: true, leftPending: true), .keyNotVerified,
                       "a refused wrap is the more specific cause")
    }

    /// `member_key_version` labels our own wrap; an older server sends none.
    func testOurWrapIsLabelledWithItsOwnVersion() throws {
        func row(_ json: String) throws -> CircleResponse {
            try APIService.decodeResponseBody(Data(json.utf8))
        }
        let base = #""id":"11111111-1111-4111-8111-1111111111c1","owner_id":"u1","is_owner":false,"encrypted_name":{"nonce":"00","ciphertext":"00"},"day_bucket":20000,"member_count":2,"key_version":5"#
        let pending = try row("{" + base + #","member_key_version":3,"key_rotation_needed":true,"key_rotation_cause":"member_removed"}"#)
        XCTAssertEqual(CircleManager.ownWrapVersion(pending), 3)
        XCTAssertEqual(pending.keyRotationCause, "member_removed")
        let old = try row("{" + base + "}")
        XCTAssertEqual(CircleManager.ownWrapVersion(old), 5, "an older server's only label")
        XCTAssertNil(old.keyRotationCause)
    }

    func testNoWrapAndNoKeyIsAKeylessJoin() {
        XCTAssertEqual(reason(hasWrapForUs: false, holdsSomeKey: false), .awaitingKey)
    }

    func testAHeldKeyThatDoesNotOpenTheNameIsOutOfDate() {
        XCTAssertEqual(reason(hasWrapForUs: true, holdsSomeKey: true), .keyOutOfDate)
    }

    func testALightPassKeepsWhatItKnew() {
        XCTAssertEqual(reason(previousReason: .sealedBeforeReset), .sealedBeforeReset)
        XCTAssertEqual(reason(), .keyUnavailable)
    }

    // MARK: - What it says

    private let allReasons: [CircleLockReason] = [
        .keysNotUnlocked, .awaitingKey, .keyNotVerified, .sealedBeforeReset,
        .keyUnreadable, .keyOutOfDate, .awaitingNewerKey, .keyUnavailable,
    ]

    /// "Never tell an owner to wait for the owner": an owner who has reset
    /// their password must not be told to wait for the circle's owner.
    func testAnOwnerIsNeverToldToWaitForTheOwner() {
        for reason in allReasons {
            let text = reason.copy(isOwner: true).explanation.lowercased()
            XCTAssertFalse(text.contains("circle's owner"), "\(reason): \(text)")
            XCTAssertFalse(text.contains("waiting for the owner"), "\(reason): \(text)")
            XCTAssertFalse(text.contains("owner or an admin opens"), "\(reason): \(text)")
        }
    }

    func testAfterTheirOwnResetTheyAreSentToTheRecoveryRestore() {
        let copy = CircleLockReason.sealedBeforeReset.copy(isOwner: false, circleName: "Family", device: "phone")
        XCTAssertTrue(copy.opensAccountSettings)
        XCTAssertEqual(copy.title, "Waiting for your circle")
        // What happens now — this phone asks by itself and the members
        // are asked with a notification — not "will be asked".
        XCTAssertEqual(copy.explanation, "You reset your password, so another member of Family has been asked to confirm it's you. It opens here as soon as one of them does. If you still have your recovery key, you can restore your previous setup instead: Account → Settings → Data from before your password reset.")
        XCTAssertFalse(copy.asksForPassword)
        XCTAssertEqual(CircleLockReason.sealedBeforeReset.copy(isOwner: true, circleName: "Family", device: "phone"), copy,
                       "the reset case reads the same for an owner")
        // The link lands on that section (the account site's anchor).
        let original = AppConfiguration.shared.environment
        defer { AppConfiguration.shared.environment = original }
        for env in AppEnvironment.allCases {
            AppConfiguration.shared.environment = env
            XCTAssertEqual(AppConfiguration.shared.preResetDataURL?.absoluteString,
                           env.accountBaseURL + "/settings#pre-reset-data")
            XCTAssertEqual(AppConfiguration.shared.preResetDataURL?.path, "/settings")
            XCTAssertEqual(AppConfiguration.shared.preResetDataURL?.fragment, "pre-reset-data")
        }
    }

    /// The password is asked for right here, never "sign out, then sign
    /// in again" — nothing is signed out and nothing is lost.
    func testMissingKeysOnThisDeviceAskForThePasswordInPlace() {
        let copy = CircleLockReason.keysNotUnlocked.copy(isOwner: false, circleName: "Family", device: "phone")
        XCTAssertEqual(copy.title, "Enter your password")
        XCTAssertEqual(copy.caption, "Enter your password to open your circles")
        XCTAssertEqual(copy.explanation, "This phone needs your password to open your circles. Nothing has been lost.")
        XCTAssertTrue(copy.asksForPassword)
        XCTAssertFalse(copy.opensAccountSettings)
        for reason in allReasons where reason != .keysNotUnlocked {
            for owner in [false, true] {
                XCTAssertFalse(reason.copy(isOwner: owner).asksForPassword, "\(reason) owner=\(owner)")
            }
        }
    }

    /// No state tells anybody to sign out, sign in again, or reopen the app.
    func testNoStateAsksForASignOutOrASignIn() {
        for reason in allReasons {
            for owner in [false, true] {
                let copy = reason.copy(isOwner: owner, circleName: "Family", device: "phone")
                for text in [copy.title, copy.caption, copy.explanation] {
                    for phrase in ["sign out", "sign in again", "signing out", "reopen", "open pingolin", "ask "] {
                        XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), "\(reason): \(text)")
                    }
                }
            }
        }
    }

    /// The field sits under the explanation on the circle's screen.
    func testTheLockedCircleScreenShowsThePasswordField() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notice = try String(contentsOf: root.appendingPathComponent("App/Views/Circles/LockedCircleNotice.swift"),
                                encoding: .utf8)
        XCTAssertTrue(notice.contains("""
                if copy.asksForPassword {
                    PasswordUnlockForm()
                }
"""))
    }

    /// Word for word: what each state says, and when it ends.
    func testEachStateSaysWhatHappensAndWhen() {
        func copy(_ reason: CircleLockReason, owner: Bool = false) -> LockedCircleCopy {
            reason.copy(isOwner: owner, circleName: "Family", device: "phone")
        }
        XCTAssertEqual(copy(.awaitingKey).title, "Almost ready")
        XCTAssertEqual(copy(.awaitingKey).explanation,
                       "You've joined Family. It opens here as soon as another member's app is online, usually within a minute.")
        // Behind, or can't open its copy: "Waiting to sync", for owners too
        // — an owner did not just join their own circle.
        for reason: CircleLockReason in [.keyOutOfDate, .awaitingNewerKey, .keyNotVerified, .keyUnreadable, .keyUnavailable] {
            for owner in [false, true] {
                XCTAssertEqual(copy(reason, owner: owner).title, "Waiting to sync", "\(reason)")
                XCTAssertEqual(copy(reason, owner: owner).caption, "Waiting to sync", "\(reason)")
                XCTAssertEqual(copy(reason, owner: owner).explanation,
                               "Awaiting sync for circle settings from another member. Locations will be queued until synced.",
                               "\(reason)")
            }
        }
        XCTAssertEqual(copy(.awaitingKey, owner: true).title, "Waiting to sync",
                       "an owner did not just join their own circle")
        // A refused write says only what is true: no "try again", no
        // promise. The words above stay for the state.
        let refused = "Not done: this iPhone is still waiting to sync this circle's settings from another member."
        XCTAssertEqual(CircleManager.CircleError.waitingToSync.errorDescription, refused, "an invitation or admission")
        XCTAssertEqual(CircleManager.CircleError.keyNotCurrent.errorDescription, refused, "a new place, check-in or alert")
    }

    /// The member removal refused while this device is behind says the same,
    /// whichever way it is behind.
    func testARefusedRemovalSaysOnlyWhatIsTrue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(manager.contains("throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)"))
        for gone in ["Try again once it has synced", "let it sync, then try again"] {
            XCTAssertFalse(manager.contains(gone), gone)
        }
    }

    /// Nothing a person reads talks about keys.
    func testNoStateTalksAboutKeys() throws {
        let banned = try NSRegularExpression(
            pattern: #"\bkeys?\b|\bwrap|\bpin(s|ned)?\b|rotat|re-key|safety number|encrypt|approve|\badmin"#,
            options: [.caseInsensitive])
        for reason in allReasons {
            for owner in [false, true] {
                let copy = reason.copy(isOwner: owner, circleName: "Family", device: "phone")
                for text in [copy.title, copy.caption, copy.explanation] {
                    // "recovery key" is a product noun the user holds (allowed).
                    let checked = text.replacingOccurrences(of: "recovery key", with: "")
                    let range = NSRange(checked.startIndex..., in: checked)
                    XCTAssertNil(banned.firstMatch(in: checked, range: range), "\(reason) owner=\(owner): \(text)")
                }
            }
        }
    }

    // MARK: - Invitations open without an owner or admin

    func testInviteCopySaysItOpensWhenAMemberIsOnline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Views/Circles/CirclesView.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(circles.contains("You can accept now. It opens as soon as another member's app is online."))
        XCTAssertFalse(circles.contains("approves your access"))
        XCTAssertFalse(circles.contains("approves their access"))
        XCTAssertFalse(circles.contains("circle's key"))
    }

    // MARK: - The auth responses behind the reset case

    /// `/api/v1/auth/archived-recovery` — non-empty means the portal can restore
    /// pre-reset data, which is what upgrades an unopenable wrap to
    /// `.sealedBeforeReset`. Shape as the auth server sends it.
    func testArchivedRecoveryDecodes() throws {
        let body = Data("""
        {"success":true,"data":{"archived":[{"key_version":1,
          "archived_at":"2026-09-20T10:00:00+00:00","kdf_salt":"c2FsdA==",
          "encrypted_master_key_for_recovery":{"nonce":"bg==","ciphertext":"Yw=="},
          "encrypted_sharing_private_key":{"nonce":"bg==","ciphertext":"Yw=="},
          "encrypted_signing_private_key":{"nonce":"bg==","ciphertext":"Yw=="}}]}}
        """.utf8)
        let list: ArchivedRecoveryListResponse = try APIService.decodeResponseBody(body)
        XCTAssertEqual(list.archived.map(\.keyVersion), [1])

        let empty: ArchivedRecoveryListResponse = try APIService.decodeResponseBody(
            Data(#"{"success":true,"data":{"archived":[]}}"#.utf8))
        XCTAssertTrue(empty.archived.isEmpty)
    }

    /// `/api/v1/auth/previous-identities` — what the portal's restore hands this
    /// app. If it does not decode, restoring in the portal changes nothing on
    /// iOS, and pointing people there (above) is a dead end. Shape as the auth
    /// server sends it, through the app's live wire decoder.
    func testPreviousIdentitiesDecodeThroughTheWireDecoder() throws {
        let body = Data("""
        {"success":true,"data":{"identities":[{"key_version":1,
          "adopted_at":"2026-09-21T09:00:00+00:00",
          "sharing_public_key":"AAAA","signing_public_key":"AAAA",
          "encrypted_sharing_private_key":{"nonce":"bg==","ciphertext":"Yw=="},
          "encrypted_signing_private_key":{"nonce":"bg==","ciphertext":"Yw=="},
          "app_sealed_private_key":{"nonce":"bm9uY2U=","ciphertext":"Y2lwaGVy"}}]}}
        """.utf8)
        let response: PreviousIdentitiesResponse = try APIService.decodeResponseBody(body)
        XCTAssertEqual(response.identities.count, 1)
        XCTAssertEqual(response.identities.first?.keyVersion, 1)
        XCTAssertEqual(response.identities.first?.appSealedPrivateKey?.nonce, "bm9uY2U=",
                       "the app-sealed key is the one thing Track reads from a restore")
    }
}
