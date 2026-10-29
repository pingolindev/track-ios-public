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
import UserNotifications
import PingolinTrackSDK
@testable import Track

/// The SOS check, the app's half: the shared verdict when this phone can't
/// check, the words, what the app does with the notices already shown, and
/// the marks: in the app group, kept across a sign-out, moved in once from
/// the app's own Application Support (`moveIn`).
@MainActor
final class SOSParityTests: XCTestCase {
    private let now: Int64 = 1_727_700_000_000

    private func opened(current: Bool, raiser: String? = "u", age: Int64? = 60_000, location: Bool = true)
        -> SOSReceiverRules.Opened {
        SOSReceiverRules.Opened(
            raiserId: raiser, sealedTimeMs: age.map { now - $0 },
            location: location ? Location(latitude: 1, longitude: 2, altitude: nil, speed: nil, heading: nil,
                                          accuracy: 5, timestamp: now, batteryLevel: nil, isCharging: nil) : nil,
            current: current, payloadHash: "h", raisedHere: false)
    }

    private func verdict(_ o: SOSReceiverRules.Opened, live: Bool = true, behind: Bool = false,
                         marks: SOSReceiverRules.Marks = .read(ended: false, seenCurrent: false),
                         shown: Bool? = true) -> SOSReceiverRules.Verdict {
        SOSReceiverRules.verdict(live: live, opened: o, behind: behind, marks: marks, raiserShown: shown, now: now)
    }

    // MARK: - Can't check

    func testWhatThisPhoneCantCheckRings() {
        let nothing = opened(current: false, raiser: nil, age: nil, location: false)
        XCTAssertEqual(verdict(nothing, behind: true), .cantCheck, "maybe sealed under a version not held yet")
        XCTAssertEqual(verdict(nothing, behind: false), .hidden, "sealed under nothing held: nobody's")
        let partly = opened(current: false, raiser: nil, age: nil, location: true)
        XCTAssertEqual(verdict(partly, behind: true), .hidden, "a part opened under an older version: refused")
        let older = opened(current: false)
        XCTAssertEqual(verdict(older, behind: true), .hidden, "opened under an older held version: not behind's")
        XCTAssertEqual(verdict(older, behind: true, marks: .read(ended: false, seenCurrent: true)), .alarming)

        // Marks that can't be read: a current one alarms either way; one they
        // would decide rings; past 24 h, quiet; closed, quiet; a raiser off the
        // roster, hidden.
        XCTAssertEqual(verdict(opened(current: true), marks: .unreadable), .alarming)
        XCTAssertEqual(verdict(older, marks: .unreadable), .cantCheck)
        XCTAssertEqual(verdict(opened(current: false, age: 86_400_001), marks: .unreadable), .quiet)
        XCTAssertEqual(verdict(older, live: false, marks: .unreadable), .quiet)
        XCTAssertEqual(verdict(older, marks: .unreadable, shown: false), .hidden)
        XCTAssertEqual(verdict(opened(current: false, raiser: nil, age: nil, location: false), marks: .unreadable),
                       .hidden)
    }

    // MARK: - The words

    func testTheAlarmIsInAndroidsWords() {
        XCTAssertTrue(SOSAlarmCopy.alarm(name: "Olivia", circle: "Family", level: "full")
                      == ("Olivia needs attention", "Asked their circle to check on them in Family"))
        XCTAssertTrue(SOSAlarmCopy.alarm(name: nil, circle: nil, level: nil)
                      == ("A circle member needs attention", "Asked their circle to check on them in your circle"))
        XCTAssertTrue(SOSAlarmCopy.alarm(name: "", circle: "", level: "full")
                      == ("A circle member needs attention", "Asked their circle to check on them in your circle"))
        XCTAssertTrue(SOSAlarmCopy.alarm(name: "Olivia", circle: "Family", level: "names")
                      == ("Olivia needs attention", "Olivia needs attention"))
        XCTAssertTrue(SOSAlarmCopy.alarm(name: "Olivia", circle: "Family", level: "generic")
                      == ("A circle member needs attention", "Tap to view"))
        XCTAssertEqual(SOSAlarmCopy.quietTitle, "Someone may need help.")
        XCTAssertEqual(SOSAlarmCopy.quietBody, "Open Track to check.")
        XCTAssertEqual(SOSAlarmCopy.newAlertTypes, ["sos", "sos_alert", "emergency"])
        XCTAssertEqual(SOSAlarmCopy.followUpTypes, ["sos_acknowledged", "sos_resolved"])
    }

