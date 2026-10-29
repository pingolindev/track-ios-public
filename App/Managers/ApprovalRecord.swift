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
import Security

// The approval record, shared by the app and its Notification Service
// Extension (project.yml compiles this file into both). The app reads and
// writes it (`KeyDeliveryApprovals`); the extension reads it
// (`ApprovalRecordStore.stored`) and writes ONLY what reduces trust — a member
// it saw leave, tombstoned (`persistDepartures`) — so the background handover
// decides with exactly the record the app keeps and can grant nothing in it.

/// One question an owner's or admin's device asks: "Let {name} into {circle}?".
struct KeyDeliveryRequest: Identifiable, Equatable {
    /// Why they are asked about. Nobody with no statement at all is
    /// asked about: they stay out, counted in the owners' and admins'
    /// "kept out" line.
    enum Reason: Equatable {
        /// A statement whose signer this device cannot confirm. Their number is
        /// shown, so the answer can be checked another way first.
        case unconfirmedInviter
        /// A late joiner: a member this device confirms whose
        /// invitation can't let them in on a circle with refresh
        /// records.
        case lateJoiner(LateJoiner.Ask)

        /// What a waiting "Let them in" keeps as its question's kind.
        var kindName: String {
            switch self {
            case .unconfirmedInviter: return "unconfirmedInviter"
            case .lateJoiner: return LateJoiner.questionKind
            }
        }
    }

    var id: String { "\(circleId):\(userId)" }
    let circleId: String
    let circleName: String
    let userId: String
    let displayName: String
    /// From `member-public-keys` (owners and admins only); nil when the server
    /// did not give it.
    let email: String?
    var reason: Reason = .unconfirmedInviter
    /// The keys the answer admits them with — the ones the question was asked
    /// about, and the ones `number` was worked out from.
    var sharingKeyHex: String? = nil
    var signingKeyHex: String? = nil
    /// Their security code with this device's user; nil when it can't be worked out.
    var number: String? = nil
}

/// Why this device counts someone as a confirmed member of a circle. Four
/// rules depend on it: who this device may hand the circle to, whose entries
/// an owner's device may vouch for, who is shown, and whose signing key may
/// vouch for anyone.
enum ApprovalOrigin: String, Codable, Equatable {
    /// Carried over from an earlier version of the app: its approvals
    /// (seeded from a roster, own invites, "Give access"). They stay.
    case preRound2Seed
    /// This device's user chose them: their own invite, the circle they
    /// created, "Let them in" (including an answer an earlier version of
    /// the app recorded about someone with no statement, which stays
    /// valid), or "It's them" after a password reset.
    case ownAction
    /// A signed invitation to their account, or an admission, from a member
    /// this device had confirmed.
    case statement
    /// A signed invitation to an EMAIL with no account at the time: taken on
    /// the server's word that the account is that email, so RECEIVE-ONLY — shown
    /// and given the circle, but their signing key vouches for nothing and their
    /// own app neither delivers nor refreshes. An admission lifts it.
    case kind2
    /// Receive-only as `kind2`, but this device's user chose them: their own
    /// invitation to that email, or "It's them" about such a member.
    case ownKind2
    /// Trusted with no statement because nothing else anchored this device in
    /// the circle: whoever sent its first copy of the circle, taken on trust
    /// once. Never the source of a backfill.
    case anchor

    /// Receive-only: never a signer this device trusts, never an SDK pin.
    var isReceiveOnly: Bool { self == .kind2 || self == .ownKind2 }
    /// This device's user chose them.
    var isChosen: Bool { self == .ownAction || self == .ownKind2 }
}

/// A receive-only member's keys as this device first confirmed them. They are
/// never SDK pins: only used to wrap the circle TO them, and a different pair
/// later is a changed identity, asked about like any other.
struct MemberKeyPair: Codable, Equatable {
    var sharingKeyHex: String
    var signingKeyHex: String

    func matches(sharing: String?, signing: String?) -> Bool {
        guard let sharing, let signing else { return false }
        return sharingKeyHex.caseInsensitiveCompare(sharing) == .orderedSame
            && signingKeyHex.caseInsensitiveCompare(signing) == .orderedSame
    }
}

/// Who left a circle while this device watched: their statements never
/// confirm anyone again, and they themselves only through a statement made
/// at or after the version this device held when they left.
struct ApprovalTombstone: Codable, Equatable {
    var statementIds: [String]
    var activeVersion: Int
}

