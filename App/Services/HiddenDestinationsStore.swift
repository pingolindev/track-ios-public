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
import Combine

/// Destinations the user has chosen not to see on this device.
///
/// The map shows every member's destinations, and only the creator may cancel
/// one — the backend enforces that. So for the majority of what is on screen,
/// other people's, hiding is the only "I don't need to see this" that can
/// exist. It is deliberately local: the destination stays live for everyone
/// else, and the user is expressing a preference about their own map rather
/// than revoking somebody's plan.
///
/// Ids are stored alongside the circle they belong to so `prune` can clean up
/// from one circle's fetch without needing every circle at once.
@MainActor
final class HiddenDestinationsStore: ObservableObject {
    static let shared = HiddenDestinationsStore()

    private let idsKey = "hidden_destination_ids"
    private let circlesKey = "hidden_destination_circles"
    private let defaults: UserDefaults

    /// Published so a view or the map redraws the moment something is hidden,
    /// rather than at the next unrelated refresh.
    @Published private(set) var hidden: Set<String> = []

    private var circleOf: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: idsKey) ?? [])
        circleOf = (defaults.dictionary(forKey: circlesKey) as? [String: String]) ?? [:]
    }

    func isHidden(_ destinationId: String) -> Bool {
        hidden.contains(destinationId)
    }

    func hide(_ destinationId: String, circleId: String?) {
        guard !destinationId.isEmpty, !hidden.contains(destinationId) else { return }
        if let circleId, !circleId.isEmpty { circleOf[destinationId] = circleId }
        persist(hidden.union([destinationId]))
    }

    func unhide(_ destinationId: String) {
        guard hidden.contains(destinationId) else { return }
        persist(hidden.subtracting([destinationId]))
    }

    /// Forget hides for destinations `circleId` no longer has.
    ///
    /// Without this the set only grows: a destination that flips to arrived
    /// leaves the list for good, and its hide would sit in UserDefaults forever
    /// for a row nobody can see again.
    ///
    /// Scoped to one circle because a caller rarely holds every circle's
    /// destinations at once, and pruning globally against a partial list would
    /// drop live hides. An entry whose circle is unknown — hidden by an older
    /// build — is kept rather than guessed at.
    func prune(circleId: String, liveIds: [String]) {
        guard !circleId.isEmpty else { return }
        let live = Set(liveIds)
        let kept = hidden.filter { id in
            guard circleOf[id] == circleId else { return true }
            return live.contains(id)
        }
        if kept.count != hidden.count { persist(kept) }
    }

    /// Sign-out: the next account must not inherit this one's hides.
    func clear() {
        circleOf = [:]
        persist([])
    }

    private func persist(_ ids: Set<String>) {
        // Trim the id->circle map to what is still hidden so it cannot outlive
        // the entries it describes.
        circleOf = circleOf.filter { ids.contains($0.key) }
        hidden = ids
        defaults.set(Array(ids), forKey: idsKey)
        defaults.set(circleOf, forKey: circlesKey)
    }
}
