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
import CoreLocation
import PingolinTrackSDK
@testable import Track

/// One fresh position once the device is addressable again after the server
/// refused it.
///
/// On a fresh sign-in the first fix can beat the APNs token: it is refused
/// "Device not found" and lost, and the circle would first see the person at
/// the next scheduled send. So when the token-carrying registration lands
/// after such a refusal, ONE fresh position goes at once:
/// - through the normal uploads, so every privacy rule applies (paused circles
///   get nothing, an approximate one gets it coarsened, only circles the
///   person shares with in real time);
/// - a FRESH fix carrying its own capture time, never a cached position
///   stamped as now; no fresh fix within the poll timeout, nothing;
/// - only within the accuracy limit every polled fix is held to;
/// - not before the circles' privacy has loaded: on a first sign-in the token
///   can land first, and the uploads would then reach this account alone;
/// - never across a session: its end drops what was owed or waiting;
/// - once per refusal and registration, never a loop.
@MainActor
final class FreshPositionAfterRefusalTests: XCTestCase {

    private let me = "11111111-1111-1111-1111-111111111111"
    private let someoneElse = "22222222-2222-2222-2222-222222222222"
    private var sends = 0
    private var keptSender: (@MainActor () async -> Void)?
    /// Whether the circles' privacy has loaded, as the streamer is told.
    private var targetsKnown = true
    private var keptTargetsKnown: (@MainActor () -> Bool)?

    override func setUp() async throws {
        try await super.setUp()
        let streamer = SDKLocationStreamer.shared
        keptSender = streamer.sendFreshPosition
        streamer.sendFreshPosition = { [weak self] in self?.sends += 1 }
        keptTargetsKnown = streamer.uploadTargetsKnown
        streamer.uploadTargetsKnown = { [weak self] in self?.targetsKnown ?? true }
        // Nothing owed or waiting from before this test.
        streamer.deviceBecameAddressable(account: nil)
        streamer.uploadTargetsLoaded(account: nil)
        await settle()
        sends = 0
    }

    override func tearDown() async throws {
        let streamer = SDKLocationStreamer.shared
        if let keptSender { streamer.sendFreshPosition = keptSender }
        if let keptTargetsKnown { streamer.uploadTargetsKnown = keptTargetsKnown }
        streamer.deviceBecameAddressable(account: nil)
        streamer.uploadTargetsLoaded(account: nil)
        try await super.tearDown()
    }

    /// Lets the streamer's send task run.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: - Once per refusal and registration

