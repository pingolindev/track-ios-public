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

/// The admission backfill's signed statement ids: the backfill signs an
/// admission with no person deciding at that moment, and on a circle with
/// refresh records a fresh admission is what brings a removed member back.
/// So it keeps the same discipline as a waiting let-in: every statement id
/// it signs is saved here BEFORE its request goes out, it looks before it
/// signs again for the same member, it is done once the server holds one
/// (the others go dead then), and after 20 ids it stops for that member.
///
/// One JSON file per account in Application Support, written as the waiting
/// changes are (`PendingChangeStore`): protected until first unlock and
/// excluded from backup. A write that fails says so, and nothing is sent then.
/// A file that is there but can't be read (`StoredFile`) is never written
/// over, and nothing is signed until it reads (`isReadable`). Wiped with the
/// account's data (`AuthManager.purgeAccountData`).
@MainActor
final class BackfillLedger {
    static let shared = BackfillLedger()

    /// At most this many ids per member, the same bound as
    /// `PendingChangeRunner.maxSignedIds`.
    static let maxIds = PendingChangeRunner.maxSignedIds

    struct Entry: Codable, Equatable {
        /// Signed, oldest first; each saved before its request went out.
        var ids: [String] = []
        /// When the newest went out: no look sooner than 2 minutes after it.
        var lastSentAt: Date?
        /// 20 ids and none held: this member is left alone.
        var stopped = false
    }

    private let directory: URL?
    private var account: String?
    private var entries: [String: Entry] = [:]
    /// The account's file is there but couldn't be read: nothing is written
    /// over it, and it's read again at the next use.
    private var unreadable = false

