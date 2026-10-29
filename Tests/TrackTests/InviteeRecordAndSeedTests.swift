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

/// The invitee record and the transition seed, through the real roster pass
/// (`AccessHandover.rosterPass`) and delivery pass
/// (`AccessHandover.deliveries`) with the SDK's own signatures.
///
/// The transition seed: the one-time seed trusts, and tombstones, nobody from
/// a pin alone — a pinned user the first complete roster does not list gets
/// nothing (pins written by older builds can belong to departed members, or to
/// invitees pinned at invite time).
///
/// The invitee record: this device's invitee record is bound to the statement
/// it signed and that statement's expiry; it makes the invitee chosen only by
/// appearing with THAT invitation in time, is never tombstoned while pending,
/// and goes on appearance, withdrawal and expiry. An own statement makes
/// anyone chosen only until it expires (+5 min); a withdrawn one is dead.
final class InviteeRecordAndSeedTests: XCTestCase {

    private let circleId = "c0ffee00-0000-4000-8000-0000000000bb"
    private let now = Date()

    private static func hex(_ b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    /// An account and one device of it.
    private struct Party {
        let userId = UUID().uuidString.lowercased()
        let name: String
        let sdk = CryptoManager()
        let sharing: String
        let signing: String

        init(_ name: String) {
            self.name = name
            sharing = InviteeRecordAndSeedTests.hex(sdk.generateKeypair().publicKey)
            signing = InviteeRecordAndSeedTests.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }
    }

    /// `signer` invites `subject` to their account, as the app does (the
    /// signer holds the circle), or — for a member whose device is not part of
    /// the test — with the statement spelled out.
    private func invite(by signer: Party, _ subject: Party) throws -> (row: [String: Any], statement: MembershipStatement) {
        let signed: SignedMembershipStatement
        if signer.sdk.hasCircleKey(circleId: circleId) {
            signed = try signer.sdk.signInvitationToAccount(
                circleId: circleId, signerUserId: signer.userId, subjectUserId: subject.userId,
                subjectSharingPublicKeyHex: subject.sharing, subjectSigningPublicKeyHex: subject.signing)
        } else {
            let issued = Int64(now.timeIntervalSince1970)
            signed = try signer.sdk.signMembershipStatement(statement: MembershipStatement(
                kind: .invitationToAccount, circleId: circleId, statementId: UUID().uuidString.lowercased(),
                signerUserId: signer.userId, issuedAt: issued, expiresAt: issued + 604_800, atVersion: 1,
                subjectUserId: subject.userId, subjectSharingPublicKeyHex: subject.sharing,
                subjectSigningPublicKeyHex: subject.signing, subjectEmail: nil))
        }
        return (["statement": signed.statementHex, "signature": signed.signatureHex],
                try signer.sdk.parseMembershipStatement(statementHex: signed.statementHex))
    }

    /// A roster row as the server serves it (snake_case).
    private func row(_ party: Party, role: String = "member", keyVersion: Int? = 1,
                     invitation: [String: Any]? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "user_id": party.userId, "display_name": party.name, "role": role,
            "encrypted_circle_key": ["nonce": "", "ciphertext": ""], "ephemeral_public_key": "",
            "can_see_history": true, "can_see_realtime": true, "status": "active",
            "joined_day_bucket": Int(now.timeIntervalSince1970 / 86_400) - 30,
            "sharing_public_key": party.sharing, "signing_public_key": party.signing,
        ]
        if let keyVersion { row["key_version"] = keyVersion }
        if let invitation { row["invitation"] = invitation }
        return row
    }

