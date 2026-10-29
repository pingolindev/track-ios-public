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

/// Who a device confirms as a member of a circle, from its own record and
/// SIGNED statements — never from the server's roster alone — and what it may
/// do for them.
///
/// Every statement here is a real Ed25519 signature made by the SDK
/// (`signMembershipStatement`) and checked by the SDK
/// (`verifyMembershipStatement`); only the pins are a stand-in, so each rule can
/// be set up without this device's key store.
final class MembershipConfirmationTests: XCTestCase {

    private let circle = "c0ffee00-0000-4000-8000-000000000001"

    /// One account: a user id and a device holding its two keys.
    private struct Party {
        let userId: String
        let crypto: CryptoManager
        let sharing: String
        let signing: String
        let email: String

        init(_ name: String) {
            userId = UUID().uuidString.lowercased()
            crypto = CryptoManager()
            let b64 = crypto.generateKeypair().publicKey
            sharing = Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
            signing = Data(base64Encoded: crypto.generateSigningKeypair().verifyingKeyB64)!
                .map { String(format: "%02x", $0) }.joined()
            email = "\(name)@example.com"
        }

        var me: MembershipConfirmation.Me {
            MembershipConfirmation.Me(userId: userId, sharingKeyHex: sharing, signingKeyHex: signing, email: email)
        }
    }

    /// The SDK does the parsing and the verifying; pins are this device's.
    private final class Checker: MembershipStatementChecking {
        let sdk = CryptoManager()
        var pins: [String: (sharing: String, signing: String)] = [:]
        var previousIdentities: Set<String> = []
        let own: String?

        init(own: String?) { self.own = own }

        func pin(_ party: Party) { pins[party.userId] = (party.sharing, party.signing) }

        func parse(_ statementHex: String) throws -> MembershipStatement {
            try sdk.parseMembershipStatement(statementHex: statementHex)
        }

        func verify(statementHex: String, signatureHex: String, signerKeyHex: String) throws -> Bool {
            try sdk.verifyMembershipStatement(
                statementHex: statementHex, signatureHex: signatureHex, signerSigningPublicKeyHex: signerKeyHex)
        }

        func pinnedSigningKey(circleId: String, userId: String) -> String? { pins[userId.lowercased()]?.signing }
        func pinnedSharingKey(circleId: String, userId: String) -> String? { pins[userId.lowercased()]?.sharing }
        func ownSigningKey() -> String? { own }
        func holdsPreviousIdentity(sharingKeyHex: String) -> Bool { previousIdentities.contains(sharingKeyHex.lowercased()) }
        /// A restored identity's signing key, as the SDK's
        /// `verifyOwnMembershipStatement` checks it.
        var previousSigning: [String] = []
        func ownSigner(statementHex: String, signatureHex: String) -> OwnStatementSigner? {
            func verifies(_ key: String) -> Bool {
                (try? verify(statementHex: statementHex, signatureHex: signatureHex, signerKeyHex: key)) == true
            }
            if let own, verifies(own) { return .currentKey }
            return previousSigning.contains(where: verifies) ? .previousKey : .notOurs
        }
    }

    private let now = Int64(Date().timeIntervalSince1970)

    /// A statement `signer` makes, signed with THEIR signing key — naming them
    /// as its signer, or whoever `signerId` says (a forgery, or the same person
    /// after a reset).
    private func statement(
        by signer: Party, as signerId: String? = nil, _ kind: MembershipStatementKind, about subject: Party? = nil,
        binding keys: (sharing: String, signing: String)? = nil, email: String? = nil,
        circle circleId: String? = nil, id: String = UUID().uuidString.lowercased(),
        atVersion: Int32 = 5, issuedAt: Int64? = nil
    ) throws -> SignedStatementRecord {
        let issued = issuedAt ?? now
        let bound = keys ?? subject.map { ($0.sharing, $0.signing) }
        let signed = try signer.crypto.signMembershipStatement(statement: MembershipStatement(
            kind: kind,
            circleId: circleId ?? circle,
            statementId: id,
            signerUserId: signerId ?? signer.userId,
            issuedAt: issued,
            expiresAt: kind == .admission ? 0 : issued + 604_800,
            atVersion: atVersion,
            subjectUserId: kind == .invitationToEmail ? nil : subject?.userId,
            subjectSharingPublicKeyHex: kind == .invitationToEmail ? nil : bound?.0,
            subjectSigningPublicKeyHex: kind == .invitationToEmail ? nil : bound?.1,
            subjectEmail: kind == .invitationToEmail ? (email ?? subject?.email) : nil
        ))
        return SignedStatementRecord(statementHex: signed.statementHex, signatureHex: signed.signatureHex)
    }

    private func row(_ party: Party, invitation: SignedStatementRecord? = nil,
                     admissions: [SignedStatementRecord] = [], keyVersion: Int? = 5,
                     accessRequested: Bool = false) -> MembershipCandidate {
        MembershipCandidate(userId: party.userId, sharingKeyHex: party.sharing, signingKeyHex: party.signing,
                            invitation: invitation, admissions: admissions, keyVersion: keyVersion,
                            accessRequested: accessRequested)
    }

    private func record(_ entries: [(Party, ApprovalOrigin)]) -> CircleApprovalRecord {
        var record = CircleApprovalRecord()
        for (party, origin) in entries { record.entries[party.userId] = origin }
        return record
    }

    private func evaluate(_ device: Party, _ roster: [MembershipCandidate], _ record: CircleApprovalRecord,
                          _ checker: Checker) -> MembershipConfirmation.Result {
        MembershipConfirmation.evaluate(circleId: circle, me: device.me, roster: roster, record: record, checker: checker)
    }

    // MARK: - A "Let them in" run that stops between its steps

    /// A waiting "Let them in" runs pin, then admission (its id saved first),
    /// then this device's choice. One that stops after the pin hands nobody
    /// anything: the member is still unconfirmed here.
    func testALetInStoppedAfterItsPinHandsNothingOver() throws {
        let (me, stranger, member) = (Party("me"), Party("stranger"), Party("member"))
        let checker = Checker(own: me.signing)
        let invitation = try statement(by: stranger, .invitationToAccount, about: member)
        checker.pin(member)  // the run's first step

        let pinnedOnly = row(member, invitation: invitation, keyVersion: nil)
        let before = evaluate(me, [row(me), pinnedOnly], CircleApprovalRecord(), checker)
        XCTAssertEqual(before.verdicts[member.userId], .unconfirmable, "pinned, not let in")
        XCTAssertFalse(MembershipConfirmation.mayDeliver(
            to: pinnedOnly, verdict: before.verdicts[member.userId], evidence: before.evidence[member.userId],
            circleKeyVersion: 5, myActiveVersion: 5, createdHere: false, now: Date()), "nothing handed over early")
    }

    /// One that stops after its admission, before the choice: this device
    /// confirms them from its own admission, but only as `.statement` (an
    /// admission has no expiry, so it makes nobody chosen). That hands them
    /// the circle at the admission's version only: the invitation's signer
    /// isn't confirmed here (that's why the question was asked), so after a
    /// rotation past the admission nothing does, whether they hold the older
    /// version or none. So the change runs again and records the choice, and
    /// with it they get every later version.
    func testAnOwnAdmissionWithoutTheChoiceHandsThemNothingAfterARotation() throws {
        let (me, stranger, member) = (Party("me"), Party("stranger"), Party("member"))
        let checker = Checker(own: me.signing)
        checker.pin(member)
        let invitation = try statement(by: stranger, .invitationToAccount, about: member)
        let admission = try statement(by: me, .admission, about: member, atVersion: 5)
        func handedOver(_ record: CircleApprovalRecord, holding keyVersion: Int?,
                        version: Int) -> (verdict: MembershipVerdict?, delivers: Bool) {
            let candidate = row(member, invitation: invitation, admissions: [admission], keyVersion: keyVersion)
            let result = evaluate(me, [row(me), candidate], record, checker)
            let verdict = result.verdicts[member.userId]
            return (verdict, MembershipConfirmation.mayDeliver(
                to: candidate, verdict: verdict, evidence: result.evidence[member.userId],
                circleKeyVersion: version, myActiveVersion: version, createdHere: false, now: Date()))
        }
        // Stopped before the choice.
        let atAdmission = handedOver(CircleApprovalRecord(), holding: nil, version: 5)
        XCTAssertEqual(atAdmission.verdict, .confirmed(.statement), "confirmed from its own admission, not chosen")
        XCTAssertTrue(atAdmission.delivers, "at the admission's version")
        XCTAssertFalse(handedOver(CircleApprovalRecord(), holding: 5, version: 6).delivers, "stranded after a rotation")
        XCTAssertFalse(handedOver(CircleApprovalRecord(), holding: nil, version: 6).delivers, "stranded after a rotation")
        // The choice, as the run records it (`approveAnswer`).
        let chosen = record([(member, .ownAction)])
        let afterRotation = handedOver(chosen, holding: 5, version: 6)
        XCTAssertEqual(afterRotation.verdict, .confirmed(.ownAction))
        XCTAssertTrue(afterRotation.delivers)
        XCTAssertTrue(handedOver(chosen, holding: nil, version: 6).delivers)
    }

    // MARK: - Own statements signed before a password reset

