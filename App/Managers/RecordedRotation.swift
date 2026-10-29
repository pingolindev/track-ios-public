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

/// Who a rotation of a circle with refresh records names, and how. Pure, so
/// each rule is testable. The SDK's record builder then checks the record
/// exactly as every other device will check it, and refuses it otherwise
/// (`prepareRecordedRotation`): a wrong plan costs a rotation, never a wrong
/// record.
///
/// The app names this account (included), the members the SDK's
/// eligibility rule allows here (included), the others the chain still
/// counts (pending: the builder takes their commitment from the chain), its
/// own person's removals, and, on the chain owner's device, its own
/// person's role changes. Nobody else: the builder fills in every member
/// the previous record included or carried pending who is off the complete
/// list, and refuses a listed member the plan leaves out.
enum RecordedRotation {
    /// A member on the COMPLETE roster the confirmation pass judged. The keys
    /// the SDK is given come from that same roster, never a later fetch.
    struct Listed: Equatable {
        let userId: String
        /// The server's word: used for a transition's roles and the ownership
        /// claim only.
        let role: CircleRole
        /// Whether they have published keys. A member with none is never
        /// included (nothing to wrap to) and never named in a transition (no
        /// commitment yet); one the chain already counts is carried pending
        /// with the chain's commitment.
        let hasKeys: Bool
    }

    /// A rotation or a repair.
    /// - `includable`: the SDK's eligibility rule's yes
    ///   (`refreshEligibility(.include)`).
    /// - `blocked`: members whose listed keys changed without the person's yes
    ///   (the send-side gate). Left pending.
    /// - `counted`: the chain's role of each member it counts (`chainRole`).
    /// - `removing`: this device's person's own removals the chain doesn't carry
    ///   yet: the member an eject removes, and those its person revoked since
    ///   (removal while behind). Named removed when the chain counts them or
    ///   the rejected record before this one names them.
    /// - `rejectedIncluded`: when the record before this one was rejected here,
    ///   a repair or not: every listed member it names, included or pending
    ///   (the SDK's `tipNamedListed`). The new record names everyone the
    ///   record before it named, so those it can't include are carried
    ///   pending.
    /// - `roleChanges`: the role changes this device's person made, on the
    ///   chain owner's device only. Nobody copies a role from the list.
    /// - `claimsOwner`: the ownership claim (`claimsOwner(...)`).
    /// - `handOverTo`: the owner's hand-over: that member is named owner and
    ///   this account member, on the chain owner's device only; never with a
    ///   claim. Whether the plan does hand over is `handsOver`'s to say.
    nonisolated static func rotationPlan(
        me: String, roster: [Listed], includable: Set<String>, blocked: Set<String>,
        counted: [String: CircleRole], removing: Set<String>, rejectedIncluded: Set<String> = [],
        roleChanges: [String: CircleRole] = [:], claimsOwner: Bool = false, handOverTo: String? = nil
    ) -> [PlannedEntry] {
        let includable = lowered(includable), blocked = lowered(blocked)
        let rejectedIncluded = lowered(rejectedIncluded)
        var roleChanges = lowered(roleChanges)
        let counted = lowered(counted)
        let handOverTo = claimsOwner ? nil : handOverTo?.lowercased()
        if let handOverTo { roleChanges[handOverTo] = .owner }
        let selfRole: CircleRole? = claimsOwner ? .owner : handOverTo != nil ? .member : nil
        var plan = [PlannedEntry(userId: me, state: .included, role: selfRole)]
        var named: Set<String> = [me.lowercased()]
        // An own removal is named for someone the chain still counts, or whom
        // the rejected record it goes after names: left out, the builder would
        // fill them in as departed, which a server undoes by listing them again
        // (the Android app does the same). Nobody else was ever named, so there
        // is nothing to remove.
        for userId in removing.sorted()
            where (counted[userId.lowercased()] != nil || rejectedIncluded.contains(userId.lowercased()))
            && named.insert(userId.lowercased()).inserted {
            plan.append(PlannedEntry(userId: userId, state: .removed, role: nil))
        }
        let removed = lowered(removing)
        for member in roster {
            let id = member.userId.lowercased()
            // Someone this person removes is never given the new key, even one
            // the chain never counted (a newcomer ejected before any record).
            guard !named.contains(id), !removed.contains(id) else { continue }
            let role = roleChanges[id]
            if member.hasKeys && includable.contains(id) && !blocked.contains(id) {
                plan.append(PlannedEntry(userId: member.userId, state: .included, role: role))
            } else if counted[id] != nil || rejectedIncluded.contains(id) {
                // Carried with the chain's commitment, so no keys are needed:
                // a listed member who has none now is carried too (the builder
                // refuses a listed member the plan leaves out).
                plan.append(PlannedEntry(userId: member.userId, state: .pending, role: role))
            } else {
                // Not in the chain yet and not allowed in: named in no record
                // until an admission or invitation lets them in.
                continue
            }
            named.insert(id)
        }
        return plan
    }

