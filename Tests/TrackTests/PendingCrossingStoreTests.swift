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

/// The durable outbox for own-crossing reports, and the durable buffer for region
/// events that arrived before the place cache resolved.
///
/// WHY THIS IS WORTH TESTING
///   - Both stores exist so that a crossing cannot vanish silently. A defect in
///     the store brings that failure back, and the symptom is identical: an alert
///     that never fires, indistinguishable from one nobody subscribed to. Nothing
///     else can catch that.
///   - The age bound is the one piece of judgement in here. Too generous and a
///     user is told at breakfast that somebody arrived somewhere last night; too
///     tight and a commute through poor coverage loses its alerts. It is bounded
///     on the CROSSING time, not on when the record was queued — the two differ
///     by the length of the network outage, and getting that backwards makes the
///     bound meaningless exactly when it matters.
///   - `take()` clears before the caller's awaits, so a second drain cannot claim
///     the same crossing. If it returned without clearing, two wake paths firing
///     together would each replay the queue.
final class PendingCrossingStoreTests: XCTestCase {

    /// Just inside and just outside the 2h staleness window, expressed against the
    /// constant rather than a literal so a change to the window moves both.
    private var window: TimeInterval { TimeInterval(PlaceAlertRules.stalenessWindowMs) / 1000 }

    @MainActor
    override func setUp() async throws {
        // Singletons persisting to one cache key: without this a previous test's
        // rows are this test's rows.
        await PendingCrossingStore.shared.clear()
        await PendingRegionEventStore.shared.clear()
    }

    @MainActor
    private func enqueueCrossing(placeId: String = "place-1", eventType: String = "enter", ago: TimeInterval) {
        PendingCrossingStore.shared.enqueue(
            placeId: placeId,
            userId: "user-me",
            deviceId: "device-1",
            eventType: eventType,
            occurredAt: Date().addingTimeInterval(-ago),
            reason: "test"
        )
    }

    // MARK: - The age bound

    /// Past the window a crossing is discarded; inside it, it survives. The second
    /// half is the control: without it this passes against a `take()` that returns
    /// nothing at all, which is the failure mode being guarded against.
    @MainActor
    func testTakeDiscardsOnlyCrossingsPastTheStalenessWindow() {
        enqueueCrossing(placeId: "stale", ago: window + 600)
        enqueueCrossing(placeId: "fresh", ago: 60)

        let due = PendingCrossingStore.shared.take()

        XCTAssertEqual(due.count, 1, "expected exactly one crossing to survive the bound")
        XCTAssertEqual(due.first?.placeId, "fresh", "the wrong crossing survived")
    }

