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
import UIKit

/// The rest of a launch that couldn't read /auth/me, once it can.
///
/// A launch with a stored session whose /auth/me failed transiently (no
/// network, a timeout, a 5xx, a 429, the circuit open) keeps the session and
/// shows the app (`AuthManager.checkExistingSession`). On its own that leaves
/// the user unset, so the guardian disclosure never shows, and nothing of
/// Track's starts, so the process shares nothing ("Location stream isn't
/// running yet") until the next launch, however soon the network comes back.
///
/// This reads /auth/me again after a growing wait (`delay`), or sooner when the
/// network comes back or the app comes to the front, and never in the background
/// (what `wait` does), until it answers; then the launch finishes as an online
/// one does (`AuthManager.completeLaunch`). It ends with the session it began in,
/// and a definitive refusal ends the session as the launch's own would have.
@MainActor
struct LaunchRetry {
    /// What a failed read means.
    enum Next: Equatable {
        /// Transient: wait, and read again.
        case again
        /// The session is definitively gone: end it, as the launch would have.
        case expire
    }

    /// Reads /auth/me.
    var read: () async throws -> User
    /// Whether the session the launch began in is still the one signed in.
    var isCurrent: () -> Bool
    /// What a failed read means.
    var next: (Error) -> Next
    /// Waits about `seconds`, less when woken.
    var wait: (TimeInterval) async -> Void
    /// The launch, finished with what /auth/me served.
    var complete: (User) async -> Void
    /// The session ended, as the launch's definitive branch ends it.
    var expire: () -> Void

    /// 5 s, doubling to a minute, then every minute.
    nonisolated static func delay(attempt: Int) -> TimeInterval {
        min(60, 5 * pow(2, Double(max(0, attempt))))
    }

    /// Reads until /auth/me answers, the session is definitively refused, or
    /// it is no longer the session the launch began in.
    func run() async {
        var attempt = 0
        while !Task.isCancelled {
            await wait(Self.delay(attempt: attempt))
            guard !Task.isCancelled, isCurrent() else { return }
            do {
                let user = try await read()
                guard isCurrent() else { return }
                await complete(user)
                return
            } catch {
                guard isCurrent() else { return }
                switch next(error) {
                case .again: attempt += 1
                case .expire: expire(); return
                }
            }
        }
    }
}

/// The wait between reads (`LaunchRetry.wait`): about `seconds`, a second at a
/// time, ended early by a wake, the network coming back or the app coming to the
/// front. A wake counts once. One that comes while a read is under way ends the
/// next wait: that read may have failed just before the network came back.
///
/// Nothing in the background: no tick, and no wait ends there, so nothing is
/// read. A process kept up there by location would otherwise read /auth/me every
/// minute of an outage all night; the email-verification and approval watches
/// stop on backgrounding for the same reason (`startEmailVerificationPolling`).
/// The app coming to the front wakes it, and the read is at once.
@MainActor
final class LaunchRetryWait {
    private var woken = false
    private var parked: CheckedContinuation<Void, Never>?
    private let tick: () async -> Void
    private let inBackground: @MainActor () -> Bool

    /// `tick`: a second, and `inBackground`: the app's state, outside tests.
    init(tick: @escaping () async -> Void = { _ = try? await Task.sleep(nanoseconds: 1_000_000_000) },
         inBackground: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .background }) {
        self.tick = tick
        self.inBackground = inBackground
    }

    func wake() {
        woken = true
        parked?.resume()
        parked = nil
    }

    func wait(_ seconds: TimeInterval) async {
        var left = seconds
        while left > 0, !woken, !Task.isCancelled {
            if inBackground() {
                await park()
            } else {
                await tick()
                left -= 1
            }
        }
        // A wake in the background (the network back) doesn't read there either.
        while inBackground(), !Task.isCancelled {
            await park()
        }
        woken = false
    }

    /// Until the next wake, or the task's cancel.
    private func park() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { parked = $0 }
        } onCancel: {
            Task { @MainActor in self.wake() }
        }
    }

    /// Whether a network path report wakes: one that turns satisfied, never the
    /// monitor's first, which only says how things stand.
    nonisolated static func wakes(from last: Bool?, to satisfied: Bool) -> Bool {
        satisfied && last == false
    }
}
