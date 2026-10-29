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

/// When a locally-hidden destination is allowed to be forgotten.
///
/// WHY THIS IS WORTH TESTING
///   `prune` is DESTRUCTIVE on an empty live list — that is its contract, and
///   it is correct given a complete list. So the caller must hold a complete
///   list: `DestinationsManager.destinations` is empty until its first
///   `refresh()`, and a prune run from a SwiftUI computed property (MapView's
///   `destinationMarkers`, say) would, on launch, prune the active circle's
///   hides against nothing and delete them all, and hidden destinations would
///   reappear on every launch. The tests below pin both halves: the store
///   still forgets what a complete list says is gone, and the manager never
///   hands it a list it does not actually have.
final class HiddenDestinationsPruneTests: XCTestCase {

    private static let circleA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private static let circleB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    @MainActor
    private func makeStore() -> HiddenDestinationsStore {
        // A scratch suite per test so nothing leaks between them or onto the
        // device's own defaults.
        let defaults = UserDefaults(suiteName: "HiddenDestinationsPruneTests.\(UUID().uuidString)")!
        return HiddenDestinationsStore(defaults: defaults)
    }

    private func row(id: String, circleId: String, status: String = "active") -> DestinationResponse {
        let blob = EncryptedBlobResponse(nonce: "00", ciphertext: "11")
        return DestinationResponse(
            id: id,
            userId: nil,
            encryptedUserId: blob,
            circleId: circleId,
            encryptedDestination: blob,
            encryptedDestName: nil,
            encryptedEta: nil,
            etaDayBucket: nil,
            notifyArrival: true,
            status: status,
            startedDayBucket: 20_000,
            arrivedDayBucket: nil,
            createdDayBucket: 20_000,
            updatedDayBucket: 20_000
        )
    }

    // MARK: - The store's own contract

    /// The documented behaviour, and the reason the CALLER has to hold a
    /// real list before invoking it. Pinned so the caller-side guarantees
    /// below cannot be quietly satisfied by weakening this.
    @MainActor
    func testPruneIsDestructiveOnAnEmptyLiveList() {
        let store = makeStore()
        store.hide("d1", circleId: Self.circleA)
        XCTAssertTrue(store.isHidden("d1"))

        store.prune(circleId: Self.circleA, liveIds: [])

        XCTAssertFalse(store.isHidden("d1"), "an empty live list means the circle has nothing left")
    }

    /// A hide made by an older build carries no circle, so no per-circle prune
    /// can judge it. It is kept rather than guessed at.
    @MainActor
    func testAHideWithNoKnownCircleIsNeverPruned() {
        let store = makeStore()
        store.hide("orphan", circleId: nil)

        store.prune(circleId: Self.circleA, liveIds: [])
        store.prune(circleId: Self.circleB, liveIds: [])

        XCTAssertTrue(store.isHidden("orphan"))
    }

    // MARK: - What the manager actually hands it

    /// Before the first refresh lands there is nothing to prune against: an
    /// empty list here is the absence of a response. Nothing may be forgotten
    /// on the strength of a list the app does not have.
    @MainActor
    func testAnEmptyResponseForgetsNothing() {
        let store = makeStore()
        store.hide("d1", circleId: Self.circleA)
        store.hide("d2", circleId: Self.circleB)

        DestinationsManager.pruneHides(against: [], store: store)

        XCTAssertTrue(store.isHidden("d1"))
        XCTAssertTrue(store.isHidden("d2"))
    }

    /// `/destinations` returns at most 100 rows, so a response is not proof
    /// of what a circle it never mentions contains. Only circles the server
    /// actually spoke about are judged.
    @MainActor
    func testACircleMissingFromTheResponseIsLeftAlone() {
        let store = makeStore()
        store.hide("a1", circleId: Self.circleA)
        store.hide("b1", circleId: Self.circleB)

        // The response mentions circle A only, and a1 is gone from it.
        DestinationsManager.pruneHides(against: [row(id: "a2", circleId: Self.circleA)], store: store)

        XCTAssertFalse(store.isHidden("a1"), "circle A was described in full, and a1 was not in it")
        XCTAssertTrue(store.isHidden("b1"), "circle B was never mentioned, so nothing is known about it")
    }

    /// The point of pruning at all: a destination that has left the server's
    /// list for good must not keep a hide alive in UserDefaults forever.
    /// The server leaves arrived rows out of the list, which is what makes
    /// absence meaningful.
    @MainActor
    func testAHideIsForgottenOnceItsRowLeavesTheResponse() {
        let store = makeStore()
        store.hide("stillThere", circleId: Self.circleA)
        store.hide("arrived", circleId: Self.circleA)

        DestinationsManager.pruneHides(
            against: [row(id: "stillThere", circleId: Self.circleA)], store: store)

        XCTAssertTrue(store.isHidden("stillThere"))
        XCTAssertFalse(store.isHidden("arrived"))
    }

    /// Every returned id counts as live, not just the active ones. The inbox
    /// shows a "Past" section and lets the user hide rows in it; pruning
    /// against ACTIVE ids alone would un-hide them while they are still on
    /// screen.
    @MainActor
    func testACancelledRowStillInTheResponseKeepsItsHide() {
        let store = makeStore()
        store.hide("cancelled", circleId: Self.circleA)

        DestinationsManager.pruneHides(
            against: [
                row(id: "active", circleId: Self.circleA),
                row(id: "cancelled", circleId: Self.circleA, status: "cancelled"),
            ],
            store: store)

        XCTAssertTrue(store.isHidden("cancelled"))
    }

    /// Two circles described in one response are judged independently — a
    /// circle that really is empty of hidden rows must not take the other's
    /// hides down with it.
    @MainActor
    func testCirclesInOneResponseAreJudgedSeparately() {
        let store = makeStore()
        store.hide("a1", circleId: Self.circleA)
        store.hide("b1", circleId: Self.circleB)

        DestinationsManager.pruneHides(
            against: [
                row(id: "a2", circleId: Self.circleA),
                row(id: "b1", circleId: Self.circleB),
            ],
            store: store)

        XCTAssertFalse(store.isHidden("a1"))
        XCTAssertTrue(store.isHidden("b1"))
    }

    /// Sign-out teardown: the next account must not inherit these.
    @MainActor
    func testClearDropsEverything() {
        let store = makeStore()
        store.hide("a1", circleId: Self.circleA)
        store.hide("orphan", circleId: nil)

        store.clear()

        XCTAssertFalse(store.isHidden("a1"))
        XCTAssertFalse(store.isHidden("orphan"))
    }
}
