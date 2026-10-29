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

import Foundation
import PingolinTrackSDK

/// The late joiner's one question: "Let {name} into {circle}?" on a circle
/// with refresh records, about a member this device confirms whom the SDK's
/// eligibility rule doesn't let in, when their invitation can't count for
/// them: it ran out before anyone's phone could hand the circle over, its
/// signer isn't an owner or admin in the chain, it was sent to an email
/// address, or this account signed it before its own password reset. Pure,
/// so each rule is testable; `CircleManager.askLateJoinerQuestions` asks.
enum LateJoiner {
    /// Which case a question is.
    enum Case: Equatable, Codable {
        /// The invitation ran out before they got the key, whoever signed it.
        case ranOut
        /// It hasn't run out, but its signer isn't an owner or admin in the
        /// chain (an admin whose promotion isn't recorded yet).
        case inviterNotChainAdmin
        /// They joined through an invitation to an email address (kind 2),
        /// which signs no user id.
        case emailInvitation
        /// This account signed their invitation (or admission) before its own
        /// password reset, so the SDK's eligibility rule doesn't count it: asked
        /// of this account, with no line.
        case ownInvitationBeforeReset
    }

    /// One invitation, as the late joiner's question counts them: the same
    /// statement id, or the same signer inviting the same person (the signed
    /// subject user id, or for kind 2 the signed address) to the same circle
    /// within 8 days either way (an invitation's 7-day age limit plus a day of
    /// clock skew). A retry signs the same invitation again with a new id, and
    /// the answer, "Not now" included, covers them all.
    struct Invitation: Codable, Equatable {
        let statementId: String
        let signerUserId: String
        let person: String
        let issuedAt: Int64
        /// True when this account signed it before its own password reset (a
        /// restored key verifies it, or this device's own approval made before
        /// the reset names it); nil otherwise, and in answers kept before.
        var signedBeforeReset: Bool? = nil
        /// The keys it binds (kind 1 and 3); nil for an email invitation.
        var boundKeys: MemberKeyPair? = nil

        static let sameWithin: Int64 = 691_200

        func isSame(as other: Invitation) -> Bool {
            if statementId.caseInsensitiveCompare(other.statementId) == .orderedSame { return true }
            return signerUserId.caseInsensitiveCompare(other.signerUserId) == .orderedSame
                && person.caseInsensitiveCompare(other.person) == .orderedSame
                && abs(issuedAt - other.issuedAt) < Self.sameWithin
        }
    }

    /// The question to ask, with what its answer is kept against. Kept with
    /// a waiting "Let them in", for the same words if it's asked again.
    struct Ask: Equatable, Codable {
        let kind: Case
        let invitation: Invitation
        /// The inviter's name for the line "{inviter} invited them.", or
        /// nil when that line isn't shown.
        let inviterLine: String?
        /// Counted in the shared cap: its signer isn't an owner or admin in
        /// the chain.
        let capped: Bool
    }

    /// A waiting "Let them in" answering this question (`LetInInputs.questionKind`).
    static let questionKind = "lateJoiner"

    /// At most this many questions pending per circle at a time whose
    /// invitation's signer isn't an owner or admin in the chain, both cases
    /// together.
    static let cap = 3

    /// What the SDK's eligibility rule said about the member
    /// (`refreshEligibility(.include)`).
    struct Standing: Equatable {
        let eligible: Bool
        let invitationExpired: Bool
        let signerNotChainAdmin: Bool
        let emailInvitationWithoutSignedId: Bool
        let removedByOwnerOrAdmin: Bool
    }

