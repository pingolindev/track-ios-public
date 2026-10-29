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

/// Settings carries the Terms beside the Privacy Policy, in a section named
/// for the two documents it holds, not only behind the purchase sheet's
/// "Terms of Use" link.
@MainActor
final class TermsInSettingsTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testSettingsLinksTheTerms() throws {
        let settings = try source("App/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("""
                // The two documents, nothing else.
                Section("Legal") {
                    NavigationLink(destination: PrivacyPolicyView()) {
                        Label("Privacy Policy", systemImage: "hand.raised.fill")
                    }
                    // The Terms, as in the purchase sheet: the same
                    // published page, opened in Safari.
                    Link(destination: StoreKitManager.Legal.terms) {
                        Label("Terms of Service", systemImage: "doc.text")
                    }
                }
        """))
        XCTAssertFalse(settings.contains("Section(\"Privacy\") {"), "the section holds the documents alone")
        // The published page, the one the purchase sheet and the store listing name.
        XCTAssertEqual(StoreKitManager.Legal.terms, URL(string: "https://pingolin.com/terms"))
    }
}
