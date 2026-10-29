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

/// After a password reset, an owner's or admin's own device signs and uploads
/// its own admission of its CURRENT keys where the SDK doesn't count its own
/// row, by one retry rule; no record is built before it is served; receive-only
/// is lifted only once the SDK counts the own row. And a flagged rotation after
/// a member's reset gives that member nothing until this device's person
/// answers "It's them", then only their new keys.
@MainActor
final class SelfAdmissionTests: XCTestCase {
    private typealias C = Track.CircleManager
    private typealias S = SelfAdmission

    private struct Party {
        let userId = UUID().uuidString.lowercased()
        let sdk = CryptoManager()
        var sharing: String
        var signing: String

        init() {
            sharing = Self.hex(sdk.generateKeypair().publicKey)
            signing = Self.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }

        static func hex(_ b64: String) -> String {
            Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
        }

        /// A password reset on a phone that keeps its store: new keys, the same
        /// circle keys and records.
        mutating func reset() {
            sharing = Self.hex(sdk.generateKeypair().publicKey)
            signing = Self.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }

        var keys: MemberKeyPair { MemberKeyPair(sharingKeyHex: sharing, signingKeyHex: signing) }
    }

    private let circle = UUID().uuidString.lowercased()

    private func row(_ party: Party, role: CircleRole = .member, statements: [SignedStatementRecord] = [])
        -> RecordMemberRow {
        RecordMemberRow(userId: party.userId, keys: party.keys, confirmed: true, listed: true, listedRole: role,
                        statements: statements, personConfirmedKeys: false, serverSaysKeyless: false)
    }

    private func eligibility(_ me: String, eligible: Bool) -> MemberEligibility {
        MemberEligibility(userId: me, eligible: eligible, basis: nil, invitationExpired: false,
                          invitationSignerNotChainAdmin: false, removedByOwnerOrAdmin: false, removedAtVersion: nil,
                          emailInvitationWithoutSignedId: false)
    }

    private struct Unread: Error {}

    // MARK: - No answer is never an answer

    func testTheOwnRowIsAnAnswerOnlyFromAReadThatReturned() {
        let me = UUID().uuidString.lowercased()
        XCTAssertEqual(S.ownRow(importedNotForked: true, me: me) { [eligibility(me, eligible: true)] }, .counted)
        XCTAssertEqual(S.ownRow(importedNotForked: true, me: me) { [eligibility(me, eligible: false)] }, .notCounted)
        XCTAssertEqual(S.ownRow(importedNotForked: true, me: me.uppercased()) { [eligibility(me, eligible: false)] },
                       .notCounted, "this account in any spelling")
        // The read throwing (e.g. "…this circle's records are not imported in this process yet").
        XCTAssertEqual(S.ownRow(importedNotForked: true, me: me) { throw Unread() }, .notKnown)
        XCTAssertEqual(S.ownRow(importedNotForked: true, me: me) { [eligibility(UUID().uuidString, eligible: false)] },
                       .notKnown, "no row for this account")
        XCTAssertEqual(S.ownRow(importedNotForked: true, me: me) { [] }, .notKnown)
        // Not imported in this process, or forked: a forked chain reads every row not eligible.
        var asked = false
        XCTAssertEqual(S.ownRow(importedNotForked: false, me: me) { asked = true; return [self.eligibility(me, eligible: false)] },
                       .notKnown)
        XCTAssertFalse(asked, "a forked or unimported circle isn't even read")
    }

    /// An error means NOT KNOWN: nothing sent, no clock, and the circle's key
    /// changes still wait; after the import, due → one emission.
    func testAnErrorSendsNothingAndKeyChangesStillWaitThenTheImportDecides() {
        let me = UUID().uuidString.lowercased()
        let unread = S.ownRow(importedNotForked: true, me: me) { throw Unread() }
        XCTAssertFalse(S.due(ownRow: unread, listedOwnerOrAdmin: true, holdsKeyInUse: true))
        XCTAssertFalse(S.keyChangesMayBuild(standing: .recorded, ownRow: unread), "key changes still wait")
        let forked = S.ownRow(importedNotForked: false, me: me) { [self.eligibility(me, eligible: false)] }
        XCTAssertFalse(S.due(ownRow: forked, listedOwnerOrAdmin: true, holdsKeyInUse: true), "a fork sends nothing")
        // After the import: due, and one attempt.
        let read = S.ownRow(importedNotForked: true, me: me) { [self.eligibility(me, eligible: false)] }
        XCTAssertTrue(S.due(ownRow: read, listedOwnerOrAdmin: true, holdsKeyInUse: true))
        XCTAssertTrue(S.mayAttempt(nil, keyVersion: 1, role: "owner", now: Date()))
        let done = S.Attempt(keyVersion: 1, role: "owner", outcome: .stored, at: Date())
        XCTAssertFalse(S.mayAttempt(done, keyVersion: 1, role: "owner", now: Date()), "one emission")
    }

