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
import UIKit
@testable import Track

/// The member bubble: one colour per person, one place that decides it, and
/// initials you can actually read on it.
///
/// WHY THIS IS WORTH TESTING
///
///   1. One person gets one colour on every surface at once. Three surfaces
///      (marker, card, roster row) that each look the member up in a roster
///      of their own choosing, and each do something different when the
///      lookup misses, can paint the same person purple on the map marker and
///      green on the member card at the same moment.
///
///   2. White initials fail WCAG AA on all nine colours in this palette, in
///      both appearances, so the ink is chosen per bubble (`ink(on:)`).
final class MemberAvatarTests: XCTestCase {

    private func member(_ userId: String) -> CircleMember {
        CircleMember(
            circleId: "c1",
            userId: userId,
            displayName: "Member \(userId)",
            role: .member,
            canSeeRealtime: true,
            canSeeHistory: true,
            // Irrelevant to avatar colouring; a plain member holds no
            // rotation right, so this is the honest value for the fixture.
            canRotateKeys: false,
            joinedAt: Date()
        )
    }

    private var roster: [CircleMember] { ["u0", "u1", "u2"].map(member) }
    private let fresh: Int64 = 60_000

    // MARK: - One colour per person

    func testEverySurfaceGetsTheSameColourForTheSamePerson() {
        // The marker and the card both call this, so "same person, same roster"
        // cannot produce two answers.
        for m in roster {
            let a = MemberPalette.bubble(forUserId: m.userId, in: roster, ageMs: fresh)
            let b = MemberPalette.bubble(forUserId: m.userId, in: roster, ageMs: fresh)
            XCTAssertEqual(a, b)
        }
    }

    func testColourFollowsRosterPositionForAndroidParity() {
        // The Android app uses `MEMBER_COLORS[position % size]`. Keeping the same
        // key is what stops one circle seeing two different colour schemes.
        XCTAssertEqual(MemberPalette.bubble(forUserId: "u0", in: roster, ageMs: fresh), MemberPalette.colors[0])
        XCTAssertEqual(MemberPalette.bubble(forUserId: "u1", in: roster, ageMs: fresh), MemberPalette.colors[1])
        XCTAssertEqual(MemberPalette.bubble(forUserId: "u2", in: roster, ageMs: fresh), MemberPalette.colors[2])
    }

    func testDistinctMembersGetDistinctColours() {
        let used = roster.map { MemberPalette.bubble(forUserId: $0.userId, in: roster, ageMs: fresh) }
        XCTAssertEqual(Set(used).count, roster.count, "two members share a bubble colour")
    }

    // MARK: - The miss cases, where separate lookups would diverge

    func testAnUnknownMemberIsGreyNotSlotZero() {
        let c = MemberPalette.bubble(forUserId: "nobody", in: roster, ageMs: fresh)
        XCTAssertEqual(c, MemberPalette.stale)
        XCTAssertNotEqual(
            c, MemberPalette.colors[0],
            """
            Falling back to slot 0 paints an unidentified member in the FIRST \
            member's colour, so two people render identically and the map lies \
            about who is where. Grey cannot collide with a real slot.
            """
        )
    }

    func testAnEmptyRosterIsGrey() {
        // The state the map is in before member decryption finishes: grey,
        // not everybody in slot 0.
        XCTAssertEqual(MemberPalette.bubble(forUserId: "u1", in: [], ageMs: fresh), MemberPalette.stale)
    }

    func testAStaleOrMissingFixIsGrey() {
        let old = MemberPalette.staleThresholdMs + 1
        XCTAssertEqual(MemberPalette.bubble(forUserId: "u1", in: roster, ageMs: old), MemberPalette.stale)
        XCTAssertEqual(MemberPalette.bubble(forUserId: "u1", in: roster, ageMs: nil), MemberPalette.stale)
        // The boundary itself is still live — 15 minutes exactly is not stale.
        XCTAssertEqual(
            MemberPalette.bubble(forUserId: "u1", in: roster, ageMs: MemberPalette.staleThresholdMs),
            MemberPalette.colors[1]
        )
    }

    // MARK: - Readable initials

