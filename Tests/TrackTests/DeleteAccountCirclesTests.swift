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

/// The delete-account sheet says plainly that the circles this account owns
/// end for everyone in them.
///
/// WHY THIS IS WORTH TESTING
///   Deleting an owner's account deletes the circles it owns outright, with
///   every member's history in them. Listing "circles you own" among the
///   account's own data would read as if only the owner lost them.
@MainActor
final class DeleteAccountCirclesTests: XCTestCase {

    func testTheSheetSaysTheCirclesEndForEveryoneInThem() throws {
        XCTAssertEqual(DeleteAccountSheet.ownedCirclesText,
                       "Circles you own are deleted for everyone in them, along with all the location history they hold. "
                       + "To keep a circle going, transfer its ownership first.")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("App/Views/Settings/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("""
                    Section {
                        Text(Self.ownedCirclesText)
                            .font(.subheadline)
                    }
        """))
        XCTAssertTrue(settings.contains(
            "Text(\"Deleting your account permanently removes your profile, places, check-ins and location history. This cannot be undone.\")"),
                      "the account's own data, without the circles")
        XCTAssertFalse(settings.contains("removes your profile, circles you own,"))
    }
}
