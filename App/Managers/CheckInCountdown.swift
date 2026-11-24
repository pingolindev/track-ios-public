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

import Foundation

/// The countdown on this account's own check-in rules ("Alert about me" on a
/// check-in rule): how long until its circle is alerted, or when it was.
///
/// It goes by what the circle's phones go by (`CheckInAlerts.decide` and
/// `decideScheduled`, and the server's wake): the rule's arming and this
/// account's newest check-in that the server has. A one-time rule counts from
/// its arming and ends at my first check-in after it, so then it shows
/// nothing; a scheduled one follows its occurrences (`scheduledLine`). A
/// check-in still waiting on this phone is not on the server: the circle can't
/// see it and would still be alerted, so it moves nothing here. Location rules
/// about oneself get no countdown: their clock restarts with every location
/// the phone sends, so it would sit at the full timeout.
enum CheckInCountdown {

    // MARK: - Words

    /// The time left: "3 h 12 min", "3 h" on the hour, "45 min", "less than a
    /// minute". Whole minutes, rounded down, so it never shows more time than
    /// is left.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded(.down))
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// A one-time rule's line, as of `now`. At or after the deadline it says
    /// when the circle was alerted (`alertedLine`).
    static func line(deadline: Date, now: Date, locale: Locale = .autoupdatingCurrent,
                     calendar: Calendar = .autoupdatingCurrent,
                     timeZone: TimeZone = .autoupdatingCurrent) -> String {
        if now < deadline {
            return "Your circle is alerted in \(duration(deadline.timeIntervalSince(now)))"
        }
        var inZone = calendar
        inZone.timeZone = timeZone
        let time = deadline.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: inZone, timeZone: timeZone))
        return alertedLine(at: deadline, time: time, now: now, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    /// When the circle was alerted: "at {time}" when `instant` is today, "on
    /// {date} at {time}" on another day, as `timeZone` tells days apart. `time`
    /// is the time as the caller words it.
    static func alertedLine(at instant: Date, time: String, now: Date, locale: Locale,
                            calendar: Calendar, timeZone: TimeZone) -> String {
        var inZone = calendar
        inZone.timeZone = timeZone
        if inZone.isDate(instant, inSameDayAs: now) {
            return "Your circle was alerted at \(time). Check in to clear it."
        }
        // Date and time formatted apart, so the words around them are ours.
        let day = instant.formatted(
            Date.FormatStyle(locale: locale, calendar: inZone, timeZone: timeZone).month(.abbreviated).day())
        return "Your circle was alerted on \(day) at \(time). Check in to clear it."
    }

    // MARK: - The deadline

    /// When a one-time rule's circle is alerted: its arming plus its timeout.
    /// Nil once it has ended: the server has a check-in of mine newer than the
    /// arming (it then turns the rule off; this knows before that comes back).
    static func deadline(myNewest: Date?, armedAt: Date, timeoutHours: Int) -> Date? {
        if let myNewest, myNewest > armedAt { return nil }
        return armedAt.addingTimeInterval(TimeInterval(timeoutHours) * 3600)
    }

    /// A day bucket, as check-ins carry one: whole days since the epoch.
    static func dayBucket(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Whether a rule has a countdown: one of this account's own active
    /// check-in rules about itself that this version judges (one-time, or
    /// scheduled with a schedule that reads), whose arming it knows. (The list
    /// holds this account's rules only.)
    static func hasCountdown(_ rule: InactivityAlertResponse) -> Bool {
        rule.isActive && rule.isSelfAlert && rule.armedAtDate != nil
            && CheckInAlerts.judgeable(kind: rule.checkInKind, schedule: rule.schedule)
    }

    static func rules(_ alerts: [InactivityAlertResponse]) -> [InactivityAlertResponse] {
        alerts.filter(hasCountdown)
    }

    /// The first day a rule's countdown needs my check-ins from: its arming
    /// day, or for a scheduled rule its latest occurrence's window, when that
    /// is earlier (an older check-in moves nothing).
    static func sinceDay(of rule: InactivityAlertResponse, now: Date) -> Int? {
        guard let armedAt = rule.armedAtDate else { return nil }
        let window = rule.schedule?.latest(atOrBefore: now)?.windowStart
        return min(dayBucket(armedAt), window.map(dayBucket) ?? .max)
    }

    /// Each circle with a countdown, by its id in its one form, and the first
    /// day its read must reach: the earliest `sinceDay` of its rules.
    static func reads(for alerts: [InactivityAlertResponse], now: Date = Date())
        -> [String: (circleId: String, sinceDay: Int)] {
        var reads: [String: (circleId: String, sinceDay: Int)] = [:]
        for rule in rules(alerts) {
            guard let day = sinceDay(of: rule, now: now) else { continue }
            let key = CanonicalId.key(rule.circleId)
            reads[key] = (rule.circleId, min(reads[key]?.sinceDay ?? day, day))
        }
        return reads
    }

    /// What this phone knows of its account's own check-ins in one circle, as
    /// the server has them.
    struct MyCheckIns: Equatable {
        /// The newest; nil when there is none from `sinceDay` on.
        var newest: Date?
        /// The first day (day bucket) the read reached: a rule armed before it
        /// can't be counted from this.
        var sinceDay: Int

        /// A check-in of this account's that the server accepted: one sent
        /// now, or one that waited and has gone out. A one-time rule's
        /// countdown ends; a scheduled one's moves on.
        mutating func accepted(at time: Date) {
            newest = max(newest ?? time, time)
        }
    }

    /// What one rule's countdown line shows.
    enum Countdown: Equatable {
        /// A one-time rule: when the circle is alerted.
        case once(deadline: Date)
        /// A scheduled one: its schedule, its arming, and my newest check-in
        /// that the server has. The line follows the clock (`scheduledLine`).
        case scheduled(CheckInSchedule, armedAt: Date, myNewest: Date?)
    }

    /// One rule's countdown, when it has one and `mine` can tell it.
    static func countdown(of rule: InactivityAlertResponse, mine: MyCheckIns?, now: Date = Date()) -> Countdown? {
        guard hasCountdown(rule), let armedAt = rule.armedAtDate, let mine,
              let needed = sinceDay(of: rule, now: now), needed >= mine.sinceDay else { return nil }
        if let schedule = rule.schedule {
            return .scheduled(schedule, armedAt: armedAt, myNewest: mine.newest)
        }
        let due = deadline(myNewest: mine.newest, armedAt: armedAt, timeoutHours: rule.timeoutHours)
        return due.map { .once(deadline: $0) }
    }

    /// When a countdown's circle is alerted, or was: a one-time rule's
    /// deadline; a scheduled rule's deadline its line is about.
    static func alertAt(_ countdown: Countdown, now: Date) -> Date? {
        switch countdown {
        case .once(let deadline):
            return deadline
        case .scheduled(let schedule, let armedAt, let myNewest):
            switch scheduledState(schedule, armedAt: armedAt, myNewest: myNewest, now: now) {
            case .missed(let due)?, .pending(let due)?, .next(let due, _)?:
                return due
            case nil:
                return nil
            }
        }
    }

    /// The countdown the check-in screen shows for `circleId`: of that
    /// circle's rules about me, the one whose alert comes soonest (or came).
    static func soonest(circleId: String, alerts: [InactivityAlertResponse], mine: [String: MyCheckIns],
                        now: Date = Date()) -> Countdown? {
        let key = CanonicalId.key(circleId)
        return rules(alerts)
            .filter { CanonicalId.key($0.circleId) == key }
            .compactMap { countdown(of: $0, mine: mine[key], now: now) }
            .min { (alertAt($0, now: now) ?? .distantFuture) < (alertAt($1, now: now) ?? .distantFuture) }
    }

    // MARK: - A scheduled rule's line

    /// Where a scheduled rule about me stands, and which deadline its line
    /// is about. D is its latest occurrence (due at or before now), N its next.
    enum ScheduledState: Equatable {
        /// D came due on a rule armed before it, with no check-in of mine since
        /// its window opened: the circle's phones raised it. This wins, or a
        /// missed day would hide behind the next.
        case missed(due: Date)
        /// N's window is open and no check-in of mine counts for it yet.
        case pending(due: Date)
        /// Otherwise the next deadline nothing counts for yet: the one after N
        /// when a check-in counted for N (its window open), else N.
        /// `checkedIn`: a check-in counted for the occurrence just past or the
        /// open one.
        case next(due: Date, checkedIn: Bool)
    }

    /// Where a scheduled rule about me stands at `now`. A check-in counts for
    /// an occurrence from its window's start on, a late one too (it clears a
    /// missed one). Nil for a schedule with no day ahead, which one that reads
    /// never is.
    static func scheduledState(_ schedule: CheckInSchedule, armedAt: Date, myNewest: Date?,
                               now: Date) -> ScheduledState? {
        func counted(_ occurrence: CheckInSchedule.Occurrence?) -> Bool {
            guard let occurrence, let myNewest else { return false }
            return myNewest >= occurrence.windowStart
        }
        let latest = schedule.latest(atOrBefore: now)
        if let latest, armedAt < latest.due, !counted(latest) {
            return .missed(due: latest.due)
        }
        guard let next = schedule.next(after: now) else { return nil }
        if next.windowStart > now {
            return .next(due: next.due, checkedIn: counted(latest))
        }
        guard counted(next) else { return .pending(due: next.due) }
        return schedule.next(after: next.due).map { ScheduledState.next(due: $0.due, checkedIn: true) }
    }

    /// The line of a scheduled rule about me, as of `now`. Its time is the
    /// rule's own as configured; days and dates are told in its zone.
    /// - missed: "Your circle was alerted at 9:00 PM. Check in to clear it."
    ///   ("on Nov 23 at 9:00 PM" when that wasn't today);
    /// - pending (always today): "Your circle is alerted at 9:00 PM unless you
    ///   check in.";
    /// - next: "Checked in. Next due tomorrow by 9:00 PM." (today, tomorrow or
    ///   the weekday), without "Checked in." when no check-in counted.
    static func scheduledLine(_ schedule: CheckInSchedule, armedAt: Date, myNewest: Date?, now: Date,
                              locale: Locale = .autoupdatingCurrent,
                              calendar: Calendar = .autoupdatingCurrent) -> String {
        let time = CheckInSchedule.timeText(minute: schedule.dueMinute, locale: locale)
        switch scheduledState(schedule, armedAt: armedAt, myNewest: myNewest, now: now) {
        case .missed(let due)?:
            return alertedLine(at: due, time: time, now: now, locale: locale, calendar: calendar,
                               timeZone: schedule.timeZone)
        case .pending?:
            return "Your circle is alerted at \(time) unless you check in."
        case .next(let due, let checkedIn)?:
            let next = "Next due \(dayWord(due, now: now, in: schedule.timeZone)) by \(time)."
            return checkedIn ? "Checked in. " + next : next
        case nil:
            return ""
        }
    }

    /// An occurrence's day, as seen from `now` in the rule's zone: "today",
    /// "tomorrow", or the weekday ("Monday").
    static func dayWord(_ instant: Date, now: Date, in timeZone: TimeZone) -> String {
        let day = CheckInSchedule.localDay(of: instant, in: timeZone)
        let today = CheckInSchedule.localDay(of: now, in: timeZone)
        if day == today { return "today" }
        if day == CheckInSchedule.adding(1, to: today) { return "tomorrow" }
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return names[CheckInSchedule.weekdayFromMonday(day)]
    }

    /// A countdown's line, as of `now`.
    static func text(_ countdown: Countdown, now: Date) -> String {
        switch countdown {
        case .once(let deadline):
            return line(deadline: deadline, now: now)
        case .scheduled(let schedule, let armedAt, let myNewest):
            return scheduledLine(schedule, armedAt: armedAt, myNewest: myNewest, now: now)
        }
    }

    // MARK: - The read (`CheckInManager.readMyNewestCheckIn`)

    /// The most pages one read walks back looking for this account's newest.
    static let maxPages = 20

    /// A read that can't tell this account's newest check-in: a row that may
    /// be newer than what it found didn't open, or it ran out of pages first.
    struct CannotTell: Error {}
}
