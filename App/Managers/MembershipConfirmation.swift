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

/// One signed membership statement as the server returned it for a member —
/// the exact bytes that were signed, never the fields.
struct SignedStatementRecord: Equatable, Codable {
    let statementHex: String
    let signatureHex: String
}

/// What the confirmation pass needs to know about one roster member.
struct MembershipCandidate: Equatable {
    let userId: String
    /// Their CURRENT keys, as the roster serves them.
    let sharingKeyHex: String?
    let signingKeyHex: String?
    /// The invitation they joined with (kind 1 or 2), if any.
    let invitation: SignedStatementRecord?
    /// Admissions (kind 3) owners and admins signed about them.
    let admissions: [SignedStatementRecord]
    /// The version of their stored copy (roster `key_version`); nil = none.
    let keyVersion: Int?
    /// They asked for a fresh copy (`access_requested`).
    let accessRequested: Bool

    var statements: [SignedStatementRecord] { (invitation.map { [$0] } ?? []) + admissions }
}

/// Where a member stands on this device.
enum MembershipVerdict: Equatable {
    /// Confirmed, and why.
    case confirmed(ApprovalOrigin)
    /// A statement from a confirmed member binds keys other than the ones this
    /// device pinned for them — their identity changed. Shown, given nothing,
    /// and asked about ("Is this really {name}?") when their current keys
    /// differ from the pin; never moves the pin.
    case subjectConflict
    /// Carries no statement: invited from an older version of the app that
    /// signed none. Hidden on every device and counted in the owners' and
    /// admins' "kept out" line; nobody is asked.
    case legacy
    /// Carries statements whose signer this device cannot confirm: not
    /// confirmed here, receive-only, or signing with a key this device has not
    /// confirmed yet. Hidden; an owner's or admin's device asks, showing their
    /// number — unless all they carry are invitations to an email.
    case unconfirmable
    /// Forged or misplaced: a bad signature under the signer's pinned key,
    /// another circle, another person, a tombstoned statement, a reused
    /// invitation to an email, a statement older than their departure, keys
    /// that match nothing. Hidden everywhere, no question; logged.
    case invalid

    var isShown: Bool {
        switch self {
        case .confirmed, .subjectConflict: return true
        default: return false
        }
    }
}

/// The SDK calls the pass makes, behind a seam so each rule is testable with
/// real signatures and without this device's key store.
protocol MembershipStatementChecking {
    func parse(_ statementHex: String) throws -> MembershipStatement
    func verify(statementHex: String, signatureHex: String, signerKeyHex: String) throws -> Bool
    /// PINNED keys (the circle's pin, else the identity pin). Read-only: a
    /// lookup never records a pin.
    func pinnedSigningKey(circleId: String, userId: String) -> String?
    func pinnedSharingKey(circleId: String, userId: String) -> String?
    /// This device's own signing key.
    func ownSigningKey() -> String?
    /// Which of this account's keys signed a statement it signed: the current
    /// key, a restored identity's, or neither. nil when it can't be told (no
    /// keys here to check with).
    func ownSigner(statementHex: String, signatureHex: String) -> OwnStatementSigner?
    /// Whether this device holds the PRIVATE key of a previous identity of its
    /// account with this sharing key — restored with the recovery key. A key
    /// the server lists proves nothing.
    func holdsPreviousIdentity(sharingKeyHex: String) -> Bool
}

extension PingolinTrackSDK.CryptoManager: MembershipStatementChecking {
    func parse(_ statementHex: String) throws -> MembershipStatement {
        try parseMembershipStatement(statementHex: statementHex)
    }

    func verify(statementHex: String, signatureHex: String, signerKeyHex: String) throws -> Bool {
        try verifyMembershipStatement(
            statementHex: statementHex, signatureHex: signatureHex, signerSigningPublicKeyHex: signerKeyHex)
    }

    func ownSigningKey() -> String? {
        try? signingPublicKeyHex()
    }

    func ownSigner(statementHex: String, signatureHex: String) -> OwnStatementSigner? {
        try? verifyOwnMembershipStatement(statementHex: statementHex, signatureHex: signatureHex)
    }

