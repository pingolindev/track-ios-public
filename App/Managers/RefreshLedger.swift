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

/// What this device's person did that a circle's refresh records don't carry
/// yet, and the repair budget.
///
/// One JSON file per account in Application Support, written as the waiting
/// changes are (`PendingChangeStore`): protected until first unlock and
/// excluded from backup. A write that fails says so. A file that is there but
/// can't be read (`StoredFile`) is never written over, and nothing it decides
/// runs until it reads (`isReadable`). Wiped with the account's data
/// (`AuthManager.purgeAccountData`).
@MainActor
final class RefreshLedger {
    static let shared = RefreshLedger()

    /// A repair at most once an hour per circle.
    static let repairSpacing: TimeInterval = 3600

    /// A removal this device's person made, and when.
    struct Removal: Codable, Equatable {
        var userId: String
        var at: Date
    }

    /// The owner's hand-over this device sent and hasn't seen done: the member
    /// its record names owner, and their keys as this device held them at the
    /// tap, the only ones a record built again may name.
    struct HandOver: Codable, Equatable {
        var target: String
        var sharingKeyHex: String
        var signingKeyHex: String
    }

    /// A removal a re-invitation from this device cleared.
    struct Cleared: Codable, Equatable {
        var removal: Removal
        /// The invitation's end (`settleRunOutReInvites`).
        var until: Date
    }

    struct Circle: Codable, Equatable {
        /// Members this device's person removed that the chain doesn't carry
        /// yet (a revoke, or a removal while behind): named "removed" in this
        /// device's next rotation, whatever the server's flag says, unless this
        /// account changed its mind since (`removalsStanding`).
        var removals: [Removal] = []
        /// Role changes this device's person made as the chain's owner, by user
        /// id: its next rotation writes them.
        var roleChanges: [String: String] = [:]
        /// Versions rejected here on an earlier pass: a repair waits one roster
        /// pass.
        var rejectedSeen: [Int32] = []
        /// Versions this device repaired: each at most once.
        var repaired: [Int32] = []
        /// This device's last repair of the circle.
        var lastRepairAt: Date?
        /// This device's own repairs: its record's version (as text) → the
        /// members the version it repaired was rejected for.
        var repairs: [String: [String]] = [:]
        /// The late-joiner invitations this device answered, "Not now"
        /// included: never asked again (once per invitation).
        var lateJoinerAnswered: [LateJoiner.Invitation] = []
        /// This device's re-invitations that cleared a removal, by statement
        /// id. One this device withdraws brings the removal back, and so does
        /// one that runs out while the member isn't on the complete list.
        /// Used, the removal stays cleared.
        var clearedByInvitations: [String: Cleared] = [:]
        /// This device's hand-over of the circle, from before it was sent until
        /// the circle reads back the member it names as its owner.
        var handOver: HandOver?
    }

    /// A change to the removals, or to the owed role changes (`role`; nil
    /// takes one back), as `apply` makes it.
    private enum RemovalChange {
        case noted(Removal)
        case cleared(userId: String, before: Date, invitation: (statementId: String, until: Date)?)
        case withdrawn(statementId: String)
        case ranOut(listed: Set<String>, at: Date)
        case role(userId: String, role: String?)
    }

    private let directory: URL?
    private var account: String?
    private var circles: [String: Circle] = [:]
    /// The account's file is there but couldn't be read: nothing is written
    /// over it, and it's read again at the next use.
    private var unreadable = false
    /// Changes to the removals (and owed roles) this session made that the
    /// file couldn't take (it didn't read, or the write failed), per account,
    /// by circle, in order. They hold all the same: a removal is never lost to
    /// a departure. Made on what the file holds at every read, and written
    /// with the next write that succeeds or as soon as the file reads again; a
    /// relaunch before that loses them. Another account signing in keeps them,
    /// as it keeps the file: only a sign-in's guarded tidy (`forget`) or an
    /// erasure takes them.
    private var unwritten: [String: [(circle: String, change: RemovalChange)]] = [:]

    /// The loaded account's unwritten changes.
    private var unwrittenHere: [(circle: String, change: RemovalChange)] {
        get { account.flatMap { unwritten[$0] } ?? [] }
        set { if let account { unwritten[account] = newValue.isEmpty ? nil : newValue } }
    }

