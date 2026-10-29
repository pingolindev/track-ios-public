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

/// A circle's alert rules judge a member by THAT circle's row of them.
/// `memberLocations` holds one row per member, the last circle's to accept
/// one; an evaluator reading it would judge a member of two circles in one by
/// the other's "Allow alerts on me" and battery, which are set per circle. The
/// battery pass reuses each circle's refresh from the inactivity pass, so it
/// too must read each circle's own row.
final class CircleRowMemoryTests: XCTestCase {

    private let family = "8b96aa7c-0000-4000-8000-0000000000f1"
    private let work = "8b96aa7c-0000-4000-8000-0000000000f2"
    private let ana = "0b5f5bf1-0000-4000-8000-0000000000a1"
    private let ben = "0b5f5bf1-0000-4000-8000-0000000000b1"
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(_ circleId: String, _ userId: String, battery: Int?, alerts: Bool?,
                     at time: Date? = nil) -> LocationData {
        LocationData(circleId: circleId, userId: userId, deviceId: "d", latitude: 37.3349, longitude: -122.0090,
                     batteryLevel: battery, timestamp: time ?? at, allowAlertsOnMe: alerts)
    }

    /// Ana's one update, sealed for each circle: Family is shown her battery
    /// and may alert on her; Work is shown no battery and may not. Whichever
    /// circle accepted it last, each is judged by its own row.
    func testEachCircleJudgesByItsOwnRow() {
        for familyLast in [false, true] {
            var memory = CircleRowMemory()
            let rows = [fix(family, ana, battery: 12, alerts: true), fix(work, ana, battery: nil, alerts: false)]
            for row in familyLast ? rows.reversed() : rows { memory.accept(row) }
            XCTAssertEqual(memory.row(of: ana, in: family)?.batteryLevel, 12, "Family last: \(familyLast)")
            XCTAssertEqual(memory.row(of: ana, in: family)?.allowAlertsOnMe, true)
            XCTAssertNil(memory.row(of: ana, in: work)?.batteryLevel, "Work isn't shown her battery")
            XCTAssertEqual(memory.row(of: ana, in: work)?.allowAlertsOnMe, false, "nor may it alert on her")
            XCTAssertNil(memory.row(of: ben, in: family))
        }
    }

    /// A newer row in one circle leaves the other circle's as it was.
    func testANewerRowInOneCircleLeavesTheOther() {
        var memory = CircleRowMemory()
        memory.accept(fix(family, ana, battery: 50, alerts: true, at: at))
        memory.accept(fix(work, ana, battery: 40, alerts: true, at: at.addingTimeInterval(60)))
        memory.accept(fix(family, ana, battery: 30, alerts: true, at: at.addingTimeInterval(120)))
        XCTAssertEqual(memory.row(of: ana, in: work)?.batteryLevel, 40)
        XCTAssertEqual(memory.row(of: ana, in: work)?.timestamp, at.addingTimeInterval(60))
        XCTAssertEqual(memory.row(of: ana, in: family)?.batteryLevel, 30)
        XCTAssertEqual(memory.row(of: ana, in: family)?.timestamp, at.addingTimeInterval(120))
    }

    /// Ids in any spelling, as the replay guard keys them.
    func testAnySpelling() {
        var memory = CircleRowMemory()
        memory.accept(fix(family.uppercased(), ana.uppercased(), battery: 12, alerts: true))
        XCTAssertEqual(memory.row(of: ana, in: family)?.batteryLevel, 12)
        memory.keepOnly([ana.uppercased()], in: family.uppercased())
        XCTAssertNotNil(memory.row(of: ana, in: family), "still shown")
        memory.forget(circleId: family, userId: ana)
        XCTAssertNil(memory.row(of: ana.uppercased(), in: family.uppercased()))
    }

    /// Each trim touches its own circle and no other.
    func testTheTrimsTouchOnlyTheirCircle() {
        var memory = CircleRowMemory()
        for circle in [family, work] {
            for person in [ana, ben] { memory.accept(fix(circle, person, battery: 9, alerts: true)) }
        }
        memory.keepOnly([ana], in: family)
        XCTAssertNotNil(memory.row(of: ana, in: family))
        XCTAssertNil(memory.row(of: ben, in: family), "no longer shown there")
        XCTAssertNotNil(memory.row(of: ben, in: work), "still shown here")
        memory.forget(circleId: work, userId: ana)
        XCTAssertNil(memory.row(of: ana, in: work))
        XCTAssertNotNil(memory.row(of: ana, in: family))
        memory.forget(circleId: family)
        XCTAssertNil(memory.row(of: ana, in: family))
        XCTAssertNotNil(memory.row(of: ben, in: work))
        memory.removeAll()
        XCTAssertNil(memory.row(of: ben, in: work))
    }

