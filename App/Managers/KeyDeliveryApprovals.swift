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

import SwiftUI

/// Who this device's user has confirmed in each circle, and why.
///
/// Nothing is seeded from a roster: trusting the first complete roster a
/// device loads would let a server that lists a ghost to a fresh device
/// have that device hand it the circle. Approvals an earlier version of the
/// app recorded that way stay, as `.preRound2Seed`; everything new comes
/// from this device's own choices or from signed statements
/// (`MembershipConfirmation`).
///
/// Entries are dropped — and tombstoned — for anyone who leaves the complete
/// roster, kept across a same-account sign-out, and wiped when another account
/// signs in or the account is deleted: the lifecycle of the member pins.
/// User and statement ids only, no secrets: the app group's UserDefaults, so
/// the notification extension can read them and record departures into them
/// (`ApprovalRecordStore`) — which is why every write here takes the approvals
/// lock and merges with the record as it is. Only records stamped with this
/// device's tag are read (`bindToThisDevice`). "Not now" on the owners' and
/// admins' question lasts for this session.
@MainActor
final class KeyDeliveryApprovals: ObservableObject {
    static let shared = KeyDeliveryApprovals(defaults: movedToAppGroup())

    /// Waiting owner/admin questions; the root host presents the first.
    @Published private(set) var requests: [KeyDeliveryRequest] = []

    /// "circleId:userId" answered "Not now" in this session.
    private var deferred: Set<String> = []

    private let defaults: UserDefaults
    /// This device's tag (`DeviceTag`): only a record carrying it is this
    /// device's; every record written carries it.
    private let readTag: () -> String?
    /// It never changes once made: read once.
    private var knownTag: String?
    /// Taken around every write: the notification extension writes departures
    /// under it too (`ApprovalRecordStore.persistDepartures`). Nothing is ever
    /// written without it — an unlocked write can drop a departure the
    /// extension just recorded — so without it (nil: no app group, never with
    /// the entitlement) nothing is written at all.
    private let lock: AppGroupLock?
    /// A person's decisions that found the lock taken, re-applied under it at
    /// the next write or return to the foreground (`retryPending`). A roster
    /// pass's changes are never queued: the next pass decides again.
    private var pending: [(owner: String, circleId: String, change: (inout CircleApprovalRecord) -> Void)] = []
    /// An erasure's wipe that found the lock taken (`clearAll`): the account
    /// to keep, run before anything else once the lock is had.
    private var pendingClear: String??
    /// A sign-in's guarded tidy that found the lock taken (`forget`): the
    /// accounts whose records go, run before anything else once it is had.
    private var pendingForget: Set<String> = []
    /// How long a write waits for the lock (tests shorten it).
    private let lockWait: TimeInterval
    private static let legacyPrefix = ApprovalRecordStore.legacyPrefix
    private static let prefix = ApprovalRecordStore.prefix
    private static let transitionPrefix = ApprovalRecordStore.transitionPrefix

    init(defaults: UserDefaults, deviceTag: @escaping () -> String? = DeviceTag.read,
         lock: AppGroupLock? = AppGroupLock.approvals(), lockWait: TimeInterval = 3) {
        self.defaults = defaults
        self.readTag = deviceTag
        self.lock = lock
        self.lockWait = lockWait
    }

    private func deviceTag() -> String? {
        if knownTag == nil { knownTag = readTag() }
        return knownTag
    }

    // MARK: - This device's records only