    // MARK: - The gate is exactly four things

    /// A fresh store after a restore, with the rotation step due:
    /// `holdsCurrentKey` is false (it has `!rotationStepDue`), the key in use
    /// is held. Due.
    func testTheGateIsTheOwnRowTheListedRoleAndTheKeyInUseNeverTheStep() {
        let stepDue = true
        let holdsCurrentKey = C.holdsCurrentKey(currentVersion: true, rotationStepDue: stepDue, behind: false)
        XCTAssertFalse(holdsCurrentKey, "the step holds every write")
        XCTAssertTrue(S.due(ownRow: .notCounted, listedOwnerOrAdmin: true, holdsKeyInUse: true),
                      "yet the self-admission is due: the step waits for it")
        for (ownRow, listed, keyInUse) in [(S.OwnRow.counted, true, true), (.notKnown, true, true),
                                           (.notCounted, false, true), (.notCounted, true, false)] {
            XCTAssertFalse(S.due(ownRow: ownRow, listedOwnerOrAdmin: listed, holdsKeyInUse: keyInUse),
                           "\(ownRow) owner/admin \(listed) key in use \(keyInUse)")
        }
    }

    // MARK: - Key changes wait while due

    func testKeyChangesBuildOnlyOnceTheOwnRowIsCounted() {
        XCTAssertTrue(S.keyChangesMayBuild(standing: .recorded, ownRow: .counted))
        XCTAssertFalse(S.keyChangesMayBuild(standing: .recorded, ownRow: .notCounted))
        XCTAssertFalse(S.keyChangesMayBuild(standing: .recorded, ownRow: .notKnown))
        for ownRow in [S.OwnRow.counted, .notCounted, .notKnown] {
            XCTAssertTrue(S.keyChangesMayBuild(standing: .noRecords, ownRow: ownRow), "no records: the own row doesn't matter")
            XCTAssertTrue(S.keyChangesMayBuild(standing: .wait, ownRow: ownRow), "`rotationMode` holds these")
        }
    }

    // MARK: - Receive-only: lifted only when the SDK counts the own row

    func testReceiveOnlyIsLiftedOnlyWhenTheOwnRowIsCounted() {
        XCTAssertFalse(S.receiveOnly(statementRule: true, ownRow: .counted),
                       "owner/admin with a served self-admission: lifted")
        XCTAssertTrue(S.receiveOnly(statementRule: true, ownRow: .notCounted),
                      "before it's served, or a plain member: stays")
        XCTAssertTrue(S.receiveOnly(statementRule: true, ownRow: .notKnown), "no answer: stays")
        for ownRow in [S.OwnRow.counted, .notCounted, .notKnown] {
            XCTAssertFalse(S.receiveOnly(statementRule: false, ownRow: ownRow), "it only ever lifts")
        }
    }

    // MARK: - The retry rule

    func testA200IsDoneForThatVersionOnly() {
        let at = Date()
        let stored = S.Attempt(keyVersion: 3, role: "admin", outcome: .stored, at: at)
        XCTAssertFalse(S.mayAttempt(stored, keyVersion: 3, role: "admin", now: at.addingTimeInterval(86_400)))
        XCTAssertTrue(S.mayAttempt(stored, keyVersion: 4, role: "admin", now: at), "a later naming record re-arms it")
    }

