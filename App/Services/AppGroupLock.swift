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

/// A lock two processes can share: a POSIX `flock` on a file in the app group
/// the app and its notification extension both hold. The kernel drops it if its
/// holder dies, so a killed process never leaves it held. Three locks use it:
///
/// * `refresh()` — ONE session refresh at a time across the app and the
///   extension. Refresh tokens rotate: a refresh retires the token it was made
///   from, and if both processes refreshed from the SAME stored token, the loser
///   would hold a retired pair — presenting it later (past auth's reuse window)
///   revokes the whole session. So every refresh, in either process, holds
///   this lock and first reads the stored pair AGAIN: changed since the caller
///   decided to refresh means the other process did, and its pair is the one
///   to use.
/// * `approvals()` — the approval records: the app's read-modify-writes and the
///   extension's trust-REDUCING writes (departures, tombstones) never interleave,
///   so neither loses the other's change.
/// * `sosMarks()` — what this device has seen of each SOS (`SOSAlarmMarks`): the
///   app's and the extension's read-change-writes never interleave.
///
/// Compiled into the app and the extension (project.yml).
final class AppGroupLock {
    /// How long the APP waits for the lock: longer than an extension run's whole
    /// budget, so the app, the primary refresher, practically always gets it.
    static let appWait: TimeInterval = 25
    /// How long the EXTENSION waits: its banner must not wait on the app.
    static let extensionWait: TimeInterval = 3

    static let refreshFile = "session-refresh.lock"
    static let approvalsFile = "approval-records.lock"
    static let sosMarksFile = "sos-marks.lock"

    let url: URL

    init(url: URL) {
        self.url = url
    }

    /// `file` in the app group both processes share, or nil without the group.
    static func inAppGroup(_ file: String, suiteName: String = ExtensionBridgeKeys.suite) -> AppGroupLock? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
            .map { AppGroupLock(url: $0.appendingPathComponent(file)) }
    }

    /// The session-refresh lock.
    static func refresh() -> AppGroupLock? { inAppGroup(refreshFile) }

    /// The approval-records lock.
    static func approvals() -> AppGroupLock? { inAppGroup(approvalsFile) }

    /// The SOS marks' lock.
    static func sosMarks() -> AppGroupLock? { inAppGroup(sosMarksFile) }

    /// The lock, held until `release()`.
    final class Held {
        private let fd: Int32
        private var released = false
        private let lock = NSLock()

        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            flock(fd, LOCK_UN)
            close(fd)
        }

        deinit {
            release()
        }
    }

    /// Waits up to `timeout` for the lock, without blocking a thread; nil if it
    /// could not be had.
    func acquire(timeout: TimeInterval) async -> Held? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                close(fd)
                return nil
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return Held(fd: fd)
    }

    /// The same, for synchronous callers (the app's record writes on the main
    /// actor): every other holder keeps it for milliseconds, so this blocks for
    /// milliseconds; nil after `timeout`.
    func acquireBlocking(timeout: TimeInterval) -> Held? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(5_000)
        }
        return Held(fd: fd)
    }
}

/// The refresh rule both processes follow, holding `AppGroupLock.refresh()`.
enum SessionRefresh {
    /// Whether the stored refresh token changed since the caller read `before`
    /// — another process refreshed, and its pair is the one to use.
    static func anotherProcessRefreshed(before: String?, now: String?) -> Bool {
        guard let now, !now.isEmpty, now != "none" else { return false }
        return now != before
    }
}
