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

/// Handing a member the circle, decided the same way wherever it runs: in the
/// app after every roster load, and in the Notification Service Extension when a
/// visible notification says someone may be owed it. project.yml compiles this
/// file — with `MembershipConfirmation.swift`, `ApprovalRecord.swift` and
/// `CircleWireModels.swift` — into both, so the extension applies exactly the
/// app's rules, from the same code.
///
/// Nothing here writes anything. The app stores what a pass returns and pins
/// through `MemberKeyPinner`; the extension stores nothing and never pins
/// (`readOnlyPinGate`).
enum AccessHandover {

    // MARK: - Who is who: the roster pass

    /// What the pin pass does for one member.
    enum PinAction: Equatable {
        /// Confirmed, not receive-only: pinned (first contact) or matched —
        /// different keys are asked about and the pin stays.
        case pin
        /// Receive-only, keys not seen yet: kept in the approval record.
        case rememberReceiveOnlyKeys
        /// Receive-only: asked about if their keys differ from the record's.
        case askIfReceiveOnlyKeysChanged
        /// A subject conflict: asked about if their keys differ from the pin.
        case askIfPinnedKeysChanged
        /// Anyone else: never pinned, never asked about.
        case nothing
    }

    /// The pin pass, pure: a pin is trust — the SDK takes a new version of a
    /// circle from any member it has pinned — so ONLY a confirmed member is
    /// pinned, never one merely listed.
    static func pinAction(for verdict: MembershipVerdict?, receiveOnlyKeysKnown: Bool) -> PinAction {
        switch verdict {
        case .confirmed(let origin)? where origin.isReceiveOnly:
            return receiveOnlyKeysKnown ? .askIfReceiveOnlyKeysChanged : .rememberReceiveOnlyKeys
        case .confirmed?:
            return .pin
        case .subjectConflict?:
            return .askIfPinnedKeysChanged
        case .legacy?, .unconfirmable?, .invalid?, nil:
            return .nothing
        }
    }

    /// One roster, decided.
    struct RosterPass {
        /// The record as this roster leaves it: departed members tombstoned
        /// (from a complete roster only), this pass's confirmations recorded,
        /// and receive-only members' first keys kept. The app stores it; the
        /// notification extension only decides with it.
        var record: CircleApprovalRecord
        var result: MembershipConfirmation.Result
        /// Every row as the confirmation pass read it, by user id.
        var candidates: [String: MembershipCandidate]
        /// What the pin pass does for each member but this device's user.
        var pinActions: [String: PinAction]
    }