    // MARK: - The notices already shown

    private let a = "c6060000-0000-4000-8000-0000000000a1"
    private let b = "c6060000-0000-4000-8000-0000000000a2"
    private let c = "c6060000-0000-4000-8000-0000000000a3"

    private func notice(_ id: String, _ alertId: String, kind: String?, title: String = "Alert",
                        body: String = "Tap to view details") -> SOSNotices.Delivered {
        SOSNotices.Delivered(identifier: id, alertType: "sos", alertId: alertId, kind: kind, title: title, body: body)
    }

    func testTheNoticesFollowWhatThisPhoneNowKnows() {
        let named: [String: (name: String?, circle: String?)] = [a: ("Olivia", "Family"), b: ("Olivia", "Family")]
        let plan = SOSNotices.plan(
            delivered: [
                notice("1", a.uppercased(), kind: "quiet", title: "Someone may need help.", body: "Open Track to check."),
                notice("2", b, kind: nil),
                notice("3", b, kind: "alarm", title: "Olivia needs attention",
                       body: "Asked their circle to check on them in Family"),
                notice("4", c, kind: "alarm", title: "x", body: "y"),
                notice("5", "c6060000-0000-4000-8000-0000000000ff", kind: nil),
                notice("6", "c6060000-0000-4000-8000-0000000000fe", kind: "quiet"),
            ],
            verdicts: [a: .alarming, b: .alarming, c: .quiet, "c6060000-0000-4000-8000-0000000000fe": .cantCheck],
            names: named, level: "full", rang: [], newPosts: false)
        XCTAssertEqual(plan.post, [
            SOSNotices.Post(identifier: "1", alertType: "sos", alertId: a.uppercased(), title: "Olivia needs attention",
                            body: "Asked their circle to check on them in Family", sound: true),
            SOSNotices.Post(identifier: "2", alertType: "sos", alertId: b, title: "Olivia needs attention",
                            body: "Asked their circle to check on them in Family", sound: false),
        ], "the quiet one rings now; the server's one is re-worded silently; one in these words is left")
        XCTAssertEqual(plan.remove, ["4", "5"], "quiet now, or not listed any more; can't check: left as it is")
    }

    func testAPostIsTheAlarm() {
        let content = SOSNotices.content(SOSNotices.Post(identifier: "1", alertType: "sos", alertId: a, title: "T",
                                                         body: "B", sound: false))
        XCTAssertNil(content.sound)
        XCTAssertEqual(content.interruptionLevel, .active)
        XCTAssertEqual(content.userInfo["alert_id"] as? String, a)
        XCTAssertEqual(content.userInfo["alert_type"] as? String, "sos")
        XCTAssertEqual(content.userInfo[SOSAlarmCopy.noticeKey] as? String, "alarm")
        XCTAssertEqual(SOSNotices.content(SOSNotices.Post(identifier: "1", alertType: "sos", alertId: a, title: "T",
                                                          body: "B", sound: true)).sound, .default)
    }

