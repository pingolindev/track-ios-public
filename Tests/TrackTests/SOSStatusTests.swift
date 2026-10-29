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

/// What an SOS status this build does not recognise is allowed to become.
///
/// WHY THIS IS WORTH TESTING
///   `.active` is the single most privileged value the enum has: it alone
///   draws a map marker (`isMappable`), fills the red "Active Alerts" section,
///   and sounds the alarm. A status the app cannot read that decoded as
///   `.active` would be a **phantom emergency** — a red banner and an alarm
///   about a person who is fine. So `SOSStatus.from(_:)` maps anything it
///   doesn't know to `.unknown`, which grants none of that.
///
///   The server writes `'active'`, `'resolved'` and `'false_alarm'`, plus
///   `'acknowledged'` on older rows, and all four are here. The status is a
///   free-form string on the wire, so a value this build has never seen can
///   still arrive.
///
///   Note the two axes are deliberately asymmetric — see
///   `testAnUnknownStatusDoesNotRetireTheRaisersOwnAlert`.
final class SOSStatusTests: XCTestCase {

    private func alert(
        status: SOSAlert.SOSStatus,
        acknowledgedByMe: Bool = false,
        dismissedByMe: Bool = false
    ) -> SOSAlert {
        SOSAlert(
            id: "5eb3a4e2-0000-4000-8000-000000000001",
            circleId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            userId: "11111111-1111-1111-1111-111111111111",
            status: status,
            latitude: 37.7749,
            longitude: -122.4194,
            acknowledgedBy: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            resolvedAt: nil,
            acknowledgedByMe: acknowledgedByMe,
            dismissedByMe: dismissedByMe
        )
    }

    // MARK: - The decode path

    /// THE RULE. Defaulting with `?? .active` would make every unreadable
    /// status a live emergency.
    func testAnUnrecognisedStatusNeverDecodesAsActive() {
        for raw in ["escalated", "expired", "standby", "", "ACTIVE", "active ", "🙂"] {
            let decoded = SOSAlert.SOSStatus.from(raw)
            XCTAssertNotEqual(decoded, .active, "\"\(raw)\" must not be coerced to active")
            XCTAssertFalse(decoded.isLive, "\"\(raw)\" must not be a live emergency")
            XCTAssertEqual(decoded, .unknown, "\"\(raw)\" is not a status this build knows")
        }
    }

    /// The four the server can actually produce still decode to themselves —
    /// the fail-closed default must not be swallowing real values. In
    /// particular `false_alarm` is the one whose raw value differs from its
    /// case name, so it is the one a careless `from(_:)` would drop.
    func testEveryStatusTheServerWritesRoundTrips() {
        XCTAssertEqual(SOSAlert.SOSStatus.from("active"), .active)
        XCTAssertEqual(SOSAlert.SOSStatus.from("acknowledged"), .acknowledged)
        XCTAssertEqual(SOSAlert.SOSStatus.from("resolved"), .resolved)
        XCTAssertEqual(SOSAlert.SOSStatus.from("false_alarm"), .falseAlarm)
    }

    /// Exactly one status is a live emergency. Map presence, the alarm gate and
    /// the "Active Alerts" section all route through `isLive`, so this is the
    /// whole privilege rule in one assertion.
    func testOnlyActiveIsLive() {
        XCTAssertEqual(SOSAlert.SOSStatus.allCases.filter(\.isLive), [.active])
    }

    // MARK: - The three things `.active` grants

    /// No map marker. The most exposing half: a marker claiming somebody is in
    /// an emergency at a specific coordinate.
    func testAnUnknownStatusIsNotMappable() {
        XCTAssertTrue(alert(status: .active).isMappable, "control: a real emergency IS mappable")
        XCTAssertFalse(alert(status: .unknown).isMappable)
    }

    /// No alarm. This is the gate in `SOSManager.loadActiveAlerts`: it
    /// sounds the alarm only for `alert.status.isLive &&
    /// !acknowledgedByMe && !dismissedByMe` (and an alert that may alarm
    /// at all), so an unknown status must fail the `isLive` clause on its
    /// own, with nothing acknowledged or dismissed to save it.
    func testAnUnknownStatusDoesNotSoundTheAlarm() {
        let needsAttention = { (a: SOSAlert) in
            a.status.isLive && !a.acknowledgedByMe && !a.dismissedByMe
        }
        XCTAssertTrue(needsAttention(alert(status: .active)), "control: a real emergency DOES alarm")
        XCTAssertFalse(needsAttention(alert(status: .unknown)))
    }

    /// Not shown as a live alert, and not silently relabelled as one.
    /// `effectiveStatus` promotes only a genuinely `.active` alert.
    func testAnUnknownStatusIsNotDisplayedAsActive() {
        XCTAssertEqual(alert(status: .unknown).effectiveStatus, .unknown)
        XCTAssertEqual(SOSAlert.SOSStatus.unknown.displayName, "Unknown status")
        XCTAssertNotEqual(SOSAlert.SOSStatus.unknown.color, SOSAlert.SOSStatus.active.color,
                          "an unreadable status must not render in the emergency colour")
    }

    /// An alert the viewer already acknowledged is shown as "acknowledged"
    /// rather than by its wire status — but ONLY when the wire status is
    /// genuinely live. An unknown status must not be laundered into
    /// `.acknowledged`, which would read as a handled emergency.
    func testAcknowledgingDoesNotLaunderAnUnknownStatus() {
        XCTAssertEqual(alert(status: .active, acknowledgedByMe: true).effectiveStatus, .acknowledged)
        XCTAssertEqual(alert(status: .unknown, acknowledgedByMe: true).effectiveStatus, .unknown)
    }

    // MARK: - The other direction

    /// Failing closed cuts BOTH ways, and this is the half that is easy to get
    /// backwards. Dropping the row, or treating an unknown status as an ending,
    /// would retire the raiser's own alert — stopping their status poll and
    /// taking the Resolve / False alarm controls with it — on the strength of a
    /// value the app could not read. That hides a real emergency, the mirror
    /// image of decoding an unknown status as active.
    ///
    /// Only the two statuses the server writes as an ending close an alert:
    /// resolving writes 'resolved', and a false alarm writes 'false_alarm'.
    func testAnUnknownStatusDoesNotRetireTheRaisersOwnAlert() {
        XCTAssertFalse(SOSAlert.SOSStatus.unknown.isClosed,
                       "an unreadable status must not be mistaken for an ending")
        XCTAssertFalse(SOSAlert.SOSStatus.active.isClosed)
        XCTAssertFalse(SOSAlert.SOSStatus.acknowledged.isClosed,
                       "acknowledged is still open: the server keeps the alert live")
        XCTAssertTrue(SOSAlert.SOSStatus.resolved.isClosed)
        XCTAssertTrue(SOSAlert.SOSStatus.falseAlarm.isClosed)
    }

    /// Inert and open at the same time is the whole point, and the two
    /// predicates are independent — an unknown status is neither a live
    /// emergency nor a finished one.
    func testUnknownIsNeitherLiveNorClosed() {
        XCTAssertFalse(SOSAlert.SOSStatus.unknown.isLive)
        XCTAssertFalse(SOSAlert.SOSStatus.unknown.isClosed)
    }
}
