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

/// The sharing switches on iOS:
/// - After a pause or real-time off ends, a watched member's silence counts
///   from the later of their last-seen and the end of that stretch, as the
///   server counts it, so a pause that runs out on a still phone isn't
///   "hasn't shared since …" about the pause itself.
/// - A crossing replayed later is judged against the stretches of not sharing
///   at its own time, as a late point is, not by the posture when it is sent:
///   the server can only judge it by the time it arrives.
/// - Another member's live destination shows their status in place of an ETA
///   while they're paused or have real-time off.
@MainActor
final class SharingSwitchesFollowUpTests: XCTestCase {

    private let circle = "33333333-3333-3333-3333-333333333333"
    private let ana = "aaaaaaaa-0000-4000-8000-000000000001"
    private let me = "11111111-1111-1111-1111-111111111111"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func member(_ id: String, sharing: String? = nil, until: Date? = nil) -> CircleMember {
        CircleMember(circleId: circle, userId: id, displayName: "Ana", role: .member, canSeeRealtime: true,
                     canSeeHistory: true, canRotateKeys: false, joinedAt: now,
                     locationSharing: sharing, sharingPausedUntil: until)
    }

    // MARK: - Silence counts from the end of a pause

    func testSilenceCountsFromTheEndOfAPause() {
        let lastSeen = at(-300)
        XCTAssertEqual(LocalInactivityStore.activeSince(lastSeen: lastSeen, notSharingSeen: nil, now: now), lastSeen)
        XCTAssertEqual(LocalInactivityStore.activeSince(lastSeen: lastSeen, notSharingSeen: at(-10), now: now), at(-10),
                       "the pause ended after they were last seen")
        XCTAssertEqual(LocalInactivityStore.activeSince(lastSeen: at(-5), notSharingSeen: at(-10), now: now), at(-5),
                       "a fix after the pause")
        XCTAssertEqual(LocalInactivityStore.activeSince(lastSeen: lastSeen, notSharingSeen: at(30), now: now), now,
                       "a planned end still ahead: never after now")
    }

    /// While they're not sharing: now, or a timed pause's planned end when
    /// that is later; never earlier than what was noted.
    func testWhatIsNotedWhileTheyAreNotSharing() {
        XCTAssertEqual(LocalInactivityStore.noted(nil, status: .off, now: now), now)
        XCTAssertEqual(LocalInactivityStore.noted(nil, status: .paused(until: at(60)), now: now), at(60))
        XCTAssertEqual(LocalInactivityStore.noted(nil, status: .paused(until: nil), now: now), now)
        XCTAssertNil(LocalInactivityStore.noted(at(60), status: .off, now: now), "never moved earlier")
        XCTAssertEqual(LocalInactivityStore.noted(at(-5), status: .off, now: now), now)
        XCTAssertEqual(LocalInactivityStore.memberKey(circle.uppercased(), ana.uppercased()), "\(circle)|\(ana)")
    }

    func testTheEvaluatorNotesAndCountsFromIt() throws {
        let monitoring = try source("App/Managers/MonitoringManager.swift")
        XCTAssertTrue(monitoring.contains(
            "store.noteNotSharing(circleId: circleId, userId: member.userId, status: sharing, now: now)"))
        XCTAssertTrue(monitoring.contains("""
                            let silentFor = now.timeIntervalSince(LocalInactivityStore.activeSince(
                                lastSeen: lastSeen,
                                notSharingSeen: store.notSharingSeen(circleId: circleId, userId: member.userId), now: now))
        """))
        XCTAssertFalse(monitoring.contains("let silentFor = now.timeIntervalSince(lastSeen)"))
        let store = try source("App/Managers/LocalInactivityStore.swift")
        XCTAssertTrue(store.contains("        notSharingSeen = [:]\n"), "a sign-out clears it")
    }

    /// Resumed early: a planned end still ahead was not the end, so silence
    /// counts from when they shared again, not from the planned end (which
    /// would hide a real silence until then). Android's rule.
    func testAnEarlyResumeBringsTheEndBack() throws {
        XCTAssertEqual(LocalInactivityStore.resumed(at(480), now: now), now, "an 8-hour pause ended after a minute")
        XCTAssertNil(LocalInactivityStore.resumed(at(-10), now: now), "a past end stands")
        XCTAssertNil(LocalInactivityStore.resumed(nil, now: now))
        let monitoring = try source("App/Managers/MonitoringManager.swift")
        XCTAssertEqual(monitoring.components(separatedBy: "store.noteSharing(circleId: circleId, userId: ").count - 1, 2,
                       "the inactivity rules and the self alerts")
    }

