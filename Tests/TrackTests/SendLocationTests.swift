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

import XCTest
import CoreLocation
import PingolinTrackSDK
@testable import Track

/// "Send location", the refresh when Track comes to the front and the wake
/// push build their location with one builder, so each carries the battery
/// level: without it, a watcher's low-battery rule about this person says
/// nothing until the next ordinary send.
final class SendLocationTests: XCTestCase {
    private let taken = Date(timeIntervalSince1970: 1_700_000_000)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func fix(altitude: Double = 31, speed: Double = 1.5, course: Double = 90) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                   altitude: altitude, horizontalAccuracy: 12, verticalAccuracy: 5,
                   course: course, speed: speed, timestamp: taken)
    }

    private func send(_ fix: CLLocation, level: Int?, charging: Bool?) -> PingolinTrackSDK.Location {
        PingolinTrackSDK.Location.forSend(fix, battery: BatteryReading(level: level, isCharging: charging))
    }

    // MARK: - The builder

    /// The level, and whether the phone is charging, go in as read.
    func testASingleSendCarriesTheBatteryLevelAndCharging() {
        let charging = send(fix(), level: 42, charging: true)
        XCTAssertEqual(charging.batteryLevel, 42)
        XCTAssertEqual(charging.isCharging, true)
        let draining = send(fix(), level: 7, charging: false)
        XCTAssertEqual(draining.batteryLevel, 7)
        XCTAssertEqual(draining.isCharging, false)
    }

    /// A reading outside 0–100 is held to it; no reading stays no reading.
    func testTheLevelIsHeldToAPercentage() {
        XCTAssertEqual(send(fix(), level: 140, charging: nil).batteryLevel, 100)
        XCTAssertEqual(send(fix(), level: -3, charging: nil).batteryLevel, 0)
        let none = send(fix(), level: nil, charging: nil)
        XCTAssertNil(none.batteryLevel)
        XCTAssertNil(none.isCharging)
    }

    /// The fix's own time and place. An unknown speed or course (negative) and
    /// a zero altitude go as unknown.
    func testTheFixsOwnTimeAndUnknownsGoAsUnknown() {
        let known = send(fix(), level: 50, charging: nil)
        XCTAssertEqual(known.timestamp, 1_700_000_000_000)
        XCTAssertEqual(known.latitude, 37.3349)
        XCTAssertEqual(known.longitude, -122.0090)
        XCTAssertEqual(known.altitude, 31)
        XCTAssertEqual(known.speed, 1.5)
        XCTAssertEqual(known.heading, 90)
        XCTAssertEqual(known.accuracy, 12)
        let unknown = send(fix(altitude: 0, speed: -1, course: -1), level: 50, charging: nil)
        XCTAssertNil(unknown.altitude)
        XCTAssertNil(unknown.speed)
        XCTAssertNil(unknown.heading)
    }

    // MARK: - Wiring

    /// The wake push, "Send location" and the refresh at coming to the front all
    /// use it, with the phone's own reading by default.
    func testTheThreeSingleSendsUseTheBuilderWithThePhonesBattery() throws {
        let builder = try source("App/Services/SendLocation.swift")
        XCTAssertTrue(builder.contains(
            "static func forSend(_ fix: CLLocation, battery: BatteryReading = .device()) -> PingolinTrackSDK.Location {"))
        XCTAssertTrue(builder.contains(
            "return BatteryReading(level: service.getBatteryLevel(), isCharging: service.isCharging())"))
        XCTAssertTrue(try source("App/Views/Map/MapView.swift").contains("let loc = PingolinTrackSDK.Location.forSend(cl)"))
        XCTAssertTrue(try source("App/TrackApp.swift").contains("let loc = PingolinTrackSDK.Location.forSend(cl)"))
        XCTAssertTrue(try source("App/Managers/PushNotificationManager.swift")
            .contains("let sdkLocation = PingolinTrackSDK.Location.forSend(location)"))
    }

    /// No send builds a location with the level left out; the per-circle
    /// withholding happens on the way out.
    func testNoLevelIsLeftOutAndTheCircleSettingStillWithholdsIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil)
        var leftOut: [String] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if try String(contentsOf: url, encoding: .utf8).contains("batteryLevel: nil as UInt8?") {
                leftOut.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(leftOut, [])
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        // The battery switch AND "Allow alerts on me"
        // (`PrivacySettings.sendsBattery`,
        // BatterySwitchWordsTests).
        XCTAssertTrue(streamer.contains("!privacy.sendsBattery,"))
    }
}