    /// Rings once: the person swiped the quiet notice away, the raiser
    /// re-sealed, and a quiet refresh finds the SOS alarming: one new alarm,
    /// with sound; the next refresh, nothing.
    func testASwipedNoticeStillRingsOnceAtTheRefresh() {
        let named: [String: (name: String?, circle: String?)] = [a: ("Olivia", "Family")]
        let first = SOSNotices.plan(delivered: [], verdicts: [a: .alarming], names: named, level: "full", rang: [],
                                    newPosts: true)
        XCTAssertEqual(first.post, [SOSNotices.Post(identifier: "sos-alarm-" + a, alertType: "sos", alertId: a,
                                                    title: "Olivia needs attention",
                                                    body: "Asked their circle to check on them in Family", sound: true)])
        XCTAssertEqual(first.remove, [])
        let posted = notice("sos-alarm-" + a, a, kind: "alarm", title: "Olivia needs attention",
                            body: "Asked their circle to check on them in Family")
        XCTAssertEqual(SOSNotices.plan(delivered: [posted], verdicts: [a: .alarming], names: named, level: "full",
                                       rang: [a], newPosts: true), SOSNotices.Plan(), "the next refresh: nothing")
        XCTAssertEqual(SOSNotices.plan(delivered: [], verdicts: [a: .alarming], names: named, level: "full", rang: [a],
                                       newPosts: true), SOSNotices.Plan(), "rung, and swiped again: nothing")
        XCTAssertEqual(SOSNotices.plan(delivered: [], verdicts: [a: .alarming], names: named, level: "full", rang: [],
                                       newPosts: false), SOSNotices.Plan(), "a load a push started posts nothing new")
    }

    /// What shows of an SOS is re-worded silently once it has rung, or when the
    /// extension's alarm of it is shown; a refresh never rings one that can't
    /// be checked, is quiet, or is hidden.
    func testOnlyTheFirstAlarmRings() {
        let quiet = notice("1", a, kind: "quiet", title: "Someone may need help.", body: "Open Track to check.")
        let rungPlan = SOSNotices.plan(delivered: [quiet], verdicts: [a: .alarming], names: [:], level: "generic",
                                       rang: [a], newPosts: true)
        XCTAssertEqual(rungPlan.post.map(\.sound), [false], "rung already: re-worded silently")
        let both = SOSNotices.plan(
            delivered: [quiet, notice("2", a, kind: "alarm", title: "x", body: "y")],
            verdicts: [a: .alarming], names: [:], level: "generic", rang: [], newPosts: true)
        XCTAssertEqual(both.post.map(\.sound), [false, false], "the extension's alarm of it is shown: it rang")
        let twice = SOSNotices.plan(delivered: [quiet, notice("3", a, kind: nil)], verdicts: [a: .alarming],
                                    names: [:], level: "generic", rang: [], newPosts: true)
        XCTAssertEqual(twice.post.map(\.sound), [false, false], "the server's banner of it is shown: it rang")
        let quietTwice = SOSNotices.plan(delivered: [quiet, notice("4", a, kind: "quiet")], verdicts: [a: .alarming],
                                         names: [:], level: "generic", rang: [], newPosts: true)
        XCTAssertEqual(quietTwice.post.map(\.sound), [true, false], "two quiet notices of one SOS: one rings")
        for verdict in [SOSReceiverRules.Verdict.cantCheck, .quiet, .hidden] {
            let plan = SOSNotices.plan(delivered: [quiet], verdicts: [a: verdict], names: [:], level: nil, rang: [],
                                       newPosts: true)
            XCTAssertFalse(plan.post.contains(where: \.sound), "\(verdict)")
        }
        XCTAssertEqual(SOSNotices.plan(delivered: [], verdicts: [a: .quiet, b: .cantCheck, c: .hidden], names: [:],
                                       level: nil, rang: [], newPosts: true), SOSNotices.Plan())
    }

    /// Rings once after a can't-check (as Android's ringOnce): the server's
    /// own banner, shown when the extension couldn't check, rang; the real
    /// alarm replaces it silently once this phone can open the SOS. With no
    /// banner left (swiped away) the alarm rings once; a quiet notice never
    /// rang.
    func testADeliveredServerBannerCountsAsRungAndTheAlarmReplacesItSilently() {
        let named: [String: (name: String?, circle: String?)] = [a: ("Olivia", "Family")]
        let banner = SOSNotices.plan(delivered: [notice("7AE4", a, kind: nil)], verdicts: [a: .alarming], names: named,
                                     level: "full", rang: [], newPosts: true)
        XCTAssertEqual(banner.post, [SOSNotices.Post(identifier: "7AE4", alertType: "sos", alertId: a,
                                                     title: "Olivia needs attention",
                                                     body: "Asked their circle to check on them in Family", sound: false)])
        XCTAssertEqual(banner.remove, [])
        let swiped = SOSNotices.plan(delivered: [], verdicts: [a: .alarming], names: named, level: "full", rang: [],
                                     newPosts: true)
        XCTAssertEqual(swiped.post.map(\.sound), [true], "no banner left: it rings once")
        let quiet = SOSNotices.plan(delivered: [notice("1", a, kind: "quiet")], verdicts: [a: .alarming], names: named,
                                    level: "full", rang: [], newPosts: true)
        XCTAssertEqual(quiet.post.map(\.sound), [true], "a quiet notice never rang")
    }