    /// A replay drop still carries a "no" the server serves now: Ana turned
    /// alerts on her off in Family and went quiet, and the server re-serves her
    /// last fix with it. Only the "no": the fix, its time and battery stay the
    /// held row's; nothing held, nothing taken.
    func testAReServedRowStillCarriesAWithdrawal() {
        var memory = CircleRowMemory()
        memory.accept(fix(family, ana, battery: 12, alerts: true, at: at.addingTimeInterval(60)))
        memory.takeWithdrawal(of: fix(family, ana, battery: 99, alerts: false, at: at))
        XCTAssertEqual(memory.row(of: ana, in: family)?.allowAlertsOnMe, false, "held true + served false")
        XCTAssertEqual(memory.row(of: ana, in: family)?.timestamp, at.addingTimeInterval(60), "never rewound")
        XCTAssertEqual(memory.row(of: ana, in: family)?.batteryLevel, 12)
        memory.takeWithdrawal(of: fix(work, ana, battery: 5, alerts: false))
        XCTAssertNil(memory.row(of: ana, in: work), "nothing held, nothing taken")
        memory.accept(fix(work, ben, battery: 40, alerts: true))
        memory.takeWithdrawal(of: fix(work.uppercased(), ben.uppercased(), battery: nil, alerts: false))
        XCTAssertEqual(memory.row(of: ben, in: work)?.allowAlertsOnMe, false, "any spelling")
    }