    func testA403WaitsForTheListedRoleOrTheVersion() {
        let at = Date()
        let refused = S.Attempt(keyVersion: 3, role: "admin", outcome: .refused, at: at)
        XCTAssertFalse(S.mayAttempt(refused, keyVersion: 3, role: "admin", now: at.addingTimeInterval(86_400)))
        XCTAssertTrue(S.mayAttempt(refused, keyVersion: 3, role: "owner", now: at))
        XCTAssertTrue(S.mayAttempt(refused, keyVersion: 4, role: "admin", now: at))
    }

    func testAnythingElseIsTriedAgainAfterTenMinutesNotBefore() {
        let at = Date()
        let failed = S.Attempt(keyVersion: 3, role: "owner", outcome: .failed, at: at)
        XCTAssertFalse(S.mayAttempt(failed, keyVersion: 3, role: "owner", now: at))
        XCTAssertFalse(S.mayAttempt(failed, keyVersion: 3, role: "owner", now: at.addingTimeInterval(599)))
        XCTAssertTrue(S.mayAttempt(failed, keyVersion: 3, role: "owner", now: at.addingTimeInterval(600)))
    }

    func testEachAnswerIsReadAsTheRuleSays() {
        XCTAssertEqual(S.outcome(nil), .stored)
        XCTAssertEqual(S.outcome(APIError(code: "http_403", message: "")), .refused)
        XCTAssertEqual(S.outcome(APIError(code: "forbidden", message: "")), .refused)
        for code in ["http_400", "http_404", "http_409", "http_429", "http_500", "http_503", "network_error",
                     "server_error", "circuit_open"] {
            XCTAssertEqual(S.outcome(APIError(code: code, message: "")), .failed, code)
        }
        XCTAssertEqual(S.outcome(URLError(.timedOut)), .failed, "no answer")
        XCTAssertEqual(S.outcome(Unread()), .failed, "the SDK couldn't sign")
    }

