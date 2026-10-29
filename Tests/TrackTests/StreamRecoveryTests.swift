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

/// The location stream must come back after ANY error, not only after an auth or
/// ownership refusal.
///
/// WHY THIS IS WORTH TESTING
///   A transport error — a network change mid-RPC, the per-RPC timeout, a server
///   rollout answering Unavailable — must not leave the stream dead until logout
///   or a relaunch, and `start()` must be able to rebuild while the dead manager
///   is still held. A phone in that state sends nothing for hours, self copy
///   included, while nothing on it looks wrong. A refreshed token must reach the
///   stream too, or the stream is refused at expiry and drops that upload.
///
///   The decision logic is pure and pinned directly; the wiring into the
///   MainActor streamer cannot be driven without a live SDK, so it is pinned at
///   the source, like ForegroundPollGateTests.
final class StreamRecoveryTests: XCTestCase {

    // MARK: - Classification

    func testTransportErrorsAreNeitherAuthNorOwnership() {
        // The SDK's on_stream_error format: "gRPC error: {code:?} - {message}".
        for message in [
            "gRPC error: Unavailable - tcp connect error",
            "gRPC error: Cancelled - operation was canceled",
            "gRPC error: DeadlineExceeded - Timeout expired",
            "gRPC error: Unknown - transport error",
            "Streaming loop error: Connection failed",
        ] {
            XCTAssertEqual(SDKLocationStreamer.classifyStreamError(message), .other, message)
        }
    }

    func testAuthRefusalsStillRefreshTheToken() {
        for message in [
            "gRPC error: Unauthenticated - Invalid or expired token",
            "invalid token",
            "Token expired",
        ] {
            XCTAssertEqual(SDKLocationStreamer.classifyStreamError(message), .auth, message)
        }
    }

    func testOwnershipRefusalsStillReRegister() {
        XCTAssertEqual(
            SDKLocationStreamer.classifyStreamError("gRPC error: PermissionDenied - Device not found"),
            .ownershipLost)
        XCTAssertEqual(
            SDKLocationStreamer.classifyStreamError("device is not owned by user"),
            .ownershipLost)
    }

    // MARK: - Backoff

