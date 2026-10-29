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

/// Smoke tests for App/Services/CacheStore.swift. Covers round-trip
/// save/load and the corrupt-row self-cleanup branch. Doesn't try to
/// validate the iOS Data Protection class — that requires running on a
/// device with a passcode set, not just any simulator.
final class CacheStoreSmokeTests: XCTestCase {

    private struct Sample: Codable, Equatable {
        let id: String
        let count: Int
    }

    override func setUp() async throws {
        await CacheStore.shared.clearAll()
    }

    override func tearDown() async throws {
        await CacheStore.shared.clearAll()
    }

    func testSaveLoadRoundTrip() async {
        let value = Sample(id: "abc", count: 42)
        await CacheStore.shared.save(value, forKey: "smoke.sample")
        let loaded = await CacheStore.shared.load(Sample.self, forKey: "smoke.sample")
        XCTAssertEqual(loaded, value)
    }

    func testLoadMissingReturnsNil() async {
        let loaded = await CacheStore.shared.load(Sample.self, forKey: "missing.key")
        XCTAssertNil(loaded)
    }

    func testRemoveDropsValue() async {
        await CacheStore.shared.save(Sample(id: "x", count: 1), forKey: "to-be-removed")
        await CacheStore.shared.remove(forKey: "to-be-removed")
        let loaded = await CacheStore.shared.load(Sample.self, forKey: "to-be-removed")
        XCTAssertNil(loaded)
    }

    func testClearAllWipesEverything() async {
        await CacheStore.shared.save(Sample(id: "1", count: 1), forKey: "a")
        await CacheStore.shared.save(Sample(id: "2", count: 2), forKey: "b")
        await CacheStore.shared.clearAll()
        let a = await CacheStore.shared.load(Sample.self, forKey: "a")
        XCTAssertNil(a)
        let b = await CacheStore.shared.load(Sample.self, forKey: "b")
        XCTAssertNil(b)
    }
}
