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

/// What the user is told when their personal (self-tracking) key is broken.
///
/// WHY THIS IS WORTH TESTING
///   Every failure of `SelfKeyManager.ensure()` must reach the screen, not
///   only the console. The worst branch — the server holds a self key this
///   device cannot unwrap, and personal tracking is not empty so replacing it
///   would destroy data — otherwise looks exactly like having no data:
///   personal history empty, personal places missing, circles working
///   normally, no explanation anywhere.
///
/// WHAT THESE PIN
///   Not the exact wording — that will change. What must survive an edit is
///   which states say something at all, and the two claims a user acts on:
///   that circles are unaffected, and that the repair comes from another
///   device.
final class SelfKeyHealthTests: XCTestCase {

    // MARK: - Which states speak

    /// A working key must not decorate Settings with a notice nobody needs.
    func testAWorkingKeySaysNothing() {
        XCTAssertNil(SelfKeyHealth.ok.notice)
    }

    /// Before `ensure()` has run — or with nobody signed in — there is nothing
    /// to report. Reporting a failure here would greet every cold launch with
    /// an alarm about a key that is merely not loaded yet.
    func testNotYetCheckedSaysNothing() {
        XCTAssertNil(SelfKeyHealth.unknown.notice)
    }

    /// The worst state reaches the user, not only the console.
    func testAnUnreadableStoredKeyIsSurfaced() throws {
        let notice = try XCTUnwrap(
            SelfKeyHealth.undecryptable.notice,
            "the branch that refuses to mint over live key material must reach the user"
        )
        XCTAssertEqual(notice.severity, .error, "nothing improves until the user acts")
        XCTAssertFalse(notice.title.isEmpty)
        XCTAssertFalse(notice.detail.isEmpty)
    }

    func testANoKeyStateIsSurfaced() throws {
        let notice = try XCTUnwrap(SelfKeyHealth.noAccountKeys.notice)
        XCTAssertEqual(notice.severity, .error, "nothing changes until the password is typed")
    }

    /// A setup that did not reach the server tries again by itself, so it
    /// is a warning that asks nothing.
    func testAFailedPublishIsOnlyAWarningAndAsksNothing() throws {
        let notice = try XCTUnwrap(SelfKeyHealth.publishFailed.notice)
        XCTAssertEqual(notice.severity, .warning)
        XCTAssertTrue(notice.detail.localizedCaseInsensitiveContains("as soon as this device reaches the server"),
                      notice.detail)
        XCTAssertFalse(SelfKeyHealth.publishFailed.asksForPassword)
    }

    /// A failed lookup is transient and destroys nothing, so it is a warning —
    /// not the red alarm that means "another device must act".
    func testAFailedLookupIsOnlyAWarning() throws {
        let notice = try XCTUnwrap(SelfKeyHealth.unreachable.notice)
        XCTAssertEqual(notice.severity, .warning)
    }

    // MARK: - What the worst state actually says

