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
@testable import Track

/// What each silent push makes the app re-fetch, and when a wake may reuse the
/// fix the app already holds.
///
/// WHY THIS IS WORTH TESTING
///   Refreshing destinations, the bell and SOS on every push, whatever it is
///   about, costs three GETs and two cache writes for a check-in or
///   low-battery push; and a `wake_location` that always starts a fresh
///   Best-accuracy fix ignores the one the resident poller took seconds ago.
///   Both cost battery, and neither shows.
final class PushRefreshPlanTests: XCTestCase {

    func testAGenericTickleStillRefreshesEverything() {
        // A tickle names no family, and the backend sends one for every family —
        // SOS included — so it cannot be narrowed.
        XCTAssertEqual(PushAppDelegate.refreshPlan(for: "tickle"), [.destinations, .bell, .sos])
        XCTAssertEqual(PushAppDelegate.refreshPlan(for: nil), [.destinations, .bell, .sos])
    }

    func testDestinationPushesDoNotReloadSOS() {
        XCTAssertEqual(PushAppDelegate.refreshPlan(for: "destination_shared"), [.destinations, .bell])
        XCTAssertEqual(PushAppDelegate.refreshPlan(for: "destination_arrival"), [.destinations, .bell])
    }

    func testSOSShapedFamiliesReloadSOS() {
        XCTAssertEqual(PushAppDelegate.refreshPlan(for: "sos_resolved"), [.bell, .sos])
        // Sent at high priority with the SOS kinds, but has no typed case.
        XCTAssertEqual(PushAppDelegate.refreshPlan(for: "emergency"), [.bell, .sos])
    }

    func testOtherFamiliesRefreshOnlyTheBell() {
        for kind in ["low_battery", "check_in", "inactivity", "circle_member_left"] {
            XCTAssertEqual(PushAppDelegate.refreshPlan(for: kind), [.bell], kind)
        }
    }

    // MARK: - Wake fix reuse

    private func fix(accuracy: CLLocationAccuracy, age: TimeInterval, now: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    func testAFreshAccurateFixAnswersTheWake() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(PushAppDelegate.isReusableWakeFix(
            fix(accuracy: 20, age: 30, now: now), acceptedAccuracy: 100, now: now))
        XCTAssertTrue(PushAppDelegate.isReusableWakeFix(
            fix(accuracy: 400, age: 100, now: now), acceptedAccuracy: 500, now: now),
            "battery saver accepts a rough fix; so does its wake")
    }

    func testAStaleOrRoughFixDoesNot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(PushAppDelegate.isReusableWakeFix(
            fix(accuracy: 20, age: 121, now: now), acceptedAccuracy: 100, now: now))
        XCTAssertFalse(PushAppDelegate.isReusableWakeFix(
            fix(accuracy: 150, age: 10, now: now), acceptedAccuracy: 100, now: now))
        XCTAssertFalse(PushAppDelegate.isReusableWakeFix(
            fix(accuracy: -1, age: 10, now: now), acceptedAccuracy: 100, now: now),
            "a negative accuracy is an invalid fix")
        XCTAssertFalse(PushAppDelegate.isReusableWakeFix(
            fix(accuracy: 20, age: -30, now: now), acceptedAccuracy: 100, now: now),
            "a fix from the future is a clock problem, not a position")
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read \(relative) at \(path.path)")
            return ""
        }
        return text
    }

    func testMemberJoinedLoadsLight() {
        let src = source("App/Managers/PushNotificationManager.swift")
        let start = src.range(of: "private static func handleMemberJoined(")
        XCTAssertNotNil(start)
        if let start {
            let body = String(src[start.upperBound...].prefix(1_600))
            XCTAssertTrue(body.contains("try await CircleManager.shared.loadCircles(light: true)"))
        }
    }

    func testTheWakeSendsTheHeldFixWhenItCan() {
        let src = source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(src.contains("let location = try await wakeFix()"))
    }
}
