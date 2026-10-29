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

/// Notification inbox. Pulls down to refresh, taps to mark-read, toolbar
/// "mark all read" hits the batch endpoint. Mirrors the Android app's
/// NotificationsFragment surface area.
struct NotificationsView: View {
    /// Shown when presented as a sheet (the map bell) so there's an explicit
    /// way out — the list fills the sheet, so a downward drag hits
    /// pull-to-refresh instead of the dismiss gesture. Omitted when pushed
    /// from Settings, which already has a back button.
    var showsDoneButton: Bool = false
    @StateObject private var manager = NotificationsManager.shared
    /// The invite list is what supplies the names for a `circle_invite` row —
    /// see `inviteBody(for:)`. Observed so the row re-renders when a refresh
    /// lands rather than staying on the server's generic wording.
    @StateObject private var invitesManager = InvitesManager.shared
    /// The rosters and places that name a row (`namedCopy(for:)`), observed so
    /// a row is named as soon as what names it loads.
    @ObservedObject private var circleManager = CircleManager.shared
    @ObservedObject private var placeManager = PlaceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingDestinations = false
    /// Set by a `circle_ownership_claim` tap. `.sheet(item:)` wants an
    /// Identifiable and a bare circle id isn't one.
    @State private var claimTarget: OwnershipClaimTarget?
    /// Set by a `circle_ownership_refused` tap: the circle itself.
    @State private var circleTarget: CircleScreenTarget?

