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
import struct PingolinTrackSDK.Location

/// This phone's battery as a send seals it.
struct BatteryReading: Equatable {
    let level: Int?
    let isCharging: Bool?

    /// The phone's own, read now.
    static func device() -> BatteryReading {
        let service = LocationService.shared
        return BatteryReading(level: service.getBatteryLevel(), isCharging: service.isCharging())
    }
}

extension PingolinTrackSDK.Location {
    /// What a single send seals from one Core Location fix: the wake push, the
    /// map's "Send location" and the refresh when Track comes to the front. One
    /// place builds it for all three, so each carries the battery level: a point
    /// without one leaves a watcher's low-battery rule with nothing to judge
    /// until the next ordinary send. The level goes in whole: a circle that
    /// doesn't share it has it taken out on the way
    /// (`SDKLocationStreamer.privacyApplied`).
    ///
    /// The fix's own time, never now: a request that times out can hand back
    /// Core Location's older cache. Core Location reports an unknown speed or
    /// course as negative, and those go as unknown.
    static func forSend(_ fix: CLLocation, battery: BatteryReading = .device()) -> PingolinTrackSDK.Location {
        PingolinTrackSDK.Location(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            altitude: fix.altitude == 0 ? nil : fix.altitude,
            speed: fix.speed < 0 ? nil : fix.speed,
            heading: fix.course < 0 ? nil : fix.course,
            accuracy: fix.horizontalAccuracy,
            timestamp: Int64(fix.timestamp.timeIntervalSince1970 * 1000),
            batteryLevel: battery.level.map { UInt8(min(max($0, 0), 100)) },
            isCharging: battery.isCharging
        )
    }
}