    func testEveryBubbleCarriesInitialsAtWcagAA() {
        for (i, bubble) in (MemberPalette.colors + [MemberPalette.stale]).enumerated() {
            let ratio = MemberPalette.contrast(bubble, MemberPalette.ink(on: bubble))
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                """
                palette entry \(i) puts its initials at \(String(format: "%.2f", ratio)):1. \
                If a colour was just added to the palette, `ink(on:)` picked the best of \
                black and white and neither clears AA — the colour itself needs changing.
                """
            )
        }
    }

    func testWhiteInitialsWouldFailOnEveryBubble() {
        // Pins the reason for `ink(on:)`. If white ever passes here, the palette
        // changed and the reasoning on `ink(on:)` needs revisiting rather than
        // the test deleting.
        for (i, bubble) in (MemberPalette.colors + [MemberPalette.stale]).enumerated() {
            XCTAssertLessThan(
                MemberPalette.contrast(bubble, .white), 4.5,
                "palette entry \(i) now passes with white initials — re-read `ink(on:)`"
            )
        }
    }

    func testTheContrastFormulaMatchesKnownValues() {
        // Anchors the implementation against values anyone can check: white on
        // black is 21:1, and a colour against itself is 1:1.
        XCTAssertEqual(MemberPalette.contrast(.white, .black), 21.0, accuracy: 0.01)
        XCTAssertEqual(MemberPalette.contrast(.white, .white), 1.0, accuracy: 0.001)
    }
}

/// A member marker already on the map is drawn again when what it shows
/// changes: its age, its stale grey, its place or its name. Otherwise it
/// could say "now" for a position 15 minutes old, under a card saying
/// "Last seen 15 minutes ago".
@MainActor
final class MemberMarkerAgeTests: XCTestCase {
    private let colour = MemberPalette.colors[1]

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func shown(ageMs: Int64, at place: String? = nil, approximate: Bool = false,
                       name: String = "Rv A") -> MemberMarkerView.Appearance {
        MemberMarkerView.appearance(displayName: name, ageMs: ageMs, fillColor: colour, atPlaceName: place,
                                    isApproximate: approximate)
    }

    /// What a marker shows moves with its age: "now", then minutes, then grey
    /// past 15 minutes; within one minute there is nothing to draw again.
    func testWhatAMarkerShowsMovesWithItsAge() {
        let live = shown(ageMs: 30_000)
        XCTAssertEqual(live.initials, "RA")
        XCTAssertEqual(live.caption, "now")
        XCTAssertEqual(live.fill, colour)
        let old = shown(ageMs: MemberPalette.staleThresholdMs + 1)
        XCTAssertEqual(old.caption, "15m")
        XCTAssertEqual(old.fill, MemberPalette.stale)
        XCTAssertNotEqual(live, old)
        XCTAssertNotEqual(shown(ageMs: 30_000), shown(ageMs: 61_000), "now, then 1m")
        XCTAssertEqual(shown(ageMs: 31_000), shown(ageMs: 59_000), "the same minute: the same marker")
        XCTAssertEqual(shown(ageMs: 30_000, at: "Park").caption, "At Park")
        XCTAssertEqual(shown(ageMs: 30_000, at: "Park", approximate: true).caption, "now",
                       "never a place worked out from an area")
        XCTAssertNotEqual(shown(ageMs: 30_000, at: "Park"), shown(ageMs: 30_000), "left the place")
        XCTAssertNotEqual(shown(ageMs: 30_000, name: "Member"), shown(ageMs: 30_000), "its name opened")
    }

    /// The view is drawn again from the annotation as it now stands.
    func testAViewIsDrawnAgainFromTheMemberAsItNowStands() {
        let member = MemberAnnotation()
        member.displayName = "Rv A"
        member.ageMs = 30_000
        member.fillColor = colour
        let view = MemberMarkerView(reuseIdentifier: "member")
        view.configure(member: member)
        XCTAssertEqual(view.accessibilityLabel, "Rv A, now")
        let before = MemberMarkerView.appearance(of: member)
        member.ageMs = MemberPalette.staleThresholdMs + 1
        XCTAssertNotEqual(MemberMarkerView.appearance(of: member), before)
        view.configure(member: member)
        XCTAssertEqual(view.accessibilityLabel, "Rv A, 15m")
    }