    func testARefusalThenTheRegistrationSendsExactlyOneFreshPosition() async {
        let streamer = SDKLocationStreamer.shared
        streamer.noteDeviceRefused(account: me)
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 1)

        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 1, "a second registration sends nothing more")
    }

    func testSeveralRefusedFixesBeforeTheRegistrationAreStillOneSend() async {
        let streamer = SDKLocationStreamer.shared
        for _ in 0..<3 { streamer.noteDeviceRefused(account: me.uppercased()) }
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 1)
    }

    func testARegistrationWithNoRefusalSendsNothing() async {
        SDKLocationStreamer.shared.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 0, "every launch registers with its token: no extra send for that")
    }

    func testEachRefusalAndRegistrationIsPaidOnce() async {
        let streamer = SDKLocationStreamer.shared
        streamer.noteDeviceRefused(account: me)
        streamer.deviceBecameAddressable(account: me)
        await settle()
        streamer.noteDeviceRefused(account: me)
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 2)
    }

    func testItIsOwedOnlyToTheAccountThatWasRefused() async {
        let streamer = SDKLocationStreamer.shared
        streamer.noteDeviceRefused(account: me)
        // Signed out, and someone else signed in before the registration landed.
        streamer.deviceBecameAddressable(account: someoneElse)
        await settle()
        XCTAssertEqual(sends, 0)
        // And it is gone, not kept for later.
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 0)
        // No account at all: nothing.
        streamer.noteDeviceRefused(account: nil)
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 0)
    }

    // MARK: - Not before the circles' privacy has loaded

    /// A first sign-in where the token beat the first circle load: paid when
    /// the load lands, once, and then it reaches the circle, not this account
    /// alone.
    func testATokenBeforeTheCirclesLoadIsPaidOnceTheyHaveAndReachesTheCircle() async {
        let streamer = SDKLocationStreamer.shared
        let circle = "33333333-3333-3333-3333-333333333333"
        var privacyHeld: [String: PrivacySettings] = [:]
        var targetsWhenPaid: [[String]] = []
        // What the uploads would send to at the moment it is paid (CircleManager.syncLocation).
        streamer.sendFreshPosition = {
            targetsWhenPaid.append(CircleManager.uploadTargets(
                selfId: SelfKeyManager.selfCircleUuid, circleIds: [circle], privacy: privacyHeld))
        }
        targetsKnown = false
        streamer.noteDeviceRefused(account: me)
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertTrue(targetsWhenPaid.isEmpty, "not yet: it would reach this account alone")

        privacyHeld[circle] = privacy(circle, mode: "exact")
        targetsKnown = true
        streamer.uploadTargetsLoaded(account: me)
        await settle()
        XCTAssertEqual(targetsWhenPaid, [[SelfKeyManager.selfCircleUuid, circle]])

        streamer.uploadTargetsLoaded(account: me)
        await settle()
        XCTAssertEqual(targetsWhenPaid.count, 1, "the next load sends nothing more")
    }

    func testCirclesLoadedForAnotherAccountPayNothing() async {
        let streamer = SDKLocationStreamer.shared
        targetsKnown = false
        streamer.noteDeviceRefused(account: me)
        streamer.deviceBecameAddressable(account: me)
        // Signed out, and someone else's circles loaded.
        streamer.uploadTargetsLoaded(account: someoneElse)
        await settle()
        XCTAssertEqual(sends, 0)
        streamer.uploadTargetsLoaded(account: me)
        await settle()
        XCTAssertEqual(sends, 0, "and it is gone, not kept for later")
    }

    func testALoadWithNothingWaitingSendsNothing() async {
        let streamer = SDKLocationStreamer.shared
        streamer.uploadTargetsLoaded(account: me)
        // Owed, but not yet addressable: the load alone pays nothing.
        streamer.noteDeviceRefused(account: me)
        streamer.uploadTargetsLoaded(account: me)
        await settle()
        XCTAssertEqual(sends, 0)
    }

    // MARK: - Not across a session

    /// A sign-out (or a switch, an expired or a revoked session) drops what was
    /// owed or waiting: the same account signing back in, in this process, is
    /// not paid for a refusal of the session before.
    func testTheEndOfASessionDropsWhatWasOwedOrWaiting() async {
        let streamer = SDKLocationStreamer.shared
        streamer.noteDeviceRefused(account: me)
        streamer.forgetFreshPositionOwed()
        streamer.deviceBecameAddressable(account: me)
        await settle()
        XCTAssertEqual(sends, 0, "owed")

        targetsKnown = false
        streamer.noteDeviceRefused(account: me)
        streamer.deviceBecameAddressable(account: me)
        streamer.forgetFreshPositionOwed()
        streamer.uploadTargetsLoaded(account: me)
        await settle()
        XCTAssertEqual(sends, 0, "waiting for the circles")
    }

    func testEveryEndOfASessionForgetsIt() throws {
        let auth = try source("App/Managers/AuthManager.swift")
        let ends = [
            ("sign-out and switch", try body(auth, from: "    private func purgeAccountData() async {",
                                             to: "        CircleManager.shared.reset()")),
            ("expired session", try body(auth, from: "    func expireSession() {", to: "        currentUser = nil")),
            ("revoked headless session", try body(try source("App/Services/HeadlessTrackingResume.swift"),
                                                  from: "    private static func sessionWasRevoked() {",
                                                  to: "    fileprivate static func markResumed() {")),
        ]
        for (name, end) in ends {
            XCTAssertTrue(end.contains("        SDKLocationStreamer.shared.stop()\n"
                                       + "        SDKLocationStreamer.shared.forgetFreshPositionOwed()\n"), name)
        }
        // Not in stop(): the ownership refusal's own rebuild runs stop() and start() while it is owed.
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertFalse(try body(streamer, from: "    func stop() {", to: "    /// Release the running manager")
            .contains("freshPosition"))
        XCTAssertTrue(streamer.contains("                self.stop()\n                self.start(jwtToken: access, userId: userId, deviceId: deviceId)"))
    }

    // MARK: - A fresh fix, with its own time, into the normal uploads

    private let askedAt = Date(timeIntervalSince1970: 1_790_000_000)
    /// What `handleFix` holds a polled fix to, on the default profile.
    private let limit = LocationService.TrackingConfig.highAccuracy.acceptedAccuracy
    // Apple Park: a fixture point nowhere near anyone's home.
    private func fix(at time: Date, accuracy: CLLocationAccuracy = 12) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: time)
    }

    func testAFreshFixGoesOnceIntoTheUploadsAsATrailPointWithItsOwnTime() async {
        let fresh = fix(at: askedAt.addingTimeInterval(3))
        var published: [LocationService.SendRequest] = []
        let sent = await LocationService.freshFixAfterRefusal(
            tracking: true, acceptedAccuracy: limit, now: { self.askedAt }, fix: { fresh },
            publish: { published.append($0) })

        XCTAssertTrue(sent)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.mode, .history, "a trail point: the refused one was lost")
        XCTAssertEqual(published.first?.location.timestamp, fresh.timestamp)
        // What the upload stamps on it: the fix's own capture time, not the moment it goes.
        XCTAssertEqual(
            LocationService.payloadTimestamp(mode: .history, fixTimestamp: fresh.timestamp,
                                             now: askedAt.addingTimeInterval(60)),
            fresh.timestamp)
    }

    func testACachedFixIsNeverSentAsNew() async {
        var published: [LocationService.SendRequest] = []
        let cached = fix(at: askedAt.addingTimeInterval(-60))
        let sent = await LocationService.freshFixAfterRefusal(
            tracking: true, acceptedAccuracy: limit, now: { self.askedAt }, fix: { cached },
            publish: { published.append($0) })
        XCTAssertFalse(sent)
        XCTAssertTrue(published.isEmpty, "left to the schedule")

        // The poll's own slack: Core Location's first delivery may be a moment older than the request.
        XCTAssertNotNil(LocationService.resendRequest(
            for: fix(at: askedAt.addingTimeInterval(-1)), askedAt: askedAt, acceptedAccuracy: limit))
        XCTAssertNil(LocationService.resendRequest(
            for: fix(at: askedAt.addingTimeInterval(-3)), askedAt: askedAt, acceptedAccuracy: limit))
    }

    /// A request that times out hands back its roughest fresh fix, and with
    /// Precise Location off every fix is kilometre-scale: `handleFix` rejects
    /// those, and so does this send. The schedule takes over.
    func testACoarseOnlyFixSendsNothing() async {
        var published: [LocationService.SendRequest] = []
        let coarse = fix(at: askedAt.addingTimeInterval(3), accuracy: limit + 1)
        let sent = await LocationService.freshFixAfterRefusal(
            tracking: true, acceptedAccuracy: limit, now: { self.askedAt }, fix: { coarse },
            publish: { published.append($0) })
        XCTAssertFalse(sent)
        XCTAssertTrue(published.isEmpty, "left to the schedule")
        // At the limit it goes; an invalid accuracy is the roughest there is.
        XCTAssertNotNil(LocationService.resendRequest(
            for: fix(at: askedAt, accuracy: limit), askedAt: askedAt, acceptedAccuracy: limit))
        XCTAssertNil(LocationService.resendRequest(
            for: fix(at: askedAt, accuracy: -1), askedAt: askedAt, acceptedAccuracy: limit))
    }

    func testNoFixWithinThePollTimeoutSendsNothing() async {
        var published: [LocationService.SendRequest] = []
        let sent = await LocationService.freshFixAfterRefusal(
            tracking: true, acceptedAccuracy: limit, now: { self.askedAt },
            fix: { throw LocationService.LocationError.timeout },
            publish: { published.append($0) })
        XCTAssertFalse(sent)
        XCTAssertTrue(published.isEmpty)
    }

    func testNothingAtAllWhileTrackingIsNotAskedFor() async {
        var asked = 0
        var published: [LocationService.SendRequest] = []
        let sent = await LocationService.freshFixAfterRefusal(
            tracking: false, acceptedAccuracy: limit, now: { self.askedAt },
            fix: { asked += 1; return self.fix(at: self.askedAt) },
            publish: { published.append($0) })
        XCTAssertFalse(sent)
        XCTAssertEqual(asked, 0, "not even a fix is asked for")
        XCTAssertTrue(published.isEmpty)
    }

    // MARK: - The privacy rules of the normal uploads apply to it

    private func privacy(_ id: String, mode: String, bubble: Bool = false) -> PrivacySettings {
        PrivacySettings(
            circleId: id, sharingMode: mode, shareRealtime: true, shareHistory: true, shareBattery: true,
            bubbleEnabled: bubble, bubbleRadius: 1, pausedUntil: nil, updatedAt: askedAt)
    }

    func testAPausedCircleGetsNothingAndAnApproximateOneGetsItCoarsened() async throws {
        let fresh = fix(at: askedAt.addingTimeInterval(3))
        var published: [LocationService.SendRequest] = []
        _ = await LocationService.freshFixAfterRefusal(
            tracking: true, acceptedAccuracy: limit, now: { self.askedAt }, fix: { fresh },
            publish: { published.append($0) })
        let request = try XCTUnwrap(published.first)

        // The uploads' targets for it (CircleManager.syncLocation): self, and the circles the person
        // shares with in real time. A paused one is not among them.
        let settings = [
            "paused": privacy("paused", mode: "paused"),
            "approx": privacy("approx", mode: "approximate", bubble: true),
            "exact": privacy("exact", mode: "exact"),
        ]
        let targets = CircleManager.uploadTargets(
            selfId: SelfKeyManager.selfCircleUuid, circleIds: ["paused", "approx", "exact"], privacy: settings)
        XCTAssertEqual(targets, [SelfKeyManager.selfCircleUuid, "approx", "exact"])

        // What each target is sent (SDKLocationStreamer.privacyApplied, on every send).
        let payload = PingolinTrackSDK.Location(
            latitude: request.location.coordinate.latitude,
            longitude: request.location.coordinate.longitude,
            altitude: nil, speed: nil, heading: nil,
            accuracy: request.location.horizontalAccuracy,
            timestamp: Int64(LocationService.payloadTimestamp(
                mode: request.mode, fixTimestamp: request.location.timestamp, now: askedAt
            ).timeIntervalSince1970 * 1000),
            batteryLevel: nil, isCharging: nil)
        let approximate = SDKLocationStreamer.privacyApplied(
            payload, circleId: "approx", privacy: settings["approx"], now: askedAt)
        XCTAssertNotNil(approximate.coarsenedToMiles, "an approximate circle gets the grid cell")
        XCTAssertNotEqual(approximate.location.latitude, payload.latitude)
        let exact = SDKLocationStreamer.privacyApplied(
            payload, circleId: "exact", privacy: settings["exact"], now: askedAt)
        XCTAssertNil(exact.coarsenedToMiles)
        XCTAssertEqual(exact.location.latitude, payload.latitude)
        XCTAssertEqual(exact.location.timestamp, Int64(fresh.timestamp.timeIntervalSince1970 * 1000))
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }

    func testTheRefusalsOweItAndTheNormalUploadsCarryIt() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let streamError = try body(streamer, from: "    fileprivate func handleStreamError(_ message: String) {",
                                   to: "    private func refreshTokenAndRestart(userId: String, deviceId: String) async {")
        let fixRefused = try body(streamer, from: "    fileprivate func handleLocationRejected(deviceId: String, error: String) {",
                                  to: "    /// Which table the server files the row under.")
        for (name, handler) in [("stream error", streamError), ("refused fix", fixRefused)] {
            let noted = try XCTUnwrap(handler.range(of: "noteDeviceRefused(account: startedUserId)"), name)
            // Before any guard that can return: a refusal is owed whatever the cooldown says.
            let cooldown = try XCTUnwrap(handler.range(of: "re-registered <5m ago"), name)
            XCTAssertLessThan(noted.upperBound, cooldown.lowerBound, name)
        }
        // The live payer: one fresh fix, through LocationService.
        XCTAssertTrue(streamer.contains("_ = await LocationService.shared.sendOneFreshFixAfterRefusal()"))

        let location = try source("App/Services/LocationService.swift")
        let send = try body(location, from: "    func sendOneFreshFixAfterRefusal() async -> Bool {",
                            to: "    /// `sendOneFreshFixAfterRefusal`, with what it reads handed in.")
        XCTAssertTrue(send.contains("tracking: wantsTracking,"))
        // The limit every polled fix is held to.
        XCTAssertTrue(send.contains("acceptedAccuracy: activeConfig.acceptedAccuracy,"))
        let handleFix = try body(location, from: "    func handleFix(_ location: CLLocation, source: String) -> FixOutcome {",
                                 to: "            return .rejectedAccuracy")
        XCTAssertTrue(handleFix.contains("let minAccuracy = TrackingConfig.acceptedAccuracy("))
        XCTAssertTrue(send.contains("fix: { try await self.requestSingleLocation() },"))
        // Into the stream every gated fix goes into, which CircleManager uploads from.
        XCTAssertTrue(send.contains("self.locationSendRequests.send($0)"))
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("        locationService.locationSendRequests\n            .receive(on: DispatchQueue.main)"))
    }

    /// The circle load says when the targets are known: after the privacy
    /// fan-out, and only for a list the server gave now (`circlesLoaded`, which
    /// a sign-out clears).
    func testTheCircleLoadTellsTheStreamerOnceTheTargetsAreKnown() throws {
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        XCTAssertTrue(streamer.contains(
            "    var uploadTargetsKnown: @MainActor () -> Bool = { CircleManager.shared.circlesLoaded }"))
        let circles = try source("App/Managers/CircleManager.swift")
        let load = try body(circles, from: "    func loadCircles(light: Bool = false) async throws {",
                            to: "    private(set) var circlesLoaded = false")
        let privacy = try XCTUnwrap(load.range(of: "_ = try? await self.loadPrivacySettings(for: id)"))
        // Where a list the server gave now marks the load done: inside `if listedNow`, at `circlesLoaded`.
        let told = try XCTUnwrap(load.range(of: "            circlesLoaded = true\n"
                                            + "            SDKLocationStreamer.shared.uploadTargetsLoaded(account: AuthManager.shared.userId)\n"
                                            + "        }\n"))
        XCTAssertLessThan(privacy.upperBound, told.lowerBound, "after the privacy fan-out")
        XCTAssertEqual(load.components(separatedBy: "uploadTargetsLoaded(").count - 1, 1)
        XCTAssertTrue(try body(circles, from: "    func reset() {", to: "    }\n").contains("circlesLoaded = false"))
    }
}
