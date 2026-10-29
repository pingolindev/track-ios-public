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

/// The account pages Settings links to open inside the app.
///
/// Under App Store Review Guideline 4, an app must not take the user to the
/// default web browser to sign in or register for an account. Both of these
/// rows open account-portal pages that ask for a sign-in, so they open inside
/// the app.
///
/// Uses the DEBUG-only -UITestSyntheticSession bypass (see
/// AuthenticatedShellTests): Settings renders without a backend, and these two
/// rows need nothing from one.
final class AccountPagesInAppTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecoveryEmailOpensInsideTheApp() throws {
        let app = openSettings()
        let row = app.buttons["settings-recovery-email"]
        tapRow(row, in: app)
        assertInAppBrowser(showing: "account.pingolin", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "closing the browser should return to Settings")
    }

    func testTwoFactorOpensInsideTheApp() throws {
        let app = openSettings()
        let row = app.buttons["Two-Factor Authentication"]
        tapRow(row, in: app)
        assertInAppBrowser(showing: "account.pingolin", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "closing the browser should return to Settings")
    }

    private func openSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestSyntheticSession"]
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()
        acceptSystemPermissionPrompts()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "the synthetic session should reach the tab bar")
        XCTAssertTrue(selectTab("Settings", in: tabs), "Settings tab never selected")
        return app
    }

    /// Settings is a long list: scroll until the row can take a tap.
    private func tapRow(_ row: XCUIElement, in app: XCUIApplication, line: UInt = #line) {
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(row) missing from Settings", line: line)
        for _ in 1...6 where !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "\(row) never became tappable", line: line)
        row.tap()
    }
}
