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

/// The record of what this phone last sent each circle (`OwnLastSentStore`).
/// It holds a point, so it is this account's only, kept out of backups, and
/// gone with the circle and at every sign-out.
@MainActor
final class OwnLastSentStoreTests: XCTestCase {

    private let circle = "e0000000-0000-4000-8000-0000000000d1"
    private let other = "e0000000-0000-4000-8000-0000000000d2"
    private let me = "e0000000-0000-4000-8000-000000000012"
    private let someoneElse = "e0000000-0000-4000-8000-000000000013"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-last-sent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ nonce: String = "aa", version: Int32 = 1) -> OwnLastSent {
        OwnLastSent(
            sent: .live,
            envelope: EnvelopeEncryptedLocation(ciphertext: "bb", ciphertextNonce: nonce, timestamp: 1_727_600_000_000,
                                                keyWraps: [KeyWrap(targetId: circle, wrappedKeyNonce: "cc", wrappedKey: "dd")]),
            wrap: KeyWrap(targetId: circle, wrappedKeyNonce: "cc", wrappedKey: "dd"),
            point: Location(latitude: 52.5, longitude: 13.4, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                            timestamp: 1_727_600_000_000, batteryLevel: nil, isCharging: nil),
            coarsenedToMiles: nil, keyVersion: version, devicePseudonym: "dp")
    }

    func testARecordIsKeptPerAccountAndCircleAcrossALaunch() {
        let store = OwnLastSentStore(directory: directory)
        store.put(record("01"), circleId: circle, owner: me)
        store.put(record("02"), circleId: other.uppercased(), owner: me)
        let later = OwnLastSentStore(directory: directory)
        XCTAssertEqual(later.record(circleId: circle.uppercased(), owner: me)?.nonce, "01", "ids in their one form")
        XCTAssertEqual(later.record(circleId: other, owner: me)?.nonce, "02")
        XCTAssertEqual(Set(later.circles(owner: me)), [circle, other])
        XCTAssertNil(later.record(circleId: circle, owner: someoneElse), "another account's file is never read back")
        XCTAssertTrue(later.circles(owner: someoneElse).isEmpty)
        // And the next account's first send drops the last one's.
        later.put(record("03"), circleId: circle, owner: someoneElse)
        XCTAssertNil(OwnLastSentStore(directory: directory).record(circleId: other, owner: me))
    }

    func testASendReplacesTheRecordAndAReSealOnlyTheOneItRead() {
        let store = OwnLastSentStore(directory: directory)
        let first = record("01")
        store.put(first.tried(2), circleId: circle, owner: me)
        store.put(first, circleId: circle, owner: me)
        XCTAssertNil(store.record(circleId: circle, owner: me)?.triedVersion, "a new row is untried")
        store.update(circleId: circle, owner: me, from: first, to: record("02", version: 2))
        XCTAssertEqual(store.record(circleId: circle, owner: me)?.nonce, "02")
        store.update(circleId: circle, owner: me, from: first, to: record("03", version: 3))
        XCTAssertEqual(store.record(circleId: circle, owner: me)?.nonce, "02", "not the record that run read")
    }

    func testItGoesWithTheCircleAndAtSignOut() throws {
        let store = OwnLastSentStore(directory: directory)
        store.put(record("01"), circleId: circle, owner: me)
        store.put(record("02"), circleId: other, owner: me)
        OwnLastSentStore(directory: directory).forget(circleId: circle.uppercased())
        let later = OwnLastSentStore(directory: directory)
        XCTAssertNil(later.record(circleId: circle, owner: me))
        XCTAssertEqual(later.record(circleId: other, owner: me)?.nonce, "02")
        later.wipeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(later.fileURL).path))
        XCTAssertNil(later.record(circleId: other, owner: me))
        XCTAssertNil(OwnLastSentStore(directory: directory).record(circleId: other, owner: me))
    }

    /// In Application Support, protected until first unlock and kept out of
    /// backups: a plaintext point never reaches iCloud or a Finder backup,
    /// nor another device by a restore.
    func testTheFileIsProtectedAndNotBackedUp() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        XCTAssertEqual(OwnLastSentStore().fileURL?.deletingLastPathComponent().standardizedFileURL.path,
                       support.standardizedFileURL.path)
        let store = OwnLastSentStore(directory: directory)
        store.put(record(), circleId: circle, owner: me)
        let file = try XCTUnwrap(store.fileURL)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/Services/OwnLastSentStore.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains(
            "try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])"))
        XCTAssertTrue(source.contains("values.isExcludedFromBackup = true"))
    }
}
