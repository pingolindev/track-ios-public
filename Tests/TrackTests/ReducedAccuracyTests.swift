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

/// "Precise Location: Off" — the permission downgrade that makes a user vanish
/// from their circle's map with no signal on either side unless the app looks.
///
/// WHY THIS IS WORTH TESTING
///   With reduced accuracy iOS reports `horizontalAccuracy` in kilometres, and
///   `LocationService.didUpdateLocations` rejects anything over 100 m (500 m in
///   battery saver), so EVERY fix is dropped while Settings still reports
///   "Always". Unless the app reads `accuracyAuthorization` and says so, the
///   family just watches their person stop moving.
///
///   The parts pinned here are the ones that fail SILENTLY if they drift: a
///   purpose key that does not match Info.plist makes iOS ignore the request
///   with no error, and a shared UserDefaults flag would let one prompt's
///   decline suppress the other's.
final class ReducedAccuracyTests: XCTestCase {

    // MARK: - The temporary-accuracy request

    /// THE SILENT-FAILURE TRAP. `requestTemporaryFullAccuracy(withPurposeKey:)`
    /// does NOTHING — no prompt, no error — when the key is absent from
    /// `NSLocationTemporaryUsageDescriptionDictionary`. The banner's button
    /// would then be exactly as dead as the state it exists to fix, and
    /// nothing would say so at build time or at run time.
    func testThePurposeKeyExistsInInfoPlist() throws {
        let dictionary = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSLocationTemporaryUsageDescriptionDictionary")
                as? [String: Any],
            "Info.plist has no NSLocationTemporaryUsageDescriptionDictionary, so "
            + "requestTemporaryFullAccuracy would silently do nothing")

