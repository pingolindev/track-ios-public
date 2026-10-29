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
import CoreLocation

/// The map camera's last settled position, published for surfaces that are not
/// inside the map's own view tree, such as the address search sheet.
///
/// WHY THIS IS NOT `@Published` / NOT AN `ObservableObject`
///   `regionDidChangeWith` fires on every pan and zoom settle. Publishing that
///   would invalidate every SwiftUI view observing it, which includes the map
///   container itself — a re-render storm driven by the user's thumb, to service a
///   value that is read exactly once, when a search runs. The search sheet pulls
///   the current value at the moment it needs it instead.
///
/// WHY IT EXISTS AT ALL
///   The map search passes `focusLat`/`focusLng` and a `SearchArea` built from
///   the visible bounds (as the Android app's does), which is what gives its rows
///   a distance, an "In <city>" header and a viewport clamp. The search sheet
///   lives outside the MapLibre view tree, so this is its path to the camera.
@MainActor
final class MapViewportState {
    static let shared = MapViewportState()

    /// Centre of the visible map. Nil until the map has laid out at least once —
    /// callers must treat that as "no focus" rather than substituting (0, 0),
    /// which is in the Gulf of Guinea and would rank every result by its distance
    /// from there.
    private(set) var center: CLLocationCoordinate2D?

    /// Padded box around the visible bounds. Nil for the same reason as `center`.
    private(set) var area: SmartSearch.SearchArea?

    /// Called from the map's `regionDidChangeWith` delegate. `south`/`north` are
    /// raw visible bounds; `east < west` is accepted and means the view crosses
    /// ±180 — `SearchArea.fromViewport` handles the wrap.
    func update(
        center: CLLocationCoordinate2D,
        south: Double, west: Double, north: Double, east: Double
    ) {
        // A degenerate box (map not laid out yet, zero-size bounds) would clamp
        // every search to nothing. Leave the previous value in place instead.
        guard south.isFinite, west.isFinite, north.isFinite, east.isFinite,
              north > south else { return }
        self.center = center
        self.area = SmartSearch.SearchArea.fromViewport(
            south: south, west: west, north: north, east: east
        )
    }
}
