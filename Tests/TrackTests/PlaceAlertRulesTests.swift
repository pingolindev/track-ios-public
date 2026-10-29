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

/// Coverage for `PlaceAlertRules` — the pure decision logic behind
/// subscriber-side place alerts.
///
/// Organised around four correctness rules (1 stateful, 2 in time order, 3
/// notification wording for delayed alerts, 4 identity for de-duplication),
/// because those are what a port can silently get wrong: the geometry is
/// obvious, the state machine is not. Mirrors the Android app's equivalent
/// so the two platforms can be checked against the same expectations.
final class PlaceAlertRulesTests: XCTestCase {

    private let fence = PlaceAlertRules.PlaceGeofence(
        placeId: "place-1",
        latitude: 37.7749,
        longitude: -122.4194,
        radiusMeters: 150
    )

    /// A point `meters` north of the fence centre. 1 degree latitude ~= 111_320 m.
    private func point(northMeters: Double, at ts: Int64) -> PlaceAlertRules.Point {
        PlaceAlertRules.Point(
            latitude: fence.latitude + northMeters / 111_320.0,
            longitude: fence.longitude,
            timestamp: ts
        )
    }

    // MARK: - Geometry

    func testDistanceIsSymmetricAndRoughlyCorrect() {
        let d = PlaceAlertRules.distanceMeters(
            fence.latitude, fence.longitude,
            fence.latitude + 1000 / 111_320.0, fence.longitude
        )
        XCTAssertEqual(d, 1000, accuracy: 5)
    }

    /// The exit margin is asymmetric ON PURPOSE: you arrive at the true radius,
    /// but must get clearly clear before a departure is declared, so one noisy
    /// fix at the edge cannot produce a spurious exit AND a spurious re-entry.
    func testInsideIsAsymmetricAcrossTheExitMargin() {
        // 160 m out: beyond the 150 m radius, inside the 150+30 m exit margin.
        let lat = fence.latitude + 160 / 111_320.0

        XCTAssertFalse(
            PlaceAlertRules.isInside(geofence: fence, latitude: lat, longitude: fence.longitude, wasInside: false),
            "arrival must use the TRUE radius, or people arrive early"
        )
        XCTAssertTrue(
            PlaceAlertRules.isInside(geofence: fence, latitude: lat, longitude: fence.longitude, wasInside: true),
            "departure must clear the margin, or a single noisy fix flaps the state machine"
        )
        XCTAssertFalse(
            PlaceAlertRules.isInside(geofence: fence, latitude: lat, longitude: fence.longitude, wasInside: nil),
            "no prior state falls back to the plain radius"
        )
    }

    func testExitMarginIsClamped() {
        XCTAssertEqual(PlaceAlertRules.exitMarginMeters(radiusMeters: 10), 20)    // floored
        XCTAssertEqual(PlaceAlertRules.exitMarginMeters(radiusMeters: 150), 30)   // 20%
        XCTAssertEqual(PlaceAlertRules.exitMarginMeters(radiusMeters: 5000), 100) // capped
    }

    // MARK: - Accuracy: a fix rougher than the ring decides nothing
    //
    // The Android app's PlaceAlertRulesTest holds its rules to the same
    // expectations. The case that matters most is a member sharing an APPROXIMATE
    // (bubble) location: the sender snaps the coordinate to a grid cell and floors
    // the reported accuracy to that cell, so the snapped point must not be judged
    // against the true ring as if it were exact.

    private func ring(radius: Int) -> PlaceAlertRules.PlaceGeofence {
        PlaceAlertRules.PlaceGeofence(
            placeId: "place-1",
            latitude: fence.latitude,
            longitude: fence.longitude,
            radiusMeters: radius
        )
    }

    private func latNorth(_ meters: Double) -> Double {
        fence.latitude + meters / 111_320.0
    }

    func testCanResolveRejectsAFixWhoseOwnErrorExceedsTheRadius() {
        let g = ring(radius: 100)
        XCTAssertFalse(PlaceAlertRules.canResolve(geofence: g, accuracyMeters: 500))
        XCTAssertFalse(PlaceAlertRules.canResolve(geofence: g, accuracyMeters: 100.001))
    }

