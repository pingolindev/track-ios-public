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

/// One far-future authenticated time must not pin the replay guard or a place
/// alert's watermark. MAX_FUTURE_SKEW_MS (the same on the web and Android): a
/// location beyond now + skew is dropped; a stored guard or watermark beyond it
/// reads as absent, and the alert standing is kept, so nothing re-fires. Keys
/// are the member's one canonical form.
final class FutureSkewTests: XCTestCase {

    private typealias C = Track.CircleManager
    private let now: Int64 = 1_727_700_000_000

    func testTheSkewIsTenMinutes() {
        XCTAssertEqual(C.maxFutureSkewMs, 600_000, "MAX_FUTURE_SKEW_MS, the same on the web and Android")
    }

    func testAFarFutureFixIsDroppedAndNeverPinsTheGuard() {
        let skew = C.maxFutureSkewMs
        XCTAssertFalse(C.shouldAcceptLocation(incomingAuthTs: now + skew + 1, lastAcceptedTs: nil, now: now),
                       "beyond the bound: dropped")
        XCTAssertTrue(C.shouldAcceptLocation(incomingAuthTs: now + skew, lastAcceptedTs: nil, now: now),
                      "at the bound: a clock a little ahead is fine")
        XCTAssertTrue(C.shouldAcceptLocation(incomingAuthTs: now, lastAcceptedTs: now + skew + 1, now: now),
                      "a stored far-future time reads as absent")
        XCTAssertFalse(C.shouldAcceptLocation(incomingAuthTs: now, lastAcceptedTs: now + skew, now: now),
                       "a stored time within the bound still guards")
        XCTAssertTrue(C.shouldAcceptLocation(incomingAuthTs: nil, lastAcceptedTs: now + skew + 1, now: now))

        // An injected far-future fix, then genuine ones.
        var last: Int64? = nil
        func step(_ ts: Int64) -> Bool {
            let accept = C.shouldAcceptLocation(incomingAuthTs: ts, lastAcceptedTs: last, now: now)
            if accept { last = ts }
            return accept
        }
        XCTAssertTrue(step(now - 60_000))
        XCTAssertFalse(step(now + 365 * 86_400_000), "planted a year ahead")
        XCTAssertTrue(step(now - 30_000), "the genuine next fix still lands")
        XCTAssertFalse(step(now - 45_000), "a replay behind it is still dropped")
    }

    func testTheGuardKeyIsTheOneForm() {
        let circle = "c2000000-0000-4000-8000-0000000000c1", member = "c2000000-0000-4000-8000-000000000001"
        let key = C.guardKey(circle, member)
        XCTAssertEqual(C.guardKey(circle.uppercased(), member.uppercased()), key)
        XCTAssertEqual(C.guardKey(circle, member.replacingOccurrences(of: "-", with: "")), key)
        XCTAssertEqual(C.guardKey(circle, "{\(member)}"), key)
        XCTAssertNotEqual(C.guardKey(circle, "c2000000-0000-4000-8000-000000000002"), key)
    }

    // MARK: - The alert watermark, bounded at read

    private let home = PlaceAlertRules.PlaceGeofence(placeId: "home", latitude: 52.5, longitude: 13.4, radiusMeters: 100)

    func testAFarFutureWatermarkReadsAsAbsentAndKeepsTheStanding() {
        typealias S = PlaceAlertRules.MemberPlaceState
        let planted = S(isInside: true, lastLocationAt: now + C.maxFutureSkewMs + 1)
        let read = PlaceAlertMemberStateStore.boundedAtRead(planted, now: now)
        XCTAssertTrue(read.isInside, "the standing is kept")
        XCTAssertEqual(read.lastLocationAt, Int64.min)
        let fine = S(isInside: false, lastLocationAt: now + C.maxFutureSkewMs)
        XCTAssertEqual(PlaceAlertMemberStateStore.boundedAtRead(fine, now: now), fine)
    }

