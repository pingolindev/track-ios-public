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

/// The schedule of a scheduled check-in rule (migration 197): "check in by
/// 9:00 PM on these days, counting from the start of the day or a from time".
///
/// The server, the Android app, the web and this app must agree on its
/// occurrences to the minute, so the rules are exact:
/// - Times are local to the rule's IANA zone. A time that doesn't exist that
///   day (a spring-forward gap) is the wall time read with the offset from
///   before the gap, so 2:30 AM on a spring-forward night is 3:30 AM summer
///   time. One that happens twice (fall-back) is the EARLIER instant.
///   Foundation's own `date(from:)` resolves a repeated time to the later one,
///   so this resolves both cases itself (`instant`).
/// - A day is scheduled when its local weekday's bit is set (bit 0 = Monday
///   ... bit 6 = Sunday).
/// - The latest occurrence is the latest due instant at or before now on a
///   scheduled day (looking back up to 8 days); its window starts at that
///   day's from time, or the start of the day. The next is the earliest due
///   instant after now (looking ahead up to 8 days).
struct CheckInSchedule: Equatable {
    /// Bit 0 = Monday ... bit 6 = Sunday.
    let days: Int
    /// Minutes after local midnight.
    let dueMinute: Int
    /// nil: counting from the start of the day.
    let fromMinute: Int?
    let timeZone: TimeZone

    /// A row's schedule; nil when a field is missing or out of range, or the
    /// zone isn't one this device knows.
    init?(days: Int?, dueMinute: Int?, fromMinute: Int?, timeZone identifier: String?) {
        guard let days, (1...127).contains(days), let dueMinute, (0..<1440).contains(dueMinute),
              let identifier, let timeZone = TimeZone(identifier: identifier) else { return nil }
        if let fromMinute, !(0..<dueMinute).contains(fromMinute) { return nil }
        self.days = days
        self.dueMinute = dueMinute
        self.fromMinute = fromMinute
        self.timeZone = timeZone
    }

    /// The bits for every day, weekdays and weekends.
    static let everyDay = 0b111_1111
    static let weekdays = 0b001_1111
    static let weekends = 0b110_0000

    /// One occurrence: its deadline, and when its check-ins start counting.
    struct Occurrence: Equatable {
        let due: Date
        let windowStart: Date
    }

    /// A calendar day, as the zone's wall clock names it.
    struct LocalDay: Equatable {
        let year: Int
        let month: Int
        let day: Int
    }

    /// The latest occurrence whose deadline is at or before `now`. nil only
    /// when no day in the last nine is scheduled, which a valid mask can't be.
    func latest(atOrBefore now: Date) -> Occurrence? {
        let today = Self.localDay(of: now, in: timeZone)
        for back in 0...8 {
            let day = Self.adding(-back, to: today)
            guard isScheduled(day) else { continue }
            let due = Self.instant(day, minute: dueMinute, in: timeZone)
            if due <= now { return occurrence(on: day, due: due) }
        }
        return nil
    }

    /// The earliest occurrence whose deadline is after `now`.
    func next(after now: Date) -> Occurrence? {
        let today = Self.localDay(of: now, in: timeZone)
        for ahead in 0...8 {
            let day = Self.adding(ahead, to: today)
            guard isScheduled(day) else { continue }
            let due = Self.instant(day, minute: dueMinute, in: timeZone)
            if due > now { return occurrence(on: day, due: due) }
        }
        return nil
    }

    private func occurrence(on day: LocalDay, due: Date) -> Occurrence {
        Occurrence(due: due, windowStart: Self.instant(day, minute: fromMinute ?? 0, in: timeZone))
    }

    /// Whether the zone's weekday of `day` has its bit set.
    func isScheduled(_ day: LocalDay) -> Bool {
        days & (1 << Self.weekdayFromMonday(day)) != 0
    }

    // MARK: - Wall times

    /// Plain day arithmetic, in a calendar with no zone of its own.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func localDay(of instant: Date, in timeZone: TimeZone) -> LocalDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    static func adding(_ days: Int, to day: LocalDay) -> LocalDay {
        let midnight = utcCalendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let moved = utcCalendar.date(byAdding: .day, value: days, to: midnight)!
        let parts = utcCalendar.dateComponents([.year, .month, .day], from: moved)
        return LocalDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// 0 = Monday ... 6 = Sunday.
    static func weekdayFromMonday(_ day: LocalDay) -> Int {
        let midnight = utcCalendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        // Gregorian weekday: 1 = Sunday ... 7 = Saturday.
        return (utcCalendar.component(.weekday, from: midnight) + 5) % 7
    }

    /// `minute` after local midnight on `day` in `timeZone`, as an instant. In
    /// a gap, the wall time read with the offset from before it; when it
    /// happens twice, the earlier.
    static func instant(_ day: LocalDay, minute: Int, in timeZone: TimeZone) -> Date {
        let wall = utcCalendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: minute / 60, minute: minute % 60))!
            .timeIntervalSince1970
        // The offsets around it: a day either side holds any change made that
        // day (a gap or an overlap is at most a few hours anywhere).
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall - 86_400))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: wall + 86_400))
        let valid = Set([before, after]).compactMap { offset -> TimeInterval? in
            let candidate = wall - TimeInterval(offset)
            return timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: candidate)) == offset ? candidate : nil
        }
        if let earliest = valid.min() {
            return Date(timeIntervalSince1970: earliest)
        }
        // A gap: the wall time read with the offset from before it.
        return Date(timeIntervalSince1970: wall - TimeInterval(before))
    }
}

// MARK: - Words

extension CheckInSchedule {
    /// A minute of the day in this phone's time format: "9:00 PM", or "21:00".
    static func timeText(minute: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let utc = TimeZone(identifier: "UTC")!
        let date = utcCalendar.date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                         hour: minute / 60, minute: minute % 60))!
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                               calendar: utcCalendar, timeZone: utc))
    }

    /// The days: "every day", "weekdays", "weekends", or their short names
    /// from Monday on ("Mon, Wed, Fri").
    static func daysText(_ days: Int) -> String {
        switch days {
        case everyDay: return "every day"
        case weekdays: return "weekdays"
        case weekends: return "weekends"
        default:
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return names.indices.filter { days & (1 << $0) != 0 }.map { names[$0] }.joined(separator: ", ")
        }
    }

    /// A zone as a person names it: its city ("America/New_York" is "New York").
    static func zoneName(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// The rule's line in the list: "Check in by 9:00 PM, every day", and its
    /// zone: "(phone's time zone)" when it follows the phone, else its city.
    func summary(followsPhone: Bool, locale: Locale = .autoupdatingCurrent) -> String {
        let zone = followsPhone ? "phone's time zone" : Self.zoneName(timeZone.identifier)
        return "Check in by \(Self.timeText(minute: dueMinute, locale: locale)), \(Self.daysText(days)) (\(zone))"
    }
}

/// A scheduled check-in rule's schedule as chosen in the editor, to create or
/// change one (and to wait with a create while this iPhone is behind).
struct CheckInScheduleChoice: Codable, Equatable {
    /// Bit 0 = Monday ... bit 6 = Sunday.
    var days: Int
    var dueMinute: Int
    /// nil: counting from the start of the day.
    var fromMinute: Int?
    /// IANA zone.
    var timeZone: String
    /// About me only: the zone follows the phone's.
    var followsPhone: Bool
}
