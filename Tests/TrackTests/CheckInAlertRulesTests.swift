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
import PingolinTrackSDK
@testable import Track

/// Check-in rules: an inactivity alert rule that watches check-ins (`watches`
/// "check_in", migration 196). A one-time rule goes off when its member hasn't
/// checked in within its timeout of its arming, and ends at their first
/// check-in after it (scheduled rules: `CheckInScheduleTests`).
///
/// The decisions are pure (`CheckInAlerts`) and tested as such: when one goes
/// off, when a lapse ends, that a failed read judges nobody, that the clock
/// starts at the rule's arming, that a paused member is still judged and that
/// this account never is. Then the wire, with and without the new fields, the
/// words, the editor as VoiceOver reads it, and the wiring, from source.
@MainActor
final class CheckInAlertRulesTests: XCTestCase {

    private let circle = "3f7a1b2c-0000-4000-8000-0123456789ab"
    private let me = "a0000000-0000-4000-8000-000000000001"
    private let ana = "a0000000-0000-4000-8000-000000000002"
    private let ben = "a0000000-0000-4000-8000-000000000003"
    private let ruleId = "b0000000-0000-4000-8000-000000000001"
    private let requestId = "b0000000-0000-4000-8000-000000000002"
    /// 2027-01-15 08:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    private func member(_ id: String, name: String = "Ana", sharing: String? = nil) -> CircleMember {
        CircleMember(circleId: circle, userId: id, displayName: name, role: .member, canSeeRealtime: true,
                     canSeeHistory: true, canRotateKeys: false, joinedAt: hours(-1000),
                     locationSharing: sharing, sharingPausedUntil: nil, historySharing: nil)
    }

    private func rule(_ id: String? = nil, members: [String], timeout: Int = 2, armedAt: Date,
                      theirs: Bool = false) -> CheckInAlerts.Rule {
        CheckInAlerts.Rule(id: id ?? ruleId, circleId: circle, timeoutHours: timeout, armedAt: armedAt,
                           memberIds: members, isTheirRequest: theirs)
    }

    private func decide(last: Date?, armed: Date, timeout: Int = 2, open: Date? = nil, now: Date) -> CheckInAlerts.Decision {
        CheckInAlerts.decide(last: last, armedAt: armed, timeoutHours: timeout, openSince: open, now: now)
    }

    // MARK: - The decision

    func testItGoesOffOnlyPastTheTimeoutCountedFromTheArming() {
        XCTAssertNil(decide(last: nil, armed: t0, now: hours(1.9)).raisesSince)
        XCTAssertNil(decide(last: nil, armed: t0, now: hours(2)).raisesSince, "exactly the timeout is not past it")
        XCTAssertEqual(decide(last: nil, armed: t0, now: hours(2).addingTimeInterval(1)).raisesSince, t0,
                       "the lapse starts at the arming it counts from")
        XCTAssertEqual(decide(last: nil, armed: t0, timeout: 24, now: hours(24.01)).raisesSince, t0)
        XCTAssertNil(decide(last: nil, armed: t0, timeout: 24, now: hours(23.99)).raisesSince)
    }

    func testWithNoCheckInSinceTheClockStartsWhenTheRuleWasArmed() {
        // Never checked in: from the rule's arming, not from "never".
        XCTAssertNil(decide(last: nil, armed: t0, timeout: 3, now: hours(2.9)).raisesSince)
        XCTAssertEqual(decide(last: nil, armed: t0, timeout: 3, now: hours(3.1)).raisesSince, t0)
        // A check-in from before the rule was made, or turned back on, does not
        // start the clock early: armed_at is later, so it counts from there.
        XCTAssertNil(decide(last: hours(-30), armed: t0, timeout: 3, now: hours(2.9)).raisesSince)
        XCTAssertEqual(decide(last: hours(-30), armed: t0, timeout: 3, now: hours(3.1)).raisesSince, t0)
        // A check-in after the arming ends the rule: nothing goes off after it.
        XCTAssertNil(decide(last: hours(1), armed: t0, timeout: 3, now: hours(3.9)).raisesSince)
        XCTAssertNil(decide(last: hours(1), armed: t0, timeout: 3, now: hours(300)).raisesSince)
    }

    func testAnOpenLapseIsRaisedOnlyOnce() {
        for last in [nil, hours(-50)] {
            let d = decide(last: last, armed: hours(-48), open: hours(-48), now: hours(9))
            XCTAssertFalse(d.resolves)
            XCTAssertNil(d.raisesSince, "still quiet since the arming, and already told")
        }
    }

    func testACheckInAfterTheLapseBeganEndsIt() {
        let d = decide(last: hours(3), armed: hours(-48), open: hours(-48), now: hours(4))
        XCTAssertTrue(d.resolves)
        XCTAssertTrue(d.checkedIn)
        XCTAssertNil(d.raisesSince, "and the rule with it: nothing goes off again")
        XCTAssertFalse(decide(last: hours(-50), armed: hours(-48), open: hours(-48), now: hours(4)).resolves,
                       "one from before the arming")
        XCTAssertFalse(decide(last: nil, armed: hours(-48), open: hours(-48), now: hours(4)).resolves,
                       "no check-in known: nothing ends it")
    }

    /// The lapse ends on a check-in newer than where it STARTED, not newer than
    /// when it fired: a check-in that waited to be sent arrives with the time
    /// the person pressed the button.
    func testACheckInThatArrivesLateStillEndsTheLapse() {
        // Fired 2 h after the arming at t0; a check-in sealed at 1.5 h reaches
        // the server at 2.5 h.
        let d = decide(last: hours(1.5), armed: t0, open: t0, now: hours(2.5))
        XCTAssertTrue(d.resolves)
        XCTAssertTrue(d.checkedIn)
        XCTAssertNil(d.raisesSince)
    }

    /// A one-time rule ends at the first check-in after its arming (the server
    /// then turns it off): its lapse ends, it never goes off again, even before
    /// the rule list says it is off. Turned back on, it counts again from the
    /// new arming.
    func testACheckInAfterTheArmingEndsTheRuleUntilItIsArmedAgain() {
        let ended = decide(last: hours(3), armed: hours(-48), open: hours(-48), now: hours(30))
        XCTAssertTrue(ended.resolves)
        XCTAssertTrue(ended.checkedIn)
        XCTAssertNil(ended.raisesSince, "27 h quiet since that check-in: not reported again")
        XCTAssertEqual(decide(last: hours(3), armed: hours(4), now: hours(6).addingTimeInterval(1)).raisesSince, hours(4),
                       "armed again after that check-in: it counts again")

        let members = [member(ana)]
        let open = [CheckInAlerts.lapseKey(ruleId: ruleId, userId: ana): hours(-48)]
        XCTAssertEqual(CheckInAlerts.judge(rules: [rule(members: [ana], armedAt: hours(-48))], members: members,
                                           consent: [:], selfId: me, newest: [CanonicalId.key(ana): hours(3)],
                                           openLapses: open, now: hours(30)),
                       [.resolve(ruleId: ruleId, userId: ana, checkedIn: true)], "ended, nothing raised")
        XCTAssertEqual(CheckInAlerts.judge(rules: [rule(members: [ana], armedAt: hours(-48))], members: members,
                                           consent: [:], selfId: me, newest: [CanonicalId.key(ana): hours(3)],
                                           openLapses: [:], now: hours(30)), [])
    }

    /// A rule turned off and back on is armed again by the server, and that
    /// ends its old lapse without a check-in: the lapse ends once the arming is
    /// later than the start it fired on. Ended only by a newer check-in, the old
    /// lapse would stay open and the re-armed rule could never go off again.
    func testARearmedRuleEndsItsOldLapseAndGoesOffAgainFromItsNewArming() {
        let firstArming = hours(-48)
        // Fired: nobody checked in since the first arming.
        XCTAssertEqual(decide(last: nil, armed: firstArming, now: hours(-45)).raisesSince, firstArming)
        let lapseStart = firstArming

        // Turned off, then back on at t0: armed_at is t0, and still no check-in.
        let rearmed = decide(last: nil, armed: t0, open: lapseStart, now: hours(1))
        XCTAssertTrue(rearmed.resolves, "the old lapse closes")
        XCTAssertFalse(rearmed.checkedIn, "but nobody checked in")
        XCTAssertNil(rearmed.raisesSince, "an hour since the new arming: under the 2 h timeout")
        let olderCheckIn = decide(last: hours(-50), armed: t0, open: lapseStart, now: hours(1))
        XCTAssertTrue(olderCheckIn.resolves)
        XCTAssertFalse(olderCheckIn.checkedIn, "a check-in from before the lapse didn't end it")
        // Then nothing until the new arming plus the timeout...
        XCTAssertNil(decide(last: nil, armed: t0, now: hours(1.9)).raisesSince)
        XCTAssertNil(decide(last: nil, armed: t0, now: hours(2)).raisesSince)
        // ...and then a new alert, counted from the new arming.
        XCTAssertEqual(decide(last: nil, armed: t0, now: hours(2).addingTimeInterval(1)).raisesSince, t0)

        // The same, pass by pass, as the circle is judged.
        let members = [member(ana)]
        let open = [CheckInAlerts.lapseKey(ruleId: ruleId, userId: ana): lapseStart]
        let rearmedRule = [rule(members: [ana], armedAt: t0)]
        func judge(_ rules: [CheckInAlerts.Rule], open: [String: Date], now: Date) -> [CheckInAlerts.Action] {
            CheckInAlerts.judge(rules: rules, members: members, consent: [:], selfId: me, newest: [:],
                                openLapses: open, now: now)
        }
        XCTAssertEqual(judge(rearmedRule, open: open, now: hours(1)),
                       [.resolve(ruleId: ruleId, userId: ana, checkedIn: false)], "closed, nothing raised")
        XCTAssertEqual(judge(rearmedRule, open: [:], now: hours(1.9)), [], "quiet until armed_at + timeout")
        XCTAssertEqual(judge(rearmedRule, open: [:], now: hours(2.1)),
                       [.raise(ruleId: ruleId, userId: ana, name: "Ana", since: t0, timeoutHours: 2)])
        XCTAssertEqual(judge([rule(members: [ana], armedAt: firstArming)], open: open, now: hours(2.1)), [],
                       "not re-armed: the lapse stays open and nothing is raised twice")
        // Closing it needs no read: a pass ends it from the rule list
        // (`passActions`), so a background pass doesn't read for that.
        let recentRead = CheckInAlerts.Read(at: hours(0.9), newest: [:])
        XCTAssertFalse(CheckInAlerts.backgroundPassReads(
            rules: rearmedRule, members: members, consent: [:], selfId: me,
            last: recentRead, openLapses: open, now: hours(1)))
        XCTAssertEqual(CheckInAlerts.passActions(rules: rearmedRule, members: members, consent: [:], selfId: me,
                                                 fresh: nil, held: recentRead.newest, openLapses: open, now: hours(1)),
                       [.resolve(ruleId: ruleId, userId: ana, checkedIn: false)])
    }

    /// A re-armed rule's old lapse closes on a pass that doesn't read and on a
    /// pass whose read fails, from the rule list alone, and neither raises
    /// anything, though the rule may be overdue again. Only a pass whose read
    /// stands raises. The Android app ends lapses the same way.
    func testARearmedRulesLapseClosesOnAPassThatDoesNotReadOrWhoseReadFails() async throws {
        let members = [member(ana)]
        let open = [CheckInAlerts.lapseKey(ruleId: ruleId, userId: ana): hours(-48)]
        let closed: [CheckInAlerts.Action] = [.resolve(ruleId: ruleId, userId: ana, checkedIn: false)]
        let held = CheckInAlerts.Read(at: hours(-0.1), newest: [CanonicalId.key(ana): hours(-50)])
        func pass(_ rules: [CheckInAlerts.Rule], fresh: [String: Date]?, open: [String: Date]) -> [CheckInAlerts.Action] {
            CheckInAlerts.passActions(rules: rules, members: members, consent: [:], selfId: me,
                                      fresh: fresh, held: held.newest, openLapses: open, now: t0)
        }
        func backgroundReads(_ rules: [CheckInAlerts.Rule]) -> Bool {
            CheckInAlerts.backgroundPassReads(rules: rules, members: members, consent: [:], selfId: me,
                                              last: held, openLapses: open, now: t0)
        }

        // Turned back on half an hour ago (2 h timeout), read six minutes ago:
        // the background pass doesn't read, and the old lapse closes anyway.
        let justRearmed = [rule(members: [ana], armedAt: hours(-0.5))]
        XCTAssertFalse(backgroundReads(justRearmed))
        XCTAssertEqual(pass(justRearmed, fresh: nil, open: open), closed)

        // Turned back on three hours ago: overdue again, so a pass reads, and
        // here the read fails on a check-in in the window that doesn't open.
        let rearmedEarlier = [rule(members: [ana], armedAt: hours(-3))]
        XCTAssertTrue(backgroundReads(rearmedEarlier))
        let crypto = try sealer()
        let unopened = try row("k-unopened", by: crypto, sender: ana, at: nil,
                               day: CheckInAlerts.readFloorDayBucket(now: t0) + 1)
        let fresh = try? await CheckInManager.readNewestCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
            [unopened]
        }
        XCTAssertNil(fresh, "the read failed")
        XCTAssertEqual(pass(rearmedEarlier, fresh: fresh, open: open), closed,
                       "closed, and not raised: that waits for a read that stands")
        // On a read that stands, the same pass closes it and raises at once.
        XCTAssertEqual(pass(rearmedEarlier, fresh: [:], open: open),
                       closed + [.raise(ruleId: ruleId, userId: ana, name: "Ana", since: hours(-3), timeoutHours: 2)])
        // Nothing open and no read that stood: nothing at all, though overdue.
        XCTAssertEqual(pass(rearmedEarlier, fresh: nil, open: [:]), [])

        // A check-in already held ends a lapse with no read too.
        XCTAssertEqual(CheckInAlerts.passActions(rules: [rule(members: [ana], armedAt: hours(-48))], members: members,
                                                 consent: [:], selfId: me, fresh: nil,
                                                 held: [CanonicalId.key(ana): hours(-1)], openLapses: open, now: t0),
                       [.resolve(ruleId: ruleId, userId: ana, checkedIn: true)])
    }

    /// The re-arm case as specified, through `decide` alone:
    /// fired with since = A1 and no check-in, then re-armed at A2 > A1 with
    /// still no check-in. The old lapse ends, nothing goes off until A2 plus
    /// the timeout, then it does. Ending lapses only on a newer check-in fails
    /// this, at each line that expects the old lapse to end.
    func testARearmEndsTheOldLapseAndTheRuleGoesOffAgainOnlyAfterItsTimeout() {
        let a1 = hours(-30)
        let a2 = t0
        XCTAssertEqual(decide(last: nil, armed: a1, now: hours(-27)).raisesSince, a1, "fired, since = A1")

        let rearmed = decide(last: nil, armed: a2, open: a1, now: hours(0.5))
        XCTAssertTrue(rearmed.resolves, "the re-arm ends the old lapse")
        XCTAssertNil(rearmed.raisesSince, "half an hour after A2: nothing yet")

        XCTAssertNil(decide(last: nil, armed: a2, now: hours(1.99)).raisesSince)
        XCTAssertNil(decide(last: nil, armed: a2, now: hours(2)).raisesSince, "A2 + timeout is not past it")
        XCTAssertEqual(decide(last: nil, armed: a2, now: hours(2).addingTimeInterval(1)).raisesSince, a2,
                       "then it goes off again, from A2")

        // A pass that first sees the re-arm after A2 + timeout ends the old
        // lapse and raises the new one at once.
        let seenLate = decide(last: nil, armed: a2, open: a1, now: hours(3))
        XCTAssertTrue(seenLate.resolves, "the re-arm ends the old lapse")
        XCTAssertEqual(seenLate.raisesSince, a2)
    }

    /// Only a check-in after the arming ends anything: one from before it is
    /// what the arming already counts past. A lapse that began after the
    /// arming (one the retired rolling rule opened at a check-in) ends at once:
    /// that check-in ended the rule.
    func testACheckInFromBeforeTheArmingEndsNothing() {
        let before = decide(last: hours(-50), armed: hours(-48), open: hours(-48), now: hours(1))
        XCTAssertFalse(before.resolves)
        XCTAssertNil(before.raisesSince, "the lapse it fired on is still open")
        let rolling = decide(last: hours(-40), armed: hours(-48), open: hours(-40), now: hours(1))
        XCTAssertTrue(rolling.resolves)
        XCTAssertFalse(rolling.checkedIn, "no check-in after it began")
        XCTAssertNil(rolling.raisesSince)
    }

    // MARK: - Judging a circle

    func testAFailedReadJudgesNobody() {
        let rules = [rule(members: [ana], armedAt: hours(-48))]
        let members = [member(ana)]
        let open = [CheckInAlerts.lapseKey(ruleId: ruleId, userId: ana): hours(-40)]
        XCTAssertEqual(CheckInAlerts.judge(rules: rules, members: members, consent: [:], selfId: me,
                                           newest: nil, openLapses: [:], now: t0), [],
                       "overdue by everything known, but a failed read is not \"no check-in\"")
        XCTAssertEqual(CheckInAlerts.judge(rules: rules, members: members, consent: [:], selfId: me,
                                           newest: nil, openLapses: open, now: t0), [],
                       "and it ends nothing either")
        // The same circle on a read that succeeded and found no check-in at all.
        XCTAssertEqual(CheckInAlerts.judge(rules: rules, members: members, consent: [:], selfId: me,
                                           newest: [:], openLapses: [:], now: t0),
                       [.raise(ruleId: ruleId, userId: ana, name: "Ana", since: hours(-48), timeoutHours: 2)])
    }

    func testThisAccountIsNeverJudged() {
        // Our own rule for everyone lists the whole roster, us included, and a
        // circle-mate's request names its owner: here, us, in another spelling.
        let rules = [rule(members: [me, ana], armedAt: hours(-48)),
                     rule(requestId, members: [me.uppercased()], armedAt: hours(-48), theirs: true)]
        let actions = CheckInAlerts.judge(rules: rules, members: [member(me, name: "Me"), member(ana)],
                                          consent: [:], selfId: me, newest: [:], openLapses: [:], now: t0)
        XCTAssertEqual(actions, [.raise(ruleId: ruleId, userId: ana, name: "Ana", since: hours(-48), timeoutHours: 2)])
    }

    /// A check-in goes out without a position, so a pause (or real time off)
    /// neither stops nor excuses one.
    func testAPausedMemberIsStillJudged() {
        let paused = member(ana, sharing: "paused")
        let off = member(ben, name: "Ben", sharing: "off")
        XCTAssertNotEqual(paused.sharing(at: t0), .on, "the roster says she isn't sharing")
        XCTAssertNotEqual(off.sharing(at: t0), .on)
        let actions = CheckInAlerts.judge(rules: [rule(members: [ana, ben], armedAt: hours(-48))],
                                          members: [paused, off], consent: [:], selfId: me,
                                          newest: [CanonicalId.key(ben): hours(-1)], openLapses: [:], now: t0)
        XCTAssertEqual(actions, [.raise(ruleId: ruleId, userId: ana, name: "Ana", since: hours(-48), timeoutHours: 2)],
                       "Ana, quiet and paused, goes off; Ben checked in an hour ago")
    }

    func testOnlyActiveMembersOfTheCircleAreJudged() {
        let actions = CheckInAlerts.judge(rules: [rule(members: [ana, ben], armedAt: hours(-48))],
                                          members: [member(ana)], consent: [:], selfId: me,
                                          newest: [:], openLapses: [:], now: t0)
        XCTAssertEqual(actions.count, 1, "Ben is not in the roster: \(actions)")
    }

    func testAllowAlertsOnMeOffSilencesARuleAboutThemButNotTheirOwnRequest() {
        let members = [member(ana)]
        let off = [CanonicalId.key(ana): false]
        XCTAssertEqual(CheckInAlerts.judge(rules: [rule(members: [ana], armedAt: hours(-48))], members: members,
                                           consent: off, selfId: me, newest: [:], openLapses: [:], now: t0), [])
        XCTAssertEqual(CheckInAlerts.judge(rules: [rule(requestId, members: [ana], armedAt: hours(-48), theirs: true)],
                                           members: members, consent: off, selfId: me, newest: [:],
                                           openLapses: [:], now: t0).count, 1,
                       "asking to be watched is their consent, as the server has it")
        for consent in [[CanonicalId.key(ana): true], [:]] {
            XCTAssertEqual(CheckInAlerts.judge(rules: [rule(members: [ana], armedAt: hours(-48))], members: members,
                                               consent: consent, selfId: me, newest: [:], openLapses: [:],
                                               now: t0).count, 1, "on, or not known: judged")
        }
    }

    func testIdsCompareInTheirOneForm() {
        let rules = [rule(members: [ana.uppercased()], armedAt: hours(-48))]
        let open = [CheckInAlerts.lapseKey(ruleId: ruleId.uppercased(), userId: ana.uppercased()): t0]
        let actions = CheckInAlerts.judge(rules: rules, members: [member(ana)], consent: [CanonicalId.key(ana): true],
                                          selfId: me.uppercased(), newest: [CanonicalId.key(ana): hours(1)],
                                          openLapses: open, now: hours(1.5))
        XCTAssertEqual(actions, [.resolve(ruleId: ruleId, userId: ana, checkedIn: true)])
    }

    func testAMemberListedTwiceIsJudgedOnce() {
        let actions = CheckInAlerts.judge(rules: [rule(members: [ana, ana.uppercased()], armedAt: hours(-48))],
                                          members: [member(ana)], consent: [:], selfId: me, newest: [:],
                                          openLapses: [:], now: t0)
        XCTAssertEqual(actions.count, 1)
    }

    // MARK: - When a background pass reads

    func testABackgroundPassReadsOnlyWhereSomethingIsDue() {
        let rules = [rule(members: [ana], armedAt: hours(-48))]
        let members = [member(ana)]
        func reads(_ rules: [CheckInAlerts.Rule], last: CheckInAlerts.Read?, open: [String: Date] = [:], now: Date) -> Bool {
            CheckInAlerts.backgroundPassReads(rules: rules, members: members, consent: [:], selfId: me,
                                              last: last, openLapses: open, now: now)
        }
        XCTAssertTrue(reads(rules, last: nil, now: t0), "never read, and 48 h since the arming: due")
        let read = CheckInAlerts.Read(at: hours(-0.5), newest: [CanonicalId.key(ana): hours(-1)])
        XCTAssertFalse(reads(rules, last: read, now: t0), "she checked in since the arming: ended, no request")
        XCTAssertFalse(reads(rules, last: read, now: hours(30)), "and nothing comes due again")
        let armedAtT0 = [rule(members: [ana], armedAt: t0)]
        XCTAssertFalse(reads(armedAtT0, last: nil, now: hours(1)),
                       "a rule armed an hour ago with a 2 h timeout: nothing due yet")
        let older = CheckInAlerts.Read(at: hours(1.5), newest: [CanonicalId.key(ana): hours(-1)])
        XCTAssertFalse(reads(armedAtT0, last: older, now: hours(1.9)))
        XCTAssertTrue(reads(armedAtT0, last: older, now: hours(2.1)), "past its timeout by that read: read again first")
    }

    func testWhileALapseIsOpenItReadsEveryHalfHour() {
        let rules = [rule(members: [ana], armedAt: hours(-48))]
        let open = [CheckInAlerts.lapseKey(ruleId: ruleId, userId: ana): hours(-48)]
        let read = CheckInAlerts.Read(at: t0, newest: [:])
        func reads(members: [CircleMember], last: CheckInAlerts.Read?, now: Date) -> Bool {
            CheckInAlerts.backgroundPassReads(rules: rules, members: members, consent: [:], selfId: me,
                                              last: last, openLapses: open, now: now)
        }
        XCTAssertFalse(reads(members: [member(ana)], last: read, now: t0.addingTimeInterval(29 * 60)))
        XCTAssertTrue(reads(members: [member(ana)], last: read, now: t0.addingTimeInterval(30 * 60)))
        XCTAssertTrue(reads(members: [member(ana)], last: nil, now: t0), "not read since launch")
        XCTAssertFalse(reads(members: [], last: read, now: hours(5)),
                       "a lapse about someone who left the circle costs no reads")
    }

    // MARK: - Reading the check-ins

    func testTheReadStopsAtAShortPageAtTheWindowOrAfterFivePages() {
        XCTAssertEqual(CheckInAlerts.pageSize, 100)
        XCTAssertEqual(CheckInAlerts.maxPages, 5)
        XCTAssertEqual(CheckInAlerts.readFloorDayBucket(now: t0), 20832, "floor((now - 26 h) / 1 day)")
        XCTAssertEqual(CheckInAlerts.readFloorDayBucket(now: Date(timeIntervalSince1970: 3 * 86_400 + 26 * 3600)), 3)
        XCTAssertEqual(CheckInAlerts.readFloorDayBucket(now: Date(timeIntervalSince1970: 3 * 86_400 + 26 * 3600 - 1)), 2)
        let floor = 20832
        XCTAssertTrue(CheckInAlerts.readsOn(pageDayBuckets: Array(repeating: floor, count: 100), floor: floor))
        XCTAssertFalse(CheckInAlerts.readsOn(pageDayBuckets: Array(repeating: floor, count: 99), floor: floor),
                       "a short page is the last")
        XCTAssertFalse(CheckInAlerts.readsOn(pageDayBuckets: Array(repeating: floor, count: 99) + [floor - 1], floor: floor),
                       "it reached past the window")
        XCTAssertFalse(CheckInAlerts.readsOn(pageDayBuckets: [], floor: floor))
    }

    private func checkIn(_ userId: String, at date: Date, type: CheckIn.CheckInType = .general) -> CheckIn {
        CheckIn(id: UUID().uuidString, circleId: circle, userId: userId, type: type, message: nil, latitude: nil,
                longitude: nil, placeId: nil, timestamp: date, isSynced: true)
    }

    func testEachMembersNewestCheckInOfAnyTypeCounts() {
        var newest: [String: Date] = [CanonicalId.key(ben): hours(-5)]
        CheckInAlerts.merge([
            checkIn(ana.uppercased(), at: hours(-3)),
            checkIn(ana, at: hours(-1), type: .safeArrival),
            checkIn(ana, at: hours(-2), type: .emergencyOk),
            checkIn(ben, at: hours(-6)),
            checkIn("", at: hours(-0.1)),
        ], into: &newest, now: t0)
        XCTAssertEqual(newest, [CanonicalId.key(ana): hours(-1), CanonicalId.key(ben): hours(-5)],
                       "newest per member, a page at a time; a row whose sender didn't open credits no one")
    }

    /// A clock may run a little fast; a check-in dated further ahead than the
    /// bound a location is held to would keep a rule quiet until that date.
    func testACheckInDatedFarAheadIsLeftOut() {
        var newest: [String: Date] = [:]
        let skew = TimeInterval(CircleManager.maxFutureSkewMs) / 1000
        CheckInAlerts.merge([checkIn(ana, at: t0.addingTimeInterval(skew + 60)),
                             checkIn(ben, at: t0.addingTimeInterval(skew - 60))], into: &newest, now: t0)
        XCTAssertNil(newest[CanonicalId.key(ana)])
        XCTAssertEqual(newest[CanonicalId.key(ben)], t0.addingTimeInterval(skew - 60))
    }

    // MARK: - Wire: the rule lists

    private let ruleHead = #""id":"b0000000-0000-4000-8000-000000000001","user_id":"a0000000-0000-4000-8000-000000000001","circle_id":"3f7a1b2c-0000-4000-8000-0123456789ab","encrypted_target_user_id":{"nonce":"nn","ciphertext":"cc"},"timeout_hours":6,"is_self_alert":false,"notify_push":true,"notify_email":false,"cooldown_minutes":60,"is_active":true,"last_triggered_day_bucket":null,"day_bucket":20415,"encrypted_conditions":null,"client_only":false,"notify_on_return":false"#

    private func decodeRules(_ rows: [String]) throws -> [InactivityAlertResponse] {
        try APIService.decodeResponseBody(Data(#"{"success":true,"data":["# .utf8)
            + Data(rows.map { "{" + $0 + "}" }.joined(separator: ",").utf8) + Data("]}".utf8))
    }

    /// 2026-11-23T10:15:30Z.
    private let armedSecond: TimeInterval = 1_795_428_930

    func testACheckInRuleDecodesItsKindAndArming() throws {
        let rows = try decodeRules([
            ruleHead + #","watches":"check_in","armed_at":"2026-11-23T10:15:30.123456Z""#,
            ruleHead + #","watches":"check_in","armed_at":"2026-11-23T10:15:30Z""#,
            ruleHead + #","watches":"check_in","armed_at":"2026-11-23T10:15:30.5Z""#,
            ruleHead + #","watches":"check_in","armed_at":"2026-11-23T10:15:30.123+00:00""#,
        ])
        XCTAssertEqual(rows.count, 4, "a whole second must not fail the list, as the wire's Date strategy would")
        XCTAssertEqual(rows.map(\.watchKind), Array(repeating: .checkIn, count: 4))
        let armed = rows.map { $0.armedAtDate?.timeIntervalSince1970 }
        XCTAssertEqual(try XCTUnwrap(armed[0]), armedSecond + 0.123456, accuracy: 0.001, "microseconds, as Postgres keeps them")
        XCTAssertEqual(try XCTUnwrap(armed[1]), armedSecond, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(armed[2]), armedSecond + 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(armed[3]), armedSecond + 0.123, accuracy: 0.001)
    }

    func testARuleFromAnOlderBackendIsALocationRule() throws {
        let rows = try decodeRules([ruleHead, ruleHead + #","watches":"location""#])
        XCTAssertEqual(rows.map(\.watchKind), [.location, .location])
        XCTAssertNil(rows[0].armedAtDate)
        XCTAssertNil(rows[0].watches)
    }

    func testAKindThisVersionDoesNotKnowIsJudgedByNeither() throws {
        let rows = try decodeRules([ruleHead + #","watches":"something_new""#,
                                    ruleHead + #","watches":"check_in","armed_at":"soon""#])
        XCTAssertNil(rows[0].watchKind)
        XCTAssertEqual(rows[1].watchKind, .checkIn)
        XCTAssertNil(rows[1].armedAtDate, "unreadable: counted from when this device first stored it")
    }

    func testACircleMatesRequestDecodesWithAndWithoutTheNewFields() throws {
        let body = Data(#"""
        {"success":true,"data":[
          {"id":"b0000000-0000-4000-8000-000000000002","user_id":"a0000000-0000-4000-8000-000000000002",
           "circle_id":"3f7a1b2c-0000-4000-8000-0123456789ab","timeout_hours":3,"notify_on_return":false,
           "watches":"check_in","armed_at":"2026-11-23T10:15:30Z"},
          {"id":"b0000000-0000-4000-8000-000000000003","user_id":"a0000000-0000-4000-8000-000000000002",
           "circle_id":"3f7a1b2c-0000-4000-8000-0123456789ab","timeout_hours":3,"notify_on_return":true}
        ]}
        """#.utf8)
        let requests: [CircleSelfAlertResponse] = try APIService.decodeResponseBody(body)
        XCTAssertEqual(requests.map(\.watchKind), [.checkIn, .location])
        XCTAssertEqual(try XCTUnwrap(requests[0].armedAtDate?.timeIntervalSince1970), armedSecond, accuracy: 0.001)
        XCTAssertNil(requests[1].armedAtDate)
    }

    func testEveryListRequestAsksForTheCheckInRules() throws {
        XCTAssertEqual(APIService.inactivityAlertsPath(limit: 100),
                       "/api/v1/inactivity-alerts?include_check_in=true&check_in_modes=once,scheduled&limit=100")
        let next = APIService.inactivityAlertsPath(limit: 100, cursorDayBucket: 20415, cursorId: ruleId)
        XCTAssertTrue(next.hasPrefix("/api/v1/inactivity-alerts?include_check_in=true&"), next)
        XCTAssertTrue(next.contains("&cursor_day_bucket=20415"), next)
        XCTAssertTrue(next.contains("&cursor_id=\(ruleId)"), next)
        XCTAssertEqual(APIService.circleSelfAlertsPath,
                       "/api/v1/inactivity-alerts/circle-self-alerts?include_check_in=true&check_in_modes=once,scheduled")

        let source = try APIServiceSource.text()
        let list = try APIServiceSource.body(ofFunc: "listInactivityAlerts", in: source)
        XCTAssertTrue(list.contains("try await get(path: Self.inactivityAlertsPath("), "every page through the path")
        XCTAssertTrue(list.contains("guard page.count >= Self.inactivityAlertsPageSize, let last = page.last else { return all }"))
        XCTAssertTrue(list.contains("throw APIError(code: \"incomplete_list\""), "a list whose pages don't end is no list")
        let requests = try APIServiceSource.body(ofFunc: "listCircleSelfAlerts", in: source)
        XCTAssertTrue(requests.contains("return try await get(path: Self.circleSelfAlertsPath)"))
    }

    // MARK: - Wire: the create

    private func createRequest(watches: String?) -> CreateInactivityAlertRequest {
        var request = CreateInactivityAlertRequest(
            circleId: circle, targetUserId: ana, encryptedTargetUserId: EncryptedBlobRequest(nonce: "nn", ciphertext: "cc"),
            timeoutMinutes: 360, isSelfAlert: false, notifyPush: true, notifyEmail: false, cooldownMinutes: 60,
            encryptedConditions: nil, clientOnly: false, targetUserPseudonym: "ps_ana", dayBucket: 20415,
            notifyOnReturn: false)
        request.watches = watches
        return request
    }

    func testACheckInRuleIsCreatedAsOneAndALocationRuleAsBefore() throws {
        let checkIn = String(decoding: try APIService.encodeRequestBody(createRequest(watches: "check_in")), as: UTF8.self)
        XCTAssertTrue(checkIn.contains(#""watches":"check_in""#), checkIn)
        XCTAssertTrue(checkIn.contains(#""target_user_pseudonym":"ps_ana""#), "a check-in rule can't exist without it")
        let location = String(decoding: try APIService.encodeRequestBody(createRequest(watches: nil)), as: UTF8.self)
        XCTAssertFalse(location.contains("watches"), "absent, as from every older app: \(location)")
        let manager = try source("App/Managers/InactivityAlertsManager.swift")
        XCTAssertTrue(manager.contains("watches: watches == .checkIn ? watches.rawValue : nil\n"))
        XCTAssertTrue(manager.contains("let notifyOnReturn = watches == .checkIn ? false : notifyOnReturn\n"),
                      "no back-online on a check-in rule")
        XCTAssertTrue(manager.contains("notifyOnReturn: alert.watchKind == .checkIn ? nil : notifyOnReturn\n"))
        XCTAssertTrue(manager.contains("&& !$0.isSelfAlert && $0.watchKind == watches }"),
                      "one rule per member and kind: a location rule doesn't stop a check-in rule")
    }

    /// A rule queued while this iPhone is behind keeps its kind; one queued by
    /// an older version reads as the location rule it was.
    func testAWaitingRuleKeepsItsKind() throws {
        let old = Data(#"{"everyone":true,"timeoutMinutes":60,"notifyPush":true,"notifyEmail":false,"cooldownMinutes":60,"notifyOnReturn":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(PendingChange.InactivityAlertInputs.self, from: old).watches)
        var inputs = PendingChange.InactivityAlertInputs(
            memberIds: [ana], everyone: false, timeoutMinutes: 120, notifyPush: true, notifyEmail: false,
            cooldownMinutes: 60, notifyOnReturn: false, watches: "check_in")
        inputs = try JSONDecoder().decode(PendingChange.InactivityAlertInputs.self, from: JSONEncoder().encode(inputs))
        XCTAssertEqual(inputs.watches, "check_in")
        let kinds = try source("App/Domain/PendingChanges/PendingChangeKinds.swift")
        XCTAssertTrue(kinds.contains("watches: inputs.watches.flatMap(InactivityWatch.init(rawValue:)) ?? .location,"))
        let manager = try source("App/Managers/InactivityAlertsManager.swift")
        XCTAssertTrue(manager.contains("watches: watches == .checkIn ? watches.rawValue : nil, schedule: schedule)),"),
                      "the queued inputs carry it")
    }

    /// The account export carries each rule's `watches` (track
    /// routes/export.rs). This app re-creates no rule from an export, so the
    /// file only has to keep it, and the section passes through as it arrived.
    func testTheExportFileKeepsEachRulesKind() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let raw = try decoder.decode(DataExportResponse.self, from: Data(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "inactivity_alerts":[{"id":"r1","timeout_hours":6,"watches":"check_in"},{"id":"r2","timeout_hours":3}]}
        """#.utf8))
        let file = TrackBackupFile.build(raw: raw, decrypted: TrackBackupFile.Decrypted(), pagesFetched: 1,
                                         isComplete: true, generatedAt: "2026-11-23T10:00:00Z")
        let rows = try XCTUnwrap(file["inactivity_alerts"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?["watches"] as? String, "check_in")
        XCTAssertNil(rows.last?["watches"], "an older export's row stays as it was: a location rule")
    }

    // MARK: - The local record

    func testAnEventStoredBeforeCheckInRulesStillReads() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = Data(#"{"id":"local-r-u-1","ruleId":"r","circleId":"c","userId":"u","memberName":"Ana","triggeredAt":"2026-11-23T10:15:30Z","isRead":false}"#.utf8)
        let event = try decoder.decode(LocalInactivityEvent.self, from: old)
        XCTAssertFalse(event.isMissedCheckIn)
        XCTAssertNil(event.lapseSince)
        XCTAssertNil(event.timeoutHours)
    }

    func testOpenMissedCheckInsAreTheOnesTheEvaluatorSees() async throws {
        let store = LocalInactivityStore.shared
        await store.loadIfNeeded()
        let rule = UUID().uuidString.lowercased()
        let location = store.record(ruleId: rule, circleId: circle, userId: ben, memberName: "Ben", triggeredAt: hours(1))
        let missed = store.record(ruleId: rule, circleId: circle, userId: ana, memberName: "Ana", triggeredAt: hours(2),
                                  watches: "check_in", lapseSince: hours(-1), timeoutHours: 3)
        defer {
            store.delete(id: missed.id)
            store.delete(id: location.id)
        }
        let open = store.openCheckInLapses
        XCTAssertEqual(open[CheckInAlerts.lapseKey(ruleId: rule, userId: ana)], hours(-1), "where the lapse started")
        XCTAssertNil(open[CheckInAlerts.lapseKey(ruleId: rule, userId: ben)], "a location lapse is not one")
        XCTAssertFalse(store.resolveMissedCheckIn(ruleId: rule, userId: ben, checkedIn: true),
                       "nor is it ended as one")
        XCTAssertTrue(store.hasUnresolved(ruleId: rule, userId: ben))
        XCTAssertTrue(store.resolveMissedCheckIn(ruleId: rule, userId: ana, checkedIn: false))
        XCTAssertNil(store.openCheckInLapses[CheckInAlerts.lapseKey(ruleId: rule, userId: ana)], "ended")
        XCTAssertFalse(store.resolveMissedCheckIn(ruleId: rule, userId: ana, checkedIn: true), "once")
        let ended = try XCTUnwrap(store.events.first { $0.id == missed.id })
        XCTAssertEqual(ended.endedByCheckIn, false, "by its rule's re-arming, as it was ended")
        XCTAssertTrue(CheckInAlerts.closedWithoutCheckIn(ended))
    }

    func testARuleWithoutAnArmingCountsFromWhenThisDeviceFirstStoredIt() async {
        let store = LocalInactivityStore.shared
        await store.loadIfNeeded()
        let rule = UUID().uuidString
        XCTAssertEqual(store.firstStored(ruleId: rule, now: hours(5)), hours(5))
        XCTAssertEqual(store.firstStored(ruleId: rule.lowercased(), now: hours(9)), hours(5), "never later than the first time")
    }

    // MARK: - Words

    func testTheWords() {
        XCTAssertEqual(CheckInAlerts.typeName, "Check-in")
        XCTAssertEqual(CheckInAlerts.missedTitle, "Missed check-in")
        XCTAssertEqual(CheckInAlerts.alertEventType, "missed_check_in")
        XCTAssertEqual(CheckInAlerts.missedBody(name: "Ana", hours: 1), "Ana hasn't checked in for 1 hour.")
        XCTAssertEqual(CheckInAlerts.missedBody(name: "Ana", hours: 6), "Ana hasn't checked in for 6 hours.")
        XCTAssertEqual(CheckInAlerts.summary(hours: 1), "Check in within 1 hour")
        XCTAssertEqual(CheckInAlerts.summary(hours: 24), "Check in within 24 hours")
        XCTAssertEqual(CheckInAlerts.helperWatchingOthers, "Get notified when this person doesn't check in on time.")
        XCTAssertEqual(CheckInAlerts.helperAboutMe, "Your circle is notified if you don't check in on time.")
        XCTAssertEqual(CheckInAlerts.endsWhenTheyCheckIn, "Ends when they check in.")
        XCTAssertEqual(CheckInAlerts.endsWhenYouCheckIn, "Ends when you check in.")
        XCTAssertEqual(CheckInAlerts.editorNote(aboutMe: false, kind: .once),
                       "Get notified when this person doesn't check in on time. Ends when they check in.")
        XCTAssertEqual(CheckInAlerts.editorNote(aboutMe: true, kind: .once),
                       "Your circle is notified if you don't check in on time. Ends when you check in.")
        XCTAssertEqual(CheckInAlerts.editorNote(aboutMe: false, kind: .scheduled), CheckInAlerts.helperWatchingOthers,
                       "the same words for either kind; only a one-time rule ends")
        XCTAssertEqual(CheckInAlerts.editorNote(aboutMe: true, kind: .scheduled), CheckInAlerts.helperAboutMe)
        XCTAssertEqual(CheckInAlerts.onceKindName, "Within a time")
        XCTAssertEqual(CheckInAlerts.scheduledKindName, "By a time of day")
        for line in [CheckInAlerts.editorNote(aboutMe: false, kind: .once), CheckInAlerts.editorNote(aboutMe: true, kind: .once),
                     CheckInAlerts.missedBody(name: "Ana", hours: 6)] {
            XCTAssertFalse(line.contains("—"), "no em-dash pauses: \(line)")
        }
    }

    func testTheBellAndTheHistorySayWhatTheNotificationSaid() {
        var event = LocalInactivityEvent(id: "local-r-u-1", ruleId: ruleId, circleId: circle, userId: ana, memberName: "Ana",
                                         triggeredAt: t0, resolvedAt: nil, isRead: false,
                                         watches: "check_in", lapseSince: hours(-6), timeoutHours: 6)
        let row = NotificationsManager.localRow(event)
        XCTAssertEqual(row.notificationType, "missed_check_in")
        XCTAssertEqual(row.title, "Missed check-in")
        XCTAssertEqual(row.body, "Ana hasn't checked in for 6 hours.")
        XCTAssertEqual(row.iconName, "clock.badge.exclamationmark")
        XCTAssertEqual(row.iconColor, .orange)
        XCTAssertEqual(CheckInAlerts.historyLine(event), "Ana hasn't checked in for 6 hours.")
        XCTAssertFalse(CheckInAlerts.closedWithoutCheckIn(event), "still open")
        // Once ended it keeps its words, marked as ended: the check-in that
        // ended it is a row of its own in the history (CheckInHistory).
        event.resolvedAt = hours(1)
        event.endedByCheckIn = true
        XCTAssertEqual(CheckInAlerts.historyLine(event), "Ana hasn't checked in for 6 hours.")
        XCTAssertFalse(CheckInAlerts.closedWithoutCheckIn(event))
        // Ended because its rule was turned back on: shown closed, not as good news.
        event.endedByCheckIn = false
        XCTAssertEqual(CheckInAlerts.historyLine(event), "Ana hasn't checked in for 6 hours.")
        XCTAssertTrue(CheckInAlerts.closedWithoutCheckIn(event))
        XCTAssertEqual(CheckInAlerts.endedMark, "Ended")

        let location = LocalInactivityEvent(id: "local-r-u-2", ruleId: ruleId, circleId: circle, userId: ana,
                                            memberName: "Ana", triggeredAt: t0, resolvedAt: nil, isRead: false)
        XCTAssertEqual(NotificationsManager.localRow(location).notificationType, "inactivity_alert", "unchanged")
        XCTAssertEqual(NotificationsManager.localRow(location).body, "Ana hasn't sent a location recently")
    }

    // MARK: - The editor, as VoiceOver reads it

    // SwiftUI builds its accessibility tree only while an assistive technology
    // is on: the switch RuleEmailSwitchTests borrows from MemberRowAccessibilityTests.
    private func spokenLabels(of view: some View) throws -> [String] {
        typealias Getter = @convention(c) () -> Bool
        typealias Setter = @convention(c) (Bool) -> Void
        guard let lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let getter = dlsym(lib, "_AXSApplicationAccessibilityEnabled"),
              let setter = dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") else {
            throw XCTSkip("this simulator runtime has no application accessibility switch")
        }
        let get = unsafeBitCast(getter, to: Getter.self)
        let set = unsafeBitCast(setter, to: Setter.self)
        let was = get()
        set(true)
        defer { set(was) }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 1400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var found: [String] = []
        collect(host.view, into: &found, depth: 0)
        window.isHidden = true
        return found
    }

    private func collect(_ object: NSObject, into found: inout [String], depth: Int) {
        guard depth < 30 else { return }
        if object.isAccessibilityElement, let label = object.accessibilityLabel, !label.isEmpty {
            found.append(label)
        }
        if let elements = object.accessibilityElements as? [NSObject] {
            for element in elements { collect(element, into: &found, depth: depth + 1) }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject {
                        collect(element, into: &found, depth: depth + 1)
                    }
                }
            }
        }
        if let view = object as? UIView {
            for subview in view.subviews { collect(subview, into: &found, depth: depth + 1) }
        }
    }

    private func editorLabels(_ mode: AlertEditorMode) throws -> [String] {
        try spokenLabels(of: NavigationStack { AlertEditorView(mode: mode) })
    }

    /// The location rule's editor, as the control: the probe hears its footer
    /// and its back-online switch, so their absence below means something.
    func testTheLocationEditorStillOffersBackOnline() throws {
        let spoken = try editorLabels(.createInactivity)
        XCTAssertTrue(spoken.contains("Notify when back online"), "\(spoken)")
        XCTAssertTrue(spoken.contains(AlertEditorView.notWhileNotSharing), "\(spoken)")
    }

    func testTheCheckInEditorSaysWhatItDoesAndNothingAboutLocation() throws {
        let spoken = try editorLabels(.createCheckIn)
        XCTAssertTrue(spoken.contains(CheckInAlerts.editorNote(aboutMe: false, kind: .once)), "\(spoken)")
        XCTAssertTrue(spoken.contains("Alert about me"), "\(spoken)")
        XCTAssertTrue(spoken.contains("Push"), "\(spoken)")
        XCTAssertFalse(spoken.contains("Notify when back online"), "\(spoken)")
        XCTAssertFalse(spoken.contains(AlertEditorView.notWhileNotSharing), "\(spoken)")
        XCTAssertFalse(spoken.contains { $0.localizedCaseInsensitiveContains("sending locations") }, "\(spoken)")
        XCTAssertFalse(spoken.contains { $0.localizedCaseInsensitiveContains("email") }, "\(spoken)")
    }

    func testEditingACheckInRuleKeepsItsWords() throws {
        let rows = try decodeRules([
            ruleHead + #","watches":"check_in","armed_at":"2026-11-23T10:15:30Z""#,
            ruleHead.replacingOccurrences(of: #""is_self_alert":false"#, with: #""is_self_alert":true"#)
                + #","watches":"check_in","armed_at":"2026-11-23T10:15:30Z""#,
        ])
        XCTAssertTrue(AlertEditorMode.editInactivity(rows[0]).watchesCheckIns)
        XCTAssertTrue(AlertEditorMode.createCheckIn.watchesCheckIns)
        XCTAssertFalse(AlertEditorMode.createInactivity.watchesCheckIns)
        let others = try editorLabels(.editInactivity(rows[0]))
        XCTAssertTrue(others.contains(CheckInAlerts.editorNote(aboutMe: false, kind: .once)), "\(others)")
        XCTAssertFalse(others.contains("Notify when back online"), "\(others)")
        XCTAssertFalse(others.contains(AlertEditorView.notWhileNotSharing), "\(others)")
        let aboutMe = try editorLabels(.editInactivity(rows[1]))
        XCTAssertTrue(aboutMe.contains(CheckInAlerts.editorNote(aboutMe: true, kind: .once)), "\(aboutMe)")
        XCTAssertFalse(aboutMe.contains("Notify when back online"), "\(aboutMe)")
    }

    // MARK: - Wiring (source)

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func body(of function: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: function), function)
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex), function)
        return String(text[start.upperBound..<end.lowerBound])
    }

    func testEveryPassJudgesTheCheckInRulesAndOnlyTheWakeAlwaysReads() throws {
        let monitor = try source("App/Managers/MonitoringManager.swift")
        XCTAssertTrue(try body(of: "func evaluateForAlertsCheck() async {", in: monitor)
            .contains("await evaluateCheckInAlerts(readEveryCircle: true)"))
        XCTAssertTrue(try body(of: "private func refreshAndEvaluatePass() async {", in: monitor)
            .contains("await evaluateCheckInAlerts(readEveryCircle: false)"))
        XCTAssertTrue(try body(of: "private func evaluateInactivityAlertsThrottledPass() async {", in: monitor)
            .contains("await evaluateCheckInAlerts(readEveryCircle: false)"))
        XCTAssertEqual(monitor.components(separatedBy: "await evaluateCheckInAlerts(").count - 1, 3)
    }

    func testTheLocationPassesLeaveCheckInRulesAlone() throws {
        let monitor = try source("App/Managers/MonitoringManager.swift")
        XCTAssertTrue(try body(of: "func evaluateInactivityAlerts() async {", in: monitor)
            .contains("inactivity.alerts.filter { $0.isActive && !$0.isSelfAlert && $0.watchKind == .location }"))
        XCTAssertTrue(try body(of: "func evaluateCircleSelfAlerts() async {", in: monitor)
            .contains("let alerts = fetched.filter { $0.watchKind == .location }"))
    }

    func testTheCheckInPassRaisesOnlyOnAReadOfThisPass() throws {
        let monitor = try source("App/Managers/MonitoringManager.swift")
        let pass = try body(of: "func evaluateCheckInAlerts(readEveryCircle: Bool) async {", in: monitor)
        XCTAssertTrue(pass.contains("$0.isActive && !$0.isSelfAlert && CheckInAlerts.judgeable(kind: $0.checkInKind, schedule: $0.schedule)"))
        XCTAssertTrue(pass.contains("let requests = (fetchedRequests ?? []).filter {\n            CheckInAlerts.judgeable(kind: $0.checkInKind, schedule: $0.schedule)"))
        let read = try XCTUnwrap(pass.range(of: """
                        if reads {
                            // Back to the window of each scheduled rule's latest occurrence
                            // too, which a weekly pattern puts days back.
                            fresh = try? await CheckInManager.shared.newestCheckIns(
                                circleId: circleId, from: CheckInAlerts.readFrom(circleRules, now: Date()))
                        }
            """))
        let actions = try XCTUnwrap(pass.range(of: "let actions = CheckInAlerts.passActions("))
        XCTAssertLessThan(read.lowerBound, actions.lowerBound, "decided on what this pass read")
        XCTAssertTrue(pass.contains(
            "fresh: fresh, held: checkInReads[circleKey]?.newest, openLapses: store.openCheckInLapses, now: now)"),
                      "nil when the pass didn't read or its read failed: then only lapses end")
        XCTAssertTrue(pass.contains("""
                        if let fresh {
                            checkInReads[circleKey] = CheckInAlerts.Read(at: now, newest: fresh)
                        }
            """), "only a read that stands is kept")
        XCTAssertEqual(pass.components(separatedBy: "CheckInAlerts.passActions(").count - 1, 1)
        XCTAssertFalse(pass.contains("CheckInAlerts.judge("), "only through passActions, which raises only on a read")
        XCTAssertTrue(pass.contains("alertType: CheckInAlerts.alertEventType, triggeredAt: now"))
        XCTAssertTrue(pass.contains("guard !store.hasUnresolved(ruleId: ruleId, userId: userId) else { continue }"))
        XCTAssertTrue(pass.contains("""
                                if store.resolveMissedCheckIn(ruleId: ruleId, userId: userId, checkedIn: checkedIn) {
                                    cancelMissedCheckInNotification(ruleId: ruleId, userId: userId)
                                }
            """), "an ended lapse takes back its notification")
        for location in ["sharing(at:", "shouldJudge", "noteNotSharing", "memberRefresh("] {
            XCTAssertFalse(pass.contains(location), "a check-in rule isn't judged by location: \(location)")
        }
        // The live read is the tested one, fed by the circle's route.
        let manager = try source("App/Managers/CheckInManager.swift")
        let live = try body(of: "func newestCheckIns(circleId: String, from: Date? = nil, now: Date = Date()) async throws -> [String: Date] {", in: manager)
        XCTAssertTrue(live.contains("return try await Self.readNewestCheckIns(circleId: circleId, now: now, from: from, crypto: cryptoManager) {"))
        XCTAssertTrue(live.contains("try await api.listCircleCheckIns("))
    }

    // MARK: - The read, sealed for real

    /// This account's copy of the circle key: it seals rows as a member's
    /// phone does, and opens them as this phone does.
    private func sealer() throws -> CryptoManager {
        let crypto = CryptoManager()
        // A circle is made by an account with its own keys (CurrentKeySealingTests).
        _ = crypto.generateKeypair()
        _ = crypto.generateSigningKeypair()
        let creation = try crypto.prepareCircleCreation()
        try crypto.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circle)
        return crypto
    }

    /// A check-in row as the server serves it. A nil sender or time is sealed
    /// under nothing this phone holds, so it doesn't open.
    private func row(_ id: String, by crypto: CryptoManager, sender: String?, at time: Date?, day: Int) throws -> CheckInResponse {
        func sealed(_ text: String?, _ fieldTag: String) throws -> [String: String] {
            guard let text else { return ["nonce": "00", "ciphertext": "00"] }
            let blob = try crypto.encryptDataV2(circleId: circle, plaintext: text, fieldTag: fieldTag)
            return ["nonce": blob.nonce, "ciphertext": blob.ciphertext]
        }
        let json: [String: Any] = [
            "id": id, "circle_id": circle, "check_in_type": "general", "day_bucket": day,
            "encrypted_user_id": try sealed(sender, "user_id"),
            "encrypted_device_id": ["nonce": "00", "ciphertext": "00"],
            "encrypted_timestamp": try sealed(time.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) },
                                              "timestamp"),
        ]
        return try APIService.makeWireDecoder().decode(CheckInResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A check-in inside the window that doesn't open here (sealed under a key
    /// this phone doesn't hold yet, say) may be exactly the one that matters:
    /// the read fails, as a page that didn't come does, and judged on that,
    /// nobody in the circle is. The same rows below the window are skipped.
    func testACheckInInsideTheWindowThatDoesntOpenFailsTheRead() async throws {
        let crypto = try sealer()
        let floor = CheckInAlerts.readFloorDayBucket(now: t0)
        let good = try row("k-good", by: crypto, sender: ana, at: hours(-1), day: floor + 1)
        let noTime = try row("k-time", by: crypto, sender: ben, at: nil, day: floor)
        let noSender = try row("k-sender", by: crypto, sender: nil, at: hours(-2), day: floor + 1)
        XCTAssertNotNil(CheckInManager.openCheckIn(good, circleId: circle, crypto: crypto))
        XCTAssertNil(CheckInManager.openCheckIn(noTime, circleId: circle, crypto: crypto), "its sealed time doesn't open")
        XCTAssertEqual(CheckInManager.openCheckIn(noSender, circleId: circle, crypto: crypto)?.checkIn.userId, "",
                       "its sender doesn't open, though its time does")

        let rules = [rule(members: [ana, ben], armedAt: hours(-48))]
        let members = [member(ana), member(ben, name: "Ben")]
        for unopened in [noTime, noSender] {
            var newest: [String: Date]?
            do {
                newest = try await CheckInManager.readNewestCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
                    [good, unopened]
                }
                XCTFail("\(unopened.id): a check-in in the window that didn't open must fail the read")
            } catch is CheckInAlerts.UnopenedCheckIn {
            }
            XCTAssertNil(newest)
            XCTAssertEqual(CheckInAlerts.judge(rules: rules, members: members, consent: [:], selfId: me,
                                               newest: newest, openLapses: [:], now: t0), [],
                           "\(unopened.id): nobody is judged, though Ben has no check-in that opened")
            XCTAssertEqual(CheckInAlerts.passActions(rules: rules, members: members, consent: [:], selfId: me,
                                                     fresh: newest, held: nil, openLapses: [:], now: t0), [],
                           "\(unopened.id): and the pass raises nothing")
        }

        let oldNoTime = try row("k-time-old", by: crypto, sender: ben, at: nil, day: floor - 1)
        let oldNoSender = try row("k-sender-old", by: crypto, sender: nil, at: hours(-40), day: floor - 1)
        let newest = try await CheckInManager.readNewestCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
            [good, oldNoTime, oldNoSender]
        }
        XCTAssertEqual(newest, [CanonicalId.key(ana): hours(-1)], "below the window: skipped, and the read stands")
        XCTAssertEqual(CheckInAlerts.judge(rules: rules, members: members, consent: [:], selfId: me,
                                           newest: newest, openLapses: [:], now: t0),
                       [.raise(ruleId: ruleId, userId: ben, name: "Ben", since: hours(-48), timeoutHours: 2)],
                       "on a read that stands, Ben's silence counts")
    }

    /// The read pages on from the last row it got (its day bucket and id),
    /// stops at a short page or after five, and fails whole when a page fails.
    func testTheReadPagesOnFromItsLastRowAndFailsWhole() async throws {
        let crypto = try sealer()
        let floor = CheckInAlerts.readFloorDayBucket(now: t0)
        let full = try (0..<CheckInAlerts.pageSize).map { i in
            try row(String(format: "k-%03d", i), by: crypto, sender: ana,
                    at: hours(-1).addingTimeInterval(-Double(i)), day: floor + 1)
        }
        let short = [try row("k-ben", by: crypto, sender: ben, at: hours(-5), day: floor)]

        var cursors: [String] = []
        let newest = try await CheckInManager.readNewestCheckIns(circleId: circle, now: t0, crypto: crypto) { day, id in
            cursors.append("\(day.map { "\($0)" } ?? "-")/\(id ?? "-")")
            return cursors.count == 1 ? full : short
        }
        XCTAssertEqual(cursors, ["-/-", "\(floor + 1)/k-099"], "the second page from the first one's last row")
        XCTAssertEqual(newest, [CanonicalId.key(ana): hours(-1), CanonicalId.key(ben): hours(-5)])

        var pages = 0
        _ = try await CheckInManager.readNewestCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
            pages += 1
            return full
        }
        XCTAssertEqual(pages, CheckInAlerts.maxPages, "full pages inside the window: five, then it stops")

        struct PageDidNotCome: Error {}
        var calls = 0
        do {
            _ = try await CheckInManager.readNewestCheckIns(circleId: circle, now: t0, crypto: crypto) { _, _ in
                calls += 1
                if calls == 2 { throw PageDidNotCome() }
                return full
            }
            XCTFail("a page that didn't come fails the read")
        } catch is PageDidNotCome {
        }
        XCTAssertEqual(calls, 2)
    }
}
