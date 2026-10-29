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
import PingolinTrackSDK
@testable import Track

/// Pausing: a pause set on one device takes effect on the others at once, and
/// points sent during it are "Dropped".
/// - A silent `privacy_check` wake refreshes every circle's privacy and shows
///   nothing; a switch to approximate sends one fresh, coarsened fix.
/// - `privacy_resumed` refreshes too, and its notice names the circle in plain
///   words at the user's detail level.
/// - No point captured while this account was not sharing with a circle is
///   ever sent to it, however late (`CirclePauseRecord`).
/// - One captured while sharing approximately goes coarsened to the bubble
///   then, whatever the mode when it is sent.
@MainActor
final class PausedSharingTests: XCTestCase {

    private let me = "11111111-1111-1111-1111-111111111111"
    private let other = "22222222-2222-2222-2222-222222222222"
    private let circle = "33333333-3333-3333-3333-333333333333"
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paused-sharing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// Another record, in its own scratch folder.
    private func newRecord(_ name: String) throws -> CirclePauseRecord {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return CirclePauseRecord(directory: folder)
    }

    private func row(_ mode: String = "exact", until: Date? = nil, realtime: Bool = true,
                     recent: [PauseInterval]? = nil, circleId: String? = nil) -> PrivacySettings {
        var settings = PrivacySettings(
            circleId: circleId ?? circle, sharingMode: mode, shareRealtime: realtime, shareHistory: true,
            shareBattery: true, bubbleEnabled: mode == "approximate", bubbleRadius: 1, pausedUntil: until,
            updatedAt: t0)
        settings.notSharingIntervals = recent
        return settings
    }

    // MARK: - The record and its rule

