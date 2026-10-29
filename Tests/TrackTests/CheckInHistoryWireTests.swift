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

/// Which route the check-in history screen reads from, and which one it must
/// never read from.
///
/// TWO ROUTES THAT LOOK INTERCHANGEABLE AND ARE NOT
///
///     GET /api/v1/check-ins                     ← personal feed
///       accepts only the account's SELF-key pseudonym (`user_pseudonym`);
///       anything else is 403 "Invalid user pseudonym".
///
///     GET /api/v1/circles/:id/check-ins         ← circle history
///       authorized by active membership of the circle.
///
///   `CheckInHistoryView` passes `activeCircle.id`, always a real circle, and a
///   per-circle pseudonym (`deriveUserPseudonym(circleId:userId:)`) sent to
///   the personal feed is always refused: no argument could make the personal
///   feed serve this screen.
///
/// WHY A PATH TEST AND NOT A ROUND TRIP
///   A wrong route fails at the authorization gate, before any response
///   handling. What has to stay true is the shape of the URL, so that is what
///   is pinned. `circleCheckInsPath` exists as a pure function for exactly
///   this reason.
final class CheckInHistoryWireTests: XCTestCase {

    private let circleId = "3f7a1b2c-0000-4000-8000-0123456789ab"

    /// The route itself. A history page must be scoped to the circle IN THE
    /// PATH — that is what makes membership the thing being checked.
    func testHistoryReadsTheCircleScopedRoute() {
        let path = APIService.circleCheckInsPath(circleId: circleId, limit: 100)

        XCTAssertTrue(
            path.hasPrefix("/api/v1/circles/\(circleId)/check-ins?"),
            "history must read the circle route; got \(path)"
        )
    }

    /// `user_pseudonym` on this request gets a 403 — the parameter belongs to
    /// the personal feed and to no other route, so it must be absent.
    func testHistoryNeverSendsAUserPseudonym() {
        let path = APIService.circleCheckInsPath(
            circleId: circleId,
            limit: 100,
            cursorDayBucket: 20_320,
            cursorId: "aaaaaaaa-0000-4000-8000-000000000001"
        )

        XCTAssertFalse(
            path.contains("user_pseudonym"),
            "a per-circle pseudonym on this route is 403 'Invalid user pseudonym'; got \(path)"
        )
    }

    /// The personal route must not be the one being called. Pinned separately
    /// from the prefix check above so an edit that brings in
    /// `/api/v1/check-ins` fails on a test whose name says why.
    func testHistoryDoesNotReadThePersonalFeed() {
        let path = APIService.circleCheckInsPath(circleId: circleId, limit: 100)

        XCTAssertFalse(
            path.hasPrefix("/api/v1/check-ins"),
            "that route authorizes against user_self_keys, not membership; got \(path)"
        )
    }

    /// The circle id must actually reach the wire: the query string carries
    /// only limit/pseudonym/cursor, so a request built without the id in its
    /// path would be unscoped and nothing in the URL would show it.
    func testTheCircleIdIsCarriedNotDropped() {
        let other = "99999999-0000-4000-8000-999999999999"

        let a = APIService.circleCheckInsPath(circleId: circleId, limit: 50)
        let b = APIService.circleCheckInsPath(circleId: other, limit: 50)

        XCTAssertNotEqual(a, b, "two circles must not produce the same request")
        XCTAssertTrue(a.contains(circleId))
        XCTAssertTrue(b.contains(other))
    }

    /// Keyset pagination is how the 30-day walk terminates. The server reads
    /// both halves of the cursor, and a missing `cursor_id` is silently taken
    /// as the nil UUID, which would re-serve the same page forever.
    func testCursorPaginationParametersAreSent() {
        let path = APIService.circleCheckInsPath(
            circleId: circleId,
            limit: 100,
            cursorDayBucket: 20_320,
            cursorId: "aaaaaaaa-0000-4000-8000-000000000001"
        )

        XCTAssertTrue(path.contains("limit=100"), path)
        XCTAssertTrue(path.contains("cursor_day_bucket=20320"), path)
        XCTAssertTrue(path.contains("cursor_id=aaaaaaaa-0000-4000-8000-000000000001"), path)
    }

    /// First page: no cursor at all, rather than a cursor with empty values —
    /// `cursor_day_bucket=` would parse as a deserialization error and 400 the
    /// whole first load.
    func testFirstPageSendsNoCursor() {
        let path = APIService.circleCheckInsPath(circleId: circleId, limit: 100)

        XCTAssertFalse(path.contains("cursor_day_bucket"), path)
        XCTAssertFalse(path.contains("cursor_id"), path)
        XCTAssertTrue(path.hasSuffix("?limit=100"), path)
    }

