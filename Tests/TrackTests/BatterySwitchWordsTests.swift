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
import PingolinTrackSDK
@testable import Track

/// The battery switch says what it does, and the level goes only where it
/// can be read for its one purpose.
///
/// WHY THIS IS WORTH TESTING
///   A label like "Share Battery Level" would promise that the circle sees
///   this account's battery. No screen on any of the three apps shows a
///   member's battery: the level goes in this account's points for the
///   circle, and the only thing that reads it is the low-battery alert about
///   them. With "Allow alerts on me" off there is no such alert, so a level
///   sent then goes for nothing, and "Sends your battery level…" would be
///   false in that state.
@MainActor
final class BatterySwitchWordsTests: XCTestCase {

    private let circle = "b7b70000-0000-4000-8000-0000000000b1"
    private let fix = PingolinTrackSDK.Location(
        latitude: 37.33490, longitude: -122.00900, altitude: 30, speed: 1.5, heading: 90, accuracy: 5,
        timestamp: 1_760_400_000_000, batteryLevel: 80, isCharging: false)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func row(battery: Bool, alertsOnMe: Bool) -> PrivacySettings {
        var row = PrivacySettings.default(for: circle)
        row.shareBattery = battery
        row.allowAlertsOnMe = alertsOnMe
        return row
    }

    func testTheSwitchSaysWhatItDoes() throws {
        XCTAssertEqual(PrivacySettingsSheet.batteryTitle, "Allow low-battery alerts about me")
        XCTAssertEqual(PrivacySettingsSheet.batteryDetail,
                       "Sends your battery level to this circle so members can be alerted when it's low.")
        XCTAssertEqual(PrivacySettingsSheet.batteryNeedsAlerts, "Turn on “Allow alerts on me” to use this.")
        XCTAssertEqual(PrivacySettingsSheet.batteryLine(allowAlertsOnMe: true), PrivacySettingsSheet.batteryDetail)
        XCTAssertEqual(PrivacySettingsSheet.batteryLine(allowAlertsOnMe: false), PrivacySettingsSheet.batteryNeedsAlerts)
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("""
                            Toggle(isOn: $settings.shareBattery) {
                                Text(Self.batteryTitle)
                                Text(Self.batteryLine(allowAlertsOnMe: settings.allowAlertsOnMe))
                            }
                            .disabled(!settings.allowAlertsOnMe)
        """), "its line by \"Allow alerts on me\", and greyed out while that is off")
        XCTAssertFalse(view.contains("Toggle(\"Share Battery Level\""))
    }

    /// The level goes only while the battery switch AND "Allow alerts on me"
    /// are on. Withheld otherwise.
    func testTheLevelGoesOnlyWhileAlertsOnMeIsOnToo() {
        XCTAssertTrue(row(battery: true, alertsOnMe: true).sendsBattery)
        XCTAssertFalse(row(battery: true, alertsOnMe: false).sendsBattery)
        XCTAssertFalse(row(battery: false, alertsOnMe: true).sendsBattery)
        XCTAssertFalse(row(battery: false, alertsOnMe: false).sendsBattery)

        let both = SDKLocationStreamer.privacyApplied(fix, circleId: circle, privacy: row(battery: true, alertsOnMe: true))
        XCTAssertEqual(both.location.batteryLevel, 80)
        XCTAssertFalse(both.batteryWithheld)
        let noAlerts = SDKLocationStreamer.privacyApplied(fix, circleId: circle, privacy: row(battery: true, alertsOnMe: false))
        XCTAssertNil(noAlerts.location.batteryLevel, "with \"Allow alerts on me\" off nothing can read it")
        XCTAssertTrue(noAlerts.batteryWithheld)
        let noSwitch = SDKLocationStreamer.privacyApplied(fix, circleId: circle, privacy: row(battery: false, alertsOnMe: true))
        XCTAssertNil(noSwitch.location.batteryLevel)
        let personal = SDKLocationStreamer.privacyApplied(fix, circleId: SelfKeyManager.selfCircleUuid,
                                                          privacy: row(battery: true, alertsOnMe: false))
        XCTAssertEqual(personal.location.batteryLevel, 80, "the personal history keeps its battery")
    }

    /// The wake asks the same rule: no circle is woken for a level it was not sent.
    func testTheWakeAsksTheSameRule() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("        return privacySettings[circleId]?.sendsBattery ?? true\n"))
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertTrue(streamer.contains("           !privacy.sendsBattery,\n"))
        XCTAssertFalse(streamer.contains("privacy.shareBattery == false"))
    }

    /// The circle row's glyph shows what goes to the circle: no battery
    /// while "Allow alerts on me" is off.
    func testTheRowShowsABatteryOnlyWhereALevelIsSent() throws {
        let view = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(view.contains("""
                                if settings.sendsBattery {
                                    Image(systemName: "battery.100")
                                }
        """))
        XCTAssertFalse(view.contains("if settings.shareBattery {"), "the switch alone says nothing of what is sent")
    }

    /// No SwiftUI marker draws a member's battery level.
    func testNoMarkerDrawsABatteryLevel() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertFalse(map.contains("struct MemberMarker: View"))
        XCTAssertFalse(map.contains("Text(\"\\(battery)%\")"))
    }
}
