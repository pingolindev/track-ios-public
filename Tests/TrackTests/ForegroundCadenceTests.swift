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

/// How often the foreground refreshes and the email-verification poll run.
///
/// WHY THIS IS WORTH TESTING
///   - Only member locations need the foreground loop's cadence: circles,
///     members and privacy re-fetched on every tick would be six GETs a tick
///     with two circles, about a thousand an hour.
///   - iOS emits `.active` for every return from Control Centre, the
///     notification shade and the app switcher, so the refreshes it triggers
///     (invites, SOS) run at most once per minute.
///   - The email-verification poll backs off: every 5 s with nothing to stop
///     it but success or logout, it would run all night for an unverified
///     user whose process tracking keeps alive.
final class ForegroundCadenceTests: XCTestCase {

    func testMemberLocationsFollowTheVisibleMapAtThirtySeconds() {
        XCTAssertEqual(ForegroundRefreshCadence.locationsInterval, 30)
        XCTAssertTrue(ForegroundRefreshCadence.shouldLoadMemberLocations(selectedTab: 0))
        XCTAssertFalse(ForegroundRefreshCadence.shouldLoadMemberLocations(selectedTab: 1))
        XCTAssertFalse(ForegroundRefreshCadence.shouldLoadMemberLocations(selectedTab: 4))
    }

    func testCirclesRefreshEveryFewMinutes() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(ForegroundRefreshCadence.circlesAreDue(lastRefreshAt: nil, now: t0))
        XCTAssertFalse(ForegroundRefreshCadence.circlesAreDue(lastRefreshAt: t0, now: t0.addingTimeInterval(20)))
        XCTAssertFalse(ForegroundRefreshCadence.circlesAreDue(lastRefreshAt: t0, now: t0.addingTimeInterval(160)))
        // A tick a few seconds early must not push the list to the next one.
        XCTAssertTrue(ForegroundRefreshCadence.circlesAreDue(lastRefreshAt: t0, now: t0.addingTimeInterval(178)))
    }

    func testForegroundRefreshesRunAtMostOncePerMinute() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ForegroundRefreshThrottle.minimumInterval, 60)
        XCTAssertTrue(ForegroundRefreshThrottle.isDue(last: nil, now: t0, interval: 60))
        XCTAssertFalse(ForegroundRefreshThrottle.isDue(last: t0, now: t0.addingTimeInterval(59), interval: 60))
        XCTAssertTrue(ForegroundRefreshThrottle.isDue(last: t0, now: t0.addingTimeInterval(60), interval: 60))
    }

    func testEmailVerificationPollBacksOffToThirtySeconds() {
        XCTAssertEqual(AuthManager.emailVerificationPollDelay(afterAttempts: 0), 5)
        XCTAssertEqual(AuthManager.emailVerificationPollDelay(afterAttempts: 1), 10)
        XCTAssertEqual(AuthManager.emailVerificationPollDelay(afterAttempts: 2), 20)
        XCTAssertEqual(AuthManager.emailVerificationPollDelay(afterAttempts: 3), 30)
        XCTAssertEqual(AuthManager.emailVerificationPollDelay(afterAttempts: 50), 30)
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

    func testTheVerificationPollStopsOffScreenAndInTheBackground() {
        let view = source("App/Views/Auth/EmailVerificationView.swift")
        XCTAssertTrue(view.contains(".onDisappear {"))
        XCTAssertTrue(view.contains("authManager.stopEmailVerificationPolling()"))
        XCTAssertTrue(view.contains("} else if phase == .background {"))
        let auth = source("App/Managers/AuthManager.swift")
        XCTAssertFalse(auth.contains("withTimeInterval: 5.0, repeats: true"),
                       "no unconditional 5 s repeating timer")
    }

    func testTheRootViewDoesNotObserveTheCircleManager() {
        // Observing CircleManager would re-evaluate the whole tab view on every
        // publish, and the root view reads none of its state.
        let src = source("App/Views/MainTabView.swift")
        XCTAssertFalse(src.contains("@StateObject private var circleManager"))
        XCTAssertFalse(src.contains("@ObservedObject private var circleManager"))
    }

    func testTheForegroundHandlerGatesInvitesAndSOS() {
        let src = source("App/TrackApp.swift")
        XCTAssertTrue(src.contains("if throttle.allow(\"invites\") {"))
        XCTAssertTrue(src.contains("if throttle.allow(\"sos.active\") {"))
    }

    func testTheSOSCardHasNoPerCardTimer() {
        let src = source("App/Views/Safety/SOSView.swift")
        XCTAssertFalse(src.contains("Timer.publish(every: 60"),
                       "a per-card minute timer keeps firing all night once the tab was visited")
        XCTAssertTrue(src.contains("TimelineView(.everyMinute)"))
    }
}