    /// A member as the role rules read them: on the complete roster now, with
    /// both keys, the SDK's eligibility rule's yes now, and the chain's role
    /// (nil: never named, or no longer counted).
    struct RoleMember: Equatable {
        let userId: String
        let listed: Bool
        let hasKeys: Bool
        let eligible: Bool
        let chainRole: CircleRole?
    }

    /// Pure: the role changes a record from this device writes: the
    /// chain's owner writes its person's own; nobody else writes any, and for
    /// everyone else each role is carried over.
    nonisolated static func writtenRoles(myChainRole: CircleRole?, owed: [String: CircleRole]) -> [String: CircleRole] {
        myChainRole == .owner ? owed : [:]
    }

    /// Pure: whether this person's owed role changes owe a record now. Only on
    /// the chain owner's device, and only a change a record can carry: a
    /// member the chain counts with another role, or a promotion of one it
    /// never named who is listed with both keys and whom the SDK's eligibility
    /// rule lets in. A newcomer comes in as a member, so a never-named member's
    /// demotion owes nothing; and a change no record can carry yet waits, or
    /// every sweep would rotate (a rotation that went through clears the
    /// backoff).
    nonisolated static func roleChangesDue(myChainRole: CircleRole?, owed: [String: CircleRole],
                                           members: [RoleMember]) -> Bool {
        guard myChainRole == .owner else { return false }
        return owed.contains { userId, role in
            guard let member = members.first(where: { CanonicalId.sameKey($0.userId, userId) }) else { return false }
            if let counted = member.chainRole { return counted != role }
            return role == .admin && member.listed && member.hasKeys && member.eligible
        }
    }

    /// Pure, as planned: the owed role changes the record `plan` carries away
    /// once the server takes it, member → role. Off the chain owner's device
    /// none can ever be written from here, and a member no longer listed has
    /// nothing to write; else only a change the plan names with that same
    /// role. A never-named member's demotion the plan leaves out stays owed: a
    /// record naming them admin may still land, from here or the owner's other
    /// device, and a lost demotion fails unsafe.
    nonisolated static func roleChangesSettled(owed: [String: CircleRole], myChainRole: CircleRole?,
                                               listed: Set<String>, plan: [PlannedEntry]) -> [String: CircleRole] {
        owed.filter { userId, role in
            myChainRole != .owner || !listed.contains(where: { CanonicalId.sameKey($0, userId) })
                || plan.contains { CanonicalId.sameKey($0.userId, userId) && $0.role == role }
        }
    }

    /// A role as the ledger keeps it.
    nonisolated static func roleName(_ role: CircleRole) -> String {
        switch role {
        case .owner: return "owner"
        case .admin: return "admin"
        case .member: return "member"
        }
    }

    /// Whether `plan` hands the circle to `target`: the target included and
    /// named owner, and this account included and named member. Anything else
    /// (a target the record can only carry pending, one it leaves out) hands
    /// nothing over, and nothing is sent: the server moves the ownership to
    /// whoever the request names (`transfer_to`), so this check is the only tie
    /// between the record and the transfer.
    nonisolated static func handsOver(_ plan: [PlannedEntry], me: String, to target: String) -> Bool {
        let owners = plan.filter { $0.role == .owner }
        guard owners.count == 1, owners[0].userId.caseInsensitiveCompare(target) == .orderedSame,
              owners[0].state == .included else { return false }
        return plan.contains {
            $0.userId.caseInsensitiveCompare(me) == .orderedSame && $0.state == .included && $0.role == .member
        }
    }