    /// The bound reads the CROSSING time. A crossing that happened two minutes ago
    /// is deliverable however long its record has sat in the store — which is the
    /// case a bound on `queuedAt` would get wrong, and it is the normal case after
    /// an outage.
    @MainActor
    func testTheBoundReadsTheCrossingTimeNotTheQueueTime() {
        enqueueCrossing(placeId: "recent-crossing", ago: 120)

        let due = PendingCrossingStore.shared.take()

        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.placeId, "recent-crossing")
    }

    // MARK: - Ordering and identity

    /// Oldest first. Order is meaning here: an enter replayed after its own exit
    /// tells a subscriber somebody is still somewhere they have left.
    @MainActor
    func testTakeReturnsOldestCrossingFirst() {
        enqueueCrossing(placeId: "second", eventType: "exit", ago: 300)
        enqueueCrossing(placeId: "first", eventType: "enter", ago: 900)

        let due = PendingCrossingStore.shared.take()

        XCTAssertEqual(due.map(\.placeId), ["first", "second"])
    }

    /// One crossing, two feeders (a failed POST for a circle whose posture was also
    /// unknown), one record. Without the identity key the user gets the crossing
    /// twice on replay.
    @MainActor
    func testTheSameCrossingQueuedTwiceIsOneRecord() {
        let at = Date().addingTimeInterval(-60)
        for _ in 0..<2 {
            PendingCrossingStore.shared.enqueue(
                placeId: "place-1", userId: "user-me", deviceId: "device-1",
                eventType: "enter", occurredAt: at, reason: "test"
            )
        }

        XCTAssertEqual(PendingCrossingStore.shared.count, 1)
    }

    /// Two genuinely different crossings of the same place are NOT collapsed — the
    /// control for the test above, which would otherwise pass against a key that
    /// ignores time entirely.
    @MainActor
    func testTwoDifferentCrossingsOfOnePlaceAreBothKept() {
        enqueueCrossing(placeId: "place-1", eventType: "enter", ago: 600)
        enqueueCrossing(placeId: "place-1", eventType: "exit", ago: 300)

        XCTAssertEqual(PendingCrossingStore.shared.count, 2)
    }

    // MARK: - take() clears

    /// A second drain must find nothing. If `take()` left the rows behind, two wake
    /// paths firing together would both replay them and the crossing would be
    /// reported twice.
    @MainActor
    func testTakeClearsSoASecondDrainFindsNothing() {
        enqueueCrossing(ago: 60)

        XCTAssertEqual(PendingCrossingStore.shared.take().count, 1)
        XCTAssertTrue(PendingCrossingStore.shared.take().isEmpty)
    }

    // MARK: - Retry accounting

    /// A failed replay is re-queued with its attempt count raised, so a wedged
    /// crossing is visible as a rising number rather than a permanently fresh one.
    /// Eviction is by age, never by this count.
    @MainActor
    func testRequeueCountsTheAttemptAndKeepsTheRecord() {
        enqueueCrossing(ago: 60)
        let record = PendingCrossingStore.shared.take().first!
        XCTAssertEqual(record.attempts, 0)

        PendingCrossingStore.shared.requeue(record)

        let again = PendingCrossingStore.shared.take()
        XCTAssertEqual(again.count, 1, "a re-queued crossing must still be there")
        XCTAssertEqual(again.first?.attempts, 1)
    }

    // MARK: - Logout

    /// Clearing on logout is a disclosure guard, not tidiness: a crossing left by
    /// account A would be replayed under B's session, reporting A's movement to B's
    /// circles under B's keys.
    @MainActor
    func testClearEmptiesTheQueue() async {
        enqueueCrossing(ago: 60)
        XCTAssertEqual(PendingCrossingStore.shared.count, 1)

        await PendingCrossingStore.shared.clear()

        XCTAssertEqual(PendingCrossingStore.shared.count, 0)
    }

    // MARK: - Region events

    /// The region buffer keeps the identifier, which IS the place id — the only
    /// field the handler reads from a CLRegion, and the reason a crossing can be
    /// buffered before any place has decrypted.
    @MainActor
    func testRegionEventsSurviveAsPlaceIdsOldestFirst() {
        PendingRegionEventStore.shared.enqueue(
            placeId: "later", isEnter: false, detectedAt: Date().addingTimeInterval(-100)
        )
        PendingRegionEventStore.shared.enqueue(
            placeId: "earlier", isEnter: true, detectedAt: Date().addingTimeInterval(-500)
        )

        let due = PendingRegionEventStore.shared.take()

        XCTAssertEqual(due.map(\.placeId), ["earlier", "later"])
        XCTAssertEqual(due.first?.isEnter, true)
    }

    /// Same bound, same control shape as the crossing store.
    @MainActor
    func testRegionEventsPastTheWindowAreDiscarded() {
        PendingRegionEventStore.shared.enqueue(
            placeId: "stale", isEnter: true, detectedAt: Date().addingTimeInterval(-(window + 600))
        )
        PendingRegionEventStore.shared.enqueue(
            placeId: "fresh", isEnter: true, detectedAt: Date().addingTimeInterval(-60)
        )

        let due = PendingRegionEventStore.shared.take()

        XCTAssertEqual(due.map(\.placeId), ["fresh"])
    }
}
