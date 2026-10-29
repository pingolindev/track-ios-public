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

/// Shell-level XCUITests that exercise the post-auth surface without
/// a real SRP handshake. Relies on the DEBUG-only
/// -UITestSyntheticSession launch argument handled in
/// AuthManager.checkExistingSession: it seeds a fake user + token in
/// keychain and flips onboarding.complete, so the app renders straight
/// into MainTabView.
///
/// API calls will fail under this bypass — the synthetic token is not
/// a valid JWT against any real backend. That is fine for what this
/// file is checking: the view hierarchy assembles, tab navigation
/// works, and transient network failures surface via the error banner
/// rather than crashing the app.
final class AuthenticatedShellTests: XCTestCase {

    /// The tab bar as MainTabView actually ships it, in order. The middle
    /// tab is "Alerts", as on Android.
    static let tabLabels = ["Map", "Circles", "Alerts", "Places", "Settings"]

    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestSyntheticSession"]
        app.launchArguments += ["-UITestCleanState", "1"]
        return app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verifies the five-tab MainTabView renders after the bypass and
    /// that none of the labels have rotted.
    func testMainTabsPresentAfterSyntheticLogin() throws {
        let app = makeApp()
        app.launch()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "Tab bar should render for a synthetic session")

        for label in Self.tabLabels {
            let button = tabs.buttons[label]
            XCTAssertTrue(button.exists, "Tab '\(label)' should be in the tab bar")
        }

        // ORDER, not just presence. MainTabView's own comment says the order
        // mirrors the Android app (0:Map 1:Circles 2:Alerts 3:Places
        // 4:Settings), that Alerts and Places "are easy to swap by accident",
        // and that cross-platform screenshot parity depends on it. A
        // presence-only check passes just as happily after a swap.
        let actual = tabs.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(actual, Self.tabLabels,
                       "Tab order must match the Android app's for screenshot parity")
    }

    /// Taps through every tab. Any crash (e.g. a view that force-unwraps
    /// CircleManager.activeCircle on mount) surfaces here even if the
    /// happy-path content is empty.
    func testTappingEveryTabDoesNotCrash() throws {
        let app = makeApp()
        app.launch()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))

        for label in Self.tabLabels {
            tabs.buttons[label].tap()
            XCTAssertEqual(app.state, .runningForeground, "App should stay foregrounded after tapping '\(label)'")
            // Let any tab-switch animations or on-appear tasks settle;
            // not strictly necessary but makes flakiness less likely on
            // a slow simulator.
            usleep(250_000)
        }
    }

    /// Settings is a long scrolling view — this case specifically checks
    /// that it lays out far enough to render at least one section header
    /// under the synthetic bypass (where most network data is empty).
    func testSettingsTabRendersSectionHeaders() throws {
        let app = makeApp()
        app.launch()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.buttons["Settings"].tap()

        // One of these headers should always be on-screen given the
        // current SettingsView; if someone renames all of them a future
        // reader will see exactly which header this test expected.
        let candidates = ["Account", "Legal", "Activity", "About"]
        let found = candidates.contains { app.staticTexts[$0].waitForExistence(timeout: 3) }
        XCTAssertTrue(found, "Settings should render at least one of the known section headers: \(candidates)")
    }
}
