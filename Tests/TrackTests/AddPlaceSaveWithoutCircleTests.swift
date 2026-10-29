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

/// What tapping Save on the Places tab's Add Place form actually does when the
/// account has no circles.
///
/// A CIRCLE IS NEVER REQUIRED
///   `PlaceManager.createPlace` posts `CreatePlaceRequest(circleId: nil, ...)`
///   for every caller, and the server accepts a place with no `circle_id`: it
///   checks membership only when one is given. A personal place is a
///   first-class row. The Map twin follows the same rule:
///   `CreatePlaceFromMapSheet` has no `activeCircle` guard, defaults its
///   visibility picker to "Just me", and shares only when a real circle was
///   picked.
///
///   So Save must never be enabled and then do nothing. A save path that
///   guards on something the button's `.disabled` predicate does not mention
///   (`activeCircle`, say) leaves a hittable button that silently throws the
///   user's work away: no alert, no request, no spinner, no dismissal.
///
/// WHY THESE ASSERT ON THE PLAN AND NOT ON A GUARD
///   A test that checks "a guard exists" can pass while Save still does
///   nothing. The claim that matters is the OUTCOME of the tap, so these
///   assert what Save resolves to. `AddPlaceSheet.plan` is the single decision
///   both `.disabled` and `savePlace()` consume, which is what makes the two
///   unable to disagree — and `testEverythingTheButtonEnablesActuallySaves`
///   is the test that pins that pairing rather than either half of it.
final class AddPlaceSaveWithoutCircleTests: XCTestCase {

    private let realCircle = "8f14e45f-ceea-467a-9f8e-4b1c2d3e4f50"

    /// A filled-in form: named, located, idle. Only the circle varies.
    private func plan(circle: String?) -> AddPlaceSheet.SavePlan? {
        AddPlaceSheet.plan(
            name: "Gym",
            hasCoordinate: true,
            isLoading: false,
            activeCircleId: circle
        )
    }

    // MARK: - Saving with no circle

    /// No circles, a complete form, and Save must still save.
    func testSavingWithNoCircleCreatesAPersonalPlace() {
        XCTAssertEqual(plan(circle: nil), .createPersonal,
                       "a solo user's Save must create a personal place; "
                       + "the wire has posted circle_id: null all along")
    }

    /// The invariant in its weakest, bluntest form: whatever Save does, it
    /// must not be *nothing*.
    func testSavingWithNoCircleIsNotANoOp() {
        XCTAssertNotNil(plan(circle: nil),
                        "Save was enabled with no circle and did nothing: no request, "
                        + "no error, no dismissal. An enabled Save must never no-op.")
    }

    /// The pairing. Every state the Save button enables — the `.disabled`
    /// predicate, negated — must resolve to a real action, whatever the
    /// circle state is. A new requirement smuggled into the save path (a
    /// circle, a premium check, a non-empty address) fails here, because that
    /// is exactly how a hittable dead button gets built.
    func testEverythingTheButtonEnablesActuallySaves() {
        let circleStates: [String?] = [nil, SelfKeyManager.selfCircleUuid, realCircle]
        for circle in circleStates {
            // name non-empty, coordinate present, not already saving.
            let outcome = AddPlaceSheet.plan(
                name: "Gym",
                hasCoordinate: true,
                isLoading: false,
                activeCircleId: circle
            )
            XCTAssertNotNil(outcome,
                            "Save is enabled in this state but resolves to nothing "
                            + "(activeCircleId: \(circle ?? "nil"))")
        }
    }

    // MARK: - The circle case still works

    /// An active circle keeps its post-create share: saving without a circle
    /// must not quietly turn every place private.
    func testAnActiveCircleStillGetsTheShare() {
        XCTAssertEqual(plan(circle: realCircle), .createAndShare(circleId: realCircle),
                       "a place created while a circle is active is still shared with it")
    }

    /// The self-circle is not a share target. `sharePlaceWithCircle` requires
    /// `cryptoManager.hasCircleKey(circleId:)` for a real circle and the owner
    /// wrap already exists, so posting a self-share would be a wasted, failing
    /// round-trip. `CreatePlaceFromMapSheet.create()` makes the same exclusion.
    func testTheSelfCircleIsNotAShareTarget() {
        XCTAssertEqual(plan(circle: SelfKeyManager.selfCircleUuid), .createPersonal,
                       "\"Just me\" is not a circle to share with")
    }

    // MARK: - What must still do nothing

    /// The three states the button legitimately greys out stay no-ops, or
    /// `.disabled(savePlan == nil)` would enable Save on an empty form.
    func testAnUnnamedPlaceSavesNothing() {
        XCTAssertNil(
            AddPlaceSheet.plan(name: "", hasCoordinate: true, isLoading: false, activeCircleId: realCircle),
            "an unnamed place is not saveable"
        )
    }

    func testAPlaceWithNoCoordinateSavesNothing() {
        XCTAssertNil(
            AddPlaceSheet.plan(name: "Gym", hasCoordinate: false, isLoading: false, activeCircleId: realCircle),
            "a place with nowhere to be is not saveable"
        )
    }

    /// Re-tapping while the first save is in flight must not start a second.
    func testASaveAlreadyInFlightStartsNothingNew() {
        XCTAssertNil(
            AddPlaceSheet.plan(name: "Gym", hasCoordinate: true, isLoading: true, activeCircleId: nil),
            "a save in flight must not be re-entered"
        )
    }
}
