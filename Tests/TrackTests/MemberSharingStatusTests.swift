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

import SwiftUI
import XCTest
@testable import Track

/// Why a member's location is not updating, said to the others in the circle.
///
/// WHY THIS IS WORTH TESTING
///   - The roster's two sharing-status fields must never cost the roster: an
///     older server omits them, and `sharing_paused_until` comes with no
///     fractions on a whole second, which the wire decoder's date strategy
///     throws on. Either fault would empty the member list, so the body is
///     decoded here as the server sends it.
///   - The words are the ones the Android app and the web show, with the end
///     of a pause in the viewer's own clock.
///   - A member who is not sharing has no marker, and nothing else about the
///     map changes — the cached position stays for when they share again.
final class MemberSharingStatusTests: XCTestCase {

    // Tuesday 2026-10-13, 09:00 in Los Angeles.
    private let now = ISO8601DateFormatter().date(from: "2026-10-13T16:00:00Z")!
    // 17:00 the same Tuesday, and 17:00 the next day, in Los Angeles.
    private let laterToday = ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z")!
    private let tomorrow = ISO8601DateFormatter().date(from: "2026-10-15T00:00:00Z")!
    private let earlier = ISO8601DateFormatter().date(from: "2026-10-13T15:00:00Z")!

    private func calendar(_ zone: String = "America/Los_Angeles") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private let us = Locale(identifier: "en_US")

