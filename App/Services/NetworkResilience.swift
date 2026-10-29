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

import Foundation

/// Small resilience layer wrapping APIService's network calls. Mirrors
/// the Android app's RateLimitInterceptor + CircuitBreakerInterceptor:
///
/// * Rate limiter — when the server replies 429, parse Retry-After and
///   sleep up to 10s, retry up to twice within a 20s total budget.
/// * Circuit breaker — track per-path consecutive failures, open after
///   5, fail-fast for 30s, then half-open one probe before reclosing.
///
/// Both pieces are actors so concurrent calls don't race the
/// counters / state machines.
actor RateLimiter {
    static let shared = RateLimiter()

    private let maxRetries = 2
    private let initialBackoffMs: UInt64 = 1_000
    private let maxBackoffMs: UInt64 = 10_000
    private let maxRetryAfterMs: UInt64 = 10_000
    private let maxTotalRetryTimeMs: UInt64 = 20_000

    /// Return the milliseconds the caller should wait before retrying,
    /// or nil if we've exhausted the budget. `attempt` is 1-indexed.
    func waitMs(forRetryAfterHeader header: String?, attempt: Int, totalWaitedMs: UInt64) -> UInt64? {
        guard attempt <= maxRetries else { return nil }
        let parsed = parseRetryAfterMs(header) ?? exponentialBackoffMs(attempt: attempt)
        let capped = min(parsed, maxRetryAfterMs)
        if totalWaitedMs + capped > maxTotalRetryTimeMs { return nil }
        return capped
    }

    private func parseRetryAfterMs(_ header: String?) -> UInt64? {
        guard let header = header else { return nil }
        if let seconds = Double(header.trimmingCharacters(in: .whitespaces)) {
            return UInt64(seconds * 1000)
        }
        // Backend always sends seconds, but spec allows HTTP-date too;
        // ignore date form rather than dragging a parser in.
        return nil
    }

    private func exponentialBackoffMs(attempt: Int) -> UInt64 {
        let base = initialBackoffMs * UInt64(pow(2.0, Double(attempt - 1)))
        let jitter = UInt64.random(in: 0...(base / 2))
        return min(base + jitter, maxBackoffMs)
    }
}

/// Per-path circuit breaker. Only protects the paths the Android app also
/// protects (circles / locations / places); other endpoints fall through.
actor CircuitBreaker {
    static let shared = CircuitBreaker()

    private let failureThreshold = 5
    private let recoveryTimeoutMs: TimeInterval = 30
    private let protectedPrefixes = [
        "/api/v1/circles/",
        "/api/v1/locations",
        "/api/v1/places",
    ]

    private enum State { case closed, open, halfOpen }

    private struct Circuit {
        var state: State = .closed
        var failureCount: Int = 0
        var openedAt: Date = .distantPast
    }

    private var circuits: [String: Circuit] = [:]

    /// Throws CircuitBreakerOpen if the breaker for this path is open
    /// (and not yet ready to half-open). Returns the protected key the
    /// caller should pass back into `record(success:)` / `record(failure:)`.
    func canSendRequest(path: String) throws -> String? {
        guard let key = circuitKey(for: path) else { return nil }
        var circuit = circuits[key] ?? Circuit()
        switch circuit.state {
        case .closed, .halfOpen:
            return key
        case .open:
            if Date().timeIntervalSince(circuit.openedAt) >= recoveryTimeoutMs {
                circuit.state = .halfOpen
                circuits[key] = circuit
                return key
            }
            throw CircuitBreakerOpen(path: key)
        }
    }

    func record(success path: String?) {
        guard let key = path else { return }
        circuits[key] = Circuit() // reset
    }

    func record(failure path: String?) {
        guard let key = path else { return }
        var circuit = circuits[key] ?? Circuit()
        circuit.failureCount += 1
        if circuit.failureCount >= failureThreshold {
            circuit.state = .open
            circuit.openedAt = Date()
        }
        circuits[key] = circuit
    }

    private func circuitKey(for path: String) -> String? {
        protectedPrefixes.first(where: { path.hasPrefix($0) })
    }
}

/// Thrown by CircuitBreaker.canSendRequest when the breaker is open.
/// APIService translates this into a user-facing APIError with code
/// "circuit_open" so callers can react (back off the polling loop, show
/// an offline banner, etc.).
struct CircuitBreakerOpen: Error {
    let path: String
}
