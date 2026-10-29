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

/// The one place a place's alert radius range is written down.
///
/// A place has ONE geofence radius, and that radius IS its alert ring, so
/// every screen that edits it must offer the same range. `EditPlaceSheet`
/// binds the live `$place.radius`, with `saveChanges()` re-registering the
/// geofence, so a screen with a narrower range would not just look different:
/// opening a 2 km place on it would shrink everyone's alert and write it back.
///
/// WHY 100...5000
///   - The 100 m floor: 50 m is below typical GPS accuracy, so a ring that
///     small fires on noise. The server's 50 m minimum is what it will accept,
///     not what is usable.
///   - The 5 km ceiling errs wide, because widening is the only safe
///     direction. A `Slider` CLAMPS a bound value that falls outside its
///     range: it does not refuse to show it, it rewrites it. So a narrower
///     range turns the edit sheet into a screen that mutates the thing it is
///     displaying, merely by being opened — a 2 km place shrinks to the
///     ceiling on appear, and `saveChanges()` then persists the shrink and
///     re-registers the geofence at the smaller size. Nobody dragged anything.
///   - Both ends sit inside the server's 50-25000, so nothing is refused.
///
/// This deliberately does NOT chase cross-platform parity: the other Track
/// apps offer other ranges, and picking between them is a product decision.
enum PlaceRadius {

    /// The range offered for a NEW place.
    static let range: ClosedRange<Double> = 100...5000

    /// Slider granularity, in metres.
    static let step: Double = 100

    /// Starting value for a new place.
    static let defaultMeters: Double = 150

    /// The range to offer when EDITING a place that already has a radius.
    ///
    /// A place can hold a value outside `range` — set on another client: the
    /// server accepts anything from 50 to 25000. Handing such a place a slider
    /// that excludes its own value does not show it out of range: SwiftUI
    /// clamps the binding, so merely OPENING the editor rewrites the radius,
    /// and `saveChanges()` then persists that and re-registers the geofence.
    /// Nobody touched the slider.
    ///
    /// So stretch the range to admit whatever is already there. The user can
    /// still drag it back inside; what they cannot do is change it by accident.
    static func editableRange(for current: Double) -> ClosedRange<Double> {
        guard current.isFinite else { return range }
        return Swift.min(range.lowerBound, current)...Swift.max(range.upperBound, current)
    }

    /// "150 m" / "1.5 km". One formatter, so both screens read alike.
    static func formatted(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : "\(Int(meters)) m"
    }
}
