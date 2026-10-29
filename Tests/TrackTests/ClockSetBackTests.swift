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

/// The held position is compared with each new fix by their wall-clock capture
/// times (the Android app uses the monotonic clock). Set the clock back an hour
/// and the held fix is stamped an hour ahead: every new fix would read as
/// older, so handleFix would skip them all, and the check-in would keep
/// re-sending the held one as current, since `livenessCacheTooOld` never trips
/// on a negative age — the person frozen on the map until the clock caught up.
/// So a held fix stamped in the future past a small tolerance wins nothing,
/// and the check-in never re-sends it.
final class ClockSetBackTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // Apple Park: a fixture point nowhere near anyone's home.
    private func fix(secondsFromNow: TimeInterval) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                   altitude: 0, horizontalAccuracy: 12, verticalAccuracy: -1,
                   timestamp: now.addingTimeInterval(secondsFromNow))
    }

    /// The held fix was taken before the clock went back an hour.
    func testAfterTheClockIsSetBackTheNextFixReplacesTheHeldOne() {
        let held = fix(secondsFromNow: 3_600)
        let next = fix(secondsFromNow: -2)
        XCTAssertTrue(LocationService.isFromTheFuture(held, now: now))
        XCTAssertFalse(LocationService.isOlder(next, than: held, now: now), "the poll's fix is taken")
        XCTAssertTrue(LocationService.isNewer(next, than: held, now: now))
        XCTAssertTrue(LocationService.adopts(next, held: held, tracking: true, now: now), "and a send-now's")
    }

    func testTheCheckInNeverReSendsAFixStampedInTheFuture() {
        XCTAssertTrue(LocationService.livenessCacheTooOld(cacheAge: -3_600, pollInterval: 300))
        XCTAssertTrue(LocationService.livenessCacheTooOld(
            cacheAge: -(LocationService.futureFixToleranceSeconds + 1), pollInterval: 300))
        XCTAssertFalse(LocationService.livenessCacheTooOld(cacheAge: -1, pollInterval: 300),
                       "a second of skew is no clock change")
        XCTAssertFalse(LocationService.livenessCacheTooOld(cacheAge: 60, pollInterval: 300))
    }

    func testTheNormalOrderIsUnchanged() {
        let held = fix(secondsFromNow: -10)
        XCTAssertFalse(LocationService.isFromTheFuture(held, now: now))
        XCTAssertTrue(LocationService.isOlder(fix(secondsFromNow: -20), than: held, now: now))
        XCTAssertFalse(LocationService.isNewer(fix(secondsFromNow: -20), than: held, now: now))
        XCTAssertTrue(LocationService.isNewer(fix(secondsFromNow: -5), than: held, now: now))
        // Within the tolerance a held fix still counts as it is.
        let skewed = fix(secondsFromNow: LocationService.futureFixToleranceSeconds)
        XCTAssertFalse(LocationService.isFromTheFuture(skewed, now: now))
        XCTAssertTrue(LocationService.isOlder(fix(secondsFromNow: -1), than: skewed, now: now))
    }

    /// Each place that compares against the held fix asks with the time now.
    func testEveryComparisonIsMadeAgainstNow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("App/Services/LocationService.swift"), encoding: .utf8)
        XCTAssertEqual(src.components(separatedBy: "!Self.isOlder(location, than: currentLocation, now: Date())").count - 1, 2,
                       "handleFix and the visit path")
        XCTAssertTrue(src.contains("guard Self.adopts(fix, held: currentLocation, tracking: wantsTracking, now: Date()) else { return }"))
        XCTAssertTrue(src.contains("guard let held, !isFromTheFuture(held, now: now) else { return true }"), "isNewer")
        XCTAssertTrue(src.contains("guard let held, !isFromTheFuture(held, now: now) else { return false }"), "isOlder")
        // And the check-in's own age reads the same clock, takes the newer of
        // the precise fix and a coarse presence confirmation, then asks the limit.
        XCTAssertTrue(src.contains(
            "let newestPresence = max(location.timestamp, lastPresenceConfirmedAt ?? .distantPast)\n"
            + "        let cacheAge = Date().timeIntervalSince(newestPresence)\n"
            + "        if Self.livenessCacheTooOld(cacheAge: cacheAge, pollInterval: currentPollInterval()) {"))
    }
}
