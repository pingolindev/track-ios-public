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

/// This account's waiting changes and the lines of the ones dropped, kept on
/// this device only.
///
/// One JSON file per account in Application Support, written with the same
/// options as the map's saved position: protected until first unlock (the
/// runner works in the background too) and excluded from backup. Not
/// `CacheStore`: `Library/Caches` may be emptied by iOS. Not UserDefaults: a
/// plain property list that goes into backups. Every access goes through the
/// main actor, and the notification extension never reads it (it has no need).
///
/// Wiped at sign-out and on an account switch (`AuthManager.purgeAccountData`);
/// kept across a session expiry, so the same person signing back in finds their
/// changes still waiting. A file that is there but can't be read (`StoredFile`:
/// protected until the first unlock after a restart, when the runner may wake
/// in the background, or damaged) is never written over or deleted, and it is
/// read again at the next use.
@MainActor
final class PendingChangeStore: ObservableObject {
    static let shared = PendingChangeStore()

    /// At most this many waiting changes per circle and per account.
    static let maxPerCircle = 20
    static let maxPerAccount = 100
    /// Two identical taps this close together are one tap.
    static let sameTapWindow: TimeInterval = 2

    /// The loaded account's changes, oldest first.
    @Published private(set) var changes: [PendingChange] = []
    @Published private(set) var notices: [DroppedNotice] = []
    private(set) var account: String?
    /// The account's file is there but couldn't be read: nothing is written
    /// over it.
    private(set) var unreadable = false

    private let directory: URL?

