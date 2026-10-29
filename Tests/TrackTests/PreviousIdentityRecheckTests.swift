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
import PingolinTrackSDK
@testable import Track

/// An identity restored in the account portal while the app runs opens
/// without a restart. Five numbered cases, plus the union, the window,
/// the pending re-check and the sign-out reset.
@MainActor
final class PreviousIdentityRecheckTests: XCTestCase {

    /// The server, the SDK and the clock, played by the test. Like the SDK, an
    /// import REPLACES the set held — `*self.previous_private_keys.write()
    /// .unwrap_or_else(|e| e.into_inner()) = opened;` (mobile-sdk crypto.rs) — and
    /// opens only the blobs sealed for this device.
    @MainActor
    final class World {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        /// The server's next answers; the last one repeats.
        var answers: [[SealedPreviousIdentity]] = [[]]
        var failNextFetch = false
        var holdFetches = false
        private(set) var fetchedAt: [Date] = []
        private var heldFetches: [CheckedContinuation<Void, Never>] = []
        var sealedForThisDevice: Set<SealedPreviousIdentity> = []
        /// A v2 blob and the v1 blob of the same identity (`sameIdentity`,
        /// v2 → v1), and which blobs carry the identity's signing key.
        var sameIdentity: [SealedPreviousIdentity: SealedPreviousIdentity] = [:]
        var withSigning: Set<SealedPreviousIdentity> = []
        /// The identities the SDK holds, and those it holds a signing key for.
        private(set) var sdk: Set<SealedPreviousIdentity> = []
        private(set) var signing: Set<SealedPreviousIdentity> = []
        private(set) var imports: [[SealedPreviousIdentity]] = []
        private(set) var reloads = 0
        /// Every wait asked for, in seconds.
        private(set) var waits: [TimeInterval] = []
        private var sleepers: [(until: Date, resume: CheckedContinuation<Void, Never>)] = []

        func loader() -> PreviousIdentityLoader {
            PreviousIdentityLoader(
                fetch: { try await self.fetch() },
                importSealed: { self.importSealed($0) },
                count: { self.sdk.count + self.signing.count },
                now: { self.clock },
                sleepFor: { await self.sleep($0) },
                onOpened: { self.reloads += 1 })
        }

        private func fetch() async throws -> [SealedPreviousIdentity] {
            fetchedAt.append(clock)
            if holdFetches { await withCheckedContinuation { heldFetches.append($0) } }
            if failNextFetch {
                failNextFetch = false
                throw URLError(.notConnectedToInternet)
            }
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }

        func releaseFetches() {
            holdFetches = false
            let held = heldFetches
            heldFetches = []
            held.forEach { $0.resume() }
        }

        private func importSealed(_ blobs: [SealedPreviousIdentity]) -> Int {
            imports.append(blobs)
            let opened = blobs.filter { sealedForThisDevice.contains($0) }
            sdk = Set(opened.map { sameIdentity[$0] ?? $0 })
            signing = Set(opened.filter { withSigning.contains($0) }.map { sameIdentity[$0] ?? $0 })
            return sdk.count
        }

        private func sleep(_ seconds: TimeInterval) async {
            waits.append(seconds)
            let until = clock.addingTimeInterval(seconds)
            await withCheckedContinuation { sleepers.append((until, $0)) }
        }

        /// Lets what is queued start its waits, moves the clock on, and ends
        /// every wait that is over by then.
        func elapse(_ seconds: TimeInterval) async {
            await PreviousIdentityRecheckTests.settle()
            clock += seconds
            let due = sleepers.filter { $0.until <= clock }
            sleepers.removeAll { $0.until <= clock }
            due.forEach { $0.resume.resume() }
            await PreviousIdentityRecheckTests.settle()
        }
    }

    /// Lets every task the main actor has queued run to its next real wait.
    static func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    private static func blob(_ n: Int) -> SealedPreviousIdentity {
        SealedPreviousIdentity(nonce: "nonce-\(n)", ciphertext: "ciphertext-\(n)")
    }

