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

/// Exercises the DeleteAccountSheet's input-validation surface without
/// actually hitting the auth server's DELETE endpoint. The sheet is the
/// user-facing App Store 5.1.1(v) compliance affordance, and its
/// belt-and-braces guard (password non-empty + typed "DELETE"
/// confirmation) is load-bearing — a change that enabled the destructive
/// button on empty input would let a thumb-fat tap wipe the account.
///
/// The full round trip against the server (register → delete → verify
/// 401 on /auth/me) is not covered here: it needs a per-run throwaway
/// account, which this UI test can't register without driving the iOS
/// registration flow first.
final class AccountDeletionTests: XCTestCase {

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestCleanState", "1",
            "-UITestSyntheticSession",
        ]
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Navigates Settings → Delete Account → sheet and drives the form.
    func testSheetValidatesPasswordAndTypedConfirmation() throws {
        let app = makeApp()
        app.launch()

        // 30 s: in a full-suite run the simulator is a dozen app
        // launches deep and the first frame takes noticeably longer
        // than in isolation.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "Tab bar should render for a synthetic session")
        tabBar.buttons["Settings"].tap()

        // "Delete Account" is near the bottom of Settings — scroll to
        // it so the Button is hittable. XCUITest's `firstMatch.tap()`
        // on an off-screen button can hit an ancestor instead.
        let deleteRow = app.buttons["Delete Account"]
        for _ in 0..<8 where !deleteRow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(deleteRow.isHittable, "Delete Account row should be reachable in Settings")
        deleteRow.tap()

        // Sheet navigation title is the easiest anchor.
        XCTAssertTrue(app.navigationBars["Delete Account"].waitForExistence(timeout: 5),
                      "DeleteAccountSheet should present after tapping Delete Account")

        let passwordField = app.secureTextFields["Your account password"]
        let confirmField = app.textFields["Type DELETE to confirm"]
        let destructive = app.buttons["Delete My Account"]

        XCTAssertTrue(passwordField.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmField.exists)
        // The explanation sections push the destructive row below the fold.
        // SwiftUI's Form does not expose that row to XCUITest until it has
        // scrolled into view, so scroll exactly as a person would before
        // asserting it exists.
        for _ in 0..<4 where !destructive.exists {
            app.swipeUp()
        }
        XCTAssertTrue(destructive.exists)

        // Empty state: destructive button is disabled.
        XCTAssertFalse(destructive.isEnabled,
                       "Delete button must stay disabled until both fields validate")

        // Password alone — still disabled. This catches a gate tied
        // only to the DELETE text field.
        for _ in 0..<4 where !passwordField.isHittable {
            app.swipeDown()
        }
        passwordField.tap()
        passwordField.typeText("any-password")
        XCTAssertFalse(destructive.isEnabled,
                       "Delete button must stay disabled with password alone (missing typed DELETE)")

        // Both fields valid — button enables.
        confirmField.tap()
        confirmField.typeText("DELETE")
        XCTAssertTrue(destructive.isEnabled,
                      "Delete button must enable once password + DELETE are typed")

        // Cancel — never actually hits the backend in this
        // shell test.
        app.navigationBars["Delete Account"].buttons["Cancel"].tap()
        XCTAssertFalse(app.navigationBars["Delete Account"].exists,
                       "Cancel should dismiss the sheet")
    }
}
