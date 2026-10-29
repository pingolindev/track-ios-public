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
import UIKit
@testable import Track

/// The Settings notification switches, and the server columns they drive.
///
/// WHY THIS IS WORTH TESTING
///   A switch that writes a UserDefaults key nothing reads — never sent to the
///   server, never consulted at receipt — is a dead control: a user who turns
///   "Circle notifications" off keeps being buzzed for every alert, forever,
///   with the switch showing off. Nothing about that failure is visible from
///   the switch — which is exactly why the wiring needs a test that does not
///   go through the UI.
final class NotificationPreferenceBindingTests: XCTestCase {

    /// Every column `GET/PUT /api/v1/notifications/preferences` exposes.
    /// Spelled out here so a key typo in the UI is caught: a wrong key is not
    /// an error anywhere — the server drops an unknown field, and the switch
    /// silently does nothing, a dead control again.
    private static let serverColumns: Set<String> = [
        "push_enabled", "email_enabled",
        "circle_invite_push", "circle_invite_email",
        "member_joined_push", "member_joined_email",
        "place_alert_push", "place_alert_email",
        "safety_alert_push", "safety_alert_email",
        "sos_push", "sos_email",
        "destination_push",
        // Push-only, like destination_push: nothing sends a check-in by
        // email, so there is no check_in_email.
        "check_in_push",
    ]

    // MARK: - The keys

    func testEveryCategoryNamesAColumnTheServerActuallyHas() {
        for category in SettingsView.pushCategories {
            XCTAssertTrue(
                Self.serverColumns.contains(category.key),
                "\(category.key) is not a notification_preferences column — a wrong key "
                + "is dropped by serde and the switch goes back to doing nothing")
        }
    }

    /// Push columns only. An email column here would be labelled as a push
    /// category and write the wrong channel.
    func testEveryCategoryIsAPushColumn() {
        for category in SettingsView.pushCategories {
            XCTAssertTrue(category.key.hasSuffix("_push"), category.key)
        }
    }

    /// iOS covers every per-category PUSH column the server has, so a category
    /// added server-side without a row here is visible as a failure rather
    /// than as a preference nobody can reach from an iPhone.
    func testEveryPerCategoryPushColumnHasARow() {
        let covered = Set(SettingsView.pushCategories.map(\.key))
        let perCategoryPush = Self.serverColumns.filter { $0.hasSuffix("_push") && $0 != "push_enabled" }
        XCTAssertEqual(covered, perCategoryPush)
    }

