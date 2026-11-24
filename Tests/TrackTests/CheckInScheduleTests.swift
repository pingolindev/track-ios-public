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

/// One-time and scheduled check-in alerts (migration 197). The occurrence
/// maths every platform must agree on to the minute (the server's own test
/// vectors are here too: track-workers check_in_schedule.rs), the scheduled
/// verdict, the end of lapses whose rule is no longer judged, the countdown
/// lines, the summaries and words, the wire, and following the phone's zone.
@MainActor
final class CheckInScheduleTests: XCTestCase {

    private let circle = "3f7a1b2c-0000-4000-8000-0123456789ab"
    private let me = "a0000000-0000-4000-8000-000000000001"
    private let ana = "a0000000-0000-4000-8000-000000000002"
    private let us = Locale(identifier: "en_US")

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func schedule(_ days: Int, due: Int, from: Int? = nil, _ zone: String) -> CheckInSchedule {
        CheckInSchedule(days: days, dueMinute: due, fromMinute: from, timeZone: zone)!
    }

    /// Newer ICU puts a narrow no-break space before "PM".
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: - The occurrence maths

    func testARowOutOfRangeOrWithAnUnknownZoneIsNoSchedule() {
        XCTAssertNil(CheckInSchedule(days: 0, dueMinute: 60, fromMinute: nil, timeZone: "UTC"), "no day")
        XCTAssertNil(CheckInSchedule(days: 128, dueMinute: 60, fromMinute: nil, timeZone: "UTC"))
        XCTAssertNil(CheckInSchedule(days: 1, dueMinute: 1440, fromMinute: nil, timeZone: "UTC"))
        XCTAssertNil(CheckInSchedule(days: 1, dueMinute: 60, fromMinute: 60, timeZone: "UTC"), "from must be before due")
        XCTAssertNil(CheckInSchedule(days: 1, dueMinute: 60, fromMinute: nil, timeZone: "Mars/Olympus"))
        XCTAssertNil(CheckInSchedule(days: nil, dueMinute: 60, fromMinute: nil, timeZone: "UTC"))
        XCTAssertNotNil(CheckInSchedule(days: 1, dueMinute: 60, fromMinute: 0, timeZone: "UTC"))
    }

    func testEveryDayByNineInNewYork() {
        let s = schedule(CheckInSchedule.everyDay, due: 21 * 60, "America/New_York")
        // 2026-11-24 is EST (UTC-5): 9:00 PM local = 02:00 UTC the next day.
        let before = utc(2026, 11, 25, 1, 59)
        XCTAssertEqual(s.latest(atOrBefore: before)?.due, utc(2026, 11, 24, 2, 0), "the 23rd's, 9:00 PM")
        XCTAssertEqual(s.latest(atOrBefore: before)?.windowStart, utc(2026, 11, 23, 5, 0), "from midnight on the 23rd")
        let at = utc(2026, 11, 25, 2, 0)
        XCTAssertEqual(s.latest(atOrBefore: at)?.due, at, "a deadline counts at its own minute")
        XCTAssertEqual(s.next(after: before)?.due, at)
        XCTAssertEqual(s.next(after: at)?.due, utc(2026, 11, 26, 2, 0), "after it, the next day's")
    }

    func testAFromTimeStartsTheWindowThatDay() {
        let s = schedule(CheckInSchedule.everyDay, due: 21 * 60, from: 18 * 60, "Europe/Berlin")
        // 2026-11-24, CET (UTC+1): from 6 PM = 17:00 UTC, due 9 PM = 20:00 UTC.
        let o = s.latest(atOrBefore: utc(2026, 11, 24, 20, 30))
        XCTAssertEqual(o?.due, utc(2026, 11, 24, 20, 0))
        XCTAssertEqual(o?.windowStart, utc(2026, 11, 24, 17, 0))
        XCTAssertEqual(s.next(after: utc(2026, 11, 24, 20, 30))?.windowStart, utc(2026, 11, 25, 17, 0))
    }