    /// Pure: whether this account is asked about a member, and how. Nil: not
    /// asked (not now, or never).
    /// - `signerChainRole`: the chain's role of the invitation's signer.
    /// - `signerName`: their name on this device's member list, if listed.
    /// - `answered`: invitations this account's device already answered here.
    /// - `pending`: the invitations of questions pending in the circle about
    ///   other members. One question per invitation, pending ones included: an
    ///   email invitation binds no user id, so a server could attach one to
    ///   several members' rows.
    /// - `pendingCapped`: questions pending in the circle that count in the cap
    ///   (this member's own excluded).
    /// - `listedKeys`: the member's keys as the list shows them now.
    nonisolated static func ask(me: String, myChainRole: CircleRole?, invitation: Invitation, standing: Standing,
                                signerChainRole: CircleRole?, signerName: String?, answered: [Invitation],
                                pending: [Invitation] = [], pendingCapped: Int, listedKeys: MemberKeyPair? = nil) -> Ask? {
        guard !standing.eligible else { return nil }
        let signedHere = invitation.signerUserId.caseInsensitiveCompare(me) == .orderedSame
        // The order when the eligibility answer sets more than one (as the
        // Android app does): it ran out, then its signer isn't an owner or
        // admin in the chain, then it went to an email address.
        let kind: Case
        if standing.invitationExpired {
            kind = .ranOut
        } else if standing.signerNotChainAdmin {
            kind = .inviterNotChainAdmin
        } else if standing.emailInvitationWithoutSignedId {
            kind = .emailInvitation
        } else if signedHere, invitation.signedBeforeReset == true, !standing.removedByOwnerOrAdmin,
                  let bound = invitation.boundKeys, let listedKeys, sameKeys(bound, listedKeys) {
            // Only for exactly the keys it binds: if theirs changed since, "Is
            // this really {name}?" decides.
            kind = .ownInvitationBeforeReset
        } else {
            return nil
        }
        let signerIsChainAdmin = signerChainRole == .owner || signerChainRole == .admin
        // Who is asked: the account that signed it, if it's an owner or admin
        // in the chain; otherwise the chain's owner.
        guard (signedHere && signerIsChainAdmin) || (!signerIsChainAdmin && myChainRole == .owner) else { return nil }
        // Never about someone an owner or admin ejected, when the signer isn't
        // one: only an owner's or admin's own new invitation counts for them.
        if !signerIsChainAdmin && standing.removedByOwnerOrAdmin { return nil }
        // Once per invitation: answered here, or asked about another member and
        // still pending.
        if (answered + pending).contains(where: { $0.isSame(as: invitation) }) { return nil }
        // The shared cap; a chain owner's or admin's own invitation has none.
        if !signerIsChainAdmin && pendingCapped >= cap { return nil }
        // The line names the inviter from this device's member list; one no
        // longer on it isn't named (no new words for "someone").
        let inviterLine: String?
        switch kind {
        case .ranOut, .inviterNotChainAdmin:
            inviterLine = signerIsChainAdmin ? nil : signerName
        case .emailInvitation:
            inviterLine = signedHere ? nil : signerName
        case .ownInvitationBeforeReset:
            inviterLine = nil
        }
        return Ask(kind: kind, invitation: invitation, inviterLine: inviterLine, capped: !signerIsChainAdmin)
    }

    /// Pure: of the questions a pass finds (`ask` for each member, with no cap
    /// and nothing pending), the members asked (as the Android app's
    /// `questions()`). One question per invitation, the one already raised
    /// keeping it. A chain owner's or admin's own invitation is always asked;
    /// of those that count in the cap, the ones already raised keep their
    /// place, then the oldest invitations, up to `cap` with what is raised
    /// outside the pass. Not whatever order the rows come in.
    /// - `raised`: the members whose question is raised already.
    /// - `pending`, `pendingCapped`: the invitations of questions raised about
    ///   members the pass doesn't find, and how many of them count in the cap.
    nonisolated static func chosen(_ found: [(member: String, ask: Ask)], raised: Set<String>,
                                   pending: [Invitation] = [], pendingCapped: Int = 0) -> [String] {
        let isRaised = { (member: String) in raised.contains(CanonicalId.key(member)) }
        var kept: [(member: String, ask: Ask)] = []
        for question in found.filter({ isRaised($0.member) }) + found.filter({ !isRaised($0.member) }) {
            let taken = kept.map { $0.ask.invitation } + pending
            if !taken.contains(where: { $0.isSame(as: question.ask.invitation) }) { kept.append(question) }
        }
        let capped = kept.filter { $0.ask.capped }.sorted { a, b in
            if isRaised(a.member) != isRaised(b.member) { return isRaised(a.member) }
            if a.ask.invitation.issuedAt != b.ask.invitation.issuedAt {
                return a.ask.invitation.issuedAt < b.ask.invitation.issuedAt
            }
            return a.ask.invitation.statementId < b.ask.invitation.statementId
        }
        return kept.filter { !$0.ask.capped }.map { $0.member } + capped.prefix(max(0, cap - pendingCapped)).map { $0.member }
    }