    // MARK: - The response envelope
    //
    // THE SHAPE THE CIRCLE ROUTE ANSWERS WITH
    //   `{"success":true,"data":[…]}` — `data` is a BARE ARRAY of check-ins.
    //   Decoding it as `Paginated<CheckInResponse>` and reading `.items` fails
    //   on every page, asking for a key the body never has:
    //
    //     Couldn't load check-in history: Decode failed:
    //     DecodingError.keyNotFound: Key 'items' not found in keyed decoding
    //     container … Body[26B]: {"success":true,"data":[]}
    //
    //   That the route paginates is true and irrelevant: it paginates by
    //   CURSOR, which is carried in the query string (pinned above), not in a
    //   `{items, has_more, next_cursor}` object. `listCircleDestinations`
    //   reads the same bare-array shape.
    //
    // READING A FAILURE FROM THESE
    //   `decodeResponseBody` tries `APIResponse<T>` under `try?` and then falls
    //   back to a direct `T` decode, so the error that escapes is the FALLBACK's,
    //   not the root cause. That is why asking for `Paginated` surfaces as
    //   keyNotFound("items") — decoding `Paginated` straight from the outer
    //   object — and why a row these tests cannot decode surfaces as
    //   typeMismatch "Expected to decode Array<Any> but found a dictionary".
    //   Both mean the same thing: `data` did not admit the type asked for.
    //
    // WHY THESE FEED REAL BODIES
    //   A test that builds a `Paginated` and decodes it passes even when the
    //   accessor asks for the wrong type — it asserts about a shape the server
    //   does not send. So the bytes asserted here are the bytes the route
    //   answers with, and they go through `APIService.decodeResponseBody`,
    //   which IS the live decode (the private `decodeResponse` calls it with
    //   the instance decoder).

