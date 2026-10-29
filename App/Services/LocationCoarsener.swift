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

/// Sender-side deterministic snap-to-grid coarsening for "approximate"
/// (bubble) circle sharing. Applied to the outgoing coordinates BEFORE
/// they are envelope-encrypted, so neither the server nor the recipient
/// ever sees the exact fix for an approximate-mode circle — only the
/// grid cell it fell into.
///
/// Deterministic on purpose: the same input point always maps to the
/// same cell, so an observer collecting many samples can't average the
/// jitter back out to recover the true position (which a per-send random
/// offset would leak). Mirrors the Android app's sender-side coarsening.
enum LocationCoarsener {
    /// Snap `(lat, lng)` to the center-of-cell grid whose cell size is
    /// `radiusMeters`. A non-positive radius is treated as "no coarsening"
    /// and returns the input unchanged.
    ///
    /// The longitude cell shrinks with latitude (meters-per-degree of
    /// longitude scales by cos(lat)); near the poles that scale collapses
    /// toward zero, so we leave longitude untouched once a degree spans
    /// less than a meter to avoid dividing by ~0.
    static func coarsenLocation(lat: Double, lng: Double, radiusMeters: Double) -> (Double, Double) {
        if radiusMeters <= 0 { return (lat, lng) }
        let cellLatDeg = radiusMeters / 111320.0
        let snappedLat = (lat / cellLatDeg).rounded() * cellLatDeg
        let metersPerDegLng = 111320.0 * cos(lat * .pi / 180.0)
        let snappedLng: Double
        if abs(metersPerDegLng) < 1.0 {
            snappedLng = lng
        } else {
            let cell = radiusMeters / metersPerDegLng
            snappedLng = (lng / cell).rounded() * cell
        }
        return (snappedLat, snappedLng)
    }
}
