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

/// The late joiner's one question: its cases, who is asked, never about
/// someone ejected, the shared cap, once per invitation, and its approved
/// lines.
final class LateJoinerTests: XCTestCase {
    private let owner = "a0a0a0a0-0000-0000-0000-000000000001"
    private let admin = "a0a0a0a0-0000-0000-0000-000000000002"
    private let plain = "a0a0a0a0-0000-0000-0000-000000000003"
    private let joiner = "b0b0b0b0-0000-0000-0000-000000000001"
    private let now: Int64 = 1_800_000_000

    private func invitation(_ id: String = "inv-1", by signer: String, to person: String? = nil,
                            at issuedAt: Int64? = nil) -> LateJoiner.Invitation {
        LateJoiner.Invitation(statementId: id, signerUserId: signer, person: person ?? joiner, issuedAt: issuedAt ?? now)
    }

    private func standing(eligible: Bool = false, expired: Bool = false, notChainAdmin: Bool = false,
                          email: Bool = false, removed: Bool = false) -> LateJoiner.Standing {
        LateJoiner.Standing(eligible: eligible, invitationExpired: expired, signerNotChainAdmin: notChainAdmin,
                            emailInvitationWithoutSignedId: email, removedByOwnerOrAdmin: removed)
    }

    private func ask(me: String, _ myRole: CircleRole?, _ invitation: LateJoiner.Invitation,
                     _ standing: LateJoiner.Standing, signerRole: CircleRole?, signerName: String? = "Pat",
                     answered: [LateJoiner.Invitation] = [], asked: [LateJoiner.Invitation] = [],
                     pending: Int = 0) -> LateJoiner.Ask? {
        LateJoiner.ask(me: me, myChainRole: myRole, invitation: invitation, standing: standing,
                       signerChainRole: signerRole, signerName: signerName, answered: answered, pending: asked,
                       pendingCapped: pending)
    }

    // MARK: - The cases and who is asked

