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

/// Behaviour of the member-tap address lookup, the counterpart to the Android
/// app's `MapViewModel.resolveMemberAddress`.
///
/// There is no background sweep and no setting: a tap is the only thing that
/// geocodes a member's position, on every platform. What is tested here is the
/// caching contract, which is what keeps a tap cheap and keeps one member's
/// address off another's sheet.
///
/// WHY THIS IS WORTH TESTING
///   - The ~1 m key rounding is the difference between one geocode per member
///     and one per GPS sample: a stationary phone reports a fix that wanders a
///     few metres, and keying on the raw double bills a lookup for every one.
///   - A lookup that found nothing must not be remembered as an answer, or a
///     member who was offline once stays addressless while they stand still.
///   - The key carries the user id, so two members on one doorstep keep
///     separate entries.
final class MemberAddressStoreTests: XCTestCase {

    /// Counts calls so an assertion can prove the geocoder was reached exactly
    /// once, not merely that something was stored.
    private final class Recorder {
        var calls: [(Double, Double)] = []
        /// Coordinates to answer with nil, simulating "no address found here".
        var failing: Set<String> = []
        func key(_ lat: Double, _ lng: Double) -> String { "\(lat),\(lng)" }
    }

    @MainActor
    private func makeStore(recorder: Recorder) -> MemberAddressStore {
        MemberAddressStore { lat, lng in
            recorder.calls.append((lat, lng))
            if recorder.failing.contains(recorder.key(lat, lng)) { return nil }
            return "\(lat)/\(lng) Main Street"
        }
    }

    // MARK: - The tap

    @MainActor
    func testResolveReturnsAndCachesAnAddress() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        let resolved = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)

        XCTAssertEqual(resolved, "37.63909/-120.99688 Main Street")
        XCTAssertEqual(
            store.address(userId: "alice", latitude: 37.63909, longitude: -120.99688),
            "37.63909/-120.99688 Main Street")
        XCTAssertEqual(rec.calls.count, 1)
    }

    /// Nothing resolves an address on its own. Constructing the store and
    /// handing it members must not reach the geocoder — only `resolve` does,
    /// and only when something calls it.
    @MainActor
    func testNothingIsGeocodedWithoutAResolve() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        XCTAssertTrue(rec.calls.isEmpty, "no lookup may happen without an explicit resolve")
        XCTAssertTrue(store.addresses.isEmpty)
        XCTAssertNil(store.address(userId: "alice", latitude: 37.63909, longitude: -120.99688))
    }

    // MARK: - Caching

    /// ~1 m rounding. 37.639090 and 37.639094 are 0.4 m apart — the same doorway
    /// — and must share one cache entry rather than billing a second lookup.
    @MainActor
    func testJitterWithinAMetreReusesOneEntry() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        _ = await store.resolve(userId: "alice", latitude: 37.639090, longitude: -120.996880)
        _ = await store.resolve(userId: "alice", latitude: 37.639094, longitude: -120.996883)

        XCTAssertEqual(rec.calls.count, 1, "a sub-metre drift must not re-geocode")
        XCTAssertEqual(store.addresses.count, 1)
    }

    /// A real move DOES get its own entry — the counterpart to the test above,
    /// which would otherwise pass just as well if the key ignored coordinates.
    @MainActor
    func testARealMoveGetsItsOwnEntry() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)
        _ = await store.resolve(userId: "alice", latitude: 37.64512, longitude: -120.99688)

        XCTAssertEqual(rec.calls.count, 2)
        XCTAssertEqual(store.addresses.count, 2)
    }

    /// Two members standing on the same spot are two entries: the key carries
    /// the user id, so one member's address can never render on another's sheet.
    @MainActor
    func testTheKeyIsPerMemberNotPerCoordinate() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)
        _ = await store.resolve(userId: "bob", latitude: 37.63909, longitude: -120.99688)

        XCTAssertEqual(store.addresses.count, 2)
        XCTAssertNotNil(store.address(userId: "alice", latitude: 37.63909, longitude: -120.99688))
        XCTAssertNotNil(store.address(userId: "bob", latitude: 37.63909, longitude: -120.99688))
    }

    /// Re-opening the same member's sheet paints from cache. This is what makes
    /// the tap-only design cheap: the second look costs nothing.
    @MainActor
    func testCachedAddressIsNotLookedUpTwice() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)
        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)

        XCTAssertEqual(rec.calls.count, 1)
    }

    // MARK: - Failure isolation

    /// One unresolvable member must not poison the next tap. Ordered so the
    /// failure comes FIRST — a store that gave up on error would leave every
    /// member tapped afterwards permanently addressless.
    @MainActor
    func testOneFailureDoesNotAffectTheNextMember() async {
        let rec = Recorder()
        rec.failing = ["37.63909,-120.99688"]
        let store = makeStore(recorder: rec)

        let alice = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)
        let bob = await store.resolve(userId: "bob", latitude: 37.65001, longitude: -121.00002)
        let carol = await store.resolve(userId: "carol", latitude: 37.66123, longitude: -121.01234)

        XCTAssertNil(alice)
        XCTAssertNotNil(bob)
        XCTAssertNotNil(carol)
        XCTAssertEqual(rec.calls.count, 3, "every tap must have reached the geocoder")
    }

    /// An empty answer is not cached — otherwise a lookup that failed once
    /// (offline, tile not yet downloaded) would be remembered as "no address
    /// here" for as long as the member stands still.
    @MainActor
    func testAFailedLookupIsNotCachedAsAnAnswer() async {
        let rec = Recorder()
        rec.failing = ["37.63909,-120.99688"]
        let store = makeStore(recorder: rec)

        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)
        rec.failing = []
        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)

        XCTAssertEqual(
            store.address(userId: "alice", latitude: 37.63909, longitude: -120.99688),
            "37.63909/-120.99688 Main Street",
            "the retry should have been allowed to succeed")
        XCTAssertEqual(rec.calls.count, 2)
    }

    // MARK: - Account hygiene

    /// Logout drops the cache: these are decrypted street addresses keyed by
    /// user id, so account B must not inherit where account A's circle stood.
    @MainActor
    func testResetClearsResolvedAddresses() async {
        let rec = Recorder()
        let store = makeStore(recorder: rec)

        _ = await store.resolve(userId: "alice", latitude: 37.63909, longitude: -120.99688)
        XCTAssertFalse(store.addresses.isEmpty)

        store.reset()

        XCTAssertTrue(store.addresses.isEmpty)
        XCTAssertNil(store.address(userId: "alice", latitude: 37.63909, longitude: -120.99688))
    }

    // MARK: - Key shape

    /// Pinned against the Android app's `"${userId}-${"%.5f"}-${"%.5f"}"` and
    /// the web client's
    /// `` `${member.id}-${lat.toFixed(5)}-${lng.toFixed(5)}` ``. The three
    /// platforms are only comparable while the key means the same thing.
    func testCacheKeyMatchesTheAndroidAndWebShape() {
        XCTAssertEqual(
            MemberAddressStore.cacheKey(userId: "alice", latitude: 37.63909, longitude: -120.99688),
            "alice-37.63909--120.99688")
        // Rounding, not truncation — and negative longitudes round the same way.
        XCTAssertEqual(
            MemberAddressStore.cacheKey(userId: "u", latitude: 1.0000049, longitude: -1.0000049),
            "u-1.00000--1.00000")
        XCTAssertEqual(
            MemberAddressStore.cacheKey(userId: "u", latitude: 1.0000051, longitude: -1.0000051),
            "u-1.00001--1.00001")
    }
}