    /// This account invited someone before an email reset; after a restore
    /// its old signing key is known again. The invitation confirms
    /// them, but under an OLD key it never makes them chosen (even while it is
    /// live), becomes no approval, and no delivery rests on it.
    func testAnOwnStatementSignedBeforeTheResetConfirmsButNeverChooses() throws {
        let (me, oldMe, newcomer) = (Party("me"), Party("me-before-the-reset"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.previousSigning = [oldMe.signing]
        let invitation = try statement(by: oldMe, as: me.userId, .invitationToAccount, about: newcomer)
        let newcomerRow = row(newcomer, invitation: invitation, keyVersion: nil)
        let result = evaluate(me, [row(me), newcomerRow], CircleApprovalRecord(), checker)

        XCTAssertEqual(result.verdicts[newcomer.userId], .confirmed(.statement), "confirms, never .ownAction")
        XCTAssertEqual(result.newlyConfirmed[newcomer.userId]?.previousKeyOnly, true)
        XCTAssertNil(result.evidence[newcomer.userId], "no delivery rests on it")
        XCTAssertFalse(MembershipConfirmation.mayDeliver(
            to: newcomerRow, verdict: result.verdicts[newcomer.userId], evidence: result.evidence[newcomer.userId],
            circleKeyVersion: 5, myActiveVersion: 5, createdHere: false, now: Date(timeIntervalSince1970: TimeInterval(now))))

        // Without the restored identity it is someone else's signature: invalid.
        checker.previousSigning = []
        XCTAssertEqual(evaluate(me, [row(me), newcomerRow], CircleApprovalRecord(), checker).verdicts[newcomer.userId],
                       .invalid)

        // The same invitation signed with the CURRENT key chooses.
        let current = try statement(by: me, .invitationToAccount, about: newcomer)
        let chosen = evaluate(me, [row(me), row(newcomer, invitation: current, keyVersion: nil)], CircleApprovalRecord(), checker)
        XCTAssertEqual(chosen.verdicts[newcomer.userId], .confirmed(.ownAction))
        XCTAssertEqual(chosen.newlyConfirmed[newcomer.userId]?.previousKeyOnly, false)
    }

    /// A member holding a current-key statement and an old-key one is
    /// confirmed by the current one: that is what an approval may rest on.
    func testACurrentKeyStatementIsPreferredOverAnOldOne() throws {
        let (me, oldMe, owner, newcomer) = (Party("me"), Party("me-before"), Party("owner"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.previousSigning = [oldMe.signing]
        checker.pin(owner)
        let old = try statement(by: oldMe, as: me.userId, .admission, about: newcomer)
        let byOwner = try statement(by: owner, .admission, about: newcomer)
        let result = evaluate(me, [row(me), row(owner), row(newcomer, admissions: [old, byOwner])],
                              record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[newcomer.userId], .confirmed(.statement))
        XCTAssertEqual(result.newlyConfirmed[newcomer.userId]?.previousKeyOnly, false)
        XCTAssertNotNil(result.evidence[newcomer.userId], "the owner's admission is evidence")
    }

    /// A confirmation resting only on an old-key own statement is never
    /// recorded as an approval (the roster pass), so the backfill never
    /// vouches for it under the current key.
    func testAnOldKeyOnlyConfirmationIsNeverRecorded() throws {
        let (me, oldMe, newcomer) = (Party("me"), Party("me-before"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.previousSigning = [oldMe.signing]
        let invitation = try statement(by: oldMe, as: me.userId, .invitationToAccount, about: newcomer)
        let roster = try Self.roster([(me, nil), (newcomer, invitation)])
        let pass = AccessHandover.rosterPass(
            circleId: circle, me: me.me, roster: roster, rosterComplete: true, activeVersion: 5,
            stored: CircleApprovalRecord(), checker: checker, now: Date(timeIntervalSince1970: TimeInterval(now)))
        XCTAssertEqual(pass.result.verdicts[newcomer.userId], .confirmed(.statement))
        XCTAssertNil(pass.record.entries[newcomer.userId], "no approval from an old key alone")
        XCTAssertEqual(pass.pinActions[newcomer.userId], .pin, "they are still a confirmed member here")
    }

    /// Rows in the server's shape, for the roster pass.
    private static func roster(_ rows: [(Party, SignedStatementRecord?)]) throws -> [CircleMemberResponse] {
        let json: [[String: Any]] = rows.map { party, invitation in
            var row: [String: Any] = [
                "user_id": party.userId, "display_name": "m", "role": "member",
                "encrypted_circle_key": ["nonce": "", "ciphertext": ""], "ephemeral_public_key": "",
                "can_see_history": true, "can_see_realtime": true, "status": "active",
                "joined_day_bucket": 20_000, "sharing_public_key": party.sharing, "signing_public_key": party.signing,
            ]
            if let invitation {
                row["invitation"] = ["statement": invitation.statementHex, "signature": invitation.signatureHex]
            } else {
                row["key_version"] = 5
            }
            return row
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([CircleMemberResponse].self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - This account, spelt another way

    /// This account under any spelling of its id is this account: its row
    /// carries this device's own keys, never the list's, and reads as this
    /// account's own; a statement "by" it is judged under its own key alone,
    /// so one the server signed confirms nobody.
    func testThisAccountSpeltAnotherWayIsThisAccount() throws {
        let (me, newcomer, server) = (Party("me"), Party("newcomer"), Party("server"))
        let checker = Checker(own: me.signing)
        let forged = try statement(by: server, as: me.userId, .invitationToAccount, about: newcomer)
        let bare = me.userId.replacingOccurrences(of: "-", with: "")
        for spelt in [me.userId.uppercased(), bare, bare.uppercased(), "{\(me.userId)}", "urn:uuid:\(me.userId)"] {
            let listed = MembershipCandidate(userId: spelt, sharingKeyHex: server.sharing, signingKeyHex: server.signing,
                                             invitation: nil, admissions: [], keyVersion: 5, accessRequested: false)
            let result = MembershipConfirmation.evaluate(
                circleId: circle, me: me.me, roster: [listed, row(newcomer, invitation: forged)],
                record: CircleApprovalRecord(), checker: checker)
            XCTAssertEqual(result.verdicts[spelt], .confirmed(.ownAction), "this account's own row: \(spelt)")
            if case .confirmed? = result.verdicts[newcomer.userId] {
                XCTFail("a statement the server signed \"by\" this account confirmed someone: \(spelt)")
            }
        }
    }

    // MARK: - Invitations

    /// A newcomer the owner invited is confirmed by a plain member's device
    /// from the signed invitation alone, and that device may hand them the
    /// circle while the invitation is fresh.
    func testAValidInvitationLetsAnyMemberDeliverToTheNewcomer() throws {
        let (me, owner, newcomer) = (Party("me"), Party("owner"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        let invitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let newcomerRow = row(newcomer, invitation: invitation, keyVersion: nil)
        let result = evaluate(me, [row(me), row(owner), newcomerRow], record([(owner, .preRound2Seed)]), checker)

        XCTAssertEqual(result.verdicts[newcomer.userId], .confirmed(.statement))
        XCTAssertEqual(result.newlyConfirmed[newcomer.userId]?.origin, .statement)
        XCTAssertNil(result.newlyConfirmed[newcomer.userId]?.keys, "a full member is pinned, not kept in the record")
        func mayDeliver(at time: TimeInterval) -> Bool {
            MembershipConfirmation.mayDeliver(
                to: newcomerRow, verdict: result.verdicts[newcomer.userId], evidence: result.evidence[newcomer.userId],
                circleKeyVersion: 5, myActiveVersion: 5, createdHere: false,
                now: Date(timeIntervalSince1970: time))
        }
        XCTAssertTrue(mayDeliver(at: TimeInterval(now)))
        XCTAssertTrue(mayDeliver(at: TimeInterval(now + 604_800 + 299)), "five minutes' grace for clocks")
        XCTAssertFalse(mayDeliver(at: TimeInterval(now + 604_800 + 301)),
                       "an expired invitation leaves the first delivery to owners and admins")
    }

    /// A statement nobody confirmed signed: hidden everywhere, never pinned,
    /// never given anything, and no question about it.
    func testAForgedStatementHidesTheMemberAndGivesThemNothing() throws {
        let (me, owner, ghost) = (Party("me"), Party("owner"), Party("ghost"))
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        // The server's own key, claiming to be the owner's.
        let forged = try statement(by: Party("server"), as: owner.userId, .invitationToAccount, about: ghost)
        XCTAssertEqual(try checker.parse(forged.statementHex).signerUserId, owner.userId)

        let ghostRow = row(ghost, invitation: forged, keyVersion: nil)
        let result = evaluate(me, [row(me), row(owner), ghostRow], record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[ghost.userId], .invalid)
        XCTAssertFalse(result.verdicts[ghost.userId]?.isShown ?? true)
        XCTAssertNil(result.newlyConfirmed[ghost.userId], "never recorded, so never pinned")
        XCTAssertNil(result.askReasons[ghost.userId], "a forgery gets no question")
        XCTAssertFalse(MembershipConfirmation.mayDeliver(
            to: ghostRow, verdict: result.verdicts[ghost.userId], evidence: nil,
            circleKeyVersion: 5, myActiveVersion: 5, createdHere: true, now: Date()))
    }

    /// Invited from an app too old to sign invitations: hidden on EVERY device,
    /// owners' and admins' too, and nobody is asked. Someone already let in
    /// stays in: that answer is a permanent entry.
    func testNoStatementIsHiddenAndNeverAskedAbout() throws {
        let (me, owner, legacy) = (Party("me"), Party("owner"), Party("legacy"))
        let checker = Checker(own: me.signing)
        let result = evaluate(me, [row(me), row(owner), row(legacy)], record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[legacy.userId], .legacy)
        XCTAssertFalse(result.verdicts[legacy.userId]?.isShown ?? true)
        XCTAssertNil(result.askReasons[legacy.userId], "never asked about")
        XCTAssertTrue(result.askReasons.isEmpty)
        let letInBefore = evaluate(me, [row(me), row(owner), row(legacy)],
                                   record([(owner, .preRound2Seed), (legacy, .ownAction)]), checker)
        XCTAssertEqual(letInBefore.verdicts[legacy.userId], .confirmed(.ownAction), "a stored answer stays valid")
    }

    /// The same invitation to an email on two rows counts for neither; a
    /// kind-1 invitation copied onto another row is invalid there only — it
    /// names someone else.
    func testReuseHidesBothForEmailInvitationsAndOnlyTheCopyOtherwise() throws {
        let (me, owner, a, b, newcomer) = (Party("me"), Party("owner"), Party("a"), Party("b"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        let emailInvitation = try statement(by: owner, .invitationToEmail, email: "shared@example.com")
        let accountInvitation = try statement(by: owner, .invitationToAccount, about: newcomer)
        let result = evaluate(me, [
            row(me), row(owner),
            row(a, invitation: emailInvitation), row(b, invitation: emailInvitation),
            row(newcomer, invitation: accountInvitation), row(Party("copy"), invitation: accountInvitation),
        ], record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[a.userId], .invalid)
        XCTAssertEqual(result.verdicts[b.userId], .invalid)
        XCTAssertEqual(result.verdicts[newcomer.userId], .confirmed(.statement), "the real row still holds")
        XCTAssertEqual(result.verdicts.values.filter { $0 == .invalid }.count, 3)
    }

    /// Someone who LEFT vouches for nobody. The caller retires their pin and
    /// their record entry first; their invitation then confirms nobody.
    func testASignerWhoLeftConfirmsNobody() throws {
        let (me, owner, leaver, newcomer) = (Party("me"), Party("owner"), Party("leaver"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        let invitation = try statement(by: leaver, .invitationToAccount, about: newcomer)
        var rec = record([(owner, .preRound2Seed)])
        rec.tombstones[leaver.userId] = ApprovalTombstone(statementIds: [], activeVersion: 5)
        let result = evaluate(me, [row(me), row(owner), row(newcomer, invitation: invitation)], rec, checker)
        XCTAssertEqual(result.verdicts[newcomer.userId], .unconfirmable)
        XCTAssertEqual(result.askReasons[newcomer.userId], .unconfirmedInviter,
                       "an owner's or admin's device asks, showing their number")
        // Even with the leaver's identity pin still held (retain keeps those): a
        // departed signer is not confirmed, so a pin is only a key lookup.
        checker.pin(leaver)
        XCTAssertEqual(evaluate(me, [row(me), row(owner), row(newcomer, invitation: invitation)], rec, checker)
            .verdicts[newcomer.userId], .unconfirmable)
    }

    /// A tombstoned statement id never confirms again, and someone who left
    /// comes back only by a statement made at or after the version this
    /// device held when they left.
    func testTombstonesKeepADepartedMemberOut() throws {
        let (me, owner, returner) = (Party("me"), Party("owner"), Party("returner"))
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        let old = try statement(by: owner, .invitationToAccount, about: returner, atVersion: 6)
        var rec = record([(owner, .preRound2Seed)])
        let oldId = try checker.parse(old.statementHex).statementId
        rec.tombstones[returner.userId] = ApprovalTombstone(statementIds: [oldId], activeVersion: 6)
        func verdict(_ invitation: SignedStatementRecord) -> MembershipVerdict? {
            evaluate(me, [row(me), row(owner), row(returner, invitation: invitation)], rec, checker)
                .verdicts[returner.userId]
        }
        XCTAssertEqual(verdict(old), .invalid, "the old invitation, replayed")
        XCTAssertEqual(verdict(try statement(by: owner, .invitationToAccount, about: returner, atVersion: 5)), .invalid,
                       "made before they left")
        XCTAssertEqual(verdict(try statement(by: owner, .invitationToAccount, about: returner, atVersion: 6)),
                       .confirmed(.statement), "a fresh invitation at the version they left at")
    }

    /// A statement binding keys other than this device's pin for them — their
    /// identity changed — is a SUBJECT CONFLICT: shown, asked about ("Is this
    /// really…?"), never confirmed that way, never a pin move. With no pin, keys
    /// that are not their current ones hold nothing.
    func testAChangedIdentityIsAConflictNotAConfirmation() throws {
        let (me, owner, member) = (Party("me"), Party("owner"), Party("member"))
        let reset = Party("member-after-reset")
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        checker.pin(member)  // pinned before their reset
        let admission = try statement(by: owner, .admission, about: member, binding: (reset.sharing, reset.signing))
        let afterReset = MembershipCandidate(userId: member.userId, sharingKeyHex: reset.sharing, signingKeyHex: reset.signing,
                                             invitation: nil, admissions: [admission], keyVersion: 5, accessRequested: false)
        let result = evaluate(me, [row(me), row(owner), afterReset], record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[member.userId], .subjectConflict)
        XCTAssertTrue(result.verdicts[member.userId]?.isShown ?? false)
        XCTAssertNil(result.newlyConfirmed[member.userId])
        XCTAssertEqual(checker.pins[member.userId]?.sharing, member.sharing, "the pin did not move")

        let stray = try statement(by: owner, .admission, about: member, binding: (Party("x").sharing, Party("y").signing))
        let strayRow = MembershipCandidate(userId: member.userId, sharingKeyHex: reset.sharing, signingKeyHex: reset.signing,
                                           invitation: nil, admissions: [stray], keyVersion: 5, accessRequested: false)
        XCTAssertEqual(evaluate(me, [row(me), row(owner), strayRow], record([(owner, .preRound2Seed)]), checker)
            .verdicts[member.userId], .subjectConflict, "keys other than the pin, whatever they are")
        checker.pins[member.userId] = nil
        XCTAssertEqual(evaluate(me, [row(me), row(owner), strayRow], record([(owner, .preRound2Seed)]), checker)
            .verdicts[member.userId], .invalid, "no pin: keys that are not theirs hold nothing")
    }

    /// Made with the signer's CURRENT key while this device still pins their
    /// old one: they changed identity and this device has not confirmed it —
    /// unconfirmable (their own question comes first), not a forgery.
    func testASignerWhoChangedIdentityIsUnconfirmedNotForged() throws {
        let (me, admin, newcomer) = (Party("me"), Party("admin"), Party("newcomer"))
        let adminAfterReset = Party("admin-after-reset")
        let checker = Checker(own: me.signing)
        checker.pin(admin)  // the OLD keys
        let invitation = try statement(by: adminAfterReset, as: admin.userId, .invitationToAccount, about: newcomer)
        let adminRow = MembershipCandidate(userId: admin.userId, sharingKeyHex: adminAfterReset.sharing,
                                           signingKeyHex: adminAfterReset.signing, invitation: nil, admissions: [],
                                           keyVersion: 5, accessRequested: false)
        let result = evaluate(me, [row(me), adminRow, row(newcomer, invitation: invitation)],
                              record([(admin, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[newcomer.userId], .unconfirmable)
        XCTAssertEqual(result.askReasons[newcomer.userId], .unconfirmedInviter)
    }

    // MARK: - This device's own statements

    /// A fresh device — no record, no pins — anchors on whoever signed its OWN
    /// invitation, checked against its own keys; the fixpoint then confirms
    /// that signer's other newcomers. Nobody else.
    func testAFreshDeviceAnchorsOnItsOwnInviterOnly() throws {
        let (me, inviter, other, ghost) = (Party("me"), Party("inviter"), Party("other"), Party("ghost"))
        let checker = Checker(own: me.signing)
        let mine = try statement(by: inviter, .invitationToAccount, about: me)
        let theirs = try statement(by: inviter, .invitationToAccount, about: other)
        let result = evaluate(me, [row(me, invitation: mine), row(inviter), row(other, invitation: theirs), row(ghost)],
                              CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[inviter.userId], .confirmed(.statement))
        XCTAssertEqual(result.verdicts[other.userId], .confirmed(.statement))
        XCTAssertEqual(result.verdicts[ghost.userId], .legacy, "the anchor is not a roster seed")
        XCTAssertFalse(result.selfIsReceiveOnly)
        XCTAssertEqual(Set(result.newlyConfirmed.keys), [inviter.userId, other.userId])
    }

    /// A device with legacy seeds for the circle is anchored by them: its own
    /// invitation adds nobody (the anchor is for a device with no seed), so a
    /// server cannot slip a signer in through it.
    func testASeededDeviceDoesNotAnchorOnItsOwnInvitation() throws {
        let (me, seed, stranger) = (Party("me"), Party("seed"), Party("stranger"))
        let checker = Checker(own: me.signing)
        checker.pin(seed)
        let mine = try statement(by: stranger, .invitationToAccount, about: me)
        let result = evaluate(me, [row(me, invitation: mine), row(seed), row(stranger)],
                              record([(seed, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[stranger.userId], .legacy)
        XCTAssertNil(result.newlyConfirmed[stranger.userId])
    }

    /// An invitation for this account that binds OTHER keys anchors nothing —
    /// unless they are a previous identity whose private key this device holds
    /// — and this device is receive-only until an owner or admin admits its
    /// CURRENT keys.
    func testAStatementBindingAnotherIdentityMakesThisDeviceReceiveOnly() throws {
        let (me, inviter) = (Party("me"), Party("inviter"))
        let before = Party("me-before-reset")
        let checker = Checker(own: me.signing)
        let mine = try statement(by: inviter, .invitationToAccount, about: me, binding: (before.sharing, before.signing))
        var result = evaluate(me, [row(me, invitation: mine), row(inviter)], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[inviter.userId], .legacy, "anchors nothing: a key the server lists proves nothing")
        XCTAssertTrue(result.selfIsReceiveOnly)

        checker.previousIdentities = [before.sharing]
        result = evaluate(me, [row(me, invitation: mine), row(inviter)], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[inviter.userId], .confirmed(.statement), "restored with the recovery key: anchors")
        XCTAssertTrue(result.selfIsReceiveOnly, "still receive-only after its own reset")

        checker.pin(inviter)
        let admitted = try statement(by: inviter, .admission, about: me)
        result = evaluate(me, [row(me, invitation: mine, admissions: [admitted]), row(inviter)],
                          record([(inviter, .statement)]), checker)
        XCTAssertFalse(result.selfIsReceiveOnly, "an admission for its current keys lifts it")
    }

    /// Joined by an invitation to its EMAIL: receive-only until admitted.
    func testJoiningByEmailIsReceiveOnlyUntilAdmitted() throws {
        let (me, inviter) = (Party("me"), Party("inviter"))
        let checker = Checker(own: me.signing)
        let mine = try statement(by: inviter, .invitationToEmail, about: me)
        var result = evaluate(me, [row(me, invitation: mine), row(inviter)], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[inviter.userId], .confirmed(.statement))
        XCTAssertTrue(result.selfIsReceiveOnly)
        let admitted = try statement(by: inviter, .admission, about: me)
        result = evaluate(me, [row(me, invitation: mine, admissions: [admitted]), row(inviter)], CircleApprovalRecord(), checker)
        XCTAssertFalse(result.selfIsReceiveOnly)
        let other = try statement(by: inviter, .invitationToEmail, email: "someone-else@example.com")
        result = evaluate(me, [row(me, invitation: other), row(inviter)], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[inviter.userId], .legacy, "another email anchors nothing")
    }

    /// Joined by an invitation to an email, with no account email to check it
    /// against on this pass (no /auth/me read in this process and none
    /// mirrored): it anchors nobody, the device is receive-only as a known one
    /// makes it, and its first key WAITS, from whoever it comes, unless it is the
    /// account's own signed slot. Knowing the email, the inviter anchors it as
    /// usual; an admission for its current keys anchors it without the email.
    func testAnEmailInvitationNoEmailCanCheckIsReceiveOnlyAndItsFirstKeyWaits() throws {
        let (me, inviter, stranger) = (Party("me"), Party("inviter"), Party("stranger"))
        let checker = Checker(own: me.signing)
        let mine = try statement(by: inviter, .invitationToEmail, about: me)
        let unknown = MembershipConfirmation.Me(userId: me.userId, sharingKeyHex: me.sharing,
                                                signingKeyHex: me.signing, email: nil)
        func pass(_ roster: [MembershipCandidate]) -> MembershipConfirmation.Result {
            MembershipConfirmation.evaluate(circleId: circle, me: unknown, roster: roster,
                                            record: CircleApprovalRecord(), checker: checker)
        }
        var result = pass([row(me, invitation: mine), row(inviter), row(stranger)])
        func decide(_ sender: String?, signed: Bool = true) -> Track.CircleManager.FirstKeyDecision {
            Track.CircleManager.firstKeyDecision(senderUserId: sender, selfUserId: me.userId, signed: signed,
                                                 membership: result)
        }
        XCTAssertEqual(result.verdicts[inviter.userId], .legacy, "who invited it can't be confirmed")
        XCTAssertTrue(result.selfIsReceiveOnly)
        XCTAssertTrue(result.ownInvitationUnchecked)
        XCTAssertEqual(decide(inviter.userId), .wait, "never on trust, not even from the inviter")
        XCTAssertEqual(decide(stranger.userId), .wait)
        XCTAssertEqual(decide(stranger.userId, signed: false), .wait)
        XCTAssertEqual(decide(me.userId, signed: false), .wait, "an unsigned 'own' wrap is anyone's")
        XCTAssertEqual(decide(nil), .fromConfirmedSender, "our own signed slot: verified under our own key")

        result = evaluate(me, [row(me, invitation: mine), row(inviter), row(stranger)], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[inviter.userId], .confirmed(.statement), "knowing the email: anchored as usual")
        XCTAssertTrue(result.selfIsReceiveOnly)
        XCTAssertFalse(result.ownInvitationUnchecked)
        XCTAssertEqual(decide(inviter.userId), .fromConfirmedSender)
        XCTAssertEqual(decide(stranger.userId, signed: false), .refuse)

        let admitted = try statement(by: inviter, .admission, about: me)
        result = pass([row(me, invitation: mine, admissions: [admitted]), row(inviter), row(stranger)])
        XCTAssertEqual(result.verdicts[inviter.userId], .confirmed(.statement), "the admission's signer anchors it")
        XCTAssertFalse(result.selfIsReceiveOnly)
        XCTAssertFalse(result.ownInvitationUnchecked, "an admission needs no email")
        XCTAssertEqual(decide(inviter.userId), .fromConfirmedSender)
        XCTAssertEqual(decide(stranger.userId), .refuse)
    }

    /// The same for an own invitation to ANOTHER address than the account's
    /// known email (it changed since the invitation was sent, or the server's
    /// word is wrong): anchors nobody, receive-only, and the first key waits.
    /// Otherwise the device would be neither receive-only nor anchored and
    /// take its first key on trust, and one that already held the key would
    /// go on to deliver and refresh after an email change.
    func testAnEmailInvitationToAnotherAddressIsReceiveOnlyAndItsFirstKeyWaits() throws {
        let (me, inviter, stranger) = (Party("me"), Party("inviter"), Party("stranger"))
        let checker = Checker(own: me.signing)
        let earlier = try statement(by: inviter, .invitationToEmail, email: "before-the-change@example.com")
        var result = evaluate(me, [row(me, invitation: earlier), row(inviter), row(stranger)],
                              CircleApprovalRecord(), checker)
        func decide(_ sender: String?, signed: Bool = true) -> Track.CircleManager.FirstKeyDecision {
            Track.CircleManager.firstKeyDecision(senderUserId: sender, selfUserId: me.userId, signed: signed,
                                                 membership: result)
        }
        XCTAssertEqual(result.verdicts[inviter.userId], .legacy, "another address anchors nothing")
        XCTAssertTrue(result.selfIsReceiveOnly)
        XCTAssertTrue(result.ownInvitationUnchecked)
        XCTAssertEqual(decide(inviter.userId), .wait)
        XCTAssertEqual(decide(stranger.userId, signed: false), .wait)
        XCTAssertEqual(decide(nil), .fromConfirmedSender, "our own signed slot")

        let admitted = try statement(by: inviter, .admission, about: me)
        result = evaluate(me, [row(me, invitation: earlier, admissions: [admitted]), row(inviter), row(stranger)],
                          CircleApprovalRecord(), checker)
        XCTAssertFalse(result.selfIsReceiveOnly, "an admission for the current keys lifts it, whatever the address")
        XCTAssertFalse(result.ownInvitationUnchecked)
        XCTAssertEqual(decide(stranger.userId), .refuse)
    }

    /// An SDK pin is never an anchor: legacy builds pinned every member
    /// they were shown, ghosts included, and those identity pins survive.
    /// Only the device's record and signed statements confirm.
    func testAnSDKPinIsNeverAnAnchor() throws {
        let (me, known, newcomer) = (Party("me"), Party("known"), Party("newcomer"))
        let checker = Checker(own: me.signing)
        checker.pin(known)
        let theirs = try statement(by: known, .invitationToAccount, about: newcomer)
        let result = evaluate(me, [row(me), row(known), row(newcomer, invitation: theirs)], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[known.userId], .legacy, "a pin confirms nobody")
        XCTAssertEqual(result.verdicts[newcomer.userId], .unconfirmable)
        XCTAssertTrue(result.newlyConfirmed.isEmpty)
        // ...whereas the record, carried over a same-account sign-out, does.
        let carried = evaluate(me, [row(me), row(known), row(newcomer, invitation: theirs)],
                               record([(known, .statement)]), checker)
        XCTAssertEqual(carried.verdicts[newcomer.userId], .confirmed(.statement))
    }

    // MARK: - Receive-only

    /// An invitation to an email confirms RECEIVE-ONLY: shown and given the
    /// circle, their keys kept in the record (never pinned), and their own
    /// statements vouch for nobody. Only an admission lifts it.
    func testAnEmailInviteeIsReceiveOnlyAndVouchesForNobody() throws {
        let (me, owner, invitee, friend) = (Party("me"), Party("owner"), Party("invitee"), Party("friend"))
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        let emailInvitation = try statement(by: owner, .invitationToEmail, about: invitee)
        let byInvitee = try statement(by: invitee, .invitationToAccount, about: friend)
        var result = evaluate(me, [row(me), row(owner), row(invitee, invitation: emailInvitation),
                                   row(friend, invitation: byInvitee)], record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[invitee.userId], .confirmed(.kind2))
        XCTAssertEqual(result.newlyConfirmed[invitee.userId]?.keys,
                       MemberKeyPair(sharingKeyHex: invitee.sharing, signingKeyHex: invitee.signing))
        XCTAssertEqual(result.verdicts[friend.userId], .unconfirmable, "a receive-only signer vouches for nobody")

        let admission = try statement(by: owner, .admission, about: invitee)
        result = evaluate(me, [row(me), row(owner), row(invitee, invitation: emailInvitation, admissions: [admission]),
                               row(friend, invitation: byInvitee)], record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[invitee.userId], .confirmed(.statement), "an admission lifts receive-only")
        XCTAssertEqual(result.verdicts[friend.userId], .confirmed(.statement))
    }

    /// A member carrying only invitations to an email is never asked about —
    /// letting them in would lift receive-only, which only a promotion may.
    func testAnEmailOnlyMemberIsNeverAskedAbout() throws {
        let (me, owner, stranger, invitee) = (Party("me"), Party("owner"), Party("stranger"), Party("invitee"))
        let checker = Checker(own: me.signing)
        let byStranger = try statement(by: stranger, .invitationToEmail, about: invitee)
        let result = evaluate(me, [row(me), row(owner), row(invitee, invitation: byStranger)],
                              record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(result.verdicts[invitee.userId], .unconfirmable)
        XCTAssertNil(result.askReasons[invitee.userId])
    }

    // MARK: - Delivery

    func testWhoMayDeliver() throws {
        let member = MembershipCandidate(userId: "m", sharingKeyHex: nil, signingKeyHex: nil, invitation: nil,
                                         admissions: [], keyVersion: 4, accessRequested: false)
        func may(_ verdict: MembershipVerdict?, _ evidence: DeliveryEvidence? = nil, owner: Bool = false,
                 row: MembershipCandidate? = nil, mine: Int = 5) -> Bool {
            MembershipConfirmation.mayDeliver(to: row ?? member, verdict: verdict, evidence: evidence,
                                              circleKeyVersion: 5, myActiveVersion: mine,
                                              createdHere: owner, now: Date())
        }
        XCTAssertTrue(may(.confirmed(.statement), owner: true), "the device that created the circle, to anyone confirmed and owed")
        XCTAssertTrue(may(.confirmed(.ownAction)), "chosen here (case (c))")
        XCTAssertTrue(may(.confirmed(.ownKind2)), "chosen here, receive-only")
        XCTAssertFalse(may(.confirmed(.statement)), "owed, but nothing a plain member may rest on")
        XCTAssertTrue(may(.confirmed(.statement), DeliveryEvidence(admissionAtVersions: [5])), "admitted at this version")
        XCTAssertFalse(may(.confirmed(.statement), DeliveryEvidence(admissionAtVersions: [4])), "admitted before it")
        XCTAssertFalse(may(.confirmed(.statement), DeliveryEvidence(invitationExpiresAt: Int64.max)),
                       "an invitation covers only the FIRST delivery, to a member with no copy")
        XCTAssertFalse(may(.subjectConflict, owner: true))
        XCTAssertFalse(may(.legacy, owner: true))
        XCTAssertFalse(may(.invalid, owner: true))
        let current = MembershipCandidate(userId: "m", sharingKeyHex: nil, signingKeyHex: nil, invitation: nil,
                                          admissions: [], keyVersion: 5, accessRequested: false)
        XCTAssertFalse(may(.confirmed(.ownAction), owner: true, row: current), "holds the current version: not owed")
        let asking = MembershipCandidate(userId: "m", sharingKeyHex: nil, signingKeyHex: nil, invitation: nil,
                                         admissions: [], keyVersion: 5, accessRequested: true)
        XCTAssertTrue(may(.confirmed(.ownAction), row: asking), "an open request is owed")
    }

    /// On a circle with refresh records, the records' delivery answer
    /// (`eDeliver`) replaces the three delivery cases and `createdHere`,
    /// and still only for a confirmed member who is owed the version.
    func testEDeliverReplacesTheThreeCasesOnACircleWithRecords() {
        let owed = MembershipCandidate(userId: "m", sharingKeyHex: nil, signingKeyHex: nil, invitation: nil,
                                       admissions: [], keyVersion: nil, accessRequested: false)
        let current = MembershipCandidate(userId: "m", sharingKeyHex: nil, signingKeyHex: nil, invitation: nil,
                                          admissions: [], keyVersion: 5, accessRequested: false)
        func may(_ row: MembershipCandidate, _ verdict: MembershipVerdict?, createdHere: Bool = false,
                 _ evidence: DeliveryEvidence? = nil, eDeliver: Bool?) -> Bool {
            MembershipConfirmation.mayDeliver(to: row, verdict: verdict, evidence: evidence, circleKeyVersion: 5,
                                              myActiveVersion: 5, createdHere: createdHere, now: Date(),
                                              eDeliver: eDeliver)
        }
        XCTAssertTrue(may(owed, .confirmed(.ownAction), createdHere: true, eDeliver: nil), "the three cases, with no records")
        XCTAssertFalse(may(owed, .confirmed(.ownAction), createdHere: true, eDeliver: false),
                       "eDeliver's no, whoever chose them and wherever the circle was made")
        XCTAssertFalse(may(owed, .confirmed(.statement), DeliveryEvidence(admissionAtVersions: [5]), eDeliver: false),
                       "eDeliver's no, whatever the three cases' evidence")
        XCTAssertTrue(may(owed, .confirmed(.statement), eDeliver: true), "eDeliver's yes, with no evidence for the three cases")
        XCTAssertFalse(may(current, .confirmed(.statement), eDeliver: true), "not owed: they hold the version")
        XCTAssertFalse(may(owed, .unconfirmable, eDeliver: true), "never someone this device doesn't confirm")
        XCTAssertFalse(may(owed, .subjectConflict, eDeliver: true))
    }

    /// The delivery pass takes the records' delivery set on a circle with
    /// records (ids compared case-insensitively), and the three delivery
    /// cases without one.
    func testTheDeliveryPassTakesEDeliversAnswerOnACircleWithRecords() {
        var result = MembershipConfirmation.Result()
        result.verdicts = ["A": .confirmed(.statement), "b": .confirmed(.ownAction)]
        let candidates = Dictionary(uniqueKeysWithValues: ["A", "b"].map { id in
            (id, MembershipCandidate(userId: id, sharingKeyHex: "s", signingKeyHex: "t", invitation: nil,
                                     admissions: [], keyVersion: nil, accessRequested: false))
        })
        let members = ["A", "b"].map {
            AccessHandover.Member(userId: $0, displayName: $0, sharingKeyHex: "s", signingKeyHex: "t")
        }
        func delivered(_ eDeliver: Set<String>?, createdHere: Bool = false) -> [String] {
            AccessHandover.deliveries(
                me: "me", circleKeyVersion: 5, heldVersion: 5, createdHere: createdHere, members: members,
                candidates: candidates, result: result, record: CircleApprovalRecord(), now: Date(),
                eDeliver: eDeliver, pinGate: { _ in [] }).map(\.userId)
        }
        XCTAssertEqual(delivered(nil), ["b"], "the three cases: chosen here")
        XCTAssertEqual(delivered(nil, createdHere: true), ["A", "b"])
        XCTAssertEqual(delivered(["a"]), ["A"], "eDeliver's yes for A; its no for b, though chosen here")
        XCTAssertEqual(delivered([], createdHere: true), [], "eDeliver's no for everyone, even on the creator's device")
    }

    /// The first key comes only from a confirmed sender; a device nothing
    /// anchors takes it on trust once; an anchored device never takes one
    /// from a stranger.
    func testTheFirstKeyComesFromAConfirmedSender() {
        let me = "me", friend = "friend", stranger = "stranger", emailed = "emailed"
        var anchored = MembershipConfirmation.Result()
        anchored.verdicts = [me: .confirmed(.ownAction), friend: .confirmed(.statement),
                             stranger: .legacy, emailed: .confirmed(.kind2)]
        var alone = MembershipConfirmation.Result()
        alone.verdicts = [me: .confirmed(.ownAction), stranger: .legacy]
        func decide(_ sender: String?, signed: Bool = true, _ result: MembershipConfirmation.Result?) -> Track.CircleManager.FirstKeyDecision {
            Track.CircleManager.firstKeyDecision(senderUserId: sender, selfUserId: me, signed: signed, membership: result)
        }
        XCTAssertEqual(decide(friend, anchored), .fromConfirmedSender)
        XCTAssertEqual(decide(friend, signed: false, anchored), .refuse, "unsigned: nothing to verify")
        XCTAssertEqual(decide(stranger, anchored), .refuse, "anchored: never from someone it cannot confirm")
        XCTAssertEqual(decide(emailed, anchored), .refuse, "a receive-only member's key authenticates nothing")
        XCTAssertEqual(decide("unlisted", alone), .refuse, "not even on the member list")
        XCTAssertEqual(decide(stranger, alone), .onTrustAndAnchor, "nothing anchors this device: once, on trust")
        XCTAssertEqual(decide(stranger, nil), .refuse, "before the member list has loaded")
        XCTAssertEqual(decide(nil, anchored), .fromConfirmedSender, "our own signed slot")
        XCTAssertEqual(decide(me, signed: false, anchored), .refuse, "an unsigned 'own' wrap is anyone's")
        XCTAssertEqual(decide(me, signed: false, alone), .onTrustAndAnchor)
    }

    // MARK: - Pins only on confirmation

    /// Only a confirmed member is ever pinned; a listed ghost never is, however
    /// it is listed. A receive-only member's keys go to the record instead.
    func testOnlyAConfirmedMemberIsPinned() {
        typealias Pin = Track.CircleManager.PinAction
        func action(_ verdict: MembershipVerdict?, known: Bool = false) -> Pin {
            Track.CircleManager.pinAction(for: verdict, receiveOnlyKeysKnown: known)
        }
        XCTAssertEqual(action(.confirmed(.statement)), .pin)
        XCTAssertEqual(action(.confirmed(.preRound2Seed)), .pin)
        XCTAssertEqual(action(.confirmed(.anchor)), .pin)
        XCTAssertEqual(action(.confirmed(.kind2)), .rememberReceiveOnlyKeys)
        XCTAssertEqual(action(.confirmed(.ownKind2), known: true), .askIfReceiveOnlyKeysChanged)
        XCTAssertEqual(action(.subjectConflict), .askIfPinnedKeysChanged)
        for verdict: MembershipVerdict? in [.legacy, .unconfirmable, .invalid, nil] {
            XCTAssertEqual(action(verdict), .nothing, "\(String(describing: verdict)) must never be pinned")
        }
        let kept = Track.CircleManager.pinsKept(
            roster: ["me", "friend", "emailed", "ghost", "conflict"],
            verdicts: ["me": .confirmed(.ownAction), "friend": .confirmed(.statement), "emailed": .confirmed(.kind2),
                       "ghost": .legacy, "conflict": .subjectConflict],
            selfUserId: "me")
        XCTAssertEqual(kept, ["me", "friend"])
    }

    /// Through the real SDK: the first retain drops an earlier build's
    /// view-pin, and a wrap "from" a listed but unconfirmed member is refused —
    /// by the SDK's pin rule and by the first-key path. The confirmed member's
    /// wrap is taken.
    func testAWrapFromAnUnconfirmedMemberIsRefused() throws {
        let circle = "d1000000-0000-4000-8000-0000000000c1"
        let (device, confirmed, ghost) = (Party("device"), Party("confirmed"), Party("ghost"))
        // The confirmed member created the circle; the server holds a key of its own.
        let creation = try confirmed.crypto.prepareCircleCreation()
        try confirmed.crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        let serverKey = try ghost.crypto.prepareCircleCreation()
        try ghost.crypto.finalizeCircleCreation(tempCircleId: serverKey.tempCircleId, realCircleId: circle)

        // Legacy pin: earlier builds pinned everyone listed; the app pins the
        // confirmed only.
        _ = try device.crypto.pinMemberKeys(circleId: circle, userId: ghost.userId,
                                            sharingPubkeyHex: ghost.sharing, signingPubkeyHex: ghost.signing)
        _ = try device.crypto.pinMemberKeys(circleId: circle, userId: confirmed.userId,
                                            sharingPubkeyHex: confirmed.sharing, signingPubkeyHex: confirmed.signing)
        let kept = Track.CircleManager.pinsKept(
            roster: [device.userId, confirmed.userId, ghost.userId],
            verdicts: [device.userId: .confirmed(.ownAction), confirmed.userId: .confirmed(.statement), ghost.userId: .legacy],
            selfUserId: device.userId)
        XCTAssertEqual(try device.crypto.retainMemberPins(circleId: circle, memberUserIds: Array(kept)), 1,
                       "the view-pin is retired")

        func wrap(from sender: Party) throws -> MemberKeyBundle {
            try sender.crypto.wrapCircleKeyForMemberFull(
                circleId: circle, memberPublicKeyHex: device.sharing, senderUserId: sender.userId,
                recipientUserId: device.userId, recipientSigningPubkeyHex: device.signing)
        }
        let forged = try wrap(from: ghost)
        XCTAssertThrowsError(try device.crypto.storeCircleKey(
            circleId: circle, encryptedKey: forged.encryptedCircleKey.nonce + forged.encryptedCircleKey.ciphertext,
            senderPublicKey: forged.ephemeralPublicKey, keyVersion: 1, senderUserId: ghost.userId,
            recipientUserId: device.userId, wrapSignatureHex: forged.wrapSignature,
            senderSigningPubkeyHex: ghost.signing), "a sender this device does not pin, in a circle it pins members of")
        XCTAssertThrowsError(try device.crypto.storeFirstCircleKey(
            circleId: circle, encryptedKey: forged.encryptedCircleKey.nonce + forged.encryptedCircleKey.ciphertext,
            senderPublicKey: forged.ephemeralPublicKey, keyVersion: 1, senderUserId: ghost.userId,
            recipientUserId: device.userId, wrapSignatureHex: forged.wrapSignature,
            confirmedSenderSigningPubkeyHex: confirmed.signing, sealedCircleName: nil),
                             "not signed by the confirmed member")
        XCTAssertFalse(device.crypto.hasCircleKey(circleId: circle))

        let real = try wrap(from: confirmed)
        try device.crypto.storeFirstCircleKey(
            circleId: circle, encryptedKey: real.encryptedCircleKey.nonce + real.encryptedCircleKey.ciphertext,
            senderPublicKey: real.ephemeralPublicKey, keyVersion: 1, senderUserId: confirmed.userId,
            recipientUserId: device.userId, wrapSignatureHex: real.wrapSignature,
            confirmedSenderSigningPubkeyHex: try XCTUnwrap(device.crypto.pinnedSigningKey(circleId: circle, userId: confirmed.userId)),
            sealedCircleName: nil)
        XCTAssertTrue(device.crypto.hasCircleKey(circleId: circle))
    }

    // MARK: - The backfill

    /// The backfill signs for SEED members — with no wrap evidence, the seed
    /// is the evidence — and otherwise only re-vouches a member whose
    /// statement no longer verifies when a confirmed member handed them their
    /// copy. Never anyone taken on first use, chosen here or receive-only.
    func testTheBackfillSignsOnlyForSeedMembers() {
        func due(_ origin: ApprovalOrigin, holds: Bool = false, fails: Bool = false, vouched: Bool = false) -> Bool {
            Track.CircleManager.backfillDue(origin: origin, statementHolds: holds, statementsFail: fails, copyVouched: vouched)
        }
        XCTAssertTrue(due(.preRound2Seed), "a seed member with no statement: the seed is the evidence")
        XCTAssertTrue(due(.preRound2Seed, fails: true), "their only statement's signer left")
        XCTAssertFalse(due(.preRound2Seed, holds: true), "every device can check them already")
        XCTAssertTrue(due(.statement, fails: true, vouched: true), "signed under a signer's previous key")
        XCTAssertFalse(due(.statement, fails: true), "a re-vouch still needs a copy from someone confirmed here")
        XCTAssertFalse(due(.statement, holds: true, vouched: true))
        for origin: ApprovalOrigin in [.ownAction, .kind2, .ownKind2, .anchor] {
            XCTAssertFalse(due(origin, fails: true, vouched: true), "\(origin)")
        }
    }

    /// The handed-over-copy evidence, through the real SDK: a stored copy
    /// counts when a member confirmed here signed it, under EITHER wrap domain
    /// — a delivery (`circle_member_wrap`) or a refresh
    /// (`rotation_member_wrap`) — and never when the member signed it for
    /// themselves. Model: the Android app's
    /// `CircleRepository.handedOverByConfirmed`.
    func testAStoredCopyCountsUnderEitherDomainButNeverWhenSelfSigned() throws {
        let (owner, member, stranger) = (Party("owner"), Party("member"), Party("stranger"))
        let (ephemeral, nonce, ciphertext) = (String(repeating: "ab", count: 32), String(repeating: "cd", count: 24),
                                              String(repeating: "ef", count: 48))
        func row(signedBy signer: Party, domain: String) throws -> CircleMemberResponse {
            let signature = try signer.crypto.signWrap(params: SignWrapParams(
                domain: domain, senderUserId: signer.userId, recipientUserId: member.userId, circleId: circle,
                placeId: "", keyVersion: 3, ephemeralPubkeyHex: ephemeral, wrapNonceHex: nonce,
                wrapCiphertextHex: ciphertext))
            let json: [String: Any] = [
                "user_id": member.userId, "role": "member", "status": "active",
                "encrypted_circle_key": ["nonce": nonce, "ciphertext": ciphertext], "ephemeral_public_key": ephemeral,
                "can_see_history": true, "can_see_realtime": true, "joined_day_bucket": 20_000, "key_version": 3,
                "wrap_signer_user_id": signer.userId, "wrap_signature": signature,
            ]
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(CircleMemberResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        // Confirmed here: the owner and the member themselves (their pins); not the stranger.
        let keys = [owner.userId: owner.signing, member.userId: member.signing]
        func vouched(_ row: CircleMemberResponse) -> Bool {
            Track.CircleManager.copyIsVouched(
                row, circleId: circle, me: UUID().uuidString.lowercased(), signerKey: { keys[$0] },
                verify: { key, signature, params in
                    (try? owner.crypto.verifyWrap(signingPubkeyHex: key, signatureHex: signature, params: params)) == true
                })
        }
        let delivery = Track.CircleManager.memberWrapDomain, refresh = Track.CircleManager.rotationMemberWrapDomain
        XCTAssertEqual(refresh, "pingolin.sig.v1.rotation_member_wrap")
        XCTAssertTrue(vouched(try row(signedBy: owner, domain: refresh)), "a refresh's copy from a confirmed member counts")
        XCTAssertTrue(vouched(try row(signedBy: owner, domain: delivery)), "a delivery's copy counts")
        XCTAssertFalse(vouched(try row(signedBy: member, domain: delivery)), "their own copy proves nobody vouched")
        XCTAssertFalse(vouched(try row(signedBy: member, domain: refresh)))
        XCTAssertFalse(vouched(try row(signedBy: stranger, domain: delivery)), "a signer not confirmed here")
        XCTAssertFalse(vouched(try row(signedBy: owner, domain: "pingolin.sig.v1.place_wrap")), "another domain")
    }

    /// Through the real SDK: the pins this device holds, grouped by circle,
    /// from `exportMemberPins` — circle pins only; an identity pin is not one.
    func testTheSeedReadsTheCirclePinsThisDeviceHolds() throws {
        let device = Party("device")
        let (a, b, c) = (Party("a"), Party("b"), Party("c"))
        let circleA = "c1000000-0000-4000-8000-00000000000a", circleB = "c1000000-0000-4000-8000-00000000000b"
        for (circleId, member) in [(circleA, a), (circleA, b), (circleB, c)] {
            _ = try device.crypto.pinMemberKeys(circleId: circleId, userId: member.userId,
                                                sharingPubkeyHex: member.sharing, signingPubkeyHex: member.signing)
        }
        // b leaves circle A: their circle pin retires, their identity pin stays.
        _ = try device.crypto.retainMemberPins(circleId: circleA, memberUserIds: [device.userId, a.userId])
        let export = try device.crypto.exportMemberPins(ownerUserId: device.userId)
        let pins = try XCTUnwrap(Track.CircleManager.circlePins(fromExport: export))
        XCTAssertEqual(pins, [circleA: [a.userId], circleB: [c.userId]])
        XCTAssertNil(Track.CircleManager.circlePins(fromExport: "not json"))
    }

    /// After the owner's backfill, a brand-new device of a legacy member — no
    /// record, no pins — anchors on the admission about itself and confirms
    /// everyone the owner admitted.
    func testANewDeviceOfALegacyMemberAnchorsOnItsAdmission() throws {
        let (me, owner, other) = (Party("me"), Party("owner"), Party("other"))
        let checker = Checker(own: me.signing)
        let aboutMe = try statement(by: owner, .admission, about: me)
        let aboutOther = try statement(by: owner, .admission, about: other)
        let result = evaluate(me, [row(me, admissions: [aboutMe]), row(owner), row(other, admissions: [aboutOther])],
                              CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[owner.userId], .confirmed(.statement))
        XCTAssertEqual(result.verdicts[other.userId], .confirmed(.statement))
        XCTAssertFalse(result.selfIsReceiveOnly)
    }

    // MARK: - Inviting a known account whose identity changed

    /// An invitation SIGNS the looked-up keys for every other member's app, so
    /// keys other than this device's pin for that account — either key — stop
    /// the invitation until this device's user has compared their number.
    func testAnInviteeWhoseKeysChangedIsAskedAboutFirst() throws {
        let changed = Track.CircleManager.inviteeKeysChanged
        XCTAssertFalse(changed("aa", "bb", (nil, nil)), "someone this device never pinned: first contact")
        XCTAssertFalse(changed("AA", "bb", ("aa", "BB")), "the same keys, any case")
        XCTAssertTrue(changed("cc", "bb", ("aa", "bb")), "a new sharing key")
        XCTAssertTrue(changed("aa", "dd", ("aa", "bb")), "a new signing key alone counts too")
        XCTAssertEqual(InviteeChange.title(email: "sam@example.com"), "Is this really sam@example.com?")
        XCTAssertEqual(InviteeChange.body(email: "sam@example.com", number: "12345 67890"),
                       "sam@example.com reset their password, so Pingolin can't tell on its own that it's still them. If you're not sure, check with them another way first.\n\nTheir number: 12345 67890")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        let ask = try XCTUnwrap(circles.range(of: "throw CircleError.inviteeChanged(InviteeChange("))
        let sign = try XCTUnwrap(circles.range(of: "let statement = try cryptoManager.signInvitationToAccount("))
        XCTAssertLessThan(ask.lowerBound, sign.lowerBound, "asked before anything is signed or sent")
    }

    // MARK: - At accept

    func testAnInvitationMustNameThisAccount() throws {
        let (me, inviter) = (Party("me"), Party("inviter"))
        let checker = Checker(own: me.signing)
        func names(_ record: SignedStatementRecord?, circle circleId: String? = nil) -> Bool? {
            MembershipConfirmation.invitationNamesMe(statementHex: record?.statementHex, circleId: circleId ?? circle,
                                                     me: me.me, checker: checker)
        }
        XCTAssertNil(names(nil), "unsigned: nothing to check")
        XCTAssertEqual(names(try statement(by: inviter, .invitationToAccount, about: me)), true)
        XCTAssertEqual(names(try statement(by: inviter, .invitationToAccount, about: me,
                                           binding: (Party("x").sharing, me.signing))), false, "other keys")
        XCTAssertEqual(names(try statement(by: inviter, .invitationToAccount, about: Party("other"))), false)
        XCTAssertEqual(names(try statement(by: inviter, .invitationToEmail, about: me)), true)
        XCTAssertEqual(names(try statement(by: inviter, .invitationToEmail, email: "nope@example.com")), false)
        XCTAssertEqual(names(try statement(by: inviter, .admission, about: me)), false)
        XCTAssertEqual(names(try statement(by: inviter, .invitationToAccount, about: me),
                             circle: "c0ffee00-0000-4000-8000-000000000002"), false, "another circle")
        // What happens, never "ask them to invite you again".
        XCTAssertEqual(InvitesManager.beingRenewed(inviter: "Ana"),
                       "This invitation is being renewed. It will work as soon as Ana confirms it's you.")
        XCTAssertEqual(InvitesManager.beingRenewed(inviter: nil),
                       "This invitation is being renewed. It will work as soon as the circle confirms it's you.")
    }

    /// Only an invitation to THIS account naming keys it no longer has is
    /// renewed. An address invitation never is, and one for another account
    /// or circle cannot be: those go nowhere, with one line and no report.
    func testOnlyThisAccountsOutdatedKeysAreRenewed() throws {
        let (me, inviter) = (Party("me"), Party("inviter"))
        let checker = Checker(own: me.signing)
        func mismatch(_ record: SignedStatementRecord?, circle circleId: String? = nil)
            -> MembershipConfirmation.InvitationMismatch? {
            MembershipConfirmation.invitationMismatch(statementHex: record?.statementHex, circleId: circleId ?? circle,
                                                      me: me.me, checker: checker)
        }
        XCTAssertNil(mismatch(nil), "unsigned: left to the server")
        XCTAssertNil(mismatch(try statement(by: inviter, .invitationToAccount, about: me)))
        XCTAssertNil(mismatch(try statement(by: inviter, .invitationToEmail, about: me)))
        XCTAssertEqual(mismatch(try statement(by: inviter, .invitationToAccount, about: me,
                                              binding: (Party("x").sharing, me.signing))), .outdatedKeys,
                       "this account, keys from before a reset: renewed")
        XCTAssertEqual(mismatch(try statement(by: inviter, .invitationToAccount, about: Party("other"))), .otherAccount)
        XCTAssertEqual(mismatch(try statement(by: inviter, .invitationToEmail, email: "nope@example.com")),
                       .otherAddress, "an address invitation is never renewed")
        XCTAssertEqual(mismatch(try statement(by: inviter, .admission, about: me)), .otherAccount)
        XCTAssertEqual(mismatch(try statement(by: inviter, .invitationToAccount, about: me,
                                              binding: (Party("x").sharing, me.signing)),
                                circle: "c0ffee00-0000-4000-8000-000000000002"), .otherAccount, "another circle")

        // The accept's invite_out_of_date waits for a renewal only for an account invitation to this user.
        func account(_ record: SignedStatementRecord?) -> Bool {
            MembershipConfirmation.isAccountInvitation(statementHex: record?.statementHex, circleId: circle,
                                                       userId: me.me.userId, checker: checker)
        }
        XCTAssertTrue(account(try statement(by: inviter, .invitationToAccount, about: me,
                                            binding: (Party("x").sharing, me.signing))))
        XCTAssertFalse(account(try statement(by: inviter, .invitationToEmail, about: me)), "an address invitation")
        XCTAssertFalse(account(try statement(by: inviter, .invitationToAccount, about: Party("other"))))
        XCTAssertFalse(account(nil), "unsigned")

        XCTAssertEqual(InvitesManager.refusal(for: .otherAddress), "This invitation was sent to a different address.")
        XCTAssertEqual(InvitesManager.refusal(for: .otherAccount), "This invitation was sent to a different account.")
        XCTAssertNil(InvitesManager.refusal(for: .outdatedKeys), "renewed, not refused")
        XCTAssertNil(InvitesManager.refusal(for: nil))
    }

    // MARK: - Wake-ups

    /// Both wake-ups a delivery may hang on refresh the circles — the member
    /// load is what delivers and what takes a delivered copy.
    func testWakeUpsRefreshTheCircles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let push = try String(contentsOf: root.appendingPathComponent("App/Managers/PushNotificationManager.swift"),
                              encoding: .utf8)
        let check = try XCTUnwrap(push.range(of: "case \"alerts_check\":"))
        let wake = try XCTUnwrap(push.range(of: "case \"wake_location\":"))
        let refresh = try XCTUnwrap(push.range(of: "try? await CircleManager.shared.loadCircles(light: true)",
                                               range: check.upperBound..<wake.lowerBound),
                                    "alerts_check refreshes the circles")
        XCTAssertNotNil(push.range(of: "await MonitoringManager.shared.evaluateForAlertsCheck()",
                                   range: refresh.upperBound..<wake.lowerBound))
        XCTAssertTrue(push.contains("try await CircleManager.shared.loadCircles(light: true)"), "member_joined too")
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertTrue(circles.contains("Task { await deliverToConfirmedMembers(circleId: circleId) }"),
                      "every member load ends in delivery")
    }

    // MARK: - The SDK contract

    /// Format 2's V1 vector reads back through the binding: kind 1, at_version 7,
    /// and a valid signature under the vector's key (the domain is the SDK's).
    func testTheSDKVectorReadsBack() throws {
        let sdk = CryptoManager()
        let v1 = "0201111111112222433384445555555555550f1e2d3c4b5a4987a6b5c4d3e2f1a0b966666666777748889999aaaaaaaaaaaa0068b46a0000000080a2bd6a0000000007000000bbbbbbbbcccc4ddd8eeeffffffffffff404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f"
        let signature = "2e344b8660536b8a820b187afb5a605da203e3515931c7f98d8891e6ba4d4f3fec2b9c2cb826b86ebb2d297d4570d9cd3daa791855bfa16bc96e6461164de804"
        let parsed = try sdk.parseMembershipStatement(statementHex: v1)
        XCTAssertEqual(parsed.kind, .invitationToAccount)
        XCTAssertEqual(parsed.atVersion, 7)
        XCTAssertEqual(parsed.subjectUserId, "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
        XCTAssertTrue(try sdk.verifyMembershipStatement(
            statementHex: v1, signatureHex: signature,
            signerSigningPublicKeyHex: "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"))
    }

    // MARK: - A self-statement changes no verdict

    private func keys(_ party: Party) -> MemberKeyPair {
        MemberKeyPair(sharingKeyHex: party.sharing, signingKeyHex: party.signing)
    }

    /// A member's own admission, signed by that member: alone it confirms
    /// nobody, pinned or not, and pins nothing; a pin alone confirms nobody,
    /// so the record row the SDK is given is not confirmed either.
    func testAMembersOwnAdmissionAloneConfirmsNobody() throws {
        let (me, member) = (Party("me"), Party("member"))
        let checker = Checker(own: me.signing)
        let own = try statement(by: member, .admission, about: member)
        var result = evaluate(me, [row(me), row(member, admissions: [own])], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[member.userId], .unconfirmable, "no pin: never confirmed by it")
        XCTAssertNil(result.newlyConfirmed[member.userId])
        XCTAssertNil(checker.pins[member.userId], "it pins nothing")

        checker.pin(member)
        result = evaluate(me, [row(me), row(member, admissions: [own])], CircleApprovalRecord(), checker)
        XCTAssertEqual(result.verdicts[member.userId], .unconfirmable, "a pin with it: still not confirmed")
        XCTAssertFalse(result.confirmed.contains(member.userId))
        XCTAssertNil(result.newlyConfirmed[member.userId])
        let rows = RecordMembers.rows(
            me: me.userId, myKeys: keys(me), candidates: [member.userId: row(member, admissions: [own])], roles: [:],
            complete: true, verdicts: result.verdicts, receiveOnlyKeys: [:], pinned: { _ in self.keys(member) },
            chosen: { _ in false })
        XCTAssertEqual(rows.first { $0.userId == member.userId }?.confirmed, false,
                       "a pin alone never makes a member confirmed")
    }

    /// A member confirmed on another basis stays confirmed, with the PINNED keys
    /// in their record row, whatever their own admission binds: the pin's keys
    /// or others (their reset).
    func testAMembersOwnAdmissionChangesNoVerdict() throws {
        let (me, owner, member) = (Party("me"), Party("owner"), Party("member"))
        let reset = Party("member-after-reset")
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        checker.pin(member)
        let invitation = try statement(by: owner, .invitationToAccount, about: member)
        let baseline = evaluate(me, [row(me), row(owner), row(member, invitation: invitation)],
                                record([(owner, .preRound2Seed)]), checker)
        XCTAssertEqual(baseline.verdicts[member.userId], .confirmed(.statement))
        for (label, bound, signer) in [("the pin's keys", member, member), ("other keys", reset, reset)] {
            let own = try statement(by: signer, as: member.userId, .admission, about: member,
                                    binding: (bound.sharing, bound.signing))
            let result = evaluate(me, [row(me), row(owner), row(member, invitation: invitation, admissions: [own])],
                                  record([(owner, .preRound2Seed)]), checker)
            XCTAssertEqual(result.verdicts[member.userId], baseline.verdicts[member.userId], label)
            XCTAssertEqual(result.evidence[member.userId], baseline.evidence[member.userId],
                           "no delivery rests on it: \(label)")
            XCTAssertEqual(result.statementHolds, baseline.statementHolds, label)
            XCTAssertEqual(result.statementsFail, baseline.statementsFail, label)
            XCTAssertEqual(checker.pins[member.userId]?.sharing, member.sharing, "the pin did not move: \(label)")
            let (inRow, source) = RecordMembers.keys(
                isMe: false, myKeys: keys(me), verdict: result.verdicts[member.userId], listed: keys(reset),
                receiveOnly: nil, pinned: keys(member))
            XCTAssertEqual(inRow, keys(member), "the pinned keys in their row: \(label)")
            XCTAssertEqual(source, .pinned)
        }
    }

    /// The roster's keys differing from the pin (their reset) is what asks and
    /// blocks, with or without their own admission of the new keys: the
    /// send-side gate gives them nothing, and the pin stays.
    func testARosterThatDiffersFromThePinIsBlockedWithOrWithoutTheirOwnAdmission() throws {
        let (me, owner, member) = (Party("me"), Party("owner"), Party("member"))
        let reset = Party("member-after-reset")
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        checker.pin(member)  // the keys from before their reset
        let invitation = try statement(by: owner, .invitationToAccount, about: member)
        let own = try statement(by: reset, as: member.userId, .admission, about: member,
                                binding: (reset.sharing, reset.signing))
        let gate = AccessHandover.readOnlyPinGate(
            me: me.userId, circleId: circle,
            pinnedSharing: { checker.pinnedSharingKey(circleId: $0, userId: $1) },
            pinnedSigning: { checker.pinnedSigningKey(circleId: $0, userId: $1) })
        var verdicts: [MembershipVerdict?] = []
        for admissions in [[], [own]] {
            let listed = MembershipCandidate(userId: member.userId, sharingKeyHex: reset.sharing, signingKeyHex: reset.signing,
                                             invitation: invitation, admissions: admissions, keyVersion: 5,
                                             accessRequested: false)
            let result = evaluate(me, [row(me), row(owner), listed], record([(owner, .preRound2Seed)]), checker)
            verdicts.append(result.verdicts[member.userId])
            let blocked = AccessHandover.sendSideGate(
                me: me.userId, result: result, record: CircleApprovalRecord(),
                members: [(member.userId, "member", reset.sharing, reset.signing)], pinGate: gate)
            XCTAssertEqual(blocked, [member.userId], "asked about, never handed the circle: \(admissions.count)")
            XCTAssertEqual(checker.pins[member.userId]?.sharing, member.sharing, "the pin did not move")
        }
        XCTAssertEqual(verdicts[0], verdicts[1], "their own admission changes nothing")
    }

    // MARK: - Statement ids on every pass

    /// A member this device's record already confirms (an approval an earlier
    /// build made, with no ids kept) gets the ids of the statements that
    /// confirm them under a CURRENT key on this pass; never a previous-key one.
    func testTheCurrentKeyStatementsOfAConfirmedMemberAreCollectedOnEveryPass() throws {
        let (me, owner, member) = (Party("me"), Party("owner"), Party("member"))
        let before = Party("me-before-reset")
        let checker = Checker(own: me.signing)
        checker.pin(owner)
        checker.pin(member)
        checker.previousSigning = [before.signing]
        let (current, beforeReset) = ("c0ffee00-aaaa-4bbb-8ccc-00000000000a", "c0ffee00-aaaa-4bbb-8ccc-00000000000b")
        let invitation = try statement(by: owner, .invitationToAccount, about: member, id: current)
        let mineBefore = try statement(by: before, as: me.userId, .admission, about: member, id: beforeReset)
        let result = evaluate(me, [row(me), row(owner), row(member, invitation: invitation, admissions: [mineBefore])],
                              record([(owner, .preRound2Seed), (member, .statement)]), checker)
        XCTAssertEqual(result.verdicts[member.userId], .confirmed(.statement))
        XCTAssertNil(result.newlyConfirmed[member.userId], "confirmed by the record, not in this pass")
        XCTAssertEqual(result.currentKeyStatementIds[member.userId], [current],
                       "the current-key invitation, never the admission signed before the reset")
    }

    /// The record keeps them, merged, only for a member approved by a
    /// statement or by this device's person; never a seed's or a receive-only one.
    func testTheRecordKeepsThemOnlyForAStatementOrAChoice() {
        var record = CircleApprovalRecord()
        record.entries = ["s": .statement, "o": .ownAction, "seed": .preRound2Seed, "k2": .kind2]
        record.statementIds = ["s": ["old"]]
        for id in ["s", "o", "seed", "k2", "nobody"] {
            record.noteStatementIds(userId: id, ids: ["new"])
        }
        XCTAssertEqual(record.statementIds["s"], ["new", "old"], "merged, never replaced")
        XCTAssertEqual(record.statementIds["o"], ["new"])
        XCTAssertNil(record.statementIds["seed"])
        XCTAssertNil(record.statementIds["k2"])
        XCTAssertNil(record.statementIds["nobody"])
        let unchanged = record
        record.noteStatementIds(userId: "s", ids: [])
        XCTAssertEqual(record, unchanged)
    }

    func testTheRosterPassKeepsThemOnEveryPass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let handover = try String(contentsOf: root.appendingPathComponent("App/Managers/AccessHandover.swift"), encoding: .utf8)
        let approve = try XCTUnwrap(handover.range(of: "for (userId, confirmation) in result.newlyConfirmed where !confirmation.previousKeyOnly {"))
        let note = try XCTUnwrap(handover.range(of: "        for (userId, ids) in result.currentKeyStatementIds {\n"
                                                    + "            record.noteStatementIds(userId: userId, ids: ids)\n        }\n"))
        XCTAssertLessThan(approve.lowerBound, note.lowerBound)
    }
}