    /// A transition, the first record of a circle without records: the
    /// confirmation rules (confirmed and not blocked: included; every other
    /// listed member with keys: pending), with every role exactly as the list
    /// shows it. The builder's own role for an entry of a transition is
    /// "member", so each is set here. Nil when this device can't write one: its
    /// account isn't an owner or admin on the list, the list doesn't show
    /// exactly one owner, or the owner has no published keys (the circle stays
    /// legacy until they do; nobody else is ever named owner).
    /// The caller passes a COMPLETE roster only.
    nonisolated static func transitionPlan(
        me: String, roster: [Listed], confirmed: Set<String>, blocked: Set<String>
    ) -> [PlannedEntry]? {
        let confirmed = lowered(confirmed), blocked = lowered(blocked)
        guard let mine = roster.first(where: { $0.userId.caseInsensitiveCompare(me) == .orderedSame }),
              mine.role != .member else { return nil }
        let owners = roster.filter { $0.role == .owner }
        guard owners.count == 1, owners[0].hasKeys else { return nil }
        var plan = [PlannedEntry(userId: me, state: .included, role: mine.role)]
        var named: Set<String> = [me.lowercased()]
        for member in roster where member.hasKeys && named.insert(member.userId.lowercased()).inserted {
            let id = member.userId.lowercased()
            let state: RecordMemberState = confirmed.contains(id) && !blocked.contains(id) ? .included : .pending
            plan.append(PlannedEntry(userId: member.userId, state: state, role: member.role))
        }
        return plan
    }

    /// The ownership claim: an admin in the chain who is the owner on this
    /// device's list names ITSELF owner, in the record that removes the chain's
    /// owner (a listed old owner: only then), or once the chain counts no owner
    /// any more (a gone owner: in its next rotation). Whether an owner this
    /// device doesn't list still counts is the chain's to say: a claim the
    /// builder refuses is planned again without it (`prepareRecordedChange`),
    /// never retried in a loop. Nothing is ever claimed on a completed claim's
    /// word alone.
    nonisolated static func claimsOwner(myChainRole: CircleRole?, myListedRole: CircleRole?,
                                        removing: Set<String>, counted: [String: CircleRole]) -> Bool {
        guard myChainRole == .admin, myListedRole == .owner else { return false }
        let counted = lowered(counted)
        let removesOwner = lowered(removing).contains { counted[$0] == .owner }
        let noOwnerKnown = !counted.values.contains(.owner)
        return removesOwner || noOwnerKnown
    }

    /// The versions a repair answers: rejected here by the SDK's check R2 (a
    /// member included who isn't allowed, an entry that matches nobody
    /// confirmed, a role or a removal without the right), or as MISATTRIBUTED
    /// (signed by another confirmed member than the one its signer entry
    /// names; passed over, its removals counting, and only an accepted record
    /// after it brings writes back; its repair links from below at once,
    /// `CircleManager.holdsWhatARepairNeeds`). A version rejected for its
    /// structure, signature or chain is no record at all: no repair links to
    /// it.
    nonisolated static func repairable(_ versions: [RecordVersionStatus]) -> [RecordVersionStatus] {
        versions.filter { status in
            status.state == .rejected
                && [.r2NotAllowed, .r2UnmatchedEntry, .role, .removal, .misattributed].contains(status.problem)
        }
    }

    /// "Not yet": every refusal of `signCircleHead` or
    /// `prepareRecordedRotation` that means this device must import the
    /// circle's records first carries this text, as InvalidInput or as
    /// KeyNotFound.
    nonisolated static let notYetText = "import this circle's records first"

    /// Pure: whether `error` is that "not yet": no failure and nothing to back
    /// off from, since only the next import can change the answer. Keyed on
    /// the error's own text, in whatever case it comes: never a switch over
    /// the SDK's cases, which a bindings update may add to, and never its
    /// description, which escapes the text's apostrophe.
    nonisolated static func notYet(_ error: Error) -> Bool {
        guard let error = error as? MobileError,
              let payload = Mirror(reflecting: error).children.first?.value else { return false }
        let message = payload as? String
            ?? Mirror(reflecting: payload).children.lazy.compactMap { $0.value as? String }.first
        return message?.contains(notYetText) ?? false
    }

    private nonisolated static func lowered(_ ids: Set<String>) -> Set<String> {
        Set(ids.map { $0.lowercased() })
    }

    private nonisolated static func lowered<V>(_ map: [String: V]) -> [String: V] {
        Dictionary(map.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