    /// The alarm names the raiser only by a name that OPENED here, never the
    /// plaintext one the server sends for older clients nor "Member": with
    /// none, the plan's words are the generic ones, in the app as in the
    /// extension.
    func testTheAlarmNamesOnlyANameThatOpened() {
        let raiser = "c6060000-0000-4000-8000-0000000000b1"
        let olivia = CircleMember(circleId: circle, userId: raiser, displayName: "Olivia", role: .member,
                                  canSeeRealtime: true, canSeeHistory: true, canRotateKeys: false, joinedAt: Date())
        XCTAssertEqual(SOSManager.openedName(of: raiser.uppercased(), in: [olivia], opened: [raiser]), "Olivia")
        XCTAssertNil(SOSManager.openedName(of: raiser, in: [olivia], opened: []), "the plaintext or placeholder name")
        XCTAssertNil(SOSManager.openedName(of: raiser, in: [olivia], opened: nil), "no roster loaded")
        XCTAssertNil(SOSManager.openedName(of: raiser, in: nil, opened: [raiser]))
        let plan = SOSNotices.plan(
            delivered: [notice("1", a, kind: nil)], verdicts: [a: .alarming],
            names: [a: (SOSManager.openedName(of: raiser, in: [olivia], opened: []), "Family")], level: "full",
            rang: [], newPosts: false)
        XCTAssertEqual(plan.post.first?.title, "A circle member needs attention")
    }

    /// A post that rings marks its SOS "rang" once iOS has taken it, never
    /// before: one iOS refuses marks nothing, and the next pass tries again.
    func testRangIsNotedOnlyAfterThePost() async {
        let ringing = SOSNotices.Post(identifier: "sos-alarm-" + a, alertType: "sos", alertId: a, title: "T", body: "B",
                                      sound: true)
        let silent = SOSNotices.Post(identifier: "1", alertType: "sos", alertId: b, title: "T", body: "B", sound: false)
        var noted: [String] = []
        var added: [String] = []
        await SOSNotices.post(SOSNotices.Plan(post: [ringing, silent]), add: { request in
            added.append(request.identifier)
            XCTAssertTrue(noted.isEmpty || request.identifier != ringing.identifier, "never marked before its post")
        }, rang: { noted.append($0.alertId) })
        XCTAssertEqual(added, ["sos-alarm-" + a, "1"])
        XCTAssertEqual(noted, [a], "only the one that rang")

        noted = []
        await SOSNotices.post(SOSNotices.Plan(post: [ringing]), add: { _ in throw URLError(.cannotWriteToFile) },
                              rang: { noted.append($0.alertId) })
        XCTAssertEqual(noted, [], "refused by iOS: not marked")
    }

    // MARK: - The marks

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sos-parity-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private let account = "c6060000-0000-4000-8000-000000000001"
    private let circle = "c6060000-0000-4000-8000-0000000000c1"

