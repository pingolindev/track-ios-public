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
@testable import Track

/// A liveness check-in re-sends `LocationService.currentLocation` stamped NOW,
/// and `handleFix` writes it. The fixes taken outside the poll (the map's
/// "Send location", the foreground nudge, a wake, a check-in, an alert, the
/// fresh position after a refusal) come from `requestSingleLocation`'s own
/// manager and never pass through it. Left out of the cache, a send from a new
/// place would be followed by a check-in — allowed while the cache is up to ten
/// minutes old (or twice a stretched poll) — that puts the person back at the
/// older place "now" until a poll's fix replaced it. So each of those fixes
/// becomes the cache when it is newer by its own time (`adoptSentFix`), while
/// tracking; every end of a session forgets the cache, and the sends that take
/// a single fix carry its own time, never now.
final class StaleCheckInAfterOneShotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func fix(_ lat: Double, secondsAgo: TimeInterval) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: -122.0090),
                   altitude: 0, horizontalAccuracy: 12, verticalAccuracy: -1,
                   timestamp: now.addingTimeInterval(-secondsAgo))
    }

    // MARK: - The rule

    func testANewerFixReplacesTheCacheAnOlderOneNever() {
        let held = fix(37.30, secondsAgo: 300)
        XCTAssertTrue(LocationService.isNewer(fix(37.33, secondsAgo: 5), than: held, now: now))
        XCTAssertTrue(LocationService.isNewer(fix(37.33, secondsAgo: 5), than: nil, now: now), "no position yet")
        XCTAssertFalse(LocationService.isNewer(fix(37.33, secondsAgo: 300), than: held, now: now), "the same moment")
        // Core Location's cache, which a timed-out request can hand back, never wins over a newer position.
        XCTAssertFalse(LocationService.isNewer(fix(37.33, secondsAgo: 600), than: held, now: now))
    }

    /// The case itself: still at A (cached 5 min ago), "Send location" from B a
    /// minute later. The check-in that follows re-sends B, the newest position,
    /// not A; and B is fresh enough for it to do so.
    func testTheCheckInAfterASendFromANewPlaceIsThatPlace() {
        var cache: CLLocation? = fix(37.30, secondsAgo: 300)
        let sentFromB = fix(37.33, secondsAgo: 240)
        if LocationService.isNewer(sentFromB, than: cache, now: now) { cache = sentFromB }
        XCTAssertEqual(cache?.coordinate.latitude, 37.33)
        XCTAssertFalse(LocationService.livenessCacheTooOld(
            cacheAge: now.timeIntervalSince(sentFromB.timestamp), pollInterval: 300))
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

    /// The fix is adopted right where it is taken, before it is sent.
    private func assertAdopts(_ file: String, after take: String, adopt: String, before send: String,
                              line: UInt = #line) throws {
        let src = try source(file)
        let taken = try XCTUnwrap(src.range(of: take), "\(file): \(take)", line: line)
        let adopted = try XCTUnwrap(src.range(of: adopt, range: taken.upperBound..<src.endIndex),
                                    "\(file) takes a fix and never adopts it", line: line)
        let sent = try XCTUnwrap(src.range(of: send, range: taken.upperBound..<src.endIndex),
                                 "\(file): \(send)", line: line)
        XCTAssertLessThan(adopted.lowerBound, sent.lowerBound, "\(file): adopted before it is sent", line: line)
    }

    func testEveryFixTakenOutsideThePollBecomesTheCache() throws {
        try assertAdopts("App/Views/Map/MapView.swift",
                         after: "let cl = try await locationService.requestSingleLocation()",
                         adopt: "locationService.adoptSentFix(cl)",
                         before: "SDKLocationStreamer.shared.sendNow(circleId: circleId, location: loc)")
        try assertAdopts("App/TrackApp.swift",
                         after: "let cl = try await locationService.requestSingleLocation()",
                         adopt: "locationService.adoptSentFix(cl)",
                         before: "SDKLocationStreamer.shared.sendNow(circleId: circleId, location: loc)")
        try assertAdopts("App/Managers/PushNotificationManager.swift",
                         after: "let location = try await wakeFix()",
                         adopt: "LocationService.shared.adoptSentFix(location)",
                         before: "try? SDKLocationStreamer.shared.send(circleId: circleId, location: sdkLocation)")
        try assertAdopts("App/Managers/CheckInManager.swift",
                         after: "if let location = try? await locationService.requestSingleLocation() {",
                         adopt: "locationService.adoptSentFix(location)",
                         before: "createCheckInOverWire(")
        // An SOS doesn't take its position from a single fix: it
        // seals what is held at the press, and the precise fix asked
        // for then is adopted when it lands (SOSRaisePositionTests'
        // wiring test).
        try assertAdopts("App/Services/LocationService.swift",
                         after: "fix: { try await self.requestSingleLocation() },",
                         adopt: "self.adoptSentFix($0.location)",
                         before: "self.locationSendRequests.send($0)")
    }

    /// A new place that takes a single fix fails here until it adopts it, or is
    /// listed with its reason.
    func testNoOtherCallerTakesASingleFix() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let known: [String: Int] = [
            "App/Views/Map/MapView.swift": 1,
            "App/TrackApp.swift": 1,
            "App/Managers/PushNotificationManager.swift": 1,   // inside wakeFix(); adopted by its caller
            "App/Managers/CheckInManager.swift": 1,
            "App/Services/LocationService.swift": 1,           // the fresh position after a refusal
            // Onboarding sends nothing and discards its fix; the first run's own
            // marker must come from tracking (FirstRunLocationTests), not from it.
            "App/Views/Onboarding/OnboardingView.swift": 1,
        ]
        var found: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            let calls = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                .filter { $0.contains("requestSingleLocation(") && !$0.contains("func requestSingleLocation(")
                    && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .count
            if calls > 0 { found[path] = calls }
        }
        XCTAssertEqual(found, known)
    }

    /// A single fix is not always taken after the request: one that times out
    /// hands back Core Location's older cache (`FreshFixRequest.timeOut`), and
    /// stamped "now" that would be an old place passed off as current. The
    /// sends that take one carry the fix's own time, as the wake does.
    func testTheSendsThatTakeASingleFixCarryItsOwnTime() throws {
        let timeOut = try body(try source("App/Services/LocationService.swift"),
                               from: "    private func timeOut() {", to: "    private func finish(")
        XCTAssertTrue(timeOut.contains("finish(.success(cached))"), "why: a timed-out request can return the cache")
        // All three build it with the one builder for a single send, which
        // takes the fix's own time (SendLocationTests checks it on a fix).
        for file in ["App/Views/Map/MapView.swift", "App/TrackApp.swift"] {
            let send = try body(try source(file), from: "let cl = try await locationService.requestSingleLocation()",
                                to: "SDKLocationStreamer.shared.sendNow(circleId: circleId, location: loc)")
            XCTAssertTrue(send.contains("let loc = PingolinTrackSDK.Location.forSend(cl)"), file)
            XCTAssertFalse(send.contains("timestamp: nowMs"), file)
        }
        let wake = try body(try source("App/Managers/PushNotificationManager.swift"),
                            from: "let location = try await wakeFix()",
                            to: "try? SDKLocationStreamer.shared.send(circleId: circleId, location: sdkLocation)")
        XCTAssertTrue(wake.contains("let sdkLocation = PingolinTrackSDK.Location.forSend(location)"))
        XCTAssertTrue(try source("App/Services/SendLocation.swift")
            .contains("timestamp: Int64(fix.timestamp.timeIntervalSince1970 * 1000),"))
    }

    func testTheCheckInStillReSendsTheCache() throws {
        let src = try source("App/Services/LocationService.swift")
        let checkIn = try body(src, from: "    private func requestLivenessCheckIn(reason: String, force: Bool = false) {",
                               to: "    @MainActor\n    private func observeMotionStateIfNeeded() {")
        XCTAssertTrue(checkIn.contains("guard let location = currentLocation else {"))
        XCTAssertTrue(checkIn.contains("routeToSendGate(location, source: reason, allowHistory: false, forceCheckIn: force)"))
        let adopt = try body(src, from: "    func adoptSentFix(_ fix: CLLocation) {",
                             to: "    /// Whether `fix` is newer than `held`")
        XCTAssertTrue(adopt.contains("guard Self.adopts(fix, held: currentLocation, tracking: wantsTracking, now: Date()) else { return }"))
        XCTAssertTrue(adopt.contains("currentLocation = fix"))
    }

    // MARK: - Not across a sign-out

    /// What a check-in re-sends, if carried across a sign-out or a switch,
    /// would put where this phone was during the last session on the next
    /// account's circles, as current. Every way a session ends stops
    /// tracking, and stopping forgets it.
    func testEveryEndOfASessionForgetsTheHeldPosition() throws {
        let stop = try body(try source("App/Services/LocationService.swift"),
                            from: "    func stopTracking() {", to: "    /// Settings changed a tracking knob")
        XCTAssertTrue(stop.contains("        currentLocation = nil\n"))
        let auth = try source("App/Managers/AuthManager.swift")
        // Sign-out, and a switch (completeLogin purges the outgoing account).
        let purge = try body(auth, from: "    private func purgeAccountData() async {", to: "        CircleManager.shared.reset()")
        XCTAssertTrue(purge.contains("LocationService.shared.stopTracking()"))
        let expire = try body(auth, from: "    func expireSession() {", to: "        currentUser = nil")
        XCTAssertTrue(expire.contains("LocationService.shared.stopTracking()"))
        let revoked = try body(try source("App/Services/HeadlessTrackingResume.swift"),
                               from: "    private static func sessionWasRevoked() {",
                               to: "    fileprivate static func markResumed() {")
        XCTAssertTrue(revoked.contains("LocationService.shared.stopTracking()"))
    }

    /// A request still in flight when the session ended lands after it: it
    /// must not bring a held position back.
    func testAFixThatLandsWhileNotTrackingIsNotHeld() {
        let landed = fix(37.33, secondsAgo: 5)
        XCTAssertFalse(LocationService.adopts(landed, held: nil, tracking: false, now: now))
        XCTAssertTrue(LocationService.adopts(landed, held: nil, tracking: true, now: now))
        XCTAssertFalse(LocationService.adopts(fix(37.33, secondsAgo: 600), held: fix(37.30, secondsAgo: 300),
                                              tracking: true, now: now), "and never an older one")
    }
}
