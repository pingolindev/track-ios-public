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

/// Map-screen variant of the destinations list that returns a
/// coordinate to fly to. Distinct from `DestinationsView` (the
/// full destinations inbox under Settings/Safety) because the FAB
/// flow needs a picker, not the inbox UX.
///
/// ONE SOURCE OF TRUTH. It reads `DestinationsManager`, so hiding means
/// the same thing in all three places — a model of its own would know
/// nothing about `HiddenDestinationsStore` and would offer destinations the
/// user had hidden from both the map and the inbox — and no rows the
/// manager already holds are fetched and decrypted a second time.
struct MapDestinationPicker: View {
    let onPick: (CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = DestinationsManager.shared
    @StateObject private var hidden = HiddenDestinationsStore.shared

    /// Everything the manager holds, minus what the user has hidden. Hiding is
    /// reversible from the inbox, which is what keeps this from being a
    /// trapdoor.
    private var visible: [Destination] {
        manager.destinations.filter { !hidden.isHidden($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = manager.lastError {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if visible.isEmpty && !manager.isRefreshing {
                    Section {
                        // The gesture is a press-and-hold,
                        // not a tap: a tap drops nothing,
                        // so the empty state names the
                        // press-and-hold.
                        Text("No destinations yet. Press and hold anywhere on the map, then choose \"Create Destination\".")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let active = DestinationsManager.live(in: visible)
                    if !active.isEmpty {
                        Section("Active") {
                            ForEach(active) { entry in
                                destinationRow(entry)
                            }
                        }
                    }
                    let history = visible.filter { !$0.status.isLive }
                    if !history.isEmpty {
                        Section("History") {
                            ForEach(history) { entry in
                                destinationRow(entry)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Destinations")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await manager.refresh() }
            .task {
                // The manager is shared, so the map may already have loaded
                // these. Only fetch when there is nothing to show — matching
                // DestinationsView, and avoiding a second round trip every
                // time the FAB is tapped.
                if manager.destinations.isEmpty {
                    await manager.refresh()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if manager.isRefreshing && visible.isEmpty {
                    ProgressView()
                }
            }
        }
    }

    @ViewBuilder
    private func destinationRow(_ entry: Destination) -> some View {
        Button {
            onPick(entry.coordinate)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name ?? "Destination")
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(String(
                    format: "%.4f, %.4f · %@",
                    entry.coordinate.latitude,
                    entry.coordinate.longitude,
                    entry.status.rawValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