    /// The marks move in once: one folder's file moves as it is; one with
    /// marks there too folds (every hash, ended if either, the earlier time);
    /// a file that doesn't read, there or here, stays where it is.
    func testTheMarksMoveIntoTheAppGroup() throws {
        let old = scratch(), group = scratch()
        let earlier = SOSAlarmMarks(directory: old), marks = SOSAlarmMarks(directory: group)
        earlier.noteSeenCurrent(account: account, circleId: circle, sosId: a, hash: "A", at: now - 5)
        earlier.noteEnded(account: account, circleId: circle, sosId: b, at: now)
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: a, hash: "B", at: now)
        marks.noteSeenCurrent(account: account, circleId: circle, sosId: b, hash: "D", at: now)
        let other = "c6060000-0000-4000-8000-000000000002"
        earlier.noteSeenCurrent(account: other, circleId: circle, sosId: c, hash: "C", at: now)
        try Data("{not json".utf8).write(to: old.appendingPathComponent("c6060000-0000-4000-8000-000000000003.json"))
        let unreadableHere = "c6060000-0000-4000-8000-000000000004"
        earlier.noteEnded(account: unreadableHere, circleId: circle, sosId: c, at: now)
        try Data("{not json".utf8).write(to: group.appendingPathComponent("\(unreadableHere).json"))

