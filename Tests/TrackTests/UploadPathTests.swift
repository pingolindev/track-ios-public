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

/// The upload path from a gated fix to the wire: which targets get it, how
/// requests are coalesced, and how often the self position is written to disk.
///
/// WHY THIS IS WORTH TESTING
///   - The sink THROTTLES, never debounces: a 10 s debounce only fires after
///     10 s of silence, so any steady stream of requests closer than that — a
///     10 s user interval while moving — would starve uploads entirely while
///     the gate believed it had sent. And a trail point must never be
///     displaced by a check-in queued behind it.
///   - One target's failure must never cost the user their own copy. The loop
///     is per-target `try?` with self first, and this pins it.
///   - `SelfLocationStore.save` runs once per fix, not once per TARGET (N+1
///     identical atomic writes).
final class UploadPathTests: XCTestCase {

    private func request(_ mode: LocationService.SendMode, lat: Double = 37) -> LocationService.SendRequest {
        LocationService.SendRequest(location: CLLocation(latitude: lat, longitude: -122), mode: mode)
    }

    // MARK: - Coalescing

    func testFirstRequestIsTakenAsIs() {
        let r = CircleManager.coalesceSendRequests(nil, request(.liveness))
        XCTAssertEqual(r.mode, .liveness)
    }

    func testATrailPointIsNeverDisplacedByACheckIn() {
        let history = request(.history, lat: 1)
        let merged = CircleManager.coalesceSendRequests(history, request(.liveness, lat: 2))
        XCTAssertEqual(merged.mode, .history)
        XCTAssertEqual(merged.location.coordinate.latitude, 1)
    }

    func testAHistoryRequestReplacesAWaitingCheckIn() {
        let merged = CircleManager.coalesceSendRequests(request(.liveness, lat: 1), request(.history, lat: 2))
        XCTAssertEqual(merged.mode, .history)
        XCTAssertEqual(merged.location.coordinate.latitude, 2)
    }

    func testTheNewerOfTwoOfAKindWins() {
        let merged = CircleManager.coalesceSendRequests(request(.history, lat: 1), request(.history, lat: 2))
        XCTAssertEqual(merged.location.coordinate.latitude, 2, "the newer position is where the device is")
    }

    // MARK: - Throttle timing

    func testTheFirstUploadGoesAtOnceThenAtMostOnePerInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CircleManager.uploadThrottleDelay(lastFlushAt: nil, now: t0, interval: 10), 0)
        XCTAssertEqual(CircleManager.uploadThrottleDelay(lastFlushAt: t0, now: t0.addingTimeInterval(3), interval: 10), 7)
        XCTAssertEqual(CircleManager.uploadThrottleDelay(lastFlushAt: t0, now: t0.addingTimeInterval(10), interval: 10), 0)
        XCTAssertEqual(CircleManager.uploadThrottleDelay(lastFlushAt: t0, now: t0.addingTimeInterval(60), interval: 10), 0)
    }

    // MARK: - Targets

    private func privacy(_ id: String, mode: String = "exact", realtime: Bool = true) -> PrivacySettings {
        PrivacySettings(
            circleId: id,
            sharingMode: mode,
            shareRealtime: realtime,
            shareHistory: true,
            shareBattery: true,
            bubbleEnabled: false,
            bubbleRadius: 1,
            pausedUntil: nil,
            updatedAt: Date()
        )
    }

    func testSelfIsFirstAndUnconditional() {
        let targets = CircleManager.uploadTargets(
            selfId: "self", circleIds: ["a", "b"],
            privacy: ["a": privacy("a", mode: "paused"), "b": privacy("b", realtime: false)])
        XCTAssertEqual(targets, ["self"], "no circle state may cost the user their own copy")
    }

    func testEligibleCirclesFollowSelfInOrder() {
        let targets = CircleManager.uploadTargets(
            selfId: "self", circleIds: ["a", "b", "c"],
            privacy: ["a": privacy("a"), "c": privacy("c")])
        XCTAssertEqual(targets, ["self", "a", "c"], "an unloaded posture fails closed")
    }

    func testSelfIsNeverSentTwice() {
        let targets = CircleManager.uploadTargets(
            selfId: "self", circleIds: ["self", "a"], privacy: ["self": privacy("self"), "a": privacy("a")])
        XCTAssertEqual(targets, ["self", "a"])
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

    func testEachTargetIsSentOnItsOwn() throws {
        let src = source("App/Managers/CircleManager.swift")
        let loop = try XCTUnwrap(src.range(of: "for targetId in targetCircleIds {"),
                                 "the per-target send loop is gone — retire this test with it")
        let after = String(src[loop.upperBound...].prefix(600))
        XCTAssertTrue(after.contains("try? SDKLocationStreamer.shared.send(circleId: targetId"))
        XCTAssertTrue(after.contains("try? SDKLocationStreamer.shared.sendLiveness(circleId: targetId"))
        XCTAssertFalse(after.contains("return"), "one target must not end the loop for the rest")
    }

    func testUploadsAreThrottledNotDebounced() throws {
        let src = source("App/Managers/CircleManager.swift")
        let sink = try XCTUnwrap(src.range(of: "locationService.locationSendRequests"))
        let chain = String(src[sink.upperBound...].prefix(300))
        XCTAssertFalse(chain.contains(".debounce("), "a debounce starves uploads under a steady stream")
        XCTAssertTrue(chain.contains("enqueueUpload(request)"))
    }

    // MARK: - Self position writes

    func testASaveNearTheLastOneIsSkipped() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = PersistedSelfLocation(latitude: 37.0, longitude: -122.0)
        let near = PersistedSelfLocation(latitude: 37.00005, longitude: -122.0) // ~5.6 m
        let far = PersistedSelfLocation(latitude: 37.0002, longitude: -122.0)   // ~22 m

        XCTAssertTrue(SelfLocationStore.shouldWrite(a, lastSaved: nil, lastSavedAt: nil, now: t0))
        XCTAssertFalse(SelfLocationStore.shouldWrite(near, lastSaved: a, lastSavedAt: t0, now: t0.addingTimeInterval(30)))
        XCTAssertTrue(SelfLocationStore.shouldWrite(far, lastSaved: a, lastSavedAt: t0, now: t0.addingTimeInterval(30)))
        XCTAssertTrue(SelfLocationStore.shouldWrite(near, lastSaved: a, lastSavedAt: t0, now: t0.addingTimeInterval(60)),
                      "an unmoved position is still refreshed once a minute")
    }
}
