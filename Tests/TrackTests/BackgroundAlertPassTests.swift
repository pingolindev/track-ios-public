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

/// The background alert-evaluation pass, and the background tasks around it.
///
/// WHY THIS IS WORTH TESTING
///   While signed in the app is never suspended (the location request keeps the
///   process alive), so MonitoringManager's 15-minute timer runs all night on
///   every iPhone, and whatever one pass costs is paid all night. So a pass
///   reuses its rule lists for an hour, never calls a route the server does not
///   serve (`/api/v1/inactivity-events` can only 404), and fetches each
///   circle's latest locations once for every evaluator. No no-op
///   BGProcessingTask is submitted on backgrounding.
final class BackgroundAlertPassTests: XCTestCase {

    // MARK: - Timer cadence

    func testTheTimerRunsEveryFifteenMinutesWithTolerance() {
        XCTAssertEqual(MonitoringManager.evaluationTimerInterval, 900)
        XCTAssertEqual(MonitoringManager.evaluationTimerTolerance, 90)
    }

    func testEveryTickRunsOutsideBatterySaver() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(MonitoringManager.timerPassIsDue(lastPassAt: nil, now: t0, batterySaver: false))
        XCTAssertTrue(MonitoringManager.timerPassIsDue(
            lastPassAt: t0, now: t0.addingTimeInterval(900), batterySaver: false))
    }

    func testBatterySaverRunsEveryOtherTick() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(MonitoringManager.timerPassIsDue(lastPassAt: nil, now: t0, batterySaver: true),
                      "the first tick in battery saver still runs")
        XCTAssertFalse(MonitoringManager.timerPassIsDue(
            lastPassAt: t0, now: t0.addingTimeInterval(900), batterySaver: true))
        // A tick late by the whole tolerance still lands on the 30-minute pass.
        XCTAssertTrue(MonitoringManager.timerPassIsDue(
            lastPassAt: t0, now: t0.addingTimeInterval(1_800 - 100), batterySaver: true))
        XCTAssertTrue(MonitoringManager.timerPassIsDue(
            lastPassAt: t0, now: t0.addingTimeInterval(1_800), batterySaver: true))
    }

    // MARK: - Rule-list reuse

    func testRuleListsAreReusedForAnHour() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MonitoringManager.ruleListMaxAge, 3600)
        XCTAssertTrue(InactivityAlertsManager.isStale(lastRefreshedAt: nil, maxAge: 3600, now: t0),
                      "never fetched (or invalidated) always fetches")
        XCTAssertFalse(InactivityAlertsManager.isStale(
            lastRefreshedAt: t0, maxAge: 3600, now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(InactivityAlertsManager.isStale(
            lastRefreshedAt: t0, maxAge: 3600, now: t0.addingTimeInterval(3600)))
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

    func testNothingCallsTheRemovedInactivityEventsRoutes() {
        // The server does not serve these routes. A client call can only
        // ever 404, and it would cost a request on every background pass.
        for file in ["App/Services/APIService.swift",
                     "App/Managers/InactivityAlertsManager.swift",
                     "App/Managers/MonitoringManager.swift",
                     "App/Views/Alerts/AlertsView.swift"] {
            let src = source(file)
            XCTAssertFalse(src.contains("\"/api/v1/inactivity-events"), "\(file) calls a removed route")
            XCTAssertFalse(src.contains("listInactivityEvents("), "\(file) still lists inactivity events")
        }
    }

    func testEveryEvaluatorSharesOneFetchPerCirclePerPass() {
        let src = source("App/Managers/MonitoringManager.swift")
        // The only direct fetch is the pass cache's own; the evaluators go
        // through `memberRefresh(for:)`.
        XCTAssertEqual(src.components(separatedBy: "CircleManager.shared.loadMemberLocations(").count - 1, 1)
        XCTAssertEqual(src.components(separatedBy: "circleManager.loadMemberLocations(").count - 1, 0)
        XCTAssertGreaterThanOrEqual(src.components(separatedBy: "try await memberRefresh(for: circleId)").count - 1, 3)
    }

    func testTheAlertsCheckPushRunsOnePassWithFreshLists() {
        let push = source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(push.contains("await MonitoringManager.shared.evaluateForAlertsCheck()"))
        let monitor = source("App/Managers/MonitoringManager.swift")
        let start = monitor.range(of: "func evaluateForAlertsCheck() async {")
        XCTAssertNotNil(start)
        if let start {
            let body = String(monitor[start.upperBound...].prefix(400))
            XCTAssertTrue(body.contains("invalidateRuleLists()"))
            XCTAssertTrue(body.contains("await runPass {"))
        }
    }

    func testTheRetiredProcessingTaskIsGoneEverywhere() {
        let plist = source("App/Info.plist")
        XCTAssertFalse(plist.contains("com.pingolin.track.location-sync"))
        XCTAssertFalse(plist.contains("<string>processing</string>"))
        XCTAssertTrue(plist.contains("com.pingolin.track.refresh"))

        let scheduler = source("App/Services/BackgroundTaskScheduler.swift")
        // Registering an identifier missing from the plist crashes at launch;
        // the one `register` left must be the refresh task.
        XCTAssertEqual(scheduler.components(separatedBy: "BGTaskScheduler.shared.register(").count - 1, 1)
        XCTAssertFalse(scheduler.contains("BGProcessingTaskRequest"))
        XCTAssertTrue(scheduler.contains("cancel(taskRequestWithIdentifier: Self.retiredLocationSyncTaskId)"))

        for file in ["App/TrackApp.swift", "App/Managers/PushNotificationManager.swift"] {
            XCTAssertFalse(source(file).contains("scheduleNextLocationSync"), "\(file) still schedules it")
        }
    }

    func testTheBackgroundRefreshLoadsLight() {
        let scheduler = source("App/Services/BackgroundTaskScheduler.swift")
        XCTAssertTrue(scheduler.contains("try await CircleManager.shared.loadCircles(light: true)"))
        XCTAssertFalse(scheduler.contains("try await CircleManager.shared.loadCircles()"))
    }
}
