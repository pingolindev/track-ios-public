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

/// Check-in rules: an inactivity alert rule that watches check-ins (the Check
/// in button: I'm OK, arrived) instead of location updates (`watches`
/// "check_in", migration 196), of two kinds (migration 197). A one-time rule
/// goes off when its member hasn't checked in within its timeout (1 to 24
/// hours) of its arming, and ends at their first check-in after it. A
/// scheduled one goes off when they haven't checked in by a time of day on
/// its days (`CheckInSchedule`).
///
/// The server holds every check-in time in plaintext and wakes the watchers'
/// devices (`alerts_check`) once one is overdue, but it decides nothing: a
/// device decides from the check-ins it opens. The decisions are here, pure,
/// so they are tested without a network, a circle key or a live actor;
/// `MonitoringManager.evaluateCheckInAlerts` gathers what they need and acts on
/// what comes back. The Android app judges the same rules the same way.
enum CheckInAlerts {

    // MARK: - Words

    /// The rule type's name, in the type chooser and the list.
    static let typeName = "Check-in"
    /// A firing's title, on the notification and the bell row.
    static let missedTitle = "Missed check-in"
    /// The type a firing is reported under for the account's other devices
    /// (`MonitoringManager.reportAlertEvent`).
    static let alertEventType = "missed_check_in"
    /// The editor's note on a rule about someone else, of either kind.
    static let helperWatchingOthers = "Get notified when this person doesn't check in on time."
    /// The editor's note on "Alert about me", of either kind.
    static let helperAboutMe = "Your circle is notified if you don't check in on time."
    /// A rule about me in the list, as "If I'm inactive" is for location.
    static let aboutMeTitle = "If I don't check in"
    /// The two kinds, in the editor.
    static let onceKindName = "Within a time"
    static let scheduledKindName = "By a time of day"
    /// A one-time rule's editor note: it ends at the next check-in.
    static let endsWhenYouCheckIn = "Ends when you check in."
    static let endsWhenTheyCheckIn = "Ends when they check in."
    /// A scheduled rule's zone when it follows the phone.
    static let phoneTimeZone = "Phone's time zone"

    /// The editor's note under a check-in rule's first setting: what the rule
    /// does, and on a one-time rule (under its hours) that it ends at the
    /// check-in.
    static func editorNote(aboutMe: Bool, kind: CheckInRuleKind) -> String {
        let helper = aboutMe ? helperAboutMe : helperWatchingOthers
        guard kind == .once else { return helper }
        return helper + " " + (aboutMe ? endsWhenYouCheckIn : endsWhenTheyCheckIn)
    }

    /// The notification's body, and the bell's and the history's row while
    /// the lapse is open. `hours` is the rule's timeout.
    static func missedBody(name: String, hours: Int) -> String {
        hours == 1
            ? "\(name) hasn't checked in for 1 hour."
            : "\(name) hasn't checked in for \(hours) hours."
    }

    /// A scheduled rule's: its own time as configured, in this phone's time
    /// format ("{name} hasn't checked in by 9:00 PM.").
    static func missedByBody(name: String, dueMinute: Int, locale: Locale = .autoupdatingCurrent) -> String {
        "\(name) hasn't checked in by \(CheckInSchedule.timeText(minute: dueMinute, locale: locale))."
    }

    /// A missed check-in's words, by the rule's kind: a scheduled one carries
    /// its due minute, a one-time one its hours.
    static func missedBody(name: String, hours: Int, dueMinute: Int?) -> String {
        dueMinute.map { missedByBody(name: name, dueMinute: $0) } ?? missedBody(name: name, hours: hours)
    }

    /// A one-time rule's line in the list (a scheduled one's is
    /// `CheckInSchedule.summary`).
    static func summary(hours: Int) -> String {
        hours == 1 ? "Check in within 1 hour" : "Check in within \(hours) hours"
    }

