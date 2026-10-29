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

/// The viewer's side of re-sealing a frozen last location (the Android app's
/// FrozenGrace): across a circle's rotation, a frozen last location this phone
/// already opened and drew stays drawn for at most `bound`, in memory only,
/// until the member's phone re-seals it under the new key. Without it the
/// marker would go at every rotation for as long as that takes.
///
/// Counted per row from when this phone first carried it, which is its first
/// read after this phone holds the newer version (it can't know when the server
/// rotated), and never longer, however many rotations follow. Only for a member
/// the server still serves frozen there whose row now opens only under an older
/// version, and only a row already drawn: never anything new. Gone with the
/// circle and at sign-out.
struct FrozenGrace {
    /// The bound on a frozen marker kept across a rotation.
    static let bound: TimeInterval = 15 * 60

    /// "circle|member", each in its one form → when this phone first carried
    /// their row.
    private var firstCarried: [String: Date] = [:]

    /// The rows of `previous` (what was drawn for `circleId` before this read)
    /// still drawn after it: their member isn't in `current` (drawn from a row
    /// under the current key), is in `staleServed` (served frozen, opening only
    /// under an older version), and was first carried less than `bound` ago.
    /// Nothing while the circle's version in use can't be read.
    mutating func carried(circleId: String, versionKnown: Bool, now: Date, previous: [String: LocationData],
                          current: Set<String>, staleServed: Set<String>) -> [String: LocationData] {
        guard versionKnown else { return [:] }
        let circle = CanonicalId.key(circleId)
        let drawnNow = Set(current.map { CanonicalId.key($0) })
        let stale = Set(staleServed.map { CanonicalId.key($0) })
        // Re-sealed, or no longer served frozen: their grace is over, and a
        // later one starts afresh.
        firstCarried = firstCarried.filter { key, _ in
            guard key.hasPrefix(circle + "|") else { return true }
            let member = String(key.dropFirst(circle.count + 1))
            return !drawnNow.contains(member) && stale.contains(member)
        }
        var kept: [String: LocationData] = [:]
        for (userId, row) in previous {
            let member = CanonicalId.key(userId)
            guard !drawnNow.contains(member), stale.contains(member) else { continue }
            let key = circle + "|" + member
            let first = firstCarried[key] ?? now
            firstCarried[key] = first
            if now.timeIntervalSince(first) < Self.bound { kept[userId] = row }
        }
        return kept
    }

    mutating func forget(circleId: String) {
        let prefix = CanonicalId.key(circleId) + "|"
        firstCarried = firstCarried.filter { !$0.key.hasPrefix(prefix) }
    }

    mutating func clear() {
        firstCarried = [:]
    }
}