    private func roster(_ rows: [[String: Any]]) throws -> [CircleMemberResponse] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([CircleMemberResponse].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    /// This device (`me`), the circle's creator, holding the circle.
    private func owner() throws -> Party {
        let me = Party("Maya")
        let creation = try me.sdk.prepareCircleCreation()
        try me.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        return me
    }

    private func pass(_ me: Party, _ roster: [CircleMemberResponse], stored: CircleApprovalRecord,
                      activeVersion: Int = 1, complete: Bool = true, at: Date? = nil) -> AccessHandover.RosterPass {
        AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me.userId, email: nil, crypto: me.sdk), roster: roster,
            rosterComplete: complete, activeVersion: activeVersion, stored: stored, checker: me.sdk, now: at ?? now)
    }

    /// Whom this device would hand the circle's current version to.
    private func delivered(_ me: Party, _ roster: [CircleMemberResponse], _ pass: AccessHandover.RosterPass,
                           version: Int = 1, at: Date? = nil) -> [String] {
        AccessHandover.deliveries(
            me: me.userId, circleKeyVersion: version, heldVersion: version,
            createdHere: AccessHandover.createdHere(pass.record, me: me.userId),
            members: roster.map { AccessHandover.Member(userId: $0.userId, displayName: "m",
                                                        sharingKeyHex: $0.sharingPublicKey, signingKeyHex: $0.signingPublicKey) },
            candidates: pass.candidates, result: pass.result, record: pass.record, now: at ?? now,
            pinGate: AccessHandover.readOnlyPinGate(
                me: me.userId, circleId: circleId,
                pinnedSharing: { me.sdk.pinnedSharingKey(circleId: $0, userId: $1) },
                pinnedSigning: { me.sdk.pinnedSigningKey(circleId: $0, userId: $1) })
        ).map(\.userId)
    }

    private func createdHere(_ me: Party) -> CircleApprovalRecord {
        var record = CircleApprovalRecord()
        record.entries[me.userId] = .ownAction
        return record
    }

    // MARK: - The invitee record

    /// invite → the circle rotates → roster passes without them: the invitee
    /// is never tombstoned, the invitation is still renewable here, and they
    /// join as this device's own choice and are handed the circle.
    func testInviteThenRotateThenPassStaysRenewableAndJoins() throws {
        let me = try owner(), newcomer = Party("Nadia")
        let (invitation, statement) = try invite(by: me, newcomer)
        var stored = createdHere(me)
        stored.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)

        // The circle moved to version 2 before they joined; a complete roster
        // without them, twice.
        let alone = try roster([row(me, role: "owner", keyVersion: 2)])
        var record = pass(me, alone, stored: stored, activeVersion: 2).record
        record = pass(me, alone, stored: record, activeVersion: 2).record
        XCTAssertNil(record.tombstones[newcomer.userId], "never tombstoned while pending")
        XCTAssertNotNil(record.invitees[newcomer.userId])
        XCTAssertTrue(InvitationRenewals.originalHolds(statement, record: record, withdrawnHere: [], now: now),
                      "still renewable here")
        XCTAssertFalse(InvitationRenewals.facts(record: record, signer: me.userId, me: me.userId, iAmOwnerOrAdmin: true,
                                                subject: newcomer.userId, statementId: statement.statementId,
                                                withdrawnHere: [], now: now).subjectDepartedOrTombstoned)

        // They join with THAT invitation (keyless: its wrap was of version 1).
        let joined = try roster([row(me, role: "owner", keyVersion: 2),
                                 row(newcomer, keyVersion: nil, invitation: invitation)])
        let after = pass(me, joined, stored: record, activeVersion: 2)
        XCTAssertEqual(after.result.verdicts[newcomer.userId], .confirmed(.ownAction))
        XCTAssertEqual(after.record.entries[newcomer.userId], .ownAction, "a permanent entry")
        XCTAssertTrue(after.record.invitees.isEmpty, "the record goes on appearance")
        XCTAssertEqual(delivered(me, joined, after, version: 2), [newcomer.userId])

        // A permanent choice: long after the invitation expired, still chosen.
        let later = Date(timeIntervalSince1970: TimeInterval(statement.expiresAt + 86_400))
        XCTAssertEqual(pass(me, joined, stored: after.record, activeVersion: 2, at: later).result.verdicts[newcomer.userId],
                       .confirmed(.ownAction))
    }

    /// Withdrawn here, then listed again with it: the id is dead — not chosen,
    /// not confirmed, not handed anything. On an admin's device (not the
    /// circle's creator): nothing here is about rotations.
    func testAWithdrawnInvitationListedAgainGetsNothing() throws {
        let me = try owner(), newcomer = Party("Nadia")
        let (invitation, statement) = try invite(by: me, newcomer)
        var stored = CircleApprovalRecord()
        stored.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)
        stored.withdrawInvitation(statementId: statement.statementId.uppercased())
        XCTAssertTrue(stored.invitees.isEmpty)

        let listed = try roster([row(me, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation)])
        let result = pass(me, listed, stored: stored)
        XCTAssertEqual(result.result.verdicts[newcomer.userId], .invalid)
        XCTAssertNil(result.record.entries[newcomer.userId])
        XCTAssertEqual(delivered(me, listed, result), [])

        // Control: the same roster, not withdrawn, hands it over (this device's
        // own choice, live).
        var live = CircleApprovalRecord()
        live.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)
        XCTAssertEqual(delivered(me, listed, pass(me, listed, stored: live)), [newcomer.userId])
    }

    /// Expired, then listed again: not chosen (through the record or its own
    /// statement), and on an admin's device an expired invitation delivers
    /// nothing (only an unexpired one does). (The circle's creator hands the
    /// circle to anyone confirmed.)
    func testAnExpiredInvitationListedAgainIsNotChosen() throws {
        let me = try owner(), newcomer = Party("Nadia")
        let (invitation, statement) = try invite(by: me, newcomer)
        var stored = CircleApprovalRecord()  // an admin here, not the creator
        stored.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)
        let expired = Date(timeIntervalSince1970: TimeInterval(statement.expiresAt + CircleApprovalRecord.inviteeGrace + 1))

        let listed = try roster([row(me, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation)])
        let result = pass(me, listed, stored: stored, at: expired)
        XCTAssertNotEqual(result.result.verdicts[newcomer.userId], .confirmed(.ownAction))
        XCTAssertNil(result.record.entries[newcomer.userId].flatMap { $0.isChosen ? $0 : nil })
        XCTAssertTrue(result.record.invitees.isEmpty)
        XCTAssertEqual(delivered(me, listed, result, at: expired), [])

        // Just inside the grace, still chosen.
        let inGrace = Date(timeIntervalSince1970: TimeInterval(statement.expiresAt + CircleApprovalRecord.inviteeGrace))
        XCTAssertEqual(pass(me, listed, stored: stored, at: inGrace).result.verdicts[newcomer.userId],
                       .confirmed(.ownAction))

        // Unseen, the record goes at expiry too.
        var unseen = stored
        unseen.settleInvitees(roster: [:], now: Int64(expired.timeIntervalSince1970))
        XCTAssertTrue(unseen.invitees.isEmpty)
    }

    /// A dead id never makes anyone chosen through the record either — say a
    /// withdrawal merged in from another write while the record stayed.
    func testADeadIdIsNeverChosenThroughTheRecord() throws {
        let nadia = "a2000000-0000-4000-8000-0000000000a1"
        var record = CircleApprovalRecord()
        record.recordInvitee(userId: nadia, statementId: "s-n", expiresAt: 4_000_000_000)
        record.deadStatementIds = ["s-n"]
        XCTAssertFalse(record.holdsPendingInvitation(subject: nadia, statementId: "s-n", now: 3_000_000_000),
                       "not renewable either")
        record.settleInvitees(roster: [nadia.uppercased(): "S-N"], now: 3_000_000_000)
        XCTAssertNil(record.entries[nadia])
        XCTAssertNil(record.entries[nadia.uppercased()])
        XCTAssertTrue(record.invitees.isEmpty, "the record goes on appearance")
    }

    /// Appearing with a DIFFERENT statement (another member's invitation): not
    /// chosen through the record — that statement decides, as for anyone.
    func testADifferentStatementIsNotChosenThroughTheRecord() throws {
        let me = try owner(), alice = Party("Alice"), newcomer = Party("Nadia")
        _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: alice.userId,
                                     sharingPubkeyHex: alice.sharing, signingPubkeyHex: alice.signing)
        let (_, mine) = try invite(by: me, newcomer)
        let (theirs, _) = try invite(by: alice, newcomer)
        var stored = createdHere(me)
        stored.entries[alice.userId] = .statement
        stored.recordInvitee(userId: newcomer.userId, statementId: mine.statementId, expiresAt: mine.expiresAt)

        let listed = try roster([row(me, role: "owner"), row(alice),
                                 row(newcomer, keyVersion: nil, invitation: theirs)])
        let result = pass(me, listed, stored: stored)
        XCTAssertEqual(result.result.verdicts[newcomer.userId], .confirmed(.statement))
        XCTAssertTrue(result.record.invitees.isEmpty, "the record goes on appearance")
    }

    // MARK: - An inviter who is no longer an owner or admin

    /// Demoted: the server has withdrawn this account's pending invitations, so
    /// this device's own records go and their ids are dead — and the invitee,
    /// listed again with that invitation, gets nothing.
    func testDemotedTheOwnInvitationsAreWithdrawn() throws {
        let me = try owner(), olga = Party("Olga"), newcomer = Party("Nadia")
        let (invitation, statement) = try invite(by: me, newcomer)
        var stored = CircleApprovalRecord()
        stored.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)

        let demoted = try roster([row(olga, role: "owner"), row(me, role: "member")])
        let record = pass(me, demoted, stored: stored).record
        XCTAssertTrue(record.invitees.isEmpty)
        XCTAssertEqual(record.deadStatementIds, [statement.statementId.lowercased()])

        let relisted = try roster([row(olga, role: "owner"), row(me, role: "member"),
                                   row(newcomer, keyVersion: nil, invitation: invitation)])
        let result = pass(me, relisted, stored: record)
        XCTAssertEqual(result.result.verdicts[newcomer.userId], .invalid)
        XCTAssertEqual(delivered(me, relisted, result), [])

        // Control: still an admin, nothing is withdrawn.
        let admin = try roster([row(olga, role: "owner"), row(me, role: "admin")])
        XCTAssertNotNil(pass(me, admin, stored: stored).record.invitees[newcomer.userId])
    }

    /// Demoted, on a roster that is NOT complete, without the member who joined
    /// with this device's invitation: nothing is withdrawn — they may be on a
    /// page this roster does not have. The next complete roster lists them with
    /// it, and they settle as this device's own choice.
    func testAnIncompleteRosterWithdrawsNothing() throws {
        let me = try owner(), olga = Party("Olga"), newcomer = Party("Nadia")
        let (invitation, statement) = try invite(by: me, newcomer)
        var stored = CircleApprovalRecord()
        stored.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)

        let page = try roster([row(olga, role: "owner"), row(me, role: "member")])
        let partial = pass(me, page, stored: stored, complete: false).record
        XCTAssertTrue(partial.deadStatementIds.isEmpty, "no id dead")
        XCTAssertNotNil(partial.invitees[newcomer.userId], "the record kept")

        let complete = try roster([row(olga, role: "owner"), row(me, role: "member"),
                                   row(newcomer, keyVersion: nil, invitation: invitation)])
        let after = pass(me, complete, stored: partial)
        XCTAssertEqual(after.result.verdicts[newcomer.userId], .confirmed(.ownAction))
        XCTAssertEqual(after.record.entries[newcomer.userId], .ownAction)
        XCTAssertTrue(after.record.deadStatementIds.isEmpty)
        XCTAssertTrue(after.record.invitees.isEmpty)
    }

    /// A server that "withdraws" (by demoting the inviter) an invitation a
    /// LISTED member carries changes nothing: they stay confirmed, and the id
    /// is not made dead — live or already expired.
    func testWithdrawingAListedMembersInvitationChangesNothing() throws {
        let me = try owner(), olga = Party("Olga"), newcomer = Party("Nadia")
        let (invitation, statement) = try invite(by: me, newcomer)
        var stored = CircleApprovalRecord()
        stored.recordInvitee(userId: newcomer.userId, statementId: statement.statementId, expiresAt: statement.expiresAt)
        let listed = try roster([row(olga, role: "owner"), row(me, role: "member"),
                                 row(newcomer, keyVersion: 1, invitation: invitation)])
        for at in [now, Date(timeIntervalSince1970: TimeInterval(statement.expiresAt + 86_400))] {
            let result = pass(me, listed, stored: stored, at: at)
            XCTAssertTrue(result.result.confirmed.contains(newcomer.userId), "\(at)")
            XCTAssertTrue(result.record.deadStatementIds.isEmpty, "\(at)")
        }
        // The record's own rule: an id a listed member carries is never killed.
        var two = CircleApprovalRecord()
        two.recordInvitee(userId: "a", statementId: "s1", expiresAt: 4_000_000_000)
        two.recordInvitee(userId: "b", statementId: "s2", expiresAt: 4_000_000_000)
        two.withdrawOwnInvitations(except: ["S2"])
        XCTAssertEqual(two.deadStatementIds, ["s1"])
        XCTAssertEqual(Array(two.invitees.keys), ["b"])
    }

    /// A pending list that no longer shows someone the roster already lists
    /// keeps their record: the next roster pass settles it.
    func testTheRosterSettlesBeforeThePendingListForgets() {
        let nadia = "a2000000-0000-4000-8000-0000000000a1", omar = "a2000000-0000-4000-8000-0000000000a2"
        var record = CircleApprovalRecord()
        record.recordInvitee(userId: nadia.uppercased(), statementId: "s-n", expiresAt: 4_000_000_000)
        record.recordInvitee(userId: omar, statementId: "s-o", expiresAt: 4_000_000_000)
        record.keepInvitees(pendingStatementIds: [], listedUsers: [nadia.replacingOccurrences(of: "-", with: "")])
        XCTAssertEqual(Array(record.invitees.keys), [nadia])
        XCTAssertTrue(record.deadStatementIds.isEmpty, "only trust dropped")
    }

    // MARK: - "Let them in"

    /// The answer pins exactly the keys behind the number before any pass.
    /// The list then swaps to other keys: they are never pinned (the pin pass
    /// raises the key-change question, and the pin stays) and never handed the
    /// circle. Without the pin at the answer, first contact takes the swapped
    /// keys: the control delivers to them.
    func testLetThemInPinsTheNumbersKeysSoASwapGetsNothing() throws {
        let me = try owner(), stranger = Party("Sam"), newcomer = Party("Nadia"), swapped = Party("Mallory")
        let (invitation, _) = try invite(by: stranger, newcomer)
        // Asked about: a statement whose signer this device can't confirm.
        let asked = try roster([row(me, role: "owner"), row(newcomer, keyVersion: nil, invitation: invitation)])
        let before = pass(me, asked, stored: createdHere(me))
        XCTAssertEqual(before.result.askReasons[newcomer.userId], .unconfirmedInviter)
        let question = MemberKeyPair(sharingKeyHex: newcomer.sharing, signingKeyHex: newcomer.signing)
        var answered = before.record
        answered.entries[newcomer.userId] = .ownAction

        // The list swaps their keys after the answer, before the next pass.
        var swappedRow = row(newcomer, keyVersion: nil, invitation: invitation)
        swappedRow["sharing_public_key"] = swapped.sharing
        swappedRow["signing_public_key"] = swapped.signing
        let swappedList = try roster([row(me, role: "owner"), swappedRow])

        // Without a pin at the answer, first contact takes the swap.
        XCTAssertEqual(delivered(me, swappedList, pass(me, swappedList, stored: answered)), [newcomer.userId],
                       "control")

        // "Let them in" as `CircleManager.letIn` does it: the question's keys are
        // pinned with the choice.
        XCTAssertTrue(CircleManager.letInHolds(asked: question, listed: question, pinned: nil))
        _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: newcomer.userId,
                                     sharingPubkeyHex: question.sharingKeyHex, signingPubkeyHex: question.signingKeyHex)
        let after = pass(me, swappedList, stored: answered)
        XCTAssertEqual(after.result.verdicts[newcomer.userId], .confirmed(.ownAction))
        XCTAssertEqual(delivered(me, swappedList, after), [], "the swapped keys are never handed the circle")
        let pin = try me.sdk.pinMemberKeys(circleId: circleId, userId: newcomer.userId,
                                           sharingPubkeyHex: swapped.sharing, signingPubkeyHex: swapped.signing)
        XCTAssertEqual(pin.state, .changedBoth, "the pin pass asks about the swap")
        XCTAssertEqual(me.sdk.pinnedSharingKey(circleId: circleId, userId: newcomer.userId)?.lowercased(),
                       question.sharingKeyHex.lowercased(), "and the pin stays on the question's keys")
        // The listed keys that match the question are handed it.
        XCTAssertEqual(delivered(me, asked, pass(me, asked, stored: answered)), [newcomer.userId])
    }

    /// At the tap, the list must still show exactly the question's keys, and
    /// nothing else may be pinned for them; otherwise nothing is pinned or
    /// signed and the question is asked again.
    func testLetThemInRefusesKeysOtherThanTheQuestions() throws {
        let a = MemberKeyPair(sharingKeyHex: "aa11", signingKeyHex: "aa22")
        let b = MemberKeyPair(sharingKeyHex: "bb11", signingKeyHex: "bb22")
        XCTAssertTrue(CircleManager.letInHolds(asked: a, listed: MemberKeyPair(sharingKeyHex: "AA11", signingKeyHex: "AA22"),
                                               pinned: nil))
        XCTAssertTrue(CircleManager.letInHolds(asked: a, listed: a, pinned: a))
        XCTAssertFalse(CircleManager.letInHolds(asked: a, listed: b, pinned: nil), "the list moved after the number")
        XCTAssertFalse(CircleManager.letInHolds(asked: a, listed: nil, pinned: nil), "no longer listed")
        XCTAssertFalse(CircleManager.letInHolds(asked: a, listed: a, pinned: b), "pinned to other keys")

        // The wiring: the answer is a change bound to the question's keys,
        // and nothing is pinned or approved when it is given. When it runs,
        // the pin comes first (before anything can hand them the circle),
        // then the admission, which signs the question's keys, then the
        // choice, so an admission not yet stored never reads as "already
        // let in"; a refusal signs nothing.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let letIn = try XCTUnwrap(circles.range(of: "    func letIn(_ request: KeyDeliveryRequest) {"))
        let answer = circles[letIn.upperBound...].prefix(1_500)
        XCTAssertTrue(answer.contains("seen: .init(keys: MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing)),"))
        XCTAssertFalse(answer.contains("pinMemberKeys("), "nothing pinned when answered")
        XCTAssertFalse(answer.contains("approvals.letIn(request, owner: me)"), "nobody approved when answered")
        let run = try XCTUnwrap(circles.range(of: "    func letInWaiting(_ change: PendingChange) async throws {"))
        let body = circles[run.upperBound...].prefix(3_000)
        let holds = try XCTUnwrap(body.range(of: "guard Self.letInHolds(asked: asked, listed: listedKeys(for: inputs.memberId, in: change.circleId),"))
        let pin = try XCTUnwrap(body.range(of: "let result = try? cryptoManager.pinMemberKeys("))
        let chosen = try XCTUnwrap(body.range(of: "guard recordLetInChoice(change, reload: change.heldStatementId != nil) else {"))
        let admit = try XCTUnwrap(body.range(of: "try await admitWaiting(change, userId: inputs.memberId, circleId: change.circleId, keys: asked)"))
        XCTAssertLessThan(holds.lowerBound, pin.lowerBound)
        XCTAssertLessThan(pin.lowerBound, admit.lowerBound)
        XCTAssertLessThan(admit.lowerBound, chosen.lowerBound, "chosen here only once the admission is stored")
        XCTAssertLessThan(pin.lowerBound, chosen.lowerBound, "pinned before anything can deliver")
        let refused = body[holds.upperBound...].prefix(200)
        XCTAssertTrue(refused.contains("throw CircleError.letInDetailsChanged"))
        XCTAssertFalse(refused.contains("admit"))
        // Its admission held (a run that stopped before the choice): nothing is
        // pinned or signed again and only the choice is recorded, and a choice
        // that isn't stored keeps the change.
        let heldOnly = try XCTUnwrap(body.range(of: "if change.heldStatementId == nil {\n"))
        XCTAssertLessThan(heldOnly.lowerBound, holds.lowerBound)
        XCTAssertTrue(body.contains("guard holdsCurrentKey(for: change.circleId) else { throw CircleError.waitingToSync }\n        if change.heldStatementId == nil {\n"),
                      "nothing else before the held check")
        XCTAssertTrue(body.contains("keys: asked)\n        }\n        guard recordLetInChoice(change, reload: change.heldStatementId != nil) else {\n            throw PendingChanges.ChoiceNotSaved()\n        }\n    }\n"),
                      "the choice is made, held or not, read back, and nothing follows it")
        // The choice is this device's user's, read back; then the roster pass
        // hands them the circle (a run that just admitted them reloads already).
        let choice = try XCTUnwrap(circles.range(of: "    func recordLetInChoice(_ change: PendingChange, reload: Bool) -> Bool {"))
        let choiceBody = circles[choice.upperBound...].prefix(600)
        XCTAssertTrue(choiceBody.contains("KeyDeliveryApprovals.shared.approveAnswer(owner: me, circleId: change.circleId,\n                                                        userId: inputs.memberId) else { return false }"))
        XCTAssertTrue(choiceBody.contains("if reload { Task { try? await self.loadMembers(for: change.circleId) } }\n        return true\n"))
        let host = try String(contentsOf: root.appendingPathComponent("App/Managers/KeyDeliveryApprovals.swift"), encoding: .utf8)
        XCTAssertTrue(host.contains("Button(\"Let them in\") { CircleManager.shared.letIn(request) }"))
    }

    // MARK: - The transition seed

    /// A pending legacy invitee pinned at the seed (older builds pinned at
    /// invite time) is not tombstoned by the first complete roster; when they
    /// join — with no statement, a legacy invitation — they stay hidden,
    /// counted in the "kept out" line, and are never asked about or confirmed.
    func testAPendingLegacyInviteeAtTheSeedStaysOut() throws {
        let me = try owner(), alice = Party("Alice"), invitee = Party("Ines")
        for party in [alice, invitee] {  // what older builds pinned
            _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: party.userId,
                                         sharingPubkeyHex: party.sharing, signingPubkeyHex: party.signing)
        }
        // The creator's device, which hands the circle to ANY confirmed member:
        // the strongest check that they are handed nothing.
        var stored = createdHere(me)
        stored.seedCandidates = [alice.userId, invitee.userId]

        let first = try roster([row(me, role: "owner"), row(alice)])
        let seeded = pass(me, first, stored: stored).record
        XCTAssertEqual(seeded.entries[alice.userId], .preRound2Seed, "listed: seeded")
        XCTAssertNil(seeded.entries[invitee.userId])
        XCTAssertNil(seeded.tombstones[invitee.userId], "not tombstoned")
        XCTAssertNil(seeded.invitees[invitee.userId], "and not an invitee record either")
        XCTAssertTrue(seeded.seedCandidates.isEmpty, "taken effect once")

        let joined = try roster([row(me, role: "owner"), row(alice), row(invitee, keyVersion: nil)])
        let result = pass(me, joined, stored: seeded)
        XCTAssertEqual(result.result.verdicts[invitee.userId], .legacy)
        XCTAssertFalse(result.result.confirmed.contains(invitee.userId), "hidden: counted as kept out")
        XCTAssertNil(result.result.askReasons[invitee.userId], "never asked about")
        XCTAssertFalse(delivered(me, joined, result).contains(invitee.userId))
    }

    /// The negative control: a REMOVED member pinned at the seed, re-listed
    /// later by the server, is neither confirmed nor handed the circle.
    func testARemovedMemberPinnedAtTheSeedIsNotLetBackIn() throws {
        let me = try owner(), alice = Party("Alice"), removed = Party("Rex")
        for party in [alice, removed] {
            _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: party.userId,
                                         sharingPubkeyHex: party.sharing, signingPubkeyHex: party.signing)
        }
        var stored = createdHere(me)  // hands the circle to ANY confirmed member
        stored.seedCandidates = [alice.userId, removed.userId]
        let seeded = pass(me, try roster([row(me, role: "owner"), row(alice)]), stored: stored).record
        XCTAssertNil(seeded.entries[removed.userId])

        let relisted = try roster([row(me, role: "owner"), row(alice), row(removed, keyVersion: nil)])
        let result = pass(me, relisted, stored: seeded)
        XCTAssertFalse(result.result.confirmed.contains(removed.userId), "not confirmed: no rotation wraps to them")
        XCTAssertEqual(delivered(me, relisted, result), [])

        // Control: if every pin made an entry at once and the server listed
        // them before any roster without them, they would be confirmed and
        // handed the circle.
        var before = createdHere(me)
        before.entries[alice.userId] = .preRound2Seed
        before.entries[removed.userId] = .preRound2Seed
        let then = pass(me, relisted, stored: before)
        XCTAssertTrue(then.result.confirmed.contains(removed.userId))
        XCTAssertEqual(delivered(me, relisted, then), [removed.userId])
    }

    /// The seed waits for a COMPLETE roster: a partial one decides nothing.
    func testThePartialRosterLeavesTheSeedWaiting() throws {
        let me = try owner(), alice = Party("Alice")
        var stored = CircleApprovalRecord()
        stored.seedCandidates = [alice.userId]
        let partial = pass(me, try roster([row(me, role: "owner"), row(alice)]), stored: stored, complete: false).record
        XCTAssertEqual(partial.seedCandidates, [alice.userId])
        XCTAssertNil(partial.entries[alice.userId])
    }

    // MARK: - The record, merged

    /// Two writers (the app's pass and a person's action, or the extension):
    /// a withdrawal is never lost, a record removed on either side is gone, and
    /// a pass that applied the seed clears it.
    func testTheNewFieldsMergeTowardsLessTrust() {
        let (alice, erin, finn, me) = ("a2000000-0000-4000-8000-0000000000b1", "a2000000-0000-4000-8000-0000000000b2",
                                       "a2000000-0000-4000-8000-0000000000b3", "a2000000-0000-4000-8000-0000000000b4")
        var base = CircleApprovalRecord()
        base.recordInvitee(userId: erin, statementId: "s-e", expiresAt: 4_000_000_000)
        base.recordInvitee(userId: finn, statementId: "s-f", expiresAt: 4_000_000_000)
        base.seedCandidates = [alice]
        var ours = base  // the pass: the seed applied, erin appeared
        ours.applySeed(roster: [alice, me])
        ours.settleInvitees(roster: [alice: nil, erin: "s-e", me: nil], now: 3_000_000_000)
        var theirs = base  // meanwhile: finn's invitation withdrawn
        theirs.withdrawInvitation(statementId: "s-f")

        let merged = CircleApprovalRecord.merged(ours: ours, base: base, theirs: theirs)
        XCTAssertEqual(merged.invitees, [:])
        XCTAssertEqual(merged.deadStatementIds, ["s-f"])
        XCTAssertEqual(merged.seedCandidates, [])
        XCTAssertEqual(merged.entries[alice], .preRound2Seed)
        XCTAssertEqual(merged.entries[erin], .ownAction)
    }

    /// The legacy `invited` set (user ids with no statement) is not read
    /// back: it could never say which invitation was theirs.
    func testTheLegacyInvitedSetIsNotCarriedOver() throws {
        let json = #"{"entries":{"alice":"statement"},"invited":["carol"]}"#
        let record = try JSONDecoder().decode(CircleApprovalRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.entries, ["alice": .statement])
        XCTAssertTrue(record.invitees.isEmpty)
    }

    // MARK: - The wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The record is written only by the invite action, from the statement it
    /// signed; a withdrawal from here kills the id (both places), a fresh
    /// server list only drops records; the seed stores candidates.
    func testTheRecordIsWrittenOnlyWhereItShouldBe() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertEqual(circles.components(separatedBy: "approveInvitee(").count - 1, 1, "only the invite action")
        XCTAssertTrue(circles.contains("boundStatement = try? cryptoManager.parseMembershipStatement(statementHex: statement.statementHex)"))
        XCTAssertTrue(circles.contains("statementId: statement.statementId,\n                                                       expiresAt: statement.expiresAt)"))
        let revoke = try XCTUnwrap(circles.range(of: "func revokeInvite(circleId: String, inviteId: String) async throws {"))
        let revokeEnd = try XCTUnwrap(circles.range(of: "\n    }\n", range: revoke.upperBound..<circles.endIndex))
        let revokeBody = circles[revoke.upperBound..<revokeEnd.lowerBound]
        XCTAssertTrue(revokeBody.contains("withdrawn = false"), "gone already (perhaps accepted): not made dead")
        XCTAssertTrue(revokeBody.contains("KeyDeliveryApprovals.shared.withdrawInvitation(owner: me, circleId: circleId, statementId: statementId)"))
        XCTAssertFalse(revokeBody.contains("forgetInviteesNoLongerPending"), "never against a cached list")
        XCTAssertTrue(circles.contains("pendingInvites[circleId] = invites\n            forgetInviteesNoLongerPending(circleId: circleId, invites: invites)"))
        XCTAssertTrue(circles.contains("KeyDeliveryApprovals.shared.keepPendingInvitations(owner: me, circleId: circleId, statementIds: pending,\n                                                           listedUsers: listed)"),
                      "the roster settles first")
        let renewals = try source("App/Managers/InvitationRenewals.swift")
        XCTAssertTrue(renewals.contains("KeyDeliveryApprovals.shared.withdrawInvitation(owner: me, circleId: question.circleId,"))
        XCTAssertTrue(renewals.contains("CircleManager.shared.forgetInviteesNoLongerPending(circleId: circleId, invites: invites)"))
        let approvals = try source("App/Managers/KeyDeliveryApprovals.swift")
        XCTAssertTrue(approvals.contains("record.seedCandidates = Set(members)"))
        XCTAssertFalse(approvals.contains("for userId in members { record.entries[userId] = .preRound2Seed }"))
    }
}
