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

/// Mirrors the Android app's NotificationRelativeLabelTest. The bell
/// label must come from the real timestamp in the device's LOCAL
/// timezone, not the UTC day bucket (whose boundary is UTC midnight —
/// mid-evening for users west of UTC), or something that happened today
/// says "Yesterday".
final class NotificationRelativeLabelTests: XCTestCase {

    private func pdtCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return cal
    }

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // The scenario: an arrival at 20:12 PDT is already 03:12 the NEXT day
    // in UTC. UTC-bucket math would flip it to "Yesterday" once the local
    // clock passes UTC midnight; the local-calendar label keeps it
    // "Today".
    func testEarlierTodayPDTAfterUtcRolloverIsToday() {
        let cal = pdtCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 20, minute: 12))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 22, minute: 0))!
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "Today")
    }

    func testTrueYesterday() {
        let cal = pdtCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 6, day: 13, hour: 23, minute: 0))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 8, minute: 0))!
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "Yesterday")
    }

    func testFutureClockSkewIsToday() {
        let cal = pdtCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 2, minute: 0))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 22, minute: 0))!
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "Today")
    }

    func testNDaysAgo() {
        let cal = utcCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 10))!
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "3 days ago")
    }

    func testWeeksAgo() {
        let cal = utcCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 5, day: 31, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 10))! // 14 days
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "2 weeks ago")
    }

    func testMonthsAgo() {
        let cal = utcCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 10))! // 60 days
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "2 months ago")
    }

    // Singular boundaries — exactly where a naive "N weeks/months ago"
    // plural goes wrong: 7 days must be "1 week ago", not "1 weeks".
    func testOneWeekAgoIsSingular() {
        let cal = utcCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 6, day: 7, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 10))! // 7 days
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "1 week ago")
    }

    func testOneMonthAgoIsSingular() {
        let cal = utcCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 10))! // 30 days
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "1 month ago")
    }

    func testUtcUserSameDayIsToday() {
        let cal = utcCalendar()
        let then = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 1))!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 23))!
        XCTAssertEqual(NotificationResponse.relativeLabel(for: then, now: now, calendar: cal), "Today")
    }

    // Timestamp parsing tolerates the server's variable sub-second
    // precision.
    func testParseTimestampWithFractionalSeconds() {
        XCTAssertNotNil(NotificationResponse.parseTimestamp("2026-06-15T03:12:00.123456Z"))
    }

    func testParseTimestampWithoutFractionalSeconds() {
        XCTAssertNotNil(NotificationResponse.parseTimestamp("2026-06-15T03:12:00Z"))
    }

    func testParseTimestampGarbageIsNil() {
        XCTAssertNil(NotificationResponse.parseTimestamp("not-a-timestamp"))
    }

    // Legacy fallback still works off the UTC bucket when createdAt is absent.
    func testBucketLabelFallback() {
        let now = Date(timeIntervalSince1970: 20_000 * 86_400 + 3_600) // bucket 20000 + 1h
        XCTAssertEqual(NotificationResponse.bucketLabel(dayBucket: 20_000, now: now), "Today")
        XCTAssertEqual(NotificationResponse.bucketLabel(dayBucket: 19_999, now: now), "Yesterday")
        XCTAssertEqual(NotificationResponse.bucketLabel(dayBucket: 19_997, now: now), "3 days ago")
    }
}