/// An invitation this device's user signed to an ACCOUNT (kind 1), until the
/// invitee appears: the statement it signed and that statement's expiry.
/// Nothing else makes a pending invitee chosen.
struct PendingInvitee: Codable, Equatable {
    var statementId: String
    var expiresAt: Int64
}

/// One circle's record on this device, for one account.
struct CircleApprovalRecord: Codable, Equatable {
    /// Confirmed members and why.
    var entries: [String: ApprovalOrigin] = [:]
    /// The statement ids each confirmed member carried when last seen, kept so a
    /// departure can tombstone them after a relaunch too.
    var statementIds: [String: [String]] = [:]
    /// Invited to their ACCOUNT from here, not joined yet, by user id
    /// (`CanonicalId.key`): bound to the statement this device signed and its
    /// expiry. It makes them chosen only when they appear with THAT statement
    /// before it expired (+5 min); it goes on any appearance, on withdrawal and
    /// at expiry, and a roster pass never tombstones it. Kept apart from the
    /// entries: an invitee is not a member yet.
    var invitees: [String: PendingInvitee] = [:]
    /// Statement ids this device's user withdrew: dead here, as a tombstone's
    /// are. Ids that merely leave the server's pending list are not.
    var deadStatementIds: Set<String> = []
    /// The one-time transition seed's pins, waiting for the first COMPLETE
    /// roster: whom it lists become `preRound2Seed` entries; whom it does
    /// not get nothing — no entry, no invitee record, no tombstone.
    var seedCandidates: Set<String> = []
    var tombstones: [String: ApprovalTombstone] = [:]
    /// Owners' and admins' devices vouch for a `preRound2Seed` member once.
    var backfilled: Set<String> = []
    /// Receive-only members' keys (see `MemberKeyPair`).
    var receiveOnlyKeys: [String: MemberKeyPair] = [:]
    /// Admissions this device's user decided on and could not sign yet — the
    /// device was behind or offline. Signed on a later pass.
    var admissionsOwed: Set<String> = []
    /// The device this record belongs to (`DeviceTag`): a record restored from
    /// a backup onto another phone — without the keys and pins it vouches for,
    /// which never leave a device — carries another tag, or none, and is not
    /// this device's record.
    var deviceTag: String?

    init() {}

    /// Every field optional on the way in, so a record written by an older
    /// build still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: ApprovalOrigin].self, forKey: .entries) ?? [:]
        statementIds = try c.decodeIfPresent([String: [String]].self, forKey: .statementIds) ?? [:]
        // An older record's `invited` (user ids, no statement) is not read:
        // it can never say WHICH invitation makes someone chosen.
        invitees = Self.inviteesByKey(try c.decodeIfPresent([String: PendingInvitee].self, forKey: .invitees) ?? [:])
        deadStatementIds = try c.decodeIfPresent(Set<String>.self, forKey: .deadStatementIds) ?? []
        seedCandidates = try c.decodeIfPresent(Set<String>.self, forKey: .seedCandidates) ?? []
        tombstones = try c.decodeIfPresent([String: ApprovalTombstone].self, forKey: .tombstones) ?? [:]
        backfilled = try c.decodeIfPresent(Set<String>.self, forKey: .backfilled) ?? []
        receiveOnlyKeys = try c.decodeIfPresent([String: MemberKeyPair].self, forKey: .receiveOnlyKeys) ?? [:]
        admissionsOwed = try c.decodeIfPresent(Set<String>.self, forKey: .admissionsOwed) ?? []
        deviceTag = try c.decodeIfPresent(String.self, forKey: .deviceTag)
    }

    /// The invitees by member key. Two spellings an earlier build kept for
    /// one member give one record where they name the same statement (the
    /// EARLIER expiry), and none where they don't: that invitation makes
    /// nobody chosen (strict).
    static func inviteesByKey(_ stored: [String: PendingInvitee]) -> [String: PendingInvitee] {
        var byKey: [String: [PendingInvitee]] = [:]
        for (userId, invitee) in stored { byKey[CanonicalId.key(userId), default: []].append(invitee) }
        return byKey.compactMapValues { held in
            guard let first = held.first, held.allSatisfy({ $0.statementId == first.statementId }) else { return nil }
            return PendingInvitee(statementId: first.statementId, expiresAt: held.map(\.expiresAt).min() ?? first.expiresAt)
        }
    }
}