    /// A check-in rule's line in the list, by its kind. A scheduled rule whose
    /// schedule this phone can't read is named by its kind alone.
    static func summary(of rule: InactivityAlertResponse, locale: Locale = .autoupdatingCurrent) -> String {
        if let schedule = rule.schedule {
            return schedule.summary(followsPhone: rule.scheduleTzFollowsPhone == true, locale: locale)
        }
        return rule.checkInKind == .scheduled ? scheduledKindName : summary(hours: rule.timeoutHours)
    }

    /// The history's row for a missed check-in: its words stay once it has
    /// ended (marked `endedMark`), since the check-in that ended it is a row
    /// of its own there (`CheckInHistory`).
    static func historyLine(_ event: LocalInactivityEvent) -> String {
        missedBody(name: event.memberName, hours: event.timeoutHours ?? 1, dueMinute: event.dueMinute)
    }

    /// The open missed check-ins whose rule this device no longer judges: it
    /// ended (a one-time rule ends at the check-in), was turned off or
    /// deleted, or the circle-mate's request is gone. Each is ended and its
    /// notification taken back. Ids in their one forms: `judged`, the rules
    /// judged now; `ownRules`, every rule of this account's (nil until its list
    /// has come once); `requests`, the circle-mates' (nil when they couldn't be
    /// read). A lapse it can't place, it leaves open.
    static func lapsesNoLongerJudged(_ open: [LocalInactivityEvent], judged: Set<String>, ownRules: Set<String>?,
                                     requests: Set<String>?) -> [LocalInactivityEvent] {
        open.filter { event in
            let rule = CanonicalId.key(event.ruleId)
            guard event.isMissedCheckIn, !event.isResolved, !judged.contains(rule), let ownRules else { return false }
            if ownRules.contains(rule) { return true }
            return requests.map { !$0.contains(rule) } ?? false
        }
    }

    /// What marks a missed check-in in the history once it has ended.
    static let endedMark = "Ended"

    /// A missed check-in that is over without a check-in known to have ended
    /// it: its rule was turned back on, or is no longer judged here
    /// (`lapsesNoLongerJudged`). The history shows it closed, not as good news.
    static func closedWithoutCheckIn(_ event: LocalInactivityEvent) -> Bool {
        event.isMissedCheckIn && event.isResolved && event.endedByCheckIn != true
    }

    // MARK: - Reading a circle's check-ins

    /// Rows asked for a page, and the most pages one read walks.
    static let pageSize = 100
    static let maxPages = 5

    /// A read that met a check-in inside its window that didn't open here
    /// (`CheckInManager.openPage`). It fails, as a page that didn't come does.
    struct UnopenedCheckIn: Error {}

    /// The oldest day a read reaches back to: floor((now - 26 h) / 1 day), a
    /// day plus slack past the longest timeout (24 h).
    static func readFloorDayBucket(now: Date) -> Int {
        Int(((now.timeIntervalSince1970 - 26 * 3600) / 86_400).rounded(.down))
    }

    /// The same, reaching back to `from` when that is earlier: a scheduled
    /// rule's window can start more than a day back (a weekly pattern).
    static func readFloorDayBucket(now: Date, from: Date?) -> Int {
        min(readFloorDayBucket(now: now), from.map(CheckInCountdown.dayBucket) ?? .max)
    }

    /// Where a circle's read must reach back to for its rules: each scheduled
    /// rule's latest window start (nil when none is scheduled).
    static func readFrom(_ rules: [Rule], now: Date) -> Date? {
        rules.compactMap { $0.schedule?.latest(atOrBefore: now)?.windowStart }.min()
    }

    /// Whether a read goes on past this page: only past a full page whose days
    /// are all inside the window. Pages come newest first (day_bucket, then id,
    /// both descending), so a short page is the last there is.
    static func readsOn(pageDayBuckets: [Int], floor: Int) -> Bool {
        guard pageDayBuckets.count >= pageSize, let smallest = pageDayBuckets.min() else { return false }
        return smallest >= floor
    }