    func testCanResolveAcceptsAFixAtOrInsideTheRadius() {
        let g = ring(radius: 100)
        XCTAssertTrue(PlaceAlertRules.canResolve(geofence: g, accuracyMeters: 100))
        XCTAssertTrue(PlaceAlertRules.canResolve(geofence: g, accuracyMeters: 12))
    }

    /// The whole reason this is a per-place gate and not a global one: only rings
    /// SMALLER than the fix's own error go dark.
    func testCanResolveIsPerPlace() {
        XCTAssertFalse(PlaceAlertRules.canResolve(geofence: ring(radius: 100), accuracyMeters: 500))
        XCTAssertTrue(PlaceAlertRules.canResolve(geofence: ring(radius: 2000), accuracyMeters: 500))
    }

    /// A sender that omits accuracy must not have its watcher's alerts silently
    /// disabled. Unknown means evaluate.
    func testUnknownAccuracyEvaluates() {
        XCTAssertTrue(PlaceAlertRules.canResolve(geofence: ring(radius: 50), accuracyMeters: nil))
    }

    /// The bubble case in the numbers that ship: the smallest bubble is 1 mile
    /// (1609.344 m) and the alert dialog's smallest ring is 100 m, so a bubbled
    /// member cannot resolve an ordinary place — but a ring larger than the bubble
    /// still can, which is why the gate is not "approximate means never".
    func testSmallestBubbleGoesDarkOnAnOrdinaryRingButNotOnAHugeOne() {
        let oneMile = 1609.344
        XCTAssertFalse(PlaceAlertRules.canResolve(geofence: ring(radius: 100), accuracyMeters: oneMile))
        XCTAssertFalse(PlaceAlertRules.canResolve(geofence: ring(radius: 150), accuracyMeters: oneMile))
        XCTAssertTrue(PlaceAlertRules.canResolve(geofence: ring(radius: 5000), accuracyMeters: oneMile))
    }

    func testARoughButUsableFixWidensTheExitMarginInsteadOfDeparting() {
        let g = ring(radius: 150) // geometric margin = 30 m
        // 120 m accuracy is usable against a 150 m ring, but far rougher than 30 m.
        // At 200 m out we are past radius+30 but inside radius+120: no departure.
        XCTAssertTrue(
            PlaceAlertRules.isInside(
                geofence: g, latitude: latNorth(200), longitude: fence.longitude,
                wasInside: true, accuracyMeters: 120
            ),
            "a 120m-accurate fix 200m out must not read as a departure"
        )
        XCTAssertFalse(
            PlaceAlertRules.isInside(
                geofence: g, latitude: latNorth(200), longitude: fence.longitude,
                wasInside: true, accuracyMeters: 5
            ),
            "the same fix, precise, IS a departure"
        )
    }

    func testWideningNeverNarrows() {
        let g = ring(radius: 150)
        for d in [10.0, 149.0, 175.0, 179.0, 181.0, 400.0] {
            XCTAssertEqual(
                PlaceAlertRules.isInside(
                    geofence: g, latitude: latNorth(d), longitude: fence.longitude, wasInside: true
                ),
                PlaceAlertRules.isInside(
                    geofence: g, latitude: latNorth(d), longitude: fence.longitude,
                    wasInside: true, accuracyMeters: 0
                ),
                "accuracy 0 must not move the boundary at \(d)m"
            )
        }
    }

    /// Deliberately asymmetric: widening arrival would make people arrive
    /// early, which is a worse failure than flapping.
    func testWideningDoesNotMoveArrival() {
        XCTAssertFalse(
            PlaceAlertRules.isInside(
                geofence: ring(radius: 150), latitude: latNorth(200), longitude: fence.longitude,
                wasInside: false, accuracyMeters: 140
            ),
            "a 140m-accurate fix 200m out must not read as an arrival"
        )
    }

    // MARK: - Rule 1 / 2: stateful, in time order

