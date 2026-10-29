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

/// Resuming tracking in a process iOS relaunched in the background for a
/// location event.
///
/// WHY THIS IS WORTH TESTING
///   Session restore runs from RootView's `.onAppear`, and a background
///   relaunch for a region exit, a significant change or a visit never shows a
///   scene. Without a headless resume a relaunched process handles its one
///   event and goes quiet, and the phone stays dark to its circle until the
///   user opens the app — silent from every angle, since the process DID
///   launch. The battery-saver sleep suspends the app on purpose, which makes
///   termination and relaunch the ordinary path rather than a rare one.
@MainActor
final class HeadlessTrackingResumeTests: XCTestCase {
    typealias Resume = HeadlessTrackingResume

    private final class Recorder {
        var calls: [String] = []
        var streamerSession: Resume.Session?
    }

    private func environment(
        background: Bool = true,
        tracking: Bool = false,
        token: String? = "jwt",
        user: String? = "user-1",
        device: String? = "device-1"
    ) -> Resume.Environment {
        Resume.Environment(
            appInBackground: { background },
            alreadyTracking: { tracking },
            storedCredentials: { (token, user, device) },
            // Known allowed: the gate's own cases are RegistrationGateTests'.
            access: { .allowed },
            readAccess: {}
        )
    }

    private func actions(_ recorder: Recorder) -> Resume.Actions {
        Resume.Actions(
            restoreCrypto: { recorder.calls.append("crypto") },
            startStreamer: { recorder.calls.append("streamer"); recorder.streamerSession = $0 },
            startTracking: { recorder.calls.append("tracking") },
            finishInBackground: { recorder.calls.append("finish") }
        )
    }

    // MARK: - The two behaviours this exists for

    func testABackgroundLocationLaunchWithAStoredSessionResumesTracking() {
        let recorder = Recorder()
        let decision = Resume.attempt(locationWake: true, environment: environment(), actions: actions(recorder))
        XCTAssertEqual(decision, .resume(.init(accessToken: "jwt", userId: "user-1", deviceId: "device-1")))
        XCTAssertEqual(recorder.calls, ["crypto", "streamer", "tracking", "finish"],
                       "keys before the streamer, the streamer before the first fix it will carry")
        XCTAssertEqual(recorder.streamerSession,
                       Resume.Session(accessToken: "jwt", userId: "user-1", deviceId: "device-1"),
                       "the streamer gets the stored credentials")
    }

    func testABackgroundLocationLaunchWithoutASessionDoesNothing() {
        let incomplete: [(String?, String?, String?)] = [
            (nil, "user-1", "device-1"),
            ("jwt", nil, "device-1"),
            ("jwt", "user-1", nil),
            ("", "user-1", "device-1"),
            ("jwt", "", "device-1"),
            ("jwt", "user-1", ""),
            (nil, nil, nil),
        ]
        for (token, user, device) in incomplete {
            let recorder = Recorder()
            let decision = Resume.attempt(
                locationWake: true,
                environment: environment(token: token, user: user, device: device),
                actions: actions(recorder)
            )
            XCTAssertEqual(decision, .noSession, "token=\(String(describing: token)) user=\(String(describing: user))")
            XCTAssertTrue(recorder.calls.isEmpty, "no streamer, no tracking, no network without a session")
        }
    }

    // MARK: - Everything else is left alone