    /// `directory` nil = Application Support/PendingChanges. Tests pass a
    /// scratch directory.
    init(directory: URL? = nil) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("PendingChanges", isDirectory: true) }
    }

    private struct Stored: Codable {
        var account: String
        var changes: [PendingChange]
        var notices: [DroppedNotice]
    }

    func fileURL(account: String) -> URL? {
        directory?.appendingPathComponent("\(CanonicalId.key(account)).json", isDirectory: false)
    }

    /// Load `account`'s file, unless it is the one loaded. A change found
    /// `running` was cut off mid-send (a crash, a kill): it goes back through
    /// the re-check, and it may have gone out.
    func use(account: String) {
        let account = CanonicalId.key(account)
        guard self.account != account || unreadable else { return }
        let read = StoredFile<Stored>.read(fileURL(account: account))
        // Still unreadable: what this session holds stays as it is.
        if case .unreadable = read, self.account == account { return }
        self.account = account
        var stored: Stored?
        switch read {
        case .missing:
            unreadable = false
        case .loaded(let value):
            stored = value
            unreadable = false
        case .unreadable:
            unreadable = true
            PendingChangeRunner.log.error("waiting changes: this account's file couldn't be read; nothing is written over it")
        }
        if stored?.account != account { stored = nil }
        changes = (stored?.changes ?? []).map { change in
            var change = change
            if case .running = change.state {
                change.state = .waiting
                change.mayHaveGoneOut = true
            }
            return change
        }
        notices = stored?.notices ?? []
    }

    /// Whether this account's changes are on disk as they are in memory now.
    @discardableResult
    private func save() -> Bool {
        guard !unreadable, let account, let url = fileURL(account: account) else { return false }
        if changes.isEmpty && notices.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard let data = try? JSONEncoder().encode(Stored(account: account, changes: changes, notices: notices)) else {
            return false
        }
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

    /// Sign-out and account switch: every account's changes and lines go.
    func wipeAll() {
        changes = []
        notices = []
        account = nil
        unreadable = false
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Reading

    /// A circle's changes still shown as pending, oldest first. Every circle
    /// compare here is by its key (`CanonicalId.sameKey`): the store's own.
    func pending(circleId: String) -> [PendingChange] {
        changes.filter { CanonicalId.sameKey($0.circleId, circleId) && $0.isPending }
    }

    /// Every change of a circle, `settling` included, oldest first.
    func all(circleId: String) -> [PendingChange] {
        changes.filter { CanonicalId.sameKey($0.circleId, circleId) }
    }

    func change(id: String) -> PendingChange? { changes.first { $0.id == id } }

    /// The circles with anything to run, the one with the oldest change first.
    var circlesWithWork: [String] {
        var seen = Set<String>()
        return changes.sorted { $0.createdAt < $1.createdAt }.compactMap { change in
            seen.insert(CanonicalId.key(change.circleId)).inserted ? change.circleId : nil
        }
    }

    var pendingCount: Int { changes.filter(\.isPending).count }

    func notices(circleId: String) -> [DroppedNotice] {
        notices.filter { CanonicalId.sameKey($0.circleId, circleId) }
    }

    // MARK: - Queuing

    enum QueueResult: Equatable {
        case queued(PendingChange)
        /// Merged into the change already waiting for the same target.
        case merged(PendingChange)
        /// Refused at once, nothing queued.
        case tooMany
    }

    /// Queue a change, merging it into one already waiting for the same target.
    /// A merge never touches `signedIds`: the ids a change already signed stay
    /// with it until it ends. While the change has never gone out, it restarts
    /// the age limit from the new tap: the later of the two limits, and never
    /// past what the new tap allows (`PendingChanges.make` caps a tap at an
    /// expiry it is given, such as an invitation's).
    func queue(_ change: PendingChange, now: Date = Date()) -> QueueResult {
        use(account: change.account)
        if let index = changes.firstIndex(where: { Self.sameTarget($0, change) }) {
            var existing = changes[index]
            switch existing.state {
            case .waiting, .needsPerson:
                existing.inputs = Self.merged(existing.inputs, with: change.inputs)
                existing.labels = change.labels
                // Why it waits now, and the version held when the person
                // decided: the newest tap's (a new tap is a new decision).
                existing.addressUnchecked = change.addressUnchecked
                existing.versionAtTap = change.versionAtTap
                if case .invite(let inputs) = change.inputs, inputs.confirmedUserId != nil {
                    // "It's them", answered with this tap: what was confirmed
                    // comes with it, as the account it binds does.
                    existing.seen = change.seen
                }
                // Once a run may have reached the server (no answer, found
                // running after a restart, or a saved statement id), a merge
                // keeps the change's own limit: the server's 8-day request-id
                // record then covers every resend.
                if !existing.mayHaveGoneOut && existing.signedIds.isEmpty {
                    existing.expiresAt = max(existing.expiresAt, change.expiresAt)
                }
                if case .needsPerson = existing.state {
                    // New inputs from the person: what they decided again.
                    existing.seen.keys = change.seen.keys ?? existing.seen.keys
                }
                changes[index] = existing
                save()
                return .merged(existing)
            case .running, .cancelling, .settling:
                // Already going out, or ending: a new change waits behind it.
                break
            }
        }
        if let same = changes.last(where: {
            $0.kind == change.kind && CanonicalId.sameKey($0.circleId, change.circleId)
                && $0.inputs.sameTap(as: change.inputs)
                && now.timeIntervalSince($0.createdAt) < Self.sameTapWindow
        }) {
            return .merged(same)
        }
        let live = changes.filter(\.isPending)
        guard live.filter({ CanonicalId.sameKey($0.circleId, change.circleId) }).count < Self.maxPerCircle,
              live.count < Self.maxPerAccount else { return .tooMany }
        changes.append(change)
        save()
        return .queued(change)
    }

    /// One change per target, per kind. Everything else (check-ins,
    /// destinations, new alerts) is its own event and never merged.
    nonisolated static func sameTarget(_ a: PendingChange, _ b: PendingChange) -> Bool {
        guard a.kind == b.kind, CanonicalId.sameKey(a.circleId, b.circleId) else { return false }
        switch (a.inputs, b.inputs) {
        case let (.invite(x), .invite(y)): return x.email == y.email
        case let (.makeAdmin(x), .makeAdmin(y)): return CanonicalId.sameKey(x, y)
        case let (.letIn(x), .letIn(y)): return CanonicalId.sameKey(x.memberId, y.memberId)
        case let (.renewInvitation(x), .renewInvitation(y)): return x.inviteId == y.inviteId
        case let (.sharePlace(x), .sharePlace(y)): return x == y
        case let (.editPlace(x, _), .editPlace(y, _)): return x == y
        case let (.alertChange(x), .alertChange(y)): return x.ruleId == y.ruleId
        case (.renameCircle, .renameCircle): return true
        default: return false
        }
    }

    /// The newest inputs win; an edit's fields merge (the later ones win).
    nonisolated static func merged(_ old: PendingChange.Inputs, with new: PendingChange.Inputs) -> PendingChange.Inputs {
        switch (old, new) {
        case let (.alertChange(x), .alertChange(y)):
            return .alertChange(.init(ruleId: x.ruleId, threshold: y.threshold ?? x.threshold,
                                      isActive: y.isActive ?? x.isActive, notifyPush: y.notifyPush ?? x.notifyPush,
                                      notifyEmail: y.notifyEmail ?? x.notifyEmail,
                                      cooldownMinutes: y.cooldownMinutes ?? x.cooldownMinutes))
        default:
            return new
        }
    }

    // MARK: - Changing a change

    /// Whether the change was found and the file then saved.
    @discardableResult
    func update(_ id: String, _ mutate: (inout PendingChange) -> Void) -> Bool {
        guard let index = changes.firstIndex(where: { $0.id == id }) else { return false }
        mutate(&changes[index])
        return save()
    }

    /// A statement a waiting change's run just signed, saved on disk BEFORE
    /// its request goes out. False when it can't be (nothing may go out
    /// then), when the change isn't running, or when it already has `limit`
    /// ids.
    func keepSigned(_ statementId: String, invitation: PendingChange.SignedInvitation?, changeId: String,
                    limit: Int) -> Bool {
        guard let current = change(id: changeId), current.isSending, current.signedIds.count < limit else {
            return false
        }
        let id = statementId.lowercased()
        return update(changeId) {
            $0.signedIds.append(id)
            if let invitation {
                $0.signedInvitations = ($0.signedInvitations ?? [:]).merging([id: invitation]) { $1 }
            }
        }
    }

    /// Done or cancelled: deleted, leaving nothing.
    func remove(_ id: String) {
        guard changes.contains(where: { $0.id == id }) else { return }
        changes.removeAll { $0.id == id }
        save()
    }

    /// Dropped: deleted, leaving its one line (none for a change the person
    /// ended themselves).
    func drop(_ id: String, line: String?, now: Date = Date()) {
        guard let change = changes.first(where: { $0.id == id }) else { return }
        changes.removeAll { $0.id == id }
        if let line {
            notices.append(DroppedNotice(id: change.id, account: change.account, circleId: change.circleId,
                                         line: line, createdAt: now, seenAt: nil))
        }
        save()
    }

    /// A line with no change behind it (a cancel's line, items 34–35).
    func addNotice(account: String, circleId: String, line: String, now: Date = Date()) {
        use(account: account)
        notices.append(DroppedNotice(id: UUID().uuidString.lowercased(), account: CanonicalId.key(account),
                                     circleId: circleId, line: line, createdAt: now, seenAt: nil))
        save()
    }

    /// The circle's lines were on screen: they clear.
    func noticesSeen(circleId: String, now: Date = Date()) {
        let before = notices.count
        notices.removeAll { CanonicalId.sameKey($0.circleId, circleId) }
        if notices.count != before { save() }
    }

    /// A circle this account left by itself: its changes go
    /// without a line.
    func forgetCircle(_ circleId: String) {
        let before = (changes.count, notices.count)
        changes.removeAll { CanonicalId.sameKey($0.circleId, circleId) }
        notices.removeAll { CanonicalId.sameKey($0.circleId, circleId) }
        if (changes.count, notices.count) != before { save() }
    }

    /// Lines older than a week go, seen or not.
    func pruneNotices(now: Date = Date()) {
        let before = notices.count
        notices.removeAll { now.timeIntervalSince($0.createdAt) > DroppedNotice.maxAge }
        if notices.count != before { save() }
    }
}

extension PendingChange.Inputs {
    /// The same tap twice: identical inputs, the times aside.
    func sameTap(as other: PendingChange.Inputs) -> Bool {
        switch (self, other) {
        case let (.checkIn(a), .checkIn(b)):
            return a.type == b.type && a.message == b.message && a.latitude == b.latitude
                && a.longitude == b.longitude && a.placeId == b.placeId
        case let (.arrived(a), .arrived(b)):
            return a.destinationId == b.destinationId
        default:
            return self == other
        }
    }
}
