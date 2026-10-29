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
import Security
@testable import Track

/// The polling model — the Android app's, knob for knob: 20 s moving, 30 s with
/// no motion opinion, five minutes still, stretched by the battery tiers, with
/// the receiver off in between.
///
/// WHY THIS IS WORTH TESTING
///   A continuous stream at kCLLocationAccuracyBest with auto-pause off (kept
///   that way so the process stays resident) can take three quarters of the
///   battery in seven hours of "Background Activity".
///
///   The rules pinned here are the ones whose drift would be silent: the
///   cadences and tiers (a constant edited back to "continuous" costs a night
///   and a battery graph to notice), the profile decision, the inference that
///   seeds stillness when motion has no opinion, and the constants that decide
///   whether the receiver is actually off between polls.
final class PollProfileTests: XCTestCase {
    typealias Inference = LocationService.StillInference
    typealias Tier = LocationService.BatteryTier

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = CLLocationCoordinate2D(latitude: 37.69886, longitude: -121.04644)

    /// A fix `metersEast` of the origin. Distances are then computed by Core
    /// Location itself, so the tests assert the rule, not a hand-rolled haversine.
    private func fix(_ metersEast: Double, accuracy: CLLocationAccuracy = 10) -> CLLocation {
        let metersPerDegree = 111_320 * cos(origin.latitude * .pi / 180)
        return CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: origin.latitude,
                longitude: origin.longitude + metersEast / metersPerDegree),
            altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
            timestamp: t0)
    }

    private func poll(
        _ profile: LocationService.PollProfile,
        tier: Tier = .normal,
        user: TimeInterval = 60,
        saver: Bool = false,
        emergency: Bool = false,
        backoff: Double = 1
    ) -> TimeInterval {
        LocationService.pollInterval(
            profile: profile, batterySaver: saver, batteryTier: tier, userInterval: user,
            emergency: emergency, backoffMultiplier: backoff)
    }

    // MARK: - Android's constants, pinned

    func testTheCadencesAndTiersAreAndroids() {
        // The Android app's LocationTrackingService.kt: POLL_MOVING_MS 20 s,
        // POLL_UNKNOWN_MS 30 s, POLL_STILL_MS 5 min, MIN_POLL_MS 10 s,
        // MAX_POLL_MS 30 min, BATTERY_MID/LOW_THRESHOLD 50/20, POLL_MULT 2/4,
        // LIVENESS_CHECKIN_INTERVAL 5 min and 3x that in battery saver.
        XCTAssertEqual(LocationService.pollMovingSeconds, 20)
        XCTAssertEqual(LocationService.pollUnknownSeconds, 30)
        XCTAssertEqual(LocationService.pollStillSeconds, 300)
        XCTAssertEqual(LocationService.minPollSeconds, 10)
        XCTAssertEqual(LocationService.maxPollSeconds, 1800)
        XCTAssertEqual(LocationService.batteryMidThresholdPercent, 50)
        XCTAssertEqual(LocationService.batteryLowThresholdPercent, 20)
        XCTAssertEqual(Tier.normal.pollMultiplier, 1)
        XCTAssertEqual(Tier.mid.pollMultiplier, 2)
        XCTAssertEqual(Tier.low.pollMultiplier, 4)
        XCTAssertEqual(LocationService.livenessIntervalSeconds, 300)
        XCTAssertEqual(LocationService.livenessBatterySaverIntervalSeconds, 900)
        // Android's battery saver is a flat BALANCED subscription at the batch
        // interval, 15 minutes by default — never "no subscription": "skips
        // streaming" in its LocationTrackingService is about the UPLOAD stream.
        XCTAssertEqual(LocationService.pollBatterySaverSeconds, 900)
    }

    // MARK: - Battery tier (Android computeBatteryTier)

    func testTheTierThresholds() {
        XCTAssertEqual(Tier.tier(levelPercent: 50, isCharging: false), .normal)
        XCTAssertEqual(Tier.tier(levelPercent: 49, isCharging: false), .mid)
        XCTAssertEqual(Tier.tier(levelPercent: 20, isCharging: false), .mid)
        XCTAssertEqual(Tier.tier(levelPercent: 19, isCharging: false), .low)
        XCTAssertEqual(Tier.tier(levelPercent: nil, isCharging: false), .normal,
                       "an unknown level is not licence to slow down")
        XCTAssertEqual(Tier.tier(levelPercent: 5, isCharging: true), .normal,
                       "charging forces normal regardless of level")
    }

    func testLowPowerModeAndHeatForceTheLowTier() {
        // Low Power Mode and heat both count, so a user who switches Low Power
        // Mode on at 80% does not keep the full cadence.
        XCTAssertEqual(Tier.tier(levelPercent: 80, isCharging: false, lowPowerMode: true), .low)
        XCTAssertEqual(Tier.tier(levelPercent: 80, isCharging: false, thermalSerious: true), .low)
        XCTAssertEqual(Tier.tier(levelPercent: 5, isCharging: true, lowPowerMode: true), .low,
                       "the user's explicit request outranks the charger")
        XCTAssertEqual(Tier.tier(levelPercent: 90, isCharging: true, thermalSerious: true), .low,
                       "a hot phone on a charger is still a hot phone")
        XCTAssertEqual(Tier.tier(levelPercent: 80, isCharging: false, lowPowerMode: false, thermalSerious: false),
                       .normal)
        XCTAssertEqual(poll(.still, tier: Tier.tier(levelPercent: 90, isCharging: false, lowPowerMode: true)), 1200,
                       "Low Power Mode stretches the still poll 4x")
    }

    // MARK: - Poll interval (Android computePollIntervalMs)

    func testTheBaseCadences() {
        XCTAssertEqual(poll(.moving), 20)
        XCTAssertEqual(poll(.unknown), 30)
        XCTAssertEqual(poll(.still), 300)
    }

    func testTheBatteryTiersStretchThePoll() {
        // `user: 0` — no interval chosen — so the cap below cannot mask the tier.
        XCTAssertEqual(poll(.moving, tier: .mid, user: 0), 40)
        XCTAssertEqual(poll(.moving, tier: .low, user: 0), 80)
        XCTAssertEqual(poll(.still, tier: .mid), 600)
        XCTAssertEqual(poll(.still, tier: .low), 1200)
    }

    func testTheUsersIntervalCapsThePollExceptWhileStill() {
        XCTAssertEqual(poll(.moving, user: 10), 10)
        XCTAssertEqual(poll(.unknown, user: 10), 10)
        XCTAssertEqual(poll(.moving, tier: .low, user: 60), 60, "the cap applies after the tier")
        XCTAssertEqual(poll(.moving, user: 900), 20, "a longer choice never slows the poll below its base")
        XCTAssertEqual(poll(.still, user: 60), 300,
                       "a fix from five minutes ago describes the same place; capping still costs a 5x GPS duty cycle")
        XCTAssertEqual(poll(.still, user: 10), 300)
        XCTAssertEqual(poll(.moving, user: 0), 20, "no choice is no cap")
    }

    func testTheClamp() {
        XCTAssertEqual(poll(.moving, user: 5), LocationService.minPollSeconds)
        XCTAssertLessThanOrEqual(poll(.still, tier: .low), LocationService.maxPollSeconds)
    }

    func testBatterySaverIsOneFlatCadenceWhateverElseIsTrue() {
        // Battery saver is one flat 15-minute cadence — Android's too — so
        // nothing here — motion, the user's interval, the battery tier, a
        // failing poll — may move it off that number.
        for profile in [LocationService.PollProfile.moving, .unknown, .still] {
            for tier in [Tier.normal, .mid, .low] {
                for user in [TimeInterval(0), 10, 60, 900] {
                    XCTAssertEqual(
                        poll(profile, tier: tier, user: user, saver: true), 900,
                        "profile=\(profile) tier=\(tier) user=\(user)")
                    XCTAssertEqual(
                        poll(profile, tier: tier, user: user, saver: true, backoff: 8), 900,
                        "backoff must not move battery saver either")
                }
            }
        }
    }

    func testBatterySaverChecksInOnThePollItAlreadyTakes() {
        // The picker's longest choice is 900 s, so in battery saver the check-in
        // cadence and the poll are the same number and a check-in rides a fix
        // the device was taking anyway — the symmetry the still cadence has at
        // five minutes. A check-in that fell between polls would re-send a
        // cached fix for no reason.
        for user in [TimeInterval(10), 60, 300, 900] {
            XCTAssertEqual(
                LocationService.livenessInterval(userInterval: user, batterySaver: true),
                poll(.still, user: user, saver: true))
        }
    }

    func testBatterySaverIsNoBusierThanAndroid() {
        // Battery saver polls no more often than Android's 900 s: at 300 s it
        // would take three times the fixes for the same result.
        XCTAssertGreaterThanOrEqual(poll(.moving, saver: true), 900)
        XCTAssertGreaterThan(poll(.moving, saver: true), poll(.still, saver: false),
                             "battery saver must be slower than the ordinary still cadence, not equal to it")
    }

    // MARK: - Liveness (Android livenessIntervalMsFor / stillRefreshCacheTooOld)

    func testTheCheckInCadenceIsTheFloorOrTheUsersIntervalWhicheverIsLonger() {
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 60, batterySaver: false), 300)
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 900, batterySaver: false), 900,
                       "a 15-minute user checks in every 15 minutes, exactly the cadence they chose")
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 0, batterySaver: false), 300)
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 60, batterySaver: true), 900,
                       "battery saver checks in more slowly but it DOES check in")
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 1200, batterySaver: true), 1200)
    }

    func testACacheOlderThanTwiceThePollIsNotDressedUpAsCurrent() {
        XCTAssertFalse(LocationService.livenessCacheTooOld(cacheAge: 599, pollInterval: 60), "ten-minute floor")
        XCTAssertTrue(LocationService.livenessCacheTooOld(cacheAge: 601, pollInterval: 60))
        XCTAssertFalse(LocationService.livenessCacheTooOld(cacheAge: 1100, pollInterval: 600))
        XCTAssertTrue(LocationService.livenessCacheTooOld(cacheAge: 1201, pollInterval: 600))
    }

    // MARK: - The profile decision

    func testMotionMovingIsFinal() {
        for held in [true, false] {
            for broken in [true, false] {
                XCTAssertEqual(
                    LocationService.desiredPollProfile(motion: .moving, held: held, anchorBrokenRecently: broken),
                    .moving, "held=\(held) broken=\(broken)")
            }
        }
    }

    func testMotionStillIsTrustedUnlessAFixJustLeftTheAnchor() {
        XCTAssertEqual(LocationService.desiredPollProfile(motion: .still, held: false, anchorBrokenRecently: false), .still)
        XCTAssertEqual(LocationService.desiredPollProfile(motion: .still, held: true, anchorBrokenRecently: false), .still)
        XCTAssertEqual(LocationService.desiredPollProfile(motion: .still, held: false, anchorBrokenRecently: true), .moving,
                       "the fixes contradict motion: the moving cadence until the phone has demonstrably settled again")
    }

    func testWithNoMotionOpinionTheFixesDecide() {
        XCTAssertEqual(LocationService.desiredPollProfile(motion: .unknown, held: false, anchorBrokenRecently: false), .unknown,
                       "the unknown cadence until the phone has demonstrably held one spot")
        XCTAssertEqual(LocationService.desiredPollProfile(motion: .unknown, held: true, anchorBrokenRecently: false), .still)
    }

    // MARK: - The receiver is actually off between polls

    func testTheKeepAliveRequestIsCoarseEnoughToPowerTheGPSDown() {
        // Core Location powers the receiver down for anything at or beyond a
        // kilometre; a keep-alive that asks for less is a continuous stream
        // under a new name.
        XCTAssertGreaterThanOrEqual(LocationService.keepAliveAccuracy, kCLLocationAccuracyKilometer)
    }

    func testTheKeepAliveOnlyDeliversMovesAHintCouldActOn() {
        // Its fixes are movement hints, and a hint needs more than
        // `coarseMoveMeters` to act; a 100 m filter would wake the process for
        // every tower handoff and, with another app's GPS on, every 100 m of
        // driving.
        XCTAssertEqual(LocationService.keepAliveDistanceFilter, LocationService.coarseMoveMeters)
        XCTAssertGreaterThanOrEqual(LocationService.keepAliveDistanceFilter, 500)
    }

    func testPollAccuracyMatchesTheEvidenceAndTheAcceptedPosition() {
        let high = LocationService.TrackingConfig.highAccuracy
        XCTAssertEqual(high.pollAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(high.stillPollAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(LocationService.TrackingConfig.highAccuracy.acceptedAccuracy, 100)
        XCTAssertEqual(LocationService.TrackingConfig.highAccuracy.stillAcceptedAccuracy, 500)
        XCTAssertEqual(LocationService.TrackingConfig.batterySaver.pollAccuracy, kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(LocationService.TrackingConfig.batterySaver.acceptedAccuracy, 500)
        XCTAssertEqual(
            LocationService.TrackingConfig.requestedAccuracy(
                profile: .still, config: high, emergency: false),
            kCLLocationAccuracyHundredMeters)
        XCTAssertEqual(
            LocationService.TrackingConfig.requestedAccuracy(
                profile: .moving, config: high, emergency: false),
            kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(
            LocationService.TrackingConfig.requestedAccuracy(
                profile: .still, config: high, emergency: true),
            kCLLocationAccuracyBest,
            "SOS keeps the best the receiver can provide")
    }

    func testSystemLowPowerModeUsesTheBatterySaverProfile() {
        XCTAssertTrue(
            LocationService.TrackingConfig.usesBatterySaver(
                userEnabled: false, systemLowPower: true),
            "iOS Low Power Mode is the user's request to save battery")
        XCTAssertTrue(
            LocationService.TrackingConfig.usesBatterySaver(
                userEnabled: true, systemLowPower: false))
        XCTAssertFalse(
            LocationService.TrackingConfig.usesBatterySaver(
                userEnabled: false, systemLowPower: false))
    }

    func testAPollCannotOutlastTheFastestTick() {
        // The fastest tick is `minPollSeconds` (10 s — a Settings choice), not
        // the 20 s moving cadence: a fixed 15 s timeout on a 10 s tick would
        // keep the receiver on 15 s of every 20.
        for interval in [LocationService.minPollSeconds, 20, 30, 60, 300, LocationService.maxPollSeconds] {
            XCTAssertLessThan(LocationService.pollTimeout(forInterval: interval), interval,
                              "a poll still running at the next tick would keep the receiver on continuously (\(interval) s)")
        }
        XCTAssertEqual(LocationService.pollTimeout(forInterval: LocationService.minPollSeconds), 8)
        XCTAssertEqual(LocationService.pollTimeout(forInterval: 300), LocationService.pollTimeoutSeconds,
                       "slow ticks keep the full 15 s to settle")
    }

    // MARK: - Backoff after unusable polls

    func testThePollBacksOffOnlyAfterThreeUnusablePollsInARow() {
        XCTAssertEqual(LocationService.pollBackoffMultiplier(consecutiveUnusable: 0), 1)
        XCTAssertEqual(LocationService.pollBackoffMultiplier(consecutiveUnusable: 2), 1)
        XCTAssertEqual(LocationService.pollBackoffMultiplier(consecutiveUnusable: 3), 2)
        XCTAssertEqual(LocationService.pollBackoffMultiplier(consecutiveUnusable: 4), 4)
        XCTAssertEqual(LocationService.pollBackoffMultiplier(consecutiveUnusable: 5), 8)
    }

    func testBackoffStretchesUpToTheStillCadenceAndNoFurther() {
        XCTAssertEqual(poll(.moving, backoff: 2), 40)
        XCTAssertEqual(poll(.unknown, backoff: 4), 120)
        XCTAssertEqual(poll(.moving, backoff: 1024), LocationService.pollStillSeconds,
                       "a subway ride polls no slower than a phone on a desk")
        XCTAssertEqual(poll(.still, backoff: 8), 300, "the still cadence is already the ceiling")
        XCTAssertEqual(poll(.still, tier: .low, backoff: 8), 1200, "backoff never SHORTENS a stretched poll")
        XCTAssertEqual(poll(.moving, user: 10, backoff: 2), 20, "the user's cap applies first, then the backoff")
    }

    // MARK: - Emergency (SOS)

    func testAnEmergencyPollsAtTheMovingCadenceWhateverElseIsTrue() {
        for profile in [LocationService.PollProfile.moving, .unknown, .still] {
            for tier in [Tier.normal, .mid, .low] {
                for saver in [false, true] {
                    XCTAssertEqual(
                        poll(profile, tier: tier, user: 60, saver: saver, emergency: true, backoff: 8), 20,
                        "profile=\(profile) tier=\(tier) saver=\(saver)")
                }
            }
        }
        XCTAssertEqual(poll(.still, user: 10, emergency: true), 10, "the user's own faster choice still holds")
    }

    func testAnEmergencyChecksInEveryMinute() {
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 900, batterySaver: true, emergency: true), 60)
        XCTAssertEqual(LocationService.livenessInterval(userInterval: 60, batterySaver: false, emergency: false), 300)
    }

    // MARK: - The check-in rides the poll

    func testTheCheckInNeedsItsOwnClockOnlyWhileThePollIsStretchedPastIt() {
        func needs(_ poll: TimeInterval, _ liveness: TimeInterval) -> Bool {
            LocationService.needsDedicatedLivenessTimer(pollInterval: poll, livenessInterval: liveness)
        }
        XCTAssertFalse(needs(20, 300), "moving: every tick offers a fix")
        XCTAssertFalse(needs(300, 300), "still: the poll IS the check-in cadence")
        XCTAssertFalse(needs(900, 900), "battery saver: the same, at 15 minutes")
        XCTAssertTrue(needs(600, 300), "still at the mid tier stretches the poll past the check-in")
        XCTAssertTrue(needs(1200, 300), "and the low tier further")
        XCTAssertTrue(needs(poll(.still, tier: .mid), LocationService.livenessInterval(userInterval: 60, batterySaver: false)))
        XCTAssertFalse(needs(poll(.still), LocationService.livenessInterval(userInterval: 60, batterySaver: false)))
        XCTAssertFalse(needs(poll(.still, saver: true), LocationService.livenessInterval(userInterval: 60, batterySaver: true)))
    }

    // MARK: - Saver-sleep trial (dev builds)

    private func shouldSleep(
        trial: Bool = true, saver: Bool = true, always: Bool = true, emergency: Bool = false,
        foreground: Bool = false,
        profile: LocationService.PollProfile = .still, stillFor: TimeInterval? = 600,
        anchor: Bool = true, regions: Bool = true
    ) -> Bool {
        LocationService.shouldEnterSaverSleep(
            trialEnabled: trial, batterySaver: saver, alwaysAuthorized: always, emergency: emergency,
            appInForeground: foreground,
            profile: profile, stillSince: stillFor.map { t0.addingTimeInterval(-$0) },
            hasAnchor: anchor, regionMonitoringAvailable: regions, now: t0)
    }

    func testASaverPhoneSleepsOnlyAfterTenStillMinutes() {
        XCTAssertTrue(shouldSleep())
        XCTAssertFalse(shouldSleep(stillFor: 599), "one second short")
        XCTAssertFalse(shouldSleep(stillFor: nil), "not still at all")
        XCTAssertFalse(shouldSleep(profile: .unknown))
        XCTAssertFalse(shouldSleep(profile: .moving))
    }

    func testEverySleepConditionIsAHardRequirement() {
        XCTAssertFalse(shouldSleep(trial: false), "App Store builds never run the trial")
        XCTAssertFalse(shouldSleep(saver: false), "only where the user already chose battery over freshness")
        XCTAssertFalse(shouldSleep(always: false), "no Always permission, no wake-up from the region")
        XCTAssertFalse(shouldSleep(emergency: true), "an SOS always keeps the phone awake")
        XCTAssertFalse(shouldSleep(foreground: true), "not while the user is looking at the map")
        XCTAssertFalse(shouldSleep(anchor: false), "nowhere to arm the exit region")
        XCTAssertFalse(shouldSleep(regions: false))
    }

    func testTheTrialIsCompiledIntoDevBuildsOnly() {
        #if DEBUG || RELEASE_DEV
        XCTAssertTrue(LocationService.saverSleepTrialEnabled)
        #else
        XCTAssertFalse(LocationService.saverSleepTrialEnabled)
        #endif
    }

    func testTheExitRegionIsTwiceTheAnchorsErrorWithinBounds() {
        XCTAssertEqual(LocationService.saverSleepRegionRadius(anchorAccuracy: 10), 150, "a GPS anchor is not a hair trigger")
        XCTAssertEqual(LocationService.saverSleepRegionRadius(anchorAccuracy: 100), 200)
        XCTAssertEqual(LocationService.saverSleepRegionRadius(anchorAccuracy: 1500), 500,
                       "a cell anchor must not let the phone drive a kilometre unnoticed")
        XCTAssertEqual(LocationService.saverSleepRegionRadius(anchorAccuracy: -1), 150)
    }

    func testEverythingButSomeoneElsesRegionWakesASleepingPhone() {
        typealias E = LocationService.SaverSleepEvent
        for event: E in [.regionExit(identifier: LocationService.saverSleepRegionIdentifier), .significantChange,
                         .visit, .motionMoving, .appBecameActive, .singleLocationRequest, .emergency, .restart] {
            XCTAssertTrue(LocationService.saverSleepShouldWake(on: event), "\(event)")
        }
        XCTAssertFalse(LocationService.saverSleepShouldWake(on: .regionExit(identifier: "a-place-id")),
                       "a place geofence says nothing about this phone leaving its anchor")
    }

    // MARK: - Still inference (Android maybeInferStill)

    func testHoldingOneSpotForThreeMinutesIsStill() {
        var inference = Inference()
        XCTAssertFalse(inference.observe(fix(0), at: t0), "the first fix is only the anchor")
        XCTAssertFalse(inference.observe(fix(5), at: t0.addingTimeInterval(60)))
        XCTAssertFalse(inference.observe(fix(12), at: t0.addingTimeInterval(179)), "one second short")
        XCTAssertTrue(inference.observe(fix(8), at: t0.addingTimeInterval(180)))
        XCTAssertTrue(inference.isHeld)
        XCTAssertFalse(inference.brokenRecently(at: t0.addingTimeInterval(180)))
    }

    func testAMovingPhoneNeverHolds() {
        var inference = Inference()
        var now = t0
        for step in 0..<10 {
            XCTAssertFalse(inference.observe(fix(Double(step) * 100), at: now), "step \(step)")
            now = now.addingTimeInterval(60)
        }
        XCTAssertFalse(inference.isHeld)
        XCTAssertTrue(inference.brokenRecently(at: now), "every fix left the previous anchor")
    }

    func testAFixThatLeavesTheAnchorBreaksTheHoldForThreeMinutes() {
        var inference = Inference()
        inference.observe(fix(0), at: t0)
        XCTAssertTrue(inference.observe(fix(3), at: t0.addingTimeInterval(180)))

        let left = t0.addingTimeInterval(240)
        XCTAssertFalse(inference.observe(fix(200), at: left))
        XCTAssertFalse(inference.isHeld)
        XCTAssertTrue(inference.brokenRecently(at: left))
        XCTAssertTrue(inference.brokenRecently(at: left.addingTimeInterval(179)))
        XCTAssertFalse(inference.brokenRecently(at: left.addingTimeInterval(180)))
        // The new spot is the anchor now: holding THERE for three minutes is still again.
        XCTAssertTrue(inference.observe(fix(204), at: left.addingTimeInterval(180)))
    }

    func testTheRadiusWidensByTheAnchorsErrorToo() {
        // A 65 m Wi-Fi anchor, then a 10 m GPS fix 55 m away: the two agree
        // within the anchor's own error. Widening by the new fix alone would
        // call that a departure and put a still phone back on the moving
        // cadence.
        XCTAssertEqual(Inference.radius(for: 10, anchorAccuracy: 65), 75)
        var inference = Inference()
        inference.observe(fix(0, accuracy: 65), at: t0)
        XCTAssertFalse(inference.brokenRecently(at: t0))
        XCTAssertTrue(inference.observe(fix(55, accuracy: 10), at: t0.addingTimeInterval(180)))
        XCTAssertFalse(inference.brokenRecently(at: t0.addingTimeInterval(180)))
        // Beyond both errors combined it is still a departure.
        XCTAssertFalse(inference.observe(fix(200, accuracy: 10), at: t0.addingTimeInterval(240)))
        XCTAssertTrue(inference.brokenRecently(at: t0.addingTimeInterval(240)))
    }

    func testTheRadiusWidensToAFixesOwnAccuracy() {
        XCTAssertEqual(Inference.radius(for: 10), Inference.radiusMeters)
        XCTAssertEqual(Inference.radius(for: 65), 65,
                       "holding a 65 m indoor fix to a 50 m anchor is an impossible test, not a strict one")
        XCTAssertEqual(Inference.radius(for: -1), Inference.radiusMeters,
                       "unknown accuracy is not licence to relax the rule")

        var loose = Inference()
        loose.observe(fix(0, accuracy: 65), at: t0)
        // 60 m away with a 65 m error is the same spot; with a 10 m error it is not.
        XCTAssertTrue(loose.observe(fix(60, accuracy: 65), at: t0.addingTimeInterval(180)))
        var strict = Inference()
        strict.observe(fix(0, accuracy: 10), at: t0)
        XCTAssertFalse(strict.observe(fix(60, accuracy: 10), at: t0.addingTimeInterval(180)))
        XCTAssertTrue(strict.brokenRecently(at: t0.addingTimeInterval(180)))
    }

    func testSeedingAnchorsWithoutCountingABreak() {
        var inference = Inference()
        inference.observe(fix(0), at: t0)
        inference.seed(fix(500), at: t0.addingTimeInterval(10))
        XCTAssertFalse(inference.brokenRecently(at: t0.addingTimeInterval(10)),
                       "where motion said the phone settled is the anchor, not a departure from the old one")
        XCTAssertFalse(inference.isHeld)
        XCTAssertTrue(inference.observe(fix(502), at: t0.addingTimeInterval(190)))
    }

    func testResetForgetsEverything() {
        var inference = Inference()
        inference.observe(fix(0), at: t0)
        inference.observe(fix(300), at: t0.addingTimeInterval(60))
        inference.reset()
        XCTAssertNil(inference.anchor)
        XCTAssertFalse(inference.isHeld)
        XCTAssertFalse(inference.brokenRecently(at: t0.addingTimeInterval(61)))
    }

    // MARK: - Coarse movement hint

    func testAKeepAliveFixCountsAsMovementOnlyBeyondItsOwnError() {
        XCTAssertTrue(LocationService.coarseFixSuggestsMovement(distanceFromAnchor: 600, accuracy: 100))
        XCTAssertFalse(LocationService.coarseFixSuggestsMovement(distanceFromAnchor: 600, accuracy: 1500),
                       "a 1.5 km cell fix 600 m away is the same tower")
        XCTAssertTrue(LocationService.coarseFixSuggestsMovement(distanceFromAnchor: 2000, accuracy: 1500))
        XCTAssertFalse(LocationService.coarseFixSuggestsMovement(distanceFromAnchor: 400, accuracy: 10))
    }

    // MARK: - Motion classification

    private func classify(
        stationary: Bool = false, walking: Bool = false, running: Bool = false,
        automotive: Bool = false, cycling: Bool = false, unknown: Bool = false, lowConfidence: Bool = false
    ) -> MotionDetectionManager.MotionState? {
        MotionDetectionManager.classify(
            stationary: stationary, walking: walking, running: running,
            automotive: automotive, cycling: cycling, unknown: unknown, lowConfidence: lowConfidence)
    }

    func testStationaryAloneIsStill() {
        XCTAssertEqual(classify(stationary: true), .still)
    }

    func testAPausedVehicleOrBikeIsStillATrip() {
        XCTAssertEqual(classify(stationary: true, automotive: true), .moving,
                       "a red light must not drop the poll to its still cadence")
        XCTAssertEqual(classify(stationary: true, cycling: true), .moving)
    }

    func testMovingNeedsAPositiveReading() {
        XCTAssertEqual(classify(walking: true), .moving)
        XCTAssertEqual(classify(running: true), .moving)
        XCTAssertEqual(classify(automotive: true), .moving)
        XCTAssertEqual(classify(cycling: true), .moving)
        // These are no opinion, not `.moving`: if every flag false fell through
        // to `.moving`, one such reading on a desk would buy a Best poll and the
        // 20 s cadence.
        XCTAssertNil(classify(), "a reading that names no activity is ignored, not applied")
        XCTAssertNil(classify(unknown: true))
        XCTAssertNil(classify(stationary: true, unknown: true), "stationary AND unknown is no opinion")
    }

    func testALowConfidenceReadingIsIgnoredNotApplied() {
        XCTAssertNil(classify(stationary: true, lowConfidence: true))
        XCTAssertNil(classify(walking: true, lowConfidence: true))
    }

    // MARK: - The wiring, asserted at the source

    /// Source assertions, in the style of LocationTargetingTests: these are
    /// one-line properties on managers built inside private paths, and each
    /// one fails SILENTLY if dropped — a keep-alive that pauses suspends the
    /// app, a poll manager without the background flag never delivers there.
    func testTheKeepAliveRequestNeverPauses() throws {
        let src = try source("App/Services/LocationService.swift")
        let body = try slice(src, from: "private func applyTrackingConfig(", to: "private func resolvedUserInterval(")
        XCTAssertTrue(body.contains("locationManager.pausesLocationUpdatesAutomatically = false"))
        XCTAssertFalse(src.contains("pausesLocationUpdatesAutomatically = true"),
                       "the system pause suspends a background app and nothing resumes updates")
    }

    func testEveryOneShotManagerMayDeliverInTheBackground() throws {
        let src = try source("App/Services/LocationService.swift")
        let request = try slice(src, from: "private final class FreshFixRequest", to: "func start()")
        XCTAssertTrue(request.contains("manager.allowsBackgroundLocationUpdates = true"),
                      "the poll's manager must deliver in the background")
        // requestSingleLocation builds no manager of its own: it runs a
        // FreshFixRequest, so the flag above covers it (push wakes and SOS run
        // with the app off screen).
        let single = try slice(src, from: "func requestSingleLocation(", to: "// MARK: - Battery Info")
        XCTAssertTrue(single.contains("FreshFixRequest("))
        XCTAssertFalse(single.contains("requestLocation()"),
                       "requestLocation() ramps towards Best whatever the fix is for")
        XCTAssertFalse(src.contains("SingleLocationDelegate"))
    }

    func testReducedAccuracySkipsThePollInsteadOfBurningItsTimeout() throws {
        let src = try source("App/Services/LocationService.swift")
        let body = try slice(src, from: "private func requestOneShotFix(", to: "enum FixOutcome")
        let guardAt = try XCTUnwrap(body.range(of: "if accuracyAuthorization == .reducedAccuracy {"))
        let startAt = try XCTUnwrap(body.range(of: "request.start()"))
        XCTAssertLessThan(guardAt.lowerBound, startAt.lowerBound,
                          "with Precise Location off no fix is ever usable, so a poll runs its whole timeout for nothing")
    }

    func testKeepAliveFixesAreHintsBeforeTheyCanBePositions() throws {
        let src = try source("App/Services/LocationService.swift")
        let body = try slice(src, from: "func handleFix(", to: "/// Per-region retry bookkeeping")
        let hint = try XCTUnwrap(body.range(of: "if source == \"stream\" {"))
        let accuracy = try XCTUnwrap(body.range(of: "guard location.horizontalAccuracy >= 0"))
        XCTAssertLessThan(hint.lowerBound, accuracy.lowerBound,
                          "an ACCURATE keep-alive delivery must not fall through to the position path")
    }

    func testACoarseStillFixConfirmsPresenceWithoutBecomingAPosition() throws {
        let src = try source("App/Services/LocationService.swift")
        let body = try slice(src, from: "func handleFix(", to: "/// Per-region retry bookkeeping")
        let presence = try XCTUnwrap(body.range(of: "if profileAtRequest == .still,"))
        let held = try XCTUnwrap(body.range(of: "currentLocation = location\n"))
        XCTAssertLessThan(presence.lowerBound, held.lowerBound,
                          "a coarse STILL fix must be handled before the precise position is replaced")
        XCTAssertTrue(body.contains("lastPresenceConfirmedAt = location.timestamp"),
                      "the coarse fix refreshes liveness evidence")
        XCTAssertTrue(body.contains("return .presence"))
        XCTAssertTrue(body.contains("return .departure"),
                      "leaving the anchor changes the next cadence without publishing cell error")
    }

    func testASignedOutLaunchDoesNotReArmSignificantChangeOrVisits() throws {
        let src = try source("App/Services/LocationService.swift")
        let body = try slice(src, from: "func wakeForBackgroundLocationDelivery()", to: "enum StoredSession")
        let absent = try XCTUnwrap(body.range(of: "case .absent:"))
        let rearm = try XCTUnwrap(body.range(of: "locationManager.startMonitoringSignificantLocationChanges()"))
        XCTAssertLessThan(absent.lowerBound, rearm.lowerBound)
        XCTAssertTrue(body.contains("locationManager.stopMonitoringVisits()"),
                      "a signed-out launch tears the persisted registrations down")
        let visit = try slice(src, from: "didVisit visit: CLVisit)", to: "// .distantFuture means")
        XCTAssertTrue(visit.contains("guard isTracking else { return }"))
    }

    func testALockedKeychainIsNotASignedOutUser() {
        // Before the first unlock after a reboot the tokens are unreadable —
        // exactly when iOS relaunches a signed-in app for SLC. Reading that as
        // "signed out" would tear their registrations down.
        XCTAssertEqual(LocationService.storedSession(fromStatuses: [errSecItemNotFound, errSecItemNotFound]), .absent)
        XCTAssertEqual(LocationService.storedSession(fromStatuses: [errSecInteractionNotAllowed, errSecItemNotFound]), .unknown)
        XCTAssertEqual(LocationService.storedSession(fromStatuses: [errSecItemNotFound, errSecSuccess]), .present)
        XCTAssertEqual(LocationService.storedSession(fromStatuses: [errSecSuccess, errSecInteractionNotAllowed]), .present)
    }

    func testTheSessionProbeAsksTheKeychainServiceTheAppWritesTo() throws {
        let keychain = try source("App/Services/KeychainService.swift")
        XCTAssertTrue(keychain.contains("private let service = \"\(LocationService.keychainService)\""),
                      "the probe must look where KeychainService stores the tokens")
    }

    func testTheTrialRegionIsHiddenFromPlaceManager() throws {
        let src = try source("App/Services/LocationService.swift")
        let places = try slice(src, from: "private var placeRegions: [CLRegion] {", to: "var monitoredCircularRegions")
        XCTAssertTrue(places.contains("Self.saverSleepRegionIdentifier"),
                      "PlaceManager removes every region it did not ask for")
        XCTAssertEqual(PlaceManager.maxMonitoredRegions, 19, "one of the 20 slots is the trial's")
    }

    func testHandleFixDoesNotBounceTheKeepAliveRequest() throws {
        let src = try source("App/Services/LocationService.swift")
        let body = try slice(src, from: "func handleFix(", to: "/// Per-region retry bookkeeping")
        XCTAssertFalse(body.contains("stopUpdatingLocation"),
                       "the keep-alive cannot produce a fresh GPS fix by design; the next poll is the retry")
        XCTAssertTrue(body.contains("routeToSendGate(location, source: \"\\(source)/stale\", allowHistory: false)"),
                      "a stale cached fix must still be able to prove the phone is alive")
    }

    func testTheTrackingKnobsReapplyToTheRunningSession() throws {
        let src = try source("App/Views/Settings/SettingsView.swift")
        for knob in ["settings.batterySaverEnabled", "locationIntervalSec", "locationDistanceMeters"] {
            XCTAssertTrue(src.contains(".onChange(of: \(knob))"), "no .onChange for \(knob)")
        }
        XCTAssertGreaterThanOrEqual(
            src.components(separatedBy: "applyTrackingSettingsChange()").count - 1, 3,
            "each knob must reach LocationService.applyTrackingSettingsChange")
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func slice(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), "\(start) not found — renamed or removed")
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), "\(end) not found after \(start)")
        return String(src[a.lowerBound..<b.lowerBound])
    }
}