    /// The map's pass: what the marker showed is read before the annotation
    /// changes, and a view on the map is drawn again in place only when that
    /// changed; removing and adding stays for an SOS or area flip alone.
    func testTheMapDrawsAMarkerAgainInPlaceOnlyWhenWhatItShowsChanged() throws {
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        let read = try XCTUnwrap(map.range(of: "                        let shownBefore = MemberMarkerView.appearance(of: existing)\n"))
        let aged = try XCTUnwrap(map.range(of: "                        existing.ageMs = ageMs\n"))
        XCTAssertLessThan(read.lowerBound, aged.lowerBound, "read before it changes")
        XCTAssertTrue(map.contains(
            "                        } else if MemberMarkerView.appearance(of: existing) != shownBefore,\n"
            + "                                  let view = mapView.view(for: existing) as? MemberMarkerView {\n"))
        XCTAssertTrue(map.contains("                            view.configure(member: existing)\n"))
        XCTAssertEqual(map.components(separatedBy: "mapView.removeAnnotation(existing)\n"
                                      + "                            mapView.addAnnotation(existing)").count - 1, 1,
                       "removed and added for an SOS or area flip alone")
        XCTAssertTrue(map.contains("                view.configure(member: m)\n"), "a new view, from the same member")
    }

    /// The map's clock moves an age on with no new position: "now" for a
    /// minute, then "1m", then grey past 15 minutes. Within the same minute,
    /// or with "At <Place>" and no grey yet, nothing is drawn again.
    func testTheClockMovesAMarkersAgeOnWithNoNewPosition() {
        let fixMs: Int64 = 1_760_000_000_000
        let member = MemberAnnotation()
        member.displayName = "Rv A"
        member.fillColor = colour
        member.fixTimeMs = fixMs
        member.ageMs = 5_000
        XCTAssertFalse(MapLibreMapView.moveAgeOn(member, nowMs: fixMs + 45_000), "still now")
        XCTAssertEqual(member.ageMs, 45_000)
        XCTAssertTrue(MapLibreMapView.moveAgeOn(member, nowMs: fixMs + 61_000))
        XCTAssertEqual(MemberMarkerView.appearance(of: member).caption, "1m")
        XCTAssertFalse(MapLibreMapView.moveAgeOn(member, nowMs: fixMs + 89_000), "the same minute")
        XCTAssertTrue(MapLibreMapView.moveAgeOn(member, nowMs: fixMs + MemberPalette.staleThresholdMs + 1))
        XCTAssertEqual(MemberMarkerView.appearance(of: member), MemberMarkerView.Appearance(
            initials: "RA", caption: "15m", fill: MemberPalette.stale))

        let atPark = MemberAnnotation()
        atPark.displayName = "Rv B"
        atPark.fillColor = colour
        atPark.fixTimeMs = fixMs
        atPark.atPlaceName = "Park"
        XCTAssertFalse(MapLibreMapView.moveAgeOn(atPark, nowMs: fixMs + 120_000), "\"At Park\" either way")
        XCTAssertTrue(MapLibreMapView.moveAgeOn(atPark, nowMs: fixMs + MemberPalette.staleThresholdMs + 1), "grey")
    }

    /// A fanned-out copy takes its member's age, and its view is drawn from it.
    func testAFannedOutCopyTakesItsMembersAge() {
        let member = MemberAnnotation()
        member.displayName = "Rv A"
        member.fillColor = colour
        member.ageMs = 61_000
        let fan = FanMemberAnnotation()
        fan.displayName = "Rv A"
        fan.fillColor = colour
        fan.ageMs = 30_000
        XCTAssertTrue(MapLibreMapView.moveAgeOn(fan, from: member))
        XCTAssertEqual(fan.ageMs, 61_000)
        XCTAssertFalse(MapLibreMapView.moveAgeOn(fan, from: member), "nothing new")
        let view = MemberMarkerView(reuseIdentifier: "member")
        view.configure(fan: fan)
        XCTAssertEqual(view.accessibilityLabel, "Rv A, 1m")
    }

