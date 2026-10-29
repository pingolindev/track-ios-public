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

/// A member who shares only an AREA in a circle, not a position.
///
/// The server marks each of their latest-location rows `sharing_mode:
/// "approximate"`, with `approximate_radius_miles` = their radius ±20 %, drawn
/// afresh on EVERY response, and requires the client to blur the coordinates
/// of such a row before display. Their phone has already snapped the point to
/// a grid whose cell is that radius (`LocationCoarsener`), so the person is
/// within 0.71 × r of it.
///
/// So this device shows an area, never the point: a translucent circle with
/// their avatar at its centre, the words "Approximate location", and nothing
/// finer — no street address, no coordinates, no place worked out on this
/// device from the point. The Android and web apps apply the same rules.
///
/// The point is NOT snapped again here: the radius on the wire changes on every
/// response, so a re-snap would make the area jump between refreshes.
struct ApproximateArea: Codable, Equatable {
    /// The row's `approximate_radius_miles`; nil when the server sent none.
    var reportedMiles: Double?
    /// The radius drawn, in miles: 1.25 × the largest radius seen for this
    /// member while they stay approximate (`ApproximateAreaMemory`). Never shown
    /// as a number — the wire value is varied on purpose.
    var drawnMiles: Double

    /// The senders' own default when no radius is stored (iOS
    /// `SDKLocationStreamer.privacyApplied`, the Android app's coarsening).
    static let defaultRadiusMiles: Double = 1
    /// 1.25 × r covers the person even when the server reports r −20 %
    /// (1.25 × 0.8 = 1.0), and a snapped point is never more than 0.71 × r away.
    static let areaFactor: Double = 1.25
    static let metersPerMile: Double = 1_609.344

    var drawnMeters: Double { drawnMiles * Self.metersPerMile }

    /// What one row says. nil for "exact", for a row without `sharing_mode` (an
    /// older server) and for anything else: those are drawn as exact rows.
    /// "paused" rows never get this far (`CircleManager.loadMemberLocations`).
    init?(sharingMode: String?, radiusMiles: Double?) {
        guard sharingMode == "approximate" else { return nil }
        let reported = radiusMiles.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.reportedMiles = reported
        self.drawnMiles = Self.areaFactor * (reported ?? Self.defaultRadiusMiles)
    }

    /// `segments` points on the circle of `radiusMeters` around `center`, on a
    /// sphere: the outline the map fills.
    static func outline(center: CLLocationCoordinate2D, radiusMeters: Double,
                        segments: Int = 72) -> [CLLocationCoordinate2D] {
        (0..<max(segments, 8)).map { index in
            destination(from: center, meters: radiusMeters,
                        bearingDegrees: 360 * Double(index) / Double(max(segments, 8)))
        }
    }

    /// The area's northern, eastern, southern and western edges: what framing
    /// the camera around a member has to take in.
    static func extremes(center: CLLocationCoordinate2D, radiusMeters: Double) -> [CLLocationCoordinate2D] {
        [0.0, 90, 180, 270].map { destination(from: center, meters: radiusMeters, bearingDegrees: $0) }
    }

    private static func destination(from center: CLLocationCoordinate2D, meters: Double,
                                    bearingDegrees: Double) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_008.8
        let angular = meters / earthRadius
        let bearing = bearingDegrees * .pi / 180
        let lat1 = center.latitude * .pi / 180
        let lon1 = center.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }
}

/// The words for an approximate member, the same on the Android app and the
/// web. No number: the radius on the wire is varied on purpose.
enum ApproximateLocationCopy {
    /// A member's row, card and marker.
    static let line = "Approximate location"
    /// Inside a spoken label, after the name.
    static let spoken = "approximate location"
}

/// Where an approximate member's point may be drawn: never centre an area on a
/// precise point.
///
/// Right after a member switches to approximate, the server labels their LAST
/// stored fix "approximate" — which may be the precise one their phone sent
/// while they were exact — and a cold start can meet that fix without ever
/// having seen it as exact. A point their phone snapped lies on a senders'
/// grid; one that does not is snapped here, once, with the senders' own formula
/// (`LocationCoarsener`), and kept where it was put for as long as that fix is
/// served, so nothing moves between refreshes.
extension ApproximateArea {
    /// Every whole-mile radius a member can set: the server keeps them
    /// between 1 and 25.
    static let senderRadii = 1...25

