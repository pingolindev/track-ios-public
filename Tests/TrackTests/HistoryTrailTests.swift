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

/// History on the map: a line per member with a dot per fix, cut to the range
/// by each fix's own time; one member's when opened from them ("View History"
/// on a member); and Custom has two pickers, not a fixed 24 hours.
final class HistoryTrailTests: XCTestCase {
    // Ids with letters, so that another spelling (`uppercased()`) is another
    // string: digits alone would make every spelling test a no-op.
    private let ana = "aaaaaaaa-1111-4111-8111-111111111111"
    private let ben = "bbbbbbbb-2222-4222-8222-222222222222"
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text[from.upperBound...].range(of: end), end)
        return text[from.upperBound..<to.lowerBound]
    }

    private func point(_ userId: String, minutes: Double, lat: Double = 37.3349) -> HistoryPoint {
        HistoryPoint(userId: userId, latitude: lat, longitude: -122.0090, at: start.addingTimeInterval(minutes * 60))
    }

    private func member(_ userId: String) -> CircleMember {
        CircleMember(circleId: "c", userId: userId, displayName: "M", role: .member, canSeeRealtime: true,
                     canSeeHistory: true, canRotateKeys: false, joinedAt: start)
    }

    // MARK: - The trails a range shows

    /// The server answers by day, so the range is cut by each fix's own time,
    /// both ends included.
    func testTheRangeIsCutByEachFixsOwnTime() {
        let points = [point(ana, minutes: -1), point(ana, minutes: 0), point(ana, minutes: 30),
                      point(ana, minutes: 60), point(ana, minutes: 61)]
        let window = (start: start, end: start.addingTimeInterval(3_600))
        let trails = HistoryTrails.trails(from: points, window: window, memberId: nil)
        XCTAssertEqual(trails.count, 1)
        XCTAssertEqual(trails[0].points.map(\.at), [0, 30, 60].map { start.addingTimeInterval($0 * 60) })
    }

    /// One trail per member, in time order, the members in a fixed order; one
    /// member's id in two spellings is one member.
    func testOneTrailPerMemberInTimeOrder() {
        let points = [point(ben, minutes: 20), point(ana.uppercased(), minutes: 10), point(ana, minutes: 5),
                      point(ben, minutes: 15)]
        let trails = HistoryTrails.trails(from: points, window: (start, start.addingTimeInterval(3_600)), memberId: nil)
        XCTAssertEqual(trails.count, 2)
        XCTAssertEqual(trails.map { CanonicalId.key($0.userId) }, [ana, ben])
        XCTAssertEqual(trails[0].points.map(\.at), [5, 10].map { start.addingTimeInterval($0 * 60) })
        XCTAssertEqual(trails[1].points.map(\.at), [15, 20].map { start.addingTimeInterval($0 * 60) })
    }

    /// Opened from a member: that member's alone, whatever the id's spelling.
    func testOneMembersHistory() {
        let points = [point(ana, minutes: 5), point(ben, minutes: 6)]
        let window = (start: start, end: start.addingTimeInterval(3_600))
        let trails = HistoryTrails.trails(from: points, window: window, memberId: ben.uppercased())
        XCTAssertEqual(trails.map(\.userId), [ben])
        XCTAssertTrue(HistoryTrails.trails(from: points, window: window, memberId: "not-an-id").isEmpty)
    }

    // MARK: - Custom

    /// Custom is the pickers' window: nothing until the start is before the
    /// end, and an end in the future reads as now.
    func testCustomIsThePickersWindow() throws {
        let now = start.addingTimeInterval(86_400)
        XCTAssertNil(HistoryRange.custom.window(now: now), "no pickers, no window")
        XCTAssertNil(HistoryRange.custom.window(now: now, custom: (start: now, end: start)), "start after end")
        XCTAssertNil(HistoryRange.custom.window(now: now, custom: (start: start, end: start)), "no width")
        let window = try XCTUnwrap(HistoryRange.custom.window(now: now, custom: (start: start, end: now.addingTimeInterval(600))))
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end, now)
        let earlier = try XCTUnwrap(HistoryRange.custom.window(
            now: now, custom: (start: start, end: start.addingTimeInterval(7_200))))
        XCTAssertEqual(earlier.end, start.addingTimeInterval(7_200))
        // The other chips don't read the pickers.
        XCTAssertEqual(HistoryRange.hour.window(now: now, custom: (start: start, end: now))?.start,
                       now.addingTimeInterval(-3_600))
    }

    // MARK: - Colours

    /// A trail is its member's marker colour without the staleness rule, since
    /// history is old by nature; someone the roster doesn't list is grey.
    func testATrailHasItsMembersColour() {
        let roster = [member(ana), member(ben)]
        XCTAssertEqual(MemberPalette.trail(forUserId: ben.uppercased(), in: roster), MemberPalette.color(forIndex: 1))
        XCTAssertEqual(MemberPalette.bubble(forUserId: ben, in: roster, ageMs: nil), MemberPalette.stale,
                       "control: the marker of someone with no fix is grey")
        XCTAssertEqual(MemberPalette.trail(forUserId: "33333333-3333-4333-8333-333333333333", in: roster),
                       MemberPalette.stale)
        XCTAssertEqual(MemberPalette.color(forIndex: 0).styleHex, "#818CF8")
        XCTAssertEqual(MemberPalette.stale.styleHex, "#9E9E9E")
    }

    // MARK: - Wiring

    /// The history model asks for one member's rows on a circle, cuts the
    /// answer into trails, and counts what is drawn.
    func testTheModelMakesTrailsFromTheRange() throws {
        let view = try source("App/Views/Map/HistoryView.swift")
        let refresh = try body(of: "    func refreshIfNeeded() async {", until: "\n    }\n", in: view)
        XCTAssertTrue(refresh.contains("guard let circleId, let window = range.window(custom: (start: customStart, end: customEnd)) else {"))
        XCTAssertTrue(refresh.contains("userId: personal ? nil : memberId"))
        XCTAssertTrue(refresh.contains("guard let loc = loc, let owner = rowUserId ?? (personal ? me : nil) else { return nil }"))
        XCTAssertTrue(refresh.contains("at: Date(timeIntervalSince1970: TimeInterval(loc.timestamp) / 1000))"))
        XCTAssertTrue(refresh.contains("""
                        let trails = HistoryTrails.trails(from: points, window: window, memberId: memberId)
                        self.trails = trails
                        self.pointCount = trails.reduce(0) { $0 + $1.points.count }
        """))
        XCTAssertFalse(view.contains("var coordinates"), "nothing read it")
        let api = try source("App/Services/APIService.swift")
        XCTAssertTrue(api.contains("let member = CanonicalId.of(userId).map { \"&user_id=\\($0)\" } ?? \"\""))
    }

    /// The map view: one history model, the trails passed to the map only while
    /// the sheet is up, a member's card opening that member's history.
    func testTheMapViewPassesTheTrailsWhileTheSheetIsUp() throws {
        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("@StateObject private var history = HistoryViewModel()"))
        XCTAssertTrue(map.contains("historyTrails: showingHistory ? Self.trailsShown(history.trails, roster: memberList) : [],"))
        XCTAssertTrue(map.contains(
            "history.open(circleId: circleId, memberId: member.userId, memberName: member.displayName)"))
        XCTAssertTrue(map.contains("history.open(circleId: circleId, memberId: nil, memberName: nil)"))
        XCTAssertTrue(map.contains("HistorySheet(viewModel: history)"))
    }

    /// The map draws them as two layers, again after every new style, and
    /// frames a new answer.
    func testTheMapDrawsTheTrails() throws {
        let map = try source("App/Views/Map/MapLibreMapView.swift")
        XCTAssertTrue(map.contains("context.coordinator.syncHistoryTrails(historyTrails, members: members)"))
        let sync = try body(of: "        func syncHistoryTrails(_ trails: [HistoryTrail], members: [CircleMember]) {",
                            until: "\n        }\n", in: map)
        XCTAssertTrue(sync.contains("MemberPalette.trail(forUserId: trail.userId, in: members).styleHex"))
        XCTAssertTrue(sync.contains("drawHistoryTrails()"))
        XCTAssertTrue(sync.contains("fitHistory(trails.flatMap { $0.points.map(\\.coordinate) })"))
        let draw = try body(of: "        func drawHistoryTrails() {", until: "\n        }\n\n", in: map)
        XCTAssertTrue(draw.contains("MLNLineStyleLayer(identifier: Self.historyLinesSource + \"-layer\", source: source)"))
        XCTAssertTrue(draw.contains("MLNCircleStyleLayer(identifier: Self.historyPointsSource + \"-layer\", source: source)"))
        XCTAssertEqual(draw.components(separatedBy: "NSExpression(mglJSONObject: [\"to-color\", [\"get\", \"color\"]])").count - 1, 2)
        XCTAssertTrue(draw.contains("let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))"))
        XCTAssertTrue(draw.contains("dot.coordinate = point.coordinate"))
        let styled = try body(of: "        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {",
                              until: "\n        }\n", in: map)
        XCTAssertTrue(styled.contains("drawHistoryTrails()"))
    }

    /// The card: the member's line with the way back to everyone, and the two
    /// pickers for Custom.
    func testTheCardOffersTheMemberAndCustomControls() throws {
        let view = try source("App/Views/Map/HistoryView.swift")
        XCTAssertTrue(view.contains("Text(\"Only \\(name)'s history\")"))
        XCTAssertTrue(view.contains("Button(\"Show all members\") { viewModel.showEveryone() }"))
        XCTAssertTrue(view.contains("DatePicker(\"From\", selection: $viewModel.customStart, in: ...Date(),"))
        XCTAssertTrue(view.contains("DatePicker(\"To\", selection: $viewModel.customEnd, in: ...Date(),"))
        XCTAssertFalse(view.contains("Pickers for custom aren't implemented yet"))
    }

    /// From a member's card on Live: their last 24 hours, as on the web, not
    /// nothing until a range is picked. Any other range stays.
    func testAMembersHistoryOpensOnTheLast24Hours() throws {
        XCTAssertEqual(HistoryViewModel.rangeOnOpen(.live, memberId: ana), .day)
        XCTAssertEqual(HistoryViewModel.rangeOnOpen(.live, memberId: nil), .live, "everyone's: as it was")
        XCTAssertEqual(HistoryViewModel.rangeOnOpen(.week, memberId: ana), .week)
        XCTAssertEqual(HistoryViewModel.rangeOnOpen(.custom, memberId: ana), .custom)
        let view = try source("App/Views/Map/HistoryView.swift")
        XCTAssertTrue(view.contains("        let opened = Self.rangeOnOpen(range, memberId: memberId)\n"))
    }

    /// The history route refuses with one 403 when nobody in the request shares
    /// their history with this account (no history kept, paused, or not a
    /// member). That is no "permission" error: nothing is drawn, and one
    /// member's history says why.
    func testNoHistoryIsSaidNotRefused() throws {
        XCTAssertTrue(HistoryViewModel.isNoHistory(APIError(code: "http_403", message: "Request failed")))
        XCTAssertFalse(HistoryViewModel.isNoHistory(APIError(code: "http_404", message: "Request failed")))
        XCTAssertFalse(HistoryViewModel.isNoHistory(APIError(code: "http_500", message: "Request failed")))
        XCTAssertNil(HistoryViewModel.noHistoryLine(status: nil, name: nil), "everyone's: no error")
        XCTAssertEqual(HistoryViewModel.noHistoryLine(status: .on, name: "Ana"),
                       "Ana doesn't share their location history in this circle.")
        XCTAssertEqual(HistoryViewModel.noHistoryLine(status: .off, name: "Ana"),
                       "Ana doesn't share their location history in this circle.")
        XCTAssertEqual(HistoryViewModel.noHistoryLine(status: .paused(until: nil), name: "Ana"),
                       "Ana paused location sharing.")
        XCTAssertEqual(SharingStatusCopy.historyOffSentence(name: "Ana"),
                       "Ana doesn't share their location history in this circle.")
        let view = try source("App/Views/Map/HistoryView.swift")
        let refused = try body(of: "            } catch let api as APIError where Self.isNoHistory(api) {",
                               until: "            } catch let api as APIError {", in: view)
        XCTAssertTrue(refused.contains("self.trails = []"), "an older range's trails are not left drawn")
        XCTAssertTrue(refused.contains("self.error = Self.noHistoryLine(status: member?.sharing(), name: self.memberName)"))
        XCTAssertFalse(refused.contains("plainLine"))
    }
}
