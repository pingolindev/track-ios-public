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

/// What the app does instead of telling a person to "try again later": it
/// tries again itself, on its own clock. A person is never asked to do what
/// can be done automatically.
enum RetryClock {
    /// Wait after the Nth failure in a row: 2, 4, 8, 16, 32, then every 60 s.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        let exponent = Double(min(max(failures - 1, 0), 6))
        return min(2 * pow(2, exponent), 60)
    }

    /// No answer came back — offline, the server unavailable or rate limited —
    /// so a try does not count and may be made again on the clock. Any other
    /// answer is an answer.
    static func nothingAnswered(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let api = error as? APIError else { return false }
        return api.code == "network_error" || api.code == "circuit_open" || api.code == "rate_limited"
            || api.code.hasPrefix("http_5")
    }

    /// Runs `attempt` until it reports success or the calling task is
    /// cancelled — a view's `.task` is, when the view goes away, so a screen
    /// retries only while someone is looking at it.
    @MainActor
    static func untilDone(_ attempt: @MainActor () async -> Bool) async {
        var failures = 0
        while !Task.isCancelled {
            if await attempt() { return }
            failures += 1
            try? await Task.sleep(nanoseconds: UInt64(delay(afterFailures: failures) * 1_000_000_000))
        }
    }
}