    /// Whether `latitude` lies on a sender's grid for ANY whole-mile radius,
    /// not only those near the reported one: the server reports
    /// round(r × (1 ± 0.2)), so a member at 3 miles can be reported as 2, and
    /// the three clients must agree on which points stay as they came.
    /// Latitude only: the longitude cell depends on the sender's own true
    /// latitude, which this device does not have. The tolerance survives the
    /// payload's packing (latitude travels as an i32 × 1e7: at most 3.5e-6 of
    /// a cell at 1 mile); a precise point passes by chance about once in
    /// 2,000 (25 × 2e-5).
    static func isOnSendersGrid(latitude: Double) -> Bool {
        senderRadii.contains { miles in
            let cellLatDeg = Double(miles) * metersPerMile / 111_320
            let cells = latitude / cellLatDeg
            return abs(cells - cells.rounded()) < 1e-5
        }
    }

    /// A point not on the senders' grid, snapped the way their phones snap:
    /// cell = the reported radius (1 mile when none is reported).
    static func snapped(_ point: CLLocationCoordinate2D, reportedMiles: Double?) -> CLLocationCoordinate2D {
        let miles = reportedMiles.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? defaultRadiusMiles
        let (lat, lng) = LocationCoarsener.coarsenLocation(
            lat: point.latitude, lng: point.longitude, radiusMeters: miles * metersPerMile)
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// What this device remembers about each approximate member, per circle, so
/// their area stays put from one refresh to the next:
/// - its size: the server varies the radius on every response, so the area
///   takes the LARGEST seen while the member stays approximate;
/// - its centre: the point drawn for the fix being served, decided the first
///   time that fix is seen (on the senders' grid: as it came; otherwise snapped
///   once) and kept while the same fix is served again.
/// Both are forgotten the moment one of their rows arrives that is not
/// approximate.
struct ApproximateAreaMemory {
    private struct Held {
        var largestMiles: Double = 0
        var fixTime: Date?
        var drawnAt: CLLocationCoordinate2D?
    }

    private var held: [String: Held] = [:]

    private static func key(_ circleId: String, _ userId: String) -> String {
        CanonicalId.key(circleId) + ":" + CanonicalId.key(userId)
    }

    /// `area` as it should be drawn: its `drawnMiles` raised to the largest seen.
    /// nil (an exact row) forgets the member in this circle.
    mutating func remember(_ area: ApproximateArea?, circleId: String, userId: String) -> ApproximateArea? {
        let key = Self.key(circleId, userId)
        guard var area else {
            held.removeValue(forKey: key)
            return nil
        }
        var entry = held[key] ?? Held()
        entry.largestMiles = max(entry.largestMiles, area.drawnMiles)
        held[key] = entry
        area.drawnMiles = entry.largestMiles
        return area
    }

    /// `fix` the way it is drawn. Not approximate: as it came (and the member
    /// is forgotten here). Approximate: the area at its largest, centred on a
    /// point on the senders' grid — the fix's own point when it is on it, else
    /// that point snapped once, and the same point again whenever this fix
    /// (by its time) is served again, whatever radius comes with it.
    mutating func draw(_ fix: LocationData, circleId: String, userId: String) -> LocationData {
        guard let area = remember(fix.approximate, circleId: circleId, userId: userId) else { return fix }
        let key = Self.key(circleId, userId)
        var entry = held[key] ?? Held()
        let centre: CLLocationCoordinate2D
        if entry.fixTime == fix.timestamp, let kept = entry.drawnAt {
            centre = kept
        } else if ApproximateArea.isOnSendersGrid(latitude: fix.latitude) {
            centre = fix.coordinate
        } else {
            centre = ApproximateArea.snapped(fix.coordinate, reportedMiles: area.reportedMiles)
        }
        entry.fixTime = fix.timestamp
        entry.drawnAt = centre
        held[key] = entry
        var drawn = fix.moved(to: centre)
        drawn.approximate = area
        return drawn
    }

    /// One member of one circle forgotten: drawn nowhere.
    mutating func forget(circleId: String, userId: String) {
        held.removeValue(forKey: Self.key(circleId, userId))
    }

    mutating func removeAll() {
        held.removeAll()
    }
}
