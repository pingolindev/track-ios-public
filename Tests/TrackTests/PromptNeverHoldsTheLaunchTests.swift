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

/// The launch never waits on the notification prompt.
///
/// WHY THIS IS WORTH TESTING
///   `requestAuthorization()` returns only once the person answers, and the
///   splash clears only when the launch's session check ends
///   (`isCheckingSession`, in its `defer`). A check that awaited the prompt
///   would leave a returning user who had never answered on the splash, with
///   no map, no location stream and no tracking, until they did; the App Store
///   report and the geocoder's manifest would wait behind the app's own ask
///   too.
@MainActor
final class PromptNeverHoldsTheLaunchTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// The session check's start-up asks without waiting for the answer, so
    /// the check completes, and the splash goes, with the prompt unanswered.
    func testTheSessionCheckCompletesWithThePromptUnanswered() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let launch = try body(auth, from: "    func checkExistingSession() async {", to: "    /// Everything of Track's a restored session starts")
        XCTAssertTrue(launch.contains("        await startTrackServices(me: me, since: epoch)\n"),
                      "the launch's start-up, the one that prompts (in completeLaunch, after the launch's read or its read again)")
        let start = try body(auth, from: "    private func startTrackServices(", to: "    /// Mirrors the Android app's SessionExpiredException gate.")
        XCTAssertTrue(start.contains("            Task { await PushNotificationManager.shared.requestAuthorization() }\n"))
        XCTAssertFalse(start.contains("            await PushNotificationManager.shared.requestAuthorization()\n"), "never awaited")
        XCTAssertFalse(launch.contains("requestAuthorization()"), "nor anywhere in the check itself")
    }

    /// The app's own ask after the check holds nothing back either: the App
    /// Store report and the geocoder go ahead.
    func testTheAppStoreReportAndTheGeocoderDoNotWaitForTheAnswer() throws {
        let app = try source("App/TrackApp.swift")
        let ask = try XCTUnwrap(app.range(of: "                Task { await pushManager.requestAuthorization() }\n"))
        let restore = try XCTUnwrap(app.range(of: "                await StoreKitManager.shared.restore()\n"))
        let geocoder = try XCTUnwrap(app.range(of: "            await GeocodingService.shared.bootstrap()\n"))
        XCTAssertLessThan(ask.lowerBound, restore.lowerBound)
        XCTAssertLessThan(restore.lowerBound, geocoder.lowerBound)
        XCTAssertFalse(app.contains("                await pushManager.requestAuthorization()\n"), "never awaited")
    }

    /// The token still follows the answer: iOS is asked for it once the person
    /// has answered, whatever they answered (the location ingest needs it).
    func testTheTokenStillFollowsTheAnswer() throws {
        let push = try source("App/Managers/PushNotificationManager.swift")
        let ask = try body(push, from: "    func requestAuthorization() async {", to: "    func requestDeviceToken() {")
        let answered = try XCTUnwrap(ask.range(of: "_ = try await center.requestAuthorization(options: [.alert, .badge, .sound])"))
        let token = try XCTUnwrap(ask.range(of: "        askForToken()\n"))
        XCTAssertLessThan(answered.lowerBound, token.lowerBound)
    }
}