    /// A point captured during a pause and delivered after it ends never
    /// goes to that circle; one captured after the pause does.
    func testAPointCapturedDuringAPauseIsNeverSentAfterItEnds() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row("paused"), at: at(10), exact: true, owner: me)      // paused here
        record.observe(row(), at: at(70), exact: true, owner: me)              // resumed here
        let now = at(300)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(40), owner: me, now: now), "during")
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(80), owner: me, now: now), "after")
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(5), owner: me, now: now), "before")
    }

    /// A pause first seen in a refresh (set on another device) began at the
    /// latest when this account was last seen sharing: from then it holds back.
    func testAPauseFirstSeenInARefreshStartsWhenLastSeenSharing() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row(), at: at(20), owner: me)                           // still sharing at 20
        record.observe(row("paused"), at: at(50), owner: me)                   // learnt at 50
        XCTAssertEqual(record.circle(circle, owner: me, now: at(50))?.observed,
                       [PauseInterval(start: at(20), end: nil, plannedEnd: nil)])
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(25), owner: me, now: at(60)))
        // Seen ending in a refresh: at most then.
        record.observe(row(), at: at(90), owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(90))?.observed.last?.end, at(90))
    }

    /// A pause first seen in a refresh starts where the server's own span
    /// says, so what was kept from before it still goes; without the span,
    /// when this account was last seen sharing (the test above).
    func testAPauseFirstSeenInARefreshStartsWhereTheServerSays() throws {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row(), at: at(20), owner: me)                           // still sharing at 20
        let began = PauseInterval(start: at(40), end: nil, plannedEnd: nil)
        record.observe(row("paused", recent: [began]), at: at(50), owner: me)  // paused elsewhere at 40
        XCTAssertEqual(record.circle(circle, owner: me, now: at(50))?.observed.last?.start, at(40))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(30), owner: me, now: at(60)), "before it")
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(45), owner: me, now: at(60)))
        // An earlier span that has ended is not the one running.
        let other = try newRecord("ended-earlier")
        other.observe(row(), at: at(20), owner: me)
        let ended = PauseInterval(start: at(5), end: at(10), plannedEnd: nil)
        other.observe(row("paused", recent: [ended]), at: at(50), owner: me)
        XCTAssertEqual(other.circle(circle, owner: me, now: at(50))?.observed.last?.start, at(20))
    }

    /// The ordering hole (the same rule as the Android app's): back online, a
    /// point that waited could go before the first refresh, while the record
    /// does not yet know of a pause set and ended elsewhere meanwhile; the
    /// server takes it, as it arrives after the pause. So it waits for a row
    /// read at least a minute after it was taken, and then the pause is known.
    func testAPointThatWaitedGoesOnlyAfterARowReadSinceIt() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)                            // read at 0; offline from 5
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(20), owner: me, now: at(40)), "not known yet")
        XCTAssertTrue(record.awaitsRead(circleId: circle, capturedAt: at(20), owner: me, now: at(40)), "so it waits")
        XCTAssertTrue(record.awaitsRead(circleId: circle, capturedAt: at(30), owner: me, now: at(40)), "this one too")
        let missed = PauseInterval(start: at(15), end: at(25), plannedEnd: nil)   // paused elsewhere meanwhile
        record.observe(row(recent: [missed]), at: at(41), owner: me)           // back online: the refresh
        XCTAssertFalse(record.awaitsRead(circleId: circle, capturedAt: at(20), owner: me, now: at(42)))
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(20), owner: me, now: at(42)), "now known: dropped")
        XCTAssertFalse(record.awaitsRead(circleId: circle, capturedAt: at(30), owner: me, now: at(42)))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(30), owner: me, now: at(42)), "not covered: it goes")
        // Read less than a minute after it was taken: still waiting.
        XCTAssertTrue(record.awaitsRead(circleId: circle, capturedAt: at(40.5), owner: me, now: at(42)))
        XCTAssertFalse(record.awaitsRead(circleId: circle, capturedAt: at(39.5), owner: me, now: at(42)))
    }

    /// A point that waits for a read is kept, not dropped for what the record
    /// does not know yet (no record at all here); the read decides. A span the
    /// record does know still holds it back, so it is never kept.
    func testAWaitingPointIsKeptNotDroppedForWhatAReadWillTell() {
        let record = CirclePauseRecord(directory: directory)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(0), owner: me, now: at(10)), "a live send's: fail closed")
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(0), owner: me, now: at(10), waiting: true))
        XCTAssertTrue(record.awaitsRead(circleId: circle, capturedAt: at(0), owner: me, now: at(10)), "kept for the read")
        record.observe(row(recent: []), at: at(20), owner: me)                 // the read: no span covers it
        XCTAssertFalse(record.awaitsRead(circleId: circle, capturedAt: at(0), owner: me, now: at(21)))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(0), owner: me, now: at(21)), "so it goes")
        record.observe(row("paused"), at: at(30), exact: true, owner: me)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(35), owner: me, now: at(40), waiting: true))
    }

    /// A save made here is no read (its copy carries no spans); the answer to a
    /// Resume is (the server's own row). Nothing known: it waits. Personal
    /// history never waits.
    func testOnlyARowReadFromTheServerReleasesAWaitingPoint() {
        let record = CirclePauseRecord(directory: directory)
        XCTAssertTrue(record.awaitsRead(circleId: circle, capturedAt: at(0), owner: me, now: at(5)), "no record")
        XCTAssertFalse(record.awaitsRead(circleId: SelfKeyManager.selfCircleUuid, capturedAt: at(0), owner: me, now: at(5)))
        record.observe(row(), at: at(0), owner: me)
        record.observe(CircleManager.storedCopy(after: approximate(2)), at: at(10), exact: true, owner: me)
        XCTAssertTrue(record.awaitsRead(circleId: circle, capturedAt: at(5), owner: me, now: at(12)), "a save's copy")
        record.observe(row(recent: []), at: at(20), exact: true, owner: me)    // a Resume's answer
        XCTAssertFalse(record.awaitsRead(circleId: circle, capturedAt: at(5), owner: me, now: at(21)))
        record.observe(.default(for: circle), at: at(30), owner: me)           // no row on the server: its word too
        XCTAssertFalse(record.awaitsRead(circleId: circle, capturedAt: at(25), owner: me, now: at(31)))
    }

    /// A pause set and ended on another device while this one was offline is
    /// never seen at a refresh, only in the server's record.
    func testAMissedPauseIsLearntFromTheServer() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        let missed = PauseInterval(start: at(30), end: at(60), plannedEnd: nil)
        record.observe(row(recent: [missed]), at: at(120), owner: me)          // sharing now, missed meanwhile
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(45), owner: me, now: at(130)))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(90), owner: me, now: at(130)))
        // The server's window also reaches back past this device's first refresh.
        let earlier = PauseInterval(start: at(-600), end: at(-500), plannedEnd: nil)
        record.observe(row(recent: [earlier, missed]), at: at(130), owner: me)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(-550), owner: me, now: at(140)))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(-300), owner: me, now: at(140)),
                       "known from the server's record, and not paused then")
    }

    /// Boundaries are server times, capture times this device's clock: a
    /// point this close to an interval counts as inside.
    func testTheSkewMargin() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        let pause = PauseInterval(start: at(30), end: at(60), plannedEnd: nil)
        record.observe(row(recent: [pause]), at: at(100), owner: me)
        let margin = CirclePauseRecord.skewMargin
        let now = at(200)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(60).addingTimeInterval(margin - 1), owner: me, now: now))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(60).addingTimeInterval(margin + 1), owner: me, now: now))
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(30).addingTimeInterval(-(margin - 1)), owner: me, now: now))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(30).addingTimeInterval(-(margin + 1)), owner: me, now: now))
    }

    /// A timed pause stops holding back at its planned end, as `isPaused`
    /// lets this phone send again, without waiting for a refresh.
    func testATimedPauseEndsOnTimeWithoutARefresh() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row("paused", until: at(60)), at: at(10), exact: true, owner: me)
        let margin = CirclePauseRecord.skewMargin
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(59), owner: me, now: at(59)))
        let afterwards = at(60).addingTimeInterval(margin + 1)
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: afterwards, owner: me, now: afterwards))
        // Seen ending in a refresh later: it ended at its planned end, not then.
        record.observe(row(), at: at(120), owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(120))?.observed.last?.end, at(60))
    }

    /// Real time off is not sharing too: the send gate's rule, and ingest's.
    func testRealTimeOffIsNotSharing() {
        XCTAssertFalse(CirclePauseRecord.shares(row(realtime: false), at: t0))
        XCTAssertFalse(CirclePauseRecord.shares(row("paused"), at: t0))
        XCTAssertFalse(CirclePauseRecord.shares(row("paused", until: at(1)), at: t0))
        XCTAssertTrue(CirclePauseRecord.shares(row("paused", until: at(-1)), at: t0), "a lapsed pause")
        XCTAssertTrue(CirclePauseRecord.shares(row("approximate"), at: t0))
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row(realtime: false), at: at(10), exact: true, owner: me)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(20), owner: me, now: at(30)))
    }

    /// Personal history is never held back.
    func testPersonalHistoryIsNeverWithheld() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(circleId: SelfKeyManager.selfCircleUuid), at: at(0), owner: me)
        XCTAssertNil(record.circle(SelfKeyManager.selfCircleUuid, owner: me))
        XCTAssertFalse(record.withholds(circleId: SelfKeyManager.selfCircleUuid, capturedAt: at(-1_000),
                                        owner: me, now: at(0)))
    }

    /// Nothing known yet: a late point is held back (fail closed), a live one
    /// is not (the send gate decides it, as before).
    func testBeforeAnythingIsKnownALatePointIsHeldBack() {
        let record = CirclePauseRecord(directory: directory)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(-10), owner: me, now: at(0)))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(0), owner: me, now: at(0)))
        record.observe(row(), at: at(0), owner: me)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(-10), owner: me, now: at(5)),
                      "before this device first knew")
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(2), owner: me, now: at(5)))
    }

    /// Durable across a relaunch, per account, and pruned past the late window.
    func testDurablePerAccountAndPruned() {
        let first = CirclePauseRecord(directory: directory)
        first.observe(row(), at: at(0), owner: me)
        first.observe(row("paused"), at: at(10), exact: true, owner: me)
        first.observe(row(), at: at(20), exact: true, owner: me)
        let relaunched = CirclePauseRecord(directory: directory)
        XCTAssertTrue(relaunched.withholds(circleId: circle, capturedAt: at(15), owner: me, now: at(30)))
        // Another account's file is dropped, never read as this one's.
        relaunched.observe(row(), at: at(40), owner: other)
        XCTAssertNil(CirclePauseRecord(directory: directory).circle(circle, owner: me, now: at(41)))
        // Past the late window, an ended interval is gone.
        let pruned = CirclePauseRecord(directory: directory)
        pruned.observe(row(), at: at(0), owner: me)
        pruned.observe(row("paused"), at: at(10), exact: true, owner: me)
        pruned.observe(row(), at: at(20), exact: true, owner: me)
        let late = at(20).addingTimeInterval(CirclePauseRecord.keepFor + 60)
        XCTAssertEqual(pruned.circle(circle, owner: me, now: late)?.observed, [])
        XCTAssertGreaterThanOrEqual(CirclePauseRecord.keepFor, 72 * 3600, "ingest's window: up to ~72 h")
    }

    func testSignOutEmptiesIt() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row("paused"), at: at(0), exact: true, owner: me)
        record.clearAll()
        XCTAssertNil(CirclePauseRecord(directory: directory).circle(circle, owner: me, now: at(1)))
    }

    // MARK: - The server's record on the wire

    func testNotSharingIntervalsAreReadFromTheRow() throws {
        // As the server writes them: RFC 3339, "+00:00", fractional seconds possible.
        let json = """
        {"id": "44444444-4444-4444-4444-444444444444", "circle_id": "\(circle)", "sharing_mode": "exact",
         "share_realtime": true, "share_history": true, "share_battery": true, "show_all_devices": false,
         "not_sharing_intervals": [
           {"start": "2026-10-14T10:00:00+00:00", "end": "2026-10-14T11:00:00.500+00:00"},
           {"start": "not a time", "end": null},
           {"start": "2026-10-14T12:00:00.250+00:00", "end": "garbled"},
           {"start": "2026-10-14T14:00:00+00:00", "end": null}
         ]}
        """
        let response = try APIService.makeWireDecoder().decode(PrivacySettingsResponse.self, from: Data(json.utf8))
        let spans = try XCTUnwrap(CircleManager.privacySettings(from: response).notSharingIntervals)
        XCTAssertEqual(spans.count, 4, "every span is kept, whatever does not read")
        guard spans.count == 4 else { return }
        XCTAssertEqual(spans[0].start, ISO8601DateFormatter().date(from: "2026-10-14T10:00:00Z"))
        XCTAssertEqual(spans[0].end.map { $0.timeIntervalSince1970 },
                       ISO8601DateFormatter().date(from: "2026-10-14T11:00:00Z").map { $0.timeIntervalSince1970 + 0.5 })
        XCTAssertEqual(spans[1].start, .distantPast, "a start that does not read: from the beginning (fail closed)")
        XCTAssertNil(spans[2].end, "an end that does not read is taken as still running")
        XCTAssertNil(spans[3].end, "still not sharing, no end known")
        XCTAssertEqual(spans[3].lastCovered, .distantFuture)
        // A span whose start cannot be placed holds back everything before its end.
        let now = Date()
        let ended = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1_800))
        let unplaced = try APIService.makeWireDecoder().decode(PrivacySettingsResponse.self, from: Data("""
        {"id": "44444444-4444-4444-4444-444444444444", "circle_id": "\(circle)", "sharing_mode": "exact",
         "share_realtime": true, "share_history": true, "share_battery": true, "show_all_devices": false,
         "not_sharing_intervals": [{"start": "not a time", "end": "\(ended)"}]}
        """.utf8))
        let record = CirclePauseRecord(directory: directory)
        record.observe(CircleManager.privacySettings(from: unplaced), at: now, owner: me)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: now.addingTimeInterval(-7_200), owner: me, now: now))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: now.addingTimeInterval(-600), owner: me, now: now))
        let older = try APIService.makeWireDecoder().decode(PrivacySettingsResponse.self, from: Data("""
        {"id": "44444444-4444-4444-4444-444444444444", "circle_id": "\(circle)", "sharing_mode": "exact",
         "share_realtime": true, "share_history": true, "share_battery": true, "show_all_devices": false}
        """.utf8))
        XCTAssertNil(CircleManager.privacySettings(from: older).notSharingIntervals, "an older server")
    }

    /// The server's record as last read has the pause running, or planned past
    /// now; a Resume, or real time back on, in a save made here (whose answer
    /// has no spans) ends it then, so live points go again at once.
    func testASaveMadeHereEndsTheServersRunningSpans() throws {
        let record = CirclePauseRecord(directory: directory)
        let running = PauseInterval(start: at(10), end: nil, plannedEnd: nil)
        record.observe(row("paused", recent: [running]), at: at(20), owner: me)
        var resumed = CircleManager.storedCopy(after: row("paused", recent: [running]))
        resumed.resume()
        XCTAssertNil(CircleManager.storedCopy(after: resumed).notSharingIntervals, "a PUT answers no spans")
        record.observe(CircleManager.storedCopy(after: resumed), at: at(30), exact: true, owner: me)
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(32), owner: me, now: at(32)))
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(25), owner: me, now: at(32)), "the pause still holds")
        // A timed pause ended early: its planned end no longer covers.
        let timed = try newRecord("timed")
        let planned = PauseInterval(start: at(10), end: at(600), plannedEnd: nil)
        timed.observe(row("paused", until: at(600), recent: [planned]), at: at(20), owner: me)
        timed.observe(row(realtime: true), at: at(30), exact: true, owner: me)
        XCTAssertFalse(timed.withholds(circleId: circle, capturedAt: at(40), owner: me, now: at(40)))
        // Real time switched back on.
        let realtime = try newRecord("realtime")
        realtime.observe(row(realtime: false, recent: [running]), at: at(20), owner: me)
        realtime.observe(row(), at: at(30), exact: true, owner: me)
        XCTAssertFalse(realtime.withholds(circleId: circle, capturedAt: at(40), owner: me, now: at(40)))
    }

    // MARK: - A switch to approximate sends one fresh fix

    func testOnlyASwitchFromExactToApproximateAsksForAFreshFix() {
        let other = "55555555-5555-5555-5555-555555555555"
        let before = [circle: row(), other: row("approximate")]
        XCTAssertEqual(CircleManager.newlyApproximate(before: before, after: [circle: row("approximate"),
                                                                               other: row("approximate")], at: t0),
                       [circle])
        XCTAssertEqual(CircleManager.newlyApproximate(before: [circle: row("paused")],
                                                      after: [circle: row("approximate")], at: t0), [],
                       "back from a pause: its last fixes were coarsened already")
        XCTAssertEqual(CircleManager.newlyApproximate(before: [:], after: [circle: row("approximate")], at: t0), [],
                       "a circle new to the list")
        XCTAssertEqual(CircleManager.newlyApproximate(before: before, after: before, at: t0), [])
    }

    // MARK: - The notice, named at the detail level

    func testTheResumedNoticeNamesTheCircleAtFullDetailOnly() {
        let title = "Location Sharing Resumed"
        let body = "Your location sharing pause has ended and sharing has automatically resumed."
        let names = NamedNotificationCopy.Names(circle: "Family")
        let full = NamedNotificationCopy.row(type: "privacy_resumed", title: title, body: body, names: names, level: "full")
        XCTAssertEqual(full?.title, title)
        XCTAssertEqual(full?.body, "Your location sharing pause in Family has ended and sharing has automatically resumed.")
        XCTAssertNil(NamedNotificationCopy.row(type: "privacy_resumed", title: title, body: body, names: names, level: "names"),
                     "Names only: no circle, the server's words")
        XCTAssertNil(NamedNotificationCopy.row(type: "privacy_resumed", title: title, body: body, names: names, level: "generic"))
        XCTAssertNil(NamedNotificationCopy.row(type: "privacy_resumed", title: title, body: body,
                                               names: .init(), level: "full"), "no circle opened: the server's words")
    }

    // MARK: - Approximate at capture stays approximate

    private func approximate(_ radius: Double, recent: [ApproximateInterval]? = nil) -> PrivacySettings {
        var settings = row("approximate")
        settings.bubbleRadius = radius
        settings.approximateIntervals = recent
        return settings
    }

    private func payload(at time: Date) -> PingolinTrackSDK.Location {
        PingolinTrackSDK.Location(latitude: 37.3349, longitude: -122.0090, altitude: 20, speed: 1.5, heading: 90,
                                  accuracy: 8, timestamp: Int64(time.timeIntervalSince1970 * 1000),
                                  batteryLevel: 80, isCharging: false)
    }

    /// A point taken while approximate (2 mi) and sent after a switch to
    /// exact goes coarsened to 2 mi; one taken after the switch goes exact.
    func testALatePointTakenWhileApproximateGoesCoarsenedAfterASwitchToExact() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(approximate(2), at: at(10), exact: true, owner: me)
        record.observe(row(), at: at(30), exact: true, owner: me)
        let now = at(60)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(20), owner: me, now: now), 2)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(40), owner: me, now: now))
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(5), owner: me, now: now))
        // The skew margin before it; none after a switch made here.
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(9.5), owner: me, now: now), 2)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(8.5), owner: me, now: now))
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(29.9), owner: me, now: now), 2)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(30.1), owner: me, now: now))
        // What the circle receives, now that the row says exact.
        let late = SDKLocationStreamer.privacyApplied(payload(at: at(20)), circleId: circle, privacy: row(), now: now,
                                                      captureRadiusMiles: 2)
        XCTAssertEqual(late.coarsenedToMiles, 2)
        XCTAssertNotEqual(late.location.latitude, 37.3349)
        XCTAssertNil(late.location.speed, "nothing to dead-reckon with")
        let fresh = SDKLocationStreamer.privacyApplied(payload(at: at(40)), circleId: circle, privacy: row(), now: now,
                                                       captureRadiusMiles: nil)
        XCTAssertNil(fresh.coarsenedToMiles)
        XCTAssertEqual(fresh.location.latitude, 37.3349)
    }

    /// A switch seen in a refresh began at the latest when the account was
    /// last seen sharing exactly.
    func testASwitchSeenInARefreshStartsWhenLastSeenExact() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row(), at: at(20), owner: me)
        record.observe(approximate(1), at: at(50), owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(50))?.observedApproximate,
                       [ApproximateInterval(start: at(20), end: nil, radiusMiles: 1)])
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(25), owner: me, now: at(60)), 1)
    }

    /// As for a pause: with the server's stretch, a switch seen in a refresh
    /// starts where it says, so what was taken while still exact goes exact.
    func testASwitchSeenInARefreshStartsWhereTheServerSays() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row(), at: at(20), owner: me)
        let began = ApproximateInterval(start: at(40), end: nil, radiusMiles: 2)
        record.observe(approximate(2, recent: [began]), at: at(50), owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(50))?.observedApproximate, [began])
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(30), owner: me, now: at(60)))
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(45), owner: me, now: at(60)), 2)
    }

    /// A new bubble seen in a refresh: the old one held until then at most, the
    /// new one since the old one was last seen; between, the larger.
    func testANewBubbleSeenInARefreshOverlapsTheOld() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(approximate(1), at: at(10), exact: true, owner: me)
        record.observe(approximate(5), at: at(50), owner: me)
        let now = at(80)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(30), owner: me, now: now), 5)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(70), owner: me, now: now), 5)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(5), owner: me, now: now))
    }

    /// An approximate stretch set and ended elsewhere while offline: from the
    /// server's record.
    func testAMissedApproximateStretchIsLearntFromTheServer() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        var exact = row()
        exact.approximateIntervals = [ApproximateInterval(start: at(30), end: at(60), radiusMiles: 3)]
        record.observe(exact, at: at(120), owner: me)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(45), owner: me, now: at(130)), 3)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(90), owner: me, now: at(130)))
        // The server's times against this device's clock: the margin, either side.
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(29.5), owner: me, now: at(130)), 3)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(60.5), owner: me, now: at(130)), 3)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(61.5), owner: me, now: at(130)))
    }

    /// Nothing known of the time: a late point goes in the largest bubble a
    /// member can set, 25 miles (fail closed), whatever is known since; a live
    /// one is left to the mode now.
    func testUnknownHistoryCoarsensALatePointToTheLargestBubble() {
        let record = CirclePauseRecord(directory: directory)
        XCTAssertEqual(CirclePauseRecord.unknownBubbleMiles, 25)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(-10), owner: me, now: at(0)), 25,
                       "no record of the circle at all")
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(0), owner: me, now: at(0)))
        record.observe(row(), at: at(0), owner: me)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(-30), owner: me, now: at(20)), 25,
                       "before this device first knew, no bubble known at all")
        record.observe(approximate(4), at: at(10), exact: true, owner: me)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(-30), owner: me, now: at(20)), 25,
                       "before this device first knew: not the bubble known since")
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(5), owner: me, now: at(20)), "known exact")
        // A row whose own bubble is none: the largest too.
        record.observe(approximate(0), at: at(30), exact: true, owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(30))?.observedApproximate.last?.radiusMiles, 25)
    }

    func testTheLargerBubbleWinsAndSelfIsNeverCoarsened() {
        let now = at(0)
        XCTAssertEqual(SDKLocationStreamer.privacyApplied(payload(at: now), circleId: circle, privacy: approximate(1),
                                                          now: now, captureRadiusMiles: 4).coarsenedToMiles, 4)
        XCTAssertEqual(SDKLocationStreamer.privacyApplied(payload(at: now), circleId: circle, privacy: approximate(5),
                                                          now: now, captureRadiusMiles: 2).coarsenedToMiles, 5)
        let mine = SDKLocationStreamer.privacyApplied(payload(at: now), circleId: SelfKeyManager.selfCircleUuid,
                                                      privacy: nil, now: now, captureRadiusMiles: 3)
        XCTAssertNil(mine.coarsenedToMiles, "personal history stays exact")
        let record = CirclePauseRecord(directory: directory)
        XCTAssertNil(record.captureRadius(circleId: SelfKeyManager.selfCircleUuid, capturedAt: at(-1_000), owner: me, now: now))
    }

    func testApproximateIntervalsAreReadFromTheRow() throws {
        let json = """
        {"id": "44444444-4444-4444-4444-444444444444", "circle_id": "\(circle)", "sharing_mode": "approximate",
         "approximate_radius_miles": 2, "share_realtime": true, "share_history": true, "share_battery": true,
         "show_all_devices": false,
         "approximate_intervals": [
           {"start": "2026-10-14T10:00:00+00:00", "end": "2026-10-14T11:00:00.500+00:00", "radius_miles": 7},
           {"start": "nope", "end": "2026-10-14T11:30:00+00:00", "radius_miles": 3},
           {"start": "2026-10-14T12:00:00+00:00", "end": "garbled"},
           {"start": "2026-10-14T13:00:00+00:00", "end": null, "radius_miles": 0}
         ]}
        """
        let response = try APIService.makeWireDecoder().decode(PrivacySettingsResponse.self, from: Data(json.utf8))
        let spans = try XCTUnwrap(CircleManager.privacySettings(from: response).approximateIntervals)
        XCTAssertEqual(spans.count, 4, "every span is kept, whatever does not read")
        guard spans.count == 4 else { return }
        XCTAssertEqual(spans[0].start, ISO8601DateFormatter().date(from: "2026-10-14T10:00:00Z"))
        XCTAssertEqual(spans[0].radiusMiles, 7)
        XCTAssertEqual(spans[0].end.map { $0.timeIntervalSince1970 },
                       ISO8601DateFormatter().date(from: "2026-10-14T11:00:00Z").map { $0.timeIntervalSince1970 + 0.5 })
        XCTAssertEqual(spans[1].start, .distantPast, "a start that does not read: from the beginning")
        XCTAssertEqual(spans[1].radiusMiles, 3)
        XCTAssertNil(spans[2].end, "an end that does not read: still running")
        XCTAssertEqual(spans[2].radiusMiles, 25, "no bubble on the span: the largest a member can set")
        XCTAssertEqual(spans[3].radiusMiles, 25, "a bubble that is none: the largest a member can set")
        let older = try APIService.makeWireDecoder().decode(PrivacySettingsResponse.self, from: Data("""
        {"id": "44444444-4444-4444-4444-444444444444", "circle_id": "\(circle)", "sharing_mode": "approximate",
         "approximate_radius_miles": 2, "share_realtime": true, "share_history": true, "share_battery": true,
         "show_all_devices": false}
        """.utf8))
        XCTAssertNil(CircleManager.privacySettings(from: older).approximateIntervals, "an older server")
    }

    /// The same for a bubble: exact again, or another bubble, in a save made
    /// here ends the server's running stretch then.
    func testASaveMadeHereEndsTheServersRunningBubble() throws {
        let record = CirclePauseRecord(directory: directory)
        let bubble = ApproximateInterval(start: at(10), end: nil, radiusMiles: 3)
        record.observe(approximate(3, recent: [bubble]), at: at(20), owner: me)
        var exact = approximate(3, recent: [bubble])
        exact.chooseBubble(false)
        XCTAssertNil(CircleManager.storedCopy(after: exact).approximateIntervals, "a PUT answers no spans")
        record.observe(CircleManager.storedCopy(after: exact), at: at(30), exact: true, owner: me)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(40), owner: me, now: at(45)))
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(25), owner: me, now: at(45)), 3)
        // Another bubble: the old one ends, the new one counts from then.
        let resized = try newRecord("resized")
        resized.observe(approximate(3, recent: [bubble]), at: at(20), owner: me)
        resized.observe(CircleManager.storedCopy(after: approximate(1, recent: [bubble])), at: at(30), exact: true, owner: me)
        XCTAssertEqual(resized.captureRadius(circleId: circle, capturedAt: at(40), owner: me, now: at(45)), 1)
        XCTAssertEqual(resized.captureRadius(circleId: circle, capturedAt: at(25), owner: me, now: at(45)), 3)
    }

    /// Written at once, kept while it runs however long, and an ended one
    /// pruned with the pauses.
    func testApproximateStretchesAreDurableAndPruned() throws {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(approximate(2), at: at(1), exact: true, owner: me)
        let reread = CirclePauseRecord(directory: directory)
        XCTAssertEqual(reread.captureRadius(circleId: circle, capturedAt: at(2), owner: me, now: at(3)), 2)
        let days = at(100 * 60)
        XCTAssertEqual(reread.captureRadius(circleId: circle, capturedAt: days.addingTimeInterval(-1_800), owner: me,
                                            now: days), 2, "still running after 100 hours")
        let ended = try newRecord("ended")
        ended.observe(row(), at: at(0), owner: me)
        ended.observe(approximate(2), at: at(10), exact: true, owner: me)
        ended.observe(row(), at: at(20), exact: true, owner: me)
        XCTAssertEqual(ended.circle(circle, owner: me, now: at(20 + 97 * 60))?.observedApproximate, [])
    }

    /// A Resume made here ends the pause by this device's own clock, so Send
    /// location right after it goes, the server's copy (ended a moment later
    /// by its clock) included. A pause set afterwards still holds, with its
    /// margin; one that ended elsewhere keeps the margin.
    func testAResumeMadeHereHasNoMarginAfterIt() throws {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(row("paused"), at: at(10), exact: true, owner: me)
        record.observe(row("paused", recent: [PauseInterval(start: at(10), end: nil, plannedEnd: nil)]), at: at(20), owner: me)
        record.observe(row(), at: at(30), exact: true, owner: me)                              // Resume, here
        let resumed = PauseInterval(start: at(10), end: at(30.2), plannedEnd: nil)
        record.observe(row(recent: [resumed]), at: at(30.5), owner: me)
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(30.1), owner: me, now: at(30.5)), "at once")
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(29.9), owner: me, now: at(31)), "before it")
        let quick = PauseInterval(start: at(30.3), end: at(30.6), plannedEnd: nil)              // set elsewhere just after
        let later = PauseInterval(start: at(40), end: at(50), plannedEnd: nil)
        record.observe(row(recent: [resumed, quick, later]), at: at(60), owner: me)
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(30.4), owner: me, now: at(61)), "a pause set after it")
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(45), owner: me, now: at(61)))
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(50.5), owner: me, now: at(61)), "with its margin")
        // Ended elsewhere: the margin stays.
        let elsewhere = try newRecord("elsewhere")
        elsewhere.observe(row(), at: at(0), owner: me)
        elsewhere.observe(row("paused"), at: at(10), exact: true, owner: me)
        elsewhere.observe(row(recent: [PauseInterval(start: at(10), end: at(30), plannedEnd: nil)]), at: at(30), owner: me)
        XCTAssertTrue(elsewhere.withholds(circleId: circle, capturedAt: at(30.5), owner: me, now: at(31)))
    }

    /// The same for a bubble: another bubble, or exact again, made here.
    func testABubbleChangeMadeHereHasNoMarginAfterIt() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(approximate(5), at: at(10), exact: true, owner: me)
        record.observe(CircleManager.storedCopy(after: approximate(2)), at: at(30), exact: true, owner: me)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(30.1), owner: me, now: at(30.2)), 2)
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(29.9), owner: me, now: at(31)), 5)
        var exact = approximate(2)
        exact.chooseBubble(false)
        record.observe(CircleManager.storedCopy(after: exact), at: at(40), exact: true, owner: me)
        XCTAssertNil(record.captureRadius(circleId: circle, capturedAt: at(40.1), owner: me, now: at(40.2)))
        XCTAssertEqual(record.captureRadius(circleId: circle, capturedAt: at(35), owner: me, now: at(41)), 2)
    }

    /// A pause taken from approximate keeps the stretch (nothing goes during
    /// it), and one back to exact ends it.
    func testAPauseFromApproximateKeepsTheStretch() {
        let record = CirclePauseRecord(directory: directory)
        record.observe(row(), at: at(0), owner: me)
        record.observe(approximate(2), at: at(10), exact: true, owner: me)
        var paused = approximate(2)
        paused.pause(until: nil)
        record.observe(paused, at: at(20), exact: true, owner: me)
        record.observe(approximate(2), at: at(30), exact: true, owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(30))?.observedApproximate,
                       [ApproximateInterval(start: at(10), end: nil, radiusMiles: 2)])
        var toExact = paused
        toExact.modeBeforePause = "exact"
        toExact.alignBubbleWithPause(at: at(40))
        record.observe(toExact, at: at(40), exact: true, owner: me)
        XCTAssertEqual(record.circle(circle, owner: me, now: at(40))?.observedApproximate.last?.end, at(40))
    }

    // MARK: - One read after an offline stretch

    /// After an offline stretch (a failed send, a rebuilt stream, this process
    /// starting), a circle not read since then is unread until a row is read
    /// from the server; a save's own copy is no read. Personal history never
    /// waits.
    func testAfterAnOfflineStretchACircleIsUnreadUntilARead() {
        let record = CirclePauseRecord(directory: directory, startedAt: at(0))
        XCTAssertTrue(record.unreadSinceOffline(circleId: circle, owner: me, now: at(0)), "nothing read yet")
        record.observe(row(), at: at(1), owner: me)
        XCTAssertFalse(record.unreadSinceOffline(circleId: circle, owner: me, now: at(2)), "no failure: no read owed")
        record.noteOffline(at: at(10))                                                   // a send failed
        XCTAssertTrue(record.unreadSinceOffline(circleId: circle, owner: me, now: at(11)))
        record.observe(CircleManager.storedCopy(after: row()), at: at(11), exact: true, owner: me)
        XCTAssertTrue(record.unreadSinceOffline(circleId: circle, owner: me, now: at(12)), "a save's own copy is no read")
        record.observe(row(), at: at(12), owner: me)                                     // the refresh
        XCTAssertFalse(record.unreadSinceOffline(circleId: circle, owner: me, now: at(13)))
        record.noteOffline(at: at(5))
        XCTAssertFalse(record.unreadSinceOffline(circleId: circle, owner: me, now: at(13)), "an older mark changes nothing")
        // Nor does it move the stretch back (a clock set back): a read before
        // the newer mark is still no read since it.
        record.noteOffline(at: at(20))
        record.noteOffline(at: at(15))
        record.observe(row(), at: at(17), owner: me)
        XCTAssertTrue(record.unreadSinceOffline(circleId: circle, owner: me, now: at(18)), "the newer mark stands")
        XCTAssertFalse(record.unreadSinceOffline(circleId: SelfKeyManager.selfCircleUuid, owner: me, now: at(13)))
        // This process starting is one too: what was read before it is unread until a read.
        let relaunched = CirclePauseRecord(directory: directory, startedAt: at(30))
        XCTAssertTrue(relaunched.unreadSinceOffline(circleId: circle, owner: me, now: at(30)))
    }

    /// The check-in's case: after a failed send, the one refresh brings a pause
    /// set and ended elsewhere meanwhile, and a held fix taken in it is held
    /// back; one taken after it goes.
    func testAfterTheReadAHeldFixInAMissedPauseIsHeldBack() {
        let record = CirclePauseRecord(directory: directory, startedAt: at(0))
        record.observe(row(), at: at(1), owner: me)
        record.noteOffline(at: at(10))
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(15), owner: me, now: at(20)), "unknown before it")
        let missed = PauseInterval(start: at(13), end: at(17), plannedEnd: nil)
        record.observe(row(recent: [missed]), at: at(20), owner: me)
        XCTAssertFalse(record.unreadSinceOffline(circleId: circle, owner: me, now: at(21)))
        XCTAssertTrue(record.withholds(circleId: circle, capturedAt: at(15), owner: me, now: at(21)), "held back")
        XCTAssertFalse(record.withholds(circleId: circle, capturedAt: at(19), owner: me, now: at(21)), "after it: goes")
    }

    /// One refresh, shared by every caller; not tried again within a minute (a
    /// failed one waits for the next caller, no loop); and a check-in waits for
    /// it a bounded time only.
    func testOneReadAfterAnOfflineStretchIsSharedBoundedAndNotLooped() async {
        var reads = 0
        var finished = 0
        let reader = PrivacyReadAfterOffline {
            reads += 1
            try? await Task.sleep(nanoseconds: 300_000_000)
            finished += 1
        }
        let start = Date()
        let first = Task { await reader.refresh(within: 2, now: start) }
        while reads == 0 { await Task.yield() }                                        // the refresh runs
        await reader.refresh(within: 2, now: start)
        XCTAssertEqual(finished, 1, "a second caller waits for the refresh that runs")
        await first.value
        XCTAssertEqual(reads, 1, "two callers, one refresh")
        await reader.refresh(within: 2, now: start.addingTimeInterval(30))
        XCTAssertEqual(reads, 1, "not again within a minute")
        await reader.refresh(within: 2, now: start.addingTimeInterval(61))
        XCTAssertEqual(reads, 2, "the next caller after that tries again")
        XCTAssertLessThanOrEqual(PrivacyReadAfterOffline.waitAtMost, 10, "inside a background wake's time")
        let hung = PrivacyReadAfterOffline { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        let began = Date()
        await hung.refresh(within: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(began), 2, "the check-in waits a bounded time")
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(_ src: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(src.range(of: start), start)
        let b = try XCTUnwrap(src.range(of: end, range: a.upperBound..<src.endIndex), end)
        return String(src[a.lowerBound..<b.lowerBound])
    }

    /// The wake refreshes every circle and posts nothing; the resumed
    /// notice refreshes too.
    func testTheWakesRefreshAndShowNothing() throws {
        let push = try source("App/Managers/PushNotificationManager.swift")
        let check = try body(push, from: "        case \"privacy_check\":\n", to: "        case \"privacy_resumed\":\n")
        XCTAssertTrue(check.contains("Self.answer(completionHandler) { await Self.refreshPrivacy() }"),
                      "answered within the wake's budget")
        for shows in ["UNUserNotificationCenter", "UNMutableNotificationContent", ".add(", "post"] {
            XCTAssertFalse(check.contains(shows), "the wake shows nothing: \(shows)")
        }
        let resumed = try body(push, from: "        case \"privacy_resumed\":\n", to: "        case \"wake_location\":\n")
        XCTAssertTrue(resumed.contains("            Self.answer(completionHandler) {\n"
                                       + "                await Self.refreshPrivacy()\n"
                                       + "                await NotificationsManager.shared.refresh()\n"))
        let refresh = try body(push, from: "    static func refreshPrivacy() async {", to: "    /// What a push asks the app to re-fetch.")
        let load = try XCTUnwrap(refresh.range(of: "try? await CircleManager.shared.loadCircles(light: true)"))
        let fresh = try XCTUnwrap(refresh.range(of: "await CircleManager.shared.sendFreshFixIfNewlyApproximate(before: before)"))
        XCTAssertLessThan(load.upperBound, fresh.lowerBound)
        // On the key the relay forwards: `alert_type` (no circle id rides it).
        XCTAssertTrue(push.contains("?? (userInfo[\"alert_type\"] as? String)"))
    }

    /// A wake answers its push once, by the budget at the latest, while the
    /// work goes on; work done sooner answers then.
    func testAWakeIsAnsweredOnceWithinItsBudget() async throws {
        XCTAssertLessThanOrEqual(PushAppDelegate.wakeBudget, 25, "iOS allows about 30 s")
        var answers: [UIBackgroundFetchResult] = []
        let answered = expectation(description: "answered by the budget")
        answered.assertForOverFulfill = false   // a second answer is counted below
        PushAppDelegate.answer({ answers.append($0); answered.fulfill() }, within: 0.2) {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        await fulfillment(of: [answered], timeout: 1.5)
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(answers, [.newData], "once, though the work ended after")
        var quick: [UIBackgroundFetchResult] = []
        PushAppDelegate.answer({ quick.append($0) }, within: 1) {}
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(quick, [.newData], "work done: answered then")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(quick, [.newData], "and not again at the budget")
    }

    /// Fed by every row the server gives, and asked before every send.
    func testEveryRowFeedsTheRecordAndEverySendAsksIt() throws {
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("        if listedNow {\n            let now = Date()\n            for settings in privacyPlan.embedded.values {\n"
                                       + "                CirclePauseRecord.shared.observe(settings, at: now, owner: AuthManager.shared.userId)"))
        let fetch = try body(circles, from: "    func loadPrivacySettings(for circleId: String) async throws {",
                             to: "    /// The one translation from the server's privacy row")
        XCTAssertEqual(fetch.components(separatedBy: "CirclePauseRecord.shared.observe(").count - 1, 2, "a row, and the default")
        let save = try body(circles, from: "    func updatePrivacySettings(_ settings: PrivacySettings, for owner: String?) async throws {",
                            to: "    /// A save, as the requests it takes")
        XCTAssertTrue(save.contains("CirclePauseRecord.shared.observe($0, at: Date(), exact: true, owner: AuthManager.shared.userId)"))
        XCTAssertTrue(save.contains("defer { Task { await self.sendFreshFixIfNewlyApproximate(before: before) } }"))
        XCTAssertTrue(circles.contains("CirclePauseRecord.shared.observe(Self.privacySettings(from: response), at: Date(), exact: true,"),
                      "a resume made here")
        // Every send to a circle, by the fix's own time.
        let sync = try body(circles, from: "        for targetId in targetCircleIds {\n", to: "    // MARK: - Refresh records")
        let asked = try XCTUnwrap(sync.range(of: "            if mode != .pastHistory,\n"
            + "               CirclePauseRecord.shared.withholds(circleId: targetId, capturedAt: location.timestamp, owner: userId) {\n"
            + "                continue\n            }"))
        let sent = try XCTUnwrap(sync.range(of: "switch mode {"))
        XCTAssertLessThan(asked.upperBound, sent.lowerBound)

        let streamer = try source("App/Services/SDKLocationStreamer.swift")
        let inner = try body(streamer, from: "    private func sendInner(", to: "        // A stream the SDK has given up on")
        let check = try XCTUnwrap(inner.range(of: "throw SendError.notSharingWhenTaken"))
        let keyGate = try XCTUnwrap(inner.range(of: "throw SendError.keyNotCurrent"))
        XCTAssertLessThan(check.upperBound, keyGate.lowerBound, "before a waiting circle could keep it")
        // A kept point taken while not sharing is dropped, and the
        // rest still go.
        let drain = try body(streamer, from: "    func drainKeptLocations() {", to: "    /// The oldest kept point")
        XCTAssertTrue(drain.contains("} catch SendError.notSharingWhenTaken {\n"
                                     + "                    // Taken while this account was not\n"
                                     + "                    // sharing with the circle: it never\n"
                                     + "                    // goes there, and the rest still do.\n"
                                     + "                    PendingCircleLocations.shared.sent(1, circleId: next.circleId, owner: owner)\n"
                                     + "                    withheld += 1\n                    continue\n"))
        // A point that waited goes only after a row read since it was taken:
        // asked in sendInner after the pause check, before anything keeps it
        // for a key; a past point is kept meanwhile; the drain skips a circle
        // whose oldest kept point waits; a refresh kicks the drain only after
        // its rows reached the record.
        let waitAsked = try XCTUnwrap(inner.range(of: "        let waiting = kind == .keptHistory\n"
            + "            && CirclePauseRecord.shared.awaitsRead(circleId: circleId, capturedAt: taken, owner: userId)\n"))
        XCTAssertTrue(inner.contains(
            "if CirclePauseRecord.shared.withholds(circleId: circleId, capturedAt: taken, owner: userId, waiting: waiting) {"))
        let wait = try XCTUnwrap(inner.range(of: "        if waiting {\n            throw SendError.waitingForSharingRecord\n        }\n"))
        XCTAssertLessThan(waitAsked.upperBound, check.lowerBound)
        XCTAssertLessThan(check.upperBound, wait.lowerBound)
        XCTAssertLessThan(wait.upperBound, keyGate.lowerBound)
        XCTAssertTrue(streamer.contains("            case SendError.keyNotCurrent, SendError.waitingForSharingRecord:\n"))
        let next = try body(streamer, from: "    private func nextKeptPoint(owner: String)", to: "    private func sendInner(")
        XCTAssertTrue(next.contains("               !CirclePauseRecord.shared.awaitsRead(\n"))
        let learnt = try XCTUnwrap(circles.range(of: "                CirclePauseRecord.shared.observe(settings, at: now, owner: AuthManager.shared.userId)"))
        let kicked = try XCTUnwrap(circles.range(of: "SDKLocationStreamer.shared.drainKeptLocations()"))
        XCTAssertLessThan(learnt.upperBound, kicked.lowerBound)
        // Every send is coarsened by the bubble in force when its fix was
        // taken, a check-in's by its held fix's time.
        XCTAssertTrue(inner.contains("let taken = capturedAt ?? Date(timeIntervalSince1970: TimeInterval(location.timestamp) / 1000)"))
        XCTAssertTrue(streamer.contains("        let applied = privacyAppliedWithBubble(location, circleId: circleId, capturedAt: taken)\n"
                                        + "        let location = applied.location\n"))
        XCTAssertTrue(streamer.contains("            captureRadiusMiles: CirclePauseRecord.shared.captureRadius(\n"
                                        + "                circleId: circleId, capturedAt: taken, owner: AuthManager.shared.userId))"))
        XCTAssertTrue(sync.contains("try? SDKLocationStreamer.shared.sendLiveness(circleId: targetId, location: sdkLocation,\n"
                                    + "                                                             capturedAt: location.timestamp)"))
        // A check-in's circles not read since an offline stretch wait for the
        // one refresh, or are left out; a newer send meanwhile ends the
        // check-in; offline is a failed send or a rebuilt stream; the drain
        // asks for the refresh too.
        let checkIn = try XCTUnwrap(circles.range(of: "        if mode == .liveness {\n"
            + "            let sentBefore = SDKLocationStreamer.lastSuccessfulSendMs\n"
            + "            targetCircleIds = await checkInTargetsAfterOffline(targetCircleIds, owner: userId)\n"
            + "            if SDKLocationStreamer.lastSuccessfulSendMs != sentBefore { return }\n        }\n"))
        let built = try XCTUnwrap(circles.range(of: "        let locationData = LocationData("))
        XCTAssertLessThan(checkIn.upperBound, built.lowerBound, "stamped after the wait")
        let targets = try body(circles, from: "    private func checkInTargetsAfterOffline(", to: "    // MARK: - Refresh records")
        XCTAssertTrue(targets.contains("guard targets.contains(where: { record.unreadSinceOffline(circleId: $0, owner: owner) }) else { return targets }\n"
                                       + "        await PrivacyReadAfterOffline.shared.refresh()\n"
                                       + "        return targets.filter { !record.unreadSinceOffline(circleId: $0, owner: owner) }\n"))
        XCTAssertEqual(streamer.components(separatedBy: "CirclePauseRecord.shared.noteOffline()").count - 1, 2)
        XCTAssertTrue(streamer.contains("                CirclePauseRecord.shared.noteOffline()\n"
                                        + "                scheduleRestart(reason: \"send failed: \\(error)\")"))
        XCTAssertTrue(streamer.contains("        CirclePauseRecord.shared.noteOffline()\n        teardown()\n"))
        let kick = try body(streamer, from: "    func drainKeptLocations() {", to: "        guard nextKeptPoint(owner: owner) != nil else { return }")
        XCTAssertTrue(kick.contains("            Task { await PrivacyReadAfterOffline.shared.refresh() }\n"))
        XCTAssertTrue(try source("App/Services/CirclePauseRecord.swift").contains(
            "_ = try? await CircleManager.shared.loadCircles(light: true)"))
        // Sign-out empties it, with the points kept for circles.
        XCTAssertTrue(try source("App/Managers/AuthManager.swift").contains(
            "        OwedWipe.clear(cryptoManager)\n        // With the fixes kept for circles, the record of when they could not\n"
            + "        // go.\n        CirclePauseRecord.shared.clearAll()\n"))
    }
}