    /// Fold opened check-ins into each member's newest, by the member's id in
    /// its one form. A check-in counts whatever key version it opened under: one
    /// made before the circle moved to a new key is still that person's latest.
    /// Left out: a row whose sender didn't open (no one to credit it to; inside
    /// the window one has already failed the read, `CheckInManager.openPage`),
    /// and one dated further ahead than any clock may be (`maxFutureSkewMs`,
    /// the bound a location is held to), which would otherwise keep a rule
    /// quiet until that date.
    static func merge(_ checkIns: [CheckIn], into newest: inout [String: Date], now: Date) {
        let latestBelievable = now.addingTimeInterval(TimeInterval(CircleManager.maxFutureSkewMs) / 1000)
        for checkIn in checkIns where !checkIn.userId.isEmpty && checkIn.timestamp <= latestBelievable {
            let key = CanonicalId.key(checkIn.userId)
            if let held = newest[key], held >= checkIn.timestamp { continue }
            newest[key] = checkIn.timestamp
        }
    }

    // MARK: - Judging

    /// One rule to judge, from either source: this account's own rule about
    /// others, or a circle-mate's request to be watched.
    struct Rule: Equatable {
        let id: String
        let circleId: String
        let timeoutHours: Int
        /// Where the clock starts for a member with no check-in since: the
        /// server's `armed_at` (made, or last turned back on), or when this
        /// device first stored the rule when there is none.
        let armedAt: Date
        /// Whom it watches.
        let memberIds: [String]
        /// A circle-mate's own request: asking is their consent, as the server
        /// has it, so "Allow alerts on me" off doesn't silence it.
        let isTheirRequest: Bool
        /// A scheduled rule's schedule (`decideScheduled`); nil for a one-time
        /// rule, judged by `timeoutHours` (`decide`).
        var schedule: CheckInSchedule? = nil
    }

    enum Action: Equatable {
        /// The lapse is over: end it and take back its notification.
        /// `checkedIn`: a check-in after it began ended it; false when only the
        /// rule did (armed again, or a scheduled rule's newer occurrence took
        /// over). No "back" notice either way: a check-in told the circle itself.
        case resolve(ruleId: String, userId: String, checkedIn: Bool)
        /// Raise it once: notification, local event, bell row, alert event.
        /// `dueMinute`: a scheduled rule's deadline, for its words.
        case raise(ruleId: String, userId: String, name: String, since: Date, timeoutHours: Int, dueMinute: Int? = nil)

        var raises: Bool {
            if case .raise = self { return true }
            return false
        }
    }

    struct Decision: Equatable {
        /// The open lapse ends.
        var resolves: Bool
        /// ...because they checked in after it began. False when it ended only
        /// because the rule was armed again after it began, or a scheduled
        /// rule's newer occurrence came due.
        var checkedIn: Bool
        /// The lapse's start, when it goes off now.
        var raisesSince: Date?
    }

    /// Whether a check-in rule of this kind can be judged here: a one-time
    /// rule, or a scheduled one whose schedule reads. A kind this version
    /// doesn't know, or a schedule that doesn't read, is judged by nothing,
    /// never as something else.
    static func judgeable(kind: CheckInRuleKind?, schedule: CheckInSchedule?) -> Bool {
        switch kind {
        case .once: return true
        case .scheduled: return schedule != nil
        case nil: return false
        }
    }

    /// An open lapse's key: the rule and the member, in their one forms.
    static func lapseKey(ruleId: String, userId: String) -> String {
        "\(CanonicalId.key(ruleId))|\(CanonicalId.key(userId))"
    }