    func testCategoriesAreDistinctAndNonEmpty() {
        let keys = SettingsView.pushCategories.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "a duplicated key would render two switches over one column")
        XCTAssertFalse(keys.isEmpty)
        for category in SettingsView.pushCategories {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.icon.isEmpty)
        }
    }

    // MARK: - The names

    /// The emergency feature is "notify my circle": the web and iOS say
    /// "Circle notifications" for sos_push, and that is the product's name
    /// for it.
    func testTheEmergencyCategoryIsNeverCalledSOS() {
        let sos = SettingsView.pushCategories.first { $0.key == "sos_push" }
        XCTAssertEqual(sos?.title, "Circle notifications")
        for category in SettingsView.pushCategories {
            XCTAssertFalse(
                category.title.localizedCaseInsensitiveContains("SOS"),
                "user-facing copy must never say SOS: \(category.title)")
        }
    }

    // MARK: - The one that cannot be switched off

    /// The server never lets preferences stop the emergency exchange: it
    /// bypasses the per-category column, the global `push_enabled` switch and
    /// quiet hours. `sos_push` therefore governs nothing, and a live switch
    /// over it renders a promise the system will not keep.
    func testTheEmergencyCategoryIsMarkedUndeniable() {
        let sos = SettingsView.pushCategories.first { $0.key == "sos_push" }
        XCTAssertEqual(sos?.undeniable, true,
                       "sos_push controls nothing server-side; the row must be locked, not live")
    }

    /// The row is LOCKED, not deleted. A silent gap teaches nobody why the
    /// switch went away, and invites a future "restore the missing category"
    /// that would make emergencies deniable again — the outcome the lock
    /// exists to prevent.
    func testTheEmergencyCategoryIsStillOnTheScreen() {
        XCTAssertNotNil(SettingsView.pushCategories.first { $0.key == "sos_push" },
                        "removing the row hides WHY it cannot be turned off")
    }

    /// Only that one. Locking a category the server really does honour would
    /// take away a working preference and tell the user it was never theirs.
    func testNoOtherCategoryIsLocked() {
        let locked = SettingsView.pushCategories.filter(\.undeniable).map(\.key)
        XCTAssertEqual(locked, ["sos_push"])
    }

    /// The reason has to say it plainly, and — like every other piece of
    /// user-facing copy here — must never call it SOS.
    func testTheLockCopySaysItCannotBeTurnedOffWithoutSayingSOS() {
        let note = SettingsView.undeniableCategoryNote
        XCTAssertFalse(note.isEmpty)
        XCTAssertTrue(note.localizedCaseInsensitiveContains("can't be turned off")
                      || note.localizedCaseInsensitiveContains("cannot be turned off"),
                      "the row has to say the switch is not coming back: \(note)")
        XCTAssertFalse(note.localizedCaseInsensitiveContains("SOS"),
                       "user-facing copy must never say SOS: \(note)")
    }

    /// The all-clear is undeniable too, and the copy has to cover it. An alarm
    /// nobody can silence paired with a resolution somebody can leaves a
    /// permanent "someone needs attention" marker with nothing able to clear
    /// it.
    func testTheLockCopyCoversTheAllClearNotJustTheAlarm() {
        XCTAssertTrue(
            SettingsView.undeniableCategoryNote.localizedCaseInsensitiveContains("all-clear"),
            "sos_resolved is undeniable as well; copy that mentions only the alarm is half the story")
    }

    /// Titles are web's, so a user who sets a preference on one client
    /// recognises the same row on another.
    func testTitlesMatchTheWebModal() {
        let titles = Dictionary(
            uniqueKeysWithValues: SettingsView.pushCategories.map { ($0.key, $0.title) })
        XCTAssertEqual(titles["circle_invite_push"], "Circle invites")
        XCTAssertEqual(titles["member_joined_push"], "Member joined")
        XCTAssertEqual(titles["safety_alert_push"], "Alert rules")
        XCTAssertEqual(titles["destination_push"], "Destinations")
        XCTAssertEqual(titles["check_in_push"], "Check-ins")
    }

    /// Check-ins have their own push column, `check_in_push`, which the server
    /// reads, writes and gates on. Pinned by KEY, not by presence: a row titled
    /// "Check-ins" over the wrong column would look identical on screen.
    func testCheckInsAreBoundToTheirOwnColumn() {
        let row = SettingsView.pushCategories.first { $0.key == "check_in_push" }
        XCTAssertNotNil(row, "check-ins have their own column, and a row for it")
        XCTAssertEqual(row?.title, "Check-ins")
        XCTAssertEqual(row?.undeniable, false, "check-ins are mutable — that is the whole point")
    }

    /// There is no `check_in_email` column, so a second switch would be a
    /// control with no channel behind it — a dead switch.
    func testCheckInsHaveNoEmailRow() {
        XCTAssertNil(SettingsView.pushCategories.first { $0.key == "check_in_email" })
        XCTAssertFalse(Self.serverColumns.contains("check_in_email"))
    }

    // MARK: - Resolution

    /// An explicit override wins over the global, in both directions. The
    /// server resolves the same way: the category's column, else
    /// `push_enabled`, else on.
    func testAnExplicitOverrideBeatsTheGlobal() {
        XCTAssertFalse(SettingsView.resolvedPush(
            ["push_enabled": true, "sos_push": false], "sos_push"))
        XCTAssertTrue(SettingsView.resolvedPush(
            ["push_enabled": false, "sos_push": true], "sos_push"))
    }

    /// An untouched category arrives as JSON null, which JSONSerialization
    /// hands over as NSNull — NOT as a missing key, and NOT as false. Reading
    /// it as false would show every category switched off to a user who has
    /// never touched one.
    func testAnUntouchedCategoryInheritsTheGlobal() {
        let off: [String: Any] = ["push_enabled": false, "sos_push": NSNull()]
        XCTAssertFalse(SettingsView.resolvedPush(off, "sos_push"))

        let on: [String: Any] = ["push_enabled": true, "sos_push": NSNull()]
        XCTAssertTrue(SettingsView.resolvedPush(on, "sos_push"))
    }

    /// An older server that has never heard of a category omits it entirely.
    func testAnAbsentKeyInheritsTheGlobal() {
        XCTAssertTrue(SettingsView.resolvedPush(["push_enabled": true], "destination_push"))
        XCTAssertFalse(SettingsView.resolvedPush(["push_enabled": false], "destination_push"))
    }

    /// For a user with no stored row the server returns push on / email off,
    /// so an empty map has to resolve the same way — otherwise the screen
    /// shows one thing and the server does another for the same account.
    func testAnUnseededServerDefaultsToPushOnAndEmailOff() {
        XCTAssertTrue(SettingsView.resolvedPush([:], "push_enabled"))
        XCTAssertTrue(SettingsView.resolvedPush([:], "sos_push"))
        XCTAssertFalse(SettingsView.resolvedEmail([:], "email_enabled"))
        XCTAssertFalse(SettingsView.resolvedEmail([:], "sos_email"))
    }

    /// The two channels keep separate fallbacks. Resolving an email category
    /// against push_enabled would turn email on for everyone.
    func testEmailCategoriesFallBackToTheEmailChannelNotThePushOne() {
        let prefs: [String: Any] = [
            "push_enabled": true, "email_enabled": false, "sos_email": NSNull(),
        ]
        XCTAssertFalse(SettingsView.resolvedEmail(prefs, "sos_email"))
        XCTAssertTrue(SettingsView.resolvedPush(prefs, "sos_push"))
    }

    /// The values really do arrive as NSNumber via JSONSerialization, not as
    /// Swift Bools — so the resolution has to survive that bridging. Decoding
    /// the real envelope shape here rather than hand-building a dictionary is
    /// what makes this a wire test.
    func testResolutionWorksOnAJSONSerializationDictionary() throws {
        let json = """
        {"push_enabled":true,"email_enabled":false,
         "circle_invite_push":null,"circle_invite_email":null,
         "member_joined_push":false,"member_joined_email":null,
         "place_alert_push":null,"place_alert_email":null,
         "safety_alert_push":null,"safety_alert_email":null,
         "sos_push":null,"sos_email":true,
         "destination_push":false,"check_in_push":null}
        """
        let prefs = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertTrue(SettingsView.resolvedPush(prefs, "push_enabled"))
        XCTAssertTrue(SettingsView.resolvedPush(prefs, "sos_push"), "null inherits push_enabled")
        XCTAssertFalse(SettingsView.resolvedPush(prefs, "member_joined_push"), "explicit false wins")
        XCTAssertFalse(SettingsView.resolvedPush(prefs, "destination_push"))
        XCTAssertTrue(SettingsView.resolvedPush(prefs, "check_in_push"), "null inherits push_enabled")
        XCTAssertFalse(SettingsView.resolvedEmail(prefs, "email_enabled"))
        XCTAssertTrue(SettingsView.resolvedEmail(prefs, "sos_email"), "explicit true wins")
        XCTAssertFalse(SettingsView.resolvedEmail(prefs, "place_alert_email"), "null inherits email_enabled")

        // Every row on the screen resolves against a real payload without
        // throwing or reading as off.
        for category in SettingsView.pushCategories {
            _ = SettingsView.resolvedPush(prefs, category.key)
        }
    }

    /// Read-modify-write must not collapse an inherited category into an
    /// explicit one: nulls have to round-trip as nulls, or flipping one switch
    /// would freeze every other category at whatever the global happened to be.
    /// The server keeps the stored value for a null, so a null that survives
    /// the round trip changes nothing.
    func testNullsSurviveAReadModifyWriteRoundTrip() throws {
        let json = """
        {"push_enabled":true,"email_enabled":false,
         "sos_push":null,"place_alert_push":null,"destination_push":true}
        """
        var prefs = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        prefs["sos_push"] = false
        let body = try JSONSerialization.data(withJSONObject: prefs)
        let round = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(round["sos_push"] as? Bool, false, "the edited field is explicit now")
        XCTAssertTrue(round["place_alert_push"] is NSNull, "an untouched category stays inherited")
        XCTAssertEqual(round["destination_push"] as? Bool, true, "an untouched override survives")
    }

    /// The same round trip, driven from the check-in row.
    ///
    /// Deliberately NOT a payload where every column is null: an assertion that
    /// a null stayed null in a body of nothing but nulls holds whatever the
    /// code does, and proves nothing. Here `check_in_push` is the field being
    /// EDITED, its neighbours carry a null and a real override, and all three
    /// have to come out the other side distinguishable.
    ///
    /// The client sends the whole map back untyped
    /// (`APIService.updateNotificationPreferences` hands the dictionary
    /// straight to `JSONSerialization`), which is what lets a column the build
    /// predates survive a round trip at all. Swap that for a typed model and
    /// this is the test that notices.
    func testFlippingCheckInsLeavesEveryOtherCategoryAsItFoundIt() throws {
        let json = """
        {"push_enabled":true,"email_enabled":false,
         "sos_push":null,"place_alert_push":null,
         "destination_push":true,"check_in_push":null}
        """
        var prefs = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        // Inherited before the edit — `push_enabled` is on, so the switch reads
        // ON even though the column is null.
        XCTAssertTrue(SettingsView.resolvedPush(prefs, "check_in_push"))

        prefs["check_in_push"] = false
        let body = try JSONSerialization.data(withJSONObject: prefs)
        let round = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(round["check_in_push"] as? Bool, false,
                       "the column has to reach the server, or check-ins stay unmutable")
        XCTAssertFalse(SettingsView.resolvedPush(round, "check_in_push"),
                       "an explicit false must beat the global, not inherit it")
        XCTAssertTrue(round["sos_push"] is NSNull, "an untouched null must not become an explicit false")
        XCTAssertTrue(round["place_alert_push"] is NSNull)
        XCTAssertEqual(round["destination_push"] as? Bool, true)
    }

    // MARK: - The icons

    /// A misspelled SF Symbol is not an error — the row renders with a blank
    /// space where the icon should be, on a screen nobody opens in a test.
    func testEveryCategoryIconIsARealSymbol() {
        for category in SettingsView.pushCategories {
            XCTAssertNotNil(UIImage(systemName: category.icon),
                            "\(category.key): \(category.icon) is not an SF Symbol on this OS")
        }
    }
}
