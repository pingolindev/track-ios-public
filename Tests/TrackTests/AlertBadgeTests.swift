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

/// The Alerts tab's badge counts what that tab still asks of you: other
/// people's live alerts you haven't dismissed — not your own open alert, not a
/// closed one waiting for the next load, not a dismissed one in its 24 h undo
/// window. The "Active Alerts" list and the badge share one filter.
final class AlertBadgeTests: XCTestCase {
    private typealias M = Track.SOSManager

    private let me = "c0000000-0000-4000-8000-00000000000c"
    private let other = "d0000000-0000-4000-8000-00000000000d"
    private let circle = "e0000000-0000-4000-8000-00000000000e"

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func alert(_ n: Int, by userId: String, status: SOSAlert.SOSStatus = .active,
                       dismissedHoursAgo: Double? = nil) -> SOSAlert {
        var alert = SOSAlert(id: "f0000000-0000-4000-8000-00000000000\(n)", circleId: circle, userId: userId,
                             status: status, latitude: 37.3349, longitude: -122.0090, acknowledgedBy: [],
                             createdAt: Date().addingTimeInterval(-300))
        if let hours = dismissedHoursAgo {
            alert.dismissedByMe = true
            alert.dismissedAt = Date().addingTimeInterval(-hours * 3600)
        }
        return alert
    }

    func testTheBadgeCountsOtherPeoplesLiveAlertsOnly() {
        XCTAssertEqual(M.badgeCount([alert(1, by: other)], me: me), 1)
        XCTAssertEqual(M.badgeCount([alert(1, by: other), alert(2, by: other)], me: me), 2)
        XCTAssertEqual(M.badgeCount([alert(1, by: me)], me: me), 0, "your own is on its own card")
        XCTAssertEqual(M.badgeCount([alert(1, by: me.uppercased())], me: me), 0, "your own in any spelling")
        for closed in [SOSAlert.SOSStatus.resolved, .falseAlarm, .unknown] {
            XCTAssertEqual(M.badgeCount([alert(1, by: other, status: closed)], me: me), 0, closed.rawValue)
        }
        XCTAssertEqual(M.badgeCount([alert(1, by: other, dismissedHoursAgo: 1)], me: me), 0,
                       "dismissed, in its undo window")
        XCTAssertEqual(M.badgeCount([alert(1, by: other, dismissedHoursAgo: 25)], me: me), 0, "dismissed, past it")
        XCTAssertEqual(M.badgeCount([alert(1, by: other), alert(2, by: me), alert(3, by: other, status: .resolved),
                                     alert(4, by: other, dismissedHoursAgo: 1)], me: me), 1)
    }

    /// "I'm Safe" (or "False Alarm", or another's close seen by the poll)
    /// updates the row in place until the next load: the badge drops at once.
    func testAClosedAlertLeavesTheBadgeAtOnce() {
        var alerts = [alert(1, by: other), alert(2, by: me)]
        XCTAssertEqual(M.badgeCount(alerts, me: me), 1)
        alerts[0].status = .resolved
        XCTAssertEqual(M.badgeCount(alerts, me: me), 0)
    }

    /// The list keeps a dismissed alert through its undo window (that row is the
    /// way back); the badge doesn't count it. Both read the one filter.
    func testTheListAndTheBadgeShareOneFilter() throws {
        let alerts = [alert(1, by: other), alert(2, by: me), alert(3, by: other, status: .resolved),
                      alert(4, by: other, dismissedHoursAgo: 1)]
        XCTAssertEqual(M.othersLive(alerts, me: me).map(\.id), [alerts[0].id, alerts[3].id])
        XCTAssertEqual(M.othersLive(alerts, me: nil).count, 3, "signed out, nobody's is mine")
        let tabs = try source("App/Views/MainTabView.swift")
        XCTAssertTrue(tabs.contains(".badge(sosManager.badgeCount)"))
        XCTAssertFalse(tabs.contains("visibleAlerts.count"))
        let manager = try source("App/Managers/SOSManager.swift")
        XCTAssertTrue(manager.contains(
            "    var badgeCount: Int { Self.badgeCount(activeAlerts, me: AuthManager.shared.userId) }"))
        let view = try source("App/Views/Safety/SOSView.swift")
        XCTAssertTrue(view.contains("""
            var otherAlerts: [SOSAlert] {
                SOSManager.othersLive(alerts, me: AuthManager.shared.userId)
            }
        """))
    }
}