    /// One one-time rule about one member, on a read that succeeded.
    ///
    /// The rule ends at the member's first check-in after its arming (the
    /// server then turns it off): from that check-in on it raises nothing and
    /// its open lapse ends, even before the rule list says it is off. Until
    /// then their silence counts from the arming, and it goes off once the
    /// timeout has passed since, unless a lapse is open. A re-arm (the rule
    /// turned off and back on, which the server arms again) also ends an open
    /// lapse that began before it, and the rule counts again from there.
    /// Without that, a re-armed rule's old lapse would never end and the rule
    /// could never go off again. A lapse still open blocks a second alert.
    static func decide(last: Date?, armedAt: Date, timeoutHours: Int, openSince: Date?, now: Date) -> Decision {
        let ended = last.map { $0 > armedAt } ?? false
        var decision = Decision(resolves: false, checkedIn: false, raisesSince: nil)
        var open = openSince
        if let started = open, ended || armedAt > started {
            decision.resolves = true
            decision.checkedIn = last.map { $0 > started } ?? false
            open = nil
        }
        let overdue = now.timeIntervalSince(armedAt) > TimeInterval(timeoutHours) * 3600
        if !ended && overdue && open == nil {
            decision.raisesSince = armedAt
        }
        return decision
    }

    /// One scheduled rule about one member, on a read that stood. D is the
    /// latest due instant at or before now, W its window start
    /// (`CheckInSchedule.latest`), `last` their newest check-in.
    ///
    /// An open lapse (start S) ends when they checked in after it began, or
    /// when a newer occurrence has come due (D > S). It goes off, with D as
    /// its start, when the rule was armed before D, they haven't checked in
    /// since W, and no lapse is open after that. So one occurrence raises once,
    /// and a missed one gives way to the next.
    static func decideScheduled(last: Date?, armedAt: Date, schedule: CheckInSchedule, openSince: Date?,
                                now: Date) -> Decision {
        var decision = Decision(resolves: false, checkedIn: false, raisesSince: nil)
        let occurrence = schedule.latest(atOrBefore: now)
        var open = openSince
        if let started = open {
            let checkedIn = last.map { $0 > started } ?? false
            if checkedIn || (occurrence.map { $0.due > started } ?? false) {
                decision.resolves = true
                decision.checkedIn = checkedIn
                open = nil
            }
        }
        if let occurrence, open == nil, armedAt < occurrence.due,
           !(last.map { $0 >= occurrence.windowStart } ?? false) {
            decision.raisesSince = occurrence.due
        }
        return decision
    }

    /// The members a rule judges: in the circle's roster, never this account
    /// itself, and never someone who turned "Allow alerts on me" off here (when
    /// this device knows it; unknown permits, as at every consent gate) unless
    /// the rule is their own request. Being paused, or having real-time sharing
    /// off, changes nothing: a check-in goes out without a position.
    static func judged(_ rule: Rule, members: [CircleMember], consent: [String: Bool],
                       selfId: String?) -> [CircleMember] {
        var seen = Set<String>()
        var judged: [CircleMember] = []
        for memberId in rule.memberIds {
            let key = CanonicalId.key(memberId)
            if let selfId, key == CanonicalId.key(selfId) { continue }
            guard seen.insert(key).inserted,
                  let member = members.first(where: { CanonicalId.key($0.userId) == key }) else { continue }
            if !rule.isTheirRequest, consent[key] == false { continue }
            judged.append(member)
        }
        return judged
    }

