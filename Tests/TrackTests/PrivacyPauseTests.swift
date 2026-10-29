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

/// `PrivacySettings.isPaused` and the mode/timestamp pair it reads.
///
/// The server keeps posture in ONE field, `sharing_mode`, and re-admits a
/// paused member only when `sharing_mode` is "paused" and `paused_until` is set
/// and has passed. So `sharing_mode = "paused"` with no `paused_until` is a
/// pause with no end — the state the "pause until I turn it back on" case
/// produces on web and Android.
///
/// `isPaused` therefore reads the mode, not only `pausedUntil`. Read from the
/// timestamp alone, such a row would load as NOT paused, every send gate would
/// stream, and the next privacy save would re-derive the mode from the two
/// booleans and write back "exact" — un-pausing the user server-side as a side
/// effect of an unrelated edit.
final class PrivacyPauseTests: XCTestCase {

    private func settings(
        mode: String,
        pausedUntil: Date? = nil,
        bubbleEnabled: Bool = false
    ) -> PrivacySettings {
        PrivacySettings(
            circleId: "c1",
            sharingMode: mode,
            shareRealtime: true,
            shareHistory: true,
            shareBattery: true,
            bubbleEnabled: bubbleEnabled,
            bubbleRadius: 1,
            pausedUntil: pausedUntil,
            updatedAt: Date()
        )
    }

    private let future = Date().addingTimeInterval(3600)
    private let past = Date().addingTimeInterval(-3600)

    // MARK: - isPaused

    func testIndefinitePauseIsPaused() {
        XCTAssertTrue(settings(mode: "paused", pausedUntil: nil).isPaused,
                      "mode 'paused' with no expiry is paused until explicitly resumed")
    }

    func testPauseWithFutureExpiryIsPaused() {
        XCTAssertTrue(settings(mode: "paused", pausedUntil: future).isPaused)
    }

    func testPauseWithElapsedExpiryHasAutoResumed() {
        XCTAssertFalse(settings(mode: "paused", pausedUntil: past).isPaused,
                       "an elapsed pause auto-resumes — that is how the server has no un-pause job")
    }

    func testModeWinsOverAStaleTimestamp() {
        // The server keeps paused_until on the row when the mode moves off
        // "paused" (only approximate_radius_miles is NULLed), so a future
        // timestamp can outlive the pause it belonged to. The mode decides.
        XCTAssertFalse(settings(mode: "exact", pausedUntil: future).isPaused)
        XCTAssertFalse(settings(mode: "approximate", pausedUntil: future).isPaused)
    }

    // MARK: - pause/resume keep the pair consistent

    func testPauseUntilNilProducesTheIndefiniteState() {
        var s = settings(mode: "exact")
        s.pause(until: nil)
        XCTAssertEqual(s.sharingMode, "paused")
        XCTAssertNil(s.pausedUntil)
        XCTAssertTrue(s.isPaused)
    }

    func testPauseSetsBothFields() {
        var s = settings(mode: "exact")
        s.pause(until: future)
        XCTAssertEqual(s.sharingMode, "paused")
        XCTAssertEqual(s.pausedUntil, future)
        XCTAssertTrue(s.isPaused)
    }

    /// Clearing the timestamp on its own means "paused, forever", so Resume
    /// has to move the mode too.
    func testResumeClearsTheModeNotJustTheTimestamp() {
        var s = settings(mode: "paused", pausedUntil: nil)
        s.resume()
        XCTAssertEqual(s.sharingMode, "exact")
        XCTAssertNil(s.pausedUntil)
        XCTAssertFalse(s.isPaused)
    }

    /// A pause taken in Bubble Mode resumes in Bubble Mode. Resume follows the
    /// mode the pause returns to, which the pause records, not the toggle on
    /// its own: a toggle left on after the bubble's own end must not bring it
    /// back.
    func testResumeReturnsToBubbleWhenBubbleIsOn() {
        var s = settings(mode: "approximate", bubbleEnabled: true)
        s.pause(until: future)
        s.resume()
        XCTAssertEqual(s.sharingMode, "approximate")
        XCTAssertFalse(s.isPaused)
    }

    // MARK: - Bubble radius

    /// The server NULLs approximate_radius_miles whenever the mode isn't
    /// approximate and then rejects anything outside 1...25, so the default
    /// must already be inside that range — 0 is a guaranteed 400.
    func testDefaultRadiusIsWithinTheServersAcceptedRange() {
        let radius = Int(PrivacySettings.default(for: "c1").bubbleRadius.rounded())
        XCTAssertTrue((1...25).contains(radius), "default rounds to \(radius), outside 1...25")
    }

    func testDefaultPostureIsExactAndNotPaused() {
        let d = PrivacySettings.default(for: "c1")
        XCTAssertEqual(d.sharingMode, "exact")
        XCTAssertFalse(d.isPaused)
        XCTAssertFalse(d.showAllDevices, "fail-closed: one marker unless the user asked for all devices")
    }
}
