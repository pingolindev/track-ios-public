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

/// Shared helpers for the UI cases that log in against a real backend.
///
/// These exist because three environment behaviours reliably break a naive
/// "log in, tap a tab, assert" flow, and each one surfaces as a failure
/// somewhere unrelated. Every login-driven case should use these rather
/// than re-deriving them.
extension XCTestCase {

    /// Dismiss iOS's post-login "Save Password?" prompt.
    ///
    /// The prompt is MODAL over the whole app: while it is up every element
    /// behind it reports `isHittable == false`, and the failure names the
    /// element you wanted rather than the prompt — "Circles navbar never
    /// appeared", "Emergency SOS button missing" — which is why its call sites
    /// each carry a comment about a tap that went nowhere.
    ///
    /// WHY BOTH PROCESSES ARE POLLED
    ///   On iOS 26 the prompt is presented IN THE APP'S OWN PROCESS: its buttons
    ///   are under `app.buttons`, not SpringBoard's, while earlier iOS presents it
    ///   from SpringBoard. A SpringBoard-only query on iOS 26 spends its whole
    ///   timeout, reports "no prompt", and leaves the app wedged behind an
    ///   invisible modal. Poll BOTH so this works whichever process owns the
    ///   prompt. (The Note iOS app's UI tests do the same.)
    ///
    ///   `addUIInterruptionMonitor` does NOT cover this either — it only fires
    ///   for elements outside the app under test.
    ///
    /// Polls both processes in one loop rather than waiting out a full timeout
    /// per label, so the common no-prompt case costs `timeout` once instead of
    /// once per spelling. Best-effort: a cheap no-op when it isn't showing.
    func dismissSavePasswordPromptIfPresent(
        _ app: XCUIApplication = XCUIApplication(),
        timeout: TimeInterval = 3
    ) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in ["Not Now", "Not now"] {
                for button in [app.buttons[label], springboard.buttons[label]]
                where button.exists && button.isHittable {
                    button.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Accept any SpringBoard permission prompts (notifications, location).
    ///
    /// Loops because iOS presents them one at a time, and returns as soon as a
    /// pass finds nothing to tap. A runner can seed these with
    /// `simctl privacy grant`; this is the belt to those braces, for runs
    /// against a simulator that hasn't been seeded.
    func acceptSystemPermissionPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 1...6 {
            var tapped = false
            // "Change to Always Allow" / "Keep Only While Using" are the
            // when-in-use → always ESCALATION dialog, which is worded nothing
            // like the first-grant one. Left standing over the app it dims
            // everything, and the next assertion fails naming whatever it was
            // looking for. Always-variant first: this app needs Always for its
            // background pumps, and the escalation dialog always offers both.
            for label in ["Allow", "Allow While Using App", "Always Allow",
                          "Change to Always Allow", "Keep Only While Using", "OK"] {
                let button = springboard.buttons[label]
                if button.exists && button.isHittable {
                    button.tap()
                    tapped = true
                    usleep(1_500_000)
                    break
                }
            }
            if !tapped { return }
        }
    }

    /// Switch to a tab and confirm it actually changed.
    ///
    /// The FIRST tap after login is reliably swallowed: the tab bar exists
    /// while the view is still transitioning off the auth screen, so the tap
    /// lands on nothing and the selection stays put. A single `tap()` then
    /// fails much later and somewhere else ("screen should render", "button
    /// missing"). Asserting on the result is what makes this deterministic.
    ///
    /// Returns whether the tab ended up selected.
    @discardableResult
    func selectTab(_ name: String, in tabBar: XCUIElement, attempts: Int = 4) -> Bool {
        let tab = tabBar.buttons[name]
        for _ in 1...attempts {
            if tab.isSelected { return true }
            if tab.exists { tab.tap() }
            usleep(1_500_000)
        }
        return tab.isSelected
    }

    /// Assert that the tap just made opened a web page INSIDE the app (Safari's
    /// view controller) on `host`, then close it with the browser's own button.
    ///
    /// Every account page opens in the app (`InAppSafari`), never in the Safari
    /// app (App Store Review Guideline 4). On iOS 26.4 (iPhone Air simulator)
    /// the browser publishes a `TopBrowserBar` holding a "Close" button and a
    /// "URL" button whose value is the page's host. Earlier iOS calls the close
    /// button "Done".
    func assertInAppBrowser(
        showing host: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let address = app.buttons["URL"]
        let opened = address.waitForExistence(timeout: 10)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        if safari.state == .runningForeground {
            // Leave the simulator on the app for the tests that follow.
            app.activate()
            XCTFail("the link switched to the Safari app", file: file, line: line)
            return
        }
        XCTAssertTrue(opened, "no in-app browser opened:\n\(app.debugDescription)", file: file, line: line)
        guard opened else { return }
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
        XCTAssertTrue(String(describing: address.value ?? "").contains(host),
                      "the in-app browser shows \(String(describing: address.value)), not \(host)",
                      file: file, line: line)

        let close = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["Close", "Done"])
        ).firstMatch
        XCTAssertTrue(close.exists, "the in-app browser needs its way back:\n\(app.debugDescription)",
                      file: file, line: line)
        // A touch at the button's centre, as a finger would. The element's own
        // `tap()` does nothing on this button: the browser's controls belong to
        // another process (SafariViewService), and on iOS 26.4 two element taps
        // in a row left the page open while one coordinate tap closed it
        // ("Safari View Controller will be dismissed" in the app's log).
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(address.waitForNonExistence(timeout: 10), "the in-app browser did not close",
                      file: file, line: line)
    }
}