    /// An SOS disc's caption moves on the same way (it uses the same age
    /// format). An annotation with no alert from a pass is left alone.
    func testTheClockMovesAnSOSCaptionOn() {
        let raised = Date(timeIntervalSince1970: 1_760_000_000)
        let alert = SOSAlert(id: "a", circleId: "c", userId: "u", status: .active, latitude: 37.3349,
                             longitude: -122.009, acknowledgedBy: [], createdAt: raised,
                             positionTakenAt: raised.addingTimeInterval(-10), positionAccuracy: 12, positionMarker: nil)
        let sos = SOSAnnotation()
        sos.alert = alert
        sos.caption = MapLibreMapView.sosCaption(alert, now: raised.addingTimeInterval(180))
        XCTAssertEqual(sos.caption, "Sent from here · 3m")
        XCTAssertFalse(MapLibreMapView.moveCaptionOn(sos, now: raised.addingTimeInterval(200)), "still 3m")
        XCTAssertTrue(MapLibreMapView.moveCaptionOn(sos, now: raised.addingTimeInterval(250)))
        XCTAssertEqual(sos.caption, "Sent from here · 4m")
        XCTAssertEqual(sos.title, MapLibreMapView.sosTitle(alert, now: raised.addingTimeInterval(250)))
        let bare = SOSAnnotation()
        bare.caption = "x"
        XCTAssertFalse(MapLibreMapView.moveCaptionOn(bare, now: raised))
        XCTAssertEqual(bare.caption, "x")
    }

    /// The clock runs only while the app is in the foreground (`.task` alone
    /// keeps running all night in this app; ForegroundPollGateTests), only while
    /// the map is on screen, and never runs a pass, each of which ends by
    /// closing an open fan. Each pass leaves it what it needs.
    func testTheClockRunsInTheForegroundOnlyAndRunsNoPass() throws {
        let mapView = try source("App/Views/Map/MapView.swift")
        let sleep = try XCTUnwrap(mapView.range(of: "try? await Task.sleep(nanoseconds: 30_000_000_000)"))
        let before = String(mapView[..<sleep.lowerBound])
        let task = try XCTUnwrap(before.range(of: ".task(", options: .backwards))
        let opener = String(before[task.lowerBound...])
        XCTAssertTrue(opener.hasPrefix(".task(id: scenePhase == .active && tabSelection.selected == ForegroundRefreshCadence.mapTabIndex) {\n"
                                       + "                guard scenePhase == .active,\n"
                                       + "                      tabSelection.selected == ForegroundRefreshCadence.mapTabIndex else { return }\n"),
                      "got: \(opener.prefix(100))")
        XCTAssertTrue(opener.contains("MapViewHolder.shared.refreshAges?()"))
        XCTAssertTrue(mapView.contains("@Environment(\\.scenePhase) private var scenePhase"))

        let map = try source("App/Views/Map/MapLibreMapView.swift")
        XCTAssertTrue(map.contains(
            "MapViewHolder.shared.refreshAges = { [weak c = context.coordinator] in c?.refreshAges() }"))
        XCTAssertTrue(map.contains("        dismissFan = nil\n        refreshAges = nil\n"), "goes at a sign-out")
        let start = try XCTUnwrap(map.range(of: "        func refreshAges(now: Date = Date()) {\n"))
        let end = try XCTUnwrap(map.range(of: "\n        }\n", range: start.upperBound..<map.endIndex))
        let clock = String(map[start.upperBound..<end.lowerBound])
        for pass in ["syncAnnotations", "applyMemberClustering", "clearFan", "removeAnnotation", "addAnnotation"] {
            XCTAssertFalse(clock.contains(pass), "the clock runs no pass: \(pass)")
        }
        XCTAssertTrue(clock.contains("(mapView.view(for: member) as? MemberMarkerView)?.configure(member: member)"))
        XCTAssertTrue(clock.contains("(mapView.view(for: fan) as? MemberMarkerView)?.configure(fan: fan)"))
        XCTAssertTrue(clock.contains("(mapView.view(for: sos) as? SOSMarkerView)?.setCaption(sos.caption)"))
        XCTAssertTrue(map.contains("                        existing.fixTimeMs = fixTimeMs\n"))
        XCTAssertTrue(map.contains("                        annot.fixTimeMs = fixTimeMs\n"))
        XCTAssertTrue(map.contains("                    existing.alert = alert\n"))
        XCTAssertTrue(map.contains("                    annot.alert = alert\n"))
        XCTAssertTrue(map.contains("                view.configure(fan: f)\n"))
    }
}