// The record's changes, as values: `KeyDeliveryApprovals` applies them to the
// stored record, and the notification extension applies the same ones to a
// copy it never stores — what the app would record on this roster, in memory.
extension CircleApprovalRecord {
    /// Record a confirmation. A stronger reason is never downgraded: a member
    /// this device's user chose stays chosen, and only an admission lifts a
    /// receive-only (kind-2) member. `keys` are a receive-only member's, kept
    /// the first time (they are never SDK pins).
    mutating func approve(userId: String, origin: ApprovalOrigin, statementIds: [String], keys: MemberKeyPair?) {
        if ApprovalOriginOrder.replaces(entries[userId], with: origin) {
            entries[userId] = origin
        }
        if !statementIds.isEmpty {
            self.statementIds[userId] = Array(Set((self.statementIds[userId] ?? []) + statementIds)).sorted()
        }
        if let keys, entries[userId]?.isReceiveOnly == true, receiveOnlyKeys[userId] == nil {
            receiveOnlyKeys[userId] = keys
        }
        if entries[userId]?.isReceiveOnly == false {
            receiveOnlyKeys.removeValue(forKey: userId)
        }
    }

    /// The ids of the statements that confirm a member under a CURRENT key on
    /// this pass, kept for a member this device approved by a statement or by
    /// its person's own choice (never a `preRound2Seed`, never a receive-only
    /// member), so that an approval an earlier build made names them from the
    /// first pass on this one. Merged, never replaced.
    mutating func noteStatementIds(userId: String, ids: [String]) {
        guard !ids.isEmpty, let origin = entries[userId], origin == .statement || origin == .ownAction else { return }
        statementIds[userId] = Array(Set((statementIds[userId] ?? []) + ids)).sorted()
    }

    /// A receive-only member's keys, the first time this device sees both —
    /// confirmed before they had published a pair. Never replaces a pair it
    /// holds: a different one is a changed identity, asked about.
    mutating func rememberReceiveOnlyKeys(userId: String, keys: MemberKeyPair) {
        guard entries[userId]?.isReceiveOnly == true, receiveOnlyKeys[userId] == nil else { return }
        receiveOnlyKeys[userId] = keys
    }

    /// Against a COMPLETE roster: anyone who has left loses their entry and is
    /// TOMBSTONED with the statement ids they carried and the version this
    /// device held (`activeVersion`, nil when it holds none) — so neither they
    /// nor their statements come back on a server's say-so. Only entries: a
    /// pending invitee is never tombstoned.
    mutating func retain(roster: Set<String>, activeVersion: Int?) {
        for userId in entries.keys where !roster.contains(userId) {
            entries.removeValue(forKey: userId)
            receiveOnlyKeys.removeValue(forKey: userId)
            admissionsOwed.remove(userId)
            backfilled.remove(userId)
            let ids = statementIds.removeValue(forKey: userId) ?? []
            var tombstone = tombstones[userId] ?? ApprovalTombstone(statementIds: [], activeVersion: 0)
            tombstone.statementIds = Array(Set(tombstone.statementIds + ids)).sorted()
            tombstone.activeVersion = max(tombstone.activeVersion, activeVersion ?? 0)
            tombstones[userId] = tombstone
        }
    }

    /// How long past its expiry an invitation still makes its invitee chosen:
    /// clock skew, never an extension.
    static let inviteeGrace: Int64 = 300

    /// This device's own invitation to an account, as it signed it.
    mutating func recordInvitee(userId: String, statementId: String, expiresAt: Int64) {
        invitees[CanonicalId.key(userId)] = PendingInvitee(statementId: statementId.lowercased(), expiresAt: expiresAt)
    }

