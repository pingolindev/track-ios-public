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

/// What owners and admins are told while a circle is finishing a removal.
enum CircleKeyNoticeCopy {
    /// The circle is waiting for the security refresh that follows someone
    /// leaving or being removed. Until it lands, they can still read anything
    /// new, so a removal must not look finished the moment they vanish from
    /// the list. Any member's app finishes it.
    static func removalPending(cause: String?, name: String?) -> String {
        if cause == "member_left" {
            return "Finishing the update after someone left. This completes as soon as a member's app is online."
        }
        return "Finishing removing \(name ?? "a member"). This completes as soon as a member's app is online."
    }
}

extension CircleKeyNoticeCopy {
    /// Owners and admins see that someone listed for the circle was kept out —
    /// the one visible trace of a server trying to slip people in, since nobody
    /// without a valid invitation is shown.
    static func keptOut(_ count: Int, circle: String?) -> String {
        let name = circle ?? "this circle"
        return count == 1
            ? "Pingolin kept 1 person out of \(name) who wasn't properly invited."
            : "Pingolin kept \(count) people out of \(name) who weren't properly invited."
    }
}

/// The circle-list line for the notice above, shown to owners and admins.
struct CircleKeyNoticeCaption: View {
    let circle: Circle
    @StateObject private var circleManager = CircleManager.shared

    var body: some View {
        if circleManager.isOwnerOrAdmin(circle) {
            if circle.removedMemberStillHasKey {
                Label(
                    CircleKeyNoticeCopy.removalPending(
                        cause: circle.keyRotationCause,
                        name: circleManager.pendingRemovalNames[circle.id]
                    ),
                    systemImage: "hourglass"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("circle-row-removal-pending")
            }
            if let kept = circleManager.hiddenMemberCounts[circle.id], kept > 0 {
                Label(CircleKeyNoticeCopy.keptOut(kept, circle: circle.readableName), systemImage: "person.fill.xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("circle-row-kept-out")
            }
        }
    }
}

/// The same notice, in full, at the top of the circle's screen.
struct CircleKeyNoticeSections: View {
    let circle: Circle
    @StateObject private var circleManager = CircleManager.shared

    var body: some View {
        if circleManager.isOwnerOrAdmin(circle), circle.removedMemberStillHasKey {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(CircleKeyNoticeCopy.removalPending(
                        cause: circle.keyRotationCause,
                        name: circleManager.pendingRemovalNames[circle.id]
                    ))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("circle-removal-pending")
            } header: {
                Text("Finishing a removal")
            }
        }
        if circleManager.isOwnerOrAdmin(circle), let kept = circleManager.hiddenMemberCounts[circle.id], kept > 0 {
            Section {
                Label(CircleKeyNoticeCopy.keptOut(kept, circle: circle.readableName), systemImage: "person.fill.xmark")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("circle-kept-out")
            }
        }
    }
}