    func testRestartBackoffDoublesFromTwoSecondsAndCapsAtFiveMinutes() {
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: 0), 2)
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: 1), 4)
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: 2), 8)
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: 7), 256)
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: 8), 300)
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: 1_000), 300)
        XCTAssertEqual(SDKLocationStreamer.restartDelay(attempt: -3), 2)
    }

    func testKeyHealBacksOffFiveFifteenSixtyMinutes() {
        XCTAssertEqual(SDKLocationStreamer.keyHealCooldownMs(afterAttempts: 0), 5 * 60_000)
        XCTAssertEqual(SDKLocationStreamer.keyHealCooldownMs(afterAttempts: 1), 15 * 60_000)
        XCTAssertEqual(SDKLocationStreamer.keyHealCooldownMs(afterAttempts: 2), 60 * 60_000)
        XCTAssertEqual(SDKLocationStreamer.keyHealCooldownMs(afterAttempts: 9), 60 * 60_000)
    }

    // MARK: - Membership refusals

    func testMembershipRefusalIsRecognised() {
        XCTAssertTrue(SDKLocationStreamer.isMembershipRefusal("not a member of this circle"))
        XCTAssertFalse(SDKLocationStreamer.isMembershipRefusal("location consent required for this circle"))
        XCTAssertFalse(SDKLocationStreamer.isMembershipRefusal("rate limited: burst. retry in 3s"))
    }

    func testMembershipReloadIsAtMostHalfHourly() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(SDKLocationStreamer.membershipReloadIsDue(last: nil, now: t0))
        XCTAssertFalse(SDKLocationStreamer.membershipReloadIsDue(last: t0, now: t0.addingTimeInterval(29 * 60)))
        XCTAssertTrue(SDKLocationStreamer.membershipReloadIsDue(last: t0, now: t0.addingTimeInterval(30 * 60)))
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent(relative)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read \(relative) at \(path.path)")
            return ""
        }
        return text
    }

    private func body(of function: String, in src: String) throws -> String {
        let start = try XCTUnwrap(src.range(of: function), "\(function) is gone — retire this test with it")
        let rest = src[start.upperBound...]
        // Up to the EARLIEST next declaration at the same indentation.
        let ends = ["\n    func ", "\n    private func ", "\n    fileprivate func ",
                    "\n    nonisolated static func ", "\n    private static func ",
                    "\n    static func ", "\n    // MARK:"]
            .compactMap { rest.range(of: $0)?.lowerBound }
        return String(rest[..<(ends.min() ?? rest.endIndex)])
    }

    /// Code lines only, so a comment may quote the line this test forbids.
    private func live(_ src: String) -> String {
        src.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testANonAuthStreamErrorSchedulesARebuild() throws {
        let src = source("App/Services/SDKLocationStreamer.swift")
        XCTAssertFalse(live(src).contains("guard isAuth else { return }"),
                       "no early return that drops every non-auth error")
        let handler = try body(of: "fileprivate func handleStreamError(", in: src)
        XCTAssertTrue(handler.contains("guard kind == .auth else {"))
        XCTAssertTrue(handler.contains("scheduleRestart(reason:"),
                      "a non-auth, non-ownership error must schedule a rebuild")
    }

    func testTheKeyHealRunsOnlyForEncryptionFailures() throws {
        let src = source("App/Services/SDKLocationStreamer.swift")
        let send = try body(of: "func send(circleId: String, location: PingolinTrackSDK.Location, kind: SendKind, capturedAt: Date? = nil) throws {", in: src)
        let heal = try XCTUnwrap(send.range(of: "Self.onSendFailed(error: error)"))
        let before = String(send[..<heal.lowerBound])
        let lastCase = try XCTUnwrap(before.range(of: "case ", options: .backwards))
        XCTAssertTrue(String(before[lastCase.lowerBound...]).hasPrefix("case SendError.encryptionFailed:"),
                      "the key heal must sit under the encryption-failure case alone")
        XCTAssertTrue(send.contains("case SendError.transportFailed, SendError.notRunning:"))
        XCTAssertTrue(src.contains("try? await CircleManager.shared.loadCircles(light: true)"),
                      "the heal reloads light")
    }

    func testASendRebuildsAStreamTheSDKHasGivenUpOn() throws {
        let src = source("App/Services/SDKLocationStreamer.swift")
        let inner = try body(of: "private func sendInner(", in: src)
        XCTAssertTrue(inner.contains("if locationManager?.isStreaming() != true {"))
        XCTAssertTrue(inner.contains("rebuildStream(reason:"))
    }

    func testBatterySaverDoesNotKeepAnIdleStreamOpen() throws {
        let streamer = source("App/Services/SDKLocationStreamer.swift")
        let inner = try body(of: "private func sendInner(", in: streamer)
        XCTAssertTrue(inner.contains("scheduleBatterySaverTeardown()"),
                      "a saver send must schedule its stream to close after the last target")
        XCTAssertTrue(streamer.contains("LocationService.shared.isBatterySaverActive"),
                      "the idle close belongs to Battery Saver only")
        XCTAssertTrue(streamer.contains("self.teardown()"))
    }

    /// Battery Saver / Low Power Mode must NOT skip the stream bring-up outright.
    /// It opens the stream lazily on the first send — but only because the
    /// session is still REGISTERED (desiredUserId/desiredDeviceId). An early
    /// return would leave those nil, and `rebuildStream`/`scheduleRestart` both
    /// bail without them, so every send would throw `.notRunning` and the phone
    /// would upload nothing (SOS included) for the whole session, with no
    /// recovery when Low Power Mode turned back off.
    func testBatterySaverRegistersTheSessionSoTheFirstSendOpensItLazily() throws {
        let streamer = source("App/Services/SDKLocationStreamer.swift")
        let register = try body(of: "func registerDesiredSession(", in: streamer)
        XCTAssertTrue(register.contains("desiredUserId = userId"),
                      "registration must set the user the lazy rebuild requires")
        XCTAssertTrue(register.contains("desiredDeviceId = deviceId"),
                      "registration must set the device the lazy rebuild requires")

        // The three (and only) stream bring-up paths must REGISTER the session
        // in Battery Saver, not drop it.
        let auth = source("App/Managers/AuthManager.swift")
        XCTAssertTrue(auth.contains("SDKLocationStreamer.shared.registerDesiredSession("),
                      "the returning-user and fresh-sign-in paths must register the session in Battery Saver")
        XCTAssertFalse(auth.contains("if !LocationService.shared.isBatterySaverActive"),
                       "Battery Saver must not skip the stream bring-up wholesale")
        let headless = source("App/Services/HeadlessTrackingResume.swift")
        XCTAssertTrue(headless.contains("SDKLocationStreamer.shared.registerDesiredSession("),
                      "a background relaunch must register the session in Battery Saver")
        XCTAssertFalse(headless.contains("guard !LocationService.shared.isBatterySaverActive else { return }"),
                       "the relaunch must not drop the session in Battery Saver")
    }

    func testTheRefreshAuthorityHandsTheTokenToTheStream() {
        let api = source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("SDKLocationStreamer.shared.updateToken(rotatedAccessToken)"),
                      "performTokenRefresh must pass every rotated access token to the stream")
        let streamer = source("App/Services/SDKLocationStreamer.swift")
        XCTAssertTrue(streamer.contains("locationManager?.updateToken(jwtToken: token)"))
        XCTAssertTrue(streamer.contains("locationManager?.updateToken(jwtToken: jwtToken)"),
                      "start() on an already-running stream must hand over the caller's token")
        XCTAssertFalse(streamer.contains("update_token is a no-op"),
                       "nothing claims that update_token does nothing")
    }

    func testLogoutForgetsTheSessionItWouldRebuild() throws {
        let src = source("App/Services/SDKLocationStreamer.swift")
        let stop = try body(of: "    func stop() {", in: src)
        XCTAssertTrue(stop.contains("desiredUserId = nil"))
        XCTAssertTrue(stop.contains("desiredDeviceId = nil"))
        XCTAssertTrue(stop.contains("restartTask?.cancel()"),
                      "a rebuild scheduled before logout must not resurrect the stream")
    }
}
