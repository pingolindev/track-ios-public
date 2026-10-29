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
@testable import Track

/// The raiser's SOS status poll, and the emergency cadence an SOS switches on.
///
/// WHY THIS IS WORTH TESTING
///   A fixed 5 s repeating status poll is 720 GETs an hour, background
///   included, and if only `resolved` or `false_alarm` stops it, an emergency
///   left open polls every five seconds for as long as it stays open.
///   Separately, raising an SOS promises "high-frequency location updates": on
///   the NORMAL profile a still phone would keep its five-minute poll through
///   its own emergency. Both failures would be silent.
final class SOSPollScheduleTests: XCTestCase {

    private func delay(_ elapsed: TimeInterval, active: Bool = true, acknowledged: Bool = false) -> TimeInterval {
        SOSManager.statusPollDelay(elapsed: elapsed, appActive: active, acknowledged: acknowledged)
    }

    func testFastWhileFreshThenBacksOff() {
        XCTAssertEqual(delay(0), 5)
        XCTAssertEqual(delay(59), 5)
        XCTAssertEqual(delay(60), 30)
        XCTAssertEqual(delay(599), 30)
        XCTAssertEqual(delay(600), 120)
        XCTAssertEqual(delay(86_400), 120, "an alert left open for a day polls every two minutes, not every five seconds")
    }

    func testTheFastPollRunsOnlyWhileTheRaiserIsLooking() {
        XCTAssertEqual(delay(0, active: false), 120)
        XCTAssertEqual(delay(300, active: false), 120)
        XCTAssertEqual(delay(86_400, active: false), 120)
    }

    func testOnceAcknowledgedOnlyASlowClosureCheckRemains() {
        XCTAssertEqual(delay(0, acknowledged: true), 900)
        XCTAssertEqual(delay(0, active: false, acknowledged: true), 900)
    }

    func testTheFirstHourCostsUnderATenthOfAFixedFiveSecondPoll() {
        // Walk the schedule for an hour with the raiser looking the whole time.
        var elapsed: TimeInterval = 0
        var polls = 0
        while elapsed < 3600 {
            elapsed += delay(elapsed)
            polls += 1
        }
        XCTAssertLessThan(polls, 72, "a fixed 5 s timer would make 720 in the same hour")
    }

    func testAcknowledgedReadsTheCountNotJustTheStatus() {
        // Acknowledging doesn't flip the shared status (only rows from older
        // servers carry `acknowledged`); it bumps a count.
        XCTAssertTrue(SOSManager.isAcknowledged(status: .active, acknowledgmentCount: 1))
        XCTAssertTrue(SOSManager.isAcknowledged(status: .acknowledged, acknowledgmentCount: nil))
        XCTAssertFalse(SOSManager.isAcknowledged(status: .active, acknowledgmentCount: 0))
        XCTAssertFalse(SOSManager.isAcknowledged(status: .active, acknowledgmentCount: nil))
    }

    // MARK: - The wiring, asserted at the source

    func testRaisingAnSOSSwitchesOnTheEmergencyCadence() throws {
        let src = try source("App/Managers/SOSManager.swift")
        let trigger = try slice(src, from: "func triggerSOS(", to: "func cancelSOS(")
        XCTAssertTrue(trigger.contains("locationService.setEmergencyMode(true)"))
        XCTAssertTrue(trigger.contains("locationService.requestFreshFix(timeout: Self.preciseFixTimeout, after: pressAt)"),
                      "the precise fix asked at the press is taken at Best accuracy")
        XCTAssertFalse(src.contains("withTimeInterval: 5.0, repeats: true"), "no fixed 5 s poll")
    }

    func testEveryWayOutOfTheEmergencyLeavesEmergencyMode() throws {
        let src = try source("App/Managers/SOSManager.swift")
        let close = try slice(src, from: "private func closeMyAlert(", to: "private func pollAlertStatus(")
        XCTAssertTrue(close.contains("locationService.setEmergencyMode(false)"))
        let reset = try slice(src, from: "func reset() {", to: "/// Build the E2EE CreateSOSRequest")
        XCTAssertTrue(reset.contains("locationService.setEmergencyMode(false)"), "logout")
        let cancel = try slice(src, from: "func cancelSOS(", to: "func resolveSOS(")
        XCTAssertTrue(cancel.contains("closeMyAlert(alert.id)"), "the raiser's own resolve / false alarm")
        let load = try slice(src, from: "func loadActiveAlerts(quiet: Bool = false)", to: "/// Alerts the MAP should draw")
        XCTAssertTrue(load.contains("await reconcileMyAlert(with: currentAlerts.map(\\.alert),"), "a resolve push lands here")
    }

    func testTheEmergencyCadenceIsTheMovingOneEvenInBatterySaver() {
        XCTAssertEqual(
            LocationService.pollInterval(profile: .still, batterySaver: true, batteryTier: .low,
                                         userInterval: 900, emergency: true),
            LocationService.pollMovingSeconds)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func slice(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), "\(start) not found — renamed or removed")
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), "\(end) not found after \(start)")
        return String(src[a.lowerBound..<b.lowerBound])
    }
}