    /// WHO IS CONFIRMED, from this device's record and the roster's signed
    /// statements:
    /// 0. this device's own invitees settle against whoever the roster lists;
    ///    on a COMPLETE roster, an inviter who is no longer an owner or admin
    ///    takes its pending invitations as withdrawn, and on the first one the
    ///    one-time seed takes effect — all before anyone is tombstoned;
    /// 1. who has LEFT is read off a COMPLETE roster only, and loses this
    ///    device's confirmation — tombstoned, so a server that re-adds them
    ///    cannot bring them back with their old statements;
    /// 2. the confirmation pass (`MembershipConfirmation.evaluate`);
    /// 3. its new confirmations are recorded, with why;
    /// 4. receive-only members' first keys are kept (never SDK pins).
    /// The caller retires departed members' PINS before this, and pins only
    /// what `pinActions` says.
    static func rosterPass(circleId: String, me: MembershipConfirmation.Me, roster: [CircleMemberResponse],
                           rosterComplete: Bool, activeVersion: Int?, stored: CircleApprovalRecord,
                           checker: MembershipStatementChecking, now: Date = Date()) -> RosterPass {
        var record = stored
        let candidates = roster.map(MembershipCandidate.init)
        let invitations = Dictionary(candidates.map { candidate in
            (candidate.userId, candidate.invitation.flatMap { try? checker.parse($0.statementHex).statementId })
        }, uniquingKeysWith: { first, _ in first })
        record.settleInvitees(roster: invitations, now: Int64(now.timeIntervalSince1970))
        if rosterComplete {
            // This account is no longer an owner or admin here, so the
            // server withdrew its pending invitations: this device's own
            // records are withdrawn too (the ids dead), except one a listed
            // member carries. Only on a COMPLETE roster: "listed" means all
            // of them, and a member who joined with one of those invitations
            // may be on a page this roster does not have.
            if let mine = roster.first(where: { $0.userId.caseInsensitiveCompare(me.userId) == .orderedSame }),
               mine.role != "owner", mine.role != "admin", !record.invitees.isEmpty {
                record.withdrawOwnInvitations(except: Set(invitations.values.compactMap { $0 }))
            }
            record.applySeed(roster: Set(roster.map(\.userId)))
            record.retain(roster: Set(roster.map(\.userId)), activeVersion: activeVersion)
        }
        let result = MembershipConfirmation.evaluate(
            circleId: circleId, me: me, roster: candidates, record: record, checker: checker, now: now)
        // Not one resting only on this account's own statement signed with a key
        // from before a password reset: it confirms for as long as the restored
        // identity is held, and is judged again on every pass.
        for (userId, confirmation) in result.newlyConfirmed where !confirmation.previousKeyOnly {
            record.approve(userId: userId, origin: confirmation.origin,
                           statementIds: confirmation.statementIds, keys: confirmation.keys)
        }
        // On every pass, so an approval recorded by an older version gets
        // them too.
        for (userId, ids) in result.currentKeyStatementIds {
            record.noteStatementIds(userId: userId, ids: ids)
        }
        let confirmedRecord = record
        var pinActions: [String: PinAction] = [:]
        for member in candidates where member.userId != me.userId {
            let action = pinAction(for: result.verdicts[member.userId],
                                   receiveOnlyKeysKnown: confirmedRecord.receiveOnlyKeys[member.userId] != nil)
            pinActions[member.userId] = action
            if action == .rememberReceiveOnlyKeys,
               let sharing = nonEmpty(member.sharingKeyHex), let signing = nonEmpty(member.signingKeyHex) {
                record.rememberReceiveOnlyKeys(
                    userId: member.userId,
                    keys: MemberKeyPair(sharingKeyHex: sharing.lowercased(), signingKeyHex: signing.lowercased()))
            }
        }
        return RosterPass(
            record: record, result: result,
            candidates: Dictionary(candidates.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first }),
            pinActions: pinActions)
    }

    // MARK: - Who gets it: the delivery pass

    /// Whether this device hands over anything in the circle at all: it holds
    /// EXACTLY the circle's current version (a device that is behind seals
    /// nothing new), the circle opens here, and its own membership is not
    /// receive-only. Nor while it knows it is behind, whatever version the
    /// server lists (`isBehind`).
    static func mayHandOver(heldVersion: Int?, circleKeyVersion: Int, circleOpens: Bool,
                            selfIsReceiveOnly: Bool, isBehind: Bool) -> Bool {
        guard let heldVersion, !isBehind else { return false }
        return circleOpens && heldVersion == circleKeyVersion && !selfIsReceiveOnly
    }

    /// The version of the caller's own stored wrap in a `GET /circles` row:
    /// `member_key_version` when the server sends it, else (an older
    /// server) the circle's `key_version`, the only label such a server
    /// provides.
    static func ownWrapVersion(_ response: CircleResponse) -> Int {
        response.memberKeyVersion ?? response.keyVersion
    }

    /// Whether a `GET /circles` row is shown locked: its name did not open, or
    /// our own wrap is older than the circle's key — a rotation left us pending,
    /// and a name it left sealed under the old key still opening changes
    /// nothing: nothing new is shared with the circle until the key arrives.
    static func isShownLocked(nameOpened: Bool, _ response: CircleResponse) -> Bool {
        !nameOpened || ownWrapVersion(response) < response.keyVersion
    }

    /// Whether this device created the circle — its own record says so: the
    /// creator is its record's first entry, `.ownAction` (`recordCreatedCircle`),
    /// and nothing else ever records this device's own user. Never a role the
    /// server lists.
    static func createdHere(_ record: CircleApprovalRecord, me: String) -> Bool {
        record.entries[me] == .ownAction
    }

    /// A roster member as the delivery pass sees them: their CURRENT keys.
    struct Member: Equatable {
        let userId: String
        let displayName: String
        let sharingKeyHex: String?
        let signingKeyHex: String?
    }

    /// Someone this device hands the circle's current version to, and the keys
    /// it wraps and checks against.
    struct Delivery: Equatable {
        let userId: String
        let displayName: String
        let sharingKeyHex: String
        let signingKeyHex: String
    }

    typealias GateMember = (userId: String, displayName: String, sharingPubkeyHex: String?, signingPubkeyHex: String?)

    /// Delivery by ANY member: who this device hands the circle's current
    /// version to now. A confirmed member it may — a newcomer with a valid,
    /// unexpired invitation (the first delivery), a member admitted at or
    /// after this device's version, someone this device's user chose; the
    /// device that created the circle to any confirmed member who is owed it —
    /// and only through the send-side gate. The caller has checked
    /// `mayHandOver`.
    ///
    /// `eDeliver`: on a circle with refresh records, the members the SDK's
    /// eligibility rule allows for delivery (`EligibilityPurpose.deliver`), in
    /// place of the cases above and `createdHere`; nil on a circle that has
    /// none.
    static func deliveries(me: String, circleKeyVersion: Int, heldVersion: Int, createdHere: Bool,
                           members: [Member], candidates: [String: MembershipCandidate],
                           result: MembershipConfirmation.Result, record: CircleApprovalRecord, now: Date,
                           eDeliver: Set<String>? = nil,
                           pinGate: ([GateMember]) -> Set<String>) -> [Delivery] {
        let allowed = eDeliver.map { Set($0.map { $0.lowercased() }) }
        let owed = members.filter { member in
            guard member.userId != me, let candidate = candidates[member.userId] else { return false }
            return MembershipConfirmation.mayDeliver(
                to: candidate,
                verdict: result.verdicts[member.userId],
                evidence: result.evidence[member.userId],
                circleKeyVersion: circleKeyVersion,
                myActiveVersion: heldVersion,
                createdHere: createdHere,
                now: now,
                eDeliver: allowed.map { $0.contains(member.userId.lowercased()) }
            )
        }
        guard !owed.isEmpty else { return [] }
        let keyed = owed.compactMap { member -> Delivery? in
            guard let sharing = member.sharingKeyHex, let signing = member.signingKeyHex else { return nil }
            return Delivery(userId: member.userId, displayName: member.displayName,
                            sharingKeyHex: sharing, signingKeyHex: signing)
        }
        let blocked = sendSideGate(
            me: me, result: result, record: record,
            members: keyed.map { (userId: $0.userId, displayName: $0.displayName,
                                  sharingPubkeyHex: $0.sharingKeyHex, signingPubkeyHex: $0.signingKeyHex) },
            pinGate: pinGate)
        return keyed.filter { !blocked.contains($0.userId) }
    }

    /// The send-side gate for handing a member the circle — delivery and
    /// rotation both. A confirmed member goes through the pin gate: pinned on
    /// first contact (the app) or taken as first contact (the extension),
    /// blocked when their keys differ from the pin. A receive-only member is
    /// never pinned: their keys must be the ones this device's record holds for
    /// them. Anyone else is blocked — never pinned on the way. Returns who is
    /// blocked.
    static func sendSideGate(me: String, result: MembershipConfirmation.Result, record: CircleApprovalRecord,
                             members: [GateMember], pinGate: ([GateMember]) -> Set<String>) -> Set<String> {
        var blocked = Set<String>()
        var full: [GateMember] = []
        for member in members where member.userId != me {
            switch result.verdicts[member.userId] {
            case .confirmed(let origin)? where origin.isReceiveOnly:
                if record.receiveOnlyKeys[member.userId]?.matches(
                    sharing: member.sharingPubkeyHex, signing: member.signingPubkeyHex) != true {
                    blocked.insert(member.userId)
                }
            case .confirmed?:
                full.append(member)
            default:
                blocked.insert(member.userId)
            }
        }
        return blocked.union(pinGate(full))
    }

    /// The pin gate for a process that must never pin: the notification
    /// extension. It decides exactly what `MemberKeyPinner.gateMembersForRotation`
    /// decides on the SDK's `pin_member_keys`, from the read-only lookups
    /// (`pinned_sharing_key` / `pinned_signing_key`: the circle's pin, else the
    /// user's identity pin — the same reference `pin_member_keys` compares
    /// against, case-insensitively):
    /// * no usable sharing key: blocked;
    /// * no signing key: first contact is allowed, unless a pinned sharing key
    ///   differs (the signing-strip downgrade);
    /// * both keys: blocked unless both are 32-byte hex (the SDK refuses
    ///   anything else) and either nothing is pinned yet (first contact — the
    ///   app would pin them now) or both match the pin.
    /// The app pins a newly confirmed member before it delivers; the extension
    /// delivers to them as that first contact and pins nothing — the app pins
    /// them on its next roster load.
    static func readOnlyPinGate(me: String, circleId: String,
                                pinnedSharing: @escaping (_ circleId: String, _ userId: String) -> String?,
                                pinnedSigning: @escaping (_ circleId: String, _ userId: String) -> String?)
        -> ([GateMember]) -> Set<String> {
        { members in
            var blocked = Set<String>()
            for m in members where m.userId != me {
                guard let sharing = m.sharingPubkeyHex, sharing.count == 64 else {
                    blocked.insert(m.userId)
                    continue
                }
                guard let signing = m.signingPubkeyHex, signing.count == 64 else {
                    if let pinned = pinnedSharing(circleId, m.userId),
                       pinned.caseInsensitiveCompare(sharing) != .orderedSame {
                        blocked.insert(m.userId)
                    }
                    continue
                }
                guard isHex32(sharing), isHex32(signing) else {
                    blocked.insert(m.userId)
                    continue
                }
                switch (pinnedSharing(circleId, m.userId), pinnedSigning(circleId, m.userId)) {
                case (nil, nil):
                    continue
                case let (pinnedSharing?, pinnedSigning?)
                    where pinnedSharing.caseInsensitiveCompare(sharing) == .orderedSame
                        && pinnedSigning.caseInsensitiveCompare(signing) == .orderedSame:
                    continue
                default:
                    blocked.insert(m.userId)
                }
            }
            return blocked
        }
    }

    private static func isHex32(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

extension MembershipCandidate {
    /// A roster row as the confirmation pass reads it.
    init(_ response: CircleMemberResponse) {
        self.init(
            userId: response.userId,
            sharingKeyHex: response.sharingPublicKey,
            signingKeyHex: response.signingPublicKey,
            invitation: response.invitation.map {
                SignedStatementRecord(statementHex: $0.statement, signatureHex: $0.signature)
            },
            admissions: (response.vouches ?? []).map {
                SignedStatementRecord(statementHex: $0.statement, signatureHex: $0.signature)
            },
            keyVersion: response.keyVersion,
            accessRequested: response.accessRequested ?? false
        )
    }
}

extension MembershipConfirmation.Me {
    /// This device as the confirmation pass needs it: its user, its OWN keys
    /// (the SDK's, never the roster's word for them) and its account email,
    /// normalized.
    static func own(userId: String, email: String?, crypto: PingolinTrackSDK.CryptoManager) -> Self {
        let sharing = (try? crypto.exportPublicKey())
            .flatMap { Data(base64Encoded: $0) }
            .map { $0.map { String(format: "%02x", $0) }.joined() }
        return Self(
            userId: userId, sharingKeyHex: sharing,
            signingKeyHex: try? crypto.signingPublicKeyHex(),
            email: email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
