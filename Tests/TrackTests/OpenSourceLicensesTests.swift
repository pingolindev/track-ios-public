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

/// The notices are a licence obligation, not decoration: a build that stops
/// bundling either inventory fails here instead of shipping an empty page.
final class OpenSourceLicensesTests: XCTestCase {
    func testBothInventoriesShipInTheAppBundle() throws {
        for inventory in OpenSourceLicensesView.inventories {
            let text = try XCTUnwrap(OpenSourceLicensesView.bundledText(inventory.resource),
                                     "\(inventory.resource).md is not in the app bundle")
            XCTAssertGreaterThan(text.count, 1_000, inventory.resource)
        }
    }

    func testEachInventoryIsTheOneItsTitleNames() throws {
        let app = try XCTUnwrap(OpenSourceLicensesView.bundledText("THIRD_PARTY_LICENSES"))
        XCTAssertTrue(app.contains("MapLibre"), "this app's own inventory")
        XCTAssertTrue(app.contains("GNU General Public License"), "it names the app's licence")
        let sdk = try XCTUnwrap(OpenSourceLicensesView.bundledText("THIRD_PARTY_LICENSES-mobile-sdk"))
        XCTAssertTrue(sdk.contains("MIT License"), "the SDK's Rust crates")
        XCTAssertFalse(sdk.contains("MapLibre"), "not a second copy of the app's inventory")
    }

    func testSourceCodeLinkIsThePublicRepository() {
        XCTAssertEqual(OpenSourceLicensesView.sourceCode.absoluteString,
                       "https://github.com/pingolindev/track-ios-public")
    }
}