        marks.moveIn(from: old)
        XCTAssertEqual(marks.mark(account: account, circleId: circle, sosId: a),
                       SOSAlarmMarks.Mark(seenCurrent: ["B", "A"], ended: false, at: now - 5))
        XCTAssertEqual(marks.mark(account: account, circleId: circle, sosId: b),
                       SOSAlarmMarks.Mark(seenCurrent: ["D"], ended: true, at: now), "ended if either was")
        XCTAssertEqual(marks.mark(account: other, circleId: circle, sosId: c)?.seenCurrent, ["C"])
        XCTAssertEqual(try Data(contentsOf: group.appendingPathComponent("\(unreadableHere).json")),
                       Data("{not json".utf8), "never written over")
        let left = try FileManager.default.contentsOfDirectory(atPath: old.path).sorted()
        XCTAssertEqual(left, ["c6060000-0000-4000-8000-000000000003.json", "\(unreadableHere).json"],
                       "the ones that don't read, there or here, stay")
        // Moving again changes nothing.
        let before = try Data(contentsOf: group.appendingPathComponent("\(account).json"))
        marks.moveIn(from: old)
        XCTAssertEqual(try Data(contentsOf: group.appendingPathComponent("\(account).json")), before)
    }

    /// Reads are fresh: what another process (the extension) wrote is seen at
    /// once, and a write merges with it rather than writing an old copy back.
    func testEveryReadIsFreshAndEveryWriteMerges() {
        let folder = scratch()
        let lock = AppGroupLock(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("sos-marks-\(UUID().uuidString).lock"))
        let app = SOSAlarmMarks(directory: folder, lock: lock), extensionSide = SOSAlarmMarks(directory: folder, lock: lock)
        XCTAssertNil(app.mark(account: account, circleId: circle, sosId: a))
        extensionSide.noteSeenCurrent(account: account, circleId: circle, sosId: a, hash: "A", at: now)
        XCTAssertEqual(app.mark(account: account, circleId: circle, sosId: a)?.seenCurrent, ["A"])
        app.noteEnded(account: account, circleId: circle, sosId: b, at: now)
        XCTAssertEqual(extensionSide.mark(account: account, circleId: circle, sosId: a)?.seenCurrent, ["A"])
        XCTAssertEqual(extensionSide.mark(account: account, circleId: circle, sosId: b)?.ended, true)
        // The lock held elsewhere: nothing is written, and it says so.
        let held = lock.acquireBlocking(timeout: 1)
        XCTAssertFalse(SOSAlarmMarks(directory: folder, lock: lock, lockWait: 0.1)
            .noteEnded(account: account, circleId: circle, sosId: c, at: now))
        held?.release()
        XCTAssertNil(app.mark(account: account, circleId: circle, sosId: c))
    }

    /// The app takes its marks as they are on disk now: no file is no mark, a
    /// file that doesn't read stays unreadable (it decides nothing then), and
    /// "seen current" is this payload's alone.
    func testTheAppReadsTheMarksAsTheyAre() {
        let marks = [SOSAlarmMarks.key(circleId: circle, sosId: a): SOSAlarmMarks.Mark(seenCurrent: ["h"], ended: true, at: now)]
        XCTAssertEqual(SOSManager.marksState(.missing, circleId: circle, sosId: a, hash: "h"),
                       .read(ended: false, seenCurrent: false))
        XCTAssertEqual(SOSManager.marksState(.unreadable, circleId: circle, sosId: a, hash: "h"), .unreadable)
        XCTAssertEqual(SOSManager.marksState(.loaded(marks), circleId: circle.uppercased(), sosId: a.uppercased(), hash: "h"),
                       .read(ended: true, seenCurrent: true))
        XCTAssertEqual(SOSManager.marksState(.loaded(marks), circleId: circle, sosId: a, hash: "another"),
                       .read(ended: true, seenCurrent: false))
        XCTAssertEqual(SOSManager.marksState(.loaded(marks), circleId: circle, sosId: b, hash: "h"),
                       .read(ended: false, seenCurrent: false))
    }

    /// The app group's folder and lock, by default.
    func testTheMarksLiveInTheAppGroup() throws {
        let group = try XCTUnwrap(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ExtensionBridgeKeys.suite))
        XCTAssertEqual(SOSAlarmMarks.groupDirectory(), group.appendingPathComponent("SOSMarks", isDirectory: true))
        XCTAssertEqual(AppGroupLock.sosMarks()?.url, group.appendingPathComponent("sos-marks.lock"))

        // The default store writes there, under that lock.
        let someone = "c6060000-0000-4000-8000-0000000000d1"
        let marks = SOSAlarmMarks()
        addTeardownBlock { marks.forget(account: someone) }
        XCTAssertTrue(marks.noteEnded(account: someone, circleId: circle, sosId: a, at: now))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: group.appendingPathComponent("SOSMarks/\(someone).json", isDirectory: false).path))
        let held = try XCTUnwrap(AppGroupLock.sosMarks()?.acquireBlocking(timeout: 1))
        XCTAssertFalse(SOSAlarmMarks(lockWait: 0.1).noteEnded(account: someone, circleId: circle, sosId: b, at: now),
                       "the lock held elsewhere: nothing written")
        held.release()
        XCTAssertNil(marks.mark(account: someone, circleId: circle, sosId: b))
    }

    /// "Rang" is one-way and per SOS; a file an earlier build wrote (no "rang")
    /// reads as not rung, never as unreadable; a fold keeps it if either had it.
    func testRangIsOneWayAndOlderFilesRead() throws {
        let folder = scratch()
        let marks = SOSAlarmMarks(directory: folder)
        XCTAssertTrue(marks.noteRang(account: account, circleId: circle, sosId: a, at: now))
        XCTAssertTrue(marks.noteRang(account: account, circleId: circle, sosId: a, at: now), "already there")
        XCTAssertEqual(marks.mark(account: account, circleId: circle, sosId: a)?.rang, true)
        XCTAssertNil(marks.mark(account: account, circleId: circle, sosId: b))

        let earlier = "c6060000-0000-4000-8000-000000000005"
        let key = SOSAlarmMarks.key(circleId: circle, sosId: c)
        try Data(#"{"\#(key)":{"seenCurrent":["h"],"ended":false,"at":5}}"#.utf8)
            .write(to: folder.appendingPathComponent("\(earlier).json"))
        XCTAssertEqual(marks.mark(account: earlier, circleId: circle, sosId: c),
                       SOSAlarmMarks.Mark(seenCurrent: ["h"], ended: false, rang: false, at: 5))
        XCTAssertTrue(marks.noteRang(account: earlier, circleId: circle, sosId: c, at: now))
        XCTAssertEqual(marks.mark(account: earlier, circleId: circle, sosId: c),
                       SOSAlarmMarks.Mark(seenCurrent: ["h"], ended: false, rang: true, at: 5))

        let folded = SOSAlarmMarks.folded([key: SOSAlarmMarks.Mark(rang: true, at: 1)], [key: SOSAlarmMarks.Mark(at: 2)])
        XCTAssertEqual(folded[key]?.rang, true, "rung if either was")
        XCTAssertEqual(SOSAlarmMarks.folded([key: SOSAlarmMarks.Mark(at: 1)], [key: SOSAlarmMarks.Mark(rang: true, at: 2)])[key]?.rang,
                       true)
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The notices are settled after a load that worked (the load throws first
    /// when it doesn't); the marks move in at launch; the extension compiles
    /// the app's own rules, marks and words.
    func testTheAppHalfIsWired() throws {
        let manager = try source("App/Managers/SOSManager.swift")
        let load = try XCTUnwrap(manager.range(of: "    func loadActiveAlerts(quiet: Bool = false) async throws {\n"
                                               + "        // This account's own open SOS that a key change left behind goes along\n"
                                               + "        // to the current key first, so this load judges the re-sealed row.\n"
                                               + "        let responses = await resealOwn(try await api.getActiveSOSAlerts())\n"))
        let settle = try XCTUnwrap(manager.range(of: "        if let myUserId {\n"
            + "            await settleShownNotices(opened: opened, verdicts: verdicts, quiet: quiet, account: myUserId, now: now)\n"
            + "        }\n    }\n"))
        XCTAssertLessThan(load.upperBound, settle.lowerBound)
        XCTAssertTrue(manager.contains("            case .cantCheck:\n                if entry.opened.opened { alerts.append(entry.alert) }\n"))
        XCTAssertTrue(manager.contains("CircleManager.shared.isBehind(circleId) || !CircleManager.shared.holdsCurrentVersion(for: circleId)"))
        // Rings once: the marks, this process's memory, and what this person
        // has handled keep a post silent; only a quiet refresh posts anew; the
        // mark follows the post.
        XCTAssertTrue(manager.contains("            if stored[SOSAlarmMarks.key(circleId: entry.alert.circleId, sosId: key)]?.rang == true\n"
                                       + "                || entry.alert.acknowledgedByMe || entry.alert.dismissedByMe {\n"))
        XCTAssertTrue(manager.contains("        var rang = rangHere\n"))
        // The names that opened, and only the load's own account.
        XCTAssertTrue(manager.contains("            let raiser = Self.openedName(of: entry.alert.userId, in: CircleManager.shared.members[circleKey],\n"
                                       + "                                         opened: CircleManager.shared.openedNames[circleKey])\n"))
        XCTAssertTrue(manager.contains("            await settleShownNotices(opened: opened, verdicts: verdicts, quiet: quiet, account: myUserId, now: now)\n"))
        XCTAssertTrue(manager.contains("        guard CanonicalId.same(AuthManager.shared.userId, me) else { return }\n"))
        XCTAssertTrue(manager.contains("            guard CanonicalId.same(AuthManager.shared.userId, me) else { throw CancellationError() }\n"
                                       + "            try await center.add(request)\n"))
        XCTAssertFalse(manager.contains("let me = AuthManager.shared.userId"), "never the account signed in now")
        XCTAssertTrue(manager.contains("        hasActiveAlert = false\n        rangHere = []\n"), "forgotten at a sign-out")
        XCTAssertTrue(try source("App/Managers/CircleManager.swift").contains(
            "        rosters[circleId] = mappedMembers\n        openedNames[circleId] = Set(decryptedNames.keys.map { CanonicalId.key($0) })\n"))
        XCTAssertTrue(manager.contains("level: UserSettings.shared.notificationDetailLevel.rawValue, rang: rang,\n"
                                       + "                                   newPosts: quiet)\n"))
        XCTAssertTrue(manager.contains("            rangHere.insert(key)\n            if let target = marked[key] {\n"
                                       + "                SOSAlarmMarks.shared.noteRang(account: me, circleId: target.circleId, sosId: key, at: target.at)\n"))
        XCTAssertTrue(try source("App/TrackApp.swift")
            .contains("        SOSAlarmMarks.shared.moveIn(from: SOSAlarmMarks.earlierDirectory())\n"))
        let project = try source("project.yml")
        for path in ["App/Managers/SOSReceiverRules.swift", "App/Managers/SOSAlarmMarks.swift",
                     "App/Notifications/SOSAlarmCopy.swift", "App/Services/StoredFile.swift"] {
            XCTAssertTrue(project.contains("      - path: \(path)\n"), path)
        }
    }
}
