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

/// The export's pure parts: cursor construction, page merging, and the file
/// format. These are the pieces that fail SILENTLY — a wrong cursor skips rows,
/// a wrong merge duplicates them, a wrong key name produces a file only this
/// client can read — and none of it surfaces until someone tries to restore.
final class DataExportTests: XCTestCase {

    // MARK: - Cursors

    func testNoCursorsOnTheFirstPage() {
        XCTAssertTrue(DataExportService.cursors(from: nil).isEmpty)
    }

    func testCircleCursorSendsZeroForANullJoinBucket() throws {
        // The server orders a NULL join bucket as 0. If the cursor omits it or
        // sends something else, the cursor and the ORDER BY disagree and rows
        // are skipped — an export that is short without saying so.
        let page = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "circles":[{"circle_id":"c-1","role":"member","key_version":2,"joined_day_bucket":null}]}
        """#)

        let c = DataExportService.cursors(from: page)
        XCTAssertEqual(c["cursor_circle_joined_bucket"], "0")
        XCTAssertEqual(c["cursor_circle_id"], "c-1")
    }

    func testLocationCursorCarriesAllThreeParts() throws {
        // inserted_at is assigned per insert BATCH, so many rows share one
        // value and (day_bucket, inserted_at) is not a total order. Without
        // row_key, every row tied with the last of a page is skipped.
        //
        // `device_id` BELOW IS NOT WHAT THE SERVER SENDS. The server's
        // export carries `device_pseudonym` — a BLAKE3 pseudonym, because
        // the server never stores a raw device id — and no `device_id`
        // field at all. `.convertFromSnakeCase` maps that to
        // `devicePseudonym`, which `LocationExportRow` does not declare, so
        // its `deviceId` is nil and the backup file writes "device_id": "".
        // No restore reads `device_id` (the web app's restore sends
        // `device_pseudonym: ''` back). The fixture keeps it so this test
        // tests the cursor and nothing else — do not read it as a
        // description of the wire.
        let page = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":1},
         "locations":[{"device_id":"d","circle_id":"c","day_bucket":20000,
          "encrypted_payload":{"nonce":"n","ciphertext":"ct","key_id":null,
           "wrapped_msg_key":null,"wrapped_msg_key_nonce":null},
          "key_id":"","inserted_at_ms":1723000000000,"row_key":"rk-9"}]}
        """#)

