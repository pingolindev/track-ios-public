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

/// Coverage for `APIError.isSessionDefinitivelyExpired` — the single gate that
/// decides whether a failure is allowed to sign the user out.
///
/// Both directions are load-bearing, in opposite ways:
///
///  * **False when it should be true**: a session revoked while the app is
///    running never signs out, and every call goes 401 → refresh → denied →
///    error banner, on repeat until a force-quit — hundreds of denied
///    `/auth/refresh` calls an hour against one revoked session, while the app
///    renders as signed-in and no location reaches the server. So the gate
///    applies on every path, not only at launch.
///
///  * **True when it should be false** is worse. Logging out on a transient
///    error wipes the refresh token, and with no stored password the device is
///    dark until someone signs in again by hand. Every negative case below is a
///    genuine error the app sees routinely and must survive.
final class SessionRevocationTests: XCTestCase {

    // MARK: - Positive control

    func testRefreshFailedIsDefinitive() {
        let error = APIError(code: "refresh_failed", message: "Refresh token rejected: session revoked")
        XCTAssertTrue(APIError.isSessionDefinitivelyExpired(error))
    }

    /// The message is the server's reason string and varies; only the code is
    /// the contract. Pin that so a message change can't quietly flip the gate.
    func testRefreshFailedIsDefinitiveRegardlessOfMessage() {
        for message in ["", "(no body)", "session not found", "signature failure"] {
            let error = APIError(code: "refresh_failed", message: message)
            XCTAssertTrue(
                APIError.isSessionDefinitivelyExpired(error),
                "refresh_failed should be definitive with message \(message.debugDescription)"
            )
        }
    }

    // MARK: - Negative controls: transient APIErrors must NOT sign out

    /// `unauthorized` is the closest false friend: `execute()` throws it when a
    /// retry still 401s *after* a successful refresh. That means the access
    /// token lost a rotation race, not that the session is gone — signing out
    /// on it would give "logged in, then immediately logged out".
    func testUnauthorizedIsNotDefinitive() {
        let error = APIError(code: "unauthorized", message: "Token refresh failed")
        XCTAssertFalse(APIError.isSessionDefinitivelyExpired(error))
    }

    func testTransientAPIErrorCodesAreNotDefinitive() {
        let transient = [
            "circuit_open",     // breaker fail-fast — server health, not session
            "rate_limited",     // 429 — server is healthy, just throttling
            "network_error",    // non-HTTP response
            "no_tokens",        // local precondition, never reached the server
            "decode_failed",    // our Codable disagrees with the payload
            "unsupported",
            "http_500",
            "http_502",
            "http_503",
            "http_404",
        ]
        for code in transient {
            let error = APIError(code: code, message: "boom")
            XCTAssertFalse(
                APIError.isSessionDefinitivelyExpired(error),
                "\(code) is transient and must not force a logout"
            )
        }
    }

    // MARK: - Negative controls: non-APIError failures

    func testURLErrorsAreNotDefinitive() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet,
            .timedOut,
            .networkConnectionLost,
            .cannotFindHost,
            .secureConnectionFailed,
            .cancelled,
        ]
        for code in codes {
            XCTAssertFalse(
                APIError.isSessionDefinitivelyExpired(URLError(code)),
                "URLError.\(code) is transient and must not force a logout"
            )
        }
    }

    func testCircuitBreakerOpenIsNotDefinitive() {
        let error = CircuitBreakerOpen(path: "/api/v1/circles/")
        XCTAssertFalse(APIError.isSessionDefinitivelyExpired(error))
    }

    func testArbitrarySwiftErrorIsNotDefinitive() {
        struct Boom: Error {}
        XCTAssertFalse(APIError.isSessionDefinitivelyExpired(Boom()))
    }

    /// A `CancellationError` is routine here — the cold-start SwiftUI `.task`
    /// callers that await a refresh get torn down as the view tree settles.
    func testCancellationIsNotDefinitive() {
        XCTAssertFalse(APIError.isSessionDefinitivelyExpired(CancellationError()))
    }

    // MARK: - Banner copy

    /// The revoked path is the one place "sign in again" is true, so it asks
    /// ErrorBanner for that copy by name; an ordinary `unauthorized` error
    /// never produces it.
    @MainActor
    func testRevocationBannerReadsAsSessionExpired() throws {
        ErrorBanner.shared.dismiss()
        ErrorBanner.shared.postSignedOut()
        XCTAssertEqual(ErrorBanner.shared.current?.kind, .error)
        XCTAssertEqual(ErrorBanner.shared.current?.message, "Your session expired. Please sign in again.")
        ErrorBanner.shared.dismiss()

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Managers/AuthManager.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func handleSessionRevoked() async {"))
        let body = source[start.upperBound...].prefix(1_200)
        XCTAssertTrue(body.contains("ErrorBanner.shared.postSignedOut()"), "the revocation must still say it")
    }
}
