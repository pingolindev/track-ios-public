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

/// Pins the Notification Service Extension's timestamp handling.
///
/// The delivered text cannot be read back automatically: iOS redacts
/// notification bodies from the device log, and there is no screenshot path
/// on iOS 26 without the Developer Disk Image. These tests cover the two
/// things that decide whether that text is right.
final class NotificationStampTests: XCTestCase {

    // MARK: - RFC3339 parsing

    /// Why the format matters.
    ///
    /// A timestamp with NINE fractional digits
    /// ("2026-07-29T02:49:21.619329845+00:00", as an RFC 3339 serializer can
    /// emit) does not parse with ISO8601DateFormatter, so `parseRFC3339` would
    /// return nil and the extension silently fall back to `Date()` — stamping
    /// DELIVERY time while looking perfectly correct. The server sends seconds
    /// precision; this pins that format, so a change to the server's output
    /// fails here instead of shipping a wrong timestamp.
    func testParsesTheSecondsPrecisionFormatTheBackendSends() throws {
        let parsed = try XCTUnwrap(
            NotificationService.parseRFC3339("2026-07-29T02:49:21Z"),
            "must parse chrono's SecondsFormat::Secs output"
        )
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_785_293_361, accuracy: 1)
    }

    /// Belt and braces: if anything upstream ever sends milliseconds, take it
    /// rather than falling back to "now".
    func testAlsoParsesFractionalSeconds() {
        XCTAssertNotNil(NotificationService.parseRFC3339("2026-07-29T02:49:21.619Z"))
    }

    func testRejectsGarbageRatherThanInventingATime() {
        XCTAssertNil(NotificationService.parseRFC3339("not a date"))
        XCTAssertNil(NotificationService.parseRFC3339(""))
    }

    // MARK: - Formatting

    /// Asserted by SHAPE, not by literal: the rendering is locale- and
    /// settings-dependent (d/M ordering, 24-hour clocks), so a hardcoded
    /// "7/28, 7:25 PM" would pass only on a US-locale 12-hour device.
    func testStampIsAShortDateThenTime() {
        let date = Date(timeIntervalSince1970: 1_785_293_361) // 2026-07-29T02:49:21Z
        let stamp = NotificationService.shortStamp(date)

        let parts = stamp.components(separatedBy: ", ")
        XCTAssertEqual(parts.count, 2, "expected '<date>, <time>' — got '\(stamp)'")

        XCTAssertTrue(
            parts[0].rangeOfCharacter(from: .decimalDigits) != nil,
            "date part '\(parts[0])' has no digits"
        )
        XCTAssertTrue(
            parts[1].contains(":"),
            "time part '\(parts[1])' is not a clock time"
        )
        // No year: the point is a SHORT stamp.
        XCTAssertFalse(stamp.contains("2026"), "stamp '\(stamp)' should omit the year")
    }

    func testStampReflectsTheGivenInstantNotNow() {
        let a = NotificationService.shortStamp(Date(timeIntervalSince1970: 1_785_293_361))
        let b = NotificationService.shortStamp(Date(timeIntervalSince1970: 1_785_293_361 + 86_400))
        XCTAssertNotEqual(a, b, "a day apart must not render identically")
    }
}
