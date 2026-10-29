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

/// A location upload goes to the self copy AND every eligible circle — the
/// contract the Android app follows too.
///
/// A single target (`activeCircle?.id ?? SelfKeyManager.selfCircleUuid`) would
/// send a fix to the active circle OR the self copy, never both, and never to a
/// second circle. With no active circle every fix would go to self alone:
/// "Your Location" on the web would read current while the same person's
/// roster row aged indefinitely, and the map would draw a trail segment to a
/// position hours old.
///
/// Source assertions, like `SessionExpiryRetentionTests`: what can break is the
/// targeting being edited down to a single id, and `syncLocation` is private,
/// @MainActor, and reaches CoreLocation, the SDK streamer and the keychain.
final class LocationTargetingTests: XCTestCase {

    private var source: String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("App/Managers/CircleManager.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read CircleManager.swift at \(path.path)")
            return ""
        }
        return text
    }

    private var syncLocationBody: String {
        let src = source
        guard let start = src.range(of: "private func syncLocation(") else {
            XCTFail("syncLocation not found — renamed or removed")
            return ""
        }
        let rest = src[start.upperBound...]
        guard let end = rest.range(of: "\n    // MARK:") ?? rest.range(of: "\n    private func ") else {
            return String(rest)
        }
        return String(rest[..<end.lowerBound])
    }

    /// The target selection lives in the pure `CircleManager.uploadTargets`,
    /// not in `syncLocation`, so its behaviour can be tested directly — see
    /// UploadPathTests. These assertions pin that `syncLocation` builds its
    /// list there, from EVERY circle, and that the selection keeps the same
    /// shape.
    private var uploadTargetsBody: String {
        let src = source
        guard let start = src.range(of: "nonisolated static func uploadTargets(") else {
            XCTFail("uploadTargets not found — renamed or removed")
            return ""
        }
        let rest = src[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    func testSelfIsAlwaysATarget() {
        // Unconditional: self-tracking has no per-circle "share realtime"
        // toggle, because there are no other members to share with.
        XCTAssertTrue(syncLocationBody.contains("selfId: SelfKeyManager.selfCircleUuid"),
                      "syncLocation must name the self copy as the list's seed")
        XCTAssertTrue(
            uploadTargetsBody.contains("var targets: [String] = [selfId]"),
            "the self copy must be seeded into the target list unconditionally")
    }

    func testEveryEligibleCircleIsATarget() {
        XCTAssertTrue(syncLocationBody.contains("circleIds: circles.map(\\.id)"),
                      "must consider EVERY circle, not just the active one")
        let t = uploadTargetsBody
        XCTAssertTrue(t.contains("for id in circleIds"), "every circle id must be considered")
        XCTAssertTrue(t.contains("targets.append(id)"),
                      "eligible circles must be added as targets")
    }

    func testAnUnknownPrivacyPostureFailsClosed() {
        // Matching the android heartbeat: a circle whose privacy row has not
        // loaded must NOT receive a possibly-exact fix on the assumption it is
        // allowed. `guard let ... else { continue }` is the shape.
        XCTAssertTrue(uploadTargetsBody.contains("guard let settings = privacy[id] else { continue }"),
                      "an unknown privacy posture must skip the circle, not send to it")
    }

    func testPausedAndRealtimeOffAreBothHonoured() {
        // Two separate conditions: checking only the pause deadline would
        // keep uploading to an indefinitely paused circle.
        let t = uploadTargetsBody
        XCTAssertTrue(t.contains("!settings.isPaused"), "a paused circle must be skipped")
        XCTAssertTrue(t.contains("settings.shareRealtime"),
                      "a circle with realtime sharing off must be skipped")
    }

    func testTheSendLoopsOverEveryTarget() {
        let b = syncLocationBody
        XCTAssertTrue(b.contains("for targetId in targetCircleIds"),
                      "the send must loop over every target")
        XCTAssertTrue(b.contains("send(circleId: targetId"),
                      "each target gets its own single-target envelope")
    }

    func testThereIsNoSingleTargetForm() {
        // The single-target form (`send(circleId: targetCircleId` and
        // `let targetCircleId =`) must not appear in live code; comment lines
        // are skipped.
        let b = syncLocationBody
        let live = b
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(
            live.contains("send(circleId: targetCircleId"),
            "no single-target send")
        XCTAssertFalse(
            live.contains("let targetCircleId ="),
            "no single-target selection: the targets are a LIST")
    }

    // MARK: - Liveness fan-out

    func testTheLivenessArmFansOutOverTheSameTargets() {
        // A check-in that reached self alone would leave every circle roster
        // ageing while "Your Location" stayed current — the exact split the
        // target LIST above exists to prevent, back through another door.
        // One loop, both arms inside it.
        let b = syncLocationBody
        XCTAssertTrue(b.contains("for targetId in targetCircleIds"),
                      "the send must still loop over every target")
        XCTAssertTrue(b.contains("sendLiveness(circleId: targetId"),
                      "a liveness check-in must go to every target, not just self")
    }

    func testTheModeDecidesTheCallAndNothingElse() {
        // The privacy gates, the target list and the envelope are shared. If a
        // second target-selection ever grows inside the liveness arm, the two
        // kinds of send will drift apart silently.
        let b = syncLocationBody
        XCTAssertEqual(
            b.components(separatedBy: "for targetId in targetCircleIds").count - 1, 1,
            "there must be exactly ONE fan-out loop, shared by both send kinds")
        XCTAssertEqual(
            b.components(separatedBy: "Self.uploadTargets(").count - 1, 1,
            "there must be exactly ONE target list")
    }

    func testTheOutgoingTimestampGoesThroughThePolicy() {
        // The check-in has to carry the CURRENT time: the map and the inactivity
        // logic both read the decrypted timestamp, and a check-in is routinely
        // built from a fix CoreLocation had already cached. Passing
        // `location.timestamp` straight through would land "this phone is alive
        // now" stamped minutes ago.
        let b = syncLocationBody
        XCTAssertTrue(b.contains("LocationService.payloadTimestamp("),
                      "the payload timestamp must go through the send policy")
        let live = b
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(
            live.contains("timestamp: location.timestamp"),
            "the fix's own timestamp must not be passed through unconditionally")
    }
}

/// The send gate: a fix earns a HISTORY row only when the device actually moved,
/// and a device that has not moved still checks in so it stays visibly alive.
///
/// Without the gate every accepted fix would become a history row in every
/// circle at the poll cadence, moved or not — a phone on a desk overnight would
/// write the same coordinates several hundred times per circle, filling the
/// location store.
///
/// The decision is a pure static so it can be pinned here without CoreLocation
/// delegates, a timer, a live gRPC stream or a signed-in user.
final class LocationSendPolicyTests: XCTestCase {

    /// ~111 m of latitude — comfortably over the 100 m default gate.
    private let farStep = 0.001
    /// ~11 m of latitude — well under it, and the scale of ordinary GPS jitter.
    private let jitterStep = 0.0001

    private func loc(lat: Double, lng: Double = -122.0, at: Date = Date()) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            timestamp: at
        )
    }

    private var threshold: CLLocationDistance { LocationService.settingsDefaultDistanceMeters }

    /// The fixtures are only worth anything if they really do straddle the gate.
    func testTheFixturesStraddleTheThreshold() {
        let origin = loc(lat: 37.0)
        XCTAssertGreaterThan(loc(lat: 37.0 + farStep).distance(from: origin), threshold,
                             "the 'moved' fixture must clear the 100 m gate")
        XCTAssertLessThan(loc(lat: 37.0 + jitterStep).distance(from: origin), threshold,
                          "the 'jitter' fixture must fall short of the 100 m gate")
    }

    // MARK: - Moved / not moved

    func testMovingFarEnoughEarnsAHistoryRow() {
        let now = Date()
        let decision = LocationService.decideSend(
            candidate: loc(lat: 37.0 + farStep),
            lastHistorySent: loc(lat: 37.0),
            distanceThresholdMeters: threshold,
            historyAllowed: true,
            lastUploadAt: now,          // seconds ago: history is NOT rate-limited
            now: now
        )
        XCTAssertEqual(decision, .history)
    }

    func testStandingStillEarnsALivenessCheckInInstead() {
        let now = Date()
        let decision = LocationService.decideSend(
            candidate: loc(lat: 37.0 + jitterStep),
            lastHistorySent: loc(lat: 37.0),
            distanceThresholdMeters: threshold,
            historyAllowed: true,
            lastUploadAt: now.addingTimeInterval(-LocationService.livenessIntervalSeconds - 1),
            now: now
        )
        XCTAssertEqual(decision, .liveness,
                       "a phone that has not moved is alive, not silent")
    }

    func testStandingStillInsideTheCadenceSendsNothingAtAll() {
        let now = Date()
        let decision = LocationService.decideSend(
            candidate: loc(lat: 37.0 + jitterStep),
            lastHistorySent: loc(lat: 37.0),
            distanceThresholdMeters: threshold,
            historyAllowed: true,
            lastUploadAt: now.addingTimeInterval(-60),   // one poll ago
            now: now
        )
        XCTAssertNil(decision,
                     "a stationary phone must not check in on every poll — that is the row volume this change exists to remove")
    }

    func testTheFirstFixOfASessionAlwaysAnchorsTheTrail() {
        let decision = LocationService.decideSend(
            candidate: loc(lat: 37.0),
            lastHistorySent: nil,
            distanceThresholdMeters: threshold,
            historyAllowed: true,
            lastUploadAt: nil,
            now: Date()
        )
        XCTAssertEqual(decision, .history,
                       "with nothing sent yet there is no 'has not moved' to speak of")
    }

    func testMovementIsMeasuredFromTheLastSENTPositionNotTheLastFix() {
        // Three sub-threshold steps in a row, each ~11 m from the one before but
        // ~33 m from where the trail was last anchored. Measuring against the
        // PREVIOUS FIX would say "not moved" forever and let a slow walk cross a
        // city without a single row.
        let now = Date()
        let anchor = loc(lat: 37.0)
        let drifted = loc(lat: 37.0 + jitterStep * 12)   // ~133 m from the anchor
        XCTAssertGreaterThan(drifted.distance(from: anchor), threshold)
        let decision = LocationService.decideSend(
            candidate: drifted,
            lastHistorySent: anchor,
            distanceThresholdMeters: threshold,
            historyAllowed: true,
            lastUploadAt: now,
            now: now
        )
        XCTAssertEqual(decision, .history)
    }

    func testHistoryIsNeverRateLimitedByTheCheckInCadence() {
        // A moving device's history is never held back by the check-in
        // cadence: the saving comes from suppressing STATIONARY sends and
        // nothing else.
        let now = Date()
        let decision = LocationService.decideSend(
            candidate: loc(lat: 37.0 + farStep),
            lastHistorySent: loc(lat: 37.0),
            distanceThresholdMeters: threshold,
            historyAllowed: true,
            lastUploadAt: now.addingTimeInterval(-1),
            now: now
        )
        XCTAssertEqual(decision, .history)
    }

    func testAHistorySendAlsoResetsTheCheckInClock() {
        // A history row refreshes the latest-position table too, so it proves
        // liveness just as well. One clock for both is what stops a device that
        // has only just stopped moving from stacking a check-in on top of the
        // row it sent seconds ago.
        let now = Date()
        let justSent = now.addingTimeInterval(-2)
        XCTAssertNil(
            LocationService.decideSend(
                candidate: loc(lat: 37.0 + jitterStep),
                lastHistorySent: loc(lat: 37.0),
                distanceThresholdMeters: threshold,
                historyAllowed: true,
                lastUploadAt: justSent,
                now: now
            ),
            "the check-in clock must count from the last upload of EITHER kind")
    }

    func testADeviceThatHasNeverUploadedChecksInImmediately() {
        XCTAssertEqual(
            LocationService.decideSend(
                candidate: loc(lat: 37.0),
                lastHistorySent: loc(lat: 37.0),
                distanceThresholdMeters: threshold,
                historyAllowed: true,
                lastUploadAt: nil,
                now: Date()
            ),
            .liveness)
    }

    func testATickThatLandsAHairEarlyStillChecksIn() {
        // In battery-saver mode the poll period IS the check-in cadence — both
        // 300 s — so a Timer firing milliseconds early would fail a bare `>=`
        // and push the check-in to the next tick, silencing a battery-saving
        // phone for ten minutes, then twenty.
        let now = Date()
        let almost = LocationService.livenessIntervalSeconds - 1
        XCTAssertLessThan(1, LocationService.livenessIntervalToleranceSeconds,
                          "the tolerance must cover ordinary timer jitter")
        XCTAssertEqual(
            LocationService.decideSend(
                candidate: loc(lat: 37.0),
                lastHistorySent: loc(lat: 37.0),
                distanceThresholdMeters: threshold,
                historyAllowed: true,
                lastUploadAt: now.addingTimeInterval(-almost),
                now: now
            ),
            .liveness)
    }

    // MARK: - The stale cached fix

    func testAStaleFixCanProveLifeButNeverAnchorsTheTrail() {
        // A stationary phone's one-shot returns the fix CoreLocation already had
        // — that is WHY it is stale — so its coordinates are current and its
        // timestamp is not. Barred from history, still good for a check-in.
        // Without this a stationary phone would go dark, which is the opposite
        // of the point.
        let now = Date()
        let decision = LocationService.decideSend(
            candidate: loc(lat: 37.0 + farStep),      // would clear the gate
            lastHistorySent: loc(lat: 37.0),
            distanceThresholdMeters: threshold,
            historyAllowed: false,
            lastUploadAt: now.addingTimeInterval(-LocationService.livenessIntervalSeconds - 1),
            now: now
        )
        XCTAssertEqual(decision, .liveness,
                       "a fix with an untrustworthy timestamp must not become a trail point")
    }

    func testAStaleFixInsideTheCadenceIsStillSuppressed() {
        let now = Date()
        XCTAssertNil(
            LocationService.decideSend(
                candidate: loc(lat: 37.0 + farStep),
                lastHistorySent: loc(lat: 37.0),
                distanceThresholdMeters: threshold,
                historyAllowed: false,
                lastUploadAt: now.addingTimeInterval(-10),
                now: now
            ))
    }

    // MARK: - The timestamp on the wire

    func testACheckInCarriesTheCurrentTimeNotTheFixTime() {
        let now = Date()
        let cached = now.addingTimeInterval(-9 * 60)
        XCTAssertEqual(
            LocationService.payloadTimestamp(mode: .liveness, fixTimestamp: cached, now: now),
            now,
            "a check-in stamped with the cached fix's time lands looking as old as the fix")
    }

    func testAHistoryRowKeepsTheMomentTheDeviceWasActuallyThere() {
        let now = Date()
        let fixTime = now.addingTimeInterval(-12)
        XCTAssertEqual(
            LocationService.payloadTimestamp(mode: .history, fixTimestamp: fixTime, now: now),
            fixTime,
            "a trail point belongs where and when the device was, not when it uploaded")
    }

    // MARK: - The default poll interval

    func testAnUntouchedPickerPollsAtSixtySecondsNotThirty() {
        // `@AppStorage("location.intervalSec") … = 60` in SettingsView is a
        // READ-side default that writes nothing to UserDefaults until the picker
        // is touched, so on a device where nobody touched it the stored value is
        // absent and this fallback is what actually runs. It must match the 60 s
        // the picker shows, or every such device polls at a rate nobody chose.
        XCTAssertEqual(
            LocationService.resolvedPollIntervalSeconds(
                stored: nil,
                unsetDefault: LocationService.TrackingConfig.highAccuracy.pollIntervalSeconds),
            60)
    }

    func testTheHighAccuracyFallbackTracksTheSettingsDefault() {
        // Read FROM the settings default rather than restated, so the screen and
        // the fallback cannot drift apart.
        XCTAssertEqual(
            LocationService.TrackingConfig.highAccuracy.pollIntervalSeconds,
            TimeInterval(LocationService.settingsDefaultIntervalSeconds))
    }

    func testAnExplicitChoiceIsHonouredWhateverItIs() {
        // Someone who deliberately picks 30 s asked for 30 s: only an absent
        // value falls back, never a stored choice.
        for chosen in [10, 30, 60, 300, 600, 900] {
            XCTAssertEqual(
                LocationService.resolvedPollIntervalSeconds(
                    stored: chosen,
                    unsetDefault: LocationService.TrackingConfig.highAccuracy.pollIntervalSeconds),
                TimeInterval(chosen),
                "the picker offers \(chosen)s and it must be used verbatim")
        }
    }

    func testAStoredZeroIsNotReadAsAUserChoice() {
        // `UserDefaults.integer(forKey:)` answers 0 for an ABSENT key and for a
        // key explicitly set to 0, so it cannot tell "nobody chose" from
        // "somebody stored zero". The resolver takes an `Int?` from
        // `object(forKey:)` precisely so those are separate branches; a stored 0
        // is not a value the picker can produce, so it is treated as no choice
        // rather than as a zero-second timer.
        XCTAssertEqual(
            LocationService.resolvedPollIntervalSeconds(
                stored: 0,
                unsetDefault: LocationService.TrackingConfig.highAccuracy.pollIntervalSeconds),
            60)
        XCTAssertEqual(
            LocationService.resolvedPollIntervalSeconds(
                stored: -5,
                unsetDefault: LocationService.TrackingConfig.highAccuracy.pollIntervalSeconds),
            60)
    }

    func testBatterySaverKeepsItsOwnSlowerDefault() {
        // The fallback is per-MODE. Flattening every unset device to 60 would
        // have quietly cancelled battery saver's whole reason to exist.
        XCTAssertEqual(LocationService.TrackingConfig.batterySaver.pollIntervalSeconds, 300)
        XCTAssertEqual(
            LocationService.resolvedPollIntervalSeconds(
                stored: nil,
                unsetDefault: LocationService.TrackingConfig.batterySaver.pollIntervalSeconds),
            300)
    }

    // MARK: - The send gate's distance threshold

    func testTheSendGateDefaultsToTheDistanceTheSettingsScreenAdvertises() {
        XCTAssertEqual(LocationService.resolvedSendDistanceMeters(stored: nil), 100)
        XCTAssertEqual(LocationService.resolvedSendDistanceMeters(stored: 0), 100)
    }

    func testTheSendGateHonoursAChosenDistance() {
        for chosen in [50, 100, 250, 500] {
            XCTAssertEqual(LocationService.resolvedSendDistanceMeters(stored: chosen),
                           CLLocationDistance(chosen))
        }
    }

    func testTheSendGateIsNotTheCoreLocationDeliveryTrigger() {
        // The keep-alive request's filter is a DELIVERY trigger for fixes that
        // are never positions (movement hints only, whatever their accuracy);
        // the send gate measures ACCEPTED fixes against the last SENT position.
        // They must not share a definition: the gate is read from Settings, the
        // filter is a constant (the hint threshold, 500 m), and reusing a
        // delivery trigger as the gate would let jitter read as movement.
        XCTAssertEqual(LocationService.keepAliveDistanceFilter, LocationService.coarseMoveMeters)
        XCTAssertNotEqual(LocationService.keepAliveDistanceFilter, LocationService.settingsDefaultDistanceMeters)
        XCTAssertGreaterThanOrEqual(LocationService.keepAliveAccuracy, kCLLocationAccuracyKilometer,
                                    "the keep-alive must stay coarse enough to leave the GPS off")
        XCTAssertEqual(LocationService.resolvedSendDistanceMeters(stored: nil),
                       LocationService.settingsDefaultDistanceMeters)
    }

    // MARK: - The wiring, asserted at the source

    private var locationServiceSource: String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("App/Services/LocationService.swift")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            XCTFail("could not read LocationService.swift at \(path.path)")
            return ""
        }
        return text
    }

    func testTheStillMotionStateIsWiredIntoTheCheckInCadence() {
        // Settling (`.still`) is exactly the moment the check-in clock
        // starts mattering, so it must reach the check-in path.
        let src = locationServiceSource
        // Both non-moving states, each on its own arm since the stream profile
        // split them (still anchors and downshifts, unknown waits for the fixes).
        for state in ["still", "unknown"] {
            XCTAssertTrue(src.contains("requestLivenessCheckIn(reason: \"motion=\(state)\")"),
                          "the \(state) motion state must reach the check-in path")
        }
    }

    func testAStaleFixIsRoutedToTheGateBeforeBeingDropped() {
        let src = locationServiceSource
        XCTAssertTrue(
            src.contains("routeToSendGate(location, source: \"\\(source)/stale\", allowHistory: false)"),
            "a stale cached fix must still be able to prove the phone is alive")
    }

    func testVisitsStillReachTheUploader() {
        // A visit is the one fix that skips `handleFix`, and the uploader
        // listens on the gated stream rather than on `locationUpdates`.
        // Without this line an arrival or departure would fire place alerts
        // locally and never reach the server at all.
        let src = locationServiceSource
        guard let visit = src.range(of: "func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit)") else {
            XCTFail("didVisit not found — renamed or removed")
            return
        }
        // Up to the next delegate method, not a fixed character count: a guard
        // added at the top of the body is not a reason for this to fail.
        let rest = src[visit.upperBound...]
        let end = rest.range(of: "func locationManager(")?.lowerBound ?? rest.endIndex
        let body = String(rest[..<end])
        XCTAssertTrue(body.contains("routeToSendGate(location, source: \"visit\""),
                      "visits must still reach the uploader")
        XCTAssertTrue(body.contains("locationUpdates.send(location)"),
                      "visit publishing itself must stay untouched")
    }

    func testTheKeepAliveRequestRunsInTheBackgroundInBothModes() {
        // The phone keeps LOOKING at its position — at Android's cadence, see
        // PollProfileTests — and only the SEND is evaluated. What must not
        // change is background delivery: without it nothing runs while the app
        // is off screen, and the gate has nothing to evaluate.
        XCTAssertTrue(LocationService.TrackingConfig.highAccuracy.allowsBackgroundUpdates)
        XCTAssertTrue(LocationService.TrackingConfig.batterySaver.allowsBackgroundUpdates)
        XCTAssertEqual(LocationService.TrackingConfig.highAccuracy.acceptedAccuracy, 100)
        XCTAssertEqual(LocationService.TrackingConfig.batterySaver.acceptedAccuracy, 500)
    }
}
