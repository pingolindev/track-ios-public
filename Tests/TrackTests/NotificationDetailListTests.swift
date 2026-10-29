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

/// The app's notification list follows "Notification detail" for every name
/// it adds: the setting governs every named text. Destination rows and
/// removed-place rows included: Generic keeps the server's words and "Names
/// only" names the person, never the place.
final class NotificationDetailListTests: XCTestCase {
    private typealias Detail = NamedNotificationCopy.Detail

    func testARemovedPlaceIsNamedOnlyAtNamesAndPlaces() {
        XCTAssertEqual(NotificationsManager.placeAlertRemovedBody(placeName: "Home", detail: .full),
                       "A place alert on Home was removed because the place was deleted")
        XCTAssertNil(NotificationsManager.placeAlertRemovedBody(placeName: "Home", detail: .names),
                     "a place: never at Names only")
        XCTAssertNil(NotificationsManager.placeAlertRemovedBody(placeName: "Home", detail: .generic))
        XCTAssertNil(NotificationsManager.placeAlertRemovedBody(placeName: nil, detail: .full), "no longer held here")
        XCTAssertNil(NotificationsManager.placeAlertRemovedBody(placeName: "", detail: .full))
    }

    func testASharedDestinationNamesWhoAndWhereByLevel() {
        func shared(_ actor: String?, _ label: String?, _ detail: Detail) -> String? {
            NotificationsManager.destinationBody(type: "destination_shared", actor: actor, label: label,
                                                 isSelf: false, detail: detail)
        }
        XCTAssertEqual(shared("Alice", "Home", .full), "Alice created a destination for Home")
        XCTAssertEqual(shared("Alice", "Home", .names), "Alice shared a new destination", "the person, not the place")
        XCTAssertNil(shared("Alice", "Home", .generic), "the server's words")
        XCTAssertEqual(shared(nil, "Home", .full), "New destination: Home")
        XCTAssertNil(shared(nil, "Home", .names), "only a place to name: the server's words")
        XCTAssertNil(shared(nil, nil, .full))
    }

    func testAnArrivalNamesWhoAndWhereByLevel() {
        func arrival(_ actor: String?, _ label: String?, isSelf: Bool = false, _ detail: Detail) -> String? {
            NotificationsManager.destinationBody(type: "destination_arrival", actor: actor, label: label,
                                                 isSelf: isSelf, detail: detail)
        }
        XCTAssertEqual(arrival("Alice", "Home", .full), "Alice arrived at Home")
        XCTAssertEqual(arrival("Alice", "Home", .names), "Alice arrived at their destination")
        XCTAssertNil(arrival("Alice", "Home", .generic))
        XCTAssertEqual(arrival("Alice", nil, .full), "Alice arrived at their destination")
        XCTAssertEqual(arrival(nil, "Home", .full), "Arrived at Home")
        XCTAssertNil(arrival(nil, "Home", .names))
        XCTAssertEqual(arrival(nil, "Home", isSelf: true, .full), "You arrived at Home")
        XCTAssertNil(arrival(nil, "Home", isSelf: true, .names), "your own arrival: the place only at full detail")
        XCTAssertNil(arrival(nil, "Home", isSelf: true, .generic))
        XCTAssertNil(NotificationsManager.destinationBody(type: "place_alert", actor: "Alice", label: "Home",
                                                          isSelf: false, detail: .full), "not a destination row")
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every load personalises at the setting it reads, the inbox reloads when
    /// the setting has changed since, and Settings says what happens.
    func testTheListFollowsTheSettingAndSettingsSaysSo() throws {
        let manager = try source("App/Managers/NotificationsManager.swift")
        XCTAssertEqual(manager.components(separatedBy: "Self.personalize($0, detail: detail)").count - 1, 3,
                       "refresh, the cached first page, and the next page")
        XCTAssertFalse(manager.contains("Self.personalize($0)"))
        XCTAssertTrue(manager.contains("guard detail == .full, case .string(let placeId)? = row.metadata?[\"place_id\"],"))
        XCTAssertTrue(manager.contains("guard type == \"destination_shared\" || type == \"destination_arrival\", detail != .generic,"))
        XCTAssertTrue(try source("App/Views/Notifications/NotificationsView.swift").contains(
            "if manager.notifications.isEmpty || manager.personalizedAt != NotificationsManager.detailNow {"))
        let settings = try source("App/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("The app's notification list follows this setting too; at Generic it keeps the standard wording."))
        XCTAssertFalse(settings.contains("always shows full detail"))
    }
}
