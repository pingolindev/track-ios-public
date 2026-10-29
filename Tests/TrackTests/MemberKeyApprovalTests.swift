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

/// "Approve" on "Member identity changed" pins exactly the keys the alert
/// carries.
///
/// It must not re-fetch the member's keys from
/// `GET /circles/{id}/member-public-keys`: the server serves that route to
/// owners and admins only, so for an ordinary member the fetch would 403 and
/// leave the pin on the old key, every later wrap signed with the new key
/// would be refused, and the circle would freeze with no message. For admins
/// it would pin whatever the server returned at that moment, not the key the
/// alert was about.
///
/// These run the real pin logic (a fresh, storage-less SDK `CryptoManager`, so
/// nothing touches this device's keychain). There is no role anywhere in the
/// approve path — it reads only what the alert carries — which is the
/// property that makes it work for a non-admin; the last test pins that the
/// owner/admin-only route stays out of it.
@MainActor
final class MemberKeyApprovalTests: XCTestCase {

    private let circleId = "7f1c2a9e-3b4d-4e5f-8a6b-1c2d3e4f5a6b"
    private let selfUserId = "0b8e7d6c-5a4b-4c3d-9e2f-1a0b9c8d7e6f"
    /// A PLAIN member (role "member") whose keys changed — e.g. after an email
    /// password reset. Nothing below depends on a role.
    private let memberUserId = "d4c3b2a1-9f8e-4d7c-8b6a-5e4f3a2b1c0d"

    private func hex(fromBase64 b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    /// A member identity as the roster serves it: lowercase hex keys.
    private func memberKeys() -> (sharing: String, signing: String) {
        let crypto = CryptoManager()
        let sharing = hex(fromBase64: crypto.generateKeypair().publicKey)
        let signing = hex(fromBase64: crypto.generateSigningKeypair().verifyingKeyB64)
        return (sharing, signing)
    }

    /// This device: its own identity loaded, as after a sign-in.
    private func device() -> CryptoManager {
        let crypto = CryptoManager()
        _ = crypto.generateKeypair()
        _ = crypto.generateSigningKeypair()
        return crypto
    }

    /// A pinner with its own once-a-day record, so one test's question does not
    /// silence the next test's.
    private func makePinner(_ crypto: CryptoManager) throws -> (MemberKeyPinner, UserDefaults) {
        let suite = "MemberKeyApprovalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (MemberKeyPinner(crypto: crypto, defaults: defaults), defaults)
    }

    func testApprovePinsExactlyTheAlertedKeys() throws {
        let crypto = device()
        let (pinner, _) = try makePinner(crypto)
        let old = memberKeys()
        let new = memberKeys()

        // First sighting pins silently.
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: old.sharing, signingPubkeyHex: old.signing)
        XCTAssertTrue(pinner.alerts.isEmpty)

        // The roster now serves different keys: an alert that CARRIES them.
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        let alert = try XCTUnwrap(pinner.alerts.first)
        XCTAssertEqual(alert.state, .changedBoth)
        XCTAssertEqual(alert.newSharingPubkeyHex, new.sharing)
        XCTAssertEqual(alert.newSigningPubkeyHex, new.signing)

        try pinner.approve(alert)

        XCTAssertEqual(crypto.pinnedSharingKey(circleId: circleId, userId: memberUserId), new.sharing,
                       "Approve must adopt the keys the alert was raised for")
        XCTAssertTrue(pinner.alerts.isEmpty, "an approved alert leaves the queue")

        // And it stays approved: the next roster refresh raises nothing — asked
        // through a pinner with no once-a-day record, which would otherwise
        // stay quiet whatever the pin said.
        let (fresh, _) = try makePinner(crypto)
        fresh.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                           sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        XCTAssertTrue(fresh.alerts.isEmpty, "the approved key must now MATCH, not re-alert")
    }