    func holdsPreviousIdentity(sharingKeyHex: String) -> Bool {
        holdsPreviousIdentity(sharingPublicKeyHex: sharingKeyHex)
    }
}

/// Who a device may treat as a member of one circle, decided from the
/// device's own record and signed statements — never from the server's
/// roster alone.
///
/// Confirmed are: this device's user; everyone its record holds who is still
/// listed; on a device with no `preRound2Seed` for the circle, the signer of
/// its user's OWN membership statement, checked against this account (its
/// keys — or a previous identity whose private key this device holds — or
/// its email); then, to a fixpoint, anyone carrying a statement that
/// verifies under the PINNED signing key of a confirmed, not receive-only
/// signer. Never anyone for an SDK pin alone:
/// * kinds 1 and 3 bind the subject's user id and keys; the keys must be this
///   device's pin for them when it has one (else: a SUBJECT CONFLICT — never a
///   confirmation, never a pin move), or their current keys when it has none;
/// * kind 2 (an invitation to an email with no account yet) is taken on the
///   server's word, RECEIVE-ONLY; only an admission lifts it;
/// * the statement names this circle; a tombstoned statement never counts, and
///   a member who left is confirmable only by a statement made at or after the
///   version this device held when they left (`at_version`); an invitation to
///   an email carried by two rows counts for neither.
/// The caller retires departed members' pins BEFORE this pass: someone who
/// has left vouches for nobody. And it pins only what this pass confirms.
enum MembershipConfirmation {
    /// A confirmation this pass made, for the caller to record.
    struct NewConfirmation: Equatable {
        let origin: ApprovalOrigin
        let statementIds: [String]
        /// A receive-only member's keys when confirmed (kept in the record,
        /// never pinned).
        let keys: MemberKeyPair?
        /// Made only by this account's own statement signed with a key from
        /// before a password reset. It confirms, but is never recorded as an
        /// approval: that would outlive the restored identity, and the
        /// backfill would then vouch under the current key.
        var previousKeyOnly = false
    }

    struct Result: Equatable {
        var verdicts: [String: MembershipVerdict] = [:]
        /// Confirmed or lifted in this pass: the caller records them.
        var newlyConfirmed: [String: NewConfirmation] = [:]
        /// This device's user joined by an invitation to their email, or their
        /// own statement binds keys other than this device's (a password reset)
        /// — and no admission for their current keys has lifted it: their app
        /// neither delivers nor refreshes.
        var selfIsReceiveOnly = false
        /// This device's user joined by an invitation to an email (the roster's
        /// word) that this pass couldn't match to the account's email: none known
        /// (no /auth/me read in this process and none mirrored for this account,
        /// `CircleManager.ownEmail`), or another address (the email changed since,
        /// or the server's word is wrong). Receive-only, as a matching one makes
        /// it, and the circle's first key waits (`CircleManager.FirstKeyDecision
        /// .wait`), unless an admission for this device's current keys has
        /// anchored it, which needs no email.
        var ownInvitationUnchecked = false
        /// For confirmed members: what a delivery by a plain member may rest on
        /// — a valid invitation's expiry, valid admissions' versions.
        var evidence: [String: DeliveryEvidence] = [:]
        /// Confirmed members with at least one statement that holds up here —
        /// what every other device can check for itself (the backfill is
        /// for the rest).
        var statementHolds: Set<String> = []
        /// Confirmed members whose statements all fail here (signed under
        /// a signer's previous key, most likely).
        var statementsFail: Set<String> = []
        /// Hidden members an owner's or admin's device asks about, and why.
        var askReasons: [String: KeyDeliveryRequest.Reason] = [:]
        /// For confirmed members: the ids of the statements that confirm them
        /// under a CURRENT key on this pass, which the record keeps for a member
        /// this device approved.
        var currentKeyStatementIds: [String: [String]] = [:]

        var confirmed: Set<String> {
            Set(verdicts.compactMap { if case .confirmed = $0.value { return $0.key } else { return nil } })
        }