    var body: some View {
        Group {
            if manager.notifications.isEmpty && !manager.isRefreshing {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await manager.markAllRead() }
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .disabled(manager.unreadCount == 0)
            }
        }
        .task {
            // Also when "Notification detail" changed since the rows were
            // personalised: destination and removed-place rows follow it too.
            if manager.notifications.isEmpty || manager.personalizedAt != NotificationsManager.detailNow {
                await manager.refresh()
            }
            // Pending invites are what name an invite row (inviteBody(for:)).
            // Best-effort and cheap; without it a cold-opened inbox shows the
            // server's unnamed copy until something else refreshes the list.
            await invitesManager.refresh()
        }
        .refreshable {
            await manager.refresh()
            await invitesManager.refresh()
        }
        .sheet(isPresented: $showingDestinations) {
            NavigationStack {
                DestinationsView()
            }
        }
        .sheet(item: $claimTarget) { target in
            NavigationStack {
                OwnershipClaimScreen(circleId: target.id)
            }
        }
        .sheet(item: $circleTarget) { target in
            NavigationStack {
                NotifiedCircleScreen(circleId: target.id)
            }
        }
    }

    private var list: some View {
        List {
            ForEach(manager.notifications, id: \.id) { row in
                let named = namedCopy(for: row)
                row.summaryRow(titleOverride: named?.title, bodyOverride: named?.body ?? inviteBody(for: row))
                    .onTapGesture {
                        Task { await manager.markRead(row) }
                        switch row.notificationType {
                        // Destination shared/arrived → the map,
                        // pointed at the destination the
                        // notification is about; the list would
                        // say nothing about WHERE it is. The
                        // server puts destination_id in the
                        // row's metadata; without it (an older
                        // row) fall back to the list.
                        case "destination_shared", "destination_arrival":
                            let destId: String? = {
                                if case .string(let v)? = row.metadata?["destination_id"] { return v }
                                return nil
                            }()
                            if let destId, !destId.isEmpty,
                               let dest = DestinationsManager.shared.destinations
                                   .first(where: { $0.id == destId }) {
                                // Asking to see it answers having hidden it, and
                                // flying to a marker that isn't drawn would look
                                // broken.
                                HiddenDestinationsStore.shared.unhide(destId)
                                // The channel already built for this: see
                                // NotificationRouteState.focusCoordinate.
                                NotificationRouteState.shared.pending =
                                    .focusCoordinate(dest.coordinate)
                                TabSelectionState.shared.selected = 0
                                dismiss()
                            } else {
                                showingDestinations = true
                            }
                        // Circle invite → the Circles tab, where the pending
                        // invitation shows Accept / Decline. Mirrors the
                        // invite PUSH-tap path (PushNotificationManager).
                        case "circle_invite", "invite":
                            Task { await InvitesManager.shared.refresh() }
                            TabSelectionState.shared.selected = 1
                            dismiss()
                        // Somebody has asked to take over a
                        // circle. The owner reads "Open Pingolin
                        // to refuse", and the circle changes
                        // hands after fourteen days of silence,
                        // so this tap opens the one screen with a
                        // refuse control on it.
                        //
                        // Presented as a sheet rather than routed
                        // to the Circles tab: this view is itself
                        // often a sheet over the map, and a tab
                        // switch behind it would leave the owner
                        // looking at the same list they just
                        // tapped.
                        case "circle_ownership_claim":
                            if let circleId = row.circleId, !circleId.isEmpty {
                                claimTarget = OwnershipClaimTarget(id: circleId)
                            }
                        // The claimant's "your request was
                        // refused": the circle itself, as a
                        // sheet for the same reason.
                        case "circle_ownership_refused":
                            if let target = CircleScreenTarget.opened(by: row) {
                                circleTarget = target
                            }
                        // Already settled — there is nothing to refuse and no
                        // claim left to read, so the circle itself is the only
                        // useful destination.
                        case "circle_ownership_transferred":
                            Task { try? await CircleManager.shared.loadCircles() }
                            TabSelectionState.shared.selected = 1
                            dismiss()
                        default:
                            break
                        }
                    }
                    .onAppear {
                        if row.id == manager.notifications.last?.id {
                            Task { await manager.loadMore() }
                        }
                    }
                    // Swipe-to-dismiss, full-swipe either direction —
                    // the Android app's ItemTouchHelper. Deletes
                    // optimistically; reverts on server failure.
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await manager.delete(row) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            if manager.hasMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No notifications yet")
                .font(.headline)
            Text("Alerts about places, check-ins, and circle notifications will show here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

extension NotificationsView {
    /// A row's words with names: who and where, from what this device opened
    /// itself (`NotificationNames`), at the "Notification detail" level, which
    /// governs every named text. nil keeps the server's words.
    func namedCopy(for row: NotificationResponse) -> (title: String, body: String?)? {
        guard let subject = manager.subjects[row.id] else { return nil }
        let circle = circleManager.circles.first { CanonicalId.same($0.id, subject.circleId) }
        let names = NotificationNames.names(
            for: subject, me: AuthManager.shared.userId, members: circleManager.members,
            opened: circleManager.openedNames, places: placeManager.places, circleName: circle?.readableName)
        return NamedNotificationCopy.row(
            type: row.notificationType, title: row.title, body: row.body, names: names,
            level: UserSettings.shared.notificationDetailLevel.rawValue)
    }

    /// Name the inviter and the circle on a stored invite row.
    ///
    /// The row's `body` is the server's relay copy — "You've been invited to
    /// join a circle" — and it has to be: the API never sees a circle name, so
    /// a stored notification cannot carry one. The push banner solves this by
    /// looking the pending invite up locally, and the inbox does the same, so
    /// it never shows the unnamed version next to the named banner. Same
    /// source, same words, same detail-level rules — nothing new travels
    /// anywhere.
    ///
    /// Returns nil when there is nothing better to say, so the row keeps the
    /// server's wording rather than blanking.
    func inviteBody(for row: NotificationResponse) -> String? {
        guard row.notificationType == "circle_invite" || row.notificationType == "invite" else {
            return nil
        }
        let pending = invitesManager.invites.map {
            InviteNotificationCopy.PendingInvite(
                id: $0.id, circleId: $0.circleId,
                circleName: $0.circleName, inviterDisplayName: $0.inviterDisplayName)
        }
        guard let picked = InviteNotificationCopy.pick(from: pending, circleId: row.circleId),
              picked.inviterDisplayName?.isEmpty == false || picked.circleName?.isEmpty == false
        else { return nil }
        return InviteNotificationCopy.body(
            inviter: picked.inviterDisplayName,
            circle: picked.circleName,
            level: UserSettings.shared.notificationDetailLevel.rawValue)
    }
}

private extension NotificationResponse {
    @ViewBuilder
    func summaryRow(titleOverride: String? = nil, bodyOverride: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(titleOverride ?? title)
                    .font(.subheadline)
                    .fontWeight(isRead ? .regular : .semibold)
                if let body = bodyOverride ?? body, !body.isEmpty {
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let label = relativeTimeLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !isRead {
                SwiftUI.Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The row's mark and its colour, by its type.
extension NotificationResponse {
    var iconName: String {
        switch notificationType {
        // The stored row's type is "place_alert"; pushes carry
        // "place_alert_enter"/"place_alert_exit". "place_arrival"/"place_departure"
        // are not emitted by the server — matching only those would send every
        // real place alert to the default bell.
        case "place_alert", "place_alert_enter", "place_alert_exit",
             "place_arrival", "place_departure": return "mappin.and.ellipse"
        case "place_alert_removed": return "mappin.slash"
        case "inactivity_alert": return "figure.walk.motion"
        case "inactivity_recovered": return "figure.walk.motion"
        // The raise's row is "sos_alert"; matching only "sos_triggered",
        // which the server does not write, would give it the plain bell.
        case "sos_alert", "sos_triggered", "sos_acknowledged", "sos_resolved": return "exclamationmark.triangle"
        case "check_in": return "hand.wave"
        case "circle_invite": return "envelope"
        case "key_rotation": return "lock.shield"
        case "destination_shared", "destination_arrival": return "flag.checkered"
        // Ownership succession, each with its own symbol: the default
        // bell would make the one notification the owner has to act on
        // look like every other notification in the list.
        case "circle_ownership_claim": return "person.crop.circle.badge.exclamationmark"
        case "circle_ownership_transferred": return "arrow.left.arrow.right.circle"
        // The claimant's "your request was refused": the mark of the
        // owner's own Refuse control.
        case "circle_ownership_refused": return "hand.raised"
        default: return "bell"
        }
    }

    var iconColor: Color {
        switch notificationType {
        case "sos_alert", "sos_triggered": return .red
        case "sos_acknowledged", "sos_resolved": return .green
        case "place_alert_enter", "place_arrival": return .blue
        case "place_alert_exit", "place_departure": return .orange
        // The stored row carries no direction — it is always "place_alert" — so
        // the neutral place colour is the honest choice rather than guessing
        // arrival. Direction lives only in the server-rendered title and in an
        // event_type_hash the server cannot read.
        case "place_alert": return .blue
        case "check_in": return .purple
        case "circle_invite": return .indigo
        case "inactivity_alert": return .orange
        case "inactivity_recovered": return .green
        case "destination_shared", "destination_arrival": return .teal
        // Orange, the app's "act on this" colour (inactivity, place exit) —
        // not red. Nothing has gone wrong; a clock is running.
        case "circle_ownership_claim": return .orange
        case "circle_ownership_transferred": return .indigo
        // Settled, as a transfer is, and nothing is asked of them: not orange.
        case "circle_ownership_refused": return .indigo
        default: return .gray
        }
    }
}

/// Identifiable wrapper so a circle id can drive `.sheet(item:)`.
struct OwnershipClaimTarget: Identifiable, Hashable {
    let id: String
}

/// The circle a notification opens on its own screen (`NotifiedCircleScreen`),
/// for `.sheet(item:)`: the claimant's "your request was refused".
struct CircleScreenTarget: Identifiable, Hashable {
    let id: String

    /// The circle in its one form, so the screen finds it in any spelling.
    init(id: String) {
        self.id = CanonicalId.circle(id) ?? id
    }

    /// What tapping `row` opens: its circle, when it is the claimant's refusal
    /// and names one.
    static func opened(by row: NotificationResponse) -> CircleScreenTarget? {
        guard row.notificationType == "circle_ownership_refused",
              let circleId = row.circleId, !circleId.isEmpty else { return nil }
        return CircleScreenTarget(id: circleId)
    }
}

// Relative-time labels. Internal (not private) so the pure helpers are
// unit-testable via @testable import. Mirrors the Android app:
// the label must come from the real timestamp in the device's LOCAL
// timezone, because the UTC day bucket rolls over at UTC midnight and
// mislabels same-local-day events as "Yesterday" for users west of UTC.
extension NotificationResponse {
    /// Label for the row's timestamp. Prefers the exact `createdAt`
    /// (local timezone); falls back to the UTC day bucket only when
    /// createdAt is absent or unparseable (a cached row, or a backend
    /// response, without the field). nil when neither is present.
    var relativeTimeLabel: String? {
        if let iso = createdAt, let date = Self.parseTimestamp(iso) {
            return Self.relativeLabel(for: date, now: Date(), calendar: .current)
        }
        if let bucket = createdDayBucket {
            return Self.bucketLabel(dayBucket: bucket, now: Date())
        }
        return nil
    }

    /// Parse an RFC3339/ISO8601 timestamp, tolerating the presence OR
    /// absence of fractional seconds (chrono emits sub-second digits only
    /// when nonzero). Returns nil on any failure so callers degrade to
    /// the bucket label rather than breaking the whole list decode.
    static func parseTimestamp(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Relative label from LOCAL calendar-day distance. Pure +
    /// parameterized for deterministic unit testing. Thresholds match
    /// the Android app's notificationRelativeLabel exactly.
    static func relativeLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let then = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: then, to: today).day ?? 0
        return label(daysAgo: daysAgo)
    }

    /// Legacy fallback: relative label from the UTC day bucket.
    static func bucketLabel(dayBucket: Int, now: Date) -> String {
        let currentBucket = Int(now.timeIntervalSince1970 / 86_400)
        return label(daysAgo: currentBucket - dayBucket)
    }

    private static func label(daysAgo: Int) -> String {
        switch daysAgo {
        // <= 0 also covers a future timestamp (server/device clock skew) —
        // show "Today" rather than a negative count.
        case ..<1: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "\(daysAgo) days ago"
        case 7..<30:
            // Singularize at the boundary: 7 days is "1 week ago",
            // not "1 weeks ago".
            let weeks = daysAgo / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        default:
            let months = daysAgo / 30
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
    }
}