        let purpose = try XCTUnwrap(
            dictionary[LocationService.temporaryAccuracyPurposeKey] as? String,
            "no entry for \(LocationService.temporaryAccuracyPurposeKey)")
        XCTAssertFalse(purpose.trimmingCharacters(in: .whitespaces).isEmpty,
                       "iOS shows this string to the user; an empty one is a blank prompt")
    }

    /// The prompt explains the consequence rather than restating the setting —
    /// this is the sentence that has to persuade someone to reverse a privacy
    /// choice, so it must say what they lose.
    func testThePurposeStringExplainsTheConsequence() throws {
        let dictionary = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSLocationTemporaryUsageDescriptionDictionary")
                as? [String: Any])
        let purpose = try XCTUnwrap(
            dictionary[LocationService.temporaryAccuracyPurposeKey] as? String)
        XCTAssertTrue(purpose.localizedCaseInsensitiveContains("circle"), purpose)
        XCTAssertTrue(purpose.localizedCaseInsensitiveContains("map"), purpose)
    }

    /// The three location usage strings the app relies on must still be there
    /// — an Info.plist edit that dropped one would make the app crash on first
    /// request.
    func testTheLocationUsageDescriptionsArePresent() {
        for key in [
            "NSLocationWhenInUseUsageDescription",
            "NSLocationAlwaysAndWhenInUseUsageDescription",
            "NSLocationAlwaysUsageDescription",
        ] {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            XCTAssertNotNil(value, "\(key) is missing")
            XCTAssertFalse(value?.isEmpty ?? true, "\(key) is empty")
        }
    }

    /// The two prompts are gated on separate flags. Sharing one would mean
    /// declining "Always" once also sends every later precise-location tap
    /// straight to Settings, skipping a prompt iOS would happily show.
    func testThePrecisePromptFlagIsNotTheAlwaysPromptFlag() {
        XCTAssertNotEqual(LocationService.precisePromptAttemptedKey, "location.alwaysPromptAttempted")
        // Namespaced with the rest of the location defaults so it is findable.
        XCTAssertTrue(LocationService.precisePromptAttemptedKey.hasPrefix("location."),
                      LocationService.precisePromptAttemptedKey)
    }

    // MARK: - Naming the failure

    /// Reduced accuracy and ordinary GPS noise are different problems with
    /// different remedies, and the rejection path names each one in
    /// `lastError`.
    func testReducedAccuracyAndOrdinaryNoiseAreDistinctErrors() {
        let reduced = LocationService.LocationError.reducedAccuracy.errorDescription
        XCTAssertNotNil(reduced)
        XCTAssertTrue(reduced!.localizedCaseInsensitiveContains("precise"), reduced!)

        let noisy = LocationService.LocationError
            .inaccurate(meters: 1200, limit: 100).errorDescription
        XCTAssertNotNil(noisy)
        XCTAssertTrue(noisy!.contains("1200"), noisy!)
        XCTAssertTrue(noisy!.contains("100"), noisy!)
        XCTAssertNotEqual(reduced, noisy)
    }

    /// Every case still describes itself. A `LocalizedError` whose
    /// `errorDescription` is nil falls back to a meaningless
    /// "Operation couldn't be completed".
    func testEveryLocationErrorDescribesItself() {
        let all: [LocationService.LocationError] = [
            .notAuthorized, .locationUnavailable, .geofencingNotAvailable, .timeout,
            .reducedAccuracy, .inaccurate(meters: 900, limit: 500),
        ]
        for error in all {
            let description = error.errorDescription
            XCTAssertNotNil(description, "\(error) has no description")
            XCTAssertFalse(description?.isEmpty ?? true, "\(error) has an empty description")
        }
    }

    // MARK: - The filter that drops the fixes

    /// The premise of this file, stated as arithmetic: a reduced-accuracy
    /// fix cannot pass either limit, so "Precise Location: Off" is total
    /// silence rather than a degraded feed. Apple documents reduced accuracy as
    /// roughly a 1–20 km region; anything in that range is orders of magnitude
    /// past both thresholds.
    func testAReducedAccuracyFixCannotPassEitherThreshold() {
        let highAccuracyLimit: CLLocationAccuracy = 100
        let batterySaverLimit: CLLocationAccuracy = 500
        for coarse: CLLocationAccuracy in [1_000, 3_000, 5_000, 20_000] {
            XCTAssertGreaterThan(coarse, highAccuracyLimit)
            XCTAssertGreaterThan(coarse, batterySaverLimit)
        }
        // Positive control: a real GPS fix clears both, so the assertions above
        // are about coarseness and not about the comparison being inverted.
        XCTAssertLessThan(CLLocationAccuracy(12), highAccuracyLimit)
    }

    // MARK: - Which warning the surfaces name

    /// THE DRIFT THIS PINS. The Map and Settings must name the same warning.
    /// Rendered on independent conditions (`authorizationStatus ==
    /// .authorizedWhenInUse` and `hasReducedAccuracy`), the two Settings
    /// banners would both show for "While Using" + Precise Off — two orange
    /// banners with two different call-to-actions, the blocking one second.
    /// Both surfaces resolve through this one function; these tests are what
    /// stop them separating.

    func testReducedAccuracyOutranksWhenInUse() {
        XCTAssertEqual(
            LocationPermissionWarning.resolve(
                status: .authorizedWhenInUse, hasReducedAccuracy: true),
            .reducedAccuracy,
            "the state that drops EVERY fix must outrank the one that drops only background fixes")
    }

    /// The case the banner exists for: permission still reads "Always", and
    /// the user has silently vanished from their circle's map.
    func testAlwaysWithReducedAccuracyStillWarns() {
        XCTAssertEqual(
            LocationPermissionWarning.resolve(
                status: .authorizedAlways, hasReducedAccuracy: true),
            .reducedAccuracy)
    }

    /// The only state with nothing to say. A warning here would be a permanent
    /// banner on a correctly configured device.
    func testAlwaysWithFullAccuracyWarnsAboutNothing() {
        XCTAssertNil(
            LocationPermissionWarning.resolve(
                status: .authorizedAlways, hasReducedAccuracy: false))
    }

    func testEachRemainingStatusNamesItself() {
        let expected: [(CLAuthorizationStatus, LocationPermissionWarning)] = [
            (.authorizedWhenInUse, .whenInUse),
            (.denied, .denied),
            (.restricted, .restricted),
            (.notDetermined, .notDetermined),
        ]
        for (status, warning) in expected {
            XCTAssertEqual(
                LocationPermissionWarning.resolve(status: status, hasReducedAccuracy: false),
                warning,
                "\(status.rawValue) resolved to the wrong warning")
        }
    }

    /// Settings shows its two banners on `== .whenInUse` and
    /// `== .reducedAccuracy`. Since both read one Optional, at most one can be
    /// true — stated here as the property rather than the implementation, so a
    /// future resolver returning a SET of warnings fails this test loudly
    /// instead of quietly restoring the double banner.
    func testAtMostOneBannerConditionHoldsInAnyState() {
        let statuses: [CLAuthorizationStatus] = [
            .authorizedAlways, .authorizedWhenInUse, .denied, .restricted, .notDetermined,
        ]
        for status in statuses {
            for reduced in [true, false] {
                let warning = LocationPermissionWarning.resolve(
                    status: status, hasReducedAccuracy: reduced)
                let shown = [warning == .whenInUse, warning == .reducedAccuracy]
                    .filter { $0 }.count
                XCTAssertLessThanOrEqual(
                    shown, 1,
                    "status=\(status.rawValue) reduced=\(reduced) lit \(shown) banners")
            }
        }
        // Positive control: the combination that could light both
        // banners is a state this loop actually visits and still
        // produces a warning, so the assertion above is not passing
        // because every case resolved to nil.
        XCTAssertEqual(
            LocationPermissionWarning.resolve(
                status: .authorizedWhenInUse, hasReducedAccuracy: true),
            .reducedAccuracy)
    }

    // MARK: - Spending the one-shot Always prompt

    /// iOS shows the Always dialog at most once, so the flag that records it
    /// decides forever whether "Enable Background Tracking" can raise a dialog
    /// or is a trip to Settings. It is set only from a status in which iOS
    /// actually shows that dialog (`alwaysPromptIsSpent(by:)`), never merely
    /// because the app asked.

    func testAskingFromWhenInUseSpendsTheOneShot() {
        XCTAssertTrue(LocationService.alwaysPromptIsSpent(by: .authorizedWhenInUse),
                      "escalating from a when-in-use grant is the case that DOES show the dialog")
    }

    /// The reachable path: tap past onboarding's Location page without
    /// granting, then Get Started. `requestSingleLocation()` throws
    /// `.notAuthorized` and the `try?` swallows it, so the ask happens from
    /// `.notDetermined` — a state in which iOS offers the When-In-Use dialog
    /// and never the Always one. Recording an Always attempt there would leave
    /// the user with "Background tracking is off" and no way back to a prompt.
    func testAskingFromNotDeterminedDoesNotSpendTheOneShot() {
        XCTAssertFalse(LocationService.alwaysPromptIsSpent(by: .notDetermined))
    }

    /// Nothing is displayed from any of these, so nothing may be recorded.
    func testNoOtherStatusSpendsTheOneShot() {
        for status: CLAuthorizationStatus in [.denied, .restricted, .authorizedAlways] {
            XCTAssertFalse(LocationService.alwaysPromptIsSpent(by: status),
                           "\(status.rawValue) shows no dialog, so it cannot spend the prompt")
        }
    }

    /// The key is one named constant. Its VALUE is what every existing install
    /// already has on disk — a rename would read back false for users who have
    /// long since spent their prompt, handing them a button that silently does
    /// nothing.
    func testTheAlwaysKeyKeepsItsStoredValue() {
        XCTAssertEqual(LocationService.alwaysPromptAttemptedKey, "location.alwaysPromptAttempted")
    }
}