    /// `directory` nil = Application Support/Backfill. Tests pass a scratch one.
    init(directory: URL? = nil) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("Backfill", isDirectory: true) }
    }

    private func key(circleId: String, userId: String) -> String {
        "\(CanonicalId.key(circleId)):\(CanonicalId.key(userId))"
    }

    /// The file's entries by their key. Entries an earlier build kept under
    /// several spellings of a circle's or a member's id fold into one, and
    /// the next write keeps that: every id signed under any, in order and
    /// none dropped (each must be able to go dead: `keep` refuses past
    /// `maxIds`, and `run` stops such a member), the latest send, and
    /// stopped if any was. A key that isn't two ids is left as it is.
    nonisolated static func folded(_ stored: [String: Entry]) -> [String: Entry] {
        var spellings: [String: [String]] = [:]
        for raw in stored.keys { spellings[Self.keyOfStored(raw), default: []].append(raw) }
        var result: [String: Entry] = [:]
        for (key, keys) in spellings {
            let entries = keys.sorted { ($0 == key ? 0 : 1, $0) < ($1 == key ? 0 : 1, $1) }.compactMap { stored[$0] }
            guard entries.count > 1 || keys != [key] else {
                result[key] = entries.first
                continue
            }
            var folded = Entry()
            for entry in entries {
                for id in entry.ids where !folded.ids.contains(id) { folded.ids.append(id) }
                if let sent = entry.lastSentAt, sent > (folded.lastSentAt ?? .distantPast) { folded.lastSentAt = sent }
                folded.stopped = folded.stopped || entry.stopped
            }
            result[key] = folded
        }
        return result
    }

    /// A stored `circle:member` key in its one form: the split where both
    /// halves are ids (a `urn:uuid:` spelling has colons of its own); as it
    /// is when there is none.
    private nonisolated static func keyOfStored(_ stored: String) -> String {
        for split in stored.indices where stored[split] == ":" {
            if let circle = CanonicalId.of(String(stored[..<split])),
               let member = CanonicalId.of(String(stored[stored.index(after: split)...])) {
                return "\(circle):\(member)"
            }
        }
        return stored
    }

    private func use(account: String) {
        let account = CanonicalId.key(account)
        guard self.account != account || unreadable else { return }
        self.account = account
        switch StoredFile<[String: Entry]>.read(fileURL(account: account)) {
        case .missing:
            (entries, unreadable) = ([:], false)
        case .loaded(let stored):
            (entries, unreadable) = (Self.folded(stored), false)
        case .unreadable:
            (entries, unreadable) = ([:], true)
        }
    }

    /// Whether this account's file could be read (or there is none): until it
    /// can, the ids signed earlier aren't known, and nothing is signed.
    func isReadable(account: String) -> Bool {
        use(account: account)
        return !unreadable
    }

    private func fileURL(account: String) -> URL? {
        directory?.appendingPathComponent("\(CanonicalId.key(account)).json", isDirectory: false)
    }

    func entry(account: String, circleId: String, userId: String) -> Entry? {
        use(account: account)
        return entries[key(circleId: circleId, userId: userId)]
    }

    /// Saved before the request goes out: false when it can't be (nothing may
    /// go out then), or when the member already has `maxIds`.
    func keep(_ statementId: String, account: String, circleId: String, userId: String, now: Date) -> Bool {
        use(account: account)
        let key = key(circleId: circleId, userId: userId)
        var entry = entries[key] ?? Entry()
        guard !entry.stopped, entry.ids.count < Self.maxIds else { return false }
        entry.ids.append(statementId.lowercased())
        entry.lastSentAt = now
        return write(key, entry)
    }

    /// 20 ids, none held: nothing more for this member.
    @discardableResult
    func stop(account: String, circleId: String, userId: String) -> Bool {
        use(account: account)
        let key = key(circleId: circleId, userId: userId)
        var entry = entries[key] ?? Entry()
        entry.stopped = true
        return write(key, entry)
    }

    /// Settled (one held, the others dead here): the entry goes.
    @discardableResult
    func clear(account: String, circleId: String, userId: String) -> Bool {
        use(account: account)
        return write(key(circleId: circleId, userId: userId), nil)
    }

    /// Sign-out and account switch.
    func wipeAll() {
        entries = [:]
        account = nil
        unreadable = false
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func write(_ key: String, _ entry: Entry?) -> Bool {
        guard !unreadable else { return false }
        let before = entries[key]
        entries[key] = entry
        guard save() else {
            entries[key] = before
            return false
        }
        return true
    }

    private func save() -> Bool {
        guard let account, let url = fileURL(account: account) else { return false }
        guard let data = try? JSONEncoder().encode(entries) else { return false }
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

/// One member's admission backfill: look first, then sign with the id saved
/// before the request, and settle on the server's positive answer. What it
/// reaches outside itself is behind `Deps`, so tests pass their own.
@MainActor
final class AdmissionBackfill {
    struct Signed {
        let statementId: String
        let statementHex: String
        let signatureHex: String
    }

    struct Deps {
        var look: (_ circleId: String, _ statementIds: [String]) async -> PendingChangeRunner.LookAnswer
        var sign: (_ circleId: String, _ userId: String) throws -> Signed
        var store: (_ circleId: String, _ userId: String, _ signed: Signed) async throws -> Void
        /// The ids that go dead here, read back (`settleSignedStatements`).
        var settle: (_ circleId: String, _ dead: [String]) -> Bool
        var now: () -> Date
    }

    enum Outcome: Equatable {
        /// One of its admissions is stored, and every other id is dead here.
        case stored
        /// Not now: the look couldn't run or came too soon, nothing could be
        /// saved or sent, or no answer came. The next pass looks first.
        case notYet
        /// 20 ids and none held: this member is left alone.
        case stopped
    }

    private let ledger: BackfillLedger
    private let account: String
    private let deps: Deps

    init(ledger: BackfillLedger, account: String, deps: Deps) {
        self.ledger = ledger
        self.account = account
        self.deps = deps
    }

    func run(circleId: String, userId: String) async -> Outcome {
        // The ids signed earlier unknown: nothing is signed.
        guard ledger.isReadable(account: account) else { return .notYet }
        let entry = ledger.entry(account: account, circleId: circleId, userId: userId)
        if entry?.stopped == true { return .stopped }
        if let entry, !entry.ids.isEmpty {
            // A request that got no answer may have been stored: look before
            // signing again, and never sooner than 2 minutes after the send.
            if let sent = entry.lastSentAt, deps.now() < sent.addingTimeInterval(PendingChangeRunner.lookAfterSend) {
                return .notYet
            }
            switch await deps.look(circleId, entry.ids) {
            case .couldNotLook, .circleGone:
                return .notYet
            case .held(let held):
                if let id = entry.ids.first(where: held.contains) {
                    return settle(held: id, ids: entry.ids, circleId: circleId, userId: userId)
                }
                guard entry.ids.count < BackfillLedger.maxIds else {
                    PendingChangeRunner.log.info("backfill for a member of circle \(circleId, privacy: .public): 20 admissions, none stored; stopped")
                    ledger.stop(account: account, circleId: circleId, userId: userId)
                    return .stopped
                }
            }
        }
        let signed: Signed
        do {
            signed = try deps.sign(circleId, userId)
        } catch {
            return .notYet
        }
        guard ledger.keep(signed.statementId, account: account, circleId: circleId, userId: userId,
                          now: deps.now()) else { return .notYet }
        do {
            try await deps.store(circleId, userId, signed)
        } catch {
            return .notYet
        }
        // A 2xx for the request that carried it: that one is held.
        let ids = ledger.entry(account: account, circleId: circleId, userId: userId)?.ids ?? [signed.statementId]
        return settle(held: signed.statementId.lowercased(), ids: ids, circleId: circleId, userId: userId)
    }

    private func settle(held: String, ids: [String], circleId: String, userId: String) -> Outcome {
        guard deps.settle(circleId, ids.filter { $0 != held }) else { return .notYet }
        ledger.clear(account: account, circleId: circleId, userId: userId)
        return .stored
    }
}