    /// A first-ever fix is not a transition: it primes the state. Defaulting
    /// `was_inside` to false would report a phantom arrival on every restart
    /// inside a geofence.
    func testFirstObservationSeedsAndEmitsNoCrossing() {
        let result = PlaceAlertRules.reconcile(
            geofence: fence,
            userId: "u1",
            prior: nil,
            points: [point(northMeters: 10, at: 1_000)]
        )
        XCTAssertEqual(result?.crossings.count, 0, "a device starting inside must not be told it just arrived")
        XCTAssertEqual(result?.state.isInside, true)
        XCTAssertEqual(result?.state.lastLocationAt, 1_000)
    }

    func testDetectsEnterAndExitInTimeOrder() {
        let result = PlaceAlertRules.reconcile(
            geofence: fence,
            userId: "u1",
            prior: PlaceAlertRules.MemberPlaceState(isInside: false, lastLocationAt: 0),
            // Deliberately out of order on input; reconcile must sort.
            points: [
                point(northMeters: 500, at: 3_000),
                point(northMeters: 10, at: 2_000),
            ]
        )
        XCTAssertEqual(result?.crossings.map(\.transition), [.enter, .exit])
        XCTAssertEqual(result?.crossings.map(\.crossedAt), [2_000, 3_000])
        XCTAssertEqual(result?.state.isInside, false)
    }

    /// The watermark is what makes an overlapping batch or a replayed page safe.
    func testPointsAtOrBeforeTheWatermarkAreSkipped() {
        let prior = PlaceAlertRules.MemberPlaceState(isInside: false, lastLocationAt: 5_000)
        XCTAssertNil(
            PlaceAlertRules.reconcile(
                geofence: fence, userId: "u1", prior: prior,
                points: [point(northMeters: 10, at: 4_000), point(northMeters: 10, at: 5_000)]
            ),
            "already-accounted points must not re-drive a transition"
        )
    }

    // MARK: - Rule 3 / notification rules