        let c = DataExportService.cursors(from: page)
        XCTAssertEqual(c["cursor_day_bucket"], "20000")
        XCTAssertEqual(c["cursor_inserted_at_ms"], "1723000000000")
        XCTAssertEqual(c["cursor_row_key"], "rk-9")
    }

    func testPrivacyCursorNeedsNoTiebreaker() throws {
        // One row per (user, circle), so the circle id alone is a total order.
        let page = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "privacy":[{"circle_id":"c-7","sharing_mode":"exact"}]}
        """#)

        let c = DataExportService.cursors(from: page)
        XCTAssertEqual(c["cursor_privacy_circle_id"], "c-7")
        XCTAssertNil(c["cursor_privacy_id"])
    }

    // MARK: - Merging

    func testAFinishedSectionIsNotAppendedTwice() throws {
        // The section that has dropped out of `outstanding` keeps what it had.
        // Re-appending would duplicate the last page of every section into the
        // file, and duplicates in a backup are only found at restore.
        let first = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "places":[{"id":"p1","circle_id":null,"radius_meters":100,"created_day_bucket":5}]}
        """#)
        let second = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "places":[{"id":"p2","circle_id":null,"radius_meters":100,"created_day_bucket":6}]}
        """#)

        let stillPaging = DataExportService.merge(first, second, outstanding: ["places"])
        XCTAssertEqual(stillPaging.places?.count, 2)

        let finished = DataExportService.merge(first, second, outstanding: [])
        XCTAssertEqual(finished.places?.count, 1)
        XCTAssertEqual(finished.places?.first?.id, "p1")
    }

    func testPreferencesAreKeptFromTheFirstPageThatHadThem() throws {
        // A singleton, requested once and carried forward. Overwriting it with a
        // later page's nil would drop it from the file.
        let withPrefs = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "preferences":{"units":"metric"}}
        """#)
        let without = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0}}
        """#)

        let merged = DataExportService.merge(withPrefs, without, outstanding: [])
        XCTAssertNotNil(merged.preferences)
    }

    // MARK: - Location parsing

    func testExportedLocationAcceptsEveryFieldNamingTheWritersUse() {
        XCTAssertEqual(
            DataExportService.parseExportedLocation(#"{"latitude":51.5,"longitude":-0.12}"#)?.latitude,
            51.5
        )
        XCTAssertEqual(
            DataExportService.parseExportedLocation(#"{"lat":51.5,"lng":-0.12}"#)?.longitude,
            -0.12
        )
        XCTAssertEqual(
            DataExportService.parseExportedLocation(#"{"lat":1.0,"lon":2.0}"#)?.longitude,
            2.0
        )
        XCTAssertNil(DataExportService.parseExportedLocation(#"{"latitude":51.5}"#))
        XCTAssertNil(DataExportService.parseExportedLocation("not json"))
    }

    // MARK: - File format

    func testTheFileUsesSnakeCaseKeysTheOtherClientsRead() throws {
        // The whole point of the backup is that it outlives the device that made
        // it. A camelCase key here produces a file only iOS can read.
        let raw = try decode(#"""
        {"metadata":{"user_id":"user-1","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.2","location_count":1}}
        """#)
        var decrypted = TrackBackupFile.Decrypted()
        decrypted.places = [
            TrackBackupFile.Place(
                id: "p1", circleId: nil, name: "Home",
                latitude: 51.5, longitude: -0.12,
                radiusMeters: 150, createdDayBucket: 19999
            )
        ]

        let file = TrackBackupFile.build(
            raw: raw, decrypted: decrypted,
            pagesFetched: 2, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TrackBackupFile.encode(file)) as? [String: Any]
        )

        let places = try XCTUnwrap(json["places"] as? [[String: Any]])
        XCTAssertEqual(places.first?["radius_meters"] as? Int, 150)
        XCTAssertEqual(places.first?["created_day_bucket"] as? Int, 19999)
        // Nested, matching web and Android — a restore reads latitude/longitude
        // back out of this object rather than off the row.
        let loc = try XCTUnwrap(places.first?["location"] as? [String: Any])
        XCTAssertEqual(loc["latitude"] as? Double, 51.5)
        // A personal place has no circle, and null is the honest answer rather
        // than the key being absent.
        XCTAssertTrue(places.first?["circle_id"] is NSNull)

        let envelope = try XCTUnwrap(json["export"] as? [String: Any])
        XCTAssertEqual(envelope["product"] as? String, "pingolin-track")
        XCTAssertEqual(envelope["generated_by"] as? String, "ios")
        XCTAssertEqual(envelope["pages_fetched"] as? Int, 2)
        XCTAssertEqual(envelope["is_complete"] as? Bool, true)
        let sections = try XCTUnwrap(envelope["sections"] as? [String: Any])
        XCTAssertEqual(sections["places"] as? Int, 1)
    }

    func testASectionThatWasNotExportedIsAbsentRatherThanEmpty() throws {
        // "devices": [] would claim the account has no devices. Absent says
        // the export did not ask, which is the truth and what a restore needs
        // to know.
        let raw = try decode(#"""
        {"metadata":{"user_id":"user-1","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.2","location_count":0}}
        """#)
        let file = TrackBackupFile.build(
            raw: raw, decrypted: TrackBackupFile.Decrypted(),
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        XCTAssertNil(file["devices"])
        let sections = try XCTUnwrap(
            (file["export"] as? [String: Any])?["sections"] as? [String: Any]
        )
        XCTAssertNil(sections["devices"])
    }

    func testConfigSectionsSurviveFieldsThisBuildDoesNotKnow() throws {
        // The file is supposed to outlive the build that wrote it, so a config
        // section is carried through untouched rather than remodelled.
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0},
         "alerts":[{"id":"a1","some_field_added_later":{"nested":[1,2,3]}}]}
        """#)
        let file = TrackBackupFile.build(
            raw: raw, decrypted: TrackBackupFile.Decrypted(),
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        let alerts = try XCTUnwrap(file["alerts"] as? [[String: Any]])
        let later = try XCTUnwrap(alerts.first?["some_field_added_later"] as? [String: Any])
        XCTAssertEqual(later["nested"] as? [Int], [1, 2, 3])
    }

    func testAnIncompleteExportSaysSoInTheFile() throws {
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.2","location_count":0}}
        """#)
        let file = TrackBackupFile.build(
            raw: raw, decrypted: TrackBackupFile.Decrypted(),
            pagesFetched: 500, isComplete: false,
            generatedAt: "2026-08-13T10:00:00Z",
            incompleteReason: "page cap reached"
        )
        let envelope = try XCTUnwrap(file["export"] as? [String: Any])
        XCTAssertEqual(envelope["is_complete"] as? Bool, false)
        XCTAssertEqual(envelope["incomplete_reason"] as? String, "page cap reached")
    }

    /// Every history point must carry `inserted_at_ms`, as a number: the web
    /// app's restore skips any point whose `day_bucket` or `inserted_at_ms` is
    /// not a number. A skip, not an error — so a file without it restores
    /// "successfully" with a history count of zero and nothing anywhere says
    /// why. The name is the server's own export field, spelled the same on the
    /// wire, in the file, and in the restore payload.
    func testALocationRowCarriesInsertedAtMsSoAWebRestoreWillTakeIt() throws {
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.2","location_count":1}}
        """#)
        var decrypted = TrackBackupFile.Decrypted()
        decrypted.locations = [
            TrackBackupFile.LocationRow(
                deviceId: "dev-1", circleId: "", dayBucket: 20000,
                timestamp: 1_723_000_000_000,
                latitude: 51.5, longitude: -0.12, accuracy: 12.5,
                keyId: "k1", insertedAtMs: 1_723_000_000_123,
                rowKey: "rk-7"
            )
        ]

        let file = TrackBackupFile.build(
            raw: raw, decrypted: decrypted,
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TrackBackupFile.encode(file)) as? [String: Any]
        )
        let row = try XCTUnwrap((json["locations"] as? [[String: Any]])?.first)

        XCTAssertEqual(row["inserted_at_ms"] as? Int64, 1_723_000_000_123)
        // The restore checks the JSON type (`typeof === 'number'`). A
        // stringified id passes a Swift nil-check and still fails that
        // check, so pin the JSON type, not just the presence.
        XCTAssertFalse(row["inserted_at_ms"] is String,
                       "web tests typeof; a string is dropped exactly like a missing key")

        // Additive. The six keys the file has always had are untouched —
        // a restore written against the six-key shape must keep working.
        //
        // `device_id` is the FILE's key (the web app and the Android app
        // write it too), but the value is "" in practice: the server sends
        // `device_pseudonym` and nothing populates
        // `LocationExportRow.deviceId`. See the note on
        // testLocationCursorCarriesAllThreeParts. Asserted here as a key
        // the writer must keep emitting, not as a value anyone should rely
        // on.
        XCTAssertEqual(row["device_id"] as? String, "dev-1")
        XCTAssertEqual(row["circle_id"] as? String, "")
        XCTAssertEqual(row["day_bucket"] as? Int, 20000)
        XCTAssertEqual(row["key_id"] as? String, "k1")
        XCTAssertEqual(row["timestamp"] as? Int64, 1_723_000_000_000)
        let point = try XCTUnwrap(row["location"] as? [String: Any])
        XCTAssertEqual(point["latitude"] as? Double, 51.5)
        XCTAssertEqual(point["longitude"] as? Double, -0.12)
        XCTAssertEqual(point["accuracy"] as? Double, 12.5)
    }

    /// A backend that predates the field sends nothing, and the key is left out
    /// rather than written as null. Both are dropped by the same guard, but an
    /// absent key is the honest shape for "the server did not tell us" — and it
    /// matches how `timestamp` already behaves.
    func testAMissingInsertedAtMsLeavesTheKeyOutRatherThanWritingNull() throws {
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.2","location_count":1}}
        """#)
        var decrypted = TrackBackupFile.Decrypted()
        decrypted.locations = [
            TrackBackupFile.LocationRow(
                deviceId: "dev-1", circleId: "", dayBucket: 20000,
                timestamp: nil, latitude: 51.5, longitude: -0.12,
                accuracy: nil, keyId: "k1", insertedAtMs: nil,
                rowKey: nil
            )
        ]
        let file = TrackBackupFile.build(
            raw: raw, decrypted: decrypted,
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        let row = try XCTUnwrap((file["locations"] as? [[String: Any]])?.first)
        XCTAssertNil(row["inserted_at_ms"])
        XCTAssertNil(row["timestamp"])
    }

    /// Restoring the same backup twice must not double the history.
    ///
    /// A restore re-seals every point with a fresh nonce, so the encrypted
    /// payload can't tell a point already restored from a new one.
    /// `/locations/restore` dedupes on `row_key`, which the server computes
    /// over the row's ORIGINAL ciphertext: it still identifies the source row
    /// after the export decrypted that ciphertext away. The name is the
    /// server's own export field, spelled the same on the wire, in the file,
    /// and in the restore payload — the web app reads it straight back out as
    /// `loc.row_key`.
    func testALocationRowCarriesRowKeySoASecondRestoreIsANoOp() throws {
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.2","location_count":1}}
        """#)
        var decrypted = TrackBackupFile.Decrypted()
        decrypted.locations = [
            TrackBackupFile.LocationRow(
                deviceId: "dev-1", circleId: "", dayBucket: 20000,
                timestamp: 1_723_000_000_000,
                latitude: 51.5, longitude: -0.12, accuracy: 12.5,
                keyId: "k1", insertedAtMs: 1_723_000_000_123,
                rowKey: "rk-9"
            )
        ]

        let file = TrackBackupFile.build(
            raw: raw, decrypted: decrypted,
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TrackBackupFile.encode(file)) as? [String: Any]
        )
        let row = try XCTUnwrap((json["locations"] as? [[String: Any]])?.first)

        XCTAssertEqual(row["row_key"] as? String, "rk-9")
        // The server compares it as a string. A number would arrive as one and
        // match nothing, so pin the JSON type rather than just the presence.
        XCTAssertTrue(row["row_key"] is String,
                      "the server trims and compares it as a string")

        // Additive. The seven keys the row has always had are
        // untouched — a restore written against the seven-key
        // shape must keep working.
        XCTAssertEqual(row["device_id"] as? String, "dev-1")
        XCTAssertEqual(row["circle_id"] as? String, "")
        XCTAssertEqual(row["day_bucket"] as? Int, 20000)
        XCTAssertEqual(row["key_id"] as? String, "k1")
        XCTAssertEqual(row["timestamp"] as? Int64, 1_723_000_000_000)
        XCTAssertEqual(row["inserted_at_ms"] as? Int64, 1_723_000_000_123)
        let point = try XCTUnwrap(row["location"] as? [String: Any])
        XCTAssertEqual(point["latitude"] as? Double, 51.5)
        XCTAssertEqual(point["longitude"] as? Double, -0.12)
    }

    /// A backend that predates the field sends nothing, and the key is left out
    /// rather than written as an empty string.
    ///
    /// The direction matters: an absent key means "cannot dedupe, INSERT", so a
    /// backup without it restores as a plain insert — duplicating on a second
    /// run. An empty string would compare equal to every other keyless row and
    /// suppress real history instead.
    func testAMissingRowKeyLeavesTheKeyOutRatherThanWritingAnEmptyString() throws {
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.2","location_count":1}}
        """#)
        var decrypted = TrackBackupFile.Decrypted()
        decrypted.locations = [
            TrackBackupFile.LocationRow(
                deviceId: "dev-1", circleId: "", dayBucket: 20000,
                timestamp: nil, latitude: 51.5, longitude: -0.12,
                accuracy: nil, keyId: "k1", insertedAtMs: 1_723_000_000_123,
                rowKey: nil
            )
        ]
        let file = TrackBackupFile.build(
            raw: raw, decrypted: decrypted,
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        // Asserted on the SERIALIZED file, not the dictionary: an NSNull would
        // pass a nil-check here and still write `"row_key": null` to disk.
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TrackBackupFile.encode(file)) as? [String: Any]
        )
        let row = try XCTUnwrap((json["locations"] as? [[String: Any]])?.first)
        XCTAssertNil(row["row_key"])
        XCTAssertFalse(row.keys.contains("row_key"),
                       "an absent key means INSERT; an empty one suppresses real points")
        // The point itself still has to be written, and still has to be
        // restorable — dropping it is the one outcome worse than a duplicate.
        XCTAssertEqual(row["inserted_at_ms"] as? Int64, 1_723_000_000_123)
    }

    // MARK: - Circle-less check-ins

    func testAPersonalCheckInDecodesAlongsideACircleOne() throws {
        // `circle_id` is null on a check-in made outside any circle, and
        // on one whose circle was later deleted (the server nulls it when
        // the circle goes). `CheckInExportRow.circleId` must be optional:
        // Codable does not skip the row it cannot decode, it throws for
        // the WHOLE page, so one personal check-in would stop this client
        // exporting the account at all.
        //
        // Both kinds are in one page deliberately. A fixture with only the
        // personal row would not notice a decode that took the null but
        // lost the circle on the other, and a fixture with only the circle
        // row would pass with a non-optional `circleId`.
        let page = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.8","location_count":0},
         "check_ins":[
           {"id":"k-personal","circle_id":null,"check_in_type":"safe_arrival","created_day_bucket":20001},
           {"id":"k-circle","circle_id":"c-1","check_in_type":"general","created_day_bucket":20000}]}
        """#)

        let rows = try XCTUnwrap(page.checkIns)
        XCTAssertEqual(rows.count, 2, "a null circle must not cost the page its other rows")
        XCTAssertNil(rows.first { $0.id == "k-personal" }?.circleId)
        XCTAssertEqual(rows.first { $0.id == "k-circle" }?.circleId, "c-1")
        // The rest of the row must survive the null, not just the id.
        XCTAssertEqual(rows.first { $0.id == "k-personal" }?.checkInType, "safe_arrival")
        XCTAssertEqual(rows.first { $0.id == "k-personal" }?.createdDayBucket, 20001)
    }

    func testAPersonalCheckInWritesNullRatherThanAMissingCircle() throws {
        // Same contract as `places`: null is the honest answer, and an absent
        // key is not. It also must NOT be the self-circle UUID — that is the
        // domain the row was decrypted under, not the circle it belongs to, and
        // writing it here would invent a circle membership in the user's own
        // backup file.
        let raw = try decode(#"""
        {"metadata":{"user_id":"user-1","exported_day_bucket":20000,"start_day_bucket":19970,
         "end_day_bucket":20000,"format_version":"1.8","location_count":0}}
        """#)
        var decrypted = TrackBackupFile.Decrypted()
        decrypted.checkIns = [
            TrackBackupFile.CheckIn(
                id: "k-personal", circleId: nil, checkInType: "safe_arrival",
                message: nil, latitude: nil, longitude: nil, createdDayBucket: 20001
            ),
            TrackBackupFile.CheckIn(
                id: "k-circle", circleId: "c-1", checkInType: "general",
                message: nil, latitude: nil, longitude: nil, createdDayBucket: 20000
            ),
        ]

        let file = TrackBackupFile.build(
            raw: raw, decrypted: decrypted,
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-08-13T10:00:00Z"
        )
        // Through JSONSerialization, because a boxed Optional in [String: Any]
        // is what would actually break the write — the dictionary itself would
        // look fine to an assertion made before encoding.
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TrackBackupFile.encode(file)) as? [String: Any]
        )
        let rows = try XCTUnwrap(json["check_ins"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)

        let personal = try XCTUnwrap(rows.first { $0["id"] as? String == "k-personal" })
        XCTAssertTrue(personal["circle_id"] is NSNull, "null, not absent and not a substituted UUID")
        XCTAssertEqual(personal["check_in_type"] as? String, "safe_arrival")

        let inCircle = try XCTUnwrap(rows.first { $0["id"] as? String == "k-circle" })
        XCTAssertEqual(inCircle["circle_id"] as? String, "c-1")

        let sections = try XCTUnwrap(
            (json["export"] as? [String: Any])?["sections"] as? [String: Any]
        )
        XCTAssertEqual(sections["check_ins"] as? Int, 2)
    }

    // MARK: - Day buckets

    func testDayBucketIsDaysSinceTheEpoch() {
        XCTAssertEqual(DataExportService.dayBucket(Date(timeIntervalSince1970: 0)), 0)
        XCTAssertEqual(DataExportService.dayBucket(Date(timeIntervalSince1970: 86_400)), 1)
        XCTAssertEqual(DataExportService.dayBucket(Date(timeIntervalSince1970: 86_400 * 20_000 + 5)), 20_000)
    }

    // MARK: - Blocked people (format 1.9)

    /// "Blocked people": the addresses whose owners may not invite this
    /// account to a circle. The server serves this section ONLY WHEN ASKED
    /// FOR: an app from before it does not know its cursor, and a section it
    /// cannot page must not be able to make its export read as incomplete.
    /// So, unlike every other section, a request that leaves the flag out
    /// does not get it.
    func testBlockedPeopleAreAskedForInSoManyWordsWhileTheyAreOutstanding() {
        let asking = APIService.exportQueryParams(
            startDayBucket: 0, endDayBucket: 10,
            include: ["blocked_people", "places"], includePreferences: false, cursors: [:]
        )
        XCTAssertEqual(asking["include_blocked_people"], "true")
        XCTAssertEqual(asking["include_places"], "true")
        XCTAssertEqual(asking["include_devices"], "false")

        // Finished: said in so many words too, so the server stops serving its last page.
        let finished = APIService.exportQueryParams(
            startDayBucket: nil, endDayBucket: nil,
            include: ["places"], includePreferences: false,
            cursors: ["cursor_blocked_person_id": "b2"]
        )
        XCTAssertEqual(finished["include_blocked_people"], "false")
        XCTAssertEqual(finished["cursor_blocked_person_id"], "b2", "the cursors travel with the flags")
        XCTAssertNil(finished["start_day_bucket"])
    }

    func testBlockedPeopleCursorSendsBothHalvesFromTheLastRow() throws {
        let page = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0,
         "blocked_people_has_more":true,"is_complete":false},
         "blocked_people":[{"id":"b3","blocked_email":"c@example.test","created_at_ms":30},
                           {"id":"b2","blocked_email":"b@example.test","created_at_ms":20}]}
        """#)

        XCTAssertTrue(page.metadata.blockedPeopleHasMore)
        let c = DataExportService.cursors(from: page)
        // The LAST row of the page, and both halves: half a cursor skips rows tied on the time.
        XCTAssertEqual(c["cursor_blocked_person_created_at_ms"], "20")
        XCTAssertEqual(c["cursor_blocked_person_id"], "b2")
    }

    func testBlockedPeopleAreAppendedWhileOutstandingAndKeptOnceFinished() throws {
        let first = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0,"blocked_people_has_more":true},
         "blocked_people":[{"id":"b3","blocked_email":"c@example.test","created_at_ms":30}]}
        """#)
        let second = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0},
         "blocked_people":[{"id":"b2","blocked_email":"b@example.test","created_at_ms":20}]}
        """#)

        let stillPaging = DataExportService.merge(first, second, outstanding: ["blocked_people"])
        XCTAssertEqual(stillPaging.blockedPeople?.compactMap { $0.string("id") }, ["b3", "b2"])

        let finished = DataExportService.merge(first, second, outstanding: [])
        XCTAssertEqual(finished.blockedPeople?.compactMap { $0.string("id") }, ["b3"])
    }

    func testBlockedPeopleReachTheFileAsTheyWereServed() throws {
        let raw = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0},
         "blocked_people":[{"id":"b1","blocked_email":"sam@example.test","created_at_ms":1759824000123}]}
        """#)
        let file = TrackBackupFile.build(
            raw: raw, decrypted: TrackBackupFile.Decrypted(),
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-10-07T10:00:00Z"
        )
        let list = try XCTUnwrap(file["blocked_people"] as? [[String: Any]])
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?["blocked_email"] as? String, "sam@example.test")
        XCTAssertEqual(list.first?["id"] as? String, "b1")
        let export = try XCTUnwrap(file["export"] as? [String: Any])
        let sections = try XCTUnwrap(export["sections"] as? [String: Any])
        XCTAssertEqual(sections["blocked_people"] as? Int, 1)
    }

    /// Asked for, served, and then DROPPED: a section that never drops out of
    /// the paging set is asked for on every request until the page limit, and
    /// the export fails as incomplete.
    func testBlockedPeopleDropOutOfThePagingSetWhenTheyAreAllHere() throws {
        let more = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0,"blocked_people_has_more":true},
         "blocked_people":[{"id":"b3","blocked_email":"c@example.test","created_at_ms":30}]}
        """#)
        XCTAssertEqual(DataExportService.stillOutstanding(["blocked_people"], after: more), ["blocked_people"])

        let last = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0},
         "blocked_people":[{"id":"b2","blocked_email":"b@example.test","created_at_ms":20}]}
        """#)
        XCTAssertEqual(DataExportService.stillOutstanding(["blocked_people"], after: last), [])

        // A page with no rows ends the section even while the flag still claims more: the
        // cursor comes from the last row, and a page without one cannot move it on.
        let stuck = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0,"blocked_people_has_more":true},
         "blocked_people":[]}
        """#)
        XCTAssertEqual(DataExportService.stillOutstanding(["blocked_people"], after: stuck), [])
        // A server from before the section serves none of it: it drops out at the first page.
        let older = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.8","location_count":0}}
        """#)
        XCTAssertEqual(DataExportService.stillOutstanding(["blocked_people"], after: older), [])
    }

    /// The same for every section the loop asks for: a page that serves none
    /// of them leaves none outstanding. A section missing from the function
    /// would still be in the set.
    func testEverySectionTheLoopAsksForDropsOutOnAPageThatServesNone() throws {
        let nothing = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0}}
        """#)
        let all: Set<String> = [
            "devices", "circles", "places", "check_ins", "locations",
            "alerts", "alert_rules", "inactivity_alerts", "privacy",
            "circle_invites", "alert_events", "place_shares",
            "web_push_subscriptions", "boundary_events",
            "destinations", "circle_notifications", "notification_history", "circle_activity",
            "blocked_people",
        ]
        XCTAssertEqual(DataExportService.stillOutstanding(all, after: nothing), [])
        XCTAssertEqual(all.count, 19)
    }

    func testAnswersFromBeforeTheSectionHaveNoneAndSayNoMoreFollows() throws {
        let older = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.8","location_count":0}}
        """#)
        XCTAssertNil(older.blockedPeople)
        XCTAssertFalse(older.metadata.blockedPeopleHasMore)
        XCTAssertNil(DataExportService.cursors(from: older)["cursor_blocked_person_id"])
        let file = TrackBackupFile.build(
            raw: older, decrypted: TrackBackupFile.Decrypted(),
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-10-07T10:00:00Z"
        )
        XCTAssertNil(file["blocked_people"], "absent, not empty: it was not served")
        let export = try XCTUnwrap(file["export"] as? [String: Any])
        let sections = try XCTUnwrap(export["sections"] as? [String: Any])
        XCTAssertNil(sections["blocked_people"])

        // An empty list is a section, with a count of none.
        let nobody = try decode(#"""
        {"metadata":{"user_id":"u","exported_day_bucket":1,"start_day_bucket":0,
         "end_day_bucket":1,"format_version":"1.9","location_count":0},"blocked_people":[]}
        """#)
        let empty = TrackBackupFile.build(
            raw: nobody, decrypted: TrackBackupFile.Decrypted(),
            pagesFetched: 1, isComplete: true,
            generatedAt: "2026-10-07T10:00:00Z"
        )
        XCTAssertEqual((empty["blocked_people"] as? [Any])?.count, 0)
    }

    // MARK: - Helper

    private func decode(_ json: String) throws -> DataExportResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DataExportResponse.self, from: Data(json.utf8))
    }
}
