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

/// Each member's row as each circle last accepted it: what that circle's alert
/// rules judge them by (inactivity, low battery, a member's own "watch me").
///
/// `CircleManager.memberLocations` holds ONE row per member, the last circle's
/// to accept one, and a replay drop in another circle keeps it. Judged by that
/// row, a member of two circles would be judged in one by the other's row: its
/// "Allow alerts on me" and its battery, both set per circle, and its time.
/// The battery pass reuses each circle's refresh from the inactivity pass, so
/// it too must read each circle's own row here. Otherwise alerts go off about
/// a member in one circle against the consent they gave in another.
///
/// Keyed by circle and member in their one forms, as the replay guard is. Kept
/// in step with `memberLocations`: written where a row is accepted, trimmed
/// wherever that is.
struct CircleRowMemory {
    private var rows: [String: LocationData] = [:]

    private static func key(_ circleId: String, _ userId: String) -> String {
        CanonicalId.key(circleId) + ":" + CanonicalId.key(userId)
    }

    /// `userId`'s row as `circleId` last accepted it; nil when it has none here.
    func row(of userId: String, in circleId: String) -> LocationData? {
        rows[Self.key(circleId, userId)]
    }

    /// A row accepted by the circle it names.
    mutating func accept(_ row: LocationData) {
        rows[Self.key(row.circleId, row.userId)] = row
    }

    /// A "no" the server serves with `served` now ("Allow alerts on me" off),
    /// onto the row its circle holds, when the replay guard dropped `served`
    /// for not being newer. The server re-serves a member's last fix until
    /// they send another, with their consent as it is now. Kept as of the
    /// last accepted fix, a member who turned alerts on them off and then
    /// went quiet, which is when an inactivity rule goes off, would still be
    /// judged and told on.
    ///
    /// One way only. A fresh row needs a newer sealed time, which only the
    /// member's phone makes; a dropped one needs nothing from them. A "yes"
    /// (or nothing) on it would let the server alone have a quiet member who
    /// had alerts off judged again on their held time and battery. A "no"
    /// gives it nothing new: it can always withhold their rows. So a "yes"
    /// counts from their next fix. The fix, its time and its battery stay
    /// the held row's. Nothing held, nothing taken.
    mutating func takeWithdrawal(of served: LocationData) {
        guard served.allowAlertsOnMe == false else { return }
        rows[Self.key(served.circleId, served.userId)]?.allowAlertsOnMe = false
    }

    /// One member of one circle: frozen there, or drawn nowhere.
    mutating func forget(circleId: String, userId: String) {
        rows.removeValue(forKey: Self.key(circleId, userId))
    }

    /// `circleId`'s rows of anyone it no longer shows. Other circles' stay.
    mutating func keepOnly(_ shown: Set<String>, in circleId: String) {
        let circle = CanonicalId.key(circleId)
        let kept = Set(shown.map(CanonicalId.key))
        rows = rows.filter { _, row in
            CanonicalId.key(row.circleId) != circle || kept.contains(CanonicalId.key(row.userId))
        }
    }

    /// A circle this device no longer has.
    mutating func forget(circleId: String) {
        let circle = CanonicalId.key(circleId)
        rows = rows.filter { _, row in CanonicalId.key(row.circleId) != circle }
    }

    mutating func removeAll() {
        rows.removeAll()
    }
}
