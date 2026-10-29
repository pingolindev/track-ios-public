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

/// Drives the first-launch onboarding walkthrough without a real SRP
/// round-trip.
///
/// Launches with:
///   -UITestSyntheticSession   isAuthenticated = true, synthetic user
///   -UITestForceOnboarding    override the synthetic-session default
///                             and flip onboarding.complete = false so
///                             the walkthrough is what renders
///
/// What this protects:
///   - All four pages exist and have their expected title.
///   - Back / Next navigation works between pages.
///   - The "Allow X" action buttons swap to "Asked" after being
///     tapped, and stay disabled (so re-tapping doesn't re-fire the
///     permission prompt).
///   - The final page swaps Next to "Get Started" and flipping it
///     clears the walkthrough (RootView moves to MainTabView).
final class OnboardingTests: XCTestCase {

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITestCleanState", "1",
            "-UITestSyntheticSession",
            "-UITestForceOnboarding",
        ]
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// All four page titles render in order, and Back / Next moves
    /// between them correctly.
    func testWalkthroughFourPages() throws {
        let app = makeApp()
        app.launch()

        // Page 1: Welcome — the title should be visible on launch.
        XCTAssertTrue(app.staticTexts["Welcome to Track"].waitForExistence(timeout: 10),
                      "Page 1 should show 'Welcome to Track' title")

        // Welcome page has no "Allow X" action, so Next is the only
        // forward control.
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Location"].waitForExistence(timeout: 3),
                      "Page 2 should show 'Location' after first Next")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 3),
                      "Page 3 should show 'Notifications' after second Next")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Motion (Optional)"].waitForExistence(timeout: 3),
                      "Page 4 should show 'Motion (Optional)' after third Next")

        // Back all the way to page 1.
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Notifications"].waitForExistence(timeout: 3),
                      "Back from page 4 should land on Notifications")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Location"].waitForExistence(timeout: 3))
        app.buttons["Back"].tap()
        XCTAssertTrue(app.staticTexts["Welcome to Track"].waitForExistence(timeout: 3))

        // First page has no Back button; verify it's absent.
        XCTAssertFalse(app.buttons["Back"].exists,
                       "Back button should be hidden on the welcome page")
    }

    /// Tapping an "Allow X" action button swaps its label to "Asked"
    /// and disables it — prevents re-tapping from firing the system
    /// permission prompt a second time (which iOS would deny as a
    /// duplicate anyway, but the user would see an extra sheet).
    func testAllowButtonSwapsToAskedAndDisables() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Track"].waitForExistence(timeout: 10))
        app.buttons["Next"].tap() // -> Location page

        let allowLocation = app.buttons["Allow Location"]
        XCTAssertTrue(allowLocation.waitForExistence(timeout: 3))
        XCTAssertTrue(allowLocation.isEnabled)

        allowLocation.tap()

        // Tapping may surface the system authorization sheet (which
        // is outside the app's accessibility tree) — dismiss it if
        // present so the next assertion lands.
        let systemAllowButton = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .alerts.buttons["Allow While Using App"]
        if systemAllowButton.waitForExistence(timeout: 3) {
            systemAllowButton.tap()
        }

        let asked = app.buttons["Asked"]
        XCTAssertTrue(asked.waitForExistence(timeout: 3),
                      "Allow button label should swap to 'Asked' after tap")
        XCTAssertFalse(asked.isEnabled,
                       "'Asked' button should be disabled — prevents a duplicate system prompt")
    }

    /// Final page's Get Started flips onboarding.complete, which the
    /// RootView reads to swap OnboardingView for MainTabView. The
    /// synthetic-session bypass already registered the user, so the
    /// tab bar is what should render next.
    func testGetStartedExitsToMainTabView() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Track"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            app.buttons["Next"].tap()
            // Small settle so the TabView .page animation doesn't
            // race the next assertion on slower machines.
            usleep(300_000)
        }

        XCTAssertTrue(app.staticTexts["Motion (Optional)"].waitForExistence(timeout: 3))

        let getStarted = app.buttons["Get Started"]
        XCTAssertTrue(getStarted.exists,
                      "Final page should swap Next to Get Started")
        getStarted.tap()

        // MainTabView's tab bar should appear now that
        // onboarding.complete is true.
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5),
                      "Tab bar should render after Get Started flips onboarding.complete")
    }
}