    /// Against ANY roster, complete or not: an invitee who appears with THAT
    /// invitation, before it expired (+5 min) and not withdrawn, becomes a
    /// chosen member — a permanent entry, whatever the statement does later.
    /// Appearing any other way, they are left to their statements. The record
    /// goes on appearance either way, and at expiry. `roster`: user id → the
    /// statement id of the invitation their row carries. Only an account's id
    /// appears (`CanonicalId.same`): a row or a record naming no UUID is
    /// nobody's invitee, and such a record goes at expiry.
    mutating func settleInvitees(roster: [String: String?], now: Int64) {
        let rows = Dictionary(roster.compactMap { entry in
            CanonicalId.of(entry.key).map { ($0, (userId: entry.key, invitation: entry.value)) }
        }, uniquingKeysWith: { first, _ in first })
        for (userId, invitee) in invitees {
            if let row = CanonicalId.of(userId).flatMap({ rows[$0] }) {
                if row.invitation?.lowercased() == invitee.statementId,
                   now <= invitee.expiresAt + Self.inviteeGrace,
                   !deadStatementIds.contains(invitee.statementId) {
                    approve(userId: row.userId, origin: .ownAction, statementIds: [invitee.statementId], keys: nil)
                }
                invitees[userId] = nil
            } else if now > invitee.expiresAt + Self.inviteeGrace {
                invitees[userId] = nil
            }
        }
    }

    /// Withdrawn from here: the record goes and the id is dead.
    mutating func withdrawInvitation(statementId: String) {
        let id = statementId.lowercased()
        invitees = invitees.filter { $0.value.statementId != id }
        deadStatementIds.insert(id)
    }

    /// The server's pending list no longer has these: their records go. Only
    /// trust is dropped — the ids are NOT made dead, so an invitation accepted
    /// meanwhile still counts. Someone the roster already lists keeps theirs:
    /// the next roster pass settles it (they may have just accepted). Listed
    /// means an account's id (`CanonicalId.same`).
    mutating func keepInvitees(pendingStatementIds: Set<String>, listedUsers: Set<String> = []) {
        let pending = Set(pendingStatementIds.map { $0.lowercased() })
        let listed = Set(listedUsers.compactMap { CanonicalId.of($0) })
        invitees = invitees.filter {
            pending.contains($0.value.statementId) || CanonicalId.of($0.key).map(listed.contains) == true
        }
    }

    /// This account is no longer an owner or admin in the circle, so the server
    /// has withdrawn every invitation it made there: this device's own records
    /// go and their ids are dead — never an id a LISTED member carries
    /// (`carried`), so a server that lies about the role can at most keep
    /// someone out.
    mutating func withdrawOwnInvitations(except carried: Set<String>) {
        let keep = Set(carried.map { $0.lowercased() })
        for invitee in invitees.values where !keep.contains(invitee.statementId) {
            withdrawInvitation(statementId: invitee.statementId)
        }
    }

    /// Whether this device holds `statementId` as its pending, unexpired and
    /// live invitation of `subject` (what the renewal facts read). A subject
    /// that is no account's id holds none (`CanonicalId.same`).
    func holdsPendingInvitation(subject: String, statementId: String, now: Int64) -> Bool {
        let id = statementId.lowercased()
        guard let subject = CanonicalId.of(subject), let invitee = invitees[subject] else { return false }
        return invitee.statementId == id && now < invitee.expiresAt && !deadStatementIds.contains(id)
    }

    /// The one-time seed against the FIRST COMPLETE roster: a pinned user it
    /// lists becomes a `preRound2Seed` entry; one it does not list gets
    /// nothing. The pins can also name people who left or were removed —
    /// trusting them, or tombstoning an invitee among them, would both be
    /// wrong. Before `retain`. Only an account's id is listed
    /// (`CanonicalId.same`).
    mutating func applySeed(roster: Set<String>) {
        guard !seedCandidates.isEmpty else { return }
        let listed = Dictionary(roster.compactMap { id in CanonicalId.of(id).map { ($0, id) } },
                                uniquingKeysWith: { first, _ in first })
        for candidate in seedCandidates {
            guard let userId = CanonicalId.of(candidate).flatMap({ listed[$0] }) else { continue }
            if ApprovalOriginOrder.replaces(entries[userId], with: .preRound2Seed) {
                entries[userId] = .preRound2Seed
            }
        }
        seedCandidates = []
    }
}

extension CircleApprovalRecord {
    /// Another record's restrictions, kept (the owner-case move,
    /// `KeyDeliveryApprovals.normalizeOwners(in:tag:)`): its tombstones and dead
    /// statement ids. Nothing that grants comes with them.
    mutating func foldRestrictions(of other: CircleApprovalRecord) {
        deadStatementIds.formUnion(other.deadStatementIds)
        for (userId, tombstone) in other.tombstones {
            var merged = tombstones[userId] ?? ApprovalTombstone(statementIds: [], activeVersion: 0)
            merged.statementIds = Array(Set(merged.statementIds + tombstone.statementIds)).sorted()
            merged.activeVersion = max(merged.activeVersion, tombstone.activeVersion)
            tombstones[userId] = merged
        }
    }

