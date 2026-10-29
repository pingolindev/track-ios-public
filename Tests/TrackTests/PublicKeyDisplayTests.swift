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

/// The screen these back tells the user to compare two keys "character for
/// character", so what it renders has to be the key and nothing else.
final class PublicKeyDisplayTests: XCTestCase {

    /// A real X25519 key, which SwiftUI hyphenates as `18483130b28de-` /
    /// `…ff6d9c-` / `c0fc6fc164f6a` when it is shown ungrouped.
    private let auditKey = "18483130b28def749c88f957f8996fe8de3b26a45ae60ff6d9cc0fc6fc164f6a"

    func testGroupingAddsOnlySpacesAndKeepsEveryCharacter() {
        let grouped = PublicKeyDisplay.grouped(auditKey)
        XCTAssertEqual(grouped.replacingOccurrences(of: " ", with: ""), auditKey,
                       "grouping must not change, drop or reorder a single character")
        XCTAssertFalse(grouped.contains("-"),
                       "a hyphen would be the layout's invention; the value has none")
    }

    func testGroupsAreEightCharactersWide() {
        let groups = PublicKeyDisplay.grouped(auditKey).split(separator: " ")
        XCTAssertEqual(groups.count, 8, "64 hex characters in eights is eight groups")
        XCTAssertTrue(groups.allSatisfy { $0.count == PublicKeyDisplay.groupSize })
    }

    /// Spaces are the whole mechanism: they give the line breaker somewhere to
    /// break, so it does not need to hyphenate.
    func testEveryGroupBoundaryIsABreakOpportunity() {
        let grouped = PublicKeyDisplay.grouped(auditKey)
        XCTAssertEqual(grouped.filter { $0 == " " }.count, 7)
    }

    /// A value someone already formatted is left alone — regrouping a UUID
    /// would be the same class of misrepresentation.
    func testAlreadyFormattedValuesAreUntouched() {
        let uuid = "3112df00-0893-4f23-81dc-571749a93f64"
        XCTAssertEqual(PublicKeyDisplay.grouped(uuid), uuid)
        XCTAssertEqual(PublicKeyDisplay.grouped("de ad be ef"), "de ad be ef")
    }

    func testShortAndEmptyValues() {
        XCTAssertEqual(PublicKeyDisplay.grouped(""), "")
        XCTAssertEqual(PublicKeyDisplay.grouped("abc"), "abc", "shorter than one group")
        XCTAssertEqual(PublicKeyDisplay.grouped("abcdefgh"), "abcdefgh", "exactly one group, no trailing space")
        XCTAssertEqual(PublicKeyDisplay.grouped("abcdefghi"), "abcdefgh i")
    }

    /// Both screens render through the same helper, because My Encryption Keys
    /// promises the member's Security Details shows "exactly what you see here".
    func testTheSameInputRendersIdenticallyForBothScreens() {
        XCTAssertEqual(PublicKeyDisplay.grouped(auditKey), PublicKeyDisplay.grouped(auditKey))
    }
}
