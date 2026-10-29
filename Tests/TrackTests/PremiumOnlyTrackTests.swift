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

/// Track Premium is what Track's server says it is, never another product's
/// subscription.
///
/// WHY THIS IS WORTH TESTING
///   When `/users/me/premium` fails (a 5xx, a timeout, offline at launch), the
///   app must not fall back to the auth server's `/billing/subscription`: that
///   list counts ANY active or trialing subscription and can't tell the
///   products apart (`product_slug` is empty on every row), so a Note
///   subscription would light up Track's "Premium" badge and its premium
///   controls. Track's own answer is the only word on Track's plan, and a
///   failure keeps the last-known value.
@MainActor
final class PremiumOnlyTrackTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testOnlyTracksOwnAnswerCounts() throws {
        let premium = try source("App/Managers/PremiumManager.swift")
        XCTAssertTrue(premium.contains("""
                do {
                    let status = try await APIService.shared.getPremiumStatus()
                    apply(hasPremium: status.hasPremium, source: status.source)
                } catch {
                    // Keep the last-known value.
                }
        """))
        XCTAssertFalse(premium.contains("getOwnSubscriptions"), "no fallback to the product-blind list")
        XCTAssertFalse(premium.contains("$0.status == \"active\" || $0.status == \"trialing\""),
                       "no subscription's status counts as Track Premium by itself")
        let api = try source("App/Services/APIService.swift")
        XCTAssertFalse(api.contains("path: \"/api/v1/billing/subscription\", baseURL"), "read nowhere")
    }
}