    /// The first case: their invitation ran out, whoever signed it. The
    /// signer is asked when it's an owner or admin in the chain (no line about
    /// the inviter, no cap); otherwise the chain's owner, with "{inviter}
    /// invited them." and the cap.
    func testARanOutInvitationIsAskedOfItsSignerOrTheChainsOwner() throws {
        let own = try XCTUnwrap(ask(me: admin, .admin, invitation(by: admin), standing(expired: true), signerRole: .admin))
        XCTAssertEqual(own.kind, .ranOut)
        XCTAssertNil(own.inviterLine)
        XCTAssertFalse(own.capped)
        XCTAssertEqual(LateJoiner.body(own), "Their invitation ran out before anyone's phone could hand the circle over.")
        XCTAssertNil(ask(me: owner, .owner, invitation(by: admin), standing(expired: true), signerRole: .admin),
                     "a chain admin's own invitation: the admin is asked, not the owner")

        let byPlain = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain),
                                        standing(expired: true, notChainAdmin: true), signerRole: .member))
        XCTAssertEqual(byPlain.kind, .ranOut)
        XCTAssertTrue(byPlain.capped)
        XCTAssertEqual(LateJoiner.body(byPlain),
                       "Their invitation ran out before anyone's phone could hand the circle over.\nPat invited them.")
        XCTAssertNil(ask(me: plain, .member, invitation(by: plain), standing(expired: true, notChainAdmin: true),
                         signerRole: .member), "a plain member is never asked, even about its own invitation")
        XCTAssertNil(ask(me: admin, .admin, invitation(by: plain), standing(expired: true, notChainAdmin: true),
                         signerRole: .member), "an admin who didn't sign it isn't asked")
    }

    /// The second case, at once: the invitation hasn't run out, but its signer
    /// isn't an owner or admin in the chain (a promotion not recorded yet):
    /// the chain's owner is asked, and the body is "{inviter} invited them."
    func testAnInviterNotYetAdminInTheChainIsNamedToTheOwner() throws {
        let asked = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain), standing(notChainAdmin: true),
                                      signerRole: .member))
        XCTAssertEqual(asked.kind, .inviterNotChainAdmin)
        XCTAssertEqual(LateJoiner.body(asked), "Pat invited them.")
        XCTAssertTrue(asked.capped)
        // An inviter no longer on this device's list isn't named: no new words.
        let unnamed = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain), standing(expired: true, notChainAdmin: true),
                                        signerRole: .member, signerName: nil))
        XCTAssertEqual(LateJoiner.body(unnamed), "Their invitation ran out before anyone's phone could hand the circle over.")
    }

    /// The third case, at once: an invitation to an email address. The body is
    /// "{inviter} invited them." when another account invited them, and
    /// nothing when this account did; never the ran-out line.
    func testAnEmailInvitationIsAskedWithItsInviterLineOrNone() throws {
        let other = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain, to: "sam@example.com"),
                                      standing(email: true), signerRole: .member))
        XCTAssertEqual(other.kind, .emailInvitation)
        XCTAssertEqual(LateJoiner.body(other), "Pat invited them.")
        let own = try XCTUnwrap(ask(me: owner, .owner, invitation(by: owner, to: "sam@example.com"),
                                    standing(email: true), signerRole: .owner))
        XCTAssertEqual(own.kind, .emailInvitation)
        XCTAssertEqual(LateJoiner.body(own), "", "this account's own invitation: the title and the buttons alone")
        XCTAssertFalse(LateJoiner.body(own).contains("ran out"))
    }

    /// When the eligibility check sets more than one flag, a fixed order
    /// decides (as in the Android app): it ran out, then its signer isn't
    /// an owner or admin in the chain, then it went to an email address.
    func testSeveralFlagsTakeAFixedOrder() throws {
        let ranOutAndEmail = try XCTUnwrap(ask(me: owner, .owner, invitation(by: owner, to: "sam@example.com"),
                                               standing(expired: true, email: true), signerRole: .owner))
        XCTAssertEqual(ranOutAndEmail.kind, .ranOut)
        XCTAssertEqual(LateJoiner.body(ranOutAndEmail),
                       "Their invitation ran out before anyone's phone could hand the circle over.")
        let notAdminAndEmail = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain, to: "sam@example.com"),
                                                 standing(notChainAdmin: true, email: true), signerRole: .member))
        XCTAssertEqual(notAdminAndEmail.kind, .inviterNotChainAdmin)
        let all = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain, to: "sam@example.com"),
                                    standing(expired: true, notChainAdmin: true, email: true), signerRole: .member))
        XCTAssertEqual(all.kind, .ranOut)
    }

    /// Nothing is asked about a member the eligibility check lets in,
    /// or one with none of the three reasons.
    func testNothingIsAskedAboutAnEligibleMemberOrOneWithoutAReason() {
        XCTAssertNil(ask(me: owner, .owner, invitation(by: plain), standing(eligible: true, expired: true, notChainAdmin: true),
                         signerRole: .member))
        XCTAssertNil(ask(me: owner, .owner, invitation(by: owner), standing(), signerRole: .owner))
    }

    // MARK: - Never about the ejected, once per invitation, the
    // cap

    /// When the signer isn't an owner or admin in the chain, never about
    /// someone an owner or admin ejected. An owner's or admin's own
    /// invitation of them is asked about when it runs out.
    func testNeverAboutSomeoneEjectedOnAPlainMembersInvitation() {
        XCTAssertNil(ask(me: owner, .owner, invitation(by: plain), standing(expired: true, notChainAdmin: true, removed: true),
                         signerRole: .member))
        XCTAssertNil(ask(me: owner, .owner, invitation(by: plain), standing(notChainAdmin: true, removed: true),
                         signerRole: .member))
        XCTAssertNotNil(ask(me: owner, .owner, invitation(by: owner), standing(expired: true, removed: true),
                            signerRole: .owner))
    }

    /// One invitation: spares of a queued invitation (new ids, issued within
    /// 8 days) are the same one: once "Not now" was answered, none is asked,
    /// in either case. The same signer's invitation 8 days on, or another
    /// signer's, is a new one; a renewal keeps its id.
    func testOneQuestionPerInvitationNotPerStatement() {
        let answered = [invitation("inv-1", by: plain, at: now)]
        func asked(_ invitation: LateJoiner.Invitation, _ standing: LateJoiner.Standing) -> Bool {
            ask(me: owner, .owner, invitation, standing, signerRole: .member, answered: answered) != nil
        }
        let second = standing(notChainAdmin: true)
        let first = standing(expired: true, notChainAdmin: true)
        XCTAssertFalse(asked(invitation("spare-1", by: plain, at: now + 3_600), second))
        XCTAssertFalse(asked(invitation("spare-2", by: plain, at: now + 6 * 86_400), first),
                       "\"Not now\" in the second case: no first-case question after it runs out")
        XCTAssertFalse(asked(invitation("spare-3", by: plain.uppercased(), at: now - 7 * 86_400), second))
        XCTAssertFalse(asked(invitation("INV-1", by: plain, at: now + 30 * 86_400), second), "a renewal keeps its id")
        XCTAssertTrue(asked(invitation("new", by: plain, at: now + 8 * 86_400), second), "8 days on: a new invitation")
        XCTAssertTrue(asked(invitation("other", by: admin, at: now), second), "another signer's")
        XCTAssertTrue(asked(invitation("someone else", by: plain, to: "c0c0c0c0-0000-0000-0000-000000000001", at: now), second))
    }

    /// One question per invitation, pending ones included: an email
    /// invitation binds no user id, so a server can attach one to several
    /// members' rows. While a question about it waits for one member, no
    /// other is asked about it; another invitation still is.
    func testOneEmailInvitationOnTwoRowsAsksOnce() throws {
        let email = invitation("email-1", by: owner, to: "sam@example.com")
        let first = try XCTUnwrap(ask(me: owner, .owner, email, standing(expired: true, email: true), signerRole: .owner))
        XCTAssertNil(ask(me: owner, .owner, email, standing(expired: true, email: true), signerRole: .owner,
                         asked: [first.invitation]), "the same invitation on another member's row")
        XCTAssertNotNil(ask(me: owner, .owner, invitation("email-2", by: owner, to: "kim@example.com"),
                            standing(expired: true, email: true), signerRole: .owner, asked: [first.invitation]),
                        "another invitation is asked")
        // A pass finds every question first, and one invitation is asked once
        // there too (`LateJoiner.chosen`).
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("signerName: signer?.displayName, answered: answered, pendingCapped: 0,"))
        XCTAssertTrue(manager.contains("let asked = Set(LateJoiner.chosen(found.map { ($0.member, $0.ask) },"))
    }

    /// A question closed because its member got in elsewhere is answered: the
    /// same invitation on another member's row is never asked about again, in
    /// that pass or any later one.
    func testAQuestionClosedElsewhereKeepsItsInvitationAnswered() throws {
        let email = invitation("email-1", by: owner, to: "sam@example.com")
        let closed = try XCTUnwrap(ask(me: owner, .owner, email, standing(expired: true, email: true), signerRole: .owner))
        XCTAssertNil(ask(me: owner, .owner, email, standing(expired: true, email: true), signerRole: .owner,
                         answered: [closed.invitation]), "the same invitation on a second row after the close")
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                    for request in queued where closed.contains(request.userId) {
                        approvals.askAgain(request)
                        KeyDeliveryApprovals.keepLateJoinerAnswer(request)
                    }
                    let answered = RefreshLedger.shared.circle(account: me, circleId: circleId).lateJoinerAnswered
            """), "kept, and read back after the close")
    }

    /// Past the cap, a question already raised keeps its place, then the
    /// oldest invitations (as in the Android app): not the rows' order. A
    /// chain owner's or admin's own invitation is always asked; one
    /// invitation is asked once, the raised row keeping it; questions raised
    /// outside the pass hold their invitations and their places.
    func testAPassAsksTheRaisedFirstThenTheOldest() throws {
        func capped(_ n: Int, at offset: Int64) throws -> (member: String, ask: LateJoiner.Ask) {
            (member: "m\(n)", ask: try XCTUnwrap(ask(me: owner, .owner, invitation("b\(n)", by: plain, to: "m\(n)", at: now + offset),
                                                     standing(notChainAdmin: true), signerRole: .member)))
        }
        let own = (member: "m6", ask: try XCTUnwrap(ask(me: owner, .owner, invitation("b6", by: owner, to: "m6", at: now + 60),
                                                        standing(expired: true), signerRole: .owner)))
        let found = [try capped(1, at: 50), try capped(2, at: 10), try capped(3, at: 40), try capped(4, at: 20),
                     try capped(5, at: 30), own]
        XCTAssertEqual(Set(LateJoiner.chosen(found, raised: ["m3", "m5"])), ["m6", "m5", "m3", "m2"])
        XCTAssertEqual(Set(LateJoiner.chosen(found, raised: [])), ["m6", "m2", "m4", "m5"], "none raised: the oldest")
        XCTAssertEqual(Set(LateJoiner.chosen(found, raised: [], pendingCapped: 2)), ["m6", "m2"],
                       "two raised outside the pass keep their places")
        // One invitation, asked once: the raised row keeps it.
        let shared = invitation("email-1", by: plain, to: "sam@example.com")
        let first = (member: "ma", ask: try XCTUnwrap(ask(me: owner, .owner, shared, standing(email: true), signerRole: .member)))
        let second = (member: "mb", ask: first.ask)
        XCTAssertEqual(LateJoiner.chosen([first, second], raised: []), ["ma"])
        XCTAssertEqual(LateJoiner.chosen([first, second], raised: ["mb"]), ["mb"])
        XCTAssertEqual(LateJoiner.chosen([first, second], raised: [], pending: [shared]), [],
                       "held by a question raised outside the pass")
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                for question in found where asked.contains(CanonicalId.key(question.member)) {
                    approvals.ask(question.request)
                }
        """), "only the chosen are asked")
    }

    /// The shared cap: at most 3 questions pending per circle whose signer
    /// isn't an owner or admin in the chain, both cases together; a chain
    /// owner's or admin's own invitation has none.
    func testTheSharedCap() throws {
        // A plain member's 5 expired invitations to strangers: 3 questions
        // pending; once one is answered, the next is asked.
        var pending: [LateJoiner.Ask] = []
        for n in 1...5 {
            if let asked = ask(me: owner, .owner, invitation("inv-\(n)", by: plain, to: "stranger-\(n)"),
                               standing(expired: true, notChainAdmin: true), signerRole: .member, pending: pending.count) {
                pending.append(asked)
            }
        }
        XCTAssertEqual(pending.map(\.invitation.statementId), ["inv-1", "inv-2", "inv-3"])
        pending.removeFirst()
        XCTAssertNotNil(ask(me: owner, .owner, invitation("inv-4", by: plain, to: "stranger-4"),
                            standing(expired: true, notChainAdmin: true), signerRole: .member, pending: pending.count))
        // A fourth invitee of an admin not in the chain yet waits while 3 are
        // pending, then is asked in whichever case applies by then.
        XCTAssertNil(ask(me: owner, .owner, invitation(by: plain), standing(notChainAdmin: true),
                         signerRole: .member, pending: 3))
        let later = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain), standing(expired: true, notChainAdmin: true),
                                      signerRole: .member, pending: 2))
        XCTAssertEqual(later.kind, .ranOut)
        // A chain owner's or admin's own invitation has no cap.
        XCTAssertNotNil(ask(me: owner, .owner, invitation(by: owner), standing(expired: true), signerRole: .owner, pending: 9))
    }

    /// The invitation a member joined with: the first among their statements
    /// as served that is an invitation to this circle, of them, holding under
    /// the key this device trusts for its signer (this account's own, else the
    /// signer's pin). The person is the signed user id, or an email
    /// invitation's signed address. Anything else is the server's word: a
    /// forged "invitation from the owner" would ask the owner with no cap.
    func testTheInvitationIsTheFirstThatHoldsUnderItsSigner() {
        let checker = Checker()
        checker.pins[plain] = "plain-key"
        func statement(_ id: String, _ kind: MembershipStatementKind = .invitationToAccount, by signer: String? = nil,
                       subject: String? = nil, email: String? = nil, circle: String = "c1", signedWith key: String = "plain-key",
                       own: OwnStatementSigner? = nil) -> SignedStatementRecord {
            checker.parsed[id] = MembershipStatement(
                kind: kind, circleId: circle, statementId: id, signerUserId: signer ?? plain, issuedAt: now,
                expiresAt: now + 604_800, atVersion: 3, subjectUserId: kind == .invitationToEmail ? nil : (subject ?? joiner),
                subjectSharingPublicKeyHex: nil, subjectSigningPublicKeyHex: nil, subjectEmail: email)
            checker.signatures[id] = key
            checker.own[id] = own
            return SignedStatementRecord(statementHex: id, signatureHex: "00")
        }
        func invitation(_ statements: [SignedStatementRecord]) -> LateJoiner.Invitation? {
            Track.CircleManager.lateJoinerInvitation(statements, of: joiner.uppercased(), circleId: "C1", me: owner,
                                                     checker: checker)
        }
        let garbled = SignedStatementRecord(statementHex: "garbled", signatureHex: "00")
        XCTAssertEqual(invitation([garbled, statement("admission", .admission), statement("forged", by: owner, signedWith: "x"),
                                   statement("other circle", circle: "c2"), statement("someone else", subject: admin),
                                   statement("unpinned", by: admin, signedWith: "admin-key"),
                                   statement("inv"), statement("inv-2")]),
                       self.invitation("inv", by: plain, at: now))
        XCTAssertEqual(invitation([statement("mine", by: owner, signedWith: "x", own: .currentKey)])?.statementId, "mine")
        XCTAssertEqual(invitation([statement("mine before a reset", by: owner, signedWith: "x", own: .previousKey)])?
            .statementId, "mine before a reset")
        XCTAssertNil(invitation([statement("says it's mine", by: owner, signedWith: "x", own: .notOurs)]))
        XCTAssertEqual(invitation([statement("email", .invitationToEmail, email: "sam@example.com")])?.person,
                       "sam@example.com")
        XCTAssertNil(invitation([statement("only", .admission)]))
    }

    private final class Checker: MembershipStatementChecking {
        var parsed: [String: MembershipStatement] = [:]
        /// Statement → the key it verifies under.
        var signatures: [String: String] = [:]
        var pins: [String: String] = [:]
        var own: [String: OwnStatementSigner] = [:]
        func parse(_ statementHex: String) throws -> MembershipStatement {
            guard let statement = parsed[statementHex] else { throw MobileError.InvalidInput(message: "unknown") }
            return statement
        }
        func verify(statementHex: String, signatureHex: String, signerKeyHex: String) throws -> Bool {
            signatures[statementHex] == signerKeyHex
        }
        func pinnedSigningKey(circleId: String, userId: String) -> String? { pins[userId] }
        func pinnedSharingKey(circleId: String, userId: String) -> String? { nil }
        func ownSigningKey() -> String? { nil }
        func ownSigner(statementHex: String, signatureHex: String) -> OwnStatementSigner? { own[statementHex] }
        func holdsPreviousIdentity(sharingKeyHex: String) -> Bool { false }
    }

    /// An admission from any device closes the question everywhere: a queued
    /// question goes once the eligibility check lets them in, or once
    /// they're no longer listed.
    func testAnAdmissionAnywhereClosesTheQuestion() throws {
        XCTAssertEqual(LateJoiner.closed(queued: [joiner.uppercased(), plain, admin],
                                         eligible: [joiner: true, plain: false]),
                       [joiner.uppercased(), admin])
        let manager = try source("App/Managers/CircleManager.swift")
        let closing = try XCTUnwrap(manager.range(of: "        let closed = Set(LateJoiner.closed(queued: queued.map(\\.userId), eligible: eligible))\n"))
        let withdrawn = try XCTUnwrap(manager.range(of: "            approvals.askAgain(request)\n", range: closing.upperBound..<manager.endIndex))
        let asking = try XCTUnwrap(manager.range(of: "        for row in listing.rows where row.confirmed", range: closing.upperBound..<manager.endIndex))
        XCTAssertLessThan(withdrawn.lowerBound, asking.lowerBound, "withdrawn before anyone is asked")
    }

    // MARK: - The joiner's own screen

    /// Only when its invitation ran out (past the 300 s grace) before
    /// this device got the key, on a circle with records.
    func testTheJoinersLineOnlyWhenTheirInvitationRanOut() {
        let clock = Date(timeIntervalSince1970: TimeInterval(now))
        XCTAssertTrue(LateJoiner.ranOutForJoiner(expiresAt: now - 301, now: clock, holdsKey: false, hasRecords: true))
        XCTAssertFalse(LateJoiner.ranOutForJoiner(expiresAt: now - 300, now: clock, holdsKey: false, hasRecords: true),
                       "within the grace: the usual line")
        XCTAssertFalse(LateJoiner.ranOutForJoiner(expiresAt: now + 86_400, now: clock, holdsKey: false, hasRecords: true),
                       "the second case: the usual line")
        XCTAssertFalse(LateJoiner.ranOutForJoiner(expiresAt: now - 301, now: clock, holdsKey: true, hasRecords: true))
        XCTAssertFalse(LateJoiner.ranOutForJoiner(expiresAt: now - 301, now: clock, holdsKey: false, hasRecords: false),
                       "a circle without records: the usual line")
        XCTAssertFalse(LateJoiner.ranOutForJoiner(expiresAt: 0, now: clock, holdsKey: false, hasRecords: true))
    }

    func testTheJoinersLineNamesWhoeverWasAsked() {
        XCTAssertEqual(LateJoiner.joinerLine(asked: "Ana"),
                       "Your invitation ran out before anyone's phone could hand the circle over. Ana has been asked to let you in.")
        XCTAssertEqual(LateJoiner.askedName(inviterRole: .admin, inviterName: "Pat", ownerName: "Ana"), "Pat")
        XCTAssertEqual(LateJoiner.askedName(inviterRole: .owner, inviterName: "Ana", ownerName: "Ana"), "Ana")
        XCTAssertEqual(LateJoiner.askedName(inviterRole: .member, inviterName: "Pat", ownerName: "Ana"), "Ana",
                       "a plain member's invitation: the owner is asked")
        XCTAssertEqual(LateJoiner.askedName(inviterRole: nil, inviterName: nil, ownerName: "Ana"), "Ana")
        let copy = CircleLockReason.awaitingKey.copy(isOwner: false, circleName: "Family", device: "phone",
                                                     ranOut: .init(asked: "Ana"))
        XCTAssertEqual(copy.explanation, LateJoiner.joinerLine(asked: "Ana"))
        XCTAssertEqual(CircleLockReason.awaitingKey.copy(isOwner: false, circleName: "Family", device: "phone").explanation,
                       "You've joined Family. It opens here as soon as another member's app is online, usually within a minute.",
                       "the second case, and every other: the usual line")
    }

    /// An owner or admin inviter with no name on the joiner's list was asked
    /// all the same: the line says an owner or admin was, in the web app's
    /// words, and never names the owner in their place. A plain member's
    /// invitation names the owner, who was asked; unnamed too when the list
    /// has no name for them.
    func testTheJoinersLineNamesNobodyElseWhenTheOneAskedIsUnnamed() {
        XCTAssertNil(LateJoiner.askedName(inviterRole: .admin, inviterName: nil, ownerName: "Ana"),
                     "the admin was asked, not Ana")
        XCTAssertNil(LateJoiner.askedName(inviterRole: .owner, inviterName: nil, ownerName: "Ana"))
        XCTAssertNil(LateJoiner.askedName(inviterRole: .member, inviterName: "Pat", ownerName: nil))
        XCTAssertEqual(LateJoiner.joinerLine(asked: nil),
                       "Your invitation ran out before anyone's phone could hand the circle over. "
                       + "An owner or admin of the circle has been asked to let you in.")
        let copy = CircleLockReason.awaitingKey.copy(isOwner: false, circleName: "Family", device: "phone",
                                                     ranOut: .init(asked: nil))
        XCTAssertEqual(copy.explanation, LateJoiner.joinerLine(asked: nil), "unnamed, still the ran-out line")
    }

    // MARK: - The question and its answer

    /// The question's words: its title and buttons, with its body per case;
    /// its answer, "Not now" included, is kept against its invitation; a
    /// "Let them in" for a late joiner always signs (they are confirmed here
    /// already: what's missing is the admission).
    @MainActor
    func testTheQuestionsWordsAndItsAnswer() throws {
        let ranOut = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain), standing(expired: true, notChainAdmin: true),
                                       signerRole: .member))
        let request = KeyDeliveryRequest(circleId: "c1", circleName: "Family", userId: joiner, displayName: "Sam",
                                         email: nil, reason: .lateJoiner(ranOut))
        XCTAssertEqual(KeyDeliveryApprovals.title(for: request), "Let Sam into Family?")
        XCTAssertEqual(KeyDeliveryApprovals.question(for: request),
                       "Their invitation ran out before anyone's phone could hand the circle over.\nPat invited them.")
        XCTAssertEqual(request.reason.kindName, LateJoiner.questionKind)
        XCTAssertEqual(KeyDeliveryRequest.Reason.unconfirmedInviter.kindName, "unconfirmedInviter")

        var change = PendingChanges.make(.letIn, account: owner, circleId: "c1",
                                         inputs: .letIn(.init(memberId: joiner, questionKind: LateJoiner.questionKind)),
                                         circleName: "Family", subject: "Sam")
        change.versionAtTap = 3
        XCTAssertNil(LetInKind.admitted(change, ownerOrAdmin: true, verdict: .confirmed(.statement)),
                     "confirmed here already: it still signs the admission")
        var plainLetIn = change
        plainLetIn.inputs = .letIn(.init(memberId: joiner, questionKind: "unconfirmedInviter"))
        XCTAssertEqual(LetInKind.admitted(plainLetIn, ownerOrAdmin: true, verdict: .confirmed(.statement)),
                       .done(line: "Sam was already let in."))

        // Its waiting "Let them in" keeps the question: asked again, in the
        // same words; one an earlier build stored still reads.
        let keptWithIt = PendingChanges.make(
            .letIn, account: owner, circleId: "c1",
            inputs: .letIn(.init(memberId: joiner, questionKind: LateJoiner.questionKind, lateJoiner: ranOut)),
            circleName: "Family", subject: "Sam")
        XCTAssertEqual(PendingQuestion.words(for: keptWithIt).title, "Let Sam into Family?")
        XCTAssertEqual(PendingQuestion.words(for: keptWithIt).body, LateJoiner.body(ranOut))
        let earlier = try JSONDecoder().decode(PendingChange.LetInInputs.self,
                                               from: Data(#"{"memberId":"m","questionKind":"owed"}"#.utf8))
        XCTAssertNil(earlier.lateJoiner)
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("        if case .lateJoiner(let ask) = request.reason { lateJoiner = ask }\n"))
        XCTAssertTrue(manager.contains("                inputs: .letIn(.init(memberId: request.userId, questionKind: request.reason.kindName,\n                                     lateJoiner: lateJoiner)),"))

        let approvals = try source("App/Managers/KeyDeliveryApprovals.swift")
        XCTAssertTrue(approvals.contains("        CircleQuestionNotifier.answered(.join, circleId: request.circleId, userId: request.userId)\n        Self.keepLateJoinerAnswer(request)\n    }\n\n    /// A late joiner's question answered"),
                      "\"Not now\" keeps the answer")
        XCTAssertTrue(approvals.contains("        CircleQuestionNotifier.answered(.join, circleId: request.circleId, userId: request.userId)\n        Self.keepLateJoinerAnswer(request)\n    }\n\n    /// A waiting \"Let them in\" runs"),
                      "\"Let them in\" keeps it too")
    }

    /// Asked after each roster pass and each import of the circle's records;
    /// the joiner's line is on the circle's own screen (the list's caption
    /// stays "Almost ready").
    func testWhereItIsAsked() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("        Task { await deliverToConfirmedMembers(circleId: circleId) }\n        askLateJoinerQuestions(circleId: circleId)\n    }\n"),
                      "after each roster pass")
        XCTAssertTrue(manager.contains("            Task { await self.deliverToConfirmedMembers(circleId: circleId) }\n            askLateJoinerQuestions(circleId: circleId)\n"),
                      "after each import")
        XCTAssertTrue(manager.contains("guard let me = AuthManager.shared.userId, standing(of: circleId) == .recorded,\n              RefreshLedger.shared.isReadable(account: me),\n"),
                      "never while the answers kept here can't be read")
        let notice = try source("App/Views/Circles/LockedCircleNotice.swift")
        XCTAssertEqual(notice.components(separatedBy: "ranOut: CircleManager.shared.lateJoinerRanOut(circle.id)").count, 2)
        XCTAssertEqual(CircleLockReason.awaitingKey.copy(isOwner: false, device: "phone", ranOut: .init(asked: "Ana")).caption,
                       "Almost ready")
    }

    /// Its answer, either way, is kept against its invitation; another
    /// question's isn't kept.
    @MainActor
    func testTheAnswerIsKeptAgainstItsInvitation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("late-joiner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = RefreshLedger(directory: directory)
        let asked = try XCTUnwrap(ask(me: owner, .owner, invitation(by: plain), standing(expired: true, notChainAdmin: true),
                                      signerRole: .member))
        KeyDeliveryApprovals.keepLateJoinerAnswer(
            KeyDeliveryRequest(circleId: "c1", circleName: "Family", userId: joiner, displayName: "Sam", email: nil,
                               reason: .lateJoiner(asked)), me: owner, ledger: ledger)
        KeyDeliveryApprovals.keepLateJoinerAnswer(
            KeyDeliveryRequest(circleId: "c2", circleName: "Work", userId: joiner, displayName: "Sam", email: nil),
            me: owner, ledger: ledger)
        let relaunched = RefreshLedger(directory: directory)
        XCTAssertEqual(relaunched.circle(account: owner, circleId: "c1").lateJoinerAnswered, [asked.invitation])
        XCTAssertEqual(relaunched.circle(account: owner, circleId: "c2"), RefreshLedger.Circle())
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - This account's own invitation from before its reset

    private let keysB = MemberKeyPair(sharingKeyHex: String(repeating: "b1", count: 32), signingKeyHex: String(repeating: "b2", count: 32))

    private func beforeReset(_ id: String = "inv-old", keys: MemberKeyPair? = nil) -> LateJoiner.Invitation {
        var it = invitation(id, by: owner)
        it.signedBeforeReset = true
        it.boundKeys = keys ?? keysB
        return it
    }

    /// The owner's own invitation, signed before its reset, that the
    /// eligibility check no longer counts and that sets none of its flags:
    /// asked of the owner, as the existing question with no line.
    @MainActor
    func testAnOwnInvitationFromBeforeTheResetIsAskedWithNoLine() throws {
        let asked = try XCTUnwrap(LateJoiner.ask(
            me: owner, myChainRole: .owner, invitation: beforeReset(), standing: standing(), signerChainRole: .owner,
            signerName: "Ana", answered: [], pendingCapped: 0, listedKeys: keysB))
        XCTAssertEqual(asked.kind, .ownInvitationBeforeReset)
        XCTAssertNil(asked.inviterLine)
        XCTAssertFalse(asked.capped)
        XCTAssertEqual(LateJoiner.body(asked), "")
        let request = KeyDeliveryRequest(circleId: "c1", circleName: "Family", userId: joiner, displayName: "Sam",
                                         email: nil, reason: .lateJoiner(asked))
        XCTAssertEqual(KeyDeliveryApprovals.title(for: request), "Let Sam into Family?")
        XCTAssertEqual(KeyDeliveryApprovals.question(for: request), "")
        // The keys in any case.
        let upper = MemberKeyPair(sharingKeyHex: keysB.sharingKeyHex.uppercased(), signingKeyHex: keysB.signingKeyHex.uppercased())
        XCTAssertNotNil(LateJoiner.ask(me: owner, myChainRole: .owner, invitation: beforeReset(), standing: standing(),
                                       signerChainRole: .owner, signerName: nil, answered: [], pendingCapped: 0,
                                       listedKeys: upper))
    }

    /// Never: signed with the current key, someone else's, the eligibility
    /// check counts them, keys that changed since, removed by an owner or
    /// admin, already answered or pending, or this account not an owner or
    /// admin in the chain.
    func testAnOwnInvitationFromBeforeTheResetIsAskedOnlyInItsCase() {
        func asked(_ invitation: LateJoiner.Invitation, me: String? = nil, _ standing: LateJoiner.Standing? = nil,
                   role: CircleRole? = .owner, listed: MemberKeyPair? = nil, answered: [LateJoiner.Invitation] = [],
                   pending: [LateJoiner.Invitation] = []) -> LateJoiner.Ask? {
            LateJoiner.ask(me: me ?? owner, myChainRole: role, invitation: invitation, standing: standing ?? self.standing(),
                           signerChainRole: role, signerName: nil, answered: answered, pending: pending, pendingCapped: 0,
                           listedKeys: listed ?? keysB)
        }
        XCTAssertNotNil(asked(beforeReset()), "control")
        var signedNow = invitation("inv-now", by: owner)
        signedNow.boundKeys = keysB
        XCTAssertNil(asked(signedNow), "signed with the current key, for the same keys: never this case")
        signedNow.signedBeforeReset = false
        XCTAssertNil(asked(signedNow))
        var someoneElses = beforeReset()
        someoneElses = LateJoiner.Invitation(statementId: someoneElses.statementId, signerUserId: admin, person: joiner,
                                             issuedAt: now, signedBeforeReset: true, boundKeys: keysB)
        XCTAssertNil(asked(someoneElses), "another account's: its own device asks")
        let plainsBefore = LateJoiner.Invitation(statementId: "inv-plain", signerUserId: plain, person: joiner, issuedAt: now,
                                                 signedBeforeReset: true, boundKeys: keysB)
        XCTAssertNil(LateJoiner.ask(me: owner, myChainRole: .owner, invitation: plainsBefore, standing: standing(),
                                    signerChainRole: .member, signerName: "Pat", answered: [], pendingCapped: 0,
                                    listedKeys: keysB), "a plain member's from before THEIR reset: never asked of the owner")
        XCTAssertNil(asked(beforeReset(), standing(eligible: true)), "the eligibility rule lets them in")
        XCTAssertNil(asked(beforeReset(), listed: MemberKeyPair(sharingKeyHex: String(repeating: "c1", count: 32),
                                                               signingKeyHex: keysB.signingKeyHex)),
                     "their keys changed since: \"It's them\" decides")
        XCTAssertNil(LateJoiner.ask(me: owner, myChainRole: .owner, invitation: beforeReset(), standing: standing(),
                                    signerChainRole: .owner, signerName: nil, answered: [], pendingCapped: 0),
                     "no listed keys: never")
        XCTAssertNil(asked(beforeReset(), standing(removed: true)), "removed by an owner or admin, whatever the signer")
        XCTAssertNil(asked(beforeReset(), answered: [beforeReset()]), "answered here")
        XCTAssertNil(asked(beforeReset(), pending: [beforeReset()]), "asked about another member")
        XCTAssertNil(asked(beforeReset(), role: nil), "this account not counted as an owner or admin in the chain")
        // The flags keep their own cases.
        XCTAssertEqual(asked(beforeReset(), standing(expired: true))?.kind, .ranOut)
    }

    /// Which own statement counts as signed before the reset: one a restored
    /// key verifies; with a kept store and no key verifying it, only one this
    /// device's own approval (a statement's, or its person's choice) names by
    /// id, an own admission included. Never the server's word: no record, a
    /// legacy seed's, another signer's.
    func testTheOwnStatementSignedBeforeTheReset() {
        let checker = Checker()
        func statement(_ id: String, _ kind: MembershipStatementKind = .invitationToAccount, by signer: String,
                       own: OwnStatementSigner?, keys: MemberKeyPair? = nil) -> SignedStatementRecord {
            checker.parsed[id] = MembershipStatement(
                kind: kind, circleId: "c1", statementId: id, signerUserId: signer, issuedAt: now,
                expiresAt: kind == .admission ? 0 : now + 604_800, atVersion: 3, subjectUserId: joiner,
                subjectSharingPublicKeyHex: (keys ?? keysB).sharingKeyHex, subjectSigningPublicKeyHex: (keys ?? keysB).signingKeyHex,
                subjectEmail: nil)
            checker.own[id] = own
            return SignedStatementRecord(statementHex: id, signatureHex: "00")
        }
        func found(_ statements: [SignedStatementRecord], record: CircleApprovalRecord? = nil) -> LateJoiner.Invitation? {
            Track.CircleManager.lateJoinerInvitation(statements, of: joiner, circleId: "c1", me: owner, checker: checker,
                                                     record: record)
        }
        func record(_ origin: ApprovalOrigin, ids: [String]) -> CircleApprovalRecord {
            var record = CircleApprovalRecord()
            record.entries[joiner.uppercased()] = origin
            record.statementIds[joiner.uppercased()] = ids.map { $0.uppercased() }
            return record
        }
        // A restored key verifies it.
        let restored = found([statement("restored", by: owner, own: .previousKey)])
        XCTAssertEqual(restored?.signedBeforeReset, true)
        XCTAssertEqual(restored?.boundKeys, keysB)
        // The current key: no reset in it.
        XCTAssertNil(found([statement("current", by: owner, own: .currentKey)])?.signedBeforeReset)
        XCTAssertNil(found([statement("own admission now", .admission, by: owner, own: .currentKey)]),
                     "a current-key own admission is no late joiner's")
        // No key verifies it; this device's own approval names it.
        XCTAssertNil(found([statement("kept", by: owner, own: .notOurs)]), "no record: the server's word")
        XCTAssertEqual(found([statement("kept", by: owner, own: .notOurs)], record: record(.statement, ids: ["kept"]))?
            .signedBeforeReset, true)
        XCTAssertEqual(found([statement("kept", by: owner, own: .notOurs)], record: record(.ownAction, ids: ["kept"]))?
            .signedBeforeReset, true)
        XCTAssertEqual(found([statement("kept admission", .admission, by: owner, own: .notOurs)],
                             record: record(.ownAction, ids: ["kept admission"]))?.statementId, "kept admission")
        XCTAssertNil(found([statement("kept", by: owner, own: .notOurs)], record: record(.preRound2Seed, ids: ["kept"])),
                     "never a legacy seed")
        XCTAssertNil(found([statement("kept", by: owner, own: .notOurs)], record: record(.kind2, ids: ["kept"])),
                     "never a receive-only origin")
        XCTAssertNil(found([statement("kept", by: owner, own: .notOurs)], record: record(.statement, ids: ["other"])),
                     "a record that names another statement")
        XCTAssertNil(found([statement("theirs", by: admin, own: nil)], record: record(.statement, ids: ["theirs"])),
                     "another signer's, unverified: never")
    }

    /// Answers and questions an earlier build kept still read: no mark.
    func testAnInvitationKeptBeforeReadsWithNoMark() throws {
        let kept = try JSONDecoder().decode(LateJoiner.Invitation.self, from: Data(
            #"{"statementId":"s","signerUserId":"a","person":"p","issuedAt":1}"#.utf8))
        XCTAssertNil(kept.signedBeforeReset)
        XCTAssertNil(kept.boundKeys)
        XCTAssertNil(LateJoiner.ask(me: "a", myChainRole: .owner, invitation: kept, standing: standing(),
                                    signerChainRole: .owner, signerName: nil, answered: [], pendingCapped: 0,
                                    listedKeys: keysB))
        let ask = LateJoiner.Ask(kind: .ownInvitationBeforeReset, invitation: beforeReset(), inviterLine: nil, capped: false)
        XCTAssertEqual(try JSONDecoder().decode(LateJoiner.Ask.self, from: JSONEncoder().encode(ask)), ask)
    }

    /// The kept yes: its "Let them in" waits as a `letIn` change and still
    /// signs when it runs. The member is confirmed here by the pre-reset
    /// invitation, and the re-check never ends it as "already let in";
    /// nothing in it asks whether the question still stands.
    @MainActor
    func testTheKeptYesForAnOwnInvitationFromBeforeTheResetStillSigns() throws {
        let asked = try XCTUnwrap(LateJoiner.ask(
            me: owner, myChainRole: .owner, invitation: beforeReset(), standing: standing(), signerChainRole: .owner,
            signerName: nil, answered: [], pendingCapped: 0, listedKeys: keysB))
        let request = KeyDeliveryRequest(circleId: "c1", circleName: "Family", userId: joiner, displayName: "Sam",
                                         email: nil, reason: .lateJoiner(asked))
        var change = PendingChanges.make(
            .letIn, account: owner, circleId: "c1",
            inputs: .letIn(.init(memberId: joiner, questionKind: request.reason.kindName, lateJoiner: asked)),
            circleName: "Family", subject: "Sam")
        change.versionAtTap = 2
        XCTAssertNil(LetInKind.admitted(change, ownerOrAdmin: true, verdict: .confirmed(.statement)),
                     "confirmed by the invitation from before the reset: it still signs")
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        let start = try XCTUnwrap(kinds.range(of: "struct LetInKind: PendingChangeHandler {"))
        let end = try XCTUnwrap(kinds.range(of: "// MARK: - renew an invitation"))
        let letIn = kinds[start.upperBound..<end.lowerBound]
        XCTAssertFalse(letIn.contains("LateJoiner.ask(") || letIn.contains("askLateJoinerQuestions"))
    }

    /// The pass only asks: nothing is let in or signed without the person's
    /// "Let them in".
    func testThePassOnlyAsks() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        let start = try XCTUnwrap(manager.range(of: "    func askLateJoinerQuestions(circleId: String) {"))
        let end = try XCTUnwrap(manager.range(of: "    nonisolated static func lateJoinerInvitation(", range: start.upperBound..<manager.endIndex))
        let pass = manager[start.upperBound..<end.lowerBound]
        // Each question found is built as a request, and only the chosen are
        // asked (`LateJoiner.chosen`).
        XCTAssertTrue(pass.contains("            found.append((row.userId, ask, KeyDeliveryRequest(\n"))
        XCTAssertTrue(pass.contains("            approvals.ask(question.request)\n"))
        XCTAssertFalse(pass.contains("letIn(") || pass.contains("PendingChanges.queue(") || pass.contains("signMembership")
                       || pass.contains("approve("))
    }

    /// The question reads this device's own approval record and the member's
    /// listed keys.
    func testTheQuestionReadsTheOwnRecordAndTheListedKeys() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("        let record = approvals.record(owner: me, circleId: circleId)\n"))
        XCTAssertTrue(manager.contains("checker: cryptoManager, record: record) else { continue }"))
        XCTAssertTrue(manager.contains("                listedKeys: listedKeys(for: row.userId, in: circleId)) else { continue }"))
    }
}
