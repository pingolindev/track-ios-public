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

/// The privacy policy ships inside the app (Settings › Privacy Policy renders
/// `App/Resources/privacy-policy.html` offline). These pin that the document is
/// actually in the bundle and is the real policy: a hard-coded placeholder, or
/// a link to a website host that does not resolve, would both be green at
/// build time and wrong on device.
final class LegalDocumentTests: XCTestCase {

    private func policyHTML() throws -> String {
        let url = try XCTUnwrap(LegalDocumentView.bundledURL(for: "privacy-policy"),
                                "privacy-policy.html must be a bundle resource (project.yml resources: App/Resources)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPrivacyPolicyIsBundled() throws {
        let html = try policyHTML()
        XCTAssertGreaterThan(html.count, 20_000, "the rendered policy is a full document, not a stub")
        XCTAssertTrue(html.contains("Privacy Policy"), "title present")
        XCTAssertFalse(html.contains("content goes here"), "never the placeholder")
    }

    /// The website's renderer stamps the version and effective date into the
    /// document; a bundled copy without them is not a rendering of the policy.
    func testPrivacyPolicyCarriesItsVersionLine() throws {
        let html = try policyHTML()
        XCTAssertTrue(html.contains("Version "), "version line present")
        XCTAssertTrue(html.contains("Effective date"), "effective date present")
    }

    /// The document is self-contained: no script tags to run offline, and the
    /// policy text does not depend on a network fetch.
    func testPrivacyPolicyIsStaticHTML() throws {
        let html = try policyHTML()
        XCTAssertFalse(html.lowercased().contains("<script"), "no JavaScript in the bundled legal document")
    }
}