    /// The signing-strip downgrade (server stopped publishing a signing key for
    /// an already-pinned member — or a member reset on an app too old to have
    /// one). Nobody can confirm such keys, so nobody is asked: no question is
    /// queued, the server is asked to tell THEM to update, and they stay out
    /// with the old pin in place.
    func testAMemberWithoutASigningKeyIsNotAskedAboutButToldToUpdate() throws {
        let crypto = device()
        let (pinner, _) = try makePinner(crypto)
        var told: [String] = []
        pinner.askToUpdate = { circle, user in told.append("\(circle):\(user)") }
        let old = memberKeys()
        let substituted = memberKeys()

        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: old.sharing, signingPubkeyHex: old.signing)
        let blocked = pinner.gateMembersForRotation(
            circleId: circleId,
            currentUserId: selfUserId,
            members: [(userId: memberUserId, displayName: "Grandpa",
                       sharingPubkeyHex: substituted.sharing, signingPubkeyHex: nil)]
        )
        XCTAssertEqual(blocked, [memberUserId], "they stay out")
        XCTAssertTrue(pinner.alerts.isEmpty, "a question nobody can answer is not asked")
        XCTAssertEqual(told, ["\(circleId):\(memberUserId)"], "the server is asked to tell them")
        XCTAssertEqual(crypto.pinnedSharingKey(circleId: circleId, userId: memberUserId), old.sharing,
                       "the old pin stays canonical")