    /// `directory` nil = Application Support/Refresh. Tests pass a scratch one.
    init(directory: URL? = nil) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("Refresh", isDirectory: true) }
    }

    func circle(account: String, circleId: String) -> Circle {
        use(account: account)
        let key = CanonicalId.key(circleId)
        var entry = circles[key] ?? Circle()
        for kept in unwrittenHere where kept.circle == key { Self.apply(kept.change, to: &entry) }
        return entry
    }

    /// Change one circle's entry; false (and nothing changed) when it can't be
    /// written. The session's unwritten changes go in with it.
    @discardableResult
    func update(account: String, circleId: String, _ change: (inout Circle) -> Void) -> Bool {
        use(account: account)
        guard !unreadable else { return false }
        let key = CanonicalId.key(circleId)
        let before = circles
        var entries = withUnwritten(circles)
        var entry = entries[key] ?? Circle()
        change(&entry)
        entries[key] = entry == Circle() ? nil : entry
        circles = entries
        guard save() else {
            circles = before
            return false
        }
        unwrittenHere = []
        return true
    }

    /// An erasure: every account's file goes.
    func wipeAll() {
        circles = [:]
        account = nil
        unreadable = false
        unwritten = [:]
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// This account signs out (`AuthManager.purgeAccountData`). Its file is
    /// kept, so what it still owes a record for (a removal above all) is named
    /// at its next sign-in here; left out, a record would show that member
    /// departed, which a server undoes by listing them again (as on Android
    /// and the web). What this session couldn't write goes in if the file
    /// takes it now; else it stays in memory for the account, as it would
    /// across another account's sign-in, until a relaunch.
    func signedOut() {
        if let account {
            use(account: account)
            flush()
        }
        (circles, account, unreadable) = ([:], nil, false)
    }

    /// The accounts with a file here, or with changes their file couldn't
    /// take yet, each by its key (a sign-in's guarded tidy). A listing that
    /// fails names none.
    func accounts() -> Set<String> {
        Set(unwritten.keys).union(storedFiles().map { CanonicalId.key($0.deletingPathExtension().lastPathComponent) })
    }

    private func storedFiles() -> [URL] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
    }

    /// A sign-in's guarded tidy (`SignInTidy`): this account's file goes,
    /// under any spelling of its id, and what its sessions couldn't write.
    func forget(account: String) {
        let gone = CanonicalId.key(account)
        for stored in unwritten.keys where CanonicalId.key(stored) == gone { unwritten[stored] = nil }
        if let loaded = self.account, CanonicalId.key(loaded) == gone {
            (circles, self.account, unreadable) = ([:], nil, false)
        }
        for file in storedFiles() where CanonicalId.key(file.deletingPathExtension().lastPathComponent) == gone {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Owe a role change this device's person made as the chain's owner, for
    /// its next rotation to write; `role` nil takes an owed one back. False
    /// when the file can't take it: it's kept for this session then, as a
    /// removal is. Roles reach the other apps only through that record.
    @discardableResult
    func noteRoleChange(account: String, circleId: String, userId: String, role: String?) -> Bool {
        make(.role(userId: userId, role: role), account: account, circleId: circleId)
    }

    /// Keep the owner's hand-over, before it is sent. False when the file
    /// can't take it, and then nothing is sent: unlike a removal, a hand-over
    /// is never kept for the session only.
    @discardableResult
    func noteHandOver(account: String, circleId: String, _ handOver: HandOver) -> Bool {
        update(account: account, circleId: circleId) { $0.handOver = handOver }
    }

    /// The hand-over is done, or stops.
    @discardableResult
    func clearHandOver(account: String, circleId: String) -> Bool {
        update(account: account, circleId: circleId) { $0.handOver = nil }
    }

    /// Every hand-over `account` keeps, by circle key.
    func handOvers(account: String) -> [String: HandOver] {
        use(account: account)
        return circles.compactMapValues(\.handOver)
    }

    /// Remember a removal this device's person made (again: the newer time).
    /// False when the file can't take it: it's kept for this session then.
    @discardableResult
    func noteRemoval(account: String, circleId: String, userId: String, at: Date) -> Bool {
        make(.noted(Removal(userId: userId, at: at)), account: account, circleId: circleId)
    }

    /// This device's person re-invited or let in someone it had removed,
    /// deciding at `decidedAt`: its pending removal of them goes, if it was
    /// made before that decision.
    /// `invitation`: the re-invitation's statement, if it was one; withdrawn
    /// from here, it brings the removal back (`invitationWithdrawn`).
    /// While the file can't be read, what it holds isn't known: the clear is
    /// kept for the session and made on it once it reads. Only an account's
    /// id takes a removal back (`CanonicalId.same`).
    @discardableResult
    func clearRemoval(account: String, circleId: String, userId: String, decidedAt: Date,
                      invitation: MembershipStatement? = nil) -> Bool {
        if isReadable(account: account), !circle(account: account, circleId: circleId).removals.contains(where: {
            CanonicalId.same($0.userId, userId) && $0.at < decidedAt
        }) { return true }
        let made = invitation.map {
            (statementId: $0.statementId.lowercased(), until: Date(timeIntervalSince1970: TimeInterval($0.expiresAt)))
        }
        return make(.cleared(userId: userId, before: decidedAt, invitation: made), account: account, circleId: circleId)
    }

    /// This device's person withdrew an invitation, unused: a removal it
    /// cleared is noted again, as it was. Kept for the session, as a clear
    /// is, while the file can't be read.
    @discardableResult
    func invitationWithdrawn(account: String, circleId: String, statementId: String) -> Bool {
        let id = statementId.lowercased()
        if isReadable(account: account), circle(account: account, circleId: circleId).clearedByInvitations[id] == nil {
            return true
        }
        return make(.withdrawn(statementId: id), account: account, circleId: circleId)
    }

    /// At a plan, with the complete member list: this device's re-invitations
    /// that ran out unused bring back the removal they cleared, as it was,
    /// unless the member is on the list (they joined with it, or came back
    /// otherwise): then it stays cleared. Either way the entry goes. Listed
    /// means an account's id (`CanonicalId.same`).
    @discardableResult
    func settleRunOutReInvites(account: String, circleId: String, listed: Set<String>, now: Date) -> Bool {
        guard circle(account: account, circleId: circleId).clearedByInvitations.values.contains(where: {
            $0.until <= now
        }) else { return true }
        return make(.ranOut(listed: Set(listed.compactMap { CanonicalId.of($0) }), at: now),
                    account: account, circleId: circleId)
    }

    /// Make a change to the removals (or an owed role) on the file; one the
    /// file can't take is kept for this session (`unwritten`).
    private func make(_ change: RemovalChange, account: String, circleId: String) -> Bool {
        if update(account: account, circleId: circleId, { Self.apply(change, to: &$0) }) { return true }
        unwritten[CanonicalId.key(account), default: []].append((circle: CanonicalId.key(circleId), change: change))
        return false
    }

    private static func apply(_ change: RemovalChange, to entry: inout Circle) {
        // The ledger's own entry for a member: one removal per member key, and
        // it stands either way (`CanonicalId.sameKey`).
        func isOf(_ userId: String) -> (Removal) -> Bool {
            { CanonicalId.sameKey($0.userId, userId) }
        }
        // Taking a removal back: only an account's id (`CanonicalId.same`).
        func isSubject(_ userId: String) -> (Removal) -> Bool {
            { CanonicalId.same($0.userId, userId) }
        }
        // A removal a re-invite cleared, back as it was: a later removal of
        // them stays as it is.
        func noteAgain(_ removal: Removal) {
            if let index = entry.removals.firstIndex(where: isOf(removal.userId)) {
                if entry.removals[index].at < removal.at { entry.removals[index] = removal }
            } else {
                entry.removals.append(removal)
            }
        }
        switch change {
        case .noted(let removal):
            entry.removals.removeAll(where: isOf(removal.userId))
            entry.removals.append(removal)
        case let .cleared(userId, before, invitation):
            let cleared = entry.removals.filter { isSubject(userId)($0) && $0.at < before }
            guard let newest = cleared.max(by: { $0.at < $1.at }) else { return }
            entry.removals.removeAll { isSubject(userId)($0) && $0.at < before }
            if let invitation {
                entry.clearedByInvitations[invitation.statementId] = Cleared(removal: newest, until: invitation.until)
            }
        case .withdrawn(let statementId):
            guard let cleared = entry.clearedByInvitations.removeValue(forKey: statementId) else { return }
            noteAgain(cleared.removal)
        case let .ranOut(listed, at):
            for (statementId, cleared) in entry.clearedByInvitations where cleared.until <= at {
                entry.clearedByInvitations.removeValue(forKey: statementId)
                if CanonicalId.of(cleared.removal.userId).map(listed.contains) != true { noteAgain(cleared.removal) }
            }
        case let .role(userId, role):
            entry.roleChanges[CanonicalId.key(userId)] = role
        }
    }

    /// Pure: the owed role changes once the server took a record that carried
    /// `taken` (member → role): each leaves only while the ledger still holds
    /// that SAME role. A change made while the record was on its way stays, to
    /// be written by the next one (a lost demotion fails unsafe).
    nonisolated static func settling(_ owed: [String: String], taken: [String: String]) -> [String: String] {
        owed.filter { userId, role in
            !taken.contains { CanonicalId.sameKey($0.key, userId) && $0.value == role }
        }
    }

    /// `entries` with the loaded account's unwritten changes made on them, in
    /// order.
    private func withUnwritten(_ entries: [String: Circle]) -> [String: Circle] {
        var entries = entries
        for kept in unwrittenHere {
            var entry = entries[kept.circle] ?? Circle()
            Self.apply(kept.change, to: &entry)
            entries[kept.circle] = entry == Circle() ? nil : entry
        }
        return entries
    }

    /// Pure: the removals that still stand. A removal made while behind stands
    /// at this device's next rotation, even after someone re-invited the member
    /// (over-removal is undone by one more invitation; under-removal leaks),
    /// except when THIS ACCOUNT changed its mind since: a newer statement
    /// about them IN THIS CIRCLE, signed by this account and verified under its
    /// CURRENT key (another of its devices), and not one this account withdrew,
    /// clears it. Another admin's does not, nor one from another circle. What
    /// clears one names this circle, this account and the member by their ids
    /// (`CanonicalId.same`): nothing that isn't an id clears anything.
    /// `statements`: each member's statements as the roster serves them.
    /// `dead`: the statement ids dead here (withdrawn, or a departed member's).
    nonisolated static func removalsStanding(_ removals: [Removal], me: String, circleId: String,
                                             statements: [String: [SignedStatementRecord]], dead: Set<String>,
                                             checker: MembershipStatementChecking) -> [Removal] {
        let dead = Set(dead.map { $0.lowercased() })
        return removals.filter { removal in
            let about = statements.first { CanonicalId.same($0.key, removal.userId) }?.value ?? []
            return !about.contains { record in
                guard let statement = try? checker.parse(record.statementHex),
                      CanonicalId.same(statement.circleId, circleId),
                      !dead.contains(statement.statementId.lowercased()),
                      CanonicalId.same(statement.signerUserId, me),
                      CanonicalId.same(statement.subjectUserId, removal.userId),
                      Double(statement.issuedAt) > removal.at.timeIntervalSince1970 else { return false }
                return checker.ownSigner(statementHex: record.statementHex, signatureHex: record.signatureHex) == .currentKey
            }
        }
    }

    /// A late-joiner question answered here, "Not now" included.
    @discardableResult
    func noteLateJoinerAnswered(account: String, circleId: String, invitation: LateJoiner.Invitation) -> Bool {
        update(account: account, circleId: circleId) { entry in
            if !entry.lateJoinerAnswered.contains(where: { $0.isSame(as: invitation) }) {
                entry.lateJoinerAnswered.append(invitation)
            }
        }
    }

    // MARK: - The repair budget

    /// Pure: whether this device repairs a version rejected here now. Only on
    /// a later pass than the one that first saw it rejected (its member list
    /// may have been catching up), at most once per version, at most once an
    /// hour per circle, and never the successor of this device's own repair
    /// rejected for the same member again (two devices with different views
    /// must not ping-pong; `rejectedFor`).
    nonisolated static func mayRepair(_ status: RecordVersionStatus, circle: Circle, now: Date,
                                      uncountedNamed: [String] = []) -> Bool {
        guard circle.rejectedSeen.contains(status.version), !circle.repaired.contains(status.version) else {
            return false
        }
        if let last = circle.lastRepairAt, now.timeIntervalSince(last) < repairSpacing { return false }
        if let before = circle.repairs[String(status.version - 1)] {
            let again = Set(before.map { CanonicalId.key($0) })
            if rejectedFor(status, uncountedNamed: uncountedNamed).contains(where: again.contains) { return false }
        }
        return true
    }

    /// Pure: the members a version was rejected here for, as the ping-pong
    /// stop compares them: those the SDK's eligibility rule refused
    /// (`notAllowed`), and the listed members the rejected tip names whom the
    /// chain doesn't count here (`uncountedNamed`: the report has no id for
    /// those nobody here matched). Each by its key (`CanonicalId.key`).
    nonisolated static func rejectedFor(_ status: RecordVersionStatus, uncountedNamed: [String]) -> [String] {
        Set((status.notAllowed + uncountedNamed).map { CanonicalId.key($0) }).sorted()
    }

    /// Pure: the rejected versions seen after this pass: those still rejected
    /// here, and no others.
    nonisolated static func rejectedSeen(after versions: [RecordVersionStatus]) -> [Int32] {
        RecordedRotation.repairable(versions).map(\.version).sorted()
    }

    // MARK: - Storage

    /// Whether this account's file could be read (or there is none): until it
    /// can, what it holds isn't known, and nothing it decides runs.
    func isReadable(account: String) -> Bool {
        use(account: account)
        return !unreadable
    }

    private func use(account: String) {
        let account = CanonicalId.key(account)
        guard self.account != account || unreadable else { return }
        self.account = account
        switch StoredFile<[String: Circle]>.read(fileURL(account: account)) {
        case .missing:
            (circles, unreadable) = ([:], false)
        case .loaded(let stored):
            (circles, unreadable) = (Self.folded(stored), false)
        case .unreadable:
            (circles, unreadable) = ([:], true)
        }
        // What this session couldn't write goes in as soon as the file reads.
        flush()
    }

    /// The file's circles by their key (`CanonicalId.key`), each circle's
    /// members by theirs. Entries kept under several spellings of an id
    /// (written before ids were taken in their one form, or a hostile
    /// server's doing) fold into one, and the next write keeps that. Whatever
    /// keeps someone out wins; nothing is capped; folding again gives the
    /// same; an entry with nothing to fold is left exactly as it is.
    /// - Removals: every member's, under every spelling, at the later time: a
    ///   removal pending under any stays pending, whatever another cleared.
    /// - Role changes: where two differ, the one with the least authority
    ///   (member, then admin, then owner); a role the SDK doesn't know never
    ///   wins. A demotion is never dropped. The trade-off: one a later
    ///   promotion superseded may be carried again, and the owner can promote
    ///   once more.
    /// - Versions rejected and repaired, and late joiners answered: all of
    ///   them; the latest repair.
    /// - A repair's members and what a re-invitation cleared: the canonical
    ///   spelling's where two hold one.
    nonisolated static func folded(_ stored: [String: Circle]) -> [String: Circle] {
        var spellings: [String: [String]] = [:]
        for circleId in stored.keys { spellings[CanonicalId.key(circleId), default: []].append(circleId) }
        var result: [String: Circle] = [:]
        for (key, ids) in spellings {
            let ordered = ids.sorted { ($0 == key ? 0 : 1, $0) < ($1 == key ? 0 : 1, $1) }
            let entries = ordered.compactMap { stored[$0] }
            if ordered == [key], let entry = entries.first, !namesAMemberTwice(entry) {
                result[key] = entry
            } else {
                result[key] = fold(entries)
            }
        }
        return result
    }

    /// Whether an entry keeps a member's removal or role change under two
    /// spellings of their id.
    private nonisolated static func namesAMemberTwice(_ entry: Circle) -> Bool {
        func twice(_ ids: [String]) -> Bool { Set(ids.map { CanonicalId.key($0) }).count != ids.count }
        return twice(entry.removals.map(\.userId)) || twice(Array(entry.roleChanges.keys))
    }

    /// `entries`, the canonical spelling's first, as one.
    private nonisolated static func fold(_ entries: [Circle]) -> Circle {
        var folded = Circle()
        func member(_ id: String) -> String { CanonicalId.key(id) }
        func appendingNew<T: Equatable>(_ list: inout [T], _ items: [T]) {
            for item in items where !list.contains(item) { list.append(item) }
        }
        var removals: [String: Removal] = [:]
        var order: [String] = []
        var roles: [String: [String]] = [:]
        for entry in entries {
            for removal in entry.removals {
                let id = member(removal.userId)
                if let had = removals[id] {
                    if removal.at > had.at { removals[id] = Removal(userId: id, at: removal.at) }
                } else {
                    order.append(id)
                    removals[id] = Removal(userId: id, at: removal.at)
                }
            }
            for (userId, role) in entry.roleChanges { roles[member(userId), default: []].append(role) }
            appendingNew(&folded.rejectedSeen, entry.rejectedSeen)
            appendingNew(&folded.repaired, entry.repaired)
            if let at = entry.lastRepairAt, at > (folded.lastRepairAt ?? .distantPast) { folded.lastRepairAt = at }
            for (version, members) in entry.repairs where folded.repairs[version] == nil {
                folded.repairs[version] = members.map(member)
            }
            for invitation in entry.lateJoinerAnswered
            where !folded.lateJoinerAnswered.contains(where: { $0.isSame(as: invitation) }) {
                folded.lateJoinerAnswered.append(invitation)
            }
            for (statementId, cleared) in entry.clearedByInvitations where folded.clearedByInvitations[statementId] == nil {
                folded.clearedByInvitations[statementId] = Cleared(
                    removal: Removal(userId: member(cleared.removal.userId), at: cleared.removal.at), until: cleared.until)
            }
            if folded.handOver == nil, let handOver = entry.handOver {
                folded.handOver = HandOver(target: member(handOver.target), sharingKeyHex: handOver.sharingKeyHex,
                                           signingKeyHex: handOver.signingKeyHex)
            }
        }
        folded.removals = order.compactMap { removals[$0] }
        folded.roleChanges = roles.compactMapValues(leastAuthority)
        return folded
    }

    /// Of the role changes two spellings hold for one member, the one with
    /// the least authority; nil when none is a role the SDK knows.
    private nonisolated static func leastAuthority(_ roles: [String]) -> String? {
        let order = ["member", "admin", "owner"]
        return roles.compactMap { order.firstIndex(of: $0) }.min().map { order[$0] }
    }

    /// Writes what this session couldn't, if the file takes it now.
    private func flush() {
        guard !unreadable, !unwrittenHere.isEmpty else { return }
        let stored = circles
        circles = withUnwritten(stored)
        if save() { unwrittenHere = [] } else { circles = stored }
    }

    private func fileURL(account: String) -> URL? {
        directory?.appendingPathComponent("\(CanonicalId.key(account)).json", isDirectory: false)
    }

    private func save() -> Bool {
        guard let account, let url = fileURL(account: account) else { return false }
        guard let data = try? JSONEncoder().encode(circles) else { return false }
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return false
        }
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
        return true
    }
}

extension RefreshLedger.Circle {
    /// Every field optional on the way in, so an entry written by an earlier
    /// version still reads: one that didn't would leave the whole file
    /// unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removals = try c.decodeIfPresent([RefreshLedger.Removal].self, forKey: .removals) ?? []
        roleChanges = try c.decodeIfPresent([String: String].self, forKey: .roleChanges) ?? [:]
        rejectedSeen = try c.decodeIfPresent([Int32].self, forKey: .rejectedSeen) ?? []
        repaired = try c.decodeIfPresent([Int32].self, forKey: .repaired) ?? []
        lastRepairAt = try c.decodeIfPresent(Date.self, forKey: .lastRepairAt)
        repairs = try c.decodeIfPresent([String: [String]].self, forKey: .repairs) ?? [:]
        lateJoinerAnswered = try c.decodeIfPresent([LateJoiner.Invitation].self, forKey: .lateJoinerAnswered) ?? []
        clearedByInvitations = try c.decodeIfPresent([String: RefreshLedger.Cleared].self,
                                                     forKey: .clearedByInvitations) ?? [:]
        handOver = try c.decodeIfPresent(RefreshLedger.HandOver.self, forKey: .handOver)
    }
}
