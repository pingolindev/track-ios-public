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

/// Device-local sort order for the Circles tab. Persists the
/// user's preferred ordering across launches as a list of circle
/// IDs in UserDefaults so a server refresh (which returns whatever
/// order the backend likes) never clobbers the user's arrangement.
/// Mirrors the Android app's `circle_sort_order` table — the
/// same separation-of-concerns: server data (circles) stays
/// canonical, ordering is device-local.
///
/// `apply(to:)` joins a server-returned list against the stored
/// order: known IDs appear in their stored position, unknown IDs
/// (newly-joined circles) fall through to the end in their
/// server-returned order. New circles are alphabetical-by-server on
/// android via `COALESCE(sortOrder, MAX_INT), name` — iOS gets the
/// same effect by relying on the existing `circles` order.
enum CircleOrderStore {
    /// Per account (`AccountKeyedDefaults`): another account signing in here,
    /// or an erasure, takes it.
    private static func key(owner: String) -> String { "circles.userOrder.\(owner.lowercased())" }

    /// Read the persisted order as a list of circle IDs. Empty when
    /// the user hasn't dragged anything yet, or nobody is signed in.
    static func load(owner: String?) -> [String] {
        guard let owner else { return [] }
        return (UserDefaults.standard.array(forKey: key(owner: owner)) as? [String]) ?? []
    }

    /// Persist the IDs in display order. Anything outside this list
    /// will sink to the bottom of subsequent `apply` calls until the
    /// user reorders again.
    static func save(_ ids: [String], owner: String?) {
        guard let owner else { return }
        UserDefaults.standard.set(ids, forKey: key(owner: owner))
    }

    /// Re-arrange `circles` to honour the stored order. IDs not in
    /// the stored list (newly joined / created circles) keep their
    /// server-returned relative order and land at the bottom.
    static func apply<C: Identifiable>(to circles: [C], owner: String?) -> [C] where C.ID == String {
        let order = load(owner: owner)
        guard !order.isEmpty else { return circles }
        let rank: [String: Int] = Dictionary(
            uniqueKeysWithValues: order.enumerated().map { ($1, $0) }
        )
        // Stable partition: ranked first (in rank order), unranked
        // last (in original order). Achieves it in O(n).
        var ranked: [(rank: Int, circle: C)] = []
        var unranked: [C] = []
        for c in circles {
            if let r = rank[c.id] {
                ranked.append((r, c))
            } else {
                unranked.append(c)
            }
        }
        ranked.sort { $0.rank < $1.rank }
        return ranked.map { $0.circle } + unranked
    }
}
