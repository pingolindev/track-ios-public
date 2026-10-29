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

/// Coverage for ErrorBanner.post(_ error:) — the dispatch table that
/// translates APIError codes + URLError cases into user-facing copy.
@MainActor
final class ErrorBannerTests: XCTestCase {

    override func setUp() async throws {
        ErrorBanner.shared.dismiss()
    }

    override func tearDown() async throws {
        ErrorBanner.shared.dismiss()
    }

    func testCircuitOpenBecomesWarning() {
        ErrorBanner.shared.post(APIError(code: "circuit_open", message: "internal"))
        let current = ErrorBanner.shared.current
        XCTAssertNotNil(current)
        XCTAssertEqual(current?.kind, .warning)
        XCTAssertEqual(current?.message, "Service paused while it recovers. Retrying soon.")
    }

    func testRateLimitedBecomesWarning() {
        ErrorBanner.shared.post(APIError(code: "rate_limited", message: "internal"))
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .warning)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "Too many requests, slow down a moment.")
    }

    func testUnsupportedBecomesInfo() {
        ErrorBanner.shared.post(APIError(code: "unsupported", message: "internal"))
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .info)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "This action isn't available yet.")
    }

    /// A 401 that is not the end of the sign-in (a request that raced a
    /// refresh or a sign-out) is nothing the person can fix, so it says
    /// nothing — least of all "sign in again".
    func testAnUnauthorizedRequestAsksNothing() {
        for message in ["internal", "Token refresh failed", "No access token", "No user id available"] {
            ErrorBanner.shared.post(APIError(code: "unauthorized", message: message))
            XCTAssertNil(ErrorBanner.shared.current, message)
        }
    }

    /// ...and "sign in again" is said only where it is true: the server refused
    /// this device's sign-in for good.
    func testOnlyTheEndOfTheSignInSaysSignInAgain() {
        ErrorBanner.shared.postSignedOut()
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .error)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "Your session expired. Please sign in again.")
    }

    /// An unknown failure is said in the app's words: the server's never
    /// reach the screen.
    func testAnUnknownAPIErrorShowsAPlainLineNotTheServersText() {
        ErrorBanner.shared.post(APIError(code: "weird_thing", message: "Custom server message"))
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .error)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "That didn't work. Please try again.")
    }

    func testOfflineURLErrorBecomesInfo() {
        let urlError = URLError(.notConnectedToInternet)
        ErrorBanner.shared.post(urlError)
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .info)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "You're offline. Showing cached data.")
    }

    /// A cancelled load says nothing: the map's `.task(id:)` re-runs when the
    /// active circle resolves and cancels the first run's request, which would
    /// otherwise show "cancelled" on every opening of the app.
    func testACancelledLoadSaysNothing() {
        let nsCancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        for error: Error in [URLError(.cancelled), CancellationError(), nsCancelled] {
            ErrorBanner.shared.post(error)
            XCTAssertNil(ErrorBanner.shared.current, "\(error)")
        }
    }

    /// ...while a request that really failed still says so.
    func testATimedOutRequestIsStillShown() {
        ErrorBanner.shared.post(URLError(.timedOut))
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .error)
        XCTAssertNotNil(ErrorBanner.shared.current?.message)
    }

    func testPlainSwiftErrorFallsThroughToLocalizedDescription() {
        struct Boom: LocalizedError {
            var errorDescription: String? { "kaboom" }
        }
        ErrorBanner.shared.post(Boom())
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .error)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "kaboom")
    }

    func testDismissClearsCurrent() {
        ErrorBanner.shared.post("hello", kind: .info)
        XCTAssertNotNil(ErrorBanner.shared.current)
        ErrorBanner.shared.dismiss()
        XCTAssertNil(ErrorBanner.shared.current)
    }
}
