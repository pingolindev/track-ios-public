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

/// Coverage for App/Services/NetworkResilience.swift. Both helpers are
/// actor-isolated so every call goes through `await`.
final class NetworkResilienceTests: XCTestCase {

    // MARK: - RateLimiter

    func testRetryAfterHeaderHonoredWhenPresent() async {
        let limiter = RateLimiter()
        // Server-supplied 3-second wait should round-trip as 3000 ms,
        // capped by the per-retry max which is well above 3s.
        let wait = await limiter.waitMs(forRetryAfterHeader: "3", attempt: 1, totalWaitedMs: 0)
        XCTAssertEqual(wait, 3_000)
    }

    func testRetryAfterCappedAtTenSeconds() async {
        let limiter = RateLimiter()
        // The server asks for an hour — the wait caps at 10 s per
        // retry.
        let wait = await limiter.waitMs(forRetryAfterHeader: "3600", attempt: 1, totalWaitedMs: 0)
        XCTAssertEqual(wait, 10_000)
    }

    func testExponentialBackoffWhenNoHeader() async {
        let limiter = RateLimiter()
        // No header -> exponential backoff. attempt=1: base 1000 ms,
        // attempt=2: base 2000 ms. Jitter adds 0…(base/2) on top, so
        // the test asserts ranges, not exact values.
        let wait1 = await limiter.waitMs(forRetryAfterHeader: nil, attempt: 1, totalWaitedMs: 0) ?? 0
        XCTAssertGreaterThanOrEqual(wait1, 1_000)
        XCTAssertLessThanOrEqual(wait1, 1_500)

        let wait2 = await limiter.waitMs(forRetryAfterHeader: nil, attempt: 2, totalWaitedMs: 0) ?? 0
        XCTAssertGreaterThanOrEqual(wait2, 2_000)
        XCTAssertLessThanOrEqual(wait2, 3_000)
    }

    func testReturnsNilOnceBudgetExhausted() async {
        let limiter = RateLimiter()
        // Already used 19s of a 20s budget — even a 2s retry overshoots.
        let wait = await limiter.waitMs(forRetryAfterHeader: "2", attempt: 1, totalWaitedMs: 19_000)
        XCTAssertNil(wait)
    }

    func testReturnsNilOnceMaxRetriesExceeded() async {
        let limiter = RateLimiter()
        // Max retries is 2; attempt 3 should be refused immediately.
        let wait = await limiter.waitMs(forRetryAfterHeader: "1", attempt: 3, totalWaitedMs: 0)
        XCTAssertNil(wait)
    }

    func testInvalidRetryAfterFallsThroughToBackoff() async {
        let limiter = RateLimiter()
        // Header present but unparseable -> fall through to exponential
        // backoff and still return a wait.
        let wait = await limiter.waitMs(forRetryAfterHeader: "Mon, 22 Apr 2026 07:00:00 GMT", attempt: 1, totalWaitedMs: 0) ?? 0
        XCTAssertGreaterThanOrEqual(wait, 1_000)
    }

    // MARK: - CircuitBreaker

    func testUnprotectedPathReturnsNilKey() async throws {
        let breaker = CircuitBreaker()
        let key = try await breaker.canSendRequest(path: "/api/v1/profile")
        XCTAssertNil(key)
    }

    func testProtectedPathReturnsKey() async throws {
        let breaker = CircuitBreaker()
        let key = try await breaker.canSendRequest(path: "/api/v1/circles/abc/locations/latest")
        XCTAssertEqual(key, "/api/v1/circles/")
    }

    func testCircuitOpensAfterThresholdFailures() async throws {
        let breaker = CircuitBreaker()
        let key = try await breaker.canSendRequest(path: "/api/v1/places")
        XCTAssertEqual(key, "/api/v1/places")

        for _ in 0..<5 {
            await breaker.record(failure: key)
        }

        do {
            _ = try await breaker.canSendRequest(path: "/api/v1/places")
            XCTFail("expected CircuitBreakerOpen after 5 failures")
        } catch is CircuitBreakerOpen {
            // Expected.
        }
    }

    func testSuccessResetsFailureCounter() async throws {
        let breaker = CircuitBreaker()
        let key = try await breaker.canSendRequest(path: "/api/v1/locations")

        // Four failures — under the threshold.
        for _ in 0..<4 {
            await breaker.record(failure: key)
        }

        // A success between the 4th and what would be the 5th failure
        // resets the counter, so the breaker stays closed even after
        // another fresh failure.
        await breaker.record(success: key)
        await breaker.record(failure: key)

        let again = try await breaker.canSendRequest(path: "/api/v1/locations")
        XCTAssertEqual(again, "/api/v1/locations")
    }

    func testFailuresOnUnprotectedPathDoNotOpenBreaker() async throws {
        let breaker = CircuitBreaker()
        // Recording a failure under nil key is a no-op.
        for _ in 0..<10 {
            await breaker.record(failure: nil)
        }
        // Protected path is still healthy.
        let key = try await breaker.canSendRequest(path: "/api/v1/circles/foo/members")
        XCTAssertEqual(key, "/api/v1/circles/")
    }
}
