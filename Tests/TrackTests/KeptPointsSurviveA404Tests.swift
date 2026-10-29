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

/// A circle, and the late points this iPhone keeps for it, are never lost to a
/// single roster 404.
///
/// WHY THIS IS WORTH TESTING
///   The members route can answer 404 "not a member" when the server's read
///   fails or lags. Pruning the circle on that alone would drop its row, its
///   keychain mirror, the active circle (the map would jump circles), and the
///   points kept for it while this phone was behind or waiting for a privacy
///   read — up to 48 hours of history lost for good, while the next list
///   brings the circle straight back. So a WHOLE circle list decides first, as
///   the Android app's `isStillAMember` does; the kept points go on a leave, a
///   delete, a refusal a whole list confirms, or a WHOLE list that no longer
///   has the circle, as waiting changes decide ("a 404 is not gone").
@MainActor
final class KeptPointsSurviveA404Tests: XCTestCase {

    private let a = "a1000000-0000-4000-8000-00000000000a"
    private let b = "b1000000-0000-4000-8000-00000000000b"
    private let me = "0f0f0f0f-1111-4222-8333-444455556666"

    private func manager() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("App/Managers/CircleManager.swift"), encoding: .utf8)
    }

    private func body(_ start: String, _ end: String, in text: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// Against a whole list: the circles it no longer has, by their one form;
    /// never the personal history's points, which no list has.
    func testAWholeListDecidesWhichKeptPointsGo() {
        XCTAssertEqual(CircleManager.keptPointsToDiscard(kept: [a, b], listed: [a]), [b])
        XCTAssertEqual(CircleManager.keptPointsToDiscard(kept: [a.uppercased()], listed: [a]), [],
                       "listed in another spelling: kept")
        XCTAssertEqual(CircleManager.keptPointsToDiscard(kept: [SelfKeyManager.selfCircleUuid, b], listed: []), [b],
                       "the personal history's points are no circle's")
    }

    /// The rule and the store together: what a whole list no longer has goes,
    /// and the rest is still there to be sent.
    func testTheStoreKeepsWhatTheListStillHas() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PendingCircleLocations(directory: directory)
        let now = Date()
        let fix = PingolinTrackSDK.Location(latitude: 37.3349, longitude: -122.009, altitude: nil, speed: nil,
                                            heading: nil, accuracy: 5, timestamp: Int64(now.timeIntervalSince1970 * 1000),
                                            batteryLevel: nil, isCharging: nil)
        store.keep(fix, circleId: a, owner: me, now: now)
        store.keep(fix, circleId: b, owner: me, now: now)
        for circleId in CircleManager.keptPointsToDiscard(kept: store.circlesWithPoints(owner: me, now: now), listed: [a]) {
            store.discard(circleId: circleId)
        }
        XCTAssertEqual(store.circlesWithPoints(owner: me, now: now), [a])
        XCTAssertEqual(store.points(circleId: a, owner: me, now: now).count, 1)
    }

    /// A roster's refusal prunes only what a whole list confirms gone; still
    /// listed, or no whole list to ask, decides nothing.
    func testARosterRefusalPrunesOnlyWhatAWholeListConfirmsGone() throws {
        XCTAssertTrue(CircleManager.rosterRefusalPrunes(listed: false))
        XCTAssertFalse(CircleManager.rosterRefusalPrunes(listed: true), "still listed: the read failed, nothing more")
        XCTAssertFalse(CircleManager.rosterRefusalPrunes(listed: nil), "no whole list: absence of knowledge is not knowledge of absence")
        let text = try manager()
        XCTAssertTrue(text.contains("""
                    if isGone, Self.rosterRefusalPrunes(listed: await wholeListHas(circleId)) {
                        pruneGoneCircle(circleId)
                    }
                    throw error
        """), "confirmed first; then the circle and what was kept for it go together (`pruneGoneCircle`)")
        XCTAssertTrue(text.contains("""
                guard let list = try? await api.getCircleList(), list.whole else { return nil }
                return list.circles.contains { CanonicalId.sameKey($0.id, circleId) }
        """), "a list on one page, by the ids' one form")
        XCTAssertEqual(text.components(separatedBy: "pruneLocalCircle(circleId: circleId)").count - 1, 2,
                       "a circle gone by the server's word (a confirmed refusal, a whole list) and a leave")
    }

    /// A roster refusal alone keeps the circle and its points; a leave, a
    /// delete, a refusal a whole list confirms and a whole list without the
    /// circle discard them.
    func testOnlyALeaveADeleteOrAWholeListDiscards() throws {
        let text = try manager()
        let prune = try body("    private func pruneLocalCircle(circleId: String) {", "    /// Pure: a roster's refusal", in: text)
        XCTAssertFalse(prune.contains("PendingCircleLocations.shared.discard"), "its callers decide, never a roster's 404 alone")
        let leave = try body("    func leaveCircle(_ circleId: String) async throws {", "\n    }\n", in: text)
        XCTAssertTrue(leave.contains("        PendingCircleLocations.shared.discard(circleId: circleId)"))
        let delete = try body("    func deleteCircle(_ circle: Circle) async throws {", "\n    }\n", in: text)
        XCTAssertTrue(delete.contains("        PendingCircleLocations.shared.discard(circleId: circle.id)\n"))
        XCTAssertTrue(text.contains("""
                if listedNow, listedWhole, let me = AuthManager.shared.userId {
                    let listed = Set(responses.map { CanonicalId.key($0.id) })
                    for circleId in Self.keptPointsToDiscard(kept: PendingCircleLocations.shared.circlesWithPoints(owner: me),
                                                             listed: listed) {
                        PendingCircleLocations.shared.discard(circleId: circleId)
                    }
                    // And what this phone last sent each of them, kept for a
                    // re-seal: it holds a point.
                    for circleId in Self.keptPointsToDiscard(kept: OwnLastSentStore.shared.circles(owner: me), listed: listed) {
                        OwnLastSentStore.shared.forget(circleId: circleId)
                    }
                }
        """), "only a list the server just gave, on one page")
        XCTAssertEqual(text.components(separatedBy: "PendingCircleLocations.shared.discard(").count - 1, 4,
                       "a circle gone by the server's word, the whole list's kept points, the delete and the leave")
    }
}
