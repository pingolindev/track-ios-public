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

/// The app and its notification extension never both refresh from the same
/// stored token. Every refresh holds `AppGroupLock.refresh()` and reads the
/// stored pair again under it; a changed pair is the other process's refresh,
/// used as it is.
final class RefreshLockTests: XCTestCase {

    private func scratchLock() -> AppGroupLock {
        AppGroupLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("refresh-lock-\(UUID().uuidString)"))
    }

    /// One holder at a time — two opens of the file contend exactly as two
    /// processes do (`flock` locks belong to the open file, not the process).
    func testOneHolderAtATime() async throws {
        let lock = scratchLock()
        let firstHeld = await lock.acquire(timeout: 1)
        let first = try XCTUnwrap(firstHeld)
        let second = AppGroupLock(url: lock.url)
        let blocked = await second.acquire(timeout: 0.3)
        XCTAssertNil(blocked, "held elsewhere: not taken")
        first.release()
        let taken = await second.acquire(timeout: 1)
        XCTAssertNotNil(taken, "free again once released")
        taken?.release()
    }

    func testAChangedStoredTokenIsTheOtherProcessRefresh() {
        XCTAssertTrue(SessionRefresh.anotherProcessRefreshed(before: "r1", now: "r2"))
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: "r1", now: "r1"))
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: "r1", now: nil), "gone is not a refresh")
        XCTAssertFalse(SessionRefresh.anotherProcessRefreshed(before: nil, now: "none"))
    }

    /// The app's refresh takes the lock, reads the stored token again under it,
    /// and adopts a changed pair instead of refreshing (source).
    func testTheAppRefreshesOnlyHoldingTheLock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let api = try String(contentsOf: root.appendingPathComponent("App/Services/APIService.swift"), encoding: .utf8)
        let take = try XCTUnwrap(api.range(of: "let held = await lock?.acquire(timeout: AppGroupLock.appWait)"))
        let reread = try XCTUnwrap(api.range(of: "if SessionRefresh.anotherProcessRefreshed(before: refreshToken, now: keychain.getString(for: .refreshToken)),"))
        let network = try XCTUnwrap(api.range(of: "response = try await self.refreshToken(refreshToken: refreshToken)"))
        XCTAssertLessThan(take.lowerBound, reread.lowerBound)
        XCTAssertLessThan(reread.lowerBound, network.lowerBound, "the stored pair is read again before any refresh")
        XCTAssertTrue(api.contains("defer { held?.release() }"))
    }
}
