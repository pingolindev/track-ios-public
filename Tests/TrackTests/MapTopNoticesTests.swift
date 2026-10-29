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

/// The map's notices in ONE column under the top controls. Notices at fixed
/// offsets of their own overlap when two show together — a guardian line drawn
/// last would cover the toast ("This circle isn't on this device any more."),
/// the "Couldn't reach server" pill and the permission banner. In one stack
/// nothing covers anything, and the guardian line, first, is never pushed off.
final class MapTopNoticesTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(_ text: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return String(text[a.lowerBound..<b.lowerBound])
    }

    /// Every notice is in the one column, in this order: the guardian line, the
    /// place card the person just asked for, the banners, then the pill and the
    /// toast, which come and go, so neither moves a banner when it does.
    func testEveryNoticeIsInTheOneColumnTheGuardianLineFirst() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let column = try body(map, from: "    private var topNotices: some View {\n",
                              to: "    /// The standing guardian line")
        var after = column.startIndex
        for notice in ["                guardianLine\n", "placeInfoCard(coordinate: pin)", "pendingInviteBanner(invite: invite,",
                       "locationPermissionBanner(warning: warning)", "selfKeyBanner(notice: notice)",
                       "                syncErrorBanner\n", "refreshPill(state: pill)", "sendToastCapsule(toast)"] {
            let found = try XCTUnwrap(column.range(of: notice, range: after..<column.endIndex), "\(notice), in order")
            after = found.upperBound
        }
        XCTAssertTrue(column.hasPrefix("    private var topNotices: some View {\n        VStack(spacing: 8) {\n"))
        // Under the top controls at every text size: its first row is the room the selector takes, laid out as the
        // selector is (its own frame, hidden), never less than 64 pt. At the larger sizes the selector wraps past
        // 64, and a line drawn over its lower part, being a Button, would take its taps.
        XCTAssertTrue(column.hasPrefix("""
            private var topNotices: some View {
                VStack(spacing: 8) {
        """), "the room comes first")
        XCTAssertTrue(column.contains("""
                    ZStack(alignment: .top) {
                        Color.clear.frame(height: 56)
                        HStack(alignment: .top) {
                            CircleSelectorButton()
                            Spacer()
                            Color.clear.frame(width: 44, height: 0)
                        }
                        .padding([.top, .horizontal])
                    }
                    .hidden()
                    .accessibilityHidden(true)

        """), "the column under the top controls")
        XCTAssertFalse(column.contains(".padding(.top,"), "no fixed offset under them")
        let selector = try body(map, from: "struct CircleSelectorButton: View {", to: "        .sheet(isPresented: $showingPicker) {")
        XCTAssertTrue(selector.contains("            .fixedSize(horizontal: false, vertical: true)\n"), "its frame holds its label")
        // Hung from its top: with both bounds the frame takes the screen's height, so a column taller than the
        // screen runs off the bottom rather than being centred, which would lift the line and the map's
        // controls.
        XCTAssertTrue(column.contains("        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)\n    }\n"),
                      "the column hangs from its top")
        XCTAssertTrue(map.contains("                topNotices\n\n            }\n    }\n"), "placed in the map's stack, last")
    }

    /// Nothing sits at a fixed offset of its own, and nothing shows in two
    /// places.
    func testNoNoticeSitsAtAFixedOffsetOfItsOwn() throws {
        let map = try source("App/Views/Map/MapView.swift")
        for fixed in [".padding(.top, invitesManager.invites.isEmpty ? 64 : 170)",
                      "+ (invitesManager.invites.isEmpty ? 0 : 106)",
                      ".padding(.top, 72)", ".padding(.top, 56)", ".padding(.top, 8)"] {
            XCTAssertFalse(map.contains(fixed), fixed)
        }
        for once in ["placeInfoCard(coordinate: pin)", "pendingInviteBanner(invite: invite,", "locationPermissionBanner(warning: warning)",
                     "selfKeyBanner(notice: notice)", "                syncErrorBanner\n",
                     "refreshPill(state: pill)", "sendToastCapsule(toast)", "                guardianLine\n",
                     "                topNotices\n"] {
            XCTAssertEqual(map.components(separatedBy: once).count - 1, 1, once)
        }
    }

    /// The guardian line keeps its words, its tap to the full explanation,
    /// and the theme's own material.
    func testTheGuardianLineIsTheSameLine() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let line = try body(map, from: "    private var guardianLine: some View {\n",
                            to: "    // The map's modifier chain")
        XCTAssertTrue(line.contains("            showGuardianDetail = true\n"))
        XCTAssertTrue(line.contains("""
                    Text(handoverDue
                         ? "This account should now be yours"
                         : "Location and history visible to guardian")
        """))
        XCTAssertTrue(line.contains(".background(.regularMaterial, in: Capsule())"))
        // Never cut short: at the largest sizes, with every notice up, a squeezed stack
        // would read "Location and histor…".
        XCTAssertTrue(line.contains("""
                        .foregroundStyle(Color.primary)
                        // Never cut short. At the largest text sizes, with every notice
                        // up, the stack would squeeze its texts, and the disclosure
                        // would read "Location and histor…". What doesn't fit runs off
                        // the bottom instead (the column hangs from its top).
                        .fixedSize(horizontal: false, vertical: true)
        """))
        XCTAssertTrue(map.contains("""
                    if authManager.guardian.managed {
                        guardianLine
                    }
        """))
        // Observed, not just read: after a launch that couldn't read /auth/me the
        // account arrives with the map up, and the line follows.
        XCTAssertTrue(map.contains("    @StateObject private var authManager = AuthManager.shared\n"))
        XCTAssertFalse(map.contains("AuthManager.shared.currentUser?.guardian"), "every guardian read observed")
    }

    /// The guardian line reads in every state: the label colour, black or white,
    /// in both. In its Button the hierarchical styles are the tint's:
    /// `.secondary` is pale accent blue, about 1.94:1 in light and 1.73:1 in
    /// dark, and `.primary` there is the accent, under 4.5:1.
    func testTheGuardianLineIsInTheLabelColour() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let line = try body(map, from: "    private var guardianLine: some View {\n",
                            to: "    // The map's modifier chain")
        XCTAssertTrue(line.contains("                .foregroundStyle(Color.primary)\n"))
        XCTAssertEqual(line.components(separatedBy: ".foregroundStyle(").count - 1, 1, "one colour, both states")
        XCTAssertFalse(line.contains(".secondary"))
        XCTAssertFalse(line.contains("AnyShapeStyle("))
    }

    /// The pill's words are in the label colour too, as "Updating…" is: orange
    /// text measured 2.15:1 in light. Its triangle keeps the warning colour.
    func testThePillsWordsAreInTheLabelColour() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let pill = try body(map, from: "    private func refreshPill(state: RefreshPillState) -> some View {\n",
                            to: "    /// Anchor decides which side the label sits on:")
        XCTAssertTrue(pill.contains("""
                        Text("Couldn't reach server — showing last known")
                            .font(.footnote)
                            .foregroundStyle(.primary)
        """))
        XCTAssertTrue(pill.contains("""
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
        """))
        XCTAssertEqual(pill.components(separatedBy: ".foregroundStyle(.orange)").count - 1, 1, "the triangle only")
    }

    /// Nothing that slides in covers the line on its way: the place card and
    /// the toast enter with `.move(edge: .top)`, and in a stack a later
    /// sibling is drawn over an earlier one, so the line is drawn above them
    /// all.
    func testTheGuardianLineIsDrawnAboveWhatSlidesInUnderIt() throws {
        let map = try source("App/Views/Map/MapView.swift")
        let line = try body(map, from: "    private var guardianLine: some View {\n",
                            to: "    // The map's modifier chain")
        XCTAssertTrue(line.contains("        .zIndex(1)\n    }\n"), "on the line's Button, the column's child")
        XCTAssertEqual(map.components(separatedBy: ".zIndex(").count - 1, 1, "the line only")
    }
}
