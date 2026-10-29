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

/// An owner's own place must not disappear from their Places tab because of who
/// it was shared to — least of all because the circle it was shared to no
/// longer exists.
///
/// THE RULE
///   Sharing ADDS to the owner's own visibility; it never transfers it. A filter
///   like
///
///       static func isVisible(sharedCircles: [String]?, in circleId: String) -> Bool {
///           guard let shared = sharedCircles, !shared.isEmpty else { return true }
///           return shared.contains(circleId)
///       }
///
///   applied to every decoded place would flip an owner's place, on its FIRST
///   share, from "visible everywhere" to "visible only inside a circle it was
///   shared to". Delete that circle and the active context
///   (`circleManager.activeCircle?.id ?? SelfKeyManager.selfCircleUuid`) falls
///   back to the self circle, `shared.contains` is false, and no context the
///   owner can switch to brings the place back. That is permanent: deleting a
///   circle does not remove the place's shares, so the place keeps naming the
///   deleted circle.
///
///   The server never hides an owner's own place: it always returns it to its
///   owner. Throwing it away on the device would also stop the owner from
///   un-sharing it, since `sharePlaceWithCircle` looks its target up in
///   `places`.
///
/// WHY THESE ASSERT ON THE LIST AND NOT ON `isVisible`
///   A boolean from a predicate is not the claim worth pinning; the claim is
///   what the Places tab ends up rendering. So these call
///   `PlaceManager.visibleInUI` — the exact expression `loadPlaces` assigns
///   into `places` — and assert over the places that come back.
///
///   `testAReceivedShareStillAppearsOnlyInTheCircleItArrivedThrough` is the
///   other half of the pairing: the owner's place stays visible without
///   turning every share anyone sent them into a place that follows them into
///   every circle.
///
/// WHERE THE EXPECTED BEHAVIOUR COMES FROM
///   Not from taste: the web app and the Android app implement this rule and
///   agree with each other, which is what makes it the specification.
///   `PlaceManager.visibleInUI`'s doc comment quotes the Android app's KDoc
///   stating it outright — read that before changing what any of these tests
///   expect.
final class OwnPlaceSurvivesDeletedShareCircleTests: XCTestCase {

    /// The self-tracking pseudo-circle. `SelfKeyManager.selfCircleUuid`, which
    /// is both what `decodePlaces` files an owned personal place under and what
    /// the active context falls back to when no circle is selected.
    private let selfCircle = SelfKeyManager.selfCircleUuid

    /// A circle that was created, shared to, then deleted.
    private let deletedCircle = "7edc19af-4ba0-4a5f-9f3c-2d1e8a6b0c47"

    /// A circle that still exists — the owner switching contexts, and the
    /// circle a received share arrives through.
    private let liveCircle = "8f14e45f-ceea-467a-9f8e-4b1c2d3e4f50"

    /// A decoded place as `decodePlaces` would have produced it.
    /// `circleId` is its `targetCircle`: the self circle for a personal place
    /// the requester OWNS (NULL `circle_id` + the owner-side wrap), and the
    /// sharing circle for one they RECEIVED (`wrap_via_circle`).
    private func place(
        id: String,
        named name: String,
        filedUnder circleId: String,
        sharedTo sharedCircles: [String]?
    ) -> Place {
        Place(
            id: id,
            circleId: circleId,
            name: name,
            latitude: 51.5074,
            longitude: -0.1278,
            radius: 150,
            placeType: "place",
            boundaryRadius: nil,
            alertsEnabled: false,
            icon: .gym,
            color: "#3B82F6",
            createdAt: Date(timeIntervalSince1970: 1_755_000_000),
            address: nil,
            notes: nil,
            wrappedKey: "aa",
            wrappedKeyNonce: "bb",
            wrapTargetId: circleId,
            sharedCircles: sharedCircles
        )
    }

    /// The case at hand: the owner's own place, shared once to a circle that
    /// has since been deleted.
    private var orphanShared: Place {
        place(id: "place-gym", named: "Gym", filedUnder: selfCircle, sharedTo: [deletedCircle])
    }

    // MARK: - A share to a deleted circle