    // MARK: - The five cases

    /// 1. Many nudges inside the window → exactly one request, when the window ends.
    func testManyNudgesInsideTheWindowAskOnceWhenItEnds() async {
        let world = World()
        let loader = world.loader()
        let start = world.clock
        let first = await loader.recheck()
        XCTAssertEqual(first, .unchanged)
        XCTAssertEqual(world.fetchedAt, [start])

        await world.elapse(10)
        for _ in 0..<20 {
            let outcome = await loader.recheck()
            XCTAssertEqual(outcome, .deferred)
            await world.elapse(5)
        }
        XCTAssertEqual(world.fetchedAt.count, 1, "nothing asked inside the window")
        XCTAssertEqual(world.waits, [170], "one wait, for the rest of the window")
        XCTAssertTrue(loader.pending)

        await world.elapse(start.addingTimeInterval(179).timeIntervalSince(world.clock))
        XCTAssertEqual(world.fetchedAt.count, 1)
        await world.elapse(1)
        XCTAssertEqual(world.fetchedAt, [start, start.addingTimeInterval(180)], "one request, when the window ends")
        XCTAssertFalse(loader.pending)

        await world.elapse(3_600)
        XCTAssertEqual(world.fetchedAt.count, 2, "and nothing after it")
        XCTAssertEqual(world.waits, [170])
    }

    /// 2. A nudge during a running re-check → exactly one follow-up, and that one
    /// is the next window's.
    func testANudgeDuringARunningRecheckGetsExactlyOneFollowUp() async {
        let world = World()
        let loader = world.loader()
        let start = world.clock
        world.holdFetches = true
        let running = Task { await loader.recheck() }
        await Self.settle()
        XCTAssertEqual(world.fetchedAt.count, 1)

        for _ in 0..<5 {
            let outcome = await loader.recheck()
            XCTAssertEqual(outcome, .deferred)
        }
        XCTAssertEqual(world.fetchedAt.count, 1, "no second request while one runs")
        XCTAssertEqual(world.waits, [], "the running one arranges the follow-up when it ends")

        await world.elapse(2)
        world.releaseFetches()
        let outcome = await running.value
        XCTAssertEqual(outcome, .unchanged)
        await Self.settle()
        XCTAssertEqual(world.waits, [178])

        await world.elapse(178)
        XCTAssertEqual(world.fetchedAt, [start, start.addingTimeInterval(180)], "exactly one follow-up")
        await world.elapse(3_600)
        XCTAssertEqual(world.fetchedAt.count, 2)
    }

    /// 3. An empty answer after a good one → the count is unchanged (the union),
    /// and nothing is loaded again. A lying answer changes nothing either.
    func testAnEmptyAnswerAfterAGoodOneKeepsTheCount() async {
        let world = World()
        let a = Self.blob(1), junk = Self.blob(2), b = Self.blob(3)
        world.sealedForThisDevice = [a, b]
        world.answers = [[a], [], [junk], [b]]
        let loader = world.loader()

        let atStart = await loader.ensureLoaded()
        XCTAssertEqual(atStart, 1)
        XCTAssertEqual(world.sdk, [a])

        // The first load is not counted: a nudge right after it asks at once.
        let empty = await loader.recheck()
        XCTAssertEqual(empty, .unchanged)
        XCTAssertEqual(world.fetchedAt.count, 2)
        XCTAssertEqual(world.imports.last, [a], "the empty answer imports what is held")
        XCTAssertEqual(world.sdk, [a], "the count is unchanged")

        await world.elapse(180)
        let lying = await loader.recheck()
        XCTAssertEqual(lying, .unchanged)
        XCTAssertEqual(world.sdk, [a])
        XCTAssertEqual(world.reloads, 0, "nothing new opened, nothing loaded again")

        await world.elapse(180)
        let restored = await loader.recheck()
        XCTAssertEqual(restored, .opened(1))
        XCTAssertEqual(world.imports.last, [a, junk, b], "everything given since sign-in, first seen first")
        XCTAssertEqual(world.sdk, [a, b])
        XCTAssertEqual(world.reloads, 1, "the circles load again once")

        // A later full load asks nothing more.
        let again = await loader.ensureLoaded()
        XCTAssertEqual(again, 2)
        XCTAssertEqual(world.fetchedAt.count, 4)
    }

