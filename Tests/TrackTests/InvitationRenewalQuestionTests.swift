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

/// Invitation renewal, on the inviter's side: an invitation whose invitee
/// reset their password is renewed only after "Is this really {email}?" →
/// "It's them", only for the keys the question showed, and only through the
/// SDK's `renewInvitation`, which verifies the original and copies its id,
/// times, kind and user id. Nothing is re-signed silently; an address
/// invitation never is.
final class InvitationRenewalQuestionTests: XCTestCase {

    private let circleId = "c0ffee00-0000-4000-8000-000000000001"
    private let me = "0b8e7d6c-5a4b-4c3d-9e2f-1a0b9c8d7e6f"
    private let other = "d4c3b2a1-9f8e-4d7c-8b6a-5e4f3a2b1c0d"

    // MARK: - Who asks: one question, never every admin

    /// Only the inviter's device, and only while this account is an owner or
    /// admin in its own record: an invitation whose signer left or was demoted
    /// is never renewed (the SDK refuses it), so nobody else asks about it.
    func testOnlyTheInvitersDeviceAsks() {
        typealias R = InvitationRenewals
        XCTAssertTrue(R.asksHere(me: me, signer: me.uppercased(), iAmOwnerOrAdmin: true))
        XCTAssertFalse(R.asksHere(me: me, signer: me, iAmOwnerOrAdmin: false), "no longer an owner or admin here")
        XCTAssertFalse(R.asksHere(me: me, signer: other, iAmOwnerOrAdmin: true), "someone else's invitation")
    }