    /// One record from a circle's records an earlier build kept under several
    /// spellings of its id: whatever keeps someone out wins, members by their
    /// key.
    /// - Every record gives its tombstones (every statement id, the higher
    ///   version), dead and carried statement ids and backfills.
    /// - Only records carrying `tag` (this device's) grant. A member the fold
    ///   tombstones gets no entry. Otherwise an entry (and receive-only keys)
    ///   holds where every record that has one agrees; where they disagree,
    ///   the canonical spelling's, and with none there, none: they are asked
    ///   about again.
    /// - An invitee holds where every record names the same statement (the
    ///   EARLIER expiry), and not where two members name one statement.
    /// - Seed candidates only when every record holds them; owed admissions
    ///   from any, but none for anyone the fold tombstones.
    /// `records`: the canonical spelling's first, if it is there.
    static func folded(_ records: [(canonical: Bool, record: CircleApprovalRecord)], tag: String?) -> CircleApprovalRecord {
        func keyed<Value>(_ map: [String: Value], _ both: (Value, Value) -> Value) -> [String: Value] {
            Dictionary(map.map { (CanonicalId.key($0.key), $0.value) }, uniquingKeysWith: both)
        }
        func keyed(_ set: Set<String>) -> Set<String> { Set(set.map { CanonicalId.key($0) }) }
        func joined(_ one: ApprovalTombstone, _ other: ApprovalTombstone) -> ApprovalTombstone {
            ApprovalTombstone(statementIds: Array(Set(one.statementIds + other.statementIds)).sorted(),
                              activeVersion: max(one.activeVersion, other.activeVersion))
        }
        func union(_ a: [String], _ b: [String]) -> [String] { Array(Set(a + b)).sorted() }
        var folded = CircleApprovalRecord()
        for (_, record) in records {
            folded.tombstones.merge(keyed(record.tombstones, joined), uniquingKeysWith: joined)
            folded.deadStatementIds.formUnion(record.deadStatementIds)
            folded.statementIds.merge(keyed(record.statementIds, union), uniquingKeysWith: union)
            folded.backfilled.formUnion(keyed(record.backfilled))
        }
        let granting = records.filter { tag != nil && $0.record.deviceTag == tag }
        // Where every value held for a member agrees, it; else the canonical
        // spelling's, if that is one value; else none.
        func agreed<Value: Equatable>(_ values: (CircleApprovalRecord) -> [String: Value]) -> [String: Value] {
            var held: [String: [(canonical: Bool, value: Value)]] = [:]
            for entry in granting {
                for (id, value) in values(entry.record) {
                    held[CanonicalId.key(id), default: []].append((canonical: entry.canonical, value: value))
                }
            }
            var result: [String: Value] = [:]
            for (member, seen) in held where folded.tombstones[member] == nil {
                let canonical = seen.filter(\.canonical).map(\.value)
                if let first = seen.first?.value, seen.allSatisfy({ $0.value == first }) {
                    result[member] = first
                } else if let first = canonical.first, canonical.allSatisfy({ $0 == first }) {
                    result[member] = first
                }
            }
            return result
        }
        folded.entries = agreed(\.entries)
        folded.receiveOnlyKeys = agreed(\.receiveOnlyKeys).filter { folded.entries[$0.key]?.isReceiveOnly == true }
        var invitees: [String: PendingInvitee] = [:]
        for member in Set(granting.flatMap { $0.record.invitees.keys.map { CanonicalId.key($0) } }) {
            let held = granting.flatMap { entry in
                entry.record.invitees.filter { CanonicalId.key($0.key) == member }.map(\.value)
            }
            guard let first = held.first, held.allSatisfy({ $0.statementId == first.statementId }) else { continue }
            invitees[member] = PendingInvitee(statementId: first.statementId,
                                              expiresAt: held.map(\.expiresAt).min() ?? first.expiresAt)
        }
        let named = Dictionary(grouping: invitees.values.map(\.statementId), by: { $0 }).filter { $0.value.count > 1 }
        folded.invitees = invitees.filter { named[$0.value.statementId] == nil }
        folded.seedCandidates = granting.count == records.count
            ? records.dropFirst().reduce(keyed(records.first?.record.seedCandidates ?? [])) {
                $0.intersection(keyed($1.record.seedCandidates))
            }
            : []
        folded.admissionsOwed = granting.reduce(into: Set<String>()) { $0.formUnion(keyed($1.record.admissionsOwed)) }
            .filter { folded.tombstones[$0] == nil }
        folded.deviceTag = granting.isEmpty ? (records.first(where: \.canonical) ?? records.first)?.record.deviceTag : tag
        return folded
    }

