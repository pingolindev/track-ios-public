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
import CoreLocation

/// Travel intentions inbox. Pulls down to refresh; swipe-actions cancel
/// or delete; tap an active destination to report arrival from the
/// current location. Mirrors the Android app's DestinationsFragment.
struct DestinationsView: View {
    @StateObject private var manager = DestinationsManager.shared
    @StateObject private var hidden = HiddenDestinationsStore.shared

    @ObservedObject private var pendingChanges = PendingChangeStore.shared

    var body: some View {
        Group {
            if manager.destinations.isEmpty && !manager.isRefreshing
                && !pendingChanges.changes.contains(where: { $0.kind == .destination && $0.isPending }) {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Destinations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if manager.destinations.isEmpty {
                await manager.refresh()
            }
        }
        .refreshable { await manager.refresh() }
    }

    private var list: some View {
        List {
            // EVERY member's destinations, not just mine.
            //
            // Cancel/Delete/Arrived are creator-only, but hiding is
            // local, so it works on any destination — and it is the
            // only thing you can do about somebody else's, which is
            // most of what the map shows. A hidden destination
            // therefore has to be reachable here, or hiding one would
            // be a trapdoor with no way back. Matches the web client
            // and the Android app.
            let active = DestinationsManager.live(in: manager.destinations)
            // Destinations waiting for this iPhone to catch up.
            if pendingChanges.changes.contains(where: { $0.kind == .destination && $0.isPending }) {
                Section(PendingChangeCopy.tag) {
                    PendingChangesInPlace(kinds: [.destination])
                }
            }
            if !active.isEmpty {
                Section("Active") {
                    ForEach(active) { row in
                        destinationRow(row)
                        // "I've arrived", waiting, on the destination's row.
                        PendingChangesInPlace(kinds: [.arrived]) { change in
                            if case .arrived(let inputs) = change.inputs { return inputs.destinationId == row.id }
                            return false
                        }
                    }
                }
            }
            let archived = manager.destinations.filter { !$0.status.isLive }
            if !archived.isEmpty {
                Section("Past") {
                    ForEach(archived) { row in
                        destinationRow(row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destinationRow(_ row: Destination) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                SwiftUI.Circle()
                    .fill(statusColor(for: row.status).opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: statusIcon(for: row.status))
                    .foregroundStyle(statusColor(for: row.status))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name ?? "Destination")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let status = Self.statusInPlaceOfETA(row, members: CircleManager.shared.members[row.circleId] ?? [],
                                                        me: AuthManager.shared.userId) {
                    // Paused, or real-time sharing off, in the
                    // destination's circle: it stays active, and
                    // nothing moves their ETA on, so their status
                    // says why.
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let eta = row.estimatedArrivalAt {
                    // Date + time — time alone ("ETA 2:30 PM")
                    // hides WHICH day. iOS decrypts the full ms
                    // timestamp, so it can show both.
                    Text("ETA \(eta.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(row.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    // The list carries every member's rows now, so whose it is
                    // has to be on the row or the extra entries are a mystery.
                    if !isMine(row) {
                        Text(creatorLabel(row))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if hidden.isHidden(row.id) {
                        Text("Hidden")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Delete / Cancel / Arrived are creator-only — the backend refuses
            // them for anyone else — so they are absent on a shared row.
            if isMine(row) {
                Button(role: .destructive) {
                    Task { await surfacingFailure { try await manager.deleteDestination(row) } }
                } label: { Label("Delete", systemImage: "trash") }

                // Terminal rows — arrived, cancelled, expired, or a status this
                // build doesn't know — get neither button: the server refuses
                // both, so offering them is offering a dead end.
                if row.status.isLive {
                    Button {
                        Task { await surfacingFailure { try await manager.cancelDestination(row) } }
                    } label: { Label("Cancel", systemImage: "xmark.circle") }
                        .tint(.orange)

                    Button {
                        Task { await surfacingFailure { _ = try await manager.reportArrival(destination: row, byPerson: true) } }
                    } label: { Label("Arrived", systemImage: "checkmark.circle") }
                        .tint(.green)
                }
            }
        }
        // Available on EVERY row, which is the point: a destination somebody
        // else created cannot be cancelled, so hiding is the only way to clear
        // it off your map. Leading edge so it never sits under a destructive.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                if hidden.isHidden(row.id) {
                    hidden.unhide(row.id)
                } else {
                    hidden.hide(row.id, circleId: row.circleId)
                }
            } label: {
                hidden.isHidden(row.id)
                    ? Label("Show again", systemImage: "eye")
                    : Label("Hide", systemImage: "eye.slash")
            }
            .tint(.gray)
        }
    }

    /// Run a row mutation and SURFACE its failure.
    ///
    /// A refusal must not be silent: tapping "Arrived" on a row the server
    /// no longer considers active (or not this user's) 404s, and without a
    /// word the row would simply sit there. The manager re-pulls the list on
    /// that 404, so the screen self-corrects, but only the banner explains
    /// why. Mirrors the Android app's DestinationRepository, which does
    /// both.
    @MainActor
    private func surfacingFailure(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            ErrorBanner.shared.post(error)
        }
    }

    private func isMine(_ row: Destination) -> Bool {
        row.isMine(AuthManager.shared.userId)
    }

    /// "Paused until …" or "Location sharing off" for another member's live
    /// destination while its creator isn't sharing in its circle; nil
    /// otherwise.
    static func statusInPlaceOfETA(_ row: Destination, members: [CircleMember], me: String?,
                                   now: Date = Date()) -> String? {
        guard row.status.isLive, !row.isMine(me),
              let creator = members.first(where: { CanonicalId.same($0.userId, row.userId) }) else { return nil }
        return SharingStatusCopy.rowLine(creator.sharing(at: now), now: now)
    }

    /// "Shared by Alice", or a generic line when the member isn't cached —
    /// better than inventing a name.
    private func creatorLabel(_ row: Destination) -> String {
        let members = CircleManager.shared.members[row.circleId] ?? []
        if let name = members.first(where: { $0.userId == row.userId })?.displayName,
           !name.isEmpty {
            return "Shared by \(name)"
        }
        return "Shared by a circle member"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.north.circle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No destinations yet")
                .font(.headline)
            Text("Share where you're heading and we'll let your circle know when you arrive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func statusIcon(for status: Destination.Status) -> String {
        switch status {
        case .active: return "location.north.circle"
        case .arrived: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .expired: return "clock.badge.xmark"
        case .unknown: return "questionmark.circle"
        }
    }

    private func statusColor(for status: Destination.Status) -> Color {
        switch status {
        case .active: return .blue
        case .arrived: return .green
        case .cancelled: return .gray
        case .expired: return .gray
        case .unknown: return .gray
        }
    }
}