        func origin(of userId: String) -> ApprovalOrigin? {
            if case .confirmed(let origin)? = verdicts[userId] { return origin }
            return nil
        }
    }

    /// Who this device is: its user id, its OWN keys (never the roster's word
    /// for them) and its account email, normalized.
    struct Me: Equatable {
        let userId: String
        let sharingKeyHex: String?
        let signingKeyHex: String?
        let email: String?
    }

    static func evaluate(
        circleId: String,
        me: Me,
        roster: [MembershipCandidate],
        record: CircleApprovalRecord,
        checker: MembershipStatementChecking,
        now: Date = Date()
    ) -> Result {
        // Ids by their one form: any spelling of this account is this
        // account, never someone to confirm.
        func key(_ id: String) -> String { CanonicalId.key(id) }
        let myId = key(me.userId)
        let rosterIds = Set(roster.map { key($0.userId) })
        // This device's own row carries ITS keys, never the roster's word for them.
        let byId: [String: MembershipCandidate] = Dictionary(roster.map { member -> (String, MembershipCandidate) in
            guard key(member.userId) == myId else { return (key(member.userId), member) }
            return (myId, MembershipCandidate(
                userId: member.userId, sharingKeyHex: me.sharingKeyHex, signingKeyHex: me.signingKeyHex,
                invitation: member.invitation, admissions: member.admissions,
                keyVersion: member.keyVersion, accessRequested: member.accessRequested))
        }, uniquingKeysWith: { first, _ in first })

        var confirmed: [String: ApprovalOrigin] = [:]
        for (userId, origin) in record.entries where rosterIds.contains(key(userId)) {
            confirmed[key(userId)] = origin
        }
        confirmed[myId] = .ownAction
        // Dead here: carried by a tombstone, or withdrawn by this device's
        // user.
        let tombstonedIds = Set(record.tombstones.values.flatMap(\.statementIds).map { $0.lowercased() })
            .union(record.deadStatementIds.map { $0.lowercased() })
        let tombstones = Dictionary(record.tombstones.map { (key($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        // This device's OWN statement makes someone chosen only until it
        // expires (+5 min), never after: a withdrawn or expired invitation a
        // server lists again chooses nobody. After that it is an ordinary
        // statement, and the delivery evidence decides. Whom this device's
        // user chose is kept as a permanent entry instead (`approve`).
        func ownAndLive(_ s: MembershipStatement) -> Bool {
            key(s.signerUserId) == myId && s.expiresAt > 0
                && Int64(now.timeIntervalSince1970) <= s.expiresAt + CircleApprovalRecord.inviteeGrace
        }

        // Parse once; what does not parse holds nothing.
        typealias Parsed = (record: SignedStatementRecord, statement: MembershipStatement)
        var parsed: [String: [Parsed]] = [:]
        var kind2Holders: [String: Set<String>] = [:]
        for member in roster {
            for record in member.statements {
                guard let statement = try? checker.parse(record.statementHex) else { continue }
                parsed[key(member.userId), default: []].append((record, statement))
                if statement.kind == .invitationToEmail {
                    kind2Holders[statement.statementId.lowercased(), default: []].insert(key(member.userId))
                }
            }
        }

        func verifies(_ entry: Parsed, _ signerKey: String) -> Bool {
            (try? checker.verify(statementHex: entry.record.statementHex,
                                 signatureHex: entry.record.signatureHex,
                                 signerKeyHex: signerKey)) == true
        }

        enum Outcome { case confirms(ApprovalOrigin, previousKey: Bool), conflict, signerUnconfirmed, invalid }

        // One statement on one member's row, judged with what is confirmed now.
        // `previousKey` names a statement this account signed with a key from
        // before a password reset: it confirms, but never makes anyone chosen,
        // becomes no approval, and no delivery rests on it.
        func judge(_ entry: Parsed, member: MembershipCandidate) -> Outcome {
            let s = entry.statement
            let id = key(member.userId)
            guard key(s.circleId) == key(circleId) else { return .invalid }
            if s.kind != .invitationToEmail, s.subjectUserId.map(key) != id { return .invalid }
            if tombstonedIds.contains(s.statementId.lowercased()) { return .invalid }
            if s.kind == .invitationToEmail, (kind2Holders[s.statementId.lowercased()]?.count ?? 0) > 1 { return .invalid }
            let signer = key(s.signerUserId)
            if signer == id, signer != myId { return .signerUnconfirmed }  // nobody vouches for themselves
            let signerKey: String
            if signer == myId {
                // This account's own statement may be signed with a key from
                // before a password reset, restored with its identity.
                if checker.ownSigner(statementHex: entry.record.statementHex,
                                     signatureHex: entry.record.signatureHex) == .previousKey {
                    return judged(s, member: member, id: id, previousKey: true)
                }
                guard let own = me.signingKeyHex ?? checker.ownSigningKey() else { return .signerUnconfirmed }
                signerKey = own
            } else {
                guard let origin = confirmed[signer], !origin.isReceiveOnly,
                      // A signer confirmed in this very pass is pinned right after
                      // it, with the keys the member list shows now.
                      let pinned = checker.pinnedSigningKey(circleId: circleId, userId: s.signerUserId)
                        ?? byId[signer]?.signingKeyHex else { return .signerUnconfirmed }
                signerKey = pinned
            }
            guard verifies(entry, signerKey) else {
                // Made with the signer's CURRENT key while this device still pins
                // an older one: they changed identity and this device has not
                // confirmed it — unconfirmable, not a forgery on its face.
                if signer != myId, let current = byId[signer]?.signingKeyHex,
                   !same(current, signerKey), verifies(entry, current) {
                    return .signerUnconfirmed
                }
                return .invalid
            }
            return judged(s, member: member, id: id, previousKey: false)
        }

        // What a statement that verified says about its subject.
        func judged(_ s: MembershipStatement, member: MembershipCandidate, id: String, previousKey: Bool) -> Outcome {
            if let tombstone = tombstones[id], Int(s.atVersion) < tombstone.activeVersion { return .invalid }
            // Only a statement signed with this account's CURRENT key chooses.
            let live = !previousKey && ownAndLive(s)
            switch s.kind {
            case .invitationToEmail:
                return .confirms(live ? .ownKind2 : .kind2, previousKey: previousKey)
            case .invitationToAccount, .admission:
                let chosen: ApprovalOrigin = live ? .ownAction : .statement
                let bindsCurrent = same(s.subjectSharingPublicKeyHex, member.sharingKeyHex)
                    && same(s.subjectSigningPublicKeyHex, member.signingKeyHex)
                let pinnedSharing = checker.pinnedSharingKey(circleId: circleId, userId: member.userId)
                let pinnedSigning = checker.pinnedSigningKey(circleId: circleId, userId: member.userId)
                if id != myId, pinnedSharing != nil || pinnedSigning != nil {
                    // Keys other than the pin: a subject conflict — never a
                    // confirmation, never a pin move; their question is asked.
                    return same(s.subjectSharingPublicKeyHex, pinnedSharing) && same(s.subjectSigningPublicKeyHex, pinnedSigning)
                        ? .confirms(chosen, previousKey: previousKey) : .conflict
                }
                return bindsCurrent ? .confirms(chosen, previousKey: previousKey) : .invalid
            }
        }

        var result = Result()
        func confirm(_ member: MembershipCandidate, _ origin: ApprovalOrigin, statementIds: [String],
                     previousKeyOnly: Bool = false) {
            confirmed[key(member.userId)] = origin
            let keys: MemberKeyPair? = origin.isReceiveOnly
                ? member.sharingKeyHex.flatMap { sharing in
                    member.signingKeyHex.map { MemberKeyPair(sharingKeyHex: sharing.lowercased(), signingKeyHex: $0.lowercased()) }
                }
                : nil
            result.newlyConfirmed[member.userId] = NewConfirmation(
                origin: origin, statementIds: statementIds, keys: keys, previousKeyOnly: previousKeyOnly)
        }

        // THIS DEVICE'S OWN STATEMENTS. Receive-only when it joined by an
        // invitation to its email, or when a statement about it binds keys other
        // than its own — a reset. The anchor is the signer of one that names it,
        // on a device with no `preRound2Seed` for the circle.
        let hasSeed = record.entries.values.contains(.preRound2Seed)
        var joinedByEmail = false
        var invitationUnchecked = false
        var bindsOtherKeys = false
        if let mine = byId[myId] {
            for entry in parsed[myId] ?? [] {
                let s = entry.statement
                guard key(s.circleId) == key(circleId) else { continue }
                let namesMe: Bool
                switch s.kind {
                case .invitationToEmail:
                    namesMe = me.email != nil && s.subjectEmail?.lowercased() == me.email?.lowercased()
                    // This device's own invitation, to an email: receive-only. One
                    // that doesn't name this account's email as known here (none
                    // known in this process, or another address: the email changed
                    // since it was sent, or the server's word is wrong) anchors
                    // nobody, and the first key waits.
                    if entry.record == mine.invitation {
                        joinedByEmail = true
                        if !namesMe { invitationUnchecked = true }
                    }
                case .invitationToAccount, .admission:
                    guard s.subjectUserId.map(key) == myId else { continue }
                    if same(s.subjectSharingPublicKeyHex, me.sharingKeyHex) && same(s.subjectSigningPublicKeyHex, me.signingKeyHex) {
                        namesMe = true
                    } else {
                        bindsOtherKeys = true
                        namesMe = s.subjectSharingPublicKeyHex.map { checker.holdsPreviousIdentity(sharingKeyHex: $0) } ?? false
                    }
                }
                let signer = key(s.signerUserId)
                guard namesMe, !hasSeed, signer != myId, let signerRow = byId[signer], confirmed[signer] == nil,
                      let signerKey = checker.pinnedSigningKey(circleId: circleId, userId: s.signerUserId) ?? signerRow.signingKeyHex,
                      verifies(entry, signerKey) else { continue }
                confirm(signerRow, .statement, statementIds: [s.statementId])
            }
        }

        // No other anchors: an SDK identity pin is NOT evidence of
        // confirmation — earlier versions of the app pinned every member they
        // were shown, ghosts included, and retainMemberPins keeps identity
        // pins. What this device trusts comes only from its own record
        // (carried over a same-account sign-out) and from the statements
        // below; a device with no anchor at all takes its first key on trust
        // once (`CircleManager.firstKeyDecision`).

        // The fixpoint: a newcomer may have been invited by another newcomer.
        var changed = true
        while changed {
            changed = false
            for member in roster where key(member.userId) != myId {
                let id = key(member.userId)
                let current = confirmed[id]
                if let current, !current.isReceiveOnly { continue }
                // A statement under a current key first: it is what an approval may rest on.
                let judgedHere = (parsed[id] ?? []).map { ($0, judge($0, member: member)) }
                func underCurrentKey(_ outcome: Outcome) -> Bool {
                    if case .confirms(_, previousKey: false) = outcome { return true }
                    return false
                }
                let currentKeyFirst = judgedHere.filter { underCurrentKey($0.1) } + judgedHere.filter { !underCurrentKey($0.1) }
                for (entry, outcome) in currentKeyFirst {
                    guard case .confirms(let origin, let previousKey) = outcome else { continue }
                    // Receive-only is lifted by an admission, and only by one.
                    if current?.isReceiveOnly == true, !origin.isReceiveOnly, entry.statement.kind != .admission { continue }
                    guard ApprovalOriginOrder.replaces(current, with: origin) else { continue }
                    confirm(member, origin, statementIds: [entry.statement.statementId], previousKeyOnly: previousKey)
                    changed = true
                    break
                }
            }
        }

        // An admission for this device's CURRENT keys, from a confirmed owner or
        // admin, lifts its receive-only state.
        let admittedAsIAm = byId[myId].map { mine in
            (parsed[myId] ?? []).contains { entry in
                guard entry.statement.kind == .admission, key(entry.statement.signerUserId) != myId,
                      case .confirms = judge(entry, member: mine) else { return false }
                return true
            }
        } ?? false
        result.selfIsReceiveOnly = (joinedByEmail || bindsOtherKeys) && !admittedAsIAm
        result.ownInvitationUnchecked = invitationUnchecked && !admittedAsIAm

        for member in roster {
            let id = key(member.userId)
            if id == myId {
                result.verdicts[member.userId] = .confirmed(.ownAction)
                continue
            }
            let outcomes = (parsed[id] ?? []).map { ($0, judge($0, member: member)) }
            if let origin = confirmed[id] {
                result.verdicts[member.userId] = .confirmed(origin)
                var found = DeliveryEvidence()
                for (entry, outcome) in outcomes {
                    // No delivery rests on a statement signed with a key from
                    // before a reset.
                    guard case .confirms(_, previousKey: false) = outcome else { continue }
                    result.currentKeyStatementIds[member.userId, default: []].append(entry.statement.statementId)
                    switch entry.statement.kind {
                    case .invitationToAccount, .invitationToEmail:
                        found.invitationExpiresAt = max(found.invitationExpiresAt ?? 0, entry.statement.expiresAt)
                    case .admission:
                        found.admissionAtVersions.append(Int(entry.statement.atVersion))
                    }
                }
                if found != DeliveryEvidence() { result.evidence[member.userId] = found }
                if outcomes.contains(where: { if case .confirms = $0.1 { return true } else { return false } }) {
                    result.statementHolds.insert(member.userId)
                } else if !member.statements.isEmpty {
                    result.statementsFail.insert(member.userId)
                }
                continue
            }
            if member.statements.isEmpty {
                result.verdicts[member.userId] = .legacy
            } else if outcomes.contains(where: { if case .conflict = $0.1 { return true } else { return false } }) {
                result.verdicts[member.userId] = .subjectConflict
            } else if outcomes.contains(where: { if case .signerUnconfirmed = $0.1 { return true } else { return false } }) {
                result.verdicts[member.userId] = .unconfirmable
                // Never for someone invited only to an email: letting them in
                // would lift receive-only, which only a promotion may.
                if outcomes.contains(where: { $0.0.statement.kind != .invitationToEmail }) {
                    result.askReasons[member.userId] = .unconfirmedInviter
                }
            } else {
                result.verdicts[member.userId] = .invalid
            }
        }
        return result
    }

    /// Whether an invitation this device's user received names THEM, checked
    /// before they accept: an invitation to their account must bind their user
    /// id and exactly this device's keys, one to an email their account's
    /// email. nil = unsigned (an older inviter's app): nothing to check.
    static func invitationNamesMe(statementHex: String?, circleId: String, me: Me,
                                  checker: MembershipStatementChecking) -> Bool? {
        guard let statementHex, !statementHex.isEmpty else { return nil }
        guard let s = try? checker.parse(statementHex),
              s.circleId.caseInsensitiveCompare(circleId) == .orderedSame else { return false }
        switch s.kind {
        case .invitationToAccount:
            return s.subjectUserId?.caseInsensitiveCompare(me.userId) == .orderedSame
                && same(s.subjectSharingPublicKeyHex, me.sharingKeyHex)
                && same(s.subjectSigningPublicKeyHex, me.signingKeyHex)
        case .invitationToEmail:
            return me.email != nil && s.subjectEmail?.lowercased() == me.email?.lowercased()
        case .admission:
            return false
        }
    }

    /// Why an invitation does not name this account as it is now, or nil when it
    /// does (or is unsigned: nothing to check). Only `.outdatedKeys` — an
    /// invitation to THIS account naming keys it no longer has, i.e. a password
    /// reset since — is renewed (after "Is this really {email}?" on the
    /// inviter's phone). An address invitation is never renewed, and another
    /// account's or circle's cannot be.
    enum InvitationMismatch: Equatable {
        case outdatedKeys
        case otherAddress
        case otherAccount
    }

    /// Only an ACCOUNT invitation (kind 1) to this user id is ever renewed: the
    /// accept's `invite_out_of_date` waits for a renewal only then.
    static func isAccountInvitation(statementHex: String?, circleId: String, userId: String,
                                    checker: MembershipStatementChecking) -> Bool {
        guard let statementHex, let s = try? checker.parse(statementHex) else { return false }
        return s.kind == .invitationToAccount
            && s.circleId.caseInsensitiveCompare(circleId) == .orderedSame
            && s.subjectUserId?.caseInsensitiveCompare(userId) == .orderedSame
    }

    static func invitationMismatch(statementHex: String?, circleId: String, me: Me,
                                   checker: MembershipStatementChecking) -> InvitationMismatch? {
        guard invitationNamesMe(statementHex: statementHex, circleId: circleId, me: me, checker: checker) == false
        else { return nil }
        guard let statementHex, let s = try? checker.parse(statementHex),
              s.circleId.caseInsensitiveCompare(circleId) == .orderedSame else { return .otherAccount }
        switch s.kind {
        case .invitationToAccount:
            return s.subjectUserId?.caseInsensitiveCompare(me.userId) == .orderedSame ? .outdatedKeys : .otherAccount
        case .invitationToEmail:
            return .otherAddress
        case .admission:
            return .otherAccount
        }
    }

    /// Whether a device may hand the circle's current version to this member.
    /// Only a confirmed member who is owed it (no copy, an older one, or an
    /// open request), and only when (a) the member has no copy yet and a valid
    /// invitation that has not expired (5 minutes' grace), (b) an admission
    /// made at or after this device's version, (c) this device's own user chose
    /// them — or this device CREATED the circle (its own record says so:
    /// `createdHere`). A role is the server's word: a server that called a
    /// plain member "admin" would otherwise widen this to every confirmed
    /// member; anyone this leaves pending comes back through the next refresh
    /// or through (b)/(c).
    ///
    /// `eDeliver`: on a circle with refresh records, the SDK's delivery
    /// eligibility for them, which replaces the three cases above and
    /// `createdHere`; nil on a circle without records.
    static func mayDeliver(
        to member: MembershipCandidate,
        verdict: MembershipVerdict?,
        evidence: DeliveryEvidence?,
        circleKeyVersion: Int,
        myActiveVersion: Int,
        createdHere: Bool,
        now: Date,
        eDeliver: Bool? = nil
    ) -> Bool {
        guard case .confirmed(let origin)? = verdict else { return false }
        let owed = member.keyVersion.map { $0 < circleKeyVersion } ?? true || member.accessRequested
        guard owed else { return false }
        if let eDeliver { return eDeliver }
        if createdHere || origin.isChosen { return true }
        if member.keyVersion == nil, let expires = evidence?.invitationExpiresAt,
           now.timeIntervalSince1970 <= Double(expires) + 300 { return true }
        if let newest = evidence?.admissionAtVersions.max(), newest >= myActiveVersion { return true }
        return false
    }

    fileprivate static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

/// What a delivery by a plain member may rest on, per confirmed member.
struct DeliveryEvidence: Equatable {
    /// The latest expiry among their valid invitations (unix seconds).
    var invitationExpiresAt: Int64? = nil
    /// The versions valid admissions about them were made at.
    var admissionAtVersions: [Int] = []
}

/// `ApprovalOrigin`'s ordering: whether `new` replaces `current`. Anything
/// over nothing; a full confirmation over a receive-only one (the caller lets
/// only an admission or its user's own choice through); receive-only never over
/// full; "chosen here" over the rest of its kind; and a statement over trust on
/// first use.
enum ApprovalOriginOrder {
    static func replaces(_ current: ApprovalOrigin?, with new: ApprovalOrigin) -> Bool {
        guard let current else { return true }
        if current == new { return false }
        switch (current.isReceiveOnly, new.isReceiveOnly) {
        case (true, false): return true
        case (false, true): return false
        case (true, true): return new == .ownKind2
        case (false, false): return new == .ownAction || (current == .anchor && new == .statement)
        }
    }
}