    /// A member this record stops vouching for: their entry and everything that
    /// hangs on it go, and their tombstone holds `tombstone`'s statements and
    /// version too.
    mutating func depart(_ userId: String, tombstone: ApprovalTombstone) {
        entries.removeValue(forKey: userId)
        receiveOnlyKeys.removeValue(forKey: userId)
        admissionsOwed.remove(userId)
        backfilled.remove(userId)
        let ids = statementIds.removeValue(forKey: userId) ?? []
        var merged = tombstones[userId] ?? ApprovalTombstone(statementIds: [], activeVersion: 0)
        merged.statementIds = Array(Set(merged.statementIds + ids + tombstone.statementIds)).sorted()
        merged.activeVersion = max(merged.activeVersion, tombstone.activeVersion)
        tombstones[userId] = merged
    }

    /// The record as it is NOW (`theirs`) with a pass's changes (`ours`,
    /// computed from `base`) made on top: a three-way merge, never an
    /// overwrite. What was written meanwhile stays — the notification
    /// extension's departures, a person's "Let them in". Where both sides
    /// changed the same thing, less trust wins: a removal beats a change, and
    /// anyone who departed on EITHER side since `base` stays departed, even if
    /// the other side confirmed them — it decided without that tombstone.
    /// The next pass decides again, with it.
    static func merged(ours: CircleApprovalRecord, base: CircleApprovalRecord,
                       theirs: CircleApprovalRecord) -> CircleApprovalRecord {
        var merged = CircleApprovalRecord()
        merged.entries = threeWay(base.entries, ours.entries, theirs.entries) { mine, other in
            ApprovalOriginOrder.replaces(mine, with: other) ? other : mine
        }
        // Two different first pairs for one member: the one already stored.
        merged.receiveOnlyKeys = threeWay(base.receiveOnlyKeys, ours.receiveOnlyKeys, theirs.receiveOnlyKeys) { _, other in
            other
        }
        merged.invitees = threeWay(base.invitees, ours.invitees, theirs.invitees) { _, other in other }
        // Once dead, dead: whichever side withdrew it.
        merged.deadStatementIds = ours.deadStatementIds.union(theirs.deadStatementIds)
        merged.seedCandidates = threeWay(base.seedCandidates, ours.seedCandidates, theirs.seedCandidates)
        merged.backfilled = threeWay(base.backfilled, ours.backfilled, theirs.backfilled)
        merged.admissionsOwed = threeWay(base.admissionsOwed, ours.admissionsOwed, theirs.admissionsOwed)
        merged.statementIds = ours.statementIds.merging(theirs.statementIds) { Array(Set($0 + $1)).sorted() }
        merged.tombstones = ours.tombstones.merging(theirs.tombstones) { one, other in
            ApprovalTombstone(statementIds: Array(Set(one.statementIds + other.statementIds)).sorted(),
                              activeVersion: max(one.activeVersion, other.activeVersion))
        }
        merged.deviceTag = theirs.deviceTag ?? ours.deviceTag
        for (userId, tombstone) in merged.tombstones
        where ours.tombstones[userId] != base.tombstones[userId] || theirs.tombstones[userId] != base.tombstones[userId] {
            merged.depart(userId, tombstone: tombstone)
        }
        merged.receiveOnlyKeys = merged.receiveOnlyKeys.filter { merged.entries[$0.key]?.isReceiveOnly == true }
        return merged
    }

    /// Per key: whichever side changed it; both, and differently — removed on
    /// either side is removed, else `both` picks.
    private static func threeWay<Value: Equatable>(_ base: [String: Value], _ ours: [String: Value],
                                                   _ theirs: [String: Value],
                                                   both: (Value, Value) -> Value) -> [String: Value] {
        var result: [String: Value] = [:]
        for key in Set(base.keys).union(ours.keys).union(theirs.keys) {
            let (was, mine, other) = (base[key], ours[key], theirs[key])
            if mine == was {
                result[key] = other
            } else if other == was || other == mine {
                result[key] = mine
            } else if let mine, let other {
                result[key] = both(mine, other)
            }
        }
        return result
    }

