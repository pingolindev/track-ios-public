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

/// The free-tier history clamp: the server shortens an over-long range instead
/// of refusing it, and says so in `history_days_allowed`.
///
/// WHY THE DECODING HALF IS TESTED AT ALL
///   Unless the app reads the field, "your plan stops here" and "the data is
///   missing" look identical — a free-tier user picking 7d gets 2 days and no
///   explanation. The field must also be optional: declared non-optional it
///   would make the WHOLE history decode throw against a backend that
///   predates it, turning a missing notice into a missing timeline. The
///   absent-key cases below are that guarantee.
final class HistoryClampTests: XCTestCase {

    private func decode(_ json: String) throws -> HistoryLocationsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HistoryLocationsResponse.self, from: Data(json.utf8))
    }

    /// One real row, so a decode that "passes" cannot be passing on an empty
    /// array that never exercised the element type.
    private let oneRow = """
    {"user_id":"11111111-1111-1111-1111-111111111111",
     "day_bucket":20000,
     "encrypted_payload":{"nonce":"aa","ciphertext":"bb","key_id":""}}
    """

    // MARK: - Decoding

    func testHistoryDaysAllowedDecodesWhenPresent() throws {
        let r = try decode("""
        {"locations":[\(oneRow)],"history_days_allowed":2}
        """)
        XCTAssertEqual(r.historyDaysAllowed, 2)
        XCTAssertEqual(r.locations.count, 1)
    }

    /// A backend that predates the field must NOT fail the whole response —
    /// losing the notice is survivable, losing the timeline is not.
    func testAbsentKeyDecodesRatherThanFailingTheWholeResponse() throws {
        let r = try decode("""
        {"locations":[\(oneRow)]}
        """)
        XCTAssertNil(r.historyDaysAllowed)
        XCTAssertEqual(r.locations.count, 1, "the rows must still land")
    }

    /// The server leaves `truncated` out unless it is true, so it is simply
    /// ABSENT on the common path rather than `false`.
    func testTruncatedIsAbsentOnTheCommonPathAndPresentWhenSet() throws {
        XCTAssertNil(try decode("""
        {"locations":[],"history_days_allowed":365}
        """).truncated)
        XCTAssertEqual(try decode("""
        {"locations":[],"history_days_allowed":365,"truncated":true}
        """).truncated, true)
    }

    /// The premium payload carries key_rotation alongside the history
    /// fields; both must decode.
    func testKeyRotationStillDecodesAlongsideTheNewFields() throws {
        let r = try decode("""
        {"locations":[],"history_days_allowed":365,
         "key_rotation":{"rotation_needed":true,"deadline":null,"message":"Rotate soon"}}
        """)
        XCTAssertEqual(r.keyRotation?.rotationNeeded, true)
        XCTAssertEqual(r.keyRotation?.message, "Rotate soon")
        XCTAssertEqual(r.historyDaysAllowed, 365)
    }

    // MARK: - The notice

    /// The case the notice exists for: free tier is 2 days, the user
    /// picked the 7d chip.
    func testFreeTierSevenDayRequestIsCalledOut() {
        let notice = HistoryViewModel.clampNotice(requestedDays: 7, allowedDays: 2)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("2 days"), notice!)
        XCTAssertTrue(notice!.contains("7 days"), notice!)
    }

    /// Premium asked for a week out of a year — nothing was clamped, so a
    /// notice here would be a lie shown to a paying member.
    func testNothingIsSaidWhenTheRangeFitsInsideTheEntitlement() {
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 7, allowedDays: 365))
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 1, allowedDays: 2))
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 0, allowedDays: 2))
    }

    /// Both ends are floored to day buckets, so a range can read a day or two
    /// short at the boundaries. Firing on that would put the notice in front of
    /// premium members, which is exactly the failure mode the tolerance exists
    /// to avoid. Same `> 2` rule the Android app uses.
    func testDayBucketRoundingDoesNotTripTheNotice() {
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 3, allowedDays: 2))
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 4, allowedDays: 2))
        XCTAssertNotNil(HistoryViewModel.clampNotice(requestedDays: 5, allowedDays: 2),
                        "one past the tolerance is a real clamp")
    }

    /// An older backend sends nothing; a nonsense value is not evidence of a
    /// clamp either. Both must stay silent rather than guess.
    func testUnknownOrNonsenseEntitlementSaysNothing() {
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 30, allowedDays: nil))
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 30, allowedDays: 0))
        XCTAssertNil(HistoryViewModel.clampNotice(requestedDays: 30, allowedDays: -1))
    }

    func testSingleDayEntitlementPluralisesCorrectly() {
        let notice = HistoryViewModel.clampNotice(requestedDays: 30, allowedDays: 1)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("1 day of history"), notice!)
        XCTAssertFalse(notice!.contains("1 days"), notice!)
    }

    // MARK: - The range being measured

    /// The notice compares the server's answer against what the chip asked
    /// for, so the two must be measured in the SAME unit the request used.
    func testRequestedDaysMatchesTheBucketsTheRequestSends() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let week = try XCTUnwrap(HistoryRange.week.window(now: now))
        XCTAssertEqual(HistoryViewModel.requestedDays(week), 7)

        let day = try XCTUnwrap(HistoryRange.day.window(now: now))
        XCTAssertEqual(HistoryViewModel.requestedDays(day), 1)

        // `.today` starts at local midnight, so it never spans a bucket
        // boundary — and must never be reported as a clamp.
        let today = try XCTUnwrap(HistoryRange.today.window(now: now))
        XCTAssertEqual(HistoryViewModel.requestedDays(today), 0)
        XCTAssertNil(HistoryViewModel.clampNotice(
            requestedDays: HistoryViewModel.requestedDays(today), allowedDays: 2))
    }

    /// `.live` fetches nothing, so there is no range to compare and no notice
    /// to show.
    func testLiveHasNoWindowToMeasure() {
        XCTAssertNil(HistoryRange.live.window())
    }
}