    func testWeeklyPatternsCarryOverTheWeekBoundary() {
        // 2026-11-23 is a Monday; 11-28 a Saturday, 11-29 a Sunday, 11-30 a Monday.
        let weekdays = schedule(CheckInSchedule.weekdays, due: 10 * 60, "UTC")
        XCTAssertEqual(weekdays.latest(atOrBefore: utc(2026, 11, 29, 12, 0))?.due, utc(2026, 11, 27, 10, 0), "Friday's")
        XCTAssertEqual(weekdays.next(after: utc(2026, 11, 28, 12, 0))?.due, utc(2026, 11, 30, 10, 0), "then Monday's")
        let sundays = schedule(1 << 6, due: 10 * 60, "UTC")
        XCTAssertEqual(sundays.latest(atOrBefore: utc(2026, 11, 28, 12, 0))?.due, utc(2026, 11, 22, 10, 0), "a week back")
        let mondays = schedule(1 << 0, due: 9 * 60, "UTC")
        XCTAssertEqual(mondays.latest(atOrBefore: utc(2026, 11, 29, 23, 0))?.due, utc(2026, 11, 23, 9, 0),
                       "on Sunday night, last Monday's")
        XCTAssertEqual(mondays.next(after: utc(2026, 11, 29, 23, 0))?.due, utc(2026, 11, 30, 9, 0), "then tomorrow's")
        XCTAssertEqual(mondays.latest(atOrBefore: utc(2026, 11, 30, 8, 59))?.due, utc(2026, 11, 23, 9, 0),
                       "a Monday morning before its time: still last week's")
        let saturdaysAndMondays = schedule((1 << 5) | (1 << 0), due: 9 * 60, "UTC")
        XCTAssertEqual(saturdaysAndMondays.latest(atOrBefore: utc(2026, 11, 29, 12, 0))?.due, utc(2026, 11, 28, 9, 0))
        XCTAssertEqual(saturdaysAndMondays.next(after: utc(2026, 11, 29, 12, 0))?.due, utc(2026, 11, 30, 9, 0))
        XCTAssertEqual(CheckInSchedule.weekdayFromMonday(.init(year: 2026, month: 11, day: 23)), 0, "bit 0 is Monday")
        XCTAssertEqual(CheckInSchedule.weekdayFromMonday(.init(year: 2026, month: 11, day: 29)), 6, "bit 6 is Sunday")
    }

    /// 2026-03-08: New York clocks go 2:00 EST -> 3:00 EDT. 2:30 AM doesn't
    /// exist; read with EST it is 07:30 UTC, i.e. 3:30 AM EDT.
    func testASpringForwardGapShiftsTheTimeForward() {
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(CheckInSchedule.instant(.init(year: 2026, month: 3, day: 8), minute: 2 * 60 + 30, in: ny),
                       utc(2026, 3, 8, 7, 30))
        let s = schedule(CheckInSchedule.everyDay, due: 2 * 60 + 30, "America/New_York")
        XCTAssertEqual(s.latest(atOrBefore: utc(2026, 3, 8, 7, 30))?.due, utc(2026, 3, 8, 7, 30))
        XCTAssertEqual(s.latest(atOrBefore: utc(2026, 3, 8, 7, 29))?.due, utc(2026, 3, 7, 7, 30), "the day before: EST")
        XCTAssertEqual(s.next(after: utc(2026, 3, 8, 7, 30))?.due, utc(2026, 3, 9, 6, 30), "the day after: 2:30 EDT")
        // A from time in the gap moves forward the same way; times around it don't move.
        let fromInGap = schedule(CheckInSchedule.everyDay, due: 9 * 60, from: 2 * 60 + 15, "America/New_York")
        XCTAssertEqual(fromInGap.latest(atOrBefore: utc(2026, 3, 8, 14, 0))?.windowStart, utc(2026, 3, 8, 7, 15))
        XCTAssertEqual(CheckInSchedule.instant(.init(year: 2026, month: 3, day: 8), minute: 3 * 60, in: ny),
                       utc(2026, 3, 8, 7, 0), "3:00 AM exists: EDT")
        XCTAssertEqual(CheckInSchedule.instant(.init(year: 2026, month: 3, day: 8), minute: 60 + 59, in: ny),
                       utc(2026, 3, 8, 6, 59), "1:59 AM exists: EST")
    }

    /// 2026-11-01: New York clocks go 2:00 EDT -> 1:00 EST. 1:30 AM happens
    /// twice; the earlier is 1:30 EDT = 05:30 UTC. Foundation's own
    /// `date(from:)` would take the later one.
    func testAFallBackRepeatTakesTheEarlierTime() {
        let ny = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(CheckInSchedule.instant(.init(year: 2026, month: 11, day: 1), minute: 90, in: ny),
                       utc(2026, 11, 1, 5, 30))
        let s = schedule(CheckInSchedule.everyDay, due: 90, "America/New_York")
        XCTAssertEqual(s.latest(atOrBefore: utc(2026, 11, 1, 6, 0))?.windowStart, utc(2026, 11, 1, 4, 0),
                       "midnight that day is still EDT")
        XCTAssertEqual(s.latest(atOrBefore: utc(2026, 11, 1, 5, 30))?.due, utc(2026, 11, 1, 5, 30))
        XCTAssertEqual(s.latest(atOrBefore: utc(2026, 11, 1, 5, 29))?.due, utc(2026, 10, 31, 5, 30), "the day before")
        XCTAssertEqual(s.next(after: utc(2026, 11, 1, 5, 30))?.due, utc(2026, 11, 2, 6, 30), "the day after: EST")
        XCTAssertEqual(CheckInSchedule.instant(.init(year: 2026, month: 11, day: 1), minute: 2 * 60, in: ny),
                       utc(2026, 11, 1, 7, 0), "2:00 AM happens once: EST")
    }

    // MARK: - The scheduled verdict

    private let everyDayByNineNY = CheckInSchedule(days: CheckInSchedule.everyDay, dueMinute: 21 * 60, fromMinute: nil,
                                                   timeZone: "America/New_York")!