    /// Kept where neither side removed it, plus whatever either side added.
    private static func threeWay(_ base: Set<String>, _ ours: Set<String>, _ theirs: Set<String>) -> Set<String> {
        ours.intersection(theirs).union(ours.subtracting(base)).union(theirs.subtracting(base))
    }
}

/// A random tag this device keeps in a ThisDeviceOnly keychain item — which a
/// backup never carries to another phone — and writes into every approval
/// record. Read here; created only by the app (`KeyDeliveryApprovals`).
enum DeviceTag {
    /// Its own service: a sign-out wipes "com.pingolin.track", and a
    /// same-account sign-in keeps the records.
    static let service = "com.pingolin.track.device"
    static let account = "approval_device_tag"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let tag = String(data: data, encoding: .utf8), !tag.isEmpty else { return nil }
        return tag
    }
}

/// Where the approval records live, and the one way to read them without
/// changing anything.
///
/// The app group both the app and its notification extension hold
/// (Track.entitlements, NotificationExtension.entitlements): the extension is a
/// separate process and cannot open the app's `UserDefaults.standard`, where
/// earlier versions of the app kept these. `KeyDeliveryApprovals` moves them
/// here once (`movedToAppGroup`). User and statement ids only, no secrets.
enum ApprovalRecordStore {
    /// Same group as `ExtensionBridge.suite`.
    static let suiteName = "group.com.pingolin.track"
    /// `keyDeliveryApprovals.v2.<owner>.<circle>`: the records in the
    /// current format.
    static let prefix = "keyDeliveryApprovals.v2."
    /// The legacy keys: `keyDeliveryApproved.<owner>.<circle>` (+ `.invited`,
    /// `.seeded`). Read once to migrate, then left alone.
    static let legacyPrefix = "keyDeliveryApproved."
    /// `keyDeliveryApprovals.transitionSeed.<owner>`: the one-time seed from the
    /// pins this device already held has been taken.
    static let transitionPrefix = "keyDeliveryApprovals.transitionSeed."
    /// The device tag that adopted the records already here when this device
    /// was first bound (`KeyDeliveryApprovals.bindToThisDevice`): the legacy
    /// keys migrate only while it is this device's tag.
    static let adoptedByKey = "keyDeliveryApprovals.adoptedBy"
    /// Someone signed in on this install before it was bound to a device tag:
    /// its records are never adopted (`KeyDeliveryApprovals.noteSignInStarting`).
    static let signedInBeforeBoundKey = "keyDeliveryApprovals.signedInBeforeBound"

    /// Every owner and circle in these keys is in its one form
    /// (`CanonicalId.key`): the same account or circle spelt another
    /// way must never read as another's records, or as none.
    static func key(owner: String, circleId: String) -> String {
        "\(prefix)\(CanonicalId.key(owner)).\(CanonicalId.key(circleId))"
    }

    /// The legacy key for a circle (`legacyPrefix`), in the same forms.
    static func legacyKey(owner: String, circleId: String) -> String {
        "\(legacyPrefix)\(CanonicalId.key(owner)).\(CanonicalId.key(circleId))"
    }

    /// The account's transition mark (`transitionPrefix`), its owner in its one form.
    static func transitionKey(owner: String) -> String {
        transitionPrefix + CanonicalId.key(owner)
    }

    /// The owner segment of one of these keys: after `prefix`, up to the next
    /// dot (user and circle ids have none).
    static func owner(ofKey key: String, prefix: String) -> Substring? {
        guard key.hasPrefix(prefix) else { return nil }
        return key.dropFirst(prefix.count).prefix { $0 != "." }
    }

    /// The circle segment of a record's or a legacy key, after the owner and
    /// its dot up to the next dot, and what follows it (a legacy key's
    /// `.invited` and `.seeded`; nothing for a record).
    static func circle(ofKey key: String, prefix: String) -> (circle: Substring, rest: Substring)? {
        guard let owner = owner(ofKey: key, prefix: prefix) else { return nil }
        let afterOwner = key.dropFirst(prefix.count + owner.count)
        guard afterOwner.first == "." else { return nil }
        let tail = afterOwner.dropFirst()
        let circle = tail.prefix { $0 != "." }
        guard !circle.isEmpty else { return nil }
        return (circle, tail.dropFirst(circle.count))
    }