    /// ICU puts a narrow no-break space before "PM"; the words are what count.
    private func plain(_ text: String?) -> String? {
        text.map { $0.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ") }
    }

    private func row(_ status: MemberSharingStatus, locale: Locale? = nil) -> String? {
        plain(SharingStatusCopy.rowLine(status, now: now, calendar: calendar(), locale: locale ?? us))
    }

    // MARK: - The roster, as the server sends it

    private func page(_ rows: [String]) throws -> Paginated<CircleMemberResponse> {
        try APIService.decodeResponseBody(Data("""
        {"success": true, "data": {"items": [\(rows.joined(separator: ","))], "has_more": false}}
        """.utf8))
    }

    private func rowJSON(_ userId: String, _ extra: String) -> String {
        """
        {"user_id": "\(userId)", "display_name": "m", "role": "member", "status": "active",
         "encrypted_circle_key": {"nonce": "00", "ciphertext": "00"}, "ephemeral_public_key": "00",
         "can_see_history": true, "can_see_realtime": true, "joined_day_bucket": 20000\(extra)}
        """
    }

    func testTheRosterReadsTheStatusAndAnOlderServerStillDecodes() throws {
        let ids = (0..<9).map { _ in UUID().uuidString.lowercased() }
        let members = try page([
            rowJSON(ids[0], #", "location_sharing": "on", "sharing_paused_until": null"#),
            rowJSON(ids[1], #", "location_sharing": "off", "sharing_paused_until": null"#),
            // The server's own forms: RFC 3339 with "+00:00" (as the privacy
            // route's `paused_until`), fractions only when stored.
            rowJSON(ids[2], #", "location_sharing": "paused", "sharing_paused_until": "2026-10-14T00:00:00+00:00""#),
            rowJSON(ids[3], #", "location_sharing": "paused", "sharing_paused_until": null"#),
            rowJSON(ids[4], ""),
            rowJSON(ids[5], #", "location_sharing": "paused", "sharing_paused_until": "2026-10-14T00:00:00.123456+00:00""#),
            rowJSON(ids[6], #", "location_sharing": "paused", "sharing_paused_until": "soon""#),
            // And "Z", with and without fractions.
            rowJSON(ids[7], #", "location_sharing": "paused", "sharing_paused_until": "2026-10-14T00:00:00Z""#),
            rowJSON(ids[8], #", "location_sharing": "paused", "sharing_paused_until": "2026-10-14T00:00:00.500Z""#),
        ]).items.map { $0.toModel(in: "c") }

        XCTAssertEqual(members.count, 9, "no row and no form of the fields may cost the list")
        XCTAssertEqual(members[0].sharing(at: now), .on)
        XCTAssertEqual(members[1].sharing(at: now), .off)
        XCTAssertEqual(members[2].sharing(at: now), .paused(until: laterToday))
        XCTAssertEqual(members[3].sharing(at: now), .paused(until: nil))
        XCTAssertNil(members[4].locationSharing, "an older server sends neither field")
        XCTAssertEqual(members[4].sharing(at: now), .on, "and that changes nothing")
        XCTAssertEqual(try XCTUnwrap(members[5].sharingPausedUntil).timeIntervalSince(laterToday), 0.123, accuracy: 0.001)
        XCTAssertEqual(members[6].sharing(at: now), .paused(until: nil), "an unreadable end is a pause with no end")
        XCTAssertEqual(members[7].sharing(at: now), .paused(until: laterToday))
        XCTAssertEqual(try XCTUnwrap(members[8].sharingPausedUntil).timeIntervalSince(laterToday), 0.5, accuracy: 0.001)
    }

    func testAnUnknownValueIsSharing() {
        XCTAssertEqual(MemberSharingStatus(wire: "approximate", pausedUntil: nil), .on)
        XCTAssertEqual(MemberSharingStatus(wire: nil, pausedUntil: laterToday), .on)
    }

    // MARK: - A pause ends at its end

    func testAPauseWhoseEndHasPassedIsSharing() {
        XCTAssertEqual(MemberSharingStatus.paused(until: earlier).at(now), .on)
        XCTAssertEqual(MemberSharingStatus.paused(until: now).at(now), .on, "the instant itself, as the read path")
        XCTAssertEqual(MemberSharingStatus.paused(until: laterToday).at(now), .paused(until: laterToday))
        XCTAssertEqual(MemberSharingStatus.paused(until: nil).at(now), .paused(until: nil), "no end never ends")
        XCTAssertEqual(MemberSharingStatus.off.at(now), .off)
        XCTAssertNil(row(.paused(until: earlier)), "no label over a member who is back")
    }

    // MARK: - The words

    func testTheRowLine() {
        XCTAssertNil(row(.on))
        XCTAssertEqual(row(.off), "Location sharing off")
        XCTAssertEqual(row(.paused(until: laterToday)), "Paused until 5:00 PM")
        XCTAssertEqual(row(.paused(until: tomorrow)), "Paused until Wed 5:00 PM")
        XCTAssertEqual(row(.paused(until: nil)), "Paused")
    }

    func testTheTimeIsInTheViewersClockAndDay() {
        let gb = Locale(identifier: "en_GB")
        XCTAssertEqual(row(.paused(until: laterToday), locale: gb), "Paused until 17:00")
        XCTAssertEqual(row(.paused(until: tomorrow), locale: gb), "Paused until Wed 17:00")
        // The instant that is 5 PM Tuesday in Los Angeles is 01:00 Wednesday in
        // London, where it is not "today" any more: the day is the viewer's.
        XCTAssertEqual(
            plain(SharingStatusCopy.time(laterToday, now: now, calendar: calendar("Europe/London"), locale: gb)),
            "Wed 01:00")
    }

    func testTheCardSentence() {
        func card(_ status: MemberSharingStatus) -> String? {
            plain(SharingStatusCopy.detailSentence(name: "Maya", status, now: now, calendar: calendar(), locale: us))
        }
        XCTAssertNil(card(.on))
        XCTAssertEqual(card(.off), "Maya turned off location sharing in this circle.")
        XCTAssertEqual(card(.paused(until: laterToday)), "Maya paused location sharing until 5:00 PM.")
        XCTAssertEqual(card(.paused(until: tomorrow)), "Maya paused location sharing until Wed 5:00 PM.")
        XCTAssertEqual(card(.paused(until: nil)), "Maya paused location sharing.")
    }

    func testTheOwnScreenSaysWhatTheOthersSee() {
        func own(_ status: MemberSharingStatus) -> String? {
            plain(SharingStatusCopy.ownSentence(status, now: now, calendar: calendar(), locale: us))
        }
        XCTAssertNil(own(.on))
        XCTAssertEqual(own(.off),
                       "Location sharing is off in this circle. Members see your history up to then and may still see the last location you shared, with “Location sharing off” next to your name.")
        XCTAssertEqual(own(.paused(until: laterToday)), "Paused until 5:00 PM. Members see this next to your name.")
        XCTAssertEqual(own(.paused(until: nil)), "Paused. Members see this next to your name.")
    }

    // MARK: - The person's own privacy row

    func testTheOwnRowFollowsTheServersRule() {
        var settings = PrivacySettings.default(for: "c")
        XCTAssertEqual(MemberSharingStatus(settings: settings), .on)
        settings.pause(until: laterToday)
        XCTAssertEqual(MemberSharingStatus(settings: settings), .paused(until: laterToday))
        settings.shareRealtime = false
        XCTAssertEqual(MemberSharingStatus(settings: settings), .off, "a lasting choice wins over a pause")
        settings.shareRealtime = true
        settings.pause(until: nil)
        XCTAssertEqual(MemberSharingStatus(settings: settings), .paused(until: nil))
        settings.pause(until: earlier)
        XCTAssertEqual(MemberSharingStatus(settings: settings).at(now), .on)
        settings.resume()
        settings.bubbleEnabled = true
        settings.sharingMode = "approximate"
        XCTAssertEqual(MemberSharingStatus(settings: settings), .on, "approximate is sharing")
    }

    // MARK: - The map

    private func member(_ id: String, _ sharing: String?, until: Date? = nil) -> CircleMember {
        CircleMember(circleId: "c", userId: id, displayName: "m", role: .member, canSeeRealtime: true,
                     canSeeHistory: true, canRotateKeys: false, joinedAt: now,
                     locationSharing: sharing, sharingPausedUntil: until)
    }

    func testTheMapDropsTheMarkerOfAMemberWhoIsNotSharing() {
        XCTAssertFalse(MemberSharingStatus.keepsMarkerWhileNotSharing, "the owner's call; one switch")
        let ids = (0..<6).map { _ in UUID().uuidString.lowercased() }
        let roster = [
            member(ids[0], "on"), member(ids[1], "off"), member(ids[2], "paused", until: laterToday),
            member(ids[3], "paused", until: earlier), member(ids[4], nil),
        ]
        // Rows in another spelling of the same ids, and one for nobody on the roster.
        let rows = ids.map {
            LocationData(circleId: "c", userId: $0.uppercased(), deviceId: "d", latitude: 37.33, longitude: -122.01)
        }
        let shown = MapView.withoutMembersNotSharing(rows, roster: roster, now: now).map { $0.userId.lowercased() }
        XCTAssertEqual(shown, [ids[0], ids[3], ids[4], ids[5]])
        XCTAssertEqual(MapView.withoutMembersNotSharing(rows, roster: [], now: now).count, rows.count)
    }

    /// The card of a member who is not sharing can be dragged taller, so the
    /// sentence is never cut off at the largest text sizes; it still opens at
    /// 160, the smallest. Every other card keeps its one snug height.
    func testTheCardOfAMemberNotSharingCanGrow() {
        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: false, hasAddress: false, hasSharingSentence: true),
                       [.height(160), .medium])
        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: false, hasAddress: false, hasSharingSentence: false),
                       [.height(140)])
        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: true, hasAddress: false, hasSharingSentence: false),
                       [.height(280)])
        XCTAssertEqual(MemberDetailSheet.cardDetents(hasLocation: true, hasAddress: true, hasSharingSentence: false),
                       [.height(320)])
    }

    // MARK: - The wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testEverySurfaceReadsTheStatus() throws {
        let manager = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(manager.contains("locationSharing: response.locationSharing,\n"),
                      "loadMembers carries it too, not only the converter")
        XCTAssertTrue(manager.contains("sharingPausedUntil: MemberSharingStatus.wireDate(response.sharingPausedUntil)"))

        let map = try source("App/Views/Map/MapView.swift")
        XCTAssertTrue(map.contains("""
                        Self.withoutMembersNotSharing(
                            Self.inCircle(circleManager.memberLocations.values, circleManager.activeCircle?.id), roster: memberList),
        """), "the markers")
        XCTAssertTrue(map.contains("return SharingStatusCopy.detailSentence(name: live.displayName, live.sharing())"),
                      "the member's card")
        XCTAssertTrue(map.contains("guard sharingSentence == nil else { return nil }"),
                      "no position, no address on that card")

        let circles = try source("App/Views/Circles/CirclesView.swift")
        XCTAssertTrue(circles.contains("guard member.sharing() == .on else { return nil }"), "no \"Last seen\"")
        XCTAssertTrue(circles.contains(": SharingStatusCopy.rowLine(member.sharing())"), "the member's row")
        XCTAssertTrue(circles.contains("if let line = SharingStatusCopy.ownSentence(ownSharing, historyOn: ownHistoryOn) {"),
                      "the own screen")
        XCTAssertTrue(circles.contains("if let line = SharingStatusCopy.rowLine(sharing) {"), "the privacy row")

        let details = try source("App/Views/Circles/MemberDetailView.swift")
        XCTAssertTrue(details.contains("SharingStatusCopy.detailSentence(name: member.displayName, member.sharing())"))
    }
}