    func testCompletePassThroughCollapsesToOneEntry() {
        let now: Int64 = 10_000
        let crossings = [
            PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .enter, crossedAt: 1_000),
            PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .exit, crossedAt: 2_000),
        ]
        let decisions = PlaceAlertRules.classify(crossings: crossings, finalInside: false, now: now)
        XCTAssertEqual(decisions.count, 1, "a missed enter+exit is ONE past-framed entry, not two pings")
        guard case let .passThrough(enter, exit) = decisions[0].surfacing else {
            return XCTFail("expected a passThrough surfacing")
        }
        XCTAssertEqual(enter.crossedAt, 1_000)
        XCTAssertEqual(exit.crossedAt, 2_000)
        XCTAssertEqual(decisions[0].surfacing.crossings.count, 2, "both halves must be claimable")
    }

    /// Staleness is judged on the MOST RECENT crossing a decision covers, so a
    /// visit that began hours ago but ended moments ago still surfaces.
    func testStalenessUsesTheLatestCrossingInTheDecision() {
        let now: Int64 = 10_000_000
        let threeHoursAgo = now - (3 * 60 * 60 * 1000)
        let decisions = PlaceAlertRules.classify(
            crossings: [
                PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .enter, crossedAt: threeHoursAgo),
                PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .exit, crossedAt: now - 60_000),
            ],
            finalInside: false,
            now: now
        )
        XCTAssertEqual(decisions.count, 1)
        XCTAssertFalse(decisions[0].silent, "ended a minute ago — a recent miss, worth surfacing")
    }

    func testAncientCrossingIsSilentNotDropped() {
        let now: Int64 = 10_000_000
        let decisions = PlaceAlertRules.classify(
            crossings: [
                PlaceAlertRules.Crossing(
                    placeId: "p", userId: "u", transition: .enter,
                    crossedAt: now - (5 * 60 * 60 * 1000)
                ),
            ],
            finalInside: true,
            now: now
        )
        XCTAssertTrue(decisions[0].silent, "older than the window: recorded and shown in the bell, but no push")
    }

    /// Rule 3: a delayed alert must never use live-sounding language.
    func testCopyStampsRealElapsedTime() {
        let now: Int64 = 10_000_000
        let arrival = PlaceAlertRules.Surfacing.arrival(
            crossing: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - (30 * 60 * 1000)),
            stillInside: true
        )
        let body = PlaceAlertRules.describe(
            surfacing: arrival, memberName: "Sam", placeName: "Home", now: now
        )
        XCTAssertTrue(body.contains("30 minutes ago"), "got: \(body)")
        XCTAssertTrue(body.contains("is still there"), "got: \(body)")

        let live = PlaceAlertRules.describe(
            surfacing: .arrival(
                crossing: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - 1_000),
                stillInside: true
            ),
            memberName: "Sam", placeName: "Home", now: now
        )
        XCTAssertEqual(live, "Sam arrived at Home", "inside the tolerance carries no 'ago' qualifier")
    }

    /// "you ARE still there", never "you IS still there".
    func testSelfCopyUsesSecondPersonVerb() {
        let now: Int64 = 10_000_000
        let body = PlaceAlertRules.describe(
            surfacing: .arrival(
                crossing: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - (30 * 60 * 1000)),
                stillInside: true
            ),
            memberName: "You", placeName: "Home", now: now, isSelf: true
        )
        XCTAssertTrue(body.contains("and are still there"), "got: \(body)")
        XCTAssertFalse(body.contains("is still there"), "second person, not third: \(body)")
    }

    // MARK: - "Names only" redaction
    //
    // The banner has to be able to drop the PLACE while keeping who and when,
    // so that a user who has chosen "Generic" does not read "Sam arrived at
    // Home" on the lock screen.

    func testNamesOnlyWithholdsThePlace() {
        let now: Int64 = 10_000_000
        let arrival = PlaceAlertRules.Surfacing.arrival(
            crossing: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - 1_000),
            stillInside: true
        )
        let body = PlaceAlertRules.describeNamesOnly(surfacing: arrival, memberName: "Sam", now: now)
        XCTAssertEqual(body, "Sam arrived at a place")
        XCTAssertFalse(body.contains("Home"))
    }

    func testNamesOnlyKeepsWhenItHappened() {
        // A time says nothing about who or where, and when a crossing happened is
        // exactly what a late-delivered alert exists to convey — the same argument
        // that lets NotificationStamp survive redaction.
        let now: Int64 = 10_000_000
        let stale = PlaceAlertRules.Surfacing.arrival(
            crossing: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - (30 * 60 * 1000)),
            stillInside: true
        )
        let body = PlaceAlertRules.describeNamesOnly(surfacing: stale, memberName: "Sam", now: now)
        XCTAssertTrue(body.contains("30 minutes ago"), "got: \(body)")
        XCTAssertTrue(body.contains("is still there"), "got: \(body)")
        XCTAssertFalse(body.contains("Home"))
    }

    func testNamesOnlyRedactsEverySurfacing() {
        // Departure and pass-through must not leak the place either — a redaction
        // that covers only the common shape is not a redaction.
        let now: Int64 = 10_000_000
        let departure = PlaceAlertRules.Surfacing.departure(
            crossing: .init(placeId: "p", userId: "u", transition: .exit, crossedAt: now - 1_000)
        )
        XCTAssertEqual(
            PlaceAlertRules.describeNamesOnly(surfacing: departure, memberName: "Sam", now: now),
            "Sam left a place"
        )

        let visit = PlaceAlertRules.Surfacing.passThrough(
            enter: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - (60 * 60 * 1000)),
            exit: .init(placeId: "p", userId: "u", transition: .exit, crossedAt: now - (30 * 60 * 1000))
        )
        let visitBody = PlaceAlertRules.describeNamesOnly(surfacing: visit, memberName: "Sam", now: now)
        XCTAssertFalse(visitBody.contains("Home"), "got: \(visitBody)")
        XCTAssertTrue(visitBody.contains("Sam"), "the NAME is what this level keeps: \(visitBody)")
    }

    func testNamesOnlyDiffersFromFullOnlyByThePlace() {
        // Pinned as a relationship rather than as two literals, so the redacted
        // wording cannot drift away from the thing it redacts.
        let now: Int64 = 10_000_000
        for surfacing in [
            PlaceAlertRules.Surfacing.arrival(
                crossing: .init(placeId: "p", userId: "u", transition: .enter, crossedAt: now - (30 * 60 * 1000)),
                stillInside: true
            ),
            PlaceAlertRules.Surfacing.departure(
                crossing: .init(placeId: "p", userId: "u", transition: .exit, crossedAt: now - 1_000)
            ),
        ] {
            let full = PlaceAlertRules.describe(
                surfacing: surfacing, memberName: "Sam", placeName: "Home", now: now
            )
            let redacted = PlaceAlertRules.describeNamesOnly(
                surfacing: surfacing, memberName: "Sam", now: now
            )
            XCTAssertEqual(
                full.replacingOccurrences(of: "Home", with: PlaceAlertRules.anonymousPlaceLabel),
                redacted,
                "the two wordings must differ by the place and nothing else"
            )
        }
    }

    func testSupersedeWindowReachesBackFurtherThanItReachesForward() {
        // The asymmetry IS the safety property. A push can only report a crossing
        // that already happened, so the backward reach can be generous enough to
        // cover the wait for local evaluation, while the forward one stays at clock
        // skew — symmetric at that width, a departure could take an arrival's
        // notification id and the user would never learn they arrived.
        XCTAssertGreaterThan(
            PlaceAlertRules.serverPushSupersedeWindowMs,
            PlaceAlertRules.serverPushSupersedeSkewMs
        )
        // And it must outlast the push-latency (cross-path dedupe) window,
        // because the local copy does not exist for minutes.
        XCTAssertGreaterThan(
            PlaceAlertRules.serverPushSupersedeWindowMs,
            PlaceAlertRules.crossPathDedupeWindowMs
        )
    }

    func testAgoLabelSingularises() {
        XCTAssertEqual(PlaceAlertRules.agoLabel(elapsedMs: 60_000), "1 minute ago")
        XCTAssertEqual(PlaceAlertRules.agoLabel(elapsedMs: 120_000), "2 minutes ago")
        XCTAssertEqual(PlaceAlertRules.agoLabel(elapsedMs: 3_600_000), "1 hour ago")
        XCTAssertEqual(PlaceAlertRules.agoLabel(elapsedMs: 86_400_000 * 3), "3 days ago")
    }

    // MARK: - Rule 4: identity for de-duplication

    func testLedgerIdIsStableAndDistinguishesTransitions() {
        let enter = PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .enter, crossedAt: 1_234)
        let exit = PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .exit, crossedAt: 1_234)
        XCTAssertEqual(enter.ledgerId, "p:u:enter:1234", "byte-identical to Android's ledgerId")
        XCTAssertNotEqual(enter.ledgerId, exit.ledgerId, "an enter and an exit must never share a ledger row")
    }

    // MARK: - Targeting

    private func alert(
        target: String?,
        circleId: String? = nil,
        type: PlaceAlert.AlertType = .both,
        enabled: Bool = true,
        days: [String]? = nil,
        start: String? = nil,
        end: String? = nil,
        suppressedByTarget: Bool = false
    ) -> PlaceAlert {
        PlaceAlert(
            id: "a1", placeId: "p", userId: "owner", alertType: type, isEnabled: enabled,
            targetUserId: target, activeDays: days, activeStartTime: start, activeEndTime: end,
            circleId: circleId, suppressedByTarget: suppressedByTarget
        )
    }

    // MARK: - allow_alerts_on_me: consent is checked on every evaluation
    //
    // The Android app's `PlaceAlertRulesTest` holds the same rules. Two
    // independent signals, because they fail at different times: the
    // server-computed suppression flag is anchored to the right circle but is
    // only as fresh as the last alert sync, while the per-fix flag is always
    // current but only knows the circle its fix arrived on.

    func testServerSuppressedAlertDoesNotWatchItsTarget() {
        let a = alert(target: "u1", circleId: "c1", suppressedByTarget: true)
        XCTAssertFalse(PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: true))
    }

    func testPerFixFlagBlocksBeforeTheAlertListHasCaughtUp() {
        // The window this closes: the target flips the switch and this device's
        // cached alert row still says "not suppressed" until its next sync. The
        // location itself carries the fresh posture, so it wins immediately.
        let a = alert(target: "u1", circleId: "c1")
        XCTAssertFalse(PlaceAlertRules.alertWatches(
            a, userId: "u1", targetIsInAlertCircle: true, targetAllowsAlertsOnLatestFix: false))
    }

    func testConsentBeatsTargetingForACircleWideAlert() {
        // Circle-wide alerts name nobody, so a consent check wired into the
        // targeted branch alone would let them sweep up an opted-out member.
        let a = alert(target: nil, circleId: "c1")
        XCTAssertFalse(PlaceAlertRules.alertWatches(
            a, userId: "u1", targetIsInAlertCircle: true, targetAllowsAlertsOnLatestFix: false))
        XCTAssertTrue(PlaceAlertRules.alertWatches(
            a, userId: "u1", targetIsInAlertCircle: true, targetAllowsAlertsOnLatestFix: true))
    }

    func testAbsencePermitsSoUnknownConsentNeverSilentlyDisablesAlerts() {
        // Most members have no privacy_settings row at all, and an older backend
        // omits both fields. Reading either as denial would turn the feature off
        // across the estate, and a silently disabled alert is indistinguishable
        // from a broken one.
        let a = alert(target: "u1", circleId: "c1")
        XCTAssertTrue(PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: true))
        XCTAssertTrue(PlaceAlertRules.alertWatches(
            a, userId: "u1", targetIsInAlertCircle: true, targetAllowsAlertsOnLatestFix: nil))
        XCTAssertTrue(PlaceAlertRules.alertWatches(
            a, userId: "u1", targetIsInAlertCircle: true, targetAllowsAlertsOnLatestFix: true))
    }

    func testExplicitTargetIgnoresCircleScope() {
        let a = alert(target: "u1", circleId: "c1")
        XCTAssertTrue(PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: false))
        XCTAssertFalse(PlaceAlertRules.alertWatches(a, userId: "u2", targetIsInAlertCircle: true))
    }

    /// A circle-wide alert means "everyone in THIS circle" — without the scope it
    /// fires when a coworker from an unrelated circle reaches your home.
    func testCircleWideIsScopedToItsOwnCircle() {
        let a = alert(target: nil, circleId: "c1")
        XCTAssertTrue(PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: true))
        XCTAssertFalse(PlaceAlertRules.alertWatches(a, userId: "u9", targetIsInAlertCircle: false))
    }

    /// Absence of knowledge is not knowledge of absence: an unsynced roster must
    /// not silently convert a working alert into one that matches nobody.
    func testUnknownRosterDoesNotScopeOut() {
        let a = alert(target: nil, circleId: "c1")
        XCTAssertTrue(
            PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: nil),
            "an unsynced roster must not silence a correctly configured alert"
        )
    }

    /// Android spells circle-wide as the "all" sentinel; iOS as nil. A row synced
    /// from either platform must read the same way.
    func testAndroidAllSentinelIsTreatedAsCircleWide() {
        let a = alert(target: "all", circleId: "c1")
        XCTAssertTrue(PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: true))
        XCTAssertFalse(PlaceAlertRules.alertWatches(a, userId: "u1", targetIsInAlertCircle: false))
    }

    func testDirectionOptInIsRespected() {
        let enter = PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .enter, crossedAt: 1)
        let exit = PlaceAlertRules.Crossing(placeId: "p", userId: "u", transition: .exit, crossedAt: 2)
        let arrivalOnly = alert(target: nil, type: .arrival)

        XCTAssertTrue(PlaceAlertRules.alertWants(arrivalOnly, surfacing: .arrival(crossing: enter, stillInside: true)))
        XCTAssertFalse(PlaceAlertRules.alertWants(arrivalOnly, surfacing: .departure(crossing: exit)))
        XCTAssertTrue(
            PlaceAlertRules.alertWants(arrivalOnly, surfacing: .passThrough(enter: enter, exit: exit)),
            "a pass-through IS an arrival that has since ended"
        )
    }

    func testDisabledAlertIsNotLive() {
        XCTAssertFalse(PlaceAlertRules.isAlertLive(alert(target: nil, enabled: false), at: 1_000))
    }

    /// An unparseable expiry must not silently kill the alert — a
    /// never-firing alert is indistinguishable from a broken feature.
    func testUnparseableExpiryIsTreatedAsNoExpiry() {
        var a = alert(target: nil)
        a.expiresAt = "not-a-date"
        XCTAssertTrue(PlaceAlertRules.isAlertLive(a, at: 9_999_999_999))
    }

    // MARK: - Schedule

    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// Wednesday 2026-07-22, 12:00 UTC (`date -u -d "2026-07-22 12:00" +%s`).
    private let wednesdayNoon: Int64 = 1_784_721_600_000

    func testNoScheduleAlwaysMatches() {
        XCTAssertTrue(PlaceAlertRules.isWithinSchedule(alert(target: nil), at: wednesdayNoon, calendar: utc()))
    }

    func testDayAndTimeWindowAreBothEnforced() {
        let a = alert(target: nil, days: ["wednesday"], start: "09:00", end: "17:00")
        XCTAssertTrue(PlaceAlertRules.isWithinSchedule(a, at: wednesdayNoon, calendar: utc()))

        let wrongDay = alert(target: nil, days: ["monday"], start: "09:00", end: "17:00")
        XCTAssertFalse(PlaceAlertRules.isWithinSchedule(wrongDay, at: wednesdayNoon, calendar: utc()))

        let outsideHours = alert(target: nil, days: ["wednesday"], start: "13:00", end: "17:00")
        XCTAssertFalse(PlaceAlertRules.isWithinSchedule(outsideHours, at: wednesdayNoon, calendar: utc()))
    }

    /// An overnight window belongs to the day it STARTS on, so 02:00 Thursday is
    /// matched against Wednesday's entry. iOS has no isOvernight flag, so this
    /// also proves the start > end derivation works.
    func testOvernightWindowAttributesSmallHoursToThePreviousDay() {
        let a = alert(target: nil, days: ["wednesday"], start: "22:00", end: "06:00")
        let thursday0200 = wednesdayNoon + (14 * 60 * 60 * 1000) // Thu 02:00 UTC
        XCTAssertTrue(
            PlaceAlertRules.isWithinSchedule(a, at: thursday0200, calendar: utc()),
            "02:00 Thursday belongs to Wednesday's overnight slot"
        )

        let wednesday2300 = wednesdayNoon + (11 * 60 * 60 * 1000) // Wed 23:00 UTC
        XCTAssertTrue(PlaceAlertRules.isWithinSchedule(a, at: wednesday2300, calendar: utc()))

        let wednesday1200 = wednesdayNoon
        XCTAssertFalse(
            PlaceAlertRules.isWithinSchedule(a, at: wednesday1200, calendar: utc()),
            "midday is outside a 22:00-06:00 window"
        )
    }

    func testMalformedTimeDegradesToNoConstraint() {
        let a = alert(target: nil, start: "99:99", end: nil)
        XCTAssertTrue(PlaceAlertRules.isWithinSchedule(a, at: wednesdayNoon, calendar: utc()))
    }

    // MARK: - The zone the window is written in (wire contract)

    /// `activeStartTime`/`activeEndTime` are bare wall-clock strings. The
    /// server reads them in the alert's stored time zone, which is UTC unless
    /// a client sends one, while `isWithinSchedule` above defaults to
    /// `Calendar.current` — the device zone. Without the zone on the wire the
    /// same alert has two answers, decided by which detector happened to see
    /// the crossing.
    ///
    /// The property MUST serialise as `timezone`. `APIService`'s encoder runs
    /// `.convertToSnakeCase`, which turns `timeZone` into `time_zone` — a key
    /// the server drops in silence, losing the zone just the same. This test
    /// exercises the real strategy rather than trusting that an all-lowercase
    /// name survives it.
    ///
    /// Asserted by PARSING the payload, not by matching text in it: the encoder
    /// escapes the separator in an IANA identifier (`America\/Los_Angeles`),
    /// which is valid JSON and decodes back to a plain slash, so a substring
    /// check would fail on a payload that is perfectly correct.
    func testCreateRequestSendsTheScheduleTimezone() throws {
        let body = try Self.encodedBody(Self.createRequest(timezone: "America/Los_Angeles"))
        XCTAssertEqual(body["timezone"] as? String, "America/Los_Angeles",
                       "create must serialize timezone; got \(body)")
        XCTAssertNil(body["time_zone"], "convertToSnakeCase mangled the key; got \(body)")
    }

    /// The PUT full-replaces the row, so an edit that omitted the zone would
    /// reset a correctly-zoned alert back to the 'UTC' default.
    func testUpdateRequestSendsTheScheduleTimezone() throws {
        let body = try Self.encodedBody(Self.updateRequest(timezone: "Europe/Zurich"))
        XCTAssertEqual(body["timezone"] as? String, "Europe/Zurich",
                       "update must serialize timezone; got \(body)")
        XCTAssertNil(body["time_zone"], "convertToSnakeCase mangled the key; got \(body)")
    }

    /// What `PlaceManager` actually puts in that field: the DEVICE zone, as an
    /// IANA identifier the server can resolve. A hardcoded "UTC", or an
    /// abbreviation like "PDT", gives the server no usable device zone.
    func testTheZoneSentIsTheDeviceZoneAndIsResolvable() {
        let id = PlaceManager.currentTimezoneIdentifier
        XCTAssertEqual(id, TimeZone.current.identifier)
        XCTAssertFalse(id.isEmpty)
        XCTAssertNotNil(TimeZone(identifier: id),
                        "\(id) is not an identifier the server can look up")
        // The zone identifier fits the server's 50-character
        // column.
        XCTAssertLessThanOrEqual(id.count, 50)
    }

    // MARK: - Wire fixtures

    /// Encode through `APIService`'s own strategy and read the result back as
    /// the server would, so the assertion is about the KEY and the VALUE rather
    /// than about how the encoder happened to spell them.
    private static func encodedBody(_ value: some Encodable) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func createRequest(timezone: String) -> CreatePlaceAlertRequest {
        CreatePlaceAlertRequest(
            placeId: "p1", circleId: "c1", targetUserId: nil,
            encryptedTargetUserId: EncryptedBlobRequest(nonce: "nn", ciphertext: "cc"),
            alertOnArrival: true, alertOnDeparture: false,
            activeDays: ["monday"], activeStartTime: "08:00", activeEndTime: "17:00",
            encryptedConditions: nil, clientOnly: false,
            notifyPush: true, notifyEmail: false, notifySms: false,
            isRecurring: true, expiresAt: nil, dayBucket: 20000,
            arrivalHash: "ah", departureHash: nil,
            enterTypeHash: "eh", exitTypeHash: nil,
            encryptedSchedule: nil, encryptedCooldown: nil,
            timezone: timezone
        )
    }

    private static func updateRequest(timezone: String) -> UpdatePlaceAlertRequest {
        UpdatePlaceAlertRequest(
            alertOnArrival: true, alertOnDeparture: false,
            activeDays: ["monday"], activeStartTime: "08:00", activeEndTime: "17:00",
            encryptedConditions: nil,
            notifyPush: true, notifyEmail: false, notifySms: false,
            isRecurring: true, isActive: true, expiresAt: nil,
            arrivalHash: "ah", departureHash: nil,
            enterTypeHash: "eh", exitTypeHash: nil,
            encryptedSchedule: nil, encryptedCooldown: nil,
            timezone: timezone
        )
    }
}
