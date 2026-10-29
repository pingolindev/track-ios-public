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

/// What happens to the anonymous credits when spends overlap or their
/// caller goes away. GeocodeSpendLoopTests pins the loop's rules per reply;
/// these pin what is around it, with integers for credits.
///
/// The actor runs one call at a time but interleaves them at every await, and
/// every spend awaits the network. Two searches reading the same pool could
/// present the same last credit (one meeting a 409) and each write its own
/// copy back: the later write would return a credit the other had consumed, or
/// drop ones it had never presented. And the next keystroke's cancellation
/// must not reach a redemption already on the wire, or it keeps a credit the
/// server has taken.
final class GeocodeSpendConcurrencyTests: XCTestCase {
    private typealias M = GeocodeTokenManager

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// An in-memory pool a manager of the test's own spends from.
    private final class MemoryPool: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [M.StoredToken]
        init(_ tokens: [M.StoredToken]) { stored = tokens }
        var tokens: [M.StoredToken] {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// The credits presented to the fake gateway, in order.
    private actor Presented {
        private(set) var nonces: [String] = []
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func add(_ nonce: String) {
            nonces.append(nonce)
            let ready = waiters.filter { nonces.count >= $0.0 }
            waiters.removeAll { nonces.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
        func waitFor(_ count: Int) async {
            if nonces.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
    }

    /// THE REENTRANCY, ON A REAL MANAGER. Two spends are held at the network
    /// await at the same time, then both answered. They present different
    /// credits rather than both presenting the last one, and the pool ends
    /// without both of them and with everything else.
    func testTwoSpendsHeldAtTheNetworkAwaitPresentDifferentCreditsAndKeepTheRest() async {
        let pool = MemoryPool((1...12).map { M.StoredToken(n: "n\($0)", w: "w\($0)") })
        let manager = M(store: .init(pinnedKeyId: { "key-1" }, load: { pool.tokens }, save: { pool.tokens = $0 }))
        let gate = SearchGate()
        let presented = Presented()
        let send: (GeocodeRedeemToken, String) async throws -> (data: Data, status: Int) = { token, _ in
            await presented.add(token.nonceB64)
            await gate.wait()
            return (Data("{}".utf8), 200)
        }
        async let first = manager.spend(send)
        async let second = manager.spend(send)
        await presented.waitFor(2)
        await gate.open()
        let answers = await [first, second]

        XCTAssertEqual(answers.compactMap { $0 }.count, 2, "both were answered")
        let both = await presented.nonces
        XCTAssertEqual(Set(both).count, 2, "the second spend presented a credit the first held: \(both)")
        XCTAssertEqual(pool.tokens.count, 10, "two consumed, nothing put back, nothing dropped")
        XCTAssertTrue(Set(both).isDisjoint(with: pool.tokens.map(\.n)), "both consumed credits are gone")

        // Each gave back what it held and did not use: the first held
        // n9...n12 and used n12, so a third spend presents n11. Held for good,
        // four credits a spend would be stranded, and server search would fall
        // back to the tiles after a few searches, until the app restarted.
        let third = await manager.spend { token, _ in
            await presented.add(token.nonceB64)
            return (Data("{}".utf8), 200)
        }
        XCTAssertNotNil(third)
        let last = await presented.nonces.last
        XCTAssertEqual(last, "n11", "a finished spend gives back the credits it held")
    }

    /// The gateway saw the first query's nonce with a 502. The next query must
    /// go out with another one, or the two could be linked: the 502's credit
    /// is gone from the pool.
    func testAfterA502TheNextQueryPresentsADifferentNonce() async {
        let pool = MemoryPool((1...12).map { M.StoredToken(n: "n\($0)", w: "w\($0)") })
        let manager = M(store: .init(pinnedKeyId: { "key-1" }, load: { pool.tokens }, save: { pool.tokens = $0 }))
        let presented = Presented()
        let failed = await manager.spend { token, _ in
            await presented.add(token.nonceB64)
            return (Data(), 502)
        }
        let answered = await manager.spend { token, _ in
            await presented.add(token.nonceB64)
            return (Data("{}".utf8), 200)
        }
        XCTAssertNil(failed, "a 502 is no answer: the search uses the tiles")
        XCTAssertNotNil(answered)
        let nonces = await presented.nonces
        XCTAssertEqual(nonces.count, 2)
        XCTAssertNotEqual(nonces.first, nonces.last, "one nonce under two queries")
        XCTAssertFalse(pool.tokens.map(\.n).contains(nonces.first ?? ""), "the 502's credit is dropped for good")
    }

    /// A thread-safe value a test's store and its fake gateway share.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// A 401 says the key this spend presented under is stale. While it was on
    /// the wire another spend may have re-pinned and minted under the current
    /// key; that pin and batch are not this 401's to wipe.
    func testARejectedKeyWipesOnlyThePinItPresentedUnder() async {
        let pin = Box<String?>("key-1")
        let pool = MemoryPool((1...12).map { M.StoredToken(n: "n\($0)", w: "w\($0)") })
        let wipes = Box(0)
        let manager = M(store: .init(pinnedKeyId: { pin.value }, load: { pool.tokens }, save: { pool.tokens = $0 },
                                     clear: { wipes.value += 1; pin.value = nil; pool.tokens = [] }))
        let gate = SearchGate()
        let held: (GeocodeRedeemToken, String) async throws -> (data: Data, status: Int) = { _, _ in
            await gate.wait()
            return (Data(), 401)
        }
        async let rejected = manager.spend(held)
        await gate.somethingWaits()
        // Another spend's legitimate rotation lands meanwhile: a new pin, a new batch.
        pin.value = "key-2"
        pool.tokens = (13...24).map { M.StoredToken(n: "n\($0)", w: "w\($0)") }
        await gate.open()
        let answer = await rejected
        XCTAssertNil(answer, "a 401 is no answer: the search uses the tiles")
        XCTAssertEqual(wipes.value, 0, "the new pin and batch stay")
        XCTAssertEqual(pin.value, "key-2")
        XCTAssertEqual(pool.tokens.count, 12)

        // The control: a 401 under the pin still current wipes it.
        let now = await manager.spend { _, _ in (Data(), 401) }
        XCTAssertNil(now)
        XCTAssertEqual(wipes.value, 1)
        XCTAssertNil(pin.value)
    }

    func testASpendNeverPresentsACreditAnotherSpendHolds() {
        let pool = Array(1...10)
        XCTAssertEqual(M.available(pool, presenting: Set<Int>(), by: { $0 }), pool)
        // The first spend holds the last four, the most its loop presents.
        let first = Set(pool.suffix(4))
        let second = M.available(pool, presenting: first, by: { $0 })
        XCTAssertEqual(second, Array(1...6))
        XCTAssertTrue(Set(second.suffix(4)).isDisjoint(with: first), "the two present different credits")
    }

    /// Two spends overlap. Each removes what IT used, from the pool as it is when
    /// it finishes, and nothing else.
    func testOverlappingSpendsEachTakeOutOnlyWhatTheyUsed() {
        let pool = Array(1...10)
        // First: holds 7...10; its credit 10 is answered.
        // Second: holds 3...6; 6 comes back already spent, 5 is answered.
        let firstBefore = pool, firstAfter = Array(1...9)
        let secondBefore = Array(1...6), secondAfter = Array(1...4)

        let afterFirst = M.afterSpend(pool, before: firstBefore, after: firstAfter, by: { $0 })
        let thenSecond = M.afterSpend(afterFirst, before: secondBefore, after: secondAfter, by: { $0 })
        XCTAssertEqual(thenSecond, [1, 2, 3, 4, 7, 8, 9])

        let afterSecond = M.afterSpend(pool, before: secondBefore, after: secondAfter, by: { $0 })
        let thenFirst = M.afterSpend(afterSecond, before: firstBefore, after: firstAfter, by: { $0 })
        XCTAssertEqual(thenFirst, [1, 2, 3, 4, 7, 8, 9], "the same pool, whichever finishes first")
    }

    func testASpendThatUsedNothingChangesNothing() {
        let current = [1, 2, 3, 11, 12]   // a refill landed meanwhile
        XCTAssertEqual(M.afterSpend(current, before: [1, 2, 3], after: [1, 2, 3], by: { $0 }), current,
                       "an unanswered redemption keeps its credit, and a spend never adds one back")
        XCTAssertEqual(M.afterSpend([], before: [1, 2, 3], after: [1, 2], by: { $0 }), [],
                       "after a wipe (a rotated key), nothing comes back")
    }

    /// The caller of a spend is cancelled while its redemption is on the wire,
    /// as a search is by the next keystroke. The redemption must not see it: a
    /// real request would throw, and the credit the server took would be kept.
    func testACancelledCallerDoesNotReachTheRedemption() async {
        let gate = SearchGate()
        let caller = Task { () -> Bool in
            await M.shielded { () -> Bool in
                await gate.wait()
                return Task.isCancelled
            }
        }
        await gate.somethingWaits()
        caller.cancel()
        await gate.open()
        let redemptionSawTheCancel = await caller.value
        XCTAssertFalse(redemptionSawTheCancel)
    }

    /// Every spend, reverse lookups and the refill inside it included, goes
    /// through the shield, and a low pool is topped up once however many spends
    /// find it low.
    func testEverySpendGoesThroughTheShieldAndOneRefill() throws {
        let text = try source("App/Services/GeocodeTokenManager.swift")
        XCTAssertTrue(text.contains("await Self.shielded { await self.spendToTheEnd(send) }"))
        XCTAssertTrue(text.contains("_ = await refillOnce()"))
        XCTAssertFalse(text.contains("_ = await refill()"), "a refill outside refillOnce mints twice")
        XCTAssertTrue(text.contains("if let refilling { return await refilling.value }"))
        XCTAssertTrue(text.contains("savePool(Self.afterSpend(loadPool(), before: before, after: mine, by: \\.n))"))
        XCTAssertFalse(text.contains("savePool(pool)                     // persist consumed/spent removals"),
                       "no whole-copy write")
    }
}
