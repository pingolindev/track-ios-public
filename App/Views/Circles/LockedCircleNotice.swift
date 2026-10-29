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

/// What a locked circle says about itself.
///
/// Each cause says what is happening and when it ends — in plain words:
/// nothing a person reads talks about keys. A circle that has not opened yet
/// does so as soon as another member's app is online; only a password reset
/// needs another member to confirm it is really them, and only the password —
/// asked for right here, never "sign out, then sign in again" — fixes a
/// device that never unlocked the account.
struct LockedCircleCopy: Equatable {
    /// The heading at the top of the circle's screen.
    let title: String
    /// One line under the circle's name in the circle list.
    let caption: String
    /// The whole explanation, at the top of the circle's screen.
    let explanation: String
    /// The way out is in the account portal (restoring pre-reset data).
    let opensAccountSettings: Bool
    /// The password field sits under the explanation (`PasswordUnlockForm`).
    var asksForPassword: Bool = false
}

/// What this app calls the device it runs on, in copy ("this phone").
enum DeviceNoun {
    static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone"
    }
}

extension CircleLockReason {
    /// The words for a device that is behind or cannot open a circle — and
    /// true: nothing new is sealed for the circle meanwhile, and this device
    /// keeps its locations for it until it has caught up
    /// (`PendingCircleLocations`). "Notify my circle" goes out as ever.
    static let waitingToSyncTitle = "Waiting to sync"
    static let waitingToSyncBody = "Awaiting sync for circle settings from another member. Locations will be queued until synced."

    /// `circleName` is nil while the name cannot be read ("this circle").
    /// `ranOut`: on the joiner's own screen, their invitation ran out, and
    /// who was asked to let them in (`CircleManager.lateJoinerRanOut`).
    func copy(isOwner: Bool, circleName: String? = nil, device: String = DeviceNoun.current,
              ranOut: LateJoiner.RanOut? = nil) -> LockedCircleCopy {
        let circle = circleName ?? "this circle"
        let waitingToSync = LockedCircleCopy(
            title: Self.waitingToSyncTitle,
            caption: Self.waitingToSyncTitle,
            explanation: Self.waitingToSyncBody,
            opensAccountSettings: false
        )
        switch self {
        case .keysNotUnlocked:
            // The one thing only the person has. Asked for in place: nothing is
            // signed out, and every circle opens once it is typed.
            return LockedCircleCopy(
                title: "Enter your password",
                caption: "Enter your password to open your circles",
                explanation: "This \(device) needs your password to open your circles. Nothing has been lost.",
                opensAccountSettings: false,
                asksForPassword: true
            )
        case .awaitingKey where isOwner:
            return waitingToSync
        case .awaitingKey:
            return LockedCircleCopy(
                title: "Almost ready",
                caption: "Almost ready",
                explanation: ranOut.map { LateJoiner.joinerLine(asked: $0.asked) }
                    ?? "You've joined \(circle). It opens here as soon as another member's app is online, usually within a minute.",
                opensAccountSettings: false
            )
        case .sealedBeforeReset:
            // What happens, not a request. This device asks for access by
            // itself (`CircleManager.requestFreshCopies`), the server wakes
            // the members' phones, and each one that is not in use gets the
            // question as a notification (`CircleQuestionNotifier`, from
            // the pin pass that wake runs); one in use asks on screen.
            return LockedCircleCopy(
                title: "Waiting for your circle",
                caption: "Waiting for your circle",
                explanation: "You reset your password, so another member of \(circle) has been asked to confirm it's you. It opens here as soon as one of them does. If you still have your recovery key, you can restore your previous setup instead: Account → Settings → Data from before your password reset.",
                opensAccountSettings: true
            )
        case .keyOutOfDate, .awaitingNewerKey, .keyNotVerified, .keyUnreadable, .keyUnavailable:
            return waitingToSync
        }
    }
}

/// The circle-list line for a locked circle. The row opens the circle, where
/// `LockedCircleSection` gives the whole explanation — the info glyph says so.
struct LockedCircleCaption: View {
    let circle: Circle

    var body: some View {
        if let reason = circle.lockReason {
            Label {
                Text(reason.copy(isOwner: circle.isOwner, circleName: circle.readableName).caption)
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("circle-row-locked")
            .accessibilityHint("Open the circle for what to do")
        }
    }
}

/// The top of a locked circle's screen: why it is locked and what to do.
struct LockedCircleSection: View {
    let circle: Circle

    var body: some View {
        if let reason = circle.lockReason {
            let copy = reason.copy(isOwner: circle.isOwner, circleName: circle.readableName,
                                   ranOut: CircleManager.shared.lateJoinerRanOut(circle.id))
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(copy.explanation)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("locked-circle-explanation")
                }
                if copy.asksForPassword {
                    PasswordUnlockForm()
                }
                // Every cause that opens the portal is about restoring data from
                // before a password reset, so land on that section.
                if copy.opensAccountSettings,
                   let url = AppConfiguration.shared.preResetDataURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("Open Account Settings")
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    .accessibilityIdentifier("locked-circle-open-account-settings")
                }
            } header: {
                Text(copy.title)
            }
        }
    }
}
