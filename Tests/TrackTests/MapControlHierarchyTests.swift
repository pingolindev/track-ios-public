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

/// The map's floating controls have exactly ONE loud one.
///
/// WHY THIS IS WORTH TESTING
///   Equal controls give no hierarchy: a column of identical accent discs beside
///   another of white ones says nothing about which one matters. Hierarchy is
///   the kind of thing that erodes one reasonable-looking commit at a time: the
///   next person adding a map action reaches for the same `fab(...)` call and
///   takes the default. The default is `.prominent`, so this counts them. A
///   second prominent control is not a compile error and not a visual change
///   anyone would notice in passing — it is just the flat row of equals coming
///   back.
///
/// THE RULE, taken from the Android app's `fragment_map.xml` rather than
/// invented:
///   `fabSendLocation` is mini + `colorPrimary`; every other resting FAB
///   (`fabQuickCheckIn`, `fabSearch`, `fabExpand`, `fabHistory`,
///   `fabDestinations`) is mini + `colorSurfaceVariant`. `fabTracking` is
///   `normal` + `colorPrimary` but ships `visibility="gone"` and appears only
///   while tracking runs, so Android's RESTING map has exactly one tinted
///   control. iOS matches.
final class MapControlHierarchyTests: XCTestCase {

    func testExactlyOneMapControlIsProminent() throws {
        let source = try Self.mapViewSource()
        let calls = Self.fabCalls(in: source)
        XCTAssertFalse(calls.isEmpty, "no `fab(` call sites found — was the builder renamed?")

        // `.prominent` is the parameter default, so a call that names no role is
        // prominent too. Counting explicit `.neutral` against the total is what
        // catches the call site that quietly took the default.
        let neutral = calls.filter { $0.contains("role: .neutral") }.count
        let prominent = calls.count - neutral
        XCTAssertEqual(
            prominent, 1,
            """
            expected exactly 1 prominent map control (Send location), found \
            \(prominent) of \(calls.count). A new FAB defaults to .prominent — \
            pass `role: .neutral` unless you mean to make it THE primary action, \
            in which case the current primary has to stop being one.
            """
        )
    }

    func testTheProminentControlIsSendLocation() throws {
        let source = try Self.mapViewSource()
        let prominent = Self.fabCalls(in: source).filter { !$0.contains("role: .neutral") }
        XCTAssertEqual(
            prominent.count, 1, "see testExactlyOneMapControlIsProminent"
        )
        XCTAssertTrue(
            prominent.first?.contains("Send location") ?? false,
            """
            the one accent control must be Send location, matching \
            the Android app's `fabSendLocation` (the only colorPrimary FAB on its \
            resting map). Found: \(prominent.first ?? "none")
            """
        )
    }

    /// The overflow button says "more", not "add". Its menu holds History and
    /// Destinations — two places to go, nothing to create — and a "+" would
    /// promise otherwise.
    func testTheOverflowGlyphIsNotAPlus() throws {
        let source = try Self.mapViewSource()
        let overflow = try XCTUnwrap(
            Self.fabCalls(in: source).first(where: { $0.contains("More actions") }),
            "no overflow FAB found"
        )
        XCTAssertTrue(overflow.contains("ellipsis"), "overflow should use `ellipsis`: \(overflow)")
        XCTAssertFalse(
            overflow.contains("\"plus\""),
            "\"+\" promises adding something; this menu adds nothing"
        )
    }

    // MARK: - Reading the source

    /// Same `#filePath` tripwire the other source-scanning tests use. Unreadable
    /// is a FAILURE, never a skip.
    static func mapViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("App/Views/Map/MapView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(
                domain: "MapControlHierarchyTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "could not read \(url.path)"]
            )
        }
        return text
    }

    /// Each `fab(` invocation as one flattened string, comment lines dropped so
    /// prose that mentions a role or a glyph is never counted as a call site.
    /// Ends at the line whose trailing `)` closes the call — every call site in
    /// this file ends with `)` on its own line or with `action:` trailing.
    static func fabCalls(in source: String) -> [String] {
        var calls: [String] = []
        var current: String?
        var depth = 0
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            // Only invocations, never the declaration or a doc reference.
            if current == nil, line.contains("fab("), !line.contains("private func fab(") {
                current = line
                depth = line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
                if depth <= 0 { calls.append(line); current = nil }
                continue
            }
            if current != nil {
                current! += " " + line
                depth += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
                if depth <= 0 { calls.append(current!); current = nil }
            }
        }
        return calls
    }
}
