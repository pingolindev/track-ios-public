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

/// Tapping a "<name> needs attention" notification does what tapping the
/// alert's row on the Alerts tab does, and its follow-ups open the Alerts tab.
/// The tap has a branch of its own: the last-resort fallback would leave the
/// person on whatever tab was open, or move them to Circles when an invitation
/// is pending.
final class AlertTapTests: XCTestCase {
    private let raiser = "11111111-1111-4111-8111-111111111111"
    private let me = "22222222-2222-4222-8222-222222222222"
    private let alertId = "5eb3a4e2-0000-4000-8000-000000000001"

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    private func alert(status: SOSAlert.SOSStatus = .active, userId: String? = nil,
                       latitude: Double? = 37.3349, longitude: Double? = -122.0090) -> SOSAlert {
        SOSAlert(id: alertId, circleId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", userId: userId ?? raiser,
                 status: status, latitude: latitude, longitude: longitude, acknowledgedBy: [],
                 createdAt: Date(timeIntervalSince1970: 1_700_000_000), resolvedAt: nil)
    }

    private func target(_ kind: String?, id: String? = nil, listed: [SOSAlert]) -> PushAppDelegate.AlertTapTarget? {
        PushAppDelegate.alertTapTarget(kind: kind, alertId: id ?? alertId, listed: listed, me: me)
    }

    /// Someone else's live alert, listed with a position: the map, flown to it
    /// with its detail open, for every kind a new alert comes as.
    func testANewAlertOpensOnTheMap() {
        for kind in ["sos", "sos_alert", "emergency"] {
            XCTAssertEqual(target(kind, listed: [alert()]), .map(alertId: alertId), kind)
        }
    }

    /// The push and the app's own notices spell the id as they do; it is the
    /// same alert whatever the spelling.
    func testTheIdMatchesInAnySpelling() {
        XCTAssertEqual(target("sos", id: alertId.uppercased(), listed: [alert()]), .map(alertId: alertId))
        XCTAssertEqual(target("sos", id: alertId.replacingOccurrences(of: "-", with: ""), listed: [alert()]),
                       .map(alertId: alertId))
    }

    /// Anything the map can't open lands on the Alerts tab, where alerts and
    /// their state are: not listed (yet), no id or no UUID, closed, no
    /// position, or the person's own.
    func testWhatTheMapCannotOpenLandsOnTheAlertsTab() {
        XCTAssertEqual(target("sos", listed: []), .alertsTab, "not listed")
        XCTAssertEqual(target("sos", id: "66666666-6666-4666-8666-666666666666", listed: [alert()]), .alertsTab,
                       "another alert is listed")
        XCTAssertEqual(PushAppDelegate.alertTapTarget(kind: "sos", alertId: nil, listed: [alert()], me: me), .alertsTab)
        XCTAssertEqual(target("sos", id: "not-an-id", listed: [alert()]), .alertsTab)
        XCTAssertEqual(target("sos", listed: [alert(status: .resolved)]), .alertsTab, "closed")
        XCTAssertEqual(target("sos", listed: [alert(latitude: nil, longitude: nil)]), .alertsTab, "no position")
        XCTAssertEqual(target("sos", listed: [alert(userId: me.uppercased())]), .alertsTab, "your own")
    }

    /// "… is responding" and "… closed the alert": the Alerts tab, listed or not.
    func testTheFollowUpsOpenTheAlertsTab() {
        for kind in ["sos_acknowledged", "sos_resolved"] {
            XCTAssertEqual(target(kind, listed: [alert()]), .alertsTab, kind)
            XCTAssertEqual(target(kind, listed: []), .alertsTab, kind)
        }
    }

    /// Nothing else is claimed: those taps go on to their own branches.
    func testOtherNotificationsAreNotAlerts() {
        for kind in ["place_alert_enter", "check_in", "circle_invite", "destination_arrival", "signed_out", "sos_refresh"] {
            XCTAssertNil(target(kind, listed: [alert()]), kind)
        }
        XCTAssertNil(target(nil, listed: [alert()]))
    }