    /// Circle deleted, so the active context has fallen back to the self
    /// circle, and the owner is looking at their own Places tab.
    func testOwnersPlaceSurvivesTheDeletionOfTheCircleItWasSharedTo() {
        let rendered = PlaceManager.visibleInUI(
            [orphanShared],
            activeCircleId: selfCircle,
            selfCircleUuid: selfCircle
        )

        XCTAssertEqual(rendered.map(\.name), ["Gym"],
                       "the owner's own place must still be on their Places tab after the "
                       + "circle it was shared to is deleted — the row is still on the "
                       + "server, and nothing removes the place_shares row with the circle, "
                       + "so a filter keyed on the share list hides it forever")
    }

    /// The same place must stay reachable by id, not merely be countable —
    /// `sharePlaceWithCircle` resolves its target out of this list, so a place
    /// missing from it cannot even be un-shared back into view.
    func testTheSurvivingPlaceIsTheOneTheOwnerCanStillActOn() {
        let rendered = PlaceManager.visibleInUI(
            [orphanShared],
            activeCircleId: selfCircle,
            selfCircleUuid: selfCircle
        )

        XCTAssertNotNil(rendered.first(where: { $0.id == "place-gym" }),
                        "the owner has to be able to find their place in the rendered list "
                        + "to un-share or delete it; dropping it strands the row")
    }

    /// The deletion is not what makes it wrong — it is what makes it permanent.
    /// A LIVE circle the place was not shared to hid it just the same, and the
    /// owner could at least switch back. Both must show it.
    func testOwnersPlaceIsVisibleFromACircleItWasNotSharedTo() {
        let rendered = PlaceManager.visibleInUI(
            [orphanShared],
            activeCircleId: liveCircle,
            selfCircleUuid: selfCircle
        )

        XCTAssertEqual(rendered.map(\.name), ["Gym"],
                       "sharing grants a circle ADDITIONAL visibility; it does not move the "
                       + "owner's own place out of every other context")
    }

    /// An unshared personal place, kept here so a rewrite of the rule cannot
    /// quietly break it while handling the shared one.
    func testAnUnsharedPersonalPlaceIsStillVisible() {
        let solo = place(id: "place-home", named: "Home", filedUnder: selfCircle, sharedTo: nil)

        XCTAssertEqual(
            PlaceManager.visibleInUI([solo], activeCircleId: selfCircle, selfCircleUuid: selfCircle)
                .map(\.name),
            ["Home"]
        )
    }

    // MARK: - The other half: the rule must not over-reach

    /// A place someone else shared TO the user arrives filed under the circle it
    /// came through, not the self circle, so it still appears only there. This
    /// is the assertion that stops the rule from being "show everything".
    func testAReceivedShareStillAppearsOnlyInTheCircleItArrivedThrough() {
        let received = place(
            id: "place-theirs",
            named: "Their Cabin",
            filedUnder: liveCircle,
            sharedTo: [liveCircle]
        )

        XCTAssertEqual(
            PlaceManager.visibleInUI([received], activeCircleId: liveCircle, selfCircleUuid: selfCircle)
                .map(\.name),
            ["Their Cabin"],
            "a received share belongs in the circle it arrived through"
        )
        XCTAssertTrue(
            PlaceManager.visibleInUI([received], activeCircleId: selfCircle, selfCircleUuid: selfCircle)
                .isEmpty,
            "a place the user does not own must NOT follow them into their personal view"
        )
    }

    /// The whole mixed list at once, in the self view: the owner's own places
    /// both present, someone else's share absent.
    func testTheOwnersSelfViewShowsTheirOwnPlacesAndOnlyThose() {
        let mixed = [
            orphanShared,
            place(id: "place-home", named: "Home", filedUnder: selfCircle, sharedTo: nil),
            place(id: "place-theirs", named: "Their Cabin", filedUnder: liveCircle, sharedTo: [liveCircle]),
        ]

        XCTAssertEqual(
            PlaceManager.visibleInUI(mixed, activeCircleId: selfCircle, selfCircleUuid: selfCircle)
                .map(\.name),
            ["Gym", "Home"]
        )
    }
}