    /// Never a "yes" from a dropped row: a replay needs nothing from the
    /// member, so a server re-serving a quiet member's last fix with true,
    /// or with nothing, must not have them judged again. Their next fix does.
    func testAReServedRowNeverRaisesConsent() {
        var memory = CircleRowMemory()
        memory.accept(fix(family, ana, battery: 12, alerts: false))
        memory.takeWithdrawal(of: fix(family, ana, battery: 12, alerts: true))
        XCTAssertEqual(memory.row(of: ana, in: family)?.allowAlertsOnMe, false, "held false + served true")
        memory.takeWithdrawal(of: fix(family, ana, battery: 12, alerts: nil))
        XCTAssertEqual(memory.row(of: ana, in: family)?.allowAlertsOnMe, false, "held false + served nil")
        memory.accept(fix(work, ana, battery: 12, alerts: true))
        memory.takeWithdrawal(of: fix(work, ana, battery: 12, alerts: nil))
        XCTAssertEqual(memory.row(of: ana, in: work)?.allowAlertsOnMe, true, "held true + served nil: as held")
        memory.accept(fix(family, ana, battery: 12, alerts: true, at: at.addingTimeInterval(60)))
        XCTAssertEqual(memory.row(of: ana, in: family)?.allowAlertsOnMe, true, "their next fix does")
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The inactivity rules, the battery rules and the self alerts all read
    /// the circle's own row, and nothing there reads `memberLocations`.
    func testEveryAlertPassReadsTheCirclesOwnRow() throws {
        let monitor = try source("App/Managers/MonitoringManager.swift")
        XCTAssertFalse(monitor.contains("circleManager.memberLocations["))
        XCTAssertTrue(monitor.contains("""
                            let circleRow = circleManager.acceptedRow(of: member.userId, in: circleId)
                            if circleRow?.allowAlertsOnMe == false { continue }
                            // Never seen this member's location → can't judge fairly.
                            guard let lastSeen = circleRow?.timestamp else { continue }
        """))
        XCTAssertTrue(monitor.contains("""
                        let circleRow = circleManager.acceptedRow(of: targetId, in: circleId)
                        if circleRow?.allowAlertsOnMe == false { continue }
                        guard let level = circleRow?.batteryLevel else { continue }
        """))
        XCTAssertTrue(monitor.contains(
            "guard let lastSeen = circleManager.acceptedRow(of: alert.userId, in: circleId)?.timestamp else { continue }"))
    }

    /// Written where a row is accepted, and trimmed wherever `memberLocations`
    /// is: a member no longer shown, frozen, drawn nowhere, a circle gone, a
    /// sign-out.
    func testItIsKeptInStepWithTheMap() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                    updatedLocations[userId] = data
                    rowsByCircle.accept(data)
                    accepted.append(data)
        """))
        XCTAssertEqual(manager.components(separatedBy: "rowsByCircle.accept(").count - 1, 2,
                       "accepted rows only: a row accepted, or the same row redrawn on a replay drop")
        XCTAssertTrue(manager.contains("            if fresh[userId] == nil { rowsByCircle.forget(circleId: circleId, userId: userId) }\n"))
        XCTAssertTrue(manager.contains("""
                rowsByCircle.keepOnly(shown, in: circleId)
                frozenLocations = frozenLocations.filter { _, loc in
        """))
        XCTAssertTrue(manager.contains("""
                        rowsByCircle.forget(circleId: circleId, userId: member.userId)
                        approximateAreas.forget(circleId: circleId, userId: member.userId)
        """))
        XCTAssertTrue(manager.contains("""
                rowsByCircle.forget(circleId: circleId)
                privacySettings.removeValue(forKey: circleId)
        """))
        XCTAssertTrue(manager.contains("""
                memberLocations = [:]
                rowsByCircle.removeAll()
        """))
        XCTAssertTrue(manager.contains("        rowsByCircle.row(of: userId, in: circleId)\n"))
    }

    /// This circle's own row redrawn on a replay drop: a member of Work who
    /// switched to approximate there with no new fix reads "Approximate
    /// location" on the Circles tab in Work too, not only on the map, and the
    /// redraw keeps a "no" taken just before, their time and battery.
    func testAReplayDropRedrawsTheCirclesOwnRowKeepingTheNo() throws {
        var memory = CircleRowMemory()
        var areas = ApproximateAreaMemory()
        memory.accept(fix(work, ana, battery: 30, alerts: true))
        var served = fix(work, ana, battery: 30, alerts: false)
        served.approximate = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
        memory.takeWithdrawal(of: served)
        let own = try XCTUnwrap(CircleManager.heldFix(memory.row(of: ana, in: work), takingPostureOf: served,
                                                      areas: &areas))
        memory.accept(own)
        XCTAssertNotNil(memory.row(of: ana, in: work)?.approximate)
        XCTAssertEqual(memory.row(of: ana, in: work)?.allowAlertsOnMe, false, "the no kept")
        XCTAssertEqual(memory.row(of: ana, in: work)?.timestamp, at)
        XCTAssertEqual(memory.row(of: ana, in: work)?.batteryLevel, 30)
    }

    /// The redraw restates the HELD fix, never the dropped one: what it
    /// writes is this circle's row, which the alert rules read, so a dropped
    /// row's "yes" or nothing, its earlier time and its battery must never
    /// reach it. Ana had alerts off at her last fix and went quiet; the server
    /// re-serves an older fix of hers with a "yes", or with nothing, as
    /// approximate.
    func testTheRedrawRestatesTheHeldFixNotTheDroppedOne() throws {
        for served in [true, nil] as [Bool?] {
            var memory = CircleRowMemory()
            var areas = ApproximateAreaMemory()
            memory.accept(fix(work, ana, battery: 30, alerts: false, at: at))
            var dropped = fix(work, ana, battery: 99, alerts: served, at: at.addingTimeInterval(-3_600))
            dropped.approximate = try XCTUnwrap(ApproximateArea(sharingMode: "approximate", radiusMiles: 2))
            memory.takeWithdrawal(of: dropped)
            let own = try XCTUnwrap(CircleManager.heldFix(memory.row(of: ana, in: work), takingPostureOf: dropped,
                                                          areas: &areas))
            memory.accept(own)
            let row = try XCTUnwrap(memory.row(of: ana, in: work))
            XCTAssertEqual(row.allowAlertsOnMe, false, "served \(String(describing: served)): still the no")
            XCTAssertEqual(row.timestamp, at, "the held time, never the dropped one's")
            XCTAssertEqual(row.batteryLevel, 30, "the held battery")
            XCTAssertNotNil(row.approximate, "drawn as they share now")
        }
    }

    /// The Circles tab's member row: its "Last seen" and its dot's age come from
    /// this circle's row, the map's when it is this circle's (redrawn as they
    /// share now), else this circle's own.
    func testTheCirclesRowReadsItsOwnCircle() throws {
        let circles = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(circles.contains("""
                return MapView.heldRow(circleManager.memberLocations[member.userId], in: circle.id)
                    ?? circleManager.acceptedRow(of: member.userId, in: circle.id)
        """))
    }

    /// The replay drop hands a served "no" on, and redraws this circle's own
    /// row as they share now (as the map's), before it moves past the row.
    func testAReplayDropTakesAServedWithdrawal() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("""
                        rowsByCircle.takeWithdrawal(of: row)
                        // How they share here now goes to this circle's own row too, as to
                        // the map's below: the Circles tab's "Approximate location" reads it.
                        if let own = Self.heldFix(rowsByCircle.row(of: userId, in: circleId), takingPostureOf: row,
                                                  areas: &approximateAreas) {
                            rowsByCircle.accept(own)
                        }
                        if let held = Self.heldFix(updatedLocations[userId], takingPostureOf: row, areas: &approximateAreas) {
        """))
        XCTAssertEqual(manager.components(separatedBy: "rowsByCircle.takeWithdrawal(").count - 1, 1)
    }
}