    /// A lapse resolves, and "is sharing location again" is said, only on a
    /// NEW fix since it fired: a pause that ended with no fix is not one.
    func testALapseResolvesOnlyOnANewFix() throws {
        XCTAssertTrue(LocalInactivityStore.resolvesLapse(triggeredAt: at(0), lastFix: at(5)))
        XCTAssertFalse(LocalInactivityStore.resolvesLapse(triggeredAt: at(0), lastFix: at(-5)), "the fix it fired on")
        XCTAssertFalse(LocalInactivityStore.resolvesLapse(triggeredAt: at(0), lastFix: at(0)))
        let monitoring = try source("App/Managers/MonitoringManager.swift")
        XCTAssertTrue(monitoring.contains("if store.resolve(ruleId: rule.id, userId: member.userId, fixAt: lastSeen) {"))
        XCTAssertTrue(monitoring.contains(
            "} else if store.resolve(ruleId: alert.id, userId: alert.userId, fixAt: lastSeen) {"))
        let store = try source("App/Managers/LocalInactivityStore.swift")
        XCTAssertTrue(store.contains(
            "if let fixAt, !Self.resolvesLapse(triggeredAt: events[idx].triggeredAt, lastFix: fixAt) { return false }"))
    }

    /// The self alerts ("watch me") count silence the same way, and note a
    /// stretch of not sharing the same way, so one can't fire right after a
    /// pause ends.
    func testTheSelfAlertsCountFromThePausesEnd() throws {
        let monitoring = try source("App/Managers/MonitoringManager.swift")
        XCTAssertTrue(monitoring.contains("""
                        let silentFor = now.timeIntervalSince(LocalInactivityStore.activeSince(
                            lastSeen: lastSeen,
                            notSharingSeen: store.notSharingSeen(circleId: circleId, userId: alert.userId), now: now))
        """))
        XCTAssertTrue(monitoring.contains(
            "store.noteNotSharing(circleId: circleId, userId: alert.userId, status: sharing, now: now)"))
    }

    // MARK: - Replayed crossings

    /// The record's rule, at the crossing's own time: a pause set and ended on
    /// another device while this phone was offline is learnt from the server's
    /// spans, and a crossing inside it never goes.
    func testAReplayedCrossingIsJudgedAtItsOwnTime() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("crossing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = CirclePauseRecord(directory: directory)
        var row = PrivacySettings(circleId: circle, sharingMode: "exact", shareRealtime: true, shareHistory: true,
                                  shareBattery: true, bubbleEnabled: false, bubbleRadius: 1, pausedUntil: nil,
                                  updatedAt: now)
        record.observe(row, at: at(0), owner: me)
        row.notSharingIntervals = [PauseInterval(start: at(20), end: at(40), plannedEnd: nil)]
        record.observe(row, at: at(60), owner: me)       // sharing now; the server's span says otherwise then
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(30), owner: me, now: at(61)), "during it")
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(50), owner: me, now: at(61)), "after it")
        XCTAssertTrue(CirclePauseRecord.awaitsRead(record.circle(circle, owner: me, now: at(61)), capturedAt: at(61)),
                      "one later than the last read waits for the next")
    }

    func testTheCrossingReportAsksTheRecord() throws {
        let places = try source("App/Managers/PlaceManager.swift")
        XCTAssertTrue(places.contains(
            "let late = Date().timeIntervalSince(detectedAt) > CirclePauseRecord.skewMargin"))
        XCTAssertTrue(places.contains("""
                    let waiting = late
                        && CirclePauseRecord.shared.awaitsRead(circleId: circleId, capturedAt: detectedAt, owner: userId)
                    if CirclePauseRecord.shared.withholds(circleId: circleId, capturedAt: detectedAt, owner: userId,
                                                          waiting: waiting) {
                        continue
                    }
                    if waiting {
                        awaitingRead = true
                        continue
                    }
        """))
        XCTAssertTrue(places.contains("if !anySent && (postureUnknown || sawReportFailure || awaitingRead) {"))
    }

    // MARK: - A not-sharing member's destination

    func testANotSharingMembersDestinationShowsTheirStatus() {
        func row(by userId: String, status: Destination.Status = .active, creator: String? = nil) -> Destination {
            Destination(id: "d", circleId: circle, userId: userId, name: "Home", latitude: 37.3349, longitude: -122.009,
                        status: status, notifyArrival: true, estimatedArrivalAt: at(30), startedAt: at(-10),
                        arrivedAt: nil, creatorId: creator ?? userId)
        }
        XCTAssertEqual(DestinationsView.statusInPlaceOfETA(row(by: ana), members: [member(ana, sharing: "off")],
                                                           me: me, now: now), "Location sharing off")
        XCTAssertEqual(DestinationsView.statusInPlaceOfETA(row(by: ana), members: [member(ana, sharing: "paused")],
                                                           me: me, now: now), "Paused")
        XCTAssertNil(DestinationsView.statusInPlaceOfETA(row(by: ana), members: [member(ana)], me: me, now: now),
                     "sharing: the ETA")
        XCTAssertNil(DestinationsView.statusInPlaceOfETA(row(by: ana, status: .arrived),
                                                         members: [member(ana, sharing: "off")], me: me, now: now),
                     "an ended one")
        XCTAssertNil(DestinationsView.statusInPlaceOfETA(row(by: me), members: [member(me, sharing: "off")],
                                                         me: me, now: now), "your own")
    }
}