    /// The empty page, byte for byte as the server sends it: 26 bytes that
    /// must decode.
    func testTheEmptyPageTheServerActuallySendsDecodes() throws {
        let body = Data(#"{"success":true,"data":[]}"#.utf8)

        let page: [CheckInResponse] = try APIService.decodeResponseBody(body)

        XCTAssertTrue(page.isEmpty, "an empty history is [] — not an error, and not a page object")
    }

    /// And a page with rows in it, so "it decodes" is not satisfied by the
    /// degenerate case alone.
    func testAPopulatedPageDecodesEveryRow() throws {
        let page: [CheckInResponse] = try APIService.decodeResponseBody(Self.populatedPage)

        XCTAssertEqual(page.count, 2, "both rows must survive; the page decodes as one array")

        let first = try XCTUnwrap(page.first)
        XCTAssertEqual(first.id, "11111111-0000-4000-8000-000000000001")
        XCTAssertEqual(first.checkInType, "safe_arrival")
        XCTAssertEqual(first.dayBucket, 20_320)
        XCTAssertEqual(first.encryptedMessage?.ciphertext, "msg-ct")
        XCTAssertEqual(first.encryptedUserId.nonce, "uid-n")
        XCTAssertEqual(first.encryptedTimestamp.ciphertext, "ts-ct")
    }

    /// The cursor walk terminates on `page.isEmpty`, so the empty body has to
    /// arrive as an empty array rather than as a throw — a throw is not a
    /// stopping condition, it is a dead screen.
    func testTheEmptyPageIsHowTheCursorWalkTerminates() throws {
        let page: [CheckInResponse] = try APIService.decodeResponseBody(
            Data(#"{"success":true,"data":[]}"#.utf8)
        )

        XCTAssertTrue(page.isEmpty, "loadCheckIns breaks its 10-page loop on this")
    }

    /// A row that deliberately withheld its location must not take the page down
    /// with it. A check-in may omit its location (for example an 'I'm safe'
    /// check-in that doesn't reveal where the sender is), and the server then
    /// sends the key as `null`. The page is decoded as ONE array, so a single
    /// such row from the web or Android client would empty the entire history
    /// for every iOS member of the circle unless the field is optional.
    func testARowThatWithheldItsLocationDoesNotEmptyThePage() throws {
        let page: [CheckInResponse] = try APIService.decodeResponseBody(Self.populatedPage)

        let withheld = try XCTUnwrap(page.last, "the null-location row must decode at all")
        XCTAssertEqual(withheld.checkInType, "im_safe")
        XCTAssertEqual(page.count, 2, "the located row must survive alongside it")

        // Deliberately NOT `XCTAssertNil(withheld.encryptedLocation)`. Touching
        // that field types this test to the field's optionality, and a
        // non-optional field would then stop the suite COMPILING instead of
        // turning it red — a build error is not the failure this test exists to
        // show. What is asserted is what the user loses: the page. Keep it that
        // way.
    }

    /// The negative half, stated once: decoding this route's body as the
    /// pagination envelope throws keyNotFound for `items`. Pinned so a reader
    /// can see that the two envelopes are not interchangeable rather than
    /// taking it on faith.
    func testThePaginationEnvelopeCannotDecodeThisRoutesBody() {
        let body = Data(#"{"success":true,"data":[]}"#.utf8)

        XCTAssertThrowsError(
            try APIService.decodeResponseBody(body) as Paginated<CheckInResponse>,
            "if this ever succeeds the route grew an envelope and these tests are stale"
        ) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "items", "the key the pagination envelope looks for")
        }
    }

    /// The call site itself, because none of the decode tests above can see it:
    /// they assert what `[CheckInResponse]` admits, not which type the accessor
    /// asks `get` for. That choice is made in one line of source, and source is
    /// the only place it is observable.
    func testTheHistoryAccessorsDoNotAskForAPaginationEnvelope() throws {
        for accessor in ["listCircleCheckIns", "getCheckIns"] {
            try APIServiceSource.assertNotPaginated(
                accessor,
                reason: "GET /api/v1/circles/:id/check-ins answers a bare array"
            )
        }
    }

    // MARK: - Fixtures

    /// Two rows in the shape the server sends: snake_case keys,
    /// `place_id`/`encrypted_message`/`encrypted_location` nullable, and the
    /// three mandatory blobs always present. The second row is the
    /// location-withheld case.
    private static let populatedPage = Data(#"""
    {"success":true,"data":[
      {"id":"11111111-0000-4000-8000-000000000001",
       "circle_id":"3f7a1b2c-0000-4000-8000-0123456789ab",
       "place_id":null,
       "encrypted_location":{"nonce":"loc-n","ciphertext":"loc-ct"},
       "encrypted_message":{"nonce":"msg-n","ciphertext":"msg-ct"},
       "check_in_type":"safe_arrival",
       "encrypted_user_id":{"nonce":"uid-n","ciphertext":"uid-ct"},
       "encrypted_device_id":{"nonce":"did-n","ciphertext":"did-ct"},
       "day_bucket":20320,
       "encrypted_timestamp":{"nonce":"ts-n","ciphertext":"ts-ct"}},
      {"id":"11111111-0000-4000-8000-000000000002",
       "circle_id":"3f7a1b2c-0000-4000-8000-0123456789ab",
       "place_id":null,
       "encrypted_location":null,
       "encrypted_message":null,
       "check_in_type":"im_safe",
       "encrypted_user_id":{"nonce":"uid-n2","ciphertext":"uid-ct2"},
       "encrypted_device_id":{"nonce":"did-n2","ciphertext":"did-ct2"},
       "day_bucket":20319,
       "encrypted_timestamp":{"nonce":"ts-n2","ciphertext":"ts-ct2"}}
    ]}
    """#.utf8)

}

/// Reads `APIService.swift` as text, so a test can assert which accessor a route
/// is wired to. Nothing else can see that: the decode tests assert what a TYPE
/// admits, while the mistake is the type the call site asks `get` for, and that
/// choice exists only in source.
///
/// Shared by `CheckInHistoryWireTests` and `InactivityNotifyOnReturnWireTests`
/// because the mistake is not specific to one endpoint:
/// `listCircleDestinations`, `listCircleCheckIns` and `listInactivityAlerts` can
/// each ask for a shape their route does not send.
enum APIServiceSource {

    /// `#filePath` is this file's absolute path at compile time, and the tests
    /// are built and run from the same checkout, so the sibling source is three
    /// directories up. Unreadable is a FAILURE, never a skip — a tripwire that
    /// quietly opts out is worse than no tripwire.
    static func text() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TrackTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("App/Services/APIService.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(
                domain: "APIServiceSource", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot read \(url.path) — this tripwire reads source and must not pass blind"]
            )
        }
        return text
    }

    /// The source of one member function, its declaration excluded so the doc
    /// comment above it (which names `getPaginated` on purpose) is not what gets
    /// matched. Ends at the first `\n    }` — the closing brace of a member at
    /// this indent level.
    static func body(ofFunc name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: "func \(name)("),
            "no `func \(name)(` in APIService.swift — was it renamed?"
        )
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(
            rest.range(of: "\n    }"),
            "could not find the end of \(name)"
        )
        return String(rest[..<end.lowerBound])
    }

    /// Fail if `accessor` reads its page through `getPaginated`. `reason` says
    /// what the route actually answers with.
    static func assertNotPaginated(
        _ accessor: String,
        reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let body = try body(ofFunc: accessor, in: try text())
        XCTAssertFalse(
            body.contains("getPaginated"), """
            \(accessor) uses getPaginated, but \(reason). getPaginated decodes \
            Paginated<E> and reads .items, so every call throws \
            keyNotFound("items") on a 200. Use `get`.
            """,
            file: file, line: line
        )
    }
}