        // An alert without a signing key still cannot be approved, should one
        // ever reach "It's them".
        let alert = MemberKeyAlert(id: "\(circleId):\(memberUserId)", circleId: circleId, userId: memberUserId,
                                   displayName: "Grandpa", state: .changedSharing, previousPinnedAt: 0,
                                   newSharingPubkeyHex: substituted.sharing, newSigningPubkeyHex: nil,
                                   fingerprint: "x")
        XCTAssertThrowsError(try pinner.approve(alert)) { error in
            XCTAssertEqual(error as? MemberKeyApprovalError, .incompleteKeys)
        }
        XCTAssertEqual(MemberRow.askedToUpdate("Grandpa"), "Grandpa · Asked to update Pingolin")
    }

    /// The question names the person and the circle in plain words — nothing
    /// about keys — says to check another way when unsure, and shows their
    /// number (the security code, for the NEW keys).
    func testTheQuestionIsPlainAndShowsTheirNumber() throws {
        let crypto = device()
        let (pinner, _) = try makePinner(crypto)
        let old = memberKeys()
        let new = memberKeys()
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: old.sharing, signingPubkeyHex: old.signing)
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        var alert = try XCTUnwrap(pinner.alerts.first)
        let number = try crypto.computeSafetyNumber(
            selfUserId: selfUserId, peerUserId: memberUserId,
            peerSharingPubkeyHex: new.sharing, peerSigningPubkeyHex: new.signing)
        alert.number = number

        XCTAssertEqual(MemberKeyAlertHost.title(for: alert), "Is this really Grandpa?")
        let message = MemberKeyAlertHost.message(for: alert, circleName: "Family")
        XCTAssertEqual(message, "Grandpa reset their password, so Pingolin can't tell on its own that it's still them. If you're sure, let them back into Family.\n\nIf you're not sure, check with Grandpa another way first. Their number: \(number)")
        XCTAssertNil(message.range(of: "key", options: .caseInsensitive))
        XCTAssertTrue(MemberKeyAlertHost.message(for: alert, circleName: nil).contains("let them back into this circle."))
        alert.number = nil
        XCTAssertFalse(MemberKeyAlertHost.message(for: alert, circleName: "Family").contains("Their number"),
                       "no number line when there is no number")
    }

    /// Asked at most once a day per member on a device — the 20 s refresh and
    /// every circle they share would otherwise ask again and again.
    func testTheQuestionIsAskedOnceADayPerMember() throws {
        let crypto = device()
        let (pinner, defaults) = try makePinner(crypto)
        let old = memberKeys()
        let new = memberKeys()
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: old.sharing, signingPubkeyHex: old.signing)
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        let first = try XCTUnwrap(pinner.alerts.first)
        pinner.dismiss(first)  // answered elsewhere; the pin did not move

        // Another circle, same person, same day: not asked.
        pinner.askAboutChangedKeys(circleId: "another-circle", userId: memberUserId, displayName: "Grandpa",
                                   known: (old.sharing, old.signing),
                                   sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        XCTAssertTrue(pinner.alerts.isEmpty, "once a day per member, whatever the circle")

        // A day later: asked again.
        let dayAgo = Date().timeIntervalSince1970 - MemberKeyPinner.questionInterval - 60
        defaults.set([memberUserId.lowercased(): dayAgo], forKey: "memberKeyQuestion.askedAt")
        pinner.askAboutChangedKeys(circleId: "another-circle", userId: memberUserId, displayName: "Grandpa",
                                   known: (old.sharing, old.signing),
                                   sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        XCTAssertEqual(pinner.alerts.count, 1)
    }

    /// An answer that did not take is asked again at the next refresh, as its
    /// failure message promises — not a day later. (The SDK refuses keys that
    /// are not hex; a missing signing key raises no question at all.)
    func testAFailedAnswerIsAskedAgainAtTheNextRefresh() throws {
        let crypto = device()
        let (pinner, _) = try makePinner(crypto)
        let old = memberKeys()
        let substituted = memberKeys()
        let unusable = String(repeating: "zz", count: 32)
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: old.sharing, signingPubkeyHex: old.signing)
        pinner.askAboutChangedKeys(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                                   known: pinner.pinnedKeys(circleId: circleId, userId: memberUserId),
                                   sharingPubkeyHex: substituted.sharing, signingPubkeyHex: unusable)
        let alert = try XCTUnwrap(pinner.alerts.first)
        XCTAssertThrowsError(try pinner.approve(alert)) { error in
            guard case .notSaved = error as? MemberKeyApprovalError else { return XCTFail("\(error)") }
        }
        pinner.askAboutChangedKeys(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                                   known: pinner.pinnedKeys(circleId: circleId, userId: memberUserId),
                                   sharingPubkeyHex: substituted.sharing, signingPubkeyHex: unusable)
        XCTAssertEqual(pinner.alerts.count, 1)
    }

    /// Asking about someone this device has NOT confirmed — a subject
    /// conflict, a receive-only member — records no pin. Only `pinConfirmed`
    /// does, and only the caller's confirmation decides when that runs.
    func testAskingNeverPins() throws {
        let crypto = device()
        let (pinner, _) = try makePinner(crypto)
        let keys = memberKeys()
        pinner.askAboutChangedKeys(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                                   known: (nil, nil),
                                   sharingPubkeyHex: keys.sharing, signingPubkeyHex: keys.signing,
                                   receiveOnly: true)
        XCTAssertNil(crypto.pinnedSharingKey(circleId: circleId, userId: memberUserId), "asking pinned them")
        XCTAssertNil(crypto.pinnedSigningKey(circleId: circleId, userId: memberUserId))
        XCTAssertEqual(pinner.alerts.first?.receiveOnly, true)
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: keys.sharing, signingPubkeyHex: keys.signing)
        XCTAssertEqual(crypto.pinnedSharingKey(circleId: circleId, userId: memberUserId), keys.sharing,
                       "confirmed: pinned on first contact")
    }

    /// "Not now" (Block) keeps the old pin and suppresses only THIS identity for
    /// the session.
    func testBlockKeepsTheOldPin() throws {
        let crypto = device()
        let (pinner, _) = try makePinner(crypto)
        let old = memberKeys()
        let new = memberKeys()
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: old.sharing, signingPubkeyHex: old.signing)
        pinner.pinConfirmed(circleId: circleId, userId: memberUserId, displayName: "Grandpa",
                            sharingPubkeyHex: new.sharing, signingPubkeyHex: new.signing)
        let alert = try XCTUnwrap(pinner.alerts.first)
        pinner.block(alert)
        XCTAssertTrue(pinner.alerts.isEmpty)
        XCTAssertEqual(crypto.pinnedSharingKey(circleId: circleId, userId: memberUserId), old.sharing)
    }

    /// The approve path must not use the owner/admin-only route.
    func testApproveNeverFetchesMemberPublicKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try String(contentsOf: root.appendingPathComponent("App/Views/Circles/MemberKeyAlertHost.swift"),
                              encoding: .utf8)
        XCTAssertFalse(host.contains("memberPublicKeys"),
                       "member-public-keys is owner/admin only; a plain member's Approve would 403")
        XCTAssertFalse(host.contains("APIService"), "Approve needs nothing from the network")
        // The answer itself (`answerItsThem`) fetches nothing either.
        let manager = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(manager.range(of: "    func answerItsThem(_ alert: MemberKeyAlert) throws {"))
        let answer = manager[start.upperBound...].prefix(2_600)
        XCTAssertFalse(answer.contains("memberPublicKeys") || answer.contains("api."))
    }
}
