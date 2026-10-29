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

/// Restore Purchases is offered in every state of the Premium sheet, the
/// eligibility check's included: restoring asks the App Store, never the
/// eligibility answer (App Review guideline 3.1.1). Hidden while the check
/// is tried again, there would be no Restore offline, or with a session the
/// server refuses. TrackUITests' RestorePurchasesTests drives the sheet
/// itself.
final class RestoreAlwaysOfferedTests: XCTestCase {
    func testRestoreNeverWaitsOnTheEligibilityCheck() throws {
        let premium = try source("App/Managers/PremiumManager.swift")
        let section = try body(premium, from: "    private var restoreSection: some View {\n", to: "\n    }\n")
        XCTAssertTrue(section.contains(".accessibilityIdentifier(\"premium-restore-purchases\")"))
        XCTAssertTrue(section.contains(".disabled(restoring || store.purchasing)"), "one action at a time")
        XCTAssertFalse(section.contains("eligibility"), "shown whatever the eligibility check says, or doesn't")
        XCTAssertFalse(section.contains("Eligibility"))

        // The sheet places it after the purchase section, outside it.
        XCTAssertTrue(premium.contains("                    purchaseSection\n\n                    restoreSection\n"))
        let purchase = try body(premium, from: "    private var purchaseSection: some View {\n", to: "\n    }\n")
        XCTAssertFalse(purchase.contains("restoreSection"))

        // Restoring starts without asking eligibility; a restored subscription
        // asks it again afterwards.
        let restore = try body(premium, from: "    private func restorePurchases() async {\n", to: "\n    }\n")
        let start = try XCTUnwrap(restore.range(of: "let outcome = await store.restorePurchases()"))
        XCTAssertFalse(restore[..<start.lowerBound].contains("ligibility"), "nothing asked before the restore")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return text[from.lowerBound..<to.lowerBound]
    }
}
