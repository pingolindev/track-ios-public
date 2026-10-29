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

/// The words for where an SOS's position stands, for the Safety card, the
/// map and its detail sheet alike.
enum SOSPositionText {
    /// The line said about the position, or nil when there is nothing to add:
    /// a position taken at the raise needs no extra line, and one that opened
    /// no position or marker says `noPosition`.
    static func line(_ reading: SOSReceiverRules.PositionReading, now: Date = Date()) -> String? {
        switch reading {
        case .unknown, .atRaise: return nil
        case .sending: return "Sending current location"
        case .unavailable: return "Location unavailable"
        case .lastKnown(let at): return "Last known location · \(time(at, now: now))"
        case .updated(let at): return "Location updated · \(time(at, now: now))"
        }
    }

    /// Where nothing opened.
    static let noPosition = "No location available for this alert"

    /// The map's word for the pin or area: for an area (`areaMeters`) its
    /// size in place of "Sent from here", which would name its centre as the
    /// spot.
    static func mapLabel(_ reading: SOSReceiverRules.PositionReading, areaMeters: Double? = nil) -> String {
        switch reading {
        case .lastKnown: return "Last known location"
        case .updated: return "Location updated"
        default: return areaMeters.map(within) ?? "Sent from here"
        }
    }

    /// What an AREA carries at its centre in place of the alert's disc (the
    /// same as Android's and the web's): "Last known location" or "Location
    /// updated · {time}" when it says so, then "Within about {distance}".
    static func areaLabel(_ reading: SOSReceiverRules.PositionReading, areaMeters: Double,
                          now: Date = Date()) -> String {
        let when: String? = {
            switch reading {
            case .lastKnown: return "Last known location"
            case .updated(let at): return "Location updated · \(time(at, now: now))"
            default: return nil
            }
        }()
        return [when, within(areaMeters)].compactMap { $0 }.joined(separator: "\n")
    }

    /// "{time}": the clock time, with the date when it isn't today.
    static func time(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "Within about {distance}", in the units this phone uses for roads.
    static func within(_ meters: Double) -> String {
        let distance = Measurement(value: meters.rounded(), unit: UnitLength.meters)
        return "Within about \(distance.formatted(.measurement(width: .abbreviated, usage: .road)))"
    }
}
