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
import PingolinTrackSDK
@testable import Track

/// "Locations will be queued until synced", made true: what a device keeps
/// for a circle it is waiting to sync, and for how long.
@MainActor
final class PendingCircleLocationsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingCircleLocationsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fix(_ secondsAgo: TimeInterval, from now: Date, battery: UInt8? = 80) -> PingolinTrackSDK.Location {
        PingolinTrackSDK.Location(
            latitude: 51.5, longitude: -0.12, altitude: 10, speed: 1, heading: 90, accuracy: 5,
            timestamp: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000),
            batteryLevel: battery, isCharging: false)
    }

    func testKeptOldestFirstAndSentInOrder() {
        let store = PendingCircleLocations(directory: directory)
        let now = Date()
        store.keep(fix(60, from: now), circleId: "c1", owner: "me", now: now)
        store.keep(fix(120, from: now), circleId: "c1", owner: "me", now: now)
        store.keep(fix(30, from: now), circleId: "c2", owner: "me", now: now)
        let kept = store.points(circleId: "c1", owner: "me", now: now)
        XCTAssertEqual(kept.map(\.timestamp), [fix(120, from: now).timestamp, fix(60, from: now).timestamp],
                       "history goes out in the order it happened")
        XCTAssertEqual(kept.first?.location.batteryLevel, 80)

        store.sent(1, circleId: "c1", owner: "me", now: now)
        XCTAssertEqual(store.points(circleId: "c1", owner: "me", now: now).map(\.timestamp), [fix(60, from: now).timestamp],
                       "a send that stopped keeps the rest")
        XCTAssertEqual(store.points(circleId: "c2", owner: "me", now: now).count, 1, "per circle")
    }

    /// 48 hours at most (the same cap on all three clients), oldest dropped first.
    func testKeptForFortyEightHoursAtMost() {
        let store = PendingCircleLocations(directory: directory)
        let now = Date()
        store.keep(fix(49 * 3600, from: now), circleId: "c1", owner: "me", now: now)
        store.keep(fix(47 * 3600, from: now), circleId: "c1", owner: "me", now: now)
        XCTAssertEqual(store.points(circleId: "c1", owner: "me", now: now).count, 1)
        XCTAssertTrue(store.points(circleId: "c1", owner: "me", now: now.addingTimeInterval(2 * 3600)).isEmpty,
                      "and what ages out while waiting goes too")
    }

    /// Survives a relaunch; another account never reads it; sign-out and a
    /// circle leaving take it with them.
    func testPerAccountAndWiped() {
        let now = Date()
        let store = PendingCircleLocations(directory: directory)
        store.keep(fix(60, from: now), circleId: "c1", owner: "me", now: now)
        store.keep(fix(60, from: now), circleId: "c2", owner: "me", now: now)

        let relaunched = PendingCircleLocations(directory: directory)
        XCTAssertEqual(relaunched.points(circleId: "c1", owner: "me", now: now).count, 1)
        XCTAssertTrue(relaunched.points(circleId: "c1", owner: "someone-else", now: now).isEmpty)

        relaunched.discard(circleId: "c1")
        XCTAssertTrue(PendingCircleLocations(directory: directory).points(circleId: "c1", owner: "me", now: now).isEmpty)
        XCTAssertEqual(PendingCircleLocations(directory: directory).points(circleId: "c2", owner: "me", now: now).count, 1)

        relaunched.clearAll()
        XCTAssertTrue(PendingCircleLocations(directory: directory).points(circleId: "c2", owner: "me", now: now).isEmpty)
    }

    /// Where the app keeps and sends them (source): only a history fix refused
    /// for waiting to sync is kept, with the circle's privacy applied — a
    /// check-in never is; they drain as `history_only`, paced under the
    /// server's per-user limit (120 a minute, shared with live sends), kicked by every
    /// live send and every circle refresh.
    func testTheStreamerKeepsAndDrainsThem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let streamer = try String(contentsOf: root.appendingPathComponent("App/Services/SDKLocationStreamer.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(streamer.contains("if case SendError.keyNotCurrent = error, kind == .history,"))
        XCTAssertTrue(streamer.contains("privacyApplied(location, circleId: circleId), circleId: circleId, owner: owner)"))
        XCTAssertTrue(streamer.contains("try self.sendInner(circleId: next.circleId, location: next.point.location, kind: .keptHistory)"))
        XCTAssertTrue(streamer.contains("case .keptHistory:\n                try manager.sendEnvelopeHistoryLocation("),
                      "kept points go out history-only")
        XCTAssertGreaterThanOrEqual(SDKLocationStreamer.keptPointSpacing, 500_000_000, "at most 2 a second")
        let live = try XCTUnwrap(streamer.range(of: "func send(circleId: String, location: PingolinTrackSDK.Location, kind: SendKind, capturedAt: Date? = nil) throws {"))
        let kick = try XCTUnwrap(streamer.range(of: "drainKeptLocations()\n", range: live.upperBound..<streamer.endIndex))
        let inner = try XCTUnwrap(streamer.range(of: "try sendInner(circleId: circleId, location: location, kind: kind, capturedAt: capturedAt)",
                                                 range: live.upperBound..<streamer.endIndex))
        XCTAssertLessThan(kick.lowerBound, inner.lowerBound, "every live send kicks the drain")
        let auth = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        XCTAssertTrue(auth.contains("PendingCircleLocations.shared.clearAll()"), "sign-out keeps no location")
        let circles = try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
        XCTAssertEqual(circles.components(separatedBy: "PendingCircleLocations.shared.discard(circleId:").count - 1, 4,
                       "a deleted circle, a left one, one a whole list no longer has and a refusal one confirms drop what was kept for them (KeptPointsSurviveA404Tests)")
        XCTAssertTrue(circles.contains("SDKLocationStreamer.shared.drainKeptLocations()"), "a refresh kicks the drain too")
    }
}
