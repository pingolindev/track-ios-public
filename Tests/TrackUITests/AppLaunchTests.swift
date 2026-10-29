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

/// Smoke-level XCUITests that run on an iOS simulator.
///
/// These are *not* backed by a real auth backend — they exercise the
/// view surface the user lands on before any network call succeeds.
/// That means:
///   - App launches without crashing
///   - Login screen is visible on first run
///   - Sign-up navigation works
///   - Sign-In button correctly gates on empty fields
///
/// For anything that needs a session (map, circles, SOS, ...), use a
/// separate file that launches with a configured test account, or with
/// the DEBUG-only -UITestSyntheticSession argument (see
/// AuthenticatedShellTests) — never a test-only code path in Release
/// builds.
final class AppLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Verifies the app starts and lands on the Login screen.
    func testLoginScreenAppearsOnCleanLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()

        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 10),
            "Email field should be visible on the login screen"
        )
        XCTAssertTrue(
            app.secureTextFields["Password"].exists,
            "Password field should be visible on the login screen"
        )
        XCTAssertTrue(
            app.buttons["Sign In"].exists,
            "Sign In button should be visible on the login screen"
        )
    }

    /// Sign In must be disabled until both fields are non-empty —
    /// protects against accidental taps that fire empty-credential SRP
    /// flows (and surface confusing network errors).
    func testSignInDisabledWhenFieldsEmpty() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()

        let signIn = app.buttons["Sign In"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertFalse(signIn.isEnabled, "Sign In should be disabled with empty fields")

        let email = app.textFields["Email"]
        email.tap()
        email.typeText("user@example.test")
        XCTAssertFalse(signIn.isEnabled, "Sign In should still be disabled with only an email")

        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("password123")
        XCTAssertTrue(signIn.isEnabled, "Sign In should be enabled once both fields are filled")
    }

    /// "Sign Up" links OUT to the account portal; the app has no sign-up form.
    ///
    /// The portal owns registration, so what is worth asserting here is that
    /// the way out exists and is a link, not a push. Where the tap lands is
    /// `testSignUpOpensInsideTheApp`.
    func testSignUpLinksOutToTheAccountPortal() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()

        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 10),
            "Login screen should render first"
        )

        // `buttons`, not `links`. A SwiftUI `Link` is published to the
        // accessibility tree as a BUTTON — on the iPhone 17 Pro simulator,
        // iOS 26.4, dumping both collections on this very screen gives:
        //
        //   links:   []
        //   buttons: ["", "login-forgot-password", "login-sign-up"]
        //
        // So `app.links["login-sign-up"]` can never match, although
        // App/Views/Auth/LoginView.swift does give the `Link` that identifier.
        //
        // waitForExistence rather than a bare `exists`: the Email field
        // rendering does not mean the rest of the form has been laid out.
        let signUp = app.buttons["login-sign-up"]
        XCTAssertTrue(
            signUp.waitForExistence(timeout: 5),
            "Sign Up link missing from login screen"
        )
        XCTAssertTrue(signUp.isHittable, "Sign Up link must be tappable, not just present")
        XCTAssertTrue(
            app.staticTexts["Don't have an account?"].exists,
            "the link needs its lead-in text to read as a sentence"
        )
        // There is no native register screen.
        XCTAssertFalse(app.textFields["Display Name"].exists,
                       "Display Name belongs to the removed native sign-up form")
    }

    /// Sign Up must not take people to the Safari app to register (App
    /// Store Review Guideline 4): it opens in Safari's view controller
    /// inside Track, and closing it comes back to sign-in.
    func testSignUpOpensInsideTheApp() throws {
        assertOpensInsideTheApp("login-sign-up")
    }

    /// Same guideline, same page family: resetting a password is signing in.
    func testForgotPasswordOpensInsideTheApp() throws {
        assertOpensInsideTheApp("login-forgot-password")
    }

    private func assertOpensInsideTheApp(_ identifier: String, line: UInt = #line) {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()

        let link = app.buttons[identifier]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "\(identifier) missing from login screen")
        link.tap()
        assertInAppBrowser(showing: "account.pingolin", in: app, line: line)
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 10),
                      "closing the browser should return to the sign-in form")
    }
}