    /// A member inside Home with a far-future watermark. A genuine fix
    /// inside re-fires nothing; one outside is one departure.
    func testNothingReFiresAndTheNextGenuineCrossingCounts() throws {
        let prior = PlaceAlertMemberStateStore.boundedAtRead(
            PlaceAlertRules.MemberPlaceState(isInside: true, lastLocationAt: now + 86_400_000), now: now)
        let inside = PlaceAlertRules.Point(latitude: 52.5, longitude: 13.4, timestamp: now - 1_000, accuracyMeters: 5)
        let stillThere = try XCTUnwrap(PlaceAlertRules.reconcile(geofence: home, userId: "m", prior: prior, points: [inside]))
        XCTAssertEqual(stillThere.crossings, [], "no arrival re-fired")
        XCTAssertTrue(stillThere.state.isInside)
        XCTAssertEqual(stillThere.state.lastLocationAt, now - 1_000, "the watermark is genuine again")

        let outside = PlaceAlertRules.Point(latitude: 52.6, longitude: 13.4, timestamp: now - 1_000, accuracyMeters: 5)
        let left = try XCTUnwrap(PlaceAlertRules.reconcile(geofence: home, userId: "m", prior: prior, points: [outside]))
        XCTAssertEqual(left.crossings.map(\.transition), [.exit], "one departure")
    }

    func testTheWatermarkIsKeyedByTheMembersOneForm() {
        let member = "c2000000-0000-4000-8000-000000000001"
        XCTAssertEqual(PlaceAlertMemberStateRecord.key(placeId: "home", userId: member.uppercased()),
                       PlaceAlertMemberStateRecord.key(placeId: "home", userId: member))
        // Two spellings an older build kept fold into the later watermark's.
        let older = PlaceAlertMemberStateRecord(placeId: "home", userId: member.uppercased(), isInside: false,
                                                lastLocationAt: now - 60_000)
        let newer = PlaceAlertMemberStateRecord(placeId: "home", userId: member, isInside: true, lastLocationAt: now)
        XCTAssertEqual(PlaceAlertMemberStateStore.later(older, newer, now: now), newer)
        XCTAssertEqual(PlaceAlertMemberStateStore.later(newer, older, now: now), newer)
        // A far-future record ranks lowest, whichever order.
        let planted = PlaceAlertMemberStateRecord(placeId: "home", userId: member, isInside: true,
                                                  lastLocationAt: now + C.maxFutureSkewMs + 1)
        XCTAssertEqual(PlaceAlertMemberStateStore.later(older, planted, now: now), older)
        XCTAssertEqual(PlaceAlertMemberStateStore.later(planted, older, now: now), older)
        // At the bound it is genuine, as it reads (boundedAtRead).
        let edge = PlaceAlertMemberStateRecord(placeId: "home", userId: member, isInside: true,
                                               lastLocationAt: now + C.maxFutureSkewMs)
        XCTAssertEqual(PlaceAlertMemberStateStore.later(older, edge, now: now), edge)
        XCTAssertEqual(PlaceAlertMemberStateStore.later(edge, older, now: now), edge)
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheBoundsAreWiredIn() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("            let guardKey = Self.guardKey(circleId, userId)\n"))
        XCTAssertTrue(circles.contains("                lastAcceptedTs: lastAcceptedLocationTs[guardKey],\n"
                                       + "                now: Int64(Date().timeIntervalSince1970 * 1000)\n"))
        XCTAssertTrue(circles.contains("!key.hasPrefix(\"\\(CanonicalId.key(circleId)):\")"))
        let ledger = try source("App/Domain/PlaceAlerts/PlaceAlertLedger.swift")
        XCTAssertTrue(ledger.contains("        return Self.boundedAtRead(\n"))
        XCTAssertTrue(ledger.contains("records[PlaceAlertMemberStateRecord.key(placeId: placeId, userId: userId)]"))
        XCTAssertTrue(ledger.contains("            let now = Int64(Date().timeIntervalSince1970 * 1000)\n"
                                      + "            records = Dictionary(cached.map { ($0.key, $0) }, "
                                      + "uniquingKeysWith: { Self.later($0, $1, now: now) })\n"))
    }
}