    /// Binds the records to this device the first time this build runs on it,
    /// before anyone can sign in (at launch and on every return to the
    /// foreground until it has happened): creates the device tag and — only
    /// when the keychain still holds this device's own key material
    /// (ThisDeviceOnly: an app update keeps it, a backup restored onto another
    /// phone never carries it) AND nobody has signed in here before this
    /// device was bound — adopts the records already here, stamping them with
    /// it. Without that they came with a backup, without the keys and pins
    /// they vouch for: untagged, they are never read, and the device starts
    /// fresh. The lock comes BEFORE the tag: a tag made without it could no
    /// longer adopt anything, so no lock means no tag yet, and the next
    /// return to the foreground tries again. Returns whether it adopted.
    @discardableResult
    static func bindToThisDevice(_ defaults: UserDefaults, tag: () -> String?, createTag: () -> String?,
                                 keychainIsThisDevices: Bool, lock: AppGroupLock?, wait: TimeInterval = 3) -> Bool {
        guard tag() == nil, let lock, let held = lock.acquireBlocking(timeout: wait) else { return false }
        defer { held.release() }
        guard let new = createTag(), keychainIsThisDevices,
              !defaults.bool(forKey: ApprovalRecordStore.signedInBeforeBoundKey) else { return false }
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let data = value as? Data,
                  var record = try? JSONDecoder().decode(CircleApprovalRecord.self, from: data),
                  record.deviceTag == nil else { continue }  // another device's stays another's
            record.deviceTag = new
            if let stamped = try? JSONEncoder().encode(record) { defaults.set(stamped, forKey: key) }
        }
        defaults.set(new, forKey: ApprovalRecordStore.adoptedByKey)
        defaults.synchronize()
        return true
    }

    /// Called as a sign-in begins, before it writes any of the SDK's keychain
    /// items: with no device tag yet, the records here can no longer be told
    /// from a restored backup's — once this account's keys are in the keychain
    /// `keychainIsThisDevices` is true either way — so adoption is off for good
    /// (it errs towards starting fresh). Kept where neither a sign-out nor
    /// `clearAll` wipes it; a backup carrying it over can only block adoption.
    static func noteSignInStarting(_ defaults: UserDefaults? = nil, tag: () -> String? = DeviceTag.read) {
        guard tag() == nil else { return }
        let defaults = defaults ?? shared.defaults
        defaults.set(true, forKey: ApprovalRecordStore.signedInBeforeBoundKey)
        defaults.synchronize()
    }

    /// `bindToThisDevice` on the real keychain and the app group. A no-op once
    /// the tag exists.
    static func bindRecordsToThisDevice() {
        guard DeviceTag.read() == nil else { return }
        bindToThisDevice(shared.defaults, tag: DeviceTag.read, createTag: DeviceTag.create,
                         keychainIsThisDevices: DeviceTag.keychainHoldsThisDevicesOwnItems(),
                         lock: AppGroupLock.approvals())
    }

    // MARK: - Storage

    /// Set in the app group once every record this device kept in the app's
    /// own defaults has been copied over.
    static let movedMark = "keyDeliveryApprovals.inAppGroup"

    /// The app group's defaults, with this device's records moved into them
    /// from `old` (the app's own defaults, where earlier versions of the app
    /// kept them) — ONCE, before anything reads or writes one: the notification
    /// extension decides with them and cannot open the app's defaults.
    /// Until the mark is set the old copies are the record: a move cut short
    /// is redone over the top of its partial copy. The old copies go only after
    /// the mark, and any left by an interrupted clean-up go at the next launch.
    /// Without the app group (never, with the entitlement) the old defaults stay
    /// the store.
    static func movedToAppGroup(from old: UserDefaults = .standard,
                                suiteName: String = ApprovalRecordStore.suiteName) -> UserDefaults {
        guard let group = UserDefaults(suiteName: suiteName) else { return old }
        let ours = old.dictionaryRepresentation().filter { key, _ in
            [prefix, legacyPrefix, transitionPrefix].contains { key.hasPrefix($0) }
        }
        if !group.bool(forKey: movedMark) {
            for (key, value) in ours { group.set(value, forKey: key) }
            group.set(true, forKey: movedMark)
        }
        for key in ours.keys { old.removeObject(forKey: key) }
        return group
    }

    private func key(owner: String, circleId: String) -> String {
        ApprovalRecordStore.key(owner: owner, circleId: circleId)
    }

    /// The circle's record, migrating the legacy keys: every legacy approval
    /// becomes a `.preRound2Seed` entry. Legacy invitees are not carried over:
    /// nothing says which invitation was theirs. Only read here — the next
    /// change stores it (`update`, under the lock).
    ///
    /// A stored record that does not read (a newer build's) yields an EMPTY
    /// record and is left alone — never rebuilt from the legacy keys over the
    /// top of it. Empty is the safe side: nobody is confirmed by it.
    func record(owner: String, circleId: String) -> CircleApprovalRecord {
        if let data = defaults.data(forKey: key(owner: owner, circleId: circleId)) {
            guard let record = try? JSONDecoder().decode(CircleApprovalRecord.self, from: data) else {
                return CircleApprovalRecord()
            }
            // Another device's record (restored from a backup), or one this
            // device never adopted: not this device's, so it confirms nobody
            // here — and the next write replaces it with one that is.
            guard let tag = deviceTag(), record.deviceTag == tag else { return CircleApprovalRecord() }
            // A circle an earlier build kept under other spellings too, not
            // folded yet or kept while one doesn't read (`foldCircleSpellings`).
            guard spellingsLeft() else { return record }
            return ApprovalRecordStore.effective(
                record, others: ApprovalRecordStore.otherSpellings(in: defaults, owner: owner, circleId: circleId), tag: tag)
        }
        // The legacy keys came with this device's records only if it adopted
        // them (`bindToThisDevice`); a restored backup's are nobody's.
        guard let tag = deviceTag(), defaults.string(forKey: ApprovalRecordStore.adoptedByKey) == tag else {
            return CircleApprovalRecord()
        }
        let legacy = ApprovalRecordStore.legacyKey(owner: owner, circleId: circleId)
        var record = CircleApprovalRecord()
        for userId in defaults.stringArray(forKey: legacy) ?? [] {
            record.entries[userId] = .preRound2Seed
        }
        return record
    }

    /// Writes the record as this device's. Nothing is written without the tag:
    /// an untagged record would never be read back.
    private func save(_ record: CircleApprovalRecord, owner: String, circleId: String) {
        guard let tag = deviceTag() else { return }
        var record = record
        record.deviceTag = tag
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key(owner: owner, circleId: circleId))
        // Out to the extension before the lock goes (`set` is asynchronous).
        defaults.synchronize()
    }

    /// Every change goes through here: read the record as it is NOW and write
    /// it back, holding the approvals lock, so a departure the extension wrote
    /// meanwhile is never lost. The extension holds it for milliseconds. Should
    /// it ever not come, nothing is written: a person's decision (`retry`) is
    /// queued and made at the next write or return to the foreground; a roster
    /// pass's is dropped, because the next pass decides again. Returns the
    /// record as it was before the change, or nil when nothing could be done.
    @discardableResult
    private func update(owner: String, circleId: String, retry: Bool = true,
                        _ change: @escaping (inout CircleApprovalRecord) -> Void) -> CircleApprovalRecord? {
        guard let lock, let held = lock.acquireBlocking(timeout: lockWait) else {
            if retry { pending.append((owner, circleId, change)) }
            return nil
        }
        defer { held.release() }
        drainPending()
        return apply(owner: owner, circleId: circleId, change)
    }

    /// Makes the queued writes, holding the lock (`update`, `retryPending`):
    /// a deferred wipe first, then the decisions in order.
    private func drainPending() {
        normalizeOwnersIfNeeded()
        if let keep = pendingClear {
            performClear(exceptOwner: keep)
            pendingClear = nil
        }
        if !pendingForget.isEmpty {
            performForget(pendingForget)
            pendingForget.removeAll()
        }
        let queued = pending
        pending.removeAll()
        for item in queued {
            apply(owner: item.owner, circleId: item.circleId, item.change)
        }
    }

    /// The queued writes, now, if the lock can be had (a return to the
    /// foreground). Whatever cannot be made stays queued.
    func retryPending() {
        guard hasPendingWrites, let lock, let held = lock.acquireBlocking(timeout: lockWait) else { return }
        defer { held.release() }
        drainPending()
    }

    /// Whether writes are waiting for the lock (tests, diagnostics).
    var hasPendingWrites: Bool { pendingClear != nil || !pendingForget.isEmpty || !pending.isEmpty }

    /// One change over the record as it is now. The caller holds the lock.
    @discardableResult
    private func apply(owner: String, circleId: String, _ change: (inout CircleApprovalRecord) -> Void)
        -> CircleApprovalRecord? {
        let stored = defaults.data(forKey: key(owner: owner, circleId: circleId))
        if let stored, (try? JSONDecoder().decode(CircleApprovalRecord.self, from: stored)) == nil {
            return nil  // a record this build cannot read is never overwritten
        }
        let current = record(owner: owner, circleId: circleId)
        var record = current
        change(&record)
        // Changed — or a legacy record, read from its old keys, stored at last.
        if record != current || (stored == nil && record != CircleApprovalRecord()) {
            save(record, owner: owner, circleId: circleId)
        }
        return current
    }

    // MARK: - The one-time transition seed

    /// Whether this account's one-time seed from existing pins has been taken
    /// on this device.
    func transitionSeedTaken(owner: String) -> Bool {
        defaults.bool(forKey: ApprovalRecordStore.transitionKey(owner: owner))
    }

    /// The one-time seed from the circle pins this device ALREADY held when this
    /// code first ran: a device updated from a version of the app that kept no
    /// approval record would otherwise show only itself in every circle, and
    /// every owner would be asked about each member. A circle with a record
    /// (legacy or current) is left alone; the pinned users of any other become
    /// its `seedCandidates`, and the FIRST COMPLETE roster decides
    /// (`CircleApprovalRecord.applySeed`): whom it lists become `.preRound2Seed`
    /// entries, the inherited residual included (a ghost pinned before the
    /// update and still listed stays trusted; it already had the circle); whom
    /// it does not list get nothing. Those pins can name people who left, were
    /// removed, or never joined (invitees are pinned at invite time).
    /// Taken ONCE per account: pins made after this are confirmations, never
    /// seeds. `pins` = circle id → the users pinned in it.
    @discardableResult
    func takeTransitionSeed(owner: String, pins: [String: Set<String>]) -> Int {
        // Without the lock nothing is seeded and the seed is NOT marked taken:
        // the next call takes it.
        guard !transitionSeedTaken(owner: owner), let lock, let held = lock.acquireBlocking(timeout: lockWait) else {
            return 0
        }
        defer { held.release() }
        var seeded = 0
        for (circleId, users) in pins {
            let members = users.filter { !CanonicalId.sameKey($0, owner) }
            guard !members.isEmpty, !hasRecord(owner: owner, circleId: circleId) else { continue }
            var record = CircleApprovalRecord()
            record.seedCandidates = Set(members)
            save(record, owner: owner, circleId: circleId)
            seeded += 1
        }
        defaults.set(true, forKey: ApprovalRecordStore.transitionKey(owner: owner))
        return seeded
    }

    /// Whether this device holds any record for the circle — a current one, or
    /// a legacy one still to migrate.
    private func hasRecord(owner: String, circleId: String) -> Bool {
        let legacy = ApprovalRecordStore.legacyKey(owner: owner, circleId: circleId)
        return defaults.object(forKey: key(owner: owner, circleId: circleId)) != nil
            || defaults.object(forKey: legacy) != nil
            || defaults.object(forKey: legacy + ".invited") != nil
    }

    // MARK: - Reading

    /// Everyone this device has confirmed in the circle, whatever the reason.
    /// A pending invitee is not a member yet: only appearing with its invitation
    /// makes them one.
    func approvedMembers(owner: String, circleId: String) -> Set<String> {
        Set(record(owner: owner, circleId: circleId).entries.keys)
    }

    func origin(owner: String, circleId: String, userId: String) -> ApprovalOrigin? {
        record(owner: owner, circleId: circleId).entries[userId]
    }

    // MARK: - Writing

    /// Record a confirmation. A stronger reason is never downgraded: a member
    /// this device's user chose stays chosen, and only an admission lifts a
    /// receive-only (kind-2) member. `keys` are a receive-only member's, kept
    /// the first time (they are never SDK pins).
    func approve(owner: String, circleId: String, userId: String,
                 origin: ApprovalOrigin = .ownAction, statementIds: [String] = [],
                 keys: MemberKeyPair? = nil) {
        update(owner: owner, circleId: circleId) { record in
            record.approve(userId: userId, origin: origin, statementIds: statementIds, keys: keys)
        }
        deferred.remove("\(circleId):\(userId)")
    }

    /// What a roster pass decided (`AccessHandover.rosterPass`: departures
    /// tombstoned, confirmations recorded, receive-only keys kept), stored as one
    /// change — never over a record this build cannot read. Its confirmations end
    /// any "Not now" on them, as `approve` does.
    ///
    /// MERGED, never overwritten: `base` is the record the pass started from,
    /// and the record as it is now may hold departures the notification
    /// extension saw meanwhile — those stay (`CircleApprovalRecord.merged`).
    /// Returns whether the record had changed since `base`: the pass decided
    /// without that change, and must decide again from the stored record.
    @discardableResult
    func store(_ passRecord: CircleApprovalRecord, base: CircleApprovalRecord, owner: String, circleId: String,
               confirmed: [String]) -> Bool {
        let current = update(owner: owner, circleId: circleId, retry: false) { current in
            current = CircleApprovalRecord.merged(ours: passRecord, base: base, theirs: current)
        }
        for userId in confirmed { deferred.remove("\(circleId):\(userId)") }
        guard var now = current else { return false }
        var then = base
        (now.deviceTag, then.deviceTag) = (nil, nil)
        return now != then
    }

    /// A receive-only member's keys, the first time this device sees both —
    /// confirmed before they had published a pair. Never replaces a pair it
    /// holds: a different one is a changed identity, asked about.
    func rememberReceiveOnlyKeys(owner: String, circleId: String, userId: String, keys: MemberKeyPair) {
        update(owner: owner, circleId: circleId, retry: false) { record in
            record.rememberReceiveOnlyKeys(userId: userId, keys: keys)
        }
    }

    /// "It's them" about a receive-only member: this device takes their new
    /// keys, still receive-only, now chosen here (this device only).
    func replaceReceiveOnlyKeys(owner: String, circleId: String, userId: String, keys: MemberKeyPair) {
        update(owner: owner, circleId: circleId) { record in
            guard record.entries[userId]?.isReceiveOnly == true else { return }
            record.entries[userId] = .ownKind2
            record.receiveOnlyKeys[userId] = keys
        }
    }

    /// An admission this device's user decided on is owed until it is signed.
    func oweAdmission(owner: String, circleId: String, userId: String) {
        update(owner: owner, circleId: circleId) { $0.admissionsOwed.insert(userId) }
    }

    func admissionSigned(owner: String, circleId: String, userId: String) {
        update(owner: owner, circleId: circleId) { $0.admissionsOwed.remove(userId) }
    }

    /// This device's user invited them to their account, with this statement.
    /// Kept apart from the entries until they appear on a roster with THAT
    /// invitation (`settleInvitees`).
    func approveInvitee(owner: String, circleId: String, userId: String, statementId: String, expiresAt: Int64) {
        update(owner: owner, circleId: circleId) {
            $0.recordInvitee(userId: userId, statementId: statementId, expiresAt: expiresAt)
        }
        deferred.remove("\(circleId):\(userId)")
    }

    /// A waiting change that signed statements ended. Every one of them but the
    /// one the server holds is dead here, and an invitation's held statement
    /// becomes this device's invitee record. True only when that reads back as
    /// stored: the change may be deleted only then, and is parked otherwise.
    /// Never queued for later, unlike a person's decision.
    func settleSignedStatements(owner: String, circleId: String, dead: [String],
                                invitee: (userId: String, statementId: String, expiresAt: Int64)?) -> Bool {
        let dead = Set(dead.map { $0.lowercased() })
        let written = update(owner: owner, circleId: circleId, retry: false) { record in
            record.deadStatementIds.formUnion(dead)
            if let invitee {
                record.recordInvitee(userId: invitee.userId, statementId: invitee.statementId,
                                     expiresAt: invitee.expiresAt)
            }
        }
        guard written != nil else { return false }
        if let invitee { deferred.remove("\(circleId):\(invitee.userId)") }
        let stored = record(owner: owner, circleId: circleId)
        guard stored.deadStatementIds.isSuperset(of: dead) else { return false }
        guard let invitee else { return true }
        return stored.invitees[CanonicalId.key(invitee.userId)]?.statementId == invitee.statementId.lowercased()
    }

    /// Withdrawn by this device's user: the record goes and the id is dead here
    /// — a server that lists the invitee with it again gets nothing.
    func withdrawInvitation(owner: String, circleId: String, statementId: String) {
        update(owner: owner, circleId: circleId) { $0.withdrawInvitation(statementId: statementId) }
    }

    /// The circle's pending invitations as the server lists them now: a record
    /// whose invitation is no longer among them goes (accepted, declined,
    /// expired or withdrawn elsewhere). Dropping trust only — no id is made dead.
    func keepPendingInvitations(owner: String, circleId: String, statementIds: Set<String>,
                                listedUsers: Set<String> = []) {
        update(owner: owner, circleId: circleId, retry: false) {
            $0.keepInvitees(pendingStatementIds: statementIds, listedUsers: listedUsers)
        }
    }

    /// A circle this device's user just created: its creator is its first entry.
    func recordCreatedCircle(owner: String, circleId: String) {
        approve(owner: owner, circleId: circleId, userId: owner, origin: .ownAction)
    }

    /// Against a COMPLETE roster: anyone who has left loses their entry and is
    /// TOMBSTONED with the statement ids they carried and the version this
    /// device held (`activeVersion`, nil when it holds none) — so neither they
    /// nor their statements come back on a server's say-so. A pending invitee
    /// is never tombstoned.
    func retain(owner: String, circleId: String, roster: Set<String>, activeVersion: Int?) {
        update(owner: owner, circleId: circleId, retry: false) { record in
            record.retain(roster: roster, activeVersion: activeVersion)
        }
    }

    /// This device's invitees against a roster (the roster pass does the same
    /// inside `AccessHandover.rosterPass`): `roster` maps each listed user id
    /// to the statement id of the invitation their row carries.
    func settleInvitees(owner: String, circleId: String, roster: [String: String?], now: Date = Date()) {
        update(owner: owner, circleId: circleId, retry: false) { record in
            record.settleInvitees(roster: roster, now: Int64(now.timeIntervalSince1970))
        }
    }

    /// The one-time seed against the first COMPLETE roster (the roster pass
    /// does the same inside `AccessHandover.rosterPass`).
    func applySeed(owner: String, circleId: String, roster: Set<String>) {
        update(owner: owner, circleId: circleId, retry: false) { $0.applySeed(roster: roster) }
    }

    func markBackfilled(owner: String, circleId: String, userId: String) {
        update(owner: owner, circleId: circleId) { $0.backfilled.insert(userId) }
    }

    // MARK: - The owners' and admins' question

    func deferredMembers(circleId: String) -> Set<String> {
        Set(deferred.compactMap { key -> String? in
            let prefix = "\(circleId):"
            return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        })
    }

    /// Queue a question unless it is already queued or was deferred.
    func ask(_ request: KeyDeliveryRequest) {
        guard !deferred.contains(request.id),
              !requests.contains(where: { $0.id == request.id }) else { return }
        requests.append(request)
        // Not only when someone happens to open the app.
        CircleQuestionNotifier.post(.join, circleId: request.circleId, userId: request.userId,
                                    name: request.displayName, circleName: request.circleName)
    }

    func isQueued(circleId: String, userId: String) -> Bool {
        requests.contains { $0.circleId == circleId && $0.userId == userId }
    }

    /// "Let them in": this device's user chose them.
    func letIn(_ request: KeyDeliveryRequest, owner: String) {
        approve(owner: owner, circleId: request.circleId, userId: request.userId, origin: .ownAction)
        requests.removeAll { $0.id == request.id }
        CircleQuestionNotifier.answered(.join, circleId: request.circleId, userId: request.userId)
    }

    /// Answered "Let them in", and the answer waits as a let-in change: the
    /// question goes, and nobody is approved until the change runs.
    func answered(_ request: KeyDeliveryRequest) {
        requests.removeAll { $0.id == request.id }
        CircleQuestionNotifier.answered(.join, circleId: request.circleId, userId: request.userId)
        Self.keepLateJoinerAnswer(request)
    }

    /// A waiting "Let them in" runs: this device's user chose them (as
    /// `letIn`), and any question still queued about them goes. True only
    /// when the choice reads back as stored: the change ends only then, since
    /// a choice lost here would leave nobody to hand them the circle after a
    /// rotation.
    func approveAnswer(owner: String, circleId: String, userId: String) -> Bool {
        approve(owner: owner, circleId: circleId, userId: userId, origin: .ownAction)
        requests.removeAll { $0.circleId == circleId && $0.userId == userId }
        return record(owner: owner, circleId: circleId).entries[userId]?.isChosen == true
    }

    /// The question is withdrawn without an answer, so the next pass asks it
    /// again about the keys the list shows then (a "Let them in" whose keys no
    /// longer hold, `CircleManager.letIn`).
    func askAgain(_ request: KeyDeliveryRequest) {
        requests.removeAll { $0.id == request.id }
        CircleQuestionNotifier.answered(.join, circleId: request.circleId, userId: request.userId)
    }

    /// "Not now": they stay out for this session. A late joiner's is the
    /// answer for good: never asked again about that invitation.
    func notNow(_ request: KeyDeliveryRequest) {
        deferred.insert(request.id)
        requests.removeAll { $0.id == request.id }
        CircleQuestionNotifier.answered(.join, circleId: request.circleId, userId: request.userId)
        Self.keepLateJoinerAnswer(request)
    }

    /// A late joiner's question answered, either way: kept against its
    /// invitation, so it is never asked again.
    /// `me` and `ledger`: the signed-in account's, unless a test gives them.
    static func keepLateJoinerAnswer(_ request: KeyDeliveryRequest, me: String? = nil, ledger: RefreshLedger? = nil) {
        guard case .lateJoiner(let ask) = request.reason, let me = me ?? AuthManager.shared.userId else { return }
        (ledger ?? .shared).noteLateJoinerAnswered(account: me, circleId: request.circleId, invitation: ask.invitation)
    }

    /// Sign-out: the questions name members of the signed-out account's
    /// circles. The records stay (a same-account sign-in keeps them); another
    /// account's go only by a sign-in's guarded tidy (`forget`).
    func reset() {
        requests.removeAll()
        deferred.removeAll()
    }

    /// The accounts with records here, each in its one form (a sign-in's
    /// guarded tidy).
    func owners() -> Set<String> {
        var found = Set<String>()
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in [Self.prefix, Self.legacyPrefix, Self.transitionPrefix] {
                if let owner = ApprovalRecordStore.owner(ofKey: key, prefix: prefix) {
                    found.insert(CanonicalId.key(String(owner)))
                }
            }
        }
        return found
    }

    /// A sign-in's guarded tidy (`SignInTidy`): these accounts' records go, the
    /// legacy ones and the one-time-seed marks included, and their queued
    /// changes with them. Everyone else's stay, queued changes too: their
    /// tombstones and dead ids hold against the server. Without the lock the
    /// deletion waits for it (`pendingForget`), and runs before anything else
    /// once it is had.
    func forget(owners: Set<String>) {
        let gone = Set(owners.map { CanonicalId.key($0) })
        guard !gone.isEmpty else { return }
        pending.removeAll { gone.contains(CanonicalId.key($0.owner)) }
        guard let lock, let held = lock.acquireBlocking(timeout: lockWait) else {
            pendingForget.formUnion(gone)
            return
        }
        defer { held.release() }
        normalizeOwnersIfNeeded()
        performForget(gone)
    }

    private func performForget(_ gone: Set<String>) {
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in [Self.prefix, Self.legacyPrefix, Self.transitionPrefix] {
                guard let found = ApprovalRecordStore.owner(ofKey: key, prefix: prefix),
                      gone.contains(CanonicalId.key(String(found))) else { continue }
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// An erasure: every account's records but `owner`'s (nil: all of them),
    /// the legacy ones and the one-time-seed marks included.
    ///
    /// Queued changes for anyone else go at once. Without the lock the wipe
    /// itself waits for it (`pendingClear`), and runs before anything else
    /// once it is had.
    func clearAll(exceptOwner owner: String?) {
        pending.removeAll { $0.owner != owner }
        guard let lock, let held = lock.acquireBlocking(timeout: lockWait) else {
            pendingClear = .some(owner)
            return
        }
        defer { held.release() }
        pendingClear = nil
        performClear(exceptOwner: owner)
    }

    /// Keeps `owner`'s keys, compared in their one form: the same account
    /// spelt another way is never taken for another's, whose tombstones and
    /// dead ids would go with it.
    private func performClear(exceptOwner owner: String?) {
        normalizeOwnersIfNeeded()
        let keep = owner.map { CanonicalId.key($0) }
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in [Self.prefix, Self.legacyPrefix, Self.transitionPrefix] {
                guard let found = ApprovalRecordStore.owner(ofKey: key, prefix: prefix) else { continue }
                if let keep, CanonicalId.key(String(found)) == keep { continue }
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Every owner and circle in the records' keys in its one form
    /// (`CanonicalId.key`), before any clear or compare; the caller holds the
    /// approvals lock. The app's alone: the extension writes nothing but
    /// departures.
    ///
    /// Owners first. A record under an owner spelt another way moves to the
    /// one form's key, or, when that key holds a record already, gives it its
    /// tombstones and dead statement ids, which only restrict, and nothing
    /// else; a record that doesn't read is never folded or dropped. The legacy
    /// keys move too; when both are there the one form's stays (a legacy key
    /// only grants). A transition mark is kept if either was set.
    ///
    /// Then circles (`foldCircleSpellings`). When every id is already in its
    /// one form, neither changes anything.
    static func normalizeOwners(in defaults: UserDefaults, tag: String?) {
        let (prefix, legacyPrefix, transitionPrefix) = (Self.prefix, Self.legacyPrefix, Self.transitionPrefix)
        for (key, value) in defaults.dictionaryRepresentation() {
            for keyPrefix in [prefix, legacyPrefix, transitionPrefix] {
                guard let owner = ApprovalRecordStore.owner(ofKey: key, prefix: keyPrefix),
                      owner != CanonicalId.key(String(owner))
                else { continue }
                let target = keyPrefix + CanonicalId.key(String(owner)) + key.dropFirst(keyPrefix.count + owner.count)
                if defaults.object(forKey: target) == nil {
                    defaults.set(value, forKey: target)
                } else if keyPrefix == prefix {
                    guard let data = value as? Data, let existing = defaults.data(forKey: target),
                          let from = try? JSONDecoder().decode(CircleApprovalRecord.self, from: data),
                          var into = try? JSONDecoder().decode(CircleApprovalRecord.self, from: existing)
                    else { continue }
                    into.foldRestrictions(of: from)
                    guard let merged = try? JSONEncoder().encode(into) else { continue }
                    defaults.set(merged, forKey: target)
                } else if keyPrefix == transitionPrefix, defaults.bool(forKey: key) {
                    defaults.set(true, forKey: target)
                }
                defaults.removeObject(forKey: key)
            }
        }
        foldCircleSpellings(in: defaults, tag: tag)
        defaults.synchronize()
    }

    /// A circle's records an earlier build kept under several spellings of its
    /// id (a hostile server's doing, before ids were taken in their one form)
    /// become one, under the one form's key. One spelling moves there. Several
    /// fold (`CircleApprovalRecord.folded`: whatever keeps someone out wins,
    /// and only this device's records grant), written under that key, and the
    /// others go only once it reads back. While any of them doesn't read,
    /// every spelling stays as it is. The legacy keys move as an owner's do:
    /// when both are there, the one form's stays.
    static func foldCircleSpellings(in defaults: UserDefaults, tag: String?) {
        var records: [String: [String]] = [:]
        var legacy: [String: [String]] = [:]
        for key in defaults.dictionaryRepresentation().keys {
            if let owner = ApprovalRecordStore.owner(ofKey: key, prefix: prefix),
               let (circle, rest) = ApprovalRecordStore.circle(ofKey: key, prefix: prefix), rest.isEmpty {
                records[ApprovalRecordStore.key(owner: String(owner), circleId: String(circle)), default: []].append(key)
            } else if let owner = ApprovalRecordStore.owner(ofKey: key, prefix: legacyPrefix),
                      let (circle, rest) = ApprovalRecordStore.circle(ofKey: key, prefix: legacyPrefix) {
                let target = ApprovalRecordStore.legacyKey(owner: String(owner), circleId: String(circle)) + rest
                legacy[target, default: []].append(key)
            }
        }
        for (target, keys) in records where keys.contains(where: { $0 != target }) {
            let spellings = keys.sorted { ($0 == target ? 0 : 1, $0) < ($1 == target ? 0 : 1, $1) }
            let decoded = spellings.map { key in
                defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CircleApprovalRecord.self, from: $0) }
            }
            guard !decoded.contains(where: { $0 == nil }) else { continue }
            let written: Data?
            if spellings.count == 1 {
                written = defaults.data(forKey: spellings[0])
            } else {
                let folded = CircleApprovalRecord.folded(
                    zip(spellings, decoded).map { (canonical: $0.0 == target, record: $0.1!) }, tag: tag)
                written = try? JSONEncoder().encode(folded)
            }
            guard let written else { continue }
            defaults.set(written, forKey: target)
            guard defaults.data(forKey: target) == written else { continue }
            for key in spellings where key != target { defaults.removeObject(forKey: key) }
        }
        for (target, keys) in legacy where keys.contains(where: { $0 != target }) {
            if defaults.object(forKey: target) == nil, let first = keys.sorted().first {
                defaults.set(defaults.object(forKey: first), forKey: target)
            }
            guard defaults.object(forKey: target) != nil else { continue }
            for key in keys where key != target { defaults.removeObject(forKey: key) }
        }
    }

    /// Whether any record here is under a circle spelt other than its one
    /// form: only then does a read look at a circle's other spellings. Found
    /// once, and again after each normalization; nothing here writes one.
    private var foundSpellingsLeft: Bool?
    private func spellingsLeft() -> Bool {
        if let foundSpellingsLeft { return foundSpellingsLeft }
        let found = defaults.dictionaryRepresentation().keys.contains { key in
            guard let owner = ApprovalRecordStore.owner(ofKey: key, prefix: Self.prefix),
                  let (circle, rest) = ApprovalRecordStore.circle(ofKey: key, prefix: Self.prefix), rest.isEmpty
            else { return false }
            return ApprovalRecordStore.key(owner: String(owner), circleId: String(circle)) != key
        }
        foundSpellingsLeft = found
        return found
    }

    /// `normalizeOwners(in:tag:)`, once per process, before any
    /// clear or compare; the caller holds the lock.
    private var ownersNormalized = false
    private func normalizeOwnersIfNeeded() {
        guard !ownersNormalized else { return }
        Self.normalizeOwners(in: defaults, tag: deviceTag())
        foundSpellingsLeft = nil
        ownersNormalized = true
    }

    /// The owner-case move at launch and on a return to the foreground, if the
    /// lock can be had: before any sign-in reads or clears a record.
    func normalizeOwners() {
        guard !ownersNormalized, let lock, let held = lock.acquireBlocking(timeout: lockWait) else { return }
        defer { held.release() }
        normalizeOwnersIfNeeded()
    }

    /// The question. Static so a test can pin the words.
    static func title(for request: KeyDeliveryRequest) -> String {
        "Let \(request.displayName) into \(request.circleName)?"
    }

    static func question(for request: KeyDeliveryRequest, device: String = DeviceNoun.current) -> String {
        let who = request.email.map { "\(request.displayName) (\($0))" } ?? request.displayName
        switch request.reason {
        case .unconfirmedInviter:
            let number = request.number.map { " Their number: \($0)." } ?? ""
            return "\(who) was invited by someone this \(device) can't confirm. If you're not sure it's them, check with \(request.displayName) another way first.\(number)"
        case .lateJoiner(let ask):
            return LateJoiner.body(ask)
        }
    }
}

/// Presents `KeyDeliveryApprovals.requests.first` at the app root — the legacy
/// question, only ever queued on an owner's or admin's device — after any
/// "Is this really {name}?" question (those go first).
struct KeyDeliveryPromptHost: ViewModifier {
    @StateObject private var approvals = KeyDeliveryApprovals.shared
    @StateObject private var pinner = MemberKeyPinner.shared
    /// Nothing over App Lock: the question waits for the unlock.
    @SwiftUI.Environment(\.appLocked) private var appLocked

    private var current: KeyDeliveryRequest? {
        pinner.alerts.isEmpty ? approvals.requests.first : nil
    }

    func body(content: Content) -> some View {
        content.alert(
            current.map(KeyDeliveryApprovals.title(for:)) ?? "",
            isPresented: Binding(
                get: { !appLocked && current != nil },
                set: { _ in }  // resolved by the buttons
            ),
            presenting: current
        ) { request in
            Button("Not now", role: .cancel) { approvals.notNow(request) }
            Button("Let them in") { CircleManager.shared.letIn(request) }
        } message: { request in
            Text(KeyDeliveryApprovals.question(for: request))
        }
    }
}

extension DeviceTag {
    /// A new random tag in a ThisDeviceOnly keychain item (the app's alone: the
    /// notification extension only reads it). nil if the keychain refused it.
    static func create() -> String? {
        let tag = UUID().uuidString.lowercased()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(tag.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Only a tag made HERE adopts anything: one that already existed
        // (errSecDuplicateItem) is nil, so a record is never stamped with it.
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? tag : nil
    }

    /// Whether the keychain still holds items only THIS device can have: its
    /// own key material, kept ThisDeviceOnly — an app update keeps it, a backup
    /// restored onto another phone never carries it.
    static func keychainHoldsThisDevicesOwnItems() -> Bool {
        for itemService in ["com.pingolin.track.sdk.cryptomanager", "com.pingolin.track.retained-member-pins"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: itemService,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnAttributes as String: true,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess { return true }
        }
        return KeychainService.shared.getString(for: .sharingPrivateKey) != nil
    }
}