    private func decide(last: Date?, armed: Date, open: Date? = nil, now: Date) -> CheckInAlerts.Decision {
        CheckInAlerts.decideScheduled(last: last, armedAt: armed, schedule: everyDayByNineNY, openSince: open, now: now)
    }

    /// Tuesday 2026-11-24 in New York (EST): 9 PM = 02:00 UTC on the 25th; its
    /// window opens at midnight, 05:00 UTC on the 24th.
    private var tuesdayDue: Date { utc(2026, 11, 25, 2, 0) }
    private var tuesdayStart: Date { utc(2026, 11, 24, 5, 0) }
    private var armedLastWeek: Date { utc(2026, 11, 17, 12, 0) }

    func testItGoesOffAtTheDeadlineWithNoCheckInSinceTheWindowOpened() {
        let tenPM = utc(2026, 11, 25, 3, 0)
        XCTAssertEqual(decide(last: nil, armed: armedLastWeek, now: tenPM).raisesSince, tuesdayDue, "starts at D")
        XCTAssertEqual(decide(last: utc(2026, 11, 24, 4, 59), armed: armedLastWeek, now: tenPM).raisesSince, tuesdayDue,
                       "a check-in before the window opened doesn't count")
        XCTAssertNil(decide(last: tuesdayStart, armed: armedLastWeek, now: tenPM).raisesSince, "one at its opening does")
        XCTAssertNil(decide(last: utc(2026, 11, 25, 2, 30), armed: armedLastWeek, now: tenPM).raisesSince,
                     "and one after the deadline too")
        XCTAssertNil(decide(last: nil, armed: utc(2026, 11, 25, 2, 0), now: tenPM).raisesSince,
                     "armed at D: not before it, so nothing")
        XCTAssertEqual(decide(last: nil, armed: utc(2026, 11, 25, 1, 59), now: tenPM).raisesSince, tuesdayDue)
    }

    func testAnOpenLapseEndsOnACheckInOrWhenTheNextOccurrenceComesDue() {
        let tenPM = utc(2026, 11, 25, 3, 0)
        let stillOpen = decide(last: nil, armed: armedLastWeek, open: tuesdayDue, now: tenPM)
        XCTAssertFalse(stillOpen.resolves)
        XCTAssertNil(stillOpen.raisesSince, "raised once per occurrence")

        let checkedIn = decide(last: utc(2026, 11, 25, 2, 45), armed: armedLastWeek, open: tuesdayDue, now: tenPM)
        XCTAssertTrue(checkedIn.resolves)
        XCTAssertTrue(checkedIn.checkedIn)
        XCTAssertNil(checkedIn.raisesSince, "that check-in is in the window: nothing new")

        // Wednesday 10 PM: Wednesday's occurrence took over without a check-in.
        let wednesdayTenPM = utc(2026, 11, 26, 3, 0)
        let next = decide(last: nil, armed: armedLastWeek, open: tuesdayDue, now: wednesdayTenPM)
        XCTAssertTrue(next.resolves)
        XCTAssertFalse(next.checkedIn)
        XCTAssertEqual(next.raisesSince, utc(2026, 11, 26, 2, 0), "and Wednesday's goes off in the same pass")
    }

    func testJudgeTellsTheKindsApartAndAScheduledRaiseCarriesItsTime() {
        let rule = CheckInAlerts.Rule(id: "r1", circleId: circle, timeoutHours: 1, armedAt: armedLastWeek,
                                      memberIds: [ana], isTheirRequest: false, schedule: everyDayByNineNY)
        let member = CircleMember(circleId: circle, userId: ana, displayName: "Ana", role: .member, canSeeRealtime: true,
                                  canSeeHistory: true, canRotateKeys: false, joinedAt: armedLastWeek)
        let actions = CheckInAlerts.judge(rules: [rule], members: [member], consent: [:], selfId: me,
                                          newest: [:], openLapses: [:], now: utc(2026, 11, 25, 3, 0))
        XCTAssertEqual(actions, [.raise(ruleId: "r1", userId: ana, name: "Ana", since: tuesdayDue, timeoutHours: 1,
                                        dueMinute: 21 * 60)])
        // Tuesday 8 PM, with a check-in on Monday at 8 PM: an hour's rule would
        // be long overdue; by its schedule, Monday's was met and Tuesday's isn't due.
        XCTAssertEqual(CheckInAlerts.judge(rules: [rule], members: [member], consent: [:], selfId: me,
                                           newest: [CanonicalId.key(ana): utc(2026, 11, 24, 1, 0)], openLapses: [:],
                                           now: utc(2026, 11, 25, 1, 0)), [])
        XCTAssertEqual(CheckInAlerts.readFrom([rule], now: utc(2026, 11, 25, 3, 0)), tuesdayStart)
        XCTAssertNil(CheckInAlerts.readFrom([CheckInAlerts.Rule(id: "r2", circleId: circle, timeoutHours: 6,
                                                                 armedAt: armedLastWeek, memberIds: [ana],
                                                                 isTheirRequest: false)], now: tuesdayDue))
        let weekly = CheckInSchedule(days: 1 << 0, dueMinute: 9 * 60, fromMinute: nil, timeZone: "UTC")!
        let now = utc(2026, 11, 29, 23, 0)
        XCTAssertEqual(CheckInAlerts.readFloorDayBucket(now: now, from: weekly.latest(atOrBefore: now)?.windowStart),
                       CheckInCountdown.dayBucket(utc(2026, 11, 23, 0, 0)), "a weekly window reaches back past a day")
        XCTAssertEqual(CheckInAlerts.readFloorDayBucket(now: now, from: nil), CheckInAlerts.readFloorDayBucket(now: now))
    }

