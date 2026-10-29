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

/// What this device has seen of each SOS, for the receiver rules
/// (`SOSReceiverRules`).
///
/// - "Seen current": every sealed payload of an SOS this device saw while its
///   key was current, by hash, one-way per hash. An SOS sealed under a key
///   version that isn't current alarms only when one of its payloads was seen
///   current here (it stays sticky across the rotation that followed), so a
///   removed member can't raise one with the server. A re-sealed SOS (new
///   bytes, the same alert) adds its own hash.
/// - "Ended": seen closed, or its raiser left this device's roster. One-way: a
///   re-listed SOS never alarms again.
/// - "Rang": this device has rung its alarm (a checked push's, or a pass's that
///   found it alarming). One-way: the alarm rings once per SOS here, and a pass
///   that finds it rung posts silently (as on Android).
///
/// One JSON file per account in the APP GROUP's container, so the notification
/// extension decides with the same marks as the app. Nothing is cached between
/// calls: every read is fresh, and every write is a read, a change and a write
/// under a lock both processes take (`AppGroupLock.sosMarks()`). Protected
/// until first unlock and excluded from backup. A file that is there but can't
/// be read (`StoredFile`) is never written over: the app's list reads it as
/// "not seen" (the strict answer), and the extension as "can't check" (it
/// rings, as it would with no marks at all). Marks go only past
/// `SOSReceiverRules.maxAlarmAgeMs`. Per account, and KEPT across a sign-out,
/// as the account's other kept trust is: another account's go only by a
/// sign-in's guarded tidy (`SignInTidy`), all of them at an erasure; never
/// adopted.
///
/// Compiled into the app and the extension (project.yml).
final class SOSAlarmMarks {
    static let shared = SOSAlarmMarks()

    /// At most this many payloads seen current per SOS: a re-seal after each
    /// rotation adds one, and the oldest goes past it.
    static let maxHashesPerAlert = 16

    struct Mark: Codable, Equatable {
        /// The payload hashes seen current, oldest first.
        var seenCurrent: [String] = []
        var ended = false
        var rang = false
        /// The SOS's sealed original time (ms), else when it was first marked:
        /// the pruning clock.
        var at: Int64
    }

