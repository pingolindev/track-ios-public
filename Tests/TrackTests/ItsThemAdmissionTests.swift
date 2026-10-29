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

/// On an owner's or admin's device, "It's them" for a member whose keys
/// changed AND whom the chain doesn't count also admits exactly the keys the
/// question showed, through the existing waiting "Let them in" (it signs with
/// this account's current key once this device holds the key in use). Only on
/// the yes, never for a counted member, never from a plain member's device;
/// never a receive-only member, and only when the refresh records'
/// eligibility, read for the shown keys, has no other answer for them.
@MainActor
final class ItsThemAdmissionTests: XCTestCase {
    private typealias C = Track.CircleManager

    private func e(eligible: Bool = false, expired: Bool = false, notChainAdmin: Bool = false, email: Bool = false,
                   removed: Bool = false) -> LateJoiner.Standing {
        LateJoiner.Standing(eligible: eligible, invitationExpired: expired, signerNotChainAdmin: notChainAdmin,
                            emailInvitationWithoutSignedId: email, removedByOwnerOrAdmin: removed)
    }

    func testItsThemAdmitsOnlyAnUncountedMemberOnAnOwnersOrAdminsDevice() {
        XCTAssertTrue(C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: true, chainRole: nil, standing: { self.e() }))
        for role in [CircleRole.member, .admin, .owner] {
            XCTAssertFalse(C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: true, chainRole: role, standing: { self.e() }),
                           "counted as \(role)")
        }
        XCTAssertFalse(C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: false, chainRole: nil, standing: { self.e() }),
                       "a plain member's yes admits nobody")
    }

    /// The SDK's eligibility rule, read for the keys the yes showed, decides:
    /// it lets them in (nothing to sign), one of its flags names a late
    /// joiner's case (that question decides), an owner or admin removed them,
    /// or it has no answer.
    func testItsThemAdmitsOnlyWhereTheEligibilityRuleHasNoOtherAnswer() {
        func admits(_ standing: LateJoiner.Standing?) -> Bool {
            C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: true, chainRole: nil, standing: { standing })
        }
        XCTAssertTrue(admits(e()), "control: not eligible, no flag, not removed")
        XCTAssertFalse(admits(e(eligible: true)), "the eligibility rule lets them in")
        XCTAssertFalse(admits(e(expired: true)), "their invitation ran out: the question decides")
        XCTAssertFalse(admits(e(notChainAdmin: true)), "its signer isn't an owner or admin in the chain")
        XCTAssertFalse(admits(e(email: true)), "an email invitation without a signed id")
        XCTAssertFalse(admits(e(removed: true)), "removed by an owner or admin")
        XCTAssertFalse(admits(nil), "no eligibility answer: not imported here, forked, no pass, an error")
    }

    /// The receive-only yes admits nobody (their way in stays the email
    /// invitation's question); the eligibility rule is read only where it
    /// decides.
    func testTheReceiveOnlyYesAdmitsNobody() {
        var reads = 0
        let read: () -> LateJoiner.Standing? = { reads += 1; return self.e() }
        XCTAssertFalse(C.itsThemAdmits(receiveOnly: true, ownerOrAdmin: true, chainRole: nil, standing: read))
        XCTAssertFalse(C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: false, chainRole: nil, standing: read))
        XCTAssertFalse(C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: true, chainRole: .member, standing: read))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(C.itsThemAdmits(receiveOnly: false, ownerOrAdmin: true, chainRole: nil, standing: read))
        XCTAssertEqual(reads, 1)
    }

    /// The eligibility rule's flags, each as the SDK said.
    func testTheStandingTakesEachEligibilityFlag() {
        func answer(eligible: Bool = false, expired: Bool = false, notChainAdmin: Bool = false, email: Bool = false,
                    removed: Bool = false) -> MemberEligibility {
            MemberEligibility(userId: "m", eligible: eligible, basis: nil, invitationExpired: expired,
                              invitationSignerNotChainAdmin: notChainAdmin, removedByOwnerOrAdmin: removed,
                              removedAtVersion: removed ? 3 : nil, emailInvitationWithoutSignedId: email)
        }
        XCTAssertEqual(LateJoiner.Standing(answer()), e())
        XCTAssertEqual(LateJoiner.Standing(answer(eligible: true)), e(eligible: true))
        XCTAssertEqual(LateJoiner.Standing(answer(expired: true)), e(expired: true))
        XCTAssertEqual(LateJoiner.Standing(answer(notChainAdmin: true)), e(notChainAdmin: true))
        XCTAssertEqual(LateJoiner.Standing(answer(email: true)), e(email: true))
        XCTAssertEqual(LateJoiner.Standing(answer(removed: true)), e(removed: true))
    }

    /// The read gives the eligibility rule the member's row with exactly the
    /// shown keys, confirmed by the yes; everything else as the last pass
    /// had it. Not on the list: no read.
    func testTheReadUsesExactlyTheShownKeys() throws {
        let old = MemberKeyPair(sharingKeyHex: String(repeating: "a1", count: 32), signingKeyHex: String(repeating: "a2", count: 32))
        let shown = MemberKeyPair(sharingKeyHex: String(repeating: "b1", count: 32), signingKeyHex: String(repeating: "b2", count: 32))
        let statement = SignedStatementRecord(statementHex: "01", signatureHex: "02")
        let other = RecordMemberRow(userId: "a0a0a0a0-0000-0000-0000-00000000000a", keys: old, confirmed: true, listed: true,
                                    listedRole: .owner, statements: [], personConfirmedKeys: false, serverSaysKeyless: false)
        let member = RecordMemberRow(userId: "B0B0B0B0-0000-0000-0000-00000000000B", keys: old, confirmed: false, listed: true,
                                     listedRole: .member, statements: [statement], personConfirmedKeys: false,
                                     serverSaysKeyless: true)
        let rows = try XCTUnwrap(C.itsThemRows([other, member], member: "b0b0b0b0-0000-0000-0000-00000000000b", keys: shown))
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], other)
        XCTAssertEqual(rows[1], RecordMemberRow(userId: member.userId, keys: shown, confirmed: true, listed: true,
                                                listedRole: .member, statements: [statement], personConfirmedKeys: true,
                                                serverSaysKeyless: true))
        XCTAssertNil(C.itsThemRows([other], member: "b0b0b0b0-0000-0000-0000-00000000000b", keys: shown))
    }

    /// Its waiting "Let them in" signs: the member is confirmed here already
    /// (the yes just approved them), and what is missing is the admission.
    /// Kept as a live answer until it runs: the re-check never ends it as
    /// "already let in".
    func testTheWaitingLetInItQueuesSigns() {
        let member = "b0b0b0b0-0000-0000-0000-00000000000b"
        var change = PendingChanges.make(.letIn, account: "a0a0a0a0-0000-0000-0000-00000000000a", circleId: "c1",
                                         inputs: .letIn(.init(memberId: member, questionKind: C.itsThemQuestionKind)),
                                         circleName: "Family", subject: "Sam")
        change.versionAtTap = 2
        XCTAssertNil(LetInKind.admitted(change, ownerOrAdmin: true, verdict: .confirmed(.ownAction)),
                     "confirmed by the yes: it still signs the admission")
        XCTAssertNil(LetInKind.admitted(change, ownerOrAdmin: true, verdict: .confirmed(.statement)))
        XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: false, verdict: .confirmed(.ownAction)),
                       .drop(line: PendingChangeCopy.notOwnerOrAdmin(change)), "no longer owner or admin: nothing signed")
        change.heldStatementId = "s1"
        XCTAssertEqual(LetInKind.admitted(change, ownerOrAdmin: false, verdict: .confirmed(.ownAction)), .run(change),
                       "its admission is stored: only the choice is left")
    }

    /// Never the backfill for a member the chain doesn't count: it signs only
    /// for a counted one, as an owner or admin in the chain.
    func testTheBackfillNeverAdmitsAnUncountedMember() {
        XCTAssertFalse(C.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .owner, memberChainRole: nil))
        XCTAssertTrue(C.backfillSigns(hasRecords: true, standing: .recorded, myChainRole: .owner, memberChainRole: .member))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The yes goes through one call; it signs nothing at the tap, and only
    /// queues the admission where `itsThemAdmits` says, for the alert's keys,
    /// on every branch (the receive-only one included, where it says no).
    func testTheYesIsWiredToTheWaitingLetIn() throws {
        let host = try source("App/Views/Circles/MemberKeyAlertHost.swift")
        XCTAssertTrue(host.contains("Button(\"It's them\") { approve(alert) }"))
        XCTAssertTrue(host.contains("            try CircleManager.shared.answerItsThem(alert)\n"))
        let circles = try source("App/Managers/CircleManager.swift")
        let start = try XCTUnwrap(circles.range(of: "    func answerItsThem(_ alert: MemberKeyAlert) throws {"))
        let body = String(circles[start.upperBound...].prefix(2_600))
        let approve = try XCTUnwrap(body.range(of: "            try MemberKeyPinner.shared.approve(alert)\n"))
        let branchesEnd = try XCTUnwrap(body.range(of: "\n        }\n        if let circle = circles.first(where: { $0.id == alert.circleId }), let signing = alert.newSigningPubkeyHex {\n"))
        let gate = try XCTUnwrap(body.range(of: "            if Self.itsThemAdmits(receiveOnly: alert.receiveOnly, ownerOrAdmin: isOwnerOrAdmin(circle),\n"
                                             + "                                  chainRole: cryptoManager.chainRole(circleId: alert.circleId, userId: alert.userId),\n"
                                             + "                                  standing: { itsThemStanding(of: alert.userId, keys: shown, in: alert.circleId) }) {\n"))
        let queue = try XCTUnwrap(body.range(of: "                    try PendingChanges.queue(\n                        .letIn, circleId: alert.circleId,"))
        XCTAssertLessThan(approve.lowerBound, branchesEnd.lowerBound, "the pin moves first, then the admission is queued")
        XCTAssertLessThan(branchesEnd.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, queue.lowerBound)
        XCTAssertTrue(body.contains("            let shown = MemberKeyPair(sharingKeyHex: alert.newSharingPubkeyHex, signingKeyHex: signing)\n"))
        XCTAssertTrue(body.contains("                        seen: .init(keys: shown), subject: alert.displayName)\n"))
        XCTAssertFalse(body.contains("admit(") || body.contains("signMembership"))
        // The eligibility rule is read for the shown keys, from the last pass,
        // on a circle imported here.
        let read = try XCTUnwrap(circles.range(of: "    func itsThemStanding(of userId: String, keys: MemberKeyPair, in circleId: String) -> LateJoiner.Standing? {"))
        let reader = String(circles[read.upperBound...].prefix(700))
        XCTAssertTrue(reader.contains("guard standing(of: circleId) == .recorded, let listing = recordMemberRows(for: circleId),"))
        XCTAssertTrue(reader.contains("let rows = Self.itsThemRows(listing.rows, member: userId, keys: keys),"))
        XCTAssertTrue(reader.contains("members: rows.map(\\.sdkMember),"))
        XCTAssertTrue(reader.contains("purpose: .include),"))
        XCTAssertTrue(reader.contains("return LateJoiner.Standing(answer)"))
        // The waiting change's run signs with the current identity key, while holding the key in use.
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        XCTAssertTrue(kinds.contains("inputs.questionKind != CircleManager.itsThemQuestionKind, case .confirmed? = verdict {"))
        let run = try XCTUnwrap(circles.range(of: "    func letInWaiting(_ change: PendingChange) async throws {"))
        XCTAssertTrue(circles[run.upperBound...].prefix(600).contains("guard holdsCurrentKey(for: change.circleId) else { throw CircleError.waitingToSync }"))
    }
}