    /// Without an explanation the notice is just an alarm: the user cannot
    /// act, because the only device that can repair this is a different one.
    /// The repair happens by itself (this device reports the copy it can't
    /// open, another device of theirs republishes it), so the notice says what
    /// happens and names no button to press anywhere.
    func testTheUnreadableNoticeSaysItComesBackByItself() throws {
        let detail = try XCTUnwrap(SelfKeyHealth.undecryptable.notice?.detail)

        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("as soon as another of your devices that can show them is online"),
            "must say what brings it back; got: \(detail)"
        )
        for gone in ["Repair my other devices", "Security details", "sign out", "Signing out"] {
            XCTAssertFalse(detail.localizedCaseInsensitiveContains(gone), "\(gone): \(detail)")
        }
    }

    /// Nothing a person reads talks about keys: no notice mentions a
    /// "personal key" or where to "re-publish" it.
    func testNoNoticeTalksAboutKeys() {
        for state in [SelfKeyHealth.undecryptable, .replacementRefused, .noAccountKeys, .publishFailed, .unreachable,
                      .needsPassword] {
            guard let notice = state.notice else { XCTFail("\(state) says nothing"); continue }
            for text in [notice.title, notice.detail] {
                XCTAssertNil(text.range(of: #"\bkeys?\b|re-?publish"#, options: [.regularExpression, .caseInsensitive]),
                             "\(state): \(text)")
            }
        }
    }

    /// Scope. A user who reads "can't read your location" and concludes their
    /// circle has stopped seeing them will go and fix a thing that is not
    /// broken — the circle copy is encrypted under the circle key and is
    /// entirely unaffected by a bad self key.
    func testTheUnreadableNoticeSaysCirclesAreUnaffected() throws {
        let detail = try XCTUnwrap(SelfKeyHealth.undecryptable.notice?.detail)

        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("circles aren't affected"),
            "must bound the damage; got: \(detail)"
        )
    }

    /// Nothing a person reads asks them to do anything about it: not here,
    /// and not in the refusal's notice either.
    func testNeitherRepairNoticeAsksAnythingOfAnybody() throws {
        for state in [SelfKeyHealth.undecryptable, .replacementRefused] {
            let detail = try XCTUnwrap(state.notice?.detail)
            for asked in ["Repair my other devices", "Reopen", "sign out", "Signing out", "try again"] {
                XCTAssertFalse(detail.localizedCaseInsensitiveContains(asked), "\(state) \(asked): \(detail)")
            }
        }
    }

    /// The history works; only the check of the published copy waits for the
    /// password — a Settings note with the field, never a Map banner or prompt.
    func testTheSigningKeyStateAsksForThePasswordQuietly() throws {
        let notice = try XCTUnwrap(SelfKeyHealth.needsPassword.notice)
        XCTAssertEqual(notice.title, "Enter your password")
        XCTAssertEqual(notice.severity, .warning)
        XCTAssertTrue(SelfKeyHealth.needsPassword.asksForPassword)
        XCTAssertFalse(SelfKeyHealth.needsPassword.deservesTopLevelSurface)
        XCTAssertFalse(SelfKeyHealth.needsPassword.retriesItself, "only the password changes it")
    }

    /// ...whereas with no account keys on this device the password IS the
    /// remedy — asked for right where the notice is, never "sign out and back
    /// in". The two states need opposite advice; collapsing them into one
    /// message makes at least one of them wrong.
    func testTheNoKeyNoticeAsksForThePasswordInPlace() throws {
        let notice = try XCTUnwrap(SelfKeyHealth.noAccountKeys.notice)

        XCTAssertEqual(notice.title, "Enter your password")
        XCTAssertEqual(notice.detail, "This device needs your password to show your personal history and personal places. Nothing has been lost.")
        XCTAssertFalse(notice.detail.localizedCaseInsensitiveContains("sign out"), notice.detail)
        XCTAssertFalse(notice.detail.localizedCaseInsensitiveContains("sign in again"), notice.detail)
        XCTAssertNotEqual(
            SelfKeyHealth.noAccountKeys.notice,
            SelfKeyHealth.undecryptable.notice,
            "these two need opposite advice and must not share a message"
        )
        let asking = [SelfKeyHealth.unknown, .ok, .unreachable, .undecryptable, .replacementRefused,
                      .noAccountKeys, .publishFailed, .needsPassword].filter(\.asksForPassword)
        XCTAssertEqual(asking, [.noAccountKeys, .needsPassword], "only the states the password fixes ask for it")
    }

    /// Everything that can clear itself is tried again by the app; only the
    /// password state waits for the person.
    func testWhatRetriesItself() {
        for state in [SelfKeyHealth.unreachable, .publishFailed, .replacementRefused, .undecryptable] {
            XCTAssertTrue(state.retriesItself, "\(state)")
        }
        for state in [SelfKeyHealth.unknown, .ok, .noAccountKeys, .needsPassword] {
            XCTAssertFalse(state.retriesItself, "\(state)")
        }
    }

    /// `ensure()` fails closed on a lookup error rather than minting — that is
    /// what stops one flaky GET at launch from overwriting a good self key. The
    /// user is owed that fact; "couldn't check" alone reads like data loss.
    func testTheUnreachableNoticeSaysNothingWasChanged() throws {
        let detail = try XCTUnwrap(SelfKeyHealth.unreachable.notice?.detail)

        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("has been changed")
                || detail.localizedCaseInsensitiveContains("unchanged"),
            "must say the key was left alone; got: \(detail)"
        )
    }

    // MARK: - The server's refusal

    /// A refused replacement is a state of its own: a device whose new self
    /// key the server rejects (`key_self_key_in_use`) records no personal
    /// locations, so it must say so instead of reporting nothing.
    func testARefusedReplacementIsSurfaced() throws {
        let notice = try XCTUnwrap(
            SelfKeyHealth.replacementRefused.notice,
            "a refused publish leaves personal tracking off — the user has to be told"
        )
        XCTAssertEqual(notice.severity, .error)
        XCTAssertFalse(notice.title.isEmpty)
        XCTAssertFalse(notice.detail.isEmpty)
    }

    /// The one fact that makes a refusal actionable rather than alarming: the
    /// real key was not destroyed, it is on the server, and it can be
    /// re-published. Lose that and the notice is indistinguishable from data
    /// loss — the opposite of what happened.
    func testTheRefusedNoticeSaysTheKeyStillExists() throws {
        let detail = try XCTUnwrap(SelfKeyHealth.replacementRefused.notice?.detail)

        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("already has location history"),
            "must say what is stored survived; got: \(detail)"
        )
        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("as soon as another of your devices that can show it is online"),
            "must say what brings it back; got: \(detail)"
        )
        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("circles aren't affected"),
            "must bound the damage, as the sibling states do; got: \(detail)"
        )
    }

    /// Distinct from `undecryptable`, which is this device's own refusal to
    /// overwrite something it could not read and never clears itself. A refusal
    /// can clear on the next launch, because it proves a key is stored to be
    /// fetched — so the two must not share a message.
    func testARefusalIsNotTheSameNoticeAsAnUnreadableKey() throws {
        XCTAssertNotEqual(
            SelfKeyHealth.replacementRefused.notice,
            SelfKeyHealth.undecryptable.notice,
            "one says only another device can fix this; the other that this device keeps checking"
        )
        let detail = try XCTUnwrap(SelfKeyHealth.replacementRefused.notice?.detail)
        XCTAssertTrue(
            detail.localizedCaseInsensitiveContains("keeps checking by itself"),
            "a refusal is retried by the app itself, and the copy says so; got: \(detail)"
        )
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("Reopen"), "nobody is told to reopen anything")
    }

    // MARK: - Which states leave Settings

    /// Settings is a surface the user has to go looking for, and none of these
    /// states have another symptom — personal history just looks empty. The
    /// error states therefore also get a banner on the Map, exactly as the
    /// location-permission warning does. `unreachable` does not: it clears
    /// itself on the next successful lookup, and a banner on every flaky launch
    /// would train people to ignore the spot.
    func testOnlyTheErrorStatesReachTheMap() {
        XCTAssertTrue(SelfKeyHealth.undecryptable.deservesTopLevelSurface)
        XCTAssertTrue(SelfKeyHealth.replacementRefused.deservesTopLevelSurface)
        XCTAssertTrue(SelfKeyHealth.noAccountKeys.deservesTopLevelSurface,
                      "the Map's banner opens Settings, where the password is asked")

        XCTAssertFalse(SelfKeyHealth.unreachable.deservesTopLevelSurface,
                       "transient, and it says nothing was changed")
        XCTAssertFalse(SelfKeyHealth.publishFailed.deservesTopLevelSurface,
                       "it tries again by itself")
        XCTAssertFalse(SelfKeyHealth.ok.deservesTopLevelSurface)
        XCTAssertFalse(SelfKeyHealth.unknown.deservesTopLevelSurface)
    }

    // MARK: - The observable

    @MainActor
    func testStatusStartsQuietAndReportsWhatWasRecorded() {
        let status = SelfKeyStatus.shared
        let original = status.health
        defer { status.record(original) }

        status.record(.ok)
        XCTAssertNil(status.notice, "a healthy key must clear the notice")

        status.record(.undecryptable)
        XCTAssertEqual(status.notice, SelfKeyHealth.undecryptable.notice)
    }
}