    /// Pure: the members whose queued question goes, since an admission from
    /// any device closes it everywhere: the SDK's eligibility rule lets them
    /// in now, or they're no longer listed. `eligible`: the rule's answer by
    /// lower-cased user id.
    nonisolated static func closed(queued: [String], eligible: [String: Bool]) -> [String] {
        queued.filter { eligible[$0.lowercased()] != false }
    }

    /// The lines: the first case says the invitation ran out, and adds
    /// "{inviter} invited them." when the inviter isn't an owner or admin in
    /// the chain; the second case is that line alone; the third case is that
    /// line when another account invited them, and nothing when this account
    /// did; the fourth case nothing. None of them mentions keys.
    nonisolated static func body(_ ask: Ask) -> String {
        let ranOut = "Their invitation ran out before anyone's phone could hand the circle over."
        let invited = ask.inviterLine.map { "\($0) invited them." }
        switch ask.kind {
        case .ranOut:
            return [ranOut, invited].compactMap { $0 }.joined(separator: "\n")
        case .inviterNotChainAdmin, .emailInvitation, .ownInvitationBeforeReset:
            return invited ?? ""
        }
    }

    /// Pure: the same pair of keys, in any case.
    nonisolated static func sameKeys(_ a: MemberKeyPair, _ b: MemberKeyPair) -> Bool {
        a.sharingKeyHex.caseInsensitiveCompare(b.sharingKeyHex) == .orderedSame
            && a.signingKeyHex.caseInsensitiveCompare(b.signingKeyHex) == .orderedSame
    }

    /// The joiner's own screen in the first case: their invitation ran out
    /// before they got the key. `asked`: the name of whoever was asked, from the
    /// joiner's own member list (the server's word, display only); nil when
    /// that list has no name for them.
    struct RanOut: Equatable {
        let asked: String?
    }

    /// The joiner's line. Unnamed, the web's words: an owner or admin was
    /// asked, and nobody else is named in their place.
    nonisolated static func joinerLine(asked: String?) -> String {
        guard let asked else {
            return "Your invitation ran out before anyone's phone could hand the circle over. "
                + "An owner or admin of the circle has been asked to let you in."
        }
        return "Your invitation ran out before anyone's phone could hand the circle over. \(asked) has been asked to let you in."
    }

    /// Pure: whether the joiner's own screen says its invitation ran out: it
    /// holds no key for a circle with records, and the invitation it joined
    /// with expired (the eligibility rule's 300 s grace included) before it
    /// got one.
    nonisolated static func ranOutForJoiner(expiresAt: Int64, now: Date, holdsKey: Bool, hasRecords: Bool) -> Bool {
        !holdsKey && hasRecords && expiresAt > 0 && Double(expiresAt) + 300 < now.timeIntervalSince1970
    }

    /// Pure: who the joiner's screen names. The inviter when the list shows
    /// them as an owner or admin, else the circle's owner (the one asked when
    /// the inviter isn't one in the chain; the joiner can't read the chain).
    /// Nil when the one asked has no name on the list: never somebody else's
    /// name, since an owner or admin inviter was asked and the owner wasn't.
    nonisolated static func askedName(inviterRole: CircleRole?, inviterName: String?, ownerName: String?) -> String? {
        if inviterRole == .owner || inviterRole == .admin { return inviterName }
        return ownerName
    }
}

extension LateJoiner.Standing {
    /// The SDK's answer for one member, each of the eligibility
    /// rule's flags as it said.
    init(_ answer: MemberEligibility) {
        self.init(eligible: answer.eligible, invitationExpired: answer.invitationExpired,
                  signerNotChainAdmin: answer.invitationSignerNotChainAdmin,
                  emailInvitationWithoutSignedId: answer.emailInvitationWithoutSignedId,
                  removedByOwnerOrAdmin: answer.removedByOwnerOrAdmin)
    }
}