    /// 4. Sign-out clears everything: what is held, the window, the pending
    /// re-check and its wait, and a request still in flight.
    func testSignOutClearsEverything() async throws {
        let world = World()
        let a = Self.blob(1), b = Self.blob(2)
        world.sealedForThisDevice = [a, b]
        world.answers = [[a]]
        let loader = world.loader()
        _ = await loader.recheck()
        await world.elapse(30)
        _ = await loader.recheck()
        await Self.settle()
        XCTAssertTrue(loader.pending)
        XCTAssertEqual(loader.held, [a])
        XCTAssertEqual(world.waits, [150])

        loader.reset()
        XCTAssertEqual(loader.held, [])
        XCTAssertFalse(loader.pending)
        await world.elapse(150)
        XCTAssertEqual(world.fetchedAt.count, 1, "the wait begun before sign-out does nothing")

        // The next sign-in starts afresh: its first load asks, nothing from
        // before the sign-out goes into the import, and a nudge asks at once.
        world.answers = [[b]]
        let count = await loader.ensureLoaded()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(world.fetchedAt.count, 2, "the first load of the next sign-in asks again")
        XCTAssertEqual(world.imports.last, [b], "nothing from before the sign-out is imported")
        let nudge = await loader.recheck()
        XCTAssertEqual(nudge, .unchanged)
        XCTAssertEqual(world.fetchedAt.count, 3, "no window carried over")

        // A request in flight at sign-out: its answer is dropped.
        await world.elapse(180)
        let reloads = world.reloads
        world.answers = [[a]]
        world.holdFetches = true
        let inFlight = Task { await loader.recheck() }
        await Self.settle()
        loader.reset()
        world.releaseFetches()
        let dropped = await inFlight.value
        XCTAssertEqual(dropped, .failed)
        XCTAssertEqual(loader.held, [])
        XCTAssertEqual(world.reloads, reloads)

        // The wiring: sign-out and an account switch both purge through
        // CircleManager.reset(), which resets the loader.
        let circles = try Self.source("App/Managers/CircleManager.swift")
        let reset = try XCTUnwrap(circles.range(of: "    func reset() {\n        circles = []"))
        XCTAssertTrue(circles[reset.upperBound...].prefix(2_000).contains("previousIdentityLoader.reset()"))
        let auth = try Self.source("App/Managers/AuthManager.swift")
        let purge = try XCTUnwrap(auth.range(of: "private func purgeAccountData() async {"))
        XCTAssertTrue(auth[purge.upperBound...].prefix(2_500).contains("CircleManager.shared.reset()"))
        XCTAssertTrue(auth.contains("func logout(retainingTrust: Bool = true) async {"))
        let prior = try XCTUnwrap(auth.range(of: "if let prior = priorUserId, CanonicalId.of(prior) != me {\n"))
        XCTAssertTrue(auth[prior.upperBound...].prefix(900).contains("            await purgeAccountData()\n            deleteOutgoingKeyMaterial()\n"))
    }

    /// The start-up load awaits the network too, so it checks the session
    /// again after the await. Signed out meanwhile: nothing is added, and the
    /// next sign-in's first load asks afresh.
    func testAStartUpLoadInFlightAtSignOutAddsNothing() async {
        let world = World()
        let a = Self.blob(1)
        world.sealedForThisDevice = [a]
        world.answers = [[a]]
        world.holdFetches = true
        let loader = world.loader()
        let loading = Task { await loader.ensureLoaded() }
        await Self.settle()
        XCTAssertEqual(world.fetchedAt.count, 1)

        loader.reset()
        world.releaseFetches()
        let opened = await loading.value
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(loader.held, [])
        XCTAssertEqual(world.imports.count, 0, "nothing imported into the session that followed")

        _ = await loader.ensureLoaded()
        XCTAssertEqual(world.fetchedAt.count, 2, "not taken as loaded: the next sign-in asks")
    }

