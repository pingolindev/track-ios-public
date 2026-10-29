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

import CoreLocation
import UIKit

/// One decrypted history fix: whose it is, where, and when (the time sealed
/// inside it, never the server's day bucket).
struct HistoryPoint: Equatable {
    let userId: String
    let latitude: Double
    let longitude: Double
    let at: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One member's history in time order: what the map draws as a line with a dot
/// per fix.
struct HistoryTrail: Equatable {
    let userId: String
    let points: [HistoryPoint]
}

enum HistoryTrails {
    /// Pure: the trails a range shows. The server answers by DAY, the only event
    /// time it holds in the clear, so a range is cut here by each fix's own
    /// time: "1h" would otherwise draw the whole day. With `memberId`, that
    /// member's alone. One trail per member, in time order; the members in a
    /// fixed order, so the same answer draws the same way.
    static func trails(from points: [HistoryPoint], window: (start: Date, end: Date),
                       memberId: String?) -> [HistoryTrail] {
        let kept = points.filter {
            $0.at >= window.start && $0.at <= window.end
                && (memberId == nil || CanonicalId.same($0.userId, memberId))
        }
        let byMember = Dictionary(grouping: kept) { CanonicalId.key($0.userId) }
        return byMember.keys.sorted().compactMap { key in
            guard let points = byMember[key], let first = points.first else { return nil }
            return HistoryTrail(userId: first.userId, points: points.sorted { $0.at < $1.at })
        }
    }

    /// The "Custom" range as asked: nil when the start isn't before the end.
    /// An end in the future reads as now.
    static func customWindow(start: Date, end: Date, now: Date) -> (start: Date, end: Date)? {
        let end = min(end, now)
        guard start < end else { return nil }
        return (start, end)
    }
}

extension UIColor {
    /// "#RRGGBB", as a map style expression reads a colour.
    var styleHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let byte = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