    func testOnlyALocationWakeResumes() {
        let recorder = Recorder()
        XCTAssertEqual(
            Resume.attempt(locationWake: false, environment: environment(), actions: actions(recorder)),
            .notALocationWake)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testTheForegroundRestoreOwnsAVisibleLaunch() {
        let recorder = Recorder()
        XCTAssertEqual(
            Resume.attempt(locationWake: true, environment: environment(background: false), actions: actions(recorder)),
            .foreground,
            "on screen, RootView's .onAppear restore runs; resuming here too would only race it")
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testASecondWakeInTheSameProcessIsANoOp() {
        let recorder = Recorder()
        XCTAssertEqual(
            Resume.attempt(locationWake: true, environment: environment(tracking: true), actions: actions(recorder)),
            .alreadyTracking)
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testTheDecisionIsPure() {
        XCTAssertEqual(
            Resume.decide(locationWake: true, appInBackground: true, alreadyTracking: false,
                          accessToken: "t", userId: "u", deviceId: "d"),
            .resume(.init(accessToken: "t", userId: "u", deviceId: "d")))
        XCTAssertEqual(
            Resume.decide(locationWake: true, appInBackground: true, alreadyTracking: false,
                          accessToken: nil, userId: "u", deviceId: "d"),
            .noSession)
        XCTAssertEqual(
            Resume.decide(locationWake: false, appInBackground: true, alreadyTracking: false,
                          accessToken: "t", userId: "u", deviceId: "d"),
            .notALocationWake)
    }

    // MARK: - The wiring, asserted at the source

    func testTheLaunchPathInstallsItForLocationLaunches() throws {
        let src = try source("App/Managers/PushNotificationManager.swift")
        XCTAssertTrue(src.contains("HeadlessTrackingResume.install(launchedForLocation: launchOptions?[.location] != nil)"))
    }

    func testAResumeDoesWhatTheSessionRestoreDoesWithoutTheUI() throws {
        let src = try source("App/Services/HeadlessTrackingResume.swift")
        let live = try slice(src, from: "extension HeadlessTrackingResume.Actions {", to: nil)
        XCTAssertTrue(live.contains("SDKLocationStreamer.shared.start("))
        XCTAssertTrue(live.contains("LocationService.shared.startTracking()"))
        XCTAssertTrue(live.contains("CircleManager.shared.loadCircles(light: true)"),
                      "without a circle load the upload targets are the self copy alone: the circle stays dark")
        XCTAssertFalse(live.contains("requestAuthorization"), "no notification prompt without a scene")
        XCTAssertFalse(live.contains("checkExistingSession"), "the UI restore is not run headless")
        // Keys reload BEFORE the private-key import: importing persists the key set.
        let load = try XCTUnwrap(live.range(of: "loadPersistedKeys()"))
        let importKey = try XCTUnwrap(live.range(of: "importPrivateKey("))
        XCTAssertLessThan(load.lowerBound, importKey.lowerBound)
    }

    func testEveryIdleLocationEventReachesTheHook() throws {
        let src = try source("App/Services/LocationService.swift")
        for header in [
            "func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {\n        guard let location = locations.last else { return }\n        noteLocationEventIfIdle()",
            "didVisit visit: CLVisit) {",
            "didEnterRegion region: CLRegion) {\n        noteLocationEventIfIdle()",
            "didExitRegion region: CLRegion) {\n        noteLocationEventIfIdle()",
        ] {
            XCTAssertTrue(src.contains(header), "missing hook call: \(header.prefix(60))")
        }
        // A visit must be offered to the hook BEFORE its isTracking guard drops it.
        let visit = try slice(src, from: "didVisit visit: CLVisit) {", to: "// .distantFuture means")
        let hook = try XCTUnwrap(visit.range(of: "noteLocationEventIfIdle()"))
        let guardLine = try XCTUnwrap(visit.range(of: "guard isTracking else { return }"))
        XCTAssertLessThan(hook.lowerBound, guardLine.lowerBound)
    }

    /// The headless restore and the later `.onAppear` restore both call
    /// `SDKLocationStreamer.start` and `startTracking()`. Both must be safe
    /// to call twice: nothing may register twice.
    func testTheTwoRestoresComposeInEitherOrder() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertTrue(streamer.contains("if locationManager != nil, startedDeviceId == deviceId {"),
                      "a second start() for the same device must not rebuild the stream")
        let location = try source("App/Services/LocationService.swift")
        XCTAssertTrue(location.contains("guard batteryObservers.isEmpty else { return }"))
        XCTAssertTrue(location.contains("guard motionSubscription == nil else { return }"))
        XCTAssertTrue(location.contains("poll skipped, previous still in flight"))
        let arm = try slice(location, from: "private func armPollTimer(", to: "private func reconcileLivenessTimer(")
        XCTAssertTrue(arm.contains("pollTimer?.invalidate()"), "a re-arm replaces the timer, never adds one")
        let motion = try source("App/Managers/MotionDetectionManager.swift")
        XCTAssertTrue(motion.contains("guard isAvailable, !isStarted else { return }"))
    }

    func testARevokedSessionStopsAHeadlessResume() throws {
        let src = try source("App/Services/HeadlessTrackingResume.swift")
        let body = try slice(src, from: "private static func sessionWasRevoked()", to: "fileprivate static func markResumed()")
        XCTAssertTrue(body.contains("guard resumedHeadless, !AuthManager.shared.isAuthenticated else { return }"),
                      "AuthManager handles a revocation itself whenever the UI is signed in")
        XCTAssertTrue(body.contains("LocationService.shared.stopTracking()"))
        XCTAssertTrue(body.contains("SDKLocationStreamer.shared.stop()"))
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func slice(_ src: String, from start: String, to end: String?) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), "\(start) not found — renamed or removed")
        guard let end else { return String(src[a.lowerBound...]) }
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), "\(end) not found after \(start)")
        return String(src[a.lowerBound..<b.lowerBound])
    }
}