    /// 5. Extra fields in the push make no difference: only the type is read,
    /// and the re-check takes nothing from the payload.
    func testExtraFieldsInThePushMakeNoDifference() throws {
        let bare: [AnyHashable: Any] = ["alert_type": "identities_check", "aps": ["content-available": 1]]
        let padded: [AnyHashable: Any] = [
            "alert_type": "identities_check", "aps": ["content-available": 1],
            "circle_id": "c1", "user_id": "u1", "identities": [["nonce": "n", "ciphertext": "c"]],
            "key_version": 7, "alert_id": "x",
        ]
        XCTAssertEqual(PushAppDelegate.pushKind(from: bare), "identities_check")
        XCTAssertEqual(PushAppDelegate.pushKind(from: padded), "identities_check")
        XCTAssertEqual(PushAppDelegate.pushKind(from: ["type": "identities_check", "alert_type": "tickle"]),
                       "identities_check")

        let push = try Self.source("App/Managers/PushNotificationManager.swift")
        let start = try XCTUnwrap(push.range(of: "        case \"identities_check\":\n"))
        let end = try XCTUnwrap(push.range(of: "        case \"wake_location\":", range: start.upperBound..<push.endIndex))
        let body = push[start.upperBound..<end.lowerBound]
        XCTAssertFalse(body.contains("userInfo"), "nothing but the type is read")
        XCTAssertTrue(body.contains("await CircleManager.shared.recheckPreviousIdentities()\n"))
        let circles = try Self.source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("func recheckPreviousIdentities() async {"), "it takes nothing")
    }

    // MARK: - An identity's signing key (v2)

    /// A v2 answer after a v1 one opens the identity's signing key: that loads
    /// the circles again (the account's own old wraps now open). A later answer
    /// with only v1 never drops the held v2 blob, so the key stays.
    func testASigningKeyGainedLoadsAgainAndIsNeverDropped() async {
        let world = World()
        let v1 = Self.blob(1)
        let v2 = SealedPreviousIdentity(nonce: "nonce-1-v2", ciphertext: "ciphertext-1-v2")
        world.sealedForThisDevice = [v1, v2]
        world.sameIdentity = [v2: v1]
        world.withSigning = [v2]
        world.answers = [[v1], [v2], [v1]]
        let loader = world.loader()

        _ = await loader.ensureLoaded()
        XCTAssertEqual(world.sdk, [v1])
        XCTAssertEqual(world.signing, [])

        let upgraded = await loader.recheck()
        XCTAssertEqual(upgraded, .opened(1), "the same identity, now with its signing key")
        XCTAssertEqual(world.signing, [v1])
        XCTAssertEqual(world.reloads, 1)

        await world.elapse(180)
        let v1Only = await loader.recheck()
        XCTAssertEqual(v1Only, .unchanged)
        XCTAssertEqual(world.imports.last, [v1, v2], "the held v2 goes into every import")
        XCTAssertEqual(world.signing, [v1], "the signing key stays")
        XCTAssertEqual(world.reloads, 1)
    }

    /// The wire: each entry's v2 blob when it has one, else v1, handed to the
    /// SDK's v2 import, which prefers v2 per identity.
    func testTheV2BlobIsPreferredAndImportedWithTheV2Call() throws {
        let both = Data(#"{"success":true,"data":{"identities":[{"key_version":1,"#
            .appending(#""app_sealed_private_key":{"nonce":"n1","ciphertext":"c1"},"#)
            .appending(#""app_sealed_private_key_v2":{"nonce":"n2","ciphertext":"c2"}},"#)
            .appending(#"{"key_version":2,"app_sealed_private_key":{"nonce":"n3","ciphertext":"c3"}},"#)
            .appending(#"{"key_version":3}]}}"#).utf8)
        let response: PreviousIdentitiesResponse = try APIService.decodeResponseBody(both)
        XCTAssertEqual(response.identities.map { $0.sealedForThisApp?.nonce }, ["n2", "n3", nil])
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loader = try String(contentsOf: root.appendingPathComponent("App/Services/PreviousIdentityLoader.swift"),
                                encoding: .utf8)
        XCTAssertTrue(loader.contains("row.sealedForThisApp.map { SealedPreviousIdentity(nonce: $0.nonce, ciphertext: $0.ciphertext) }"))
        XCTAssertTrue(loader.contains("importSealed: { Int(try cryptoManager.importPreviousIdentitiesV2(sealed: $0)) },"))
        XCTAssertFalse(loader.contains("importPreviousIdentities(sealed:"), "never the v1 call, which drops signing keys")
        XCTAssertTrue(loader.contains("count: { Int(cryptoManager.previousIdentityCount()) + cryptoManager.previousSigningPublicKeys().count },"))
    }

    // MARK: - The foreground, failures and the cap

    /// A return to the foreground looks while a circle is locked since a reset,
    /// runs a pending re-check once its window is over, and otherwise does
    /// nothing. It is under the same window.
    func testTheForegroundLooksOnlyWithCause() async throws {
        let world = World()
        let loader = world.loader()
        let start = world.clock
        let idle = await loader.foreground(locked: false)
        XCTAssertNil(idle)
        XCTAssertEqual(world.fetchedAt, [])

        let locked = await loader.foreground(locked: true)
        XCTAssertEqual(locked, .unchanged)
        await world.elapse(60)
        let soon = await loader.foreground(locked: true)
        XCTAssertEqual(soon, .deferred, "inside the window")
        XCTAssertEqual(world.fetchedAt.count, 1)
        await Self.settle()
        XCTAssertEqual(world.waits, [120])

        // The app is suspended through the window's end; its wait ends after
        // the foreground.
        world.clock = start.addingTimeInterval(400)
        let back = await loader.foreground(locked: false)
        XCTAssertEqual(back, .unchanged, "the pending re-check runs at the next foreground")
        XCTAssertEqual(world.fetchedAt, [start, start.addingTimeInterval(400)])
        await world.elapse(0)
        XCTAssertEqual(world.fetchedAt.count, 2, "the old wait finds nothing pending")
        let after = await loader.foreground(locked: false)
        XCTAssertNil(after)

        let wiring = try Self.source("App/Managers/CircleManager.swift")
        XCTAssertTrue(wiring.contains("await previousIdentityLoader.foreground(\n            locked: circles.contains { $0.lockReason == .sealedBeforeReset })"))
        let app = try Self.source("App/TrackApp.swift")
        XCTAssertTrue(app.contains("await CircleManager.shared.previousIdentitiesOnForeground()"))
    }

    /// A failed request is still a request: it takes the window, keeps nothing
    /// half-done, and the next re-check tries again.
    func testAFailedRequestCountsAndLeavesItForLater() async {
        let world = World()
        let a = Self.blob(1)
        world.sealedForThisDevice = [a]
        world.answers = [[a]]
        world.failNextFetch = true
        let loader = world.loader()
        let failed = await loader.recheck()
        XCTAssertEqual(failed, .failed)
        let soon = await loader.recheck()
        XCTAssertEqual(soon, .deferred)
        await world.elapse(180)
        XCTAssertEqual(world.fetchedAt.count, 2)
        XCTAssertEqual(world.sdk, [a])
        XCTAssertEqual(world.reloads, 1)
    }

    /// Junk can't grow what is held without bound.
    func testWhatIsHeldIsCapped() async {
        let world = World()
        world.answers = [(0..<40).map(Self.blob)]
        let loader = world.loader()
        _ = await loader.recheck()
        XCTAssertEqual(loader.held.count, PreviousIdentityLoader.maxHeld)
        XCTAssertEqual(loader.held.first, Self.blob(0))
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
