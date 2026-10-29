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
import PingolinTrackSDK

/// Identities from before a password reset.
///
/// An email password reset replaces the account keypair, so every circle key —
/// each ECDH-wrapped to the OLD public key — stops opening. The device keeps a
/// perfectly valid session and shows circles with no name, no places and no
/// locations, while all of that data sits on the server intact.
///
/// If the user still had their recovery key they can recover that identity in
/// the account portal, which seals it under a value the SDK derives from the key
/// this app already holds. All the crypto is in the SDK
/// (`importPreviousIdentitiesV2`); this fetches and hands it over.
///
/// An identity may come with its old signing public key (a v2 blob), which
/// lets this account's own wraps and statements from before the reset count
/// again. Each entry's v2 blob is taken when it has one, else its v1 blob. The
/// SDK prefers a v2 blob over a v1 blob of the same identity, so the union
/// below never drops a signing key an earlier answer brought.
///
/// A restore made while the app runs opens without a restart. auth nudges the
/// account's devices with an `identities_check` silent push, and since a
/// silent push is best effort, a return to the foreground while a circle is
/// still locked since a reset asks too. Either way it is the same fetch and
/// import as the first load, under three rules:
///  - It only adds. The SDK's import replaces the set it holds, so what goes in
///    is everything this process was given since sign-in: an empty or lying
///    answer changes nothing.
///  - The circles are loaded again only when more opens than before: more
///    identities, or more of their signing keys.
///  - At most one re-check every `window`, whatever asks; the first load is not
///    counted. A trigger refused because one is running, or inside the window,
///    leaves one pending re-check, which runs when the window ends or at the
///    first foreground after it — and counts as that window's one.
///
/// Sign-out and an account switch forget all of it (`reset()`, through
/// `CircleManager.reset()`); the SDK drops the identities themselves.
@MainActor
final class PreviousIdentityLoader {
    /// At most one re-check in this many seconds.
    static let window: TimeInterval = 180
    /// The server can't plant an identity — a blob opens only under a key
    /// derived from this device's own — but it can send junk, which the union
    /// would keep. An account has one blob per restored reset.
    static let maxHeld = 32

    enum Outcome: Equatable {
        /// This many more identities open than before; the circles were loaded again.
        case opened(Int)
        /// Asked; nothing new opened.
        case unchanged
        /// Not asked now: one is running, or the window is not over. It runs once, later.
        case deferred
        /// The ask or the import failed.
        case failed
    }

    private let fetch: () async throws -> [SealedPreviousIdentity]
    private let importSealed: ([SealedPreviousIdentity]) throws -> Int
    private let count: () -> Int
    private let now: () -> Date
    private let sleepFor: (TimeInterval) async -> Void
    private let onOpened: @MainActor () async -> Void

    private var loaded = false
    /// Every blob this process was given since sign-in, first seen first.
    private(set) var held: [SealedPreviousIdentity] = []
    private var lastRecheckAt: Date?
    private var running = false
    private(set) var pending = false
    private var scheduled = false
    /// Bumped by `reset()`: work begun before a sign-out ends without effect.
    private var generation = 0

    convenience init(api: APIService, cryptoManager: PingolinTrackSDK.CryptoManager,
                     onOpened: @escaping @MainActor () async -> Void) {
        self.init(
            fetch: {
                try await api.getPreviousIdentities().compactMap { row in
                    row.sealedForThisApp.map { SealedPreviousIdentity(nonce: $0.nonce, ciphertext: $0.ciphertext) }
                }
            },
            importSealed: { Int(try cryptoManager.importPreviousIdentitiesV2(sealed: $0)) },
            count: { Int(cryptoManager.previousIdentityCount()) + cryptoManager.previousSigningPublicKeys().count },
            onOpened: onOpened)
    }

    init(fetch: @escaping () async throws -> [SealedPreviousIdentity],
         importSealed: @escaping ([SealedPreviousIdentity]) throws -> Int,
         count: @escaping () -> Int,
         now: @escaping () -> Date = Date.init,
         sleepFor: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
         onOpened: @escaping @MainActor () async -> Void) {
        self.fetch = fetch
        self.importSealed = importSealed
        self.count = count
        self.now = now
        self.sleepFor = sleepFor
        self.onOpened = onOpened
    }

    /// Load once per session, before circle keys are unwrapped.
    ///
    /// Never throws: for almost every account this imports nothing, and a
    /// failure must only mean older data stays unreadable — not that the app
    /// stops working. A transient failure — no answer, or no account key to
    /// open with yet — leaves `loaded` false so a later refresh retries rather
    /// than hiding recovered data for the whole session.
    @discardableResult
    func ensureLoaded() async -> Int {
        if loaded { return count() }
        let asked = generation
        do {
            let answer = try await fetch()
            guard asked == generation else { return 0 }
            let opened = try take(answer)
            loaded = true
            return opened
        } catch {
            print("[PreviousIdentityLoader] not available: \(error)")
            return 0
        }
    }

    /// The `identities_check` nudge, or a foreground that has cause to look.
    @discardableResult
    func recheck() async -> Outcome {
        if running || insideWindow {
            pending = true
            if !running { scheduleForWindowEnd() }
            return .deferred
        }
        return await run()
    }

    /// The app came to the foreground: a pending re-check runs now if its window
    /// is over, and so does one while a circle is locked since a reset.
    @discardableResult
    func foreground(locked: Bool) async -> Outcome? {
        guard pending || locked else { return nil }
        return await recheck()
    }

    /// Sign-out and account switch: forget everything. A re-check waiting for
    /// its window, or running, ends without effect.
    func reset() {
        generation += 1
        loaded = false
        held = []
        lastRecheckAt = nil
        running = false
        pending = false
        scheduled = false
    }

    private var insideWindow: Bool {
        guard let last = lastRecheckAt else { return false }
        return now().timeIntervalSince(last) < Self.window
    }

    private func run() async -> Outcome {
        let asked = generation
        running = true
        pending = false
        lastRecheckAt = now()
        var outcome = Outcome.failed
        do {
            let answer = try await fetch()
            guard asked == generation else { return .failed }
            let before = count()
            _ = try take(answer)
            loaded = true
            let after = count()
            outcome = after > before ? .opened(after - before) : .unchanged
        } catch {
            guard asked == generation else { return .failed }
            print("[PreviousIdentityLoader] re-check failed: \(error)")
        }
        running = false
        if pending { scheduleForWindowEnd() }
        if case .opened = outcome { await onOpened() }
        return outcome
    }

    /// Adds `answer` to what is held and imports all of it.
    private func take(_ answer: [SealedPreviousIdentity]) throws -> Int {
        for blob in answer where held.count < Self.maxHeld && !held.contains(blob) {
            held.append(blob)
        }
        guard !held.isEmpty else { return 0 }
        return try importSealed(held)
    }

    /// One wait per window, however many triggers were refused in it.
    private func scheduleForWindowEnd() {
        guard !scheduled, let last = lastRecheckAt else { return }
        scheduled = true
        let asked = generation
        let wait = max(0, Self.window - now().timeIntervalSince(last))
        Task { @MainActor [self] in
            await sleepFor(wait)
            guard asked == generation else { return }
            scheduled = false
            if pending { await recheck() }
        }
    }
}