    enum Stored: Equatable {
        /// Nothing stored for this circle (or only legacy keys, which only
        /// the app migrates) — or a record that is not this device's
        /// (another tag, or none: restored from a backup).
        case none
        /// Stored, but not readable by this build.
        case unreadable
        case record(CircleApprovalRecord)
    }

    /// The stored record, as the circle's spellings make it (`effective`),
    /// when it is this device's (`deviceTag`). Never migrates — the
    /// notification extension's way in.
    static func stored(in defaults: UserDefaults, owner: String, circleId: String, deviceTag: String?) -> Stored {
        guard let data = defaults.data(forKey: key(owner: owner, circleId: circleId)) else { return .none }
        guard let record = try? JSONDecoder().decode(CircleApprovalRecord.self, from: data) else { return .unreadable }
        guard let deviceTag, record.deviceTag == deviceTag else { return .none }
        return .record(effective(record, others: otherSpellings(in: defaults, owner: owner, circleId: circleId),
                                 tag: deviceTag))
    }

    /// This circle's records under another spelling of its id than the one
    /// form's key, the owner's the same (an earlier build's: the app folds
    /// them, `KeyDeliveryApprovals.foldCircleSpellings`, or keeps every one
    /// while one doesn't read), each decoded; nil for one that doesn't read.
    static func otherSpellings(in defaults: UserDefaults, owner: String, circleId: String) -> [CircleApprovalRecord?] {
        let target = key(owner: owner, circleId: circleId)
        return defaults.dictionaryRepresentation().compactMap { stored, value -> CircleApprovalRecord?? in
            guard stored != target, let storedOwner = Self.owner(ofKey: stored, prefix: prefix),
                  storedOwner == CanonicalId.key(owner),
                  let (circle, rest) = Self.circle(ofKey: stored, prefix: prefix), rest.isEmpty,
                  Self.key(owner: owner, circleId: String(circle)) == target else { return nil }
            return .some((value as? Data).flatMap { try? JSONDecoder().decode(CircleApprovalRecord.self, from: $0) })
        }
    }

    /// The one form's `record` as the circle's other spellings make it:
    /// folded with them (`CircleApprovalRecord.folded`); and while any of them
    /// doesn't read, granting NOTHING, with what the one form's and the
    /// readable ones restrict: the one that doesn't read may hold a tombstone.
    static func effective(_ record: CircleApprovalRecord, others: [CircleApprovalRecord?],
                          tag: String?) -> CircleApprovalRecord {
        guard !others.isEmpty else { return record }
        let readable = others.compactMap { $0 }
        return CircleApprovalRecord.folded(
            [(canonical: true, record: record)] + readable.map { (canonical: false, record: $0) },
            tag: readable.count == others.count ? tag : nil)
    }

    /// The ONE write the notification extension makes to a record: members it
    /// saw leave (a complete roster without them) lose their entry and are
    /// tombstoned — so a server that re-adds them later cannot get them back
    /// in through a record that still says "approved". Nothing is ever added.
    /// Holding the approvals lock the app's writes take too, over the record
    /// as it is NOW; only this device's record; nothing if the lock or the
    /// record cannot be had. Returns whether the stored record now holds the
    /// departures (written here, or already there).
    @discardableResult
    static func persistDepartures(_ departed: [String: ApprovalTombstone], in defaults: UserDefaults, owner: String,
                                  circleId: String, deviceTag: String?, lock: AppGroupLock?,
                                  wait: TimeInterval = 1) async -> Bool {
        guard !departed.isEmpty else { return true }
        guard let lock, let held = await lock.acquire(timeout: wait) else { return false }
        defer { held.release() }
        guard case .record(var record) = stored(in: defaults, owner: owner, circleId: circleId, deviceTag: deviceTag)
        else { return false }
        let before = record
        for (userId, tombstone) in departed {
            record.depart(userId, tombstone: tombstone)
        }
        guard record != before else { return true }
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: key(owner: owner, circleId: circleId))
        // Out to the other process before the lock goes (`set` is asynchronous).
        defaults.synchronize()
        return true
    }
}