    /// The tap's branch: matched on the kind (`type`, else `alert_type`), with
    /// the alert's id from `sos_id`, else `alert_id`, and checked before the copy
    /// sniffs and the last-resort fallback.
    func testTheTapHasItsOwnBranchAheadOfTheFallback() throws {
        let push = try source("App/Managers/PushNotificationManager.swift")
        let tap = try body(of: "        didReceive response: UNNotificationResponse,", until: "\n    }\n", in: push)
        let branch = try XCTUnwrap(tap.range(of: """
                let tapKind = Self.pushKind(from: userInfo)
                if let tapKind, SOSAlarmCopy.newAlertTypes.contains(tapKind) || SOSAlarmCopy.followUpTypes.contains(tapKind) {
                    let sosId = (userInfo["sos_id"] as? String) ?? correlationId
                    Task { @MainActor in
                        await Self.openAlert(kind: tapKind, sosId: sosId)
                        completionHandler()
                    }
                    return
                }

        """))
        for later in ["        if isDestination {\n", "        if isInvite {\n", "        Task { @MainActor in\n            await InvitesManager.shared.refresh()\n"] {
            let at = try XCTUnwrap(tap.range(of: later), later)
            XCTAssertLessThan(branch.upperBound, at.lowerBound, later)
        }
    }

    /// Opening it: after the launch's session check, only with a session; an
    /// alert not listed yet is loaded once; then the map (tab 0, by id) or the
    /// Alerts tab (tab 2).
    func testOpeningWaitsForTheSessionAndLoadsWhatIsNotListed() throws {
        let push = try source("App/Managers/PushNotificationManager.swift")
        let open = try body(of: "    static func openAlert(kind: String, sosId: String?) async {", until: "\n    }\n", in: push)
        XCTAssertTrue(open.contains("""
                while AuthManager.shared.isCheckingSession && waited < 40 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waited += 1
                }
                guard !AuthManager.shared.isCheckingSession, AuthManager.shared.isAuthenticated else {
        """))
        XCTAssertTrue(open.contains("""
                var target = alertTapTarget(kind: kind, alertId: sosId, listed: sos.visibleAlerts, me: AuthManager.shared.userId)
                if target == .alertsTab, SOSAlarmCopy.newAlertTypes.contains(kind) {
                    try? await sos.loadActiveAlerts()
                    target = alertTapTarget(kind: kind, alertId: sosId, listed: sos.visibleAlerts, me: AuthManager.shared.userId)
                }
        """))
        XCTAssertTrue(open.contains("""
                case .map(let alertId)?:
                    TabSelectionState.shared.selected = 0
                    NotificationRouteState.shared.pending = .focusAlert(alertId: alertId)
        """))
        XCTAssertTrue(open.contains("""
                case .alertsTab?:
                    TabSelectionState.shared.selected = 2
        """))
    }

    /// The map opens it as the Alerts tab's row does (`pendingFocusSOS`): it
    /// looks the alert up when it shows it, flies there and opens its detail.
    /// One that ended, or lost its position, since the tap opens the Alerts tab
    /// instead of a bare map.
    func testTheMapOpensTheAlertItLists() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let routes = try body(of: ".onReceive(notificationRoute.$pending) { route in", until: "\n            }\n", in: map)
        XCTAssertTrue(routes.contains("""
                        case .focusAlert(let alertId):
                            if let alert = sosManager.activeAlerts.first(where: { CanonicalId.same($0.id, alertId) }),
                               let coord = alert.coordinate {
                                show(alert, at: coord)
                                mapTapState.selectedSOS = alert
                                mapTapState.showingSOSDetail = true
                            } else {
        """))
        let ended = try body(of: "                    } else {\n", until: "\n                    }\n", in: String(routes))
        XCTAssertTrue(ended.contains("TabSelectionState.shared.selected = 2"))
    }

    /// Tab 2 is the Alerts tab, and 0 the map.
    func testTheTabsAreWhereTheTapSendsIt() throws {
        let tabs = try source("App/Views/MainTabView.swift")
        XCTAssertTrue(tabs.contains("""
                    SOSView()
                        .tabItem {
                            Label("Alerts", systemImage: sosManager.hasActiveAlert ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        }
                        .tag(2)
        """))
        XCTAssertTrue(tabs.contains("""
                        .tabItem {
                            Label("Map", systemImage: "map.fill")
                        }
                        .tag(0)
        """))
    }
}