    func testOnlyAKindThisVersionJudgesIsJudged() {
        XCTAssertTrue(CheckInAlerts.judgeable(kind: .once, schedule: nil))
        XCTAssertTrue(CheckInAlerts.judgeable(kind: .scheduled, schedule: everyDayByNineNY))
        XCTAssertFalse(CheckInAlerts.judgeable(kind: .scheduled, schedule: nil), "a schedule that doesn't read")
        XCTAssertFalse(CheckInAlerts.judgeable(kind: nil, schedule: nil), "a kind this version doesn't know")
    }

    // MARK: - Lapses of rules no longer judged

    private func lapse(_ rule: String, missed: Bool = true, resolved: Bool = false) -> LocalInactivityEvent {
        LocalInactivityEvent(id: "local-\(rule)", ruleId: rule, circleId: circle, userId: ana, memberName: "Ana",
                             triggeredAt: tuesdayDue, resolvedAt: resolved ? tuesdayDue : nil, isRead: false,
                             watches: missed ? "check_in" : nil, lapseSince: tuesdayDue, timeoutHours: 1)
    }

    func testALapseWhoseRuleIsNoLongerJudgedEndsOnlyWhenThatIsKnown() throws {
        let open = [lapse("judged"), lapse("mine-off"), lapse("mine-deleted"), lapse("request-gone"),
                    lapse("request-live"), lapse("location", missed: false), lapse("ended", resolved: true)]
        let judged: Set<String> = ["judged", "request-live"]
        let own: Set<String> = ["judged", "mine-off"]
        let requests: Set<String> = ["request-live"]
        XCTAssertEqual(CheckInAlerts.lapsesNoLongerJudged(open, judged: judged, ownRules: own, requests: requests).map(\.ruleId),
                       ["mine-off", "mine-deleted", "request-gone"],
                       "turned off (or ended), deleted, a request gone; never a location lapse or one already ended")
        XCTAssertEqual(CheckInAlerts.lapsesNoLongerJudged(open, judged: judged, ownRules: own, requests: nil).map(\.ruleId),
                       ["mine-off"], "with the requests unread, one that isn't ours may still be a request")
        XCTAssertEqual(CheckInAlerts.lapsesNoLongerJudged(open, judged: judged, ownRules: nil, requests: requests), [],
                       "before this account's list has come once, nothing can be told")
        let monitor = try String(contentsOf: Self.root.appendingPathComponent("App/Managers/MonitoringManager.swift"),
                                 encoding: .utf8)
        let start = try XCTUnwrap(monitor.range(of: "func evaluateCheckInAlerts(readEveryCircle: Bool) async {"))
        let pass = monitor[start.upperBound...]
        let cleanup = try XCTUnwrap(pass.range(of: "endLapsesNoLongerJudged("))
        let early = try XCTUnwrap(pass.range(of: "guard !own.isEmpty || !requests.isEmpty else { return }"))
        XCTAssertLessThan(cleanup.lowerBound, early.lowerBound, "it runs even when no rule is left to judge")
        XCTAssertTrue(monitor.contains(
            "ownRules: inactivity.hasLoaded ? Set(inactivity.alerts.map { CanonicalId.key($0.id) }) : nil,"))
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - My countdown on a scheduled rule

    private func line(myNewest: Date?, armed: Date? = nil, now: Date, schedule: CheckInSchedule? = nil) -> String {
        plain(CheckInCountdown.scheduledLine(schedule ?? everyDayByNineNY, armedAt: armed ?? armedLastWeek,
                                             myNewest: myNewest, now: now, locale: us,
                                             calendar: Calendar(identifier: .gregorian)))
    }

    func testTheScheduledCountdownLines() {
        let mondayEightPM = utc(2026, 11, 24, 1, 0)
        XCTAssertEqual(line(myNewest: mondayEightPM, now: utc(2026, 11, 24, 20, 0)),
                       "Your circle is alerted at 9:00 PM unless you check in.", "Tuesday 3 PM, nothing yet today")
        XCTAssertEqual(line(myNewest: utc(2026, 11, 24, 15, 0), now: utc(2026, 11, 24, 20, 0)),
                       "Checked in. Next due tomorrow by 9:00 PM.", "checked in at 10 AM for tonight's")
        XCTAssertEqual(line(myNewest: mondayEightPM, now: utc(2026, 11, 25, 3, 0)),
                       "Your circle was alerted at 9:00 PM. Check in to clear it.", "10 PM, missed")
        XCTAssertEqual(line(myNewest: mondayEightPM, armed: utc(2026, 11, 25, 2, 30), now: utc(2026, 11, 25, 3, 0)),
                       "Next due tomorrow by 9:00 PM.", "armed after tonight's: nothing missed, nothing owed yet")
        XCTAssertEqual(line(myNewest: utc(2026, 11, 25, 2, 40), now: utc(2026, 11, 25, 2, 45)),
                       "Checked in. Next due tomorrow by 9:00 PM.", "a late check-in clears the missed one")
        XCTAssertEqual(line(myNewest: utc(2026, 11, 24, 15, 0), armed: utc(2026, 11, 25, 2, 30), now: utc(2026, 11, 25, 3, 0)),
                       "Checked in. Next due tomorrow by 9:00 PM.",
                       "one in the window just past counts for it, on a rule made after its deadline too (as on web and Android)")

        // From 6 PM: at 7 AM, last night's was met and tonight's window opens later.
        let fromSix = schedule(CheckInSchedule.everyDay, due: 21 * 60, from: 18 * 60, "America/New_York")
        XCTAssertEqual(line(myNewest: mondayEightPM, now: utc(2026, 11, 24, 12, 0), schedule: fromSix),
                       "Checked in. Next due today by 9:00 PM.")
        XCTAssertEqual(line(myNewest: utc(2026, 11, 24, 14, 0), now: utc(2026, 11, 24, 23, 30), schedule: fromSix),
                       "Your circle is alerted at 9:00 PM unless you check in.", "one at 9 AM is before tonight's window")

        // Mondays only, armed on a Tuesday: next Monday's is owed, and named.
        let mondays = schedule(1 << 0, due: 21 * 60, "America/New_York")
        XCTAssertEqual(line(myNewest: nil, armed: utc(2026, 11, 24, 15, 0), now: utc(2026, 11, 24, 16, 0), schedule: mondays),
                       "Next due Monday by 9:00 PM.")
        // Armed last week: Monday's was missed, and it isn't today, so its date.
        XCTAssertEqual(line(myNewest: nil, now: utc(2026, 11, 24, 16, 0), schedule: mondays),
                       "Your circle was alerted on Nov 23 at 9:00 PM. Check in to clear it.")
        XCTAssertEqual(line(myNewest: utc(2026, 11, 24, 15, 0), now: utc(2026, 11, 24, 16, 0), schedule: mondays),
                       "Checked in. Next due Monday by 9:00 PM.", "checked in late for it")
    }

    func testDaysAreNamedInTheRulesZone() {
        let ny = TimeZone(identifier: "America/New_York")!
        let now = utc(2026, 11, 25, 3, 0)  // Tuesday 10 PM in New York, Wednesday in UTC
        XCTAssertEqual(CheckInCountdown.dayWord(utc(2026, 11, 25, 4, 0), now: now, in: ny), "today")
        XCTAssertEqual(CheckInCountdown.dayWord(utc(2026, 11, 26, 2, 0), now: now, in: ny), "tomorrow")
        XCTAssertEqual(CheckInCountdown.dayWord(utc(2026, 11, 30, 14, 0), now: now, in: ny), "Monday")
    }

    func testAScheduledRuleAboutMeCountsDownAndTheSheetPicksTheSoonest() throws {
        let scheduled = try rule("r-s", aboutMe: true, scheduled: true)
        let once = try rule("r-o", aboutMe: true, scheduled: false, timeoutHours: 6)
        let mine = CheckInCountdown.MyCheckIns(newest: nil, sinceDay: 0)
        let now = utc(2026, 11, 24, 20, 0)
        guard case .scheduled(let s, _, _)? = CheckInCountdown.countdown(of: scheduled, mine: mine, now: now) else {
            return XCTFail("a scheduled countdown")
        }
        XCTAssertEqual(s.dueMinute, 21 * 60)
        XCTAssertEqual(CheckInCountdown.alertAt(.scheduled(s, armedAt: armedLastWeek, myNewest: utc(2026, 11, 24, 1, 0)),
                                                now: now), tuesdayDue, "tonight's")
        XCTAssertEqual(CheckInCountdown.alertAt(.scheduled(s, armedAt: armedLastWeek, myNewest: utc(2026, 11, 24, 15, 0)),
                                                now: now), utc(2026, 11, 26, 2, 0), "checked in for tonight's: tomorrow's")
        XCTAssertEqual(CheckInCountdown.alertAt(.scheduled(s, armedAt: armedLastWeek, myNewest: nil),
                                                now: utc(2026, 11, 25, 3, 0)), tuesdayDue, "missed: when it was")
        let shortRead = CheckInCountdown.MyCheckIns(newest: nil, sinceDay: CheckInCountdown.dayBucket(now))
        XCTAssertNil(CheckInCountdown.countdown(of: scheduled, mine: shortRead, now: now),
                     "a read that didn't reach back to the latest window")
        // The once rule armed last week with no check-in is long overdue: it is the soonest (it came).
        let soonest = CheckInCountdown.soonest(circleId: circle, alerts: [scheduled, once],
                                               mine: [CanonicalId.key(circle): mine], now: now)
        guard case .once? = soonest else { return XCTFail("the overdue one-time rule: \(String(describing: soonest))") }
        // A check-in since its arming ended it: no countdown, and the scheduled one is left.
        let checkedIn = CheckInCountdown.MyCheckIns(newest: utc(2026, 11, 24, 15, 0), sinceDay: 0)
        XCTAssertNil(CheckInCountdown.countdown(of: once, mine: checkedIn, now: now))
        guard case .scheduled? = CheckInCountdown.soonest(circleId: circle, alerts: [scheduled, once],
                                                         mine: [CanonicalId.key(circle): checkedIn], now: now) else {
            return XCTFail("the scheduled rule")
        }
    }

    // MARK: - Summaries and words

    func testTheSummaries() throws {
        let s = schedule(CheckInSchedule.everyDay, due: 21 * 60, "America/New_York")
        XCTAssertEqual(plain(s.summary(followsPhone: true, locale: us)), "Check in by 9:00 PM, every day (phone's time zone)")
        XCTAssertEqual(plain(s.summary(followsPhone: false, locale: us)), "Check in by 9:00 PM, every day (New York)")
        XCTAssertEqual(CheckInSchedule.daysText(CheckInSchedule.weekdays), "weekdays")
        XCTAssertEqual(CheckInSchedule.daysText(CheckInSchedule.weekends), "weekends")
        XCTAssertEqual(CheckInSchedule.daysText(0b001_0101), "Mon, Wed, Fri")
        XCTAssertEqual(CheckInSchedule.daysText(1 << 6), "Sun")
        XCTAssertEqual(CheckInSchedule.zoneName("America/Argentina/Buenos_Aires"), "Buenos Aires")
        XCTAssertEqual(CheckInSchedule.zoneName("UTC"), "UTC")
        XCTAssertEqual(plain(CheckInSchedule.timeText(minute: 7 * 60 + 5, locale: us)), "7:05 AM")
        XCTAssertEqual(CheckInSchedule.timeText(minute: 21 * 60, locale: Locale(identifier: "en_GB")), "21:00",
                       "in this phone's own format")
        XCTAssertEqual(CheckInAlerts.summary(of: try rule("r-o", scheduled: false, timeoutHours: 6)), "Check in within 6 hours")
        XCTAssertEqual(plain(CheckInAlerts.summary(of: try rule("r-s", scheduled: true), locale: us)),
                       "Check in by 9:00 PM, every day (New York)")
        XCTAssertEqual(CheckInAlerts.summary(of: try rule("r-x", scheduled: true, zone: "Mars/Olympus")), "By a time of day",
                       "a schedule this phone can't read is named by its kind")
    }

    func testTheMissedWordsByKind() {
        XCTAssertEqual(plain(CheckInAlerts.missedByBody(name: "Ana", dueMinute: 21 * 60, locale: us)),
                       "Ana hasn't checked in by 9:00 PM.")
        XCTAssertEqual(CheckInAlerts.missedBody(name: "Ana", hours: 6, dueMinute: nil), "Ana hasn't checked in for 6 hours.")
        var event = lapse("r1")
        event.dueMinute = 21 * 60
        XCTAssertTrue(plain(CheckInAlerts.historyLine(event)).hasPrefix("Ana hasn't checked in by "))
        XCTAssertTrue(plain(NotificationsManager.localRow(event).body ?? "").hasPrefix("Ana hasn't checked in by "))
        XCTAssertEqual(NotificationsManager.localRow(event).title, "Missed check-in")
    }

    // MARK: - The wire

    private func rule(_ id: String, aboutMe: Bool = false, active: Bool = true, scheduled: Bool,
                      timeoutHours: Int = 1, zone: String = "America/New_York", follows: Bool = false,
                      mode: String? = nil) throws -> InactivityAlertResponse {
        var json = "{\"id\":\"\(id)\",\"user_id\":\"\(me)\",\"circle_id\":\"\(circle)\","
            + "\"encrypted_target_user_id\":{\"nonce\":\"nn\",\"ciphertext\":\"cc\"},\"timeout_hours\":\(timeoutHours),"
            + "\"is_self_alert\":\(aboutMe),\"notify_push\":true,\"notify_email\":false,\"cooldown_minutes\":60,"
            + "\"is_active\":\(active),\"day_bucket\":20800,\"watches\":\"check_in\",\"armed_at\":\"2026-11-17T12:00:00Z\""
        if scheduled {
            json += ",\"check_in_mode\":\"scheduled\",\"schedule_days\":127,\"schedule_due_minute\":1260,"
                + "\"schedule_from_minute\":null,\"schedule_tz\":\"\(zone)\",\"schedule_tz_follows_phone\":\(follows)"
        } else if let mode {
            json += ",\"check_in_mode\":\"\(mode)\""
        }
        return try APIService.makeWireDecoder().decode(InactivityAlertResponse.self, from: Data((json + "}").utf8))
    }

    func testRowsDecodeTheirKindAndSchedule() throws {
        let scheduled = try rule("r-s", aboutMe: true, scheduled: true, follows: true)
        XCTAssertEqual(scheduled.checkInKind, .scheduled)
        XCTAssertEqual(scheduled.schedule?.days, 127)
        XCTAssertEqual(scheduled.schedule?.dueMinute, 21 * 60)
        XCTAssertNil(scheduled.schedule?.fromMinute)
        XCTAssertEqual(scheduled.schedule?.timeZone.identifier, "America/New_York")
        XCTAssertEqual(scheduled.scheduleTzFollowsPhone, true)
        XCTAssertEqual(try rule("r-o", scheduled: false, mode: "once").checkInKind, .once)
        XCTAssertEqual(try rule("r-old", scheduled: false).checkInKind, .once, "no mode written: one-time")
        XCTAssertNil(try rule("r-new", scheduled: false, mode: "monthly").checkInKind, "a kind this version doesn't know")
        XCTAssertNil(try rule("r-mars", scheduled: true, zone: "Mars/Olympus").schedule)

        let requests: [CircleSelfAlertResponse] = try APIService.decodeResponseBody(Data(#"""
        {"success":true,"data":[{"id":"q1","user_id":"a0000000-0000-4000-8000-000000000002",
          "circle_id":"3f7a1b2c-0000-4000-8000-0123456789ab","timeout_hours":1,"notify_on_return":false,
          "watches":"check_in","armed_at":"2026-11-17T12:00:00Z","check_in_mode":"scheduled","schedule_days":31,
          "schedule_due_minute":540,"schedule_from_minute":480,"schedule_tz":"Europe/Berlin"}]}
        """#.utf8))
        XCTAssertEqual(requests.first?.schedule?.days, CheckInSchedule.weekdays)
        XCTAssertEqual(requests.first?.schedule?.fromMinute, 480)
    }

    private func json(_ body: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: APIService.encodeRequestBody(body)) as? [String: Any])
    }

    func testCreatesAndChangesSayTheKindAndTheSchedule() throws {
        var create = CreateInactivityAlertRequest(
            circleId: circle, targetUserId: me, encryptedTargetUserId: EncryptedBlobRequest(nonce: "nn", ciphertext: "cc"),
            timeoutMinutes: 60, isSelfAlert: true, notifyPush: true, notifyEmail: false, cooldownMinutes: 60,
            encryptedConditions: nil, clientOnly: false, targetUserPseudonym: "ps", dayBucket: 20800, notifyOnReturn: false)
        create.watches = "check_in"
        create.checkInMode = "scheduled"
        create.scheduleDays = 127
        create.scheduleDueMinute = 1260
        create.scheduleTz = "America/New_York"
        create.scheduleTzFollowsPhone = true
        let made = try json(create)
        XCTAssertEqual(made["check_in_mode"] as? String, "scheduled")
        XCTAssertEqual(made["schedule_days"] as? Int, 127)
        XCTAssertEqual(made["schedule_due_minute"] as? Int, 1260)
        XCTAssertEqual(made["schedule_tz"] as? String, "America/New_York")
        XCTAssertEqual(made["schedule_tz_follows_phone"] as? Bool, true)
        XCTAssertNil(made["schedule_from_minute"], "left out: from the start of the day")

        var change = UpdateInactivityAlertRequest(timeoutMinutes: nil, isActive: true, notifyPush: true, notifyEmail: false,
                                                  cooldownMinutes: nil, encryptedConditions: nil, notifyOnReturn: nil)
        change.scheduleFromMinute = .startOfDay
        XCTAssertTrue(try json(change)["schedule_from_minute"] is NSNull, "back to the start of the day: an explicit null")
        change.scheduleFromMinute = .minute(360)
        XCTAssertEqual(try json(change)["schedule_from_minute"] as? Int, 360)

        var follow = UpdateInactivityAlertRequest(timeoutMinutes: nil, isActive: nil, notifyPush: nil, notifyEmail: nil,
                                                  cooldownMinutes: nil, encryptedConditions: nil, notifyOnReturn: nil)
        follow.scheduleTz = "Europe/London"
        XCTAssertEqual(try json(follow) as NSDictionary, ["schedule_tz": "Europe/London"] as NSDictionary,
                       "a follow-the-phone update sends only the zone")

        let manager = try String(contentsOf: Self.root.appendingPathComponent("App/Managers/InactivityAlertsManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(manager.contains("request.checkInMode = (schedule == nil ? CheckInRuleKind.once : .scheduled).rawValue"))
        XCTAssertTrue(manager.contains("request.scheduleTzFollowsPhone = schedule.map { $0.followsPhone && isSelfAlert }"),
                      "only a rule about me follows the phone")
        XCTAssertTrue(manager.contains("let timeoutMinutes = schedule == nil ? timeoutMinutes : 60"))
        XCTAssertTrue(manager.contains("let cooldownMinutes = schedule == nil ? cooldownMinutes : 60"),
                      "no cooldown on a scheduled rule, whatever the hidden slider says")
        XCTAssertTrue(APIService.inactivityAlertsPath(limit: 100).contains("&check_in_modes=once,scheduled&"))
        XCTAssertTrue(APIService.circleSelfAlertsPath.hasSuffix("&check_in_modes=once,scheduled"))
    }

    // MARK: - Following the phone

    func testOnlyMyRulesThatFollowThePhoneAndAreElsewhereMove() throws {
        let alerts = [
            try rule("move", aboutMe: true, scheduled: true, zone: "America/New_York", follows: true),
            try rule("move-off", aboutMe: true, active: false, scheduled: true, zone: "Asia/Tokyo", follows: true),
            try rule("here", aboutMe: true, scheduled: true, zone: "Europe/London", follows: true),
            try rule("chosen", aboutMe: true, scheduled: true, zone: "America/New_York", follows: false),
            try rule("theirs", aboutMe: false, scheduled: true, zone: "America/New_York", follows: true),
            try rule("once", aboutMe: true, scheduled: false),
        ]
        XCTAssertEqual(InactivityAlertsManager.rulesToMove(alerts, to: "Europe/London").map(\.id), ["move", "move-off"])
        let monitor = try String(contentsOf: Self.root.appendingPathComponent("App/Managers/MonitoringManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(monitor.contains("""
                invalidateRuleLists()
                Task { await InactivityAlertsManager.shared.followPhoneTimeZone() }
        """), "on coming to the foreground")
        XCTAssertTrue(monitor.contains("forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main"),
                      "when the phone's zone changes")
        XCTAssertTrue(monitor.contains("""
                    await InactivityAlertsManager.shared.followPhoneTimeZone()
                    await refreshAndEvaluate()
        """), "and on start")
    }

    // MARK: - The editor, as VoiceOver reads it

    // SwiftUI builds its accessibility tree only while an assistive technology
    // is on (the switch RuleEmailSwitchTests borrows). Labels and values both.
    private func spoken(_ view: some View) throws -> [String] {
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 2200))
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
        if object.isAccessibilityElement {
            for text in [object.accessibilityLabel, object.accessibilityValue] {
                if let text, !text.isEmpty { found.append(text) }
            }
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

    func testTheScheduledEditorAsVoiceOverReadsIt() throws {
        let mine = try rule("r-s", aboutMe: true, scheduled: true, follows: true)
        let aboutMe = try spoken(NavigationStack { AlertEditorView(mode: .editInactivity(mine)) })
        for label in ["Check in by", "Monday", "Sunday", CheckInAlerts.phoneTimeZone] {
            XCTAssertTrue(aboutMe.contains(label), "\(label) in \(aboutMe)")
        }
        XCTAssertTrue(aboutMe.contains("Counting from, Start of day"), "the picker with its choice: \(aboutMe)")
        XCTAssertTrue(aboutMe.contains(CheckInAlerts.helperAboutMe), "what it does, and no end: \(aboutMe)")
        XCTAssertFalse(aboutMe.contains("Cooldown"), "a scheduled rule wakes once per occurrence: \(aboutMe)")
        XCTAssertFalse(aboutMe.contains("Check in within"), "\(aboutMe)")

        let other = try rule("r-t", aboutMe: false, scheduled: true, zone: "America/New_York")
        let theirs = try spoken(NavigationStack { AlertEditorView(mode: .editInactivity(other)) })
        XCTAssertTrue(theirs.contains("Time zone, New York"), "their zone, by name: \(theirs)")
        XCTAssertTrue(theirs.contains(CheckInAlerts.helperWatchingOthers), "\(theirs)")
        XCTAssertFalse(theirs.contains(CheckInAlerts.phoneTimeZone), "only a rule about me follows the phone")

        let create = try spoken(NavigationStack { AlertEditorView(mode: .createCheckIn) })
        for label in [CheckInAlerts.onceKindName, CheckInAlerts.scheduledKindName, "Check in within",
                      CheckInAlerts.editorNote(aboutMe: false, kind: .once)] {
            XCTAssertTrue(create.contains(label), "\(label) in \(create)")
        }
    }

    // MARK: - The editor

    func testTheEditorKeepsAScheduleItCanSave() {
        XCTAssertTrue(AlertEditorView.scheduleIsValid(.init(days: 127, dueMinute: 1260, fromMinute: nil,
                                                            timeZone: "UTC", followsPhone: false)))
        XCTAssertFalse(AlertEditorView.scheduleIsValid(.init(days: 0, dueMinute: 1260, fromMinute: nil,
                                                             timeZone: "UTC", followsPhone: false)), "no day")
        XCTAssertFalse(AlertEditorView.scheduleIsValid(.init(days: 1, dueMinute: 600, fromMinute: 600,
                                                             timeZone: "UTC", followsPhone: false)), "from at the deadline")
        XCTAssertEqual(AlertEditorView.minute(of: AlertEditorView.time(minute: 21 * 60 + 15)), 21 * 60 + 15)
        XCTAssertEqual(TimeZonePickerView.zones(matching: "", phone: "Europe/London").first, "Europe/London",
                       "this phone's zone first")
        XCTAssertTrue(TimeZonePickerView.zones(matching: "new york").contains("America/New_York"), "found by city")
    }
}
