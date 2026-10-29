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

/// MainTabView's refresh loop must run in the FOREGROUND only.
///
/// WHY THIS IS WORTH TESTING
///   iOS does not suspend the loop in the background: `.task` is cancelled
///   when the view goes away, the root tab view never goes away on
///   backgrounding, and this app is never suspended in the background because
///   LocationService keeps a location request running. Without the gate the
///   loop polls all night: a /locations/latest GET every tick, plus the
///   circles, members and privacy GETs of each tick.
///
///   Source assertion, like LocationTargetingTests: what can break is the
///   `id:` being dropped from `.task`, or the guard from its body, and a view
///   cannot be driven through a scene-phase change from a unit test.
final class ForegroundPollGateTests: XCTestCase {
    private var source: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("App/Views/MainTabView.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read MainTabView.swift at \(path.path)")
            return ""
        }
        return text
    }

    func testTheRefreshLoopIsKeyedOnTheScenePhase() throws {
        let src = source
        let loop = try XCTUnwrap(
            src.range(of: "Task.sleep(\n                    nanoseconds: UInt64(ForegroundRefreshCadence.locationsInterval * 1_000_000_000))"),
            "the foreground refresh loop is gone — retire this test with it")
        let before = String(src[..<loop.lowerBound])
        // The nearest `.task(` above the loop must carry the scene-phase id.
        let task = try XCTUnwrap(before.range(of: ".task(", options: .backwards), "no .task modifier above the loop")
        let opener = String(before[task.lowerBound...])
        XCTAssertTrue(
            opener.hasPrefix(".task(id: scenePhase == .active)"),
            "the loop's task must restart on every foreground/background edge, got: \(opener.prefix(60))")
        XCTAssertTrue(
            opener.contains("guard scenePhase == .active else { return }"),
            "a task started while backgrounded must return at once")
        XCTAssertTrue(
            src.contains("@Environment(\\.scenePhase) private var scenePhase"),
            "scenePhase must be read as a view property so the task id changes with it")
    }
}