    /// A 400 (say, the server's read of the new keys lagging the reset), then a
    /// 200 ten minutes later: served, and nothing more for that version.
    func testA400ThenA200TenMinutesLater() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SelfAdmissionTests-\(UUID().uuidString)"))
        let owner = UUID().uuidString.lowercased()
        let t0 = Date()
        XCTAssertTrue(S.mayAttempt(S.lastAttempt(circleId: circle, owner: owner, defaults: defaults),
                                   keyVersion: 1, role: "owner", now: t0))
        S.note(.init(keyVersion: 1, role: "owner", outcome: S.outcome(APIError(code: "http_400", message: "")), at: t0),
               circleId: circle, owner: owner, defaults: defaults)
        XCTAssertFalse(S.mayAttempt(S.lastAttempt(circleId: circle, owner: owner, defaults: defaults),
                                    keyVersion: 1, role: "owner", now: t0.addingTimeInterval(300)), "not inside 10 minutes")
        let t1 = t0.addingTimeInterval(600)
        XCTAssertTrue(S.mayAttempt(S.lastAttempt(circleId: circle.uppercased(), owner: owner.uppercased(), defaults: defaults),
                                   keyVersion: 1, role: "owner", now: t1), "a 400 is not done; any spelling")
        S.note(.init(keyVersion: 1, role: "owner", outcome: S.outcome(nil), at: t1),
               circleId: circle, owner: owner, defaults: defaults)
        XCTAssertFalse(S.mayAttempt(S.lastAttempt(circleId: circle, owner: owner, defaults: defaults),
                                    keyVersion: 1, role: "owner", now: t1.addingTimeInterval(86_400)))
        XCTAssertNil(S.lastAttempt(circleId: circle, owner: UUID().uuidString, defaults: defaults),
                     "another account's marks are its own")
        XCTAssertTrue(AccountKeyedDefaults.prefixes.contains(S.prefix), "wiped with the other account-keyed stores")
    }

    // MARK: - With the SDK, on this device

    /// A made the circle (its genesis commits A's keys), then reset its
    /// password on a phone that kept its store. The SDK doesn't count A's own
    /// row, so the self-admission is due, and A's builder refuses every key
    /// change. A signs its own admission with its CURRENT keys; served in A's
    /// row, the SDK counts it, this device's own row included, and the
    /// builder builds.
    func testAResetOwnersOwnRowWaitsForItsOwnAdmissionAndTheBuilderWithIt() throws {
        var a = Party()
        let genesis = try a.sdk.prepareRecordedCircleCreation(creatorUserId: a.userId, circleId: circle).genesis
        _ = try a.sdk.importRefreshRecords(circleId: circle, records: [genesis], keyChain: [],
                                           members: [row(a, role: .owner).sdkMember], rosterComplete: true,
                                           ownHead: nil, memberHeads: [])
        let before = S.ownRow(importedNotForked: true, me: a.userId) {
            try a.sdk.refreshEligibility(circleId: circle, members: [row(a, role: .owner).sdkMember], purpose: .include)
        }
        XCTAssertEqual(before, .counted, "before the reset the chain counts A")

        a.reset()
        let afterReset = row(a, role: .owner)
        let ownRow = S.ownRow(importedNotForked: true, me: a.userId) {
            try a.sdk.refreshEligibility(circleId: circle, members: [afterReset.sdkMember], purpose: .include)
        }
        XCTAssertEqual(ownRow, .notCounted)
        XCTAssertTrue(S.due(ownRow: ownRow, listedOwnerOrAdmin: true, holdsKeyInUse: true))
        XCTAssertFalse(S.keyChangesMayBuild(standing: .recorded, ownRow: ownRow))
        XCTAssertThrowsError(try a.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: a.userId, kind: .rotation,
            planned: [PlannedEntry(userId: a.userId, state: .included, role: nil)], members: [afterReset.sdkMember],
            rosterComplete: true, currentCircleNamePlaintext: ""), "the builder refuses an uncounted own row")

        // Its own admission: signer = subject = A, A's CURRENT keys, the version it seals under.
        let signed = try a.sdk.signMembershipAdmission(
            circleId: circle, signerUserId: a.userId, subjectUserId: a.userId,
            subjectSharingPublicKeyHex: a.sharing, subjectSigningPublicKeyHex: a.signing)
        let statement = try a.sdk.parseMembershipStatement(statementHex: signed.statementHex)
        XCTAssertEqual(statement.kind, .admission)
        XCTAssertEqual(statement.signerUserId, a.userId)
        XCTAssertEqual(statement.subjectUserId, a.userId)
        XCTAssertEqual(statement.subjectSharingPublicKeyHex, a.sharing)
        XCTAssertEqual(statement.subjectSigningPublicKeyHex, a.signing)
        XCTAssertEqual(statement.atVersion, try a.sdk.getActiveVersion(circleId: circle))
        XCTAssertTrue(try a.sdk.verifyMembershipStatement(
            statementHex: signed.statementHex, signatureHex: signed.signatureHex, signerSigningPublicKeyHex: a.signing),
            "signed with the current key, never a restored one")

        let served = row(a, role: .owner, statements: [
            SignedStatementRecord(statementHex: signed.statementHex, signatureHex: signed.signatureHex)])
        let counted = S.ownRow(importedNotForked: true, me: a.userId) {
            try a.sdk.refreshEligibility(circleId: circle, members: [served.sdkMember], purpose: .include)
        }
        XCTAssertEqual(counted, .counted)
        XCTAssertFalse(S.due(ownRow: counted, listedOwnerOrAdmin: true, holdsKeyInUse: true), "done")
        XCTAssertTrue(S.keyChangesMayBuild(standing: .recorded, ownRow: counted))
        XCTAssertNoThrow(try a.sdk.prepareRecordedRotation(
            circleId: circle, senderUserId: a.userId, kind: .rotation,
            planned: [PlannedEntry(userId: a.userId, state: .included, role: nil)], members: [served.sdkMember],
            rosterComplete: true, currentCircleNamePlaintext: ""), "the key change builds once it is served")
    }

    // MARK: - The wrap after a member's reset

    /// D, an owner, pins M; M resets. A flagged rotation (cause "other", no
    /// deadline) neither includes nor wraps M until D's person answers "It's
    /// them"; then it gives M only the new keys, and the old ones are refused.
    /// The recorded path (the planner) and the record-less one (`rotationDecision`).
    func testAFlaggedRotationAfterAMembersResetWaitsForItsThemThenOnlyTheNewKeys() throws {
        let d = Party()
        var m = Party()
        _ = try d.sdk.pinMemberKeys(circleId: circle, userId: m.userId, sharingPubkeyHex: m.sharing, signingPubkeyHex: m.signing)
        let old = m.keys
        m.reset()
        var result = MembershipConfirmation.Result()
        result.verdicts[m.userId] = .confirmed(.statement)  // their old basis stands
        let gate = AccessHandover.readOnlyPinGate(
            me: d.userId, circleId: circle,
            pinnedSharing: { d.sdk.pinnedSharingKey(circleId: $0, userId: $1) },
            pinnedSigning: { d.sdk.pinnedSigningKey(circleId: $0, userId: $1) })
        func blocked(listing keys: MemberKeyPair) -> Set<String> {
            AccessHandover.sendSideGate(me: d.userId, result: result, record: CircleApprovalRecord(),
                                        members: [(m.userId, "M", keys.sharingKeyHex, keys.signingKeyHex)], pinGate: gate)
        }
        func planned(_ blocked: Set<String>) -> [PlannedEntry] {
            RecordedRotation.rotationPlan(
                me: d.userId, roster: [.init(userId: d.userId, role: .owner, hasKeys: true),
                                       .init(userId: m.userId, role: .member, hasKeys: true)],
                includable: [d.userId, m.userId], blocked: blocked,
                counted: [d.userId: .owner, m.userId: .member], removing: [])
        }
        func decided(_ blocked: Set<String>) -> C.RotationDecision {
            C.rotationDecision(selfUserId: d.userId, circleKeyVersion: 1, cause: "other",
                               wrapSet: [(d.userId, 1), (m.userId, 1)], roster: [d.userId, m.userId],
                               blocked: blocked, confirmed: [d.userId, m.userId])
        }
        XCTAssertTrue(C.performsSecurityRefresh(flagged: true, cause: "other"), "rotated on the bare flag")

        // Before "It's them": blocked, so neither included nor wrapped.
        let before = blocked(listing: m.keys)
        XCTAssertEqual(before, [m.userId])
        XCTAssertNotEqual(planned(before).first { $0.userId == m.userId }?.state, .included)
        XCTAssertFalse(decided(before).wrap.contains(m.userId))
        XCTAssertTrue(decided(before).pending.contains(m.userId))

        // "It's them": the pin moves to the NEW keys; then included and wrapped.
        try d.sdk.approveMemberKeyChange(circleId: circle, userId: m.userId,
                                         newSharingPubkeyHex: m.sharing, newSigningPubkeyHex: m.signing)
        let after = blocked(listing: m.keys)
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(planned(after).first { $0.userId == m.userId }?.state, .included)
        XCTAssertTrue(decided(after).wrap.contains(m.userId))
        XCTAssertEqual(d.sdk.pinnedSharingKey(circleId: circle, userId: m.userId)?.lowercased(), m.sharing)
        // The old keys listed again: refused, never wrapped to.
        XCTAssertEqual(blocked(listing: old), [m.userId])
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    /// The emitter reads the key in use, never the step's gate; it signs
    /// as this account about this account with its own current keys, uploads
    /// for this account, and touches this account's row only by reloading the
    /// roster after a 200.
    func testTheEmitterIsWiredToItsFourConditionsAndTheServedRoster() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        let emitter = try body(of: "    private func publishSelfAdmissionsIfDue() async {", until: "\n    }\n", in: circles)
        XCTAssertTrue(emitter.contains("guard SelfAdmission.due(ownRow: ownRowState(circle), listedOwnerOrAdmin: isOwnerOrAdmin(circle),\n"
                                       + "                                    holdsKeyInUse: holdsKeyInUse(circle.id)) else { continue }"))
        XCTAssertFalse(emitter.contains("holdsCurrentKey("), "never the step's gate")
        XCTAssertTrue(emitter.contains("let own = ownIdentity(userId: me)"))
        XCTAssertTrue(emitter.contains("circleId: circle.id, signerUserId: me, subjectUserId: me,\n"
                                       + "                    subjectSharingPublicKeyHex: sharing, subjectSigningPublicKeyHex: signing)"))
        XCTAssertTrue(emitter.contains("circleId: circle.id, userId: me, statementHex: signed.statementHex, signatureHex: signed.signatureHex)"))
        XCTAssertTrue(emitter.contains("            if outcome == .stored {\n"
                                       + "                Self.keyLog.info(\"circle \\(circle.id, privacy: .public): this account's own admission is stored\")\n"
                                       + "                try? await loadMembers(for: circle.id)"))
        XCTAssertFalse(emitter.contains("membership["), "never into this account's row from here")
        XCTAssertFalse(emitter.contains("membershipCandidates["))
        XCTAssertTrue(emitter.contains("guard SelfAdmission.mayAttempt(SelfAdmission.lastAttempt(circleId: circle.id, owner: me),"))

        // After the records import, before the rotations.
        let load = try body(of: "        if needHistoricalKeys || recordsImportDue(now: Date()) {\n            await importRefreshRecords()\n",
                            until: "let circlesNeedingRotation", in: circles)
        XCTAssertTrue(load.contains("            await publishSelfAdmissionsIfDue()\n"))

        // The own row is read again after each import and each roster pass, and goes at a sign-out.
        let importer = try body(of: "    private func importRefreshRecords() async {", until: "\n    }\n", in: circles)
        XCTAssertTrue(importer.contains("        ownRows.removeAll()\n"))
        XCTAssertTrue(circles.contains("        membershipCandidates[circleId] = pass.candidates\n"
                                       + "        rosterWraps[circleId] = Dictionary(responses.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })\n"
                                       + "        // This pass's member rows are what the SDK reads this account's own row from.\n"
                                       + "        ownRows.removeValue(forKey: CanonicalId.key(circleId))\n"))
        let reset = try body(of: "    func reset() {", until: "\n    }\n", in: circles)
        XCTAssertTrue(reset.contains("        ownRows.removeAll()\n"))
    }

    /// Every place a record is built waits for the counted own row.
    func testEveryKeyChangeWaitsForTheCountedOwnRow() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("                && !CanonicalId.isPersonalSlot($0.id)\n                && keyChangesMayBuild($0)\n        }"),
                      "the sweep (the rotation step with it)")
        XCTAssertTrue(circles.contains("holdsWhatItRotates(circle), !inRotationBackoff(circleId), !changesAwaitingImport.waits(circleId),\n"
                                       + "              keyChangesMayBuild(circle)\n"), "the owed rotation")
        let rotate = try body(of: "    func rotateCircleKey(for circleId: String) async throws {", until: "prepareRecordedChange(", in: circles)
        XCTAssertTrue(rotate.contains("        if !keyChangesMayBuild(circle) {\n"), "the rotation itself")
        let remove = try body(of: "    func removeMember(from circleId: String, userId: String) async throws {",
                              until: "change = try prepareRecordedChange(", in: circles)
        XCTAssertTrue(remove.contains("            guard keyChangesMayBuild(circle) else {\n"
                                      + "                throw CircleError.ejectFailed(CircleError.notDoneWhileWaitingToSync)\n"),
                      "an eject answers the existing words")
        // The owner's hand-over builds a record too, with the same gate.
        let handOver = try body(of: "    private func handOverWithRecord(", until: "change = try prepareRecordedChange(", in: circles)
        XCTAssertTrue(handOver.contains("              keyChangesMayBuild(circle)\n        else { throw CircleError.handOverNotNow }\n"),
                      "a hand-over waits too")
        XCTAssertEqual(circles.components(separatedBy: "prepareRecordedChange(").count - 1, 4,
                       "the definition and its three callers, all gated")
    }

    /// Receive-only is read through the SDK's own row at every reader.
    func testEveryReceiveOnlyReaderTakesTheLift() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("                && !selfIsReceiveOnly(circleId))"), "the rotation step")
        XCTAssertTrue(circles.contains("guard let me = AuthManager.shared.userId, !selfIsReceiveOnly(circle.id), holdsCurrentKey(for: circle.id),"),
                      "the admission backfill")
        XCTAssertTrue(circles.contains("selfIsReceiveOnly: selfIsReceiveOnly(circleId), isBehind: isBehind(circleId)),"), "deliveries")
        XCTAssertTrue(circles.contains("selfIsReceiveOnly: selfIsReceiveOnly(circleId)) {"), "the refresh plan")
        XCTAssertEqual(circles.components(separatedBy: ".selfIsReceiveOnly").count - 1, 1,
                       "the statement rule is read in one place: `selfIsReceiveOnly(_:)`")
    }
}