    /// Every rule of one circle on one read of its check-ins. `newest` nil is
    /// a read that failed: nobody is judged, since a failed read is not "no
    /// check-in". `openLapses`: this device's open lapses, by `lapseKey`, to
    /// their starts.
    static func judge(rules: [Rule], members: [CircleMember], consent: [String: Bool], selfId: String?,
                      newest: [String: Date]?, openLapses: [String: Date], now: Date) -> [Action] {
        guard let newest else { return [] }
        var actions: [Action] = []
        for rule in rules {
            for member in judged(rule, members: members, consent: consent, selfId: selfId) {
                let last = newest[CanonicalId.key(member.userId)]
                let openSince = openLapses[lapseKey(ruleId: rule.id, userId: member.userId)]
                let decision = rule.schedule.map {
                    decideScheduled(last: last, armedAt: rule.armedAt, schedule: $0, openSince: openSince, now: now)
                } ?? decide(last: last, armedAt: rule.armedAt, timeoutHours: rule.timeoutHours,
                            openSince: openSince, now: now)
                if decision.resolves {
                    actions.append(.resolve(ruleId: rule.id, userId: member.userId, checkedIn: decision.checkedIn))
                }
                if let since = decision.raisesSince {
                    actions.append(.raise(ruleId: rule.id, userId: member.userId, name: member.displayName,
                                          since: since, timeoutHours: rule.timeoutHours,
                                          dueMinute: rule.schedule?.dueMinute))
                }
            }
        }
        return actions
    }

    /// What one pass does in one circle. `fresh`: this pass's read, nil when it
    /// didn't read or its read failed. `held`: the last read that stood.
    ///
    /// On a read that stood, everything is judged on it. Without one, only the
    /// lapses that the current rules and the held read already end are ended:
    /// a rule armed again (its new `armed_at` is in the rule list), or a
    /// check-in already held. Nothing is raised: an alert needs a read that
    /// stood in the same pass. So a lapse never waits for a read to end, which
    /// matters while a circle's reads fail (a check-in that doesn't open fails
    /// them for up to a day). The Android app ends lapses the same way.
    static func passActions(rules: [Rule], members: [CircleMember], consent: [String: Bool], selfId: String?,
                            fresh: [String: Date]?, held: [String: Date]?, openLapses: [String: Date],
                            now: Date) -> [Action] {
        if let fresh {
            return judge(rules: rules, members: members, consent: consent, selfId: selfId,
                         newest: fresh, openLapses: openLapses, now: now)
        }
        return judge(rules: rules, members: members, consent: consent, selfId: selfId,
                     newest: held ?? [:], openLapses: openLapses, now: now)
            .filter { !$0.raises }
    }

    // MARK: - When a background pass reads

    /// A circle's check-ins as a pass last read them.
    struct Read: Equatable {
        let at: Date
        /// Each member's newest check-in, by their id in its one form.
        let newest: [String: Date]
    }

    /// How often a background pass reads a circle while one of its lapses is
    /// open: enough to take back a stale alert, when the wake that follows a
    /// check-in was lost.
    static let openLapseReadInterval: TimeInterval = 30 * 60

    /// Whether a background pass (the timer, a location wake) reads a circle's
    /// check-ins. The `alerts_check` wake always reads, without asking this.
    ///
    /// It judges from its last read first (none: no check-in known) and reads
    /// when that would raise an alert, or, while a lapse is open, when the last
    /// read is half an hour old (a check-in only a read can show may end it).
    /// An alert it raises then stands on the new read (the caller judges again
    /// on it), never on the old one. Ending a lapse needs no read
    /// (`passActions`). A circle with nothing about to go off costs no request,
    /// which is every circle almost all the time.
    static func backgroundPassReads(rules: [Rule], members: [CircleMember], consent: [String: Bool],
                                    selfId: String?, last: Read?, openLapses: [String: Date],
                                    now: Date) -> Bool {
        let fromLastRead = judge(rules: rules, members: members, consent: consent, selfId: selfId,
                                 newest: last?.newest ?? [:], openLapses: openLapses, now: now)
        if fromLastRead.contains(where: \.raises) {
            return true
        }
        let anyOpen = rules.contains { rule in
            judged(rule, members: members, consent: consent, selfId: selfId).contains {
                openLapses[lapseKey(ruleId: rule.id, userId: $0.userId)] != nil
            }
        }
        guard anyOpen else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last.at) >= openLapseReadInterval
    }
}