    /// The folder in the app group; nil without the group (never, with the
    /// entitlement).
    static func groupDirectory(suiteName: String = ExtensionBridgeKeys.suite) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
            .map { $0.appendingPathComponent("SOSMarks", isDirectory: true) }
    }

    /// Where earlier versions kept them: the app's own Application Support
    /// (`moveIn`).
    static func earlierDirectory() -> URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: false))
            .map { $0.appendingPathComponent("SOSMarks", isDirectory: true) }
    }

    private let directory: URL?
    private let lock: AppGroupLock?
    private let lockWait: TimeInterval

    /// `directory` nil = the app group's SOSMarks, locked by
    /// `AppGroupLock.sosMarks()`. Tests pass a scratch folder and a lock.
    init(directory: URL? = nil, lock: AppGroupLock? = nil, lockWait: TimeInterval = 1) {
        self.directory = directory ?? Self.groupDirectory()
        self.lock = lock ?? (directory == nil ? AppGroupLock.sosMarks() : nil)
        self.lockWait = lockWait
    }

    static func key(circleId: String, sosId: String) -> String {
        CanonicalId.key(circleId) + "|" + CanonicalId.key(sosId)
    }

    private func fileURL(account: String) -> URL? {
        directory?.appendingPathComponent(CanonicalId.key(account) + ".json", isDirectory: false)
    }

    /// The account's marks as they are on disk now.
    func read(account: String) -> StoredFile<[String: Mark]> {
        StoredFile<[String: Mark]>.read(fileURL(account: account))
    }

    /// The mark for an SOS; nil when there is none or the file can't be read.
    func mark(account: String, circleId: String, sosId: String) -> Mark? {
        guard case .loaded(let marks) = read(account: account) else { return nil }
        return marks[Self.key(circleId: circleId, sosId: sosId)]
    }

    /// A payload seen while its key was current. False when not written.
    @discardableResult
    func noteSeenCurrent(account: String, circleId: String, sosId: String, hash: String, at: Int64) -> Bool {
        change(account: account, circleId: circleId, sosId: sosId, at: at) { mark in
            guard !mark.seenCurrent.contains(hash) else { return false }
            mark.seenCurrent.append(hash)
            if mark.seenCurrent.count > Self.maxHashesPerAlert {
                mark.seenCurrent.removeFirst(mark.seenCurrent.count - Self.maxHashesPerAlert)
            }
            return true
        }
    }

    /// Seen closed, or its raiser off the roster. False when not written.
    @discardableResult
    func noteEnded(account: String, circleId: String, sosId: String, at: Int64) -> Bool {
        change(account: account, circleId: circleId, sosId: sosId, at: at) { mark in
            guard !mark.ended else { return false }
            mark.ended = true
            return true
        }
    }

    /// Its alarm has rung on this device. False when not written.
    @discardableResult
    func noteRang(account: String, circleId: String, sosId: String, at: Int64) -> Bool {
        change(account: account, circleId: circleId, sosId: sosId, at: at) { mark in
            guard !mark.rang else { return false }
            mark.rang = true
            return true
        }
    }

    /// One mark changed on what the file holds now, under the lock. True when
    /// it holds the change afterwards (written here, or already there).
    private func change(account: String, circleId: String, sosId: String, at: Int64,
                        _ apply: (inout Mark) -> Bool) -> Bool {
        locked {
            let marks: [String: Mark]
            switch read(account: account) {
            case .missing: marks = [:]
            case .loaded(let stored): marks = stored
            case .unreadable: return false
            }
            let key = Self.key(circleId: circleId, sosId: sosId)
            var mark = marks[key] ?? Mark(at: at)
            guard apply(&mark) else { return true }
            var changed = marks
            changed[key] = mark
            return save(changed, account: account)
        } ?? false
    }

    /// Marks past `maxAgeMs` go; nothing else ever does.
    func prune(account: String, now: Int64, maxAgeMs: Int64) {
        _ = locked {
            guard case .loaded(let marks) = read(account: account) else { return false }
            let kept = marks.filter { now - $0.value.at <= maxAgeMs }
            return kept.count == marks.count || save(kept, account: account)
        }
    }

    /// The accounts with marks here, each by its key (a sign-in's guarded
    /// tidy). A listing that fails names none.
    func accounts() -> Set<String> {
        Set(storedFiles().map { CanonicalId.key($0.deletingPathExtension().lastPathComponent) })
    }

    /// A sign-in's guarded tidy (`SignInTidy`): this account's marks go, under
    /// any spelling of its id.
    func forget(account: String) {
        let gone = CanonicalId.key(account)
        _ = locked {
            for file in storedFiles() where CanonicalId.key(file.deletingPathExtension().lastPathComponent) == gone {
                try? FileManager.default.removeItem(at: file)
            }
            return true
        }
    }

    /// An erasure: every account's marks go.
    func wipeAll() {
        _ = locked {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            return true
        }
    }

    /// The marks earlier versions kept in the app's own Application Support,
    /// moved here once (at launch): a file with none here moves as it
    /// is; one with marks here too folds into them (every hash seen current,
    /// ended if either was, the earlier time). A file that doesn't read, here
    /// or there, stays where it is and is tried again at the next launch
    /// (before the first unlock, for one).
    func moveIn(from old: URL?) {
        guard let old, let files = try? FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
        else { return }
        _ = locked {
            for file in files where file.pathExtension == "json" {
                let account = file.deletingPathExtension().lastPathComponent
                guard case .loaded(let theirs) = StoredFile<[String: Mark]>.read(file) else { continue }
                let merged: [String: Mark]
                switch read(account: account) {
                case .missing: merged = theirs
                case .loaded(let ours): merged = Self.folded(ours, theirs)
                case .unreadable: continue
                }
                guard save(merged, account: account) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: old)
            }
            return true
        }
    }

    /// Two sets of one account's marks as one: every hash seen current (capped
    /// as ever, the newest kept), ended if either was, rung if either was, the
    /// earlier time.
    static func folded(_ ours: [String: Mark], _ theirs: [String: Mark]) -> [String: Mark] {
        ours.merging(theirs) { one, other in
            var seen = one.seenCurrent
            for hash in other.seenCurrent where !seen.contains(hash) { seen.append(hash) }
            return Mark(seenCurrent: Array(seen.suffix(maxHashesPerAlert)), ended: one.ended || other.ended,
                        rang: one.rang || other.rang, at: min(one.at, other.at))
        }
    }

    private func storedFiles() -> [URL] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
    }

    /// `work` holding the lock; nil when the lock can't be had (nothing is
    /// changed then). Without a lock (a test's scratch folder), it just runs.
    private func locked<T>(_ work: () -> T) -> T? {
        guard let lock else { return work() }
        guard let held = lock.acquireBlocking(timeout: lockWait) else { return nil }
        defer { held.release() }
        return work()
    }

    private func save(_ marks: [String: Mark], account: String) -> Bool {
        guard let url = fileURL(account: account), let directory else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marks)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}

extension SOSAlarmMarks.Mark {
    /// A mark written by an earlier version has no "rang": it reads as not rung.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenCurrent = try c.decodeIfPresent([String].self, forKey: .seenCurrent) ?? []
        ended = try c.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        rang = try c.decodeIfPresent(Bool.self, forKey: .rang) ?? false
        at = try c.decode(Int64.self, forKey: .at)
    }
}
