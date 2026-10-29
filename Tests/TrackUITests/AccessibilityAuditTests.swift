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

/// WCAG-oriented accessibility audits driven by XCTest's own auditor.
///
/// `performAccessibilityAudit()` walks the live view hierarchy and reports the
/// machine-checkable accessibility problems Apple's auditor knows about:
/// contrast, Dynamic Type support, clipped text, undersized hit regions,
/// elements with no description, wrong traits. It needs no fixture, no network
/// and no extra tooling — the UI test bundle already exists, so this is the
/// cheapest accessibility coverage iOS can have.
///
/// Available unconditionally here: the app sets `IPHONEOS_DEPLOYMENT_TARGET`
/// 17.0 (project.yml) and the audit API is iOS 17+, so no `#available` dance
/// is needed.
///
/// WHY THE LOGIN SCREEN GETS ONE CASE PER AUDIT TYPE
///   So that a known failure can be accepted for one audit type without hiding
///   another: accepting a failing `testAudit_LoginScreen_contrast` must not also
///   hide a future Dynamic Type or hit-region problem on the same screen.
final class AccessibilityAuditTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true   // report EVERY issue, not just the first
    }

    // MARK: - helpers

    /// Run one audit type and fail with a readable, per-issue breakdown.
    ///
    /// The handler logs each issue. Apart from MapLibre's renderer-only map
    /// labels, which expose no UIKit element for the app to annotate, it
    /// suppresses nothing: app-owned issues belong in failure output, where
    /// fixing one shows. The fallback logging exists because the default
    /// failure message names the element but not which screen it was on,
    /// which is unreadable in a test log covering several screens.
    /// `typeName` is passed in rather than interpolated from the type itself:
    /// XCUIAccessibilityAuditType has no useful description and prints as
    /// `XCUIAccessibilityAuditType(rawValue: 65536)`, which tells a reader of
    /// the test log nothing about what was checked.
    func audit(
        _ app: XCUIApplication,
        _ type: XCUIAccessibilityAuditType,
        named typeName: String,
        screen: String,
        ignoresUnattributedMapText: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var seen = 0
        do {
            try app.performAccessibilityAudit(for: type) { issue in
                seen += 1
                // The element is what makes a finding fixable: compactDescription
                // alone says "Contrast nearly passed" and names nothing, which is
                // unactionable in a test log. identifier/label locate the view.
                let el = issue.element
                let who = [el?.identifier, el?.label]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " / ")
                // When identifier and label are BOTH empty the line
                // above says only what kind of problem it is —
                // "Dynamic Type font sizes are unsupported
                // {0@(0.0, 0.0, 0.0, 0.0)}" — which names no view and
                // cannot be acted on. The element's own description
                // carries the view hierarchy, so print it when there
                // is nothing else to go on.
                let fallback = who.isEmpty
                    ? (el.map { "  <- (unnamed) \($0.debugDescription.prefix(400))" } ?? "  <- (no element)")
                    : ""
                print("A11Y [\(screen)] \(typeName): \(issue.compactDescription)"
                      + (who.isEmpty ? "" : "  <- \(who)")
                      + "  {\(el?.elementType.rawValue ?? 0)@\(el?.frame ?? .zero)}"
                      + fallback)
                if ignoresUnattributedMapText,
                   typeName == "elementDetection",
                   issue.element == nil,
                   issue.compactDescription == "Potentially inaccessible text" {
                    // MapLibre draws street and place labels into the map canvas;
                    // they have no UIKit element the app can annotate. Keep the
                    // app's own text and controls in scope while excluding those
                    // unaddressable renderer labels.
                    print("A11Y [\(screen)] \(typeName): known MapLibre-rendered label")
                    return true
                }
                if ignoresUnattributedMapText,
                   typeName == "dynamicType",
                   issue.element == nil,
                   issue.compactDescription == "Dynamic Type font sizes are unsupported" {
                    // The same renderer labels are font-sized by the map style,
                    // not UIKit. Their zero-frame, elementless audit entries are
                    // therefore just as unaddressable as elementDetection. Do
                    // not use this exemption for an attributed font issue.
                    print("A11Y [\(screen)] \(typeName): known MapLibre-rendered label")
                    return true
                }
                return false   // no app-owned issue is suppressed; see the doc comment
            }
        } catch {
            XCTFail("audit(\(typeName)) on \(screen) could not run: \(error)",
                    file: file, line: line)
        }
        print("A11Y [\(screen)] \(typeName): \(seen) issue(s)")

        // A screenshot only when there is something to look at.
        if seen > 0 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "a11y-\(screen)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// Launch to the login screen and wait for it to actually be on screen.
    ///
    /// Auditing before the view exists is the failure mode worth guarding: an
    /// empty hierarchy produces zero issues and reads as a clean pass.
    func launchToLogin() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestCleanState", "1"]
        app.launch()
        XCTAssertTrue(
            app.textFields["Email"].waitForExistence(timeout: 20),
            "login screen never appeared — the audit below would have scanned nothing"
        )
        return app
    }

    // MARK: - login screen, one case per audit type

    func testAudit_LoginScreen_contrast() throws {
        audit(try launchToLogin(), .contrast, named: "contrast", screen: "login")
    }

    func testAudit_LoginScreen_dynamicType() throws {
        audit(try launchToLogin(), .dynamicType, named: "dynamicType", screen: "login")
    }

    func testAudit_LoginScreen_elementDetection() throws {
        audit(try launchToLogin(), .elementDetection, named: "elementDetection", screen: "login")
    }

    func testAudit_LoginScreen_hitRegion() throws {
        audit(try launchToLogin(), .hitRegion, named: "hitRegion", screen: "login")
    }

    func testAudit_LoginScreen_sufficientElementDescription() throws {
        audit(try launchToLogin(), .sufficientElementDescription,
              named: "sufficientElementDescription", screen: "login")
    }

    func testAudit_LoginScreen_textClipped() throws {
        audit(try launchToLogin(), .textClipped, named: "textClipped", screen: "login")
    }

    func testAudit_LoginScreen_trait() throws {
        audit(try launchToLogin(), .trait, named: "trait", screen: "login")
    }
}
