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

/// A fix taken outside the poll (the map's "Send location", the foreground
/// nudge, a wake, a check-in, an alert, the fresh position after a refusal)
/// reaches the checks that react to where this phone is, as a polled fix does
/// (as in the Android app).
///
/// Those checks ride `LocationService.locationUpdates`: destination
/// auto-arrival (`DestinationsManager.checkAutoArrival`), own place alerts
/// (`PlaceAlertEvaluator.evaluateOwn`), the monitored-region pick past 19
/// places, the inactivity watch. Fed only by `handleFix` and visits, an arrival
/// at a destination whose first fix there was a send-now would wait for the
/// next accepted poll fix: minutes, on a still cadence. So an ADOPTED one-shot
/// is published too, but only when it is a position by `handleFix`'s own rules,
/// so a coarse or cached one-shot can never fake an arrival; and nothing on
/// `locationUpdates` uploads. The other way round, a poll's fix or a visit
/// older than the one held is skipped: nothing moves for it, while the same
/// fix again still proves a stationary phone alive.
@MainActor
final class OneShotFixLocalChecksTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// What `handleFix` holds a polled fix to, on the default profile.
    private let limit = LocationService.TrackingConfig.highAccuracy.acceptedAccuracy

    // Apple Park: a fixture point nowhere near anyone's home.
    private let destination = CLLocation(latitude: 37.3349, longitude: -122.0090)

    private func fix(northOfDestinationBy meters: Double = 30, accuracy: CLLocationAccuracy = 12,
                     secondsAgo: TimeInterval = 2) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 37.3349 + meters / 111_320, longitude: -122.0090),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                   timestamp: now.addingTimeInterval(-secondsAgo))
    }

    // MARK: - Only a position by handleFix's rules

    func testAnAccurateFreshOneShotIsAPositionAsAPolledFixIs() {
        XCTAssertTrue(LocationService.passesPositionRules(fix(), acceptedAccuracy: limit, now: now))
        XCTAssertTrue(LocationService.passesPositionRules(fix(accuracy: limit), acceptedAccuracy: limit, now: now),
                      "at the limit")
    }

    /// A request that times out hands back its roughest fresh fix, and with
    /// Precise Location off every fix is kilometre-scale: held for the
    /// check-in (it is what the send already gave the circle), never published.
    func testACoarseOneShotIsNeverPublished() {
        let coarse = fix(accuracy: limit + 1)
        XCTAssertFalse(LocationService.passesPositionRules(coarse, acceptedAccuracy: limit, now: now))
        XCTAssertFalse(LocationService.passesPositionRules(fix(accuracy: -1), acceptedAccuracy: limit, now: now),
                       "an invalid accuracy is the roughest there is")
        XCTAssertTrue(LocationService.adopts(coarse, held: nil, tracking: true, now: now), "still the check-in's")
    }

    /// Core Location's cache, which a timed-out request can hand back: past
    /// `handleFix`'s stale-fix limit it is no position there, nor here.
    func testACachedOneShotIsNeverPublished() {
        let limitAge = TimeInterval(LocationService.staleFixAgeLimitSeconds)
        XCTAssertTrue(LocationService.passesPositionRules(fix(secondsAgo: limitAge), acceptedAccuracy: limit, now: now))
        XCTAssertFalse(LocationService.passesPositionRules(fix(secondsAgo: limitAge + 1), acceptedAccuracy: limit, now: now))
    }

    // MARK: - The arrival it was waiting for

    /// Send location 30 m from an own destination: published, and inside the
    /// radius `checkAutoArrival` arrives at, so the arrival goes on that fix
    /// rather than at the next poll's.
    func testASendNowAtTheDestinationArrivesWithoutWaitingForAPoll() {
        let sendNow = fix(northOfDestinationBy: 30)
        XCTAssertTrue(LocationService.passesPositionRules(sendNow, acceptedAccuracy: limit, now: now))
        XCTAssertLessThanOrEqual(sendNow.distance(from: destination), DestinationsManager.arrivalRadiusMeters)
        // And one outside the radius is no arrival, published or not.
        XCTAssertGreaterThan(fix(northOfDestinationBy: 150).distance(from: destination),
                             DestinationsManager.arrivalRadiusMeters)
    }

    /// A coarse fix whose coordinate happens to sit on the destination: the
    /// radius alone would take it, so the gate is what keeps it from faking an
    /// arrival.
    func testACoarseSendNowAtTheDestinationIsNoArrival() {
        let coarse = fix(northOfDestinationBy: 0, accuracy: 1_500)
        XCTAssertLessThanOrEqual(coarse.distance(from: destination), DestinationsManager.arrivalRadiusMeters)
        XCTAssertFalse(LocationService.passesPositionRules(coarse, acceptedAccuracy: limit, now: now))
    }

    // MARK: - A fix older than the one held

    /// A poll's fix taken at t=100 lands at t=105, after a send-now taken at
    /// t=103 was adopted at t=104. The held position stays the send-now's:
    /// the poll's fix is older.
    func testAPollFixOlderThanAnAdoptedOneShotIsSkipped() {
        let sendNow = fix(secondsAgo: 2)
        let poll = fix(secondsAgo: 5)
        XCTAssertTrue(LocationService.adopts(sendNow, held: fix(secondsAgo: 300), tracking: true, now: now))
        XCTAssertTrue(LocationService.isOlder(poll, than: sendNow, now: now), "taken before the held fix")
        XCTAssertFalse(LocationService.isOlder(fix(secondsAgo: 1), than: sendNow, now: now), "a later one")
        XCTAssertFalse(LocationService.isOlder(poll, than: nil, now: now), "nothing held")
    }

    /// The same fix again is not older. A stationary phone's poll hands back the
    /// cached fix it already holds, and the stale path still offers it to the
    /// gate as proof of life (no age limit there); skipping it, the phone would
    /// read as inactive once the check-in's own honesty limit ran out.
    func testTheSameFixAgainIsNotOlder() {
        let held = fix(secondsAgo: 400)
        XCTAssertFalse(LocationService.isOlder(held, than: held, now: now))
        XCTAssertFalse(LocationService.isOlder(fix(secondsAgo: 400), than: held, now: now), "an equal capture time")
    }

    /// handleFix and the visit path skip an older fix before anything moves:
    /// the held position, the stillness evidence, the local checks, the gate.
    /// The poll still offers its check-in, which carries the held fix, and such
    /// a poll is no failed poll.
    func testAnOlderFixIsSkippedBeforeAnythingMoves() throws {
        let src = try source("App/Services/LocationService.swift")
        let handleFix = try body(src, from: "    func handleFix(_ location: CLLocation, source: String) -> FixOutcome {",
                                 to: "    /// A keep-alive delivery.")
        let hint = try XCTUnwrap(handleFix.range(of: "            return .movementHint\n        }\n"))
        let skip = try XCTUnwrap(handleFix.range(of: "        guard !Self.isOlder(location, than: currentLocation, now: Date()) else {\n"
                                                 + "            Self.writeLocationDiag(\"older than the held fix src=\\(source): nothing moves\")\n"))
        let skipped = try XCTUnwrap(handleFix.range(of: "            return .older\n        }\n",
                                                    range: skip.upperBound..<handleFix.endIndex))
        let firstMove = try XCTUnwrap(handleFix.range(of: "        let minAccuracy = TrackingConfig.acceptedAccuracy(\n"))
        XCTAssertLessThanOrEqual(hint.upperBound, skip.lowerBound, "a keep-alive delivery is never a position anyway")
        XCTAssertLessThan(skipped.upperBound, firstMove.lowerBound, "before any state moves")
        // Inside it nothing moves: a fix this would have taken as a position goes to history alone.
        let inside = String(handleFix[skip.upperBound..<skipped.lowerBound])
        XCTAssertTrue(inside.contains("            if Self.passesPositionRules(location, acceptedAccuracy: activeConfig.acceptedAccuracy, now: Date()) {\n"
                                      + "                routePastHistory(location, source: source)\n            }\n"))
        for moves in ["currentLocation =", "locationUpdates.send(", "routeToSendGate(", "stillInference"] {
            XCTAssertFalse(inside.contains(moves), moves)
        }
        // The stale proof of life is still there for the same fix again.
        XCTAssertTrue(handleFix.contains("routeToSendGate(location, source: \"\\(source)/stale\", allowHistory: false)"))

        let visit = try body(src, from: "    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {",
                             to: "    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {")
        let visitSkip = try XCTUnwrap(visit.range(of: "        guard !Self.isOlder(location, than: currentLocation, now: Date()) else {\n"
                                                  + "            Self.writeLocationDiag(\"older than the held fix src=visit: nothing moves\")\n"))
        let visitSkipped = try XCTUnwrap(visit.range(of: "            return\n        }\n", range: visitSkip.upperBound..<visit.endIndex))
        let visitInside = String(visit[visitSkip.upperBound..<visitSkipped.lowerBound])
        XCTAssertTrue(visitInside.contains("            routePastHistory(location, source: \"visit\")\n"))
        for moves in ["currentLocation =", "locationUpdates.send(", "routeToSendGate("] {
            XCTAssertFalse(visitInside.contains(moves), moves)
        }
        let visitHeld = try XCTUnwrap(visit.range(of: "        currentLocation = location\n"))
        XCTAssertLessThanOrEqual(visitSkipped.upperBound, visitHeld.lowerBound, "before the held position moves")

        let poll = try body(src, from: "    private func requestOneShotFix(reason: String) {", to: "    enum FixOutcome: Equatable {")
        XCTAssertTrue(poll.contains("if outcome != .accepted, outcome != .stale, outcome != .departure,\n"
                                    + "               self.livenessTimer == nil {"),
                      "a poll whose fix was older offers the check-in, with the held fix")
        let record = try body(src, from: "    private func recordPollOutcome(", to: "    private func resetPollBackoff(")
        XCTAssertTrue(record.contains("        case .some(.stale), .some(.movementHint), .some(.older):\n            break"),
                      "and is no failed poll")
        XCTAssertEqual(record.components(separatedBy: ".older").count - 1, 1, "nowhere else in it")
    }

    // MARK: - A late point: history alone, never the live latest

    /// A late visit (or a poll's fix older than the one held) is still a true
    /// past position. Where the gate would file it in history it goes there as a
    /// history-only point with its own time, never a live one: the server keeps
    /// the last row INSERTED as the latest, so a live late point would become
    /// the circle's latest position. And never a check-in, which would claim the
    /// older place as current.
    func testALateVisitGoesToHistoryAloneNeverTheLiveLatest() {
        let lastHistory = CLLocation(latitude: 37.30, longitude: -122.0090)
        let lateVisit = fix(northOfDestinationBy: 0, secondsAgo: 1_200)
        let request = LocationService.pastHistoryRequest(
            for: lateVisit, lastHistorySent: lastHistory, distanceThresholdMeters: 50,
            lastUploadAt: now.addingTimeInterval(-600), now: now)
        XCTAssertEqual(request?.mode, .pastHistory)
        XCTAssertEqual(request?.location.timestamp, lateVisit.timestamp)
        XCTAssertEqual(LocationService.payloadTimestamp(mode: .pastHistory, fixTimestamp: lateVisit.timestamp, now: now),
                       lateVisit.timestamp, "its own time on the wire")
        // Where the gate would only have checked in: nothing.
        XCTAssertNil(LocationService.pastHistoryRequest(
            for: lateVisit, lastHistorySent: lateVisit, distanceThresholdMeters: 50,
            lastUploadAt: now.addingTimeInterval(-600), now: now))
    }

    func testAPastPointTakesTheHistoryOnlyWire() throws {
        // Not through the throttle's coalescing, where it would displace the live request or be displaced by it.
        let circles = try source("App/Managers/CircleManager.swift")
        let enqueue = try body(circles, from: "    private func enqueueUpload(_ request: LocationService.SendRequest) {",
                               to: "    private func flushUpload() {")
        let bypass = try XCTUnwrap(enqueue.range(of: "        if request.mode == .pastHistory {\n"
                                                 + "            Task { await syncLocation(request.location, mode: .pastHistory) }\n"
                                                 + "            return\n        }\n"))
        let coalesce = try XCTUnwrap(enqueue.range(of: "pendingSendRequest = Self.coalesceSendRequests("))
        XCTAssertLessThan(bypass.upperBound, coalesce.lowerBound)
        XCTAssertTrue(circles.contains("            case .pastHistory:\n"
                                       + "                try? SDKLocationStreamer.shared.sendPastHistory(circleId: targetId, location: sdkLocation)"))
        // The streamer: `history_only` on the wire, and none of a live send's bookkeeping.
        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let past = try body(streamer, from: "    func sendPastHistory(circleId: String, location: PingolinTrackSDK.Location) throws {",
                            to: "    func send(circleId: String, location: PingolinTrackSDK.Location, kind: SendKind, capturedAt: Date? = nil) throws {")
        XCTAssertTrue(past.contains("try sendInner(circleId: circleId, location: location, kind: .keptHistory)"))
        for live in ["lastSendLocationMs", "SelfLocationStore.save", "onSendSucceeded", "noteSendQueued"] {
            XCTAssertFalse(past.contains(live), live)
        }
        XCTAssertTrue(streamer.contains("            case .keptHistory:\n                try manager.sendEnvelopeHistoryLocation("))
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

    func testAnAdoptedPositionIsPublishedAndNothingIsUploaded() throws {
        let src = try source("App/Services/LocationService.swift")
        let adopt = try body(src, from: "    func adoptSentFix(_ fix: CLLocation) {",
                             to: "    /// Whether `fix` is a position by `handleFix`'s rules")
        let held = try XCTUnwrap(adopt.range(of: "        currentLocation = fix\n"))
        let gate = try XCTUnwrap(adopt.range(of:
            "        guard Self.passesPositionRules(fix, acceptedAccuracy: activeConfig.acceptedAccuracy, now: Date()) else { return }\n"))
        let published = try XCTUnwrap(adopt.range(of: "        locationUpdates.send(fix)\n"))
        XCTAssertLessThan(held.upperBound, gate.lowerBound, "held for the check-in whatever its accuracy")
        XCTAssertLessThanOrEqual(gate.upperBound, published.lowerBound, "gated, then published")
        for upload in ["routeToSendGate(", "locationSendRequests", "SDKLocationStreamer"] {
            XCTAssertFalse(adopt.contains(upload), "adopting uploads nothing: \(upload)")
        }
        // The rules are handleFix's own.
        let handleFix = try body(src, from: "    func handleFix(_ location: CLLocation, source: String) -> FixOutcome {",
                                 to: "    /// A keep-alive delivery.")
        XCTAssertTrue(handleFix.contains("let minAccuracy = TrackingConfig.acceptedAccuracy("))
        XCTAssertTrue(handleFix.contains("guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= minAccuracy else {"))
        XCTAssertTrue(handleFix.contains("if ageSec > Self.staleFixAgeLimitSeconds {"))
        // And it publishes before the gate, which is a call, not a subscriber.
        XCTAssertTrue(handleFix.contains("        locationUpdates.send(location)\n"
                                         + "        // Publish first, gate second. Everything on `locationUpdates` is local —"))
    }

    /// Every subscriber of `locationUpdates` is a local check; the uploads ride
    /// the gated stream. The one other is this device's own open SOS: every fix
    /// after its press is the alert's position, which goes out only as the
    /// alert's re-seal, never through the stream or its gates. A new subscriber
    /// fails here until it is looked at.
    func testEverythingOnLocationUpdatesIsLocal() throws {
        let subscribers: [(file: String, subject: String, next: String)] = [
            ("App/Managers/DestinationsManager.swift", "LocationService.shared.locationUpdates\n",
             "await self?.checkAutoArrival(location: location)"),
            ("App/Managers/CircleManager.swift", "locationService.locationUpdates\n",
             "await PlaceAlertEvaluator.shared.evaluateOwn("),
            ("App/Managers/PlaceManager.swift", "locationService.locationUpdates\n",
             "self?.reprioritizeMonitoredRegionsOnMovement(location)"),
            ("App/Managers/MonitoringManager.swift", "locationService.locationUpdates\n",
             "await self?.evaluateInactivityAlertsThrottled()"),
            ("App/Managers/SOSManager.swift", "locationService.locationUpdates\n",
             "Task { @MainActor in self?.offer(fix, alertId: alertId, pressAt: pressAt) }"),
        ]
        for (file, subject, next) in subscribers {
            let sink = try body(try source(file), from: subject, to: ".store(in: &")
            XCTAssertTrue(sink.contains(next), file)
            for upload in ["routeToSendGate(", "locationSendRequests", "SDKLocationStreamer", "syncLocation("] {
                XCTAssertFalse(sink.contains(upload), "\(file): \(upload)")
            }
        }
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("        locationService.locationSendRequests\n            .receive(on: DispatchQueue.main)"),
                      "the uploads' stream")

        // The sweep: who touches `locationUpdates` at all, comments aside.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("App"), includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            let uses = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                .filter { $0.contains("locationUpdates") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .count
            if uses > 0 { found[path] = uses }
        }
        XCTAssertEqual(found, [
            // The subject, handleFix's send, the visit's send, adoptSentFix's send.
            "App/Services/LocationService.swift": 4,
            "App/Managers/DestinationsManager.swift": 1,
            "App/Managers/CircleManager.swift": 1,
            "App/Managers/PlaceManager.swift": 1,
            "App/Managers/MonitoringManager.swift": 1,
            "App/Managers/SOSManager.swift": 1,
        ])
    }
}
