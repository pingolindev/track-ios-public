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

/// App Review looks for a visible Restore Purchases control (guideline 3.1.1),
/// and the launch-time `StoreKitManager.restore()` is invisible. This pins the
/// button to the subscription sheet a user reaches from Settings.
///
/// Uses the DEBUG-only -UITestSyntheticSession bypass (see
/// AuthenticatedShellTests). Its token is valid against no backend, so the
/// sheet's eligibility check fails — which is exactly a state that must still
/// offer Restore: the person looking for it is the one whose purchase did not
/// show up.
final class RestorePurchasesTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSubscriptionSheetOffersRestorePurchases() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestSyntheticSession"]
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()
        acceptSystemPermissionPrompts()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.buttons["Settings"].tap()

        let plan = app.buttons["plan-info-button"]
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "Settings shows the plan row")
        if !plan.isHittable { app.swipeUp() }
        plan.tap()

        let restore = app.buttons["premium-restore-purchases"]
        XCTAssertTrue(
            restore.waitForExistence(timeout: 20),
            "the subscription sheet must offer Restore Purchases once eligibility has answered")
        XCTAssertTrue(restore.isHittable)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "subscription-sheet-restore"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