    /// "Still shows" = the same account and both keys the question showed.
    func testTheAnswerSignsOnlyWhatTheQuestionShowed() throws {
        let question = InvitationRenewals.Question(
            circleId: circleId, inviteId: "i", email: "sam@example.com", subjectUserId: other,
            statementId: "s", originalStatementHex: "", originalSignatureHex: "",
            sharingKeyHex: "aa", signingKeyHex: "bb", number: nil)
        func lookup(_ user: String?, _ sharing: String?, _ signing: String?) throws -> UserPublicKeyResponse {
            var json: [String: Any] = ["email": "sam@example.com"]
            if let user { json["user_id"] = user }
            if let sharing { json["sharing_public_key"] = sharing }
            if let signing { json["signing_public_key"] = signing }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(UserPublicKeyResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertTrue(InvitationRenewals.stillShows(question, try lookup(other.uppercased(), "AA", "bb")))
        XCTAssertFalse(InvitationRenewals.stillShows(question, try lookup(other, "cc", "bb")), "the sharing key moved")
        XCTAssertFalse(InvitationRenewals.stillShows(question, try lookup(other, "aa", "cc")), "the signing key moved")
        XCTAssertFalse(InvitationRenewals.stillShows(question, try lookup(me, "aa", "bb")), "another account")
        XCTAssertFalse(InvitationRenewals.stillShows(question, try lookup(nil, nil, nil)), "no account any more")
    }

    // MARK: - The SDK's renewal, for real

    private func hex(_ b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    /// An inviter device holding the circle, and an invitee's old and new keys.
    private func setUp() throws -> (inviter: CryptoManager, old: (String, String), new: (String, String)) {
        let inviter = CryptoManager()
        _ = inviter.generateKeypair()
        _ = inviter.generateSigningKeypair()
        let creation = try inviter.prepareCircleCreation()
        try inviter.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        func keys() -> (String, String) {
            let c = CryptoManager()
            return (hex(c.generateKeypair().publicKey), hex(c.generateSigningKeypair().verifyingKeyB64))
        }
        return (inviter, keys(), keys())
    }

    private let clean = InvitationRenewalFacts(originalSignerIsOwnerOrAdminNow: true, renewerIsOwnerOrAdmin: true,
                                               subjectDepartedOrTombstoned: false, invitationWithdrawnOrDead: false)

    func testTheRenewalBindsTheQuestionsKeysAndKeepsEverythingElse() throws {
        let (inviter, old, new) = try setUp()
        let original = try inviter.signInvitationToAccount(
            circleId: circleId, signerUserId: me, subjectUserId: other,
            subjectSharingPublicKeyHex: old.0, subjectSigningPublicKeyHex: old.1)
        XCTAssertTrue(InvitationRenewals.keysChanged(original: original.statement, sharing: new.0, signing: new.1))
        XCTAssertFalse(InvitationRenewals.keysChanged(original: original.statement, sharing: old.0.uppercased(),
                                                      signing: old.1), "the same keys, whatever the case")

        let renewed = try inviter.renewInvitation(
            circleId: circleId, renewerUserId: me, originalStatementHex: original.statementHex,
            originalSignatureHex: original.signatureHex, newSubjectSharingPublicKeyHex: new.0,
            newSubjectSigningPublicKeyHex: new.1, facts: clean)
        let s = renewed.statement, o = original.statement
        XCTAssertEqual(s.kind, .invitationToAccount)
        XCTAssertEqual(s.statementId, o.statementId, "the same invitation")
        XCTAssertEqual(s.issuedAt, o.issuedAt)
        XCTAssertEqual(s.expiresAt, o.expiresAt, "it never outlives the original")
        XCTAssertEqual(s.subjectUserId, o.subjectUserId, "the same account")
        XCTAssertEqual(s.subjectSharingPublicKeyHex?.lowercased(), new.0)
        XCTAssertEqual(s.subjectSigningPublicKeyHex?.lowercased(), new.1)
        XCTAssertTrue(try inviter.verifyMembershipStatement(statementHex: renewed.statementHex,
                                                            signatureHex: renewed.signatureHex,
                                                            signerSigningPublicKeyHex: try inviter.signingPublicKeyHex()))
    }

    /// Everything a renewal may never do is refused by the SDK and signs
    /// nothing.
    func testWhatANewKeyRenewalMayNeverDo() throws {
        let (inviter, old, new) = try setUp()
        let original = try inviter.signInvitationToAccount(
            circleId: circleId, signerUserId: me, subjectUserId: other,
            subjectSharingPublicKeyHex: old.0, subjectSigningPublicKeyHex: old.1)
        func renew(_ facts: InvitationRenewalFacts, keys: (String, String), statement: SignedMembershipStatement? = nil) {
            let base = statement ?? original
            XCTAssertThrowsError(try inviter.renewInvitation(
                circleId: circleId, renewerUserId: me, originalStatementHex: base.statementHex,
                originalSignatureHex: base.signatureHex, newSubjectSharingPublicKeyHex: keys.0,
                newSubjectSigningPublicKeyHex: keys.1, facts: facts))
        }
        renew(clean, keys: old)  // a version-only re-sign
        renew(InvitationRenewalFacts(originalSignerIsOwnerOrAdminNow: false, renewerIsOwnerOrAdmin: true,
                                     subjectDepartedOrTombstoned: false, invitationWithdrawnOrDead: false), keys: new)
        renew(InvitationRenewalFacts(originalSignerIsOwnerOrAdminNow: true, renewerIsOwnerOrAdmin: false,
                                     subjectDepartedOrTombstoned: false, invitationWithdrawnOrDead: false), keys: new)
        renew(InvitationRenewalFacts(originalSignerIsOwnerOrAdminNow: true, renewerIsOwnerOrAdmin: true,
                                     subjectDepartedOrTombstoned: true, invitationWithdrawnOrDead: false), keys: new)
        renew(InvitationRenewalFacts(originalSignerIsOwnerOrAdminNow: true, renewerIsOwnerOrAdmin: true,
                                     subjectDepartedOrTombstoned: false, invitationWithdrawnOrDead: true), keys: new)
        // An address invitation is never renewed.
        renew(clean, keys: new, statement: try inviter.signInvitationToEmail(
            circleId: circleId, signerUserId: me, email: "sam@example.com"))
    }

    // MARK: - The facts come from THIS device's record

    func testTheFactsComeFromThisDevicesRecord() {
        typealias R = InvitationRenewals
        let statementId = "5e5e5e5e-0000-4000-8000-000000000009"
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        // This device's own pending invitation of `other`, under that
        // statement (what the renewal reads).
        var pending = CircleApprovalRecord()
        pending.recordInvitee(userId: other, statementId: statementId, expiresAt: 2_000_100_000)

        let mine = R.facts(record: pending, signer: me, me: me, iAmOwnerOrAdmin: true,
                           subject: other, statementId: statementId, withdrawnHere: [], now: now)
        XCTAssertTrue(mine.originalSignerIsOwnerOrAdminNow)
        XCTAssertTrue(mine.renewerIsOwnerOrAdmin)
        XCTAssertFalse(mine.subjectDepartedOrTombstoned)
        XCTAssertFalse(mine.invitationWithdrawnOrDead)
        // No longer an owner or admin here: neither holds.
        let demoted = R.facts(record: pending, signer: me, me: me, iAmOwnerOrAdmin: false,
                              subject: other, statementId: statementId, withdrawnHere: [], now: now)
        XCTAssertFalse(demoted.originalSignerIsOwnerOrAdminNow)
        XCTAssertFalse(demoted.renewerIsOwnerOrAdmin)
        // Someone else's invitation is never "the signer is an owner or admin now" here.
        XCTAssertFalse(R.facts(record: pending, signer: other, me: me, iAmOwnerOrAdmin: true,
                               subject: "x", statementId: statementId, withdrawnHere: [], now: now)
            .originalSignerIsOwnerOrAdminNow)

        // Not this device's pending invitation: no record, another statement,
        // or expired — the renewal is refused.
        for (record, why) in [(CircleApprovalRecord(), "no record"),
                              ({ var r = CircleApprovalRecord()
                                 r.recordInvitee(userId: other, statementId: "another", expiresAt: 2_000_100_000)
                                 return r }(), "another invitation"),
                              ({ var r = CircleApprovalRecord()
                                 r.recordInvitee(userId: other, statementId: statementId, expiresAt: 1_999_999_999)
                                 return r }(), "expired")] {
            XCTAssertTrue(R.facts(record: record, signer: me, me: me, iAmOwnerOrAdmin: true, subject: other,
                                  statementId: statementId, withdrawnHere: [], now: now).subjectDepartedOrTombstoned, why)
        }
        // Someone who left and was invited AGAIN is renewable: the record, not the tombstone.
        var reinvited = pending
        reinvited.tombstones[other] = ApprovalTombstone(statementIds: ["old"], activeVersion: 3)
        XCTAssertFalse(R.facts(record: reinvited, signer: me, me: me, iAmOwnerOrAdmin: true, subject: other,
                               statementId: statementId, withdrawnHere: [], now: now).subjectDepartedOrTombstoned)

        // A dead id: a tombstone carries it, it was withdrawn here, or it is in
        // the record's dead ids.
        var carried = pending
        carried.tombstones["someone"] = ApprovalTombstone(statementIds: [statementId.uppercased()], activeVersion: 3)
        XCTAssertTrue(R.facts(record: carried, signer: me, me: me, iAmOwnerOrAdmin: true, subject: other,
                              statementId: statementId, withdrawnHere: [], now: now).invitationWithdrawnOrDead)
        XCTAssertTrue(R.facts(record: pending, signer: me, me: me, iAmOwnerOrAdmin: true, subject: other,
                              statementId: statementId, withdrawnHere: [statementId.lowercased()], now: now)
            .invitationWithdrawnOrDead)
        var withdrawn = pending
        withdrawn.withdrawInvitation(statementId: statementId.uppercased())
        let dead = R.facts(record: withdrawn, signer: me, me: me, iAmOwnerOrAdmin: true, subject: other,
                           statementId: statementId, withdrawnHere: [], now: now)
        XCTAssertTrue(dead.invitationWithdrawnOrDead)
        XCTAssertTrue(dead.subjectDepartedOrTombstoned, "withdrawn: no longer pending here either")
    }

    /// A kind-3 admission proves "admitted", not "admin". Owner or
    /// admin = created here, else the circle list's role.
    func testOwnerOrAdminIsCreatedHereElseTheListsRole() {
        typealias R = InvitationRenewals
        XCTAssertTrue(R.ownerOrAdmin(createdHere: true, ownerInList: false, role: nil))
        XCTAssertTrue(R.ownerOrAdmin(createdHere: false, ownerInList: true, role: nil))
        XCTAssertTrue(R.ownerOrAdmin(createdHere: false, ownerInList: false, role: .admin))
        XCTAssertFalse(R.ownerOrAdmin(createdHere: false, ownerInList: false, role: .member))
        XCTAssertFalse(R.ownerOrAdmin(createdHere: false, ownerInList: false, role: nil))
        let renewals = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Managers/InvitationRenewals.swift"), encoding: .utf8)
        XCTAssertFalse(renewals?.contains("admissions") ?? true, "an admission is never taken for admin")
    }

    /// The original is checked BEFORE anyone is asked: unexpired, not a dead or
    /// withdrawn id, and this device's own pending invitation of its subject —
    /// not merely "no tombstone".
    func testTheOriginalIsCheckedBeforeAsking() throws {
        let (inviter, old, _) = try setUp()
        let original = try inviter.signInvitationToAccount(
            circleId: circleId, signerUserId: me, subjectUserId: other,
            subjectSharingPublicKeyHex: old.0, subjectSigningPublicKeyHex: old.1).statement
        let now = Date()
        typealias R = InvitationRenewals
        var pending = CircleApprovalRecord()
        pending.recordInvitee(userId: other.uppercased(), statementId: original.statementId.uppercased(),
                              expiresAt: original.expiresAt)
        XCTAssertTrue(R.originalHolds(original, record: pending, withdrawnHere: [], now: now))
        XCTAssertFalse(R.originalHolds(original, record: CircleApprovalRecord(), withdrawnHere: [], now: now),
                       "not this device's pending invitation")
        XCTAssertFalse(R.originalHolds(original, record: pending, withdrawnHere: [],
                                       now: Date(timeIntervalSince1970: TimeInterval(original.expiresAt + 1))),
                       "expired")
        XCTAssertFalse(R.originalHolds(original, record: pending,
                                       withdrawnHere: [original.statementId.lowercased()], now: now), "withdrawn here")
        var withdrawn = pending
        withdrawn.withdrawInvitation(statementId: original.statementId)
        XCTAssertFalse(R.originalHolds(original, record: withdrawn, withdrawnHere: [], now: now), "withdrawn: dead")
        var deadId = pending
        deadId.tombstones["someone"] = ApprovalTombstone(statementIds: [original.statementId.uppercased()],
                                                         activeVersion: 1)
        XCTAssertFalse(R.originalHolds(original, record: deadId, withdrawnHere: [], now: now), "a dead id")
        // A tombstone for the subject from an earlier membership does not stop
        // a renewal of this device's NEW invitation of them.
        var reinvited = pending
        reinvited.tombstones[other.uppercased()] = ApprovalTombstone(statementIds: [], activeVersion: 1)
        XCTAssertTrue(R.originalHolds(original, record: reinvited, withdrawnHere: [], now: now))
    }

    // MARK: - The wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testNothingIsSignedWithoutTheQuestion() throws {
        let renewals = try source("App/Managers/InvitationRenewals.swift")
        // Asked only for a renewal request, never for needs_renewal alone.
        XCTAssertTrue(renewals.contains("for invite in invites where invite.renewalRequested == true {"))
        XCTAssertFalse(renewals.contains("needsRenewal == true"))
        // Only an account invitation; the directory read here; once per id.
        XCTAssertTrue(renewals.contains("original.kind == .invitationToAccount"))
        XCTAssertTrue(renewals.contains("Self.keysChanged(original: original, sharing: sharing, signing: signing)"))
        XCTAssertTrue(renewals.contains("guard !Self.asked(owner: me).contains(statementId),"))
        // "It's them": the directory is read again BEFORE anything is signed.
        let answer = try XCTUnwrap(renewals.range(of: "func itsThem(_ question: Question, waiting: PendingChange? = nil) async throws {"))
        let body = renewals[answer.upperBound...]
        let reread = try XCTUnwrap(body.range(of: "lookup = try await api.lookupPublicKey(email: question.email)"))
        let sign = try XCTUnwrap(body.range(of: "let signed = try crypto.renewInvitation("))
        XCTAssertLessThan(reread.lowerBound, sign.lowerBound)
        // …and signs only when the directory still shows the question's keys.
        let still = try XCTUnwrap(body.range(of: "guard Self.stillShows(question, lookup) else {"))
        XCTAssertLessThan(still.lowerBound, sign.lowerBound)
        // Only the question's keys, and never a tombstone touched.
        XCTAssertTrue(body.contains("newSubjectSharingPublicKeyHex: question.sharingKeyHex,"))
        XCTAssertTrue(body.contains("memberPublicKeyHex: question.sharingKeyHex,"))
        XCTAssertFalse(renewals.contains("tombstones.removeValue"))
        XCTAssertFalse(renewals.contains("signMembershipStatement("), "no hand-rolled signing")
        // Verified before the question; asked again at most once.
        let consider = try XCTUnwrap(renewals.range(of: "private func consider("))
        let verify = try XCTUnwrap(renewals.range(of: "guard signedByMe, Self.originalHolds(", range: consider.upperBound..<renewals.endIndex))
        let lookup = try XCTUnwrap(renewals.range(of: "guard let lookup = try? await api.lookupPublicKey(email: email),", range: consider.upperBound..<renewals.endIndex))
        XCTAssertLessThan(verify.lowerBound, lookup.lowerBound, "nothing is asked about an original that doesn't hold")
        XCTAssertTrue(renewals.contains("guard !Self.reasked(owner: me).contains(question.id) else {"))
        // The renewal answered invite_lookup_changed: looked up again, asked
        // again (once); a check that can't be done keeps it waiting.
        XCTAssertTrue(renewals.contains("""
        } catch let error as APIError where error.isServerCode("invite_lookup_changed") {
            // The account's keys moved after the question: look them up again,
            // and ask again (at most once per invitation). A check that can't
            // be done keeps the renewal waiting, as above.
            let fresh: UserPublicKeyResponse
            do {
                fresh = try await api.lookupPublicKey(email: question.email)
            } catch where PendingChanges.addressCouldNotBeChecked(error) {
                try keep(question, addressUnchecked: true)
                return
            }
            try reaskOrDrop(question, lookup: fresh, me: me)
"""))
        // "Not them" withdraws for good.
        XCTAssertTrue(renewals.contains("_ = try await api.revokeInvite(circleId: question.circleId, inviteId: question.inviteId)"))
        XCTAssertTrue(renewals.contains("Self.markWithdrawn(question.statementId, owner: me)"))

        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("let renewing = responses.filter { $0.invitesNeedRenewal == true }.map(\\.id)"))
        XCTAssertTrue(manager.contains("await InvitationRenewals.shared.look(circleIds: renewing)"))
        let app = try source("App/TrackApp.swift")
        XCTAssertTrue(app.contains(".modifier(InvitationRenewalQuestionHost())"))
    }

    /// A device that is behind in the circle signs no renewal (the server
    /// refuses its `at_version`) and asks the server nothing: the answer waits
    /// as a `renewInvitation` change for exactly the keys shown, and the
    /// question is answered. The run later keeps the original id, so it needs
    /// no signed-id ledger.
    func testARenewalWhileBehindSignsNothingAndWaits() throws {
        let renewals = try source("App/Managers/InvitationRenewals.swift")
        let answer = try XCTUnwrap(renewals.range(of: "func itsThem(_ question: Question, waiting: PendingChange? = nil) async throws {"))
        let body = renewals[answer.upperBound...]
        let behind = try XCTUnwrap(body.range(of: """
                guard CircleManager.shared.holdsCurrentKey(for: question.circleId) else {
                    guard waiting == nil else { throw CircleManager.CircleError.waitingToSync }
        """), "a run refused while behind goes back to the runner")
        let queued = try XCTUnwrap(body.range(of: "            try keep(question, addressUnchecked: false)\n            return\n        }"))
        let keep = try XCTUnwrap(renewals.range(of: "    private func keep(_ question: Question, addressUnchecked: Bool) throws {"))
        let keepBody = renewals[keep.upperBound...].prefix(1_200)
        XCTAssertTrue(keepBody.contains("try PendingChanges.queue(\n            .renewInvitation, circleId: question.circleId,"))
        XCTAssertTrue(keepBody.contains("seen: .init(keys: MemberKeyPair(sharingKeyHex: question.sharingKeyHex,\n                                            signingKeyHex: question.signingKeyHex)),"),
                      "bound to the keys the question showed")
        XCTAssertTrue(keepBody.contains("expiresAt: original.map { Date(timeIntervalSince1970: TimeInterval($0.expiresAt)) },\n            addressUnchecked: addressUnchecked)"),
                      "until the invitation's own expiry")
        XCTAssertTrue(keepBody.contains("drop(question)\n        CircleQuestionNotifier.answered(.invitee, circleId: question.circleId, userId: question.subjectUserId)"))
        XCTAssertFalse(keepBody.prefix(900).contains("lookupPublicKey"), "keeping asks the server nothing")
        let lookup = try XCTUnwrap(body.range(of: "lookup = try await api.lookupPublicKey(email: question.email)"))
        let sign = try XCTUnwrap(body.range(of: "let signed = try crypto.renewInvitation("))
        let send = try XCTUnwrap(body.range(of: "_ = try await api.renewInvitation("))
        XCTAssertLessThan(behind.lowerBound, queued.lowerBound)
        XCTAssertLessThan(queued.lowerBound, lookup.lowerBound, "nothing is asked of the server either")
        XCTAssertLessThan(queued.lowerBound, sign.lowerBound, "nothing signed")
        XCTAssertLessThan(queued.lowerBound, send.lowerBound)
        XCTAssertEqual(CircleManager.CircleError.waitingToSync.errorDescription,
                       "Not done: this iPhone is still waiting to sync this circle's settings from another member.")

        // The question stays and waits for its circle; the others are asked.
        func question(_ circle: String, _ id: String) -> InvitationRenewals.Question {
            InvitationRenewals.Question(
                circleId: circle, inviteId: "i-\(id)", email: "sam@example.com", subjectUserId: other,
                statementId: id, originalStatementHex: "", originalSignatureHex: "",
                sharingKeyHex: "aa", signingKeyHex: "bb", number: nil)
        }
        let behindOne = question("c-behind", "s1"), fine = question("c-fine", "s2")
        var caughtUp: Set<String> = ["c-fine"]
        XCTAssertEqual(InvitationRenewals.next([behindOne, fine], waitingForSync: ["s1"],
                                               caughtUp: { caughtUp.contains($0) })?.id, "s2")
        XCTAssertNil(InvitationRenewals.next([behindOne], waitingForSync: ["s1"], caughtUp: { caughtUp.contains($0) }),
                     "not asked again while behind")
        caughtUp.insert("c-behind")
        XCTAssertEqual(InvitationRenewals.next([behindOne, fine], waitingForSync: ["s1"],
                                               caughtUp: { caughtUp.contains($0) })?.id, "s1",
                       "asked again once caught up")
        XCTAssertEqual(InvitationRenewals.next([behindOne], waitingForSync: [], caughtUp: { _ in false })?.id, "s1",
                       "a question not waiting is asked at once")

        // The host asks through `next`, and never over the outcome line.
        XCTAssertTrue(renewals.contains("guard pinner.alerts.isEmpty, answering == nil, outcome == nil else { return nil }"))
        XCTAssertTrue(renewals.contains("return InvitationRenewals.next(renewals.questions, waitingForSync: renewals.waitingForSync,"))
        let drop = try XCTUnwrap(renewals.range(of: "    private func drop(_ question: Question) {"))
        XCTAssertTrue(renewals[drop.upperBound...].prefix(200).contains("waitingForSync.remove(question.id)"))
    }

    /// What the server found nothing to do for is said in the app's words, by
    /// code; the server's `message` is never shown.
    func testNothingToRenewIsSaidInTheAppsWords() throws {
        let raw = "Invalid membership statement: at_version is not this circle's current key version"
        func said(_ code: String) -> String {
            InvitationRenewals.nothingToRenewText(APIError(code: code, message: raw, errorCode: code))
        }
        XCTAssertEqual(said("invite_not_renewable"),
                       "This invitation can't be renewed any more: you can no longer invite people to this circle.")
        XCTAssertEqual(said("invite_not_found"), "The invitation isn't there any more, so there was nothing to renew.")
        XCTAssertEqual(said("invite_changed"),
                       "The invitation was answered, withdrawn or renewed meanwhile, so there was nothing to renew.")
        // An unknown refusal of the renewal (say, invalid statement): a plain line.
        let unknown = APIError(code: "invite_invalid_statement", message: raw, errorCode: "invite_invalid_statement")
        XCTAssertEqual(unknown.localizedDescription, "That didn't work. Please try again.")
        let renewals = try source("App/Managers/InvitationRenewals.swift")
        XCTAssertFalse(renewals.contains("error.message"), "no server text reaches the outcome")
        XCTAssertTrue(renewals.contains("throw RenewalError.notDone(Self.nothingToRenewText(error))"))
    }

    func testTheQuestionNotificationSaysWhatHappened() {
        XCTAssertEqual(CircleQuestionCopy.body(.invitee, name: "sam@example.com", circle: nil, level: nil),
                       "sam@example.com reset their password. Check it's really them.")
        XCTAssertEqual(CircleQuestionCopy.body(.invitee, name: "sam@example.com", circle: nil, level: "generic"),
                       "A circle needs your answer.")
    }
}
