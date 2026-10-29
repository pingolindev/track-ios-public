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

/// The Track backup file, as written on iOS.
///
/// THE FILE IS THE SAME ONE THE WEB AND ANDROID WRITE. Not "similar" — the same
/// key names in the same shape, because the whole point of a backup is that it
/// outlives the device that made it. A backup taken here restores on the web and
/// the other way round. That is why every key below is spelled out by hand in
/// snake_case: handing this to `JSONEncoder` with a camelCase model would emit
/// `radiusMeters` and produce a file only this client can read.
///
/// The Android app's Kotlin counterpart is `TrackBackupFile.kt`, and
/// the two are meant to stay readable against each other — same section order,
/// same envelope, same decisions about what is left out.
///
/// Values are DECRYPTED. The file is the user's own plaintext data, which is why
/// it is written to a location the user picks rather than into app storage.
///
/// WHAT IS NOT IN IT is deliberate: circle keys, and the encrypted alert targets
/// that stay encrypted because the server is blind to who a rule watches and a
/// plaintext copy on disk would undo that.
enum TrackBackupFile {

    static let product = "pingolin-track"
    static let generatedBy = "ios"

    struct Device {
        let id: String
        let name: String
        let platform: String?
        let registeredDayBucket: Int
    }

    struct Circle {
        let circleId: String
        let name: String
        let role: String
        let keyVersion: Int
        let joinedDayBucket: Int?
        /// Opened only with a key the export itself carried, never one this
        /// device holds: the server's word. Written as
        /// `"key_unverified": true`, the web's field, so every client's restore
        /// leaves the row out. The same on the three rows below.
        var keyUnverified = false
    }

    struct Place {
        let id: String
        let circleId: String?
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int
        let createdDayBucket: Int
        var keyUnverified = false
    }

    struct CheckIn {
        let id: String
        /// Optional for the same reason as `Place.circleId`: a check-in with no
        /// circle is a fact about the data, and the file records it as null
        /// rather than substituting the self-circle UUID it was DECRYPTED under.
        let circleId: String?
        let checkInType: String
        let message: String?
        let latitude: Double?
        let longitude: Double?
        let createdDayBucket: Int
        var keyUnverified = false
    }

    struct LocationRow {
        let deviceId: String
        let circleId: String
        let dayBucket: Int
        let timestamp: Int64?
        let latitude: Double
        let longitude: Double
        let accuracy: Double?
        let keyId: String
        /// Server-side insertion time, ms since epoch — the server's export
        /// field `inserted_at_ms`, straight through untouched.
        ///
        /// WITHOUT THIS THE HISTORY DOES NOT RESTORE. The web app's restore
        /// skips any point without a numeric `day_bucket` and `inserted_at_ms`,
        /// and sends the latter on to `/locations/restore` as the row's
        /// identity. Without the key every history point in a backup file is
        /// silently skipped, and the restore reports success with a history
        /// count of zero.
        ///
        /// Optional only to tolerate a backend that does not send the field;
        /// `LocationExportRow.insertedAtMs` is already `Int64?` for the same
        /// reason. Omitted from the file when nil rather than written as null,
        /// matching `timestamp` — a null fails web's guard exactly as an
        /// absent key does, and an absent key is the honest shape for "the
        /// server did not tell us".
        let insertedAtMs: Int64?
        /// The exporting row's own identifier — the server's export field
        /// `row_key`, carried through untouched.
        ///
        /// What makes restoring the same file twice a no-op. A restore re-seals
        /// every point with a FRESH NONCE, so deduplicating on the encrypted
        /// payload could never match, and a second restore would double the
        /// entire history. The server computes `row_key` over the row's
        /// ORIGINAL ciphertext — which the export throws away when it decrypts
        /// — so this is the only thing left that still identifies the source
        /// row, and it is stable across any number of restores.
        ///
        /// Optional to tolerate a backend that does not send the field;
        /// `LocationExportRow.rowKey` is already `String?` for the same reason.
        /// Omitted from the file when nil rather than written as an empty
        /// string: the server reads an absent key as "cannot dedupe, INSERT",
        /// which is the safe direction. An empty string would compare equal to
        /// every other keyless row and suppress real points.
        let rowKey: String?
        var keyUnverified = false
    }

    struct Decrypted {
        var devices: [Device]?
        var circles: [Circle]?
        var places: [Place]?
        var checkIns: [CheckIn]?
        var locations: [LocationRow]?
    }

    /// Build the file body.
    ///
    /// - Parameters:
    ///   - raw: the merged pages, for the config sections that pass through
    ///     untouched.
    ///   - decrypted: the same export with the encrypted fields opened.
    ///   - pagesFetched: how many requests it took, for the envelope.
    ///   - isComplete: whether the CLIENT finished paging. The server reports
    ///     completeness per page; what matters in the file is whether the loop
    ///     that wrote it ran to the end, because a file that stops early is the
    ///     failure this whole mechanism exists to prevent — and it is only
    ///     discovered at restore time.
    static func build(
        raw: DataExportResponse,
        decrypted: Decrypted,
        pagesFetched: Int,
        isComplete: Bool,
        generatedAt: String,
        incompleteReason: String? = nil
    ) -> [String: Any] {
        var root: [String: Any] = [:]
        var sections: [String: Any] = [:]

        root["metadata"] = [
            "user_id": raw.metadata.userId,
            "exported_day_bucket": raw.metadata.exportedDayBucket,
            "start_day_bucket": raw.metadata.startDayBucket,
            "end_day_bucket": raw.metadata.endDayBucket,
            "format_version": raw.metadata.formatVersion,
            "location_count": raw.metadata.locationCount,
        ]

        if let list = decrypted.devices {
            root["devices"] = list.map { device($0) }
            sections["devices"] = list.count
        }
        if let list = decrypted.circles {
            root["circles"] = list.map { circle($0) }
            sections["circles"] = list.count
        }
        if let list = decrypted.places {
            root["places"] = list.map { place($0) }
            sections["places"] = list.count
        }
        if let list = decrypted.checkIns {
            root["check_ins"] = list.map { checkIn($0) }
            sections["check_ins"] = list.count
        }
        if let list = decrypted.locations {
            root["locations"] = list.map { location($0) }
            sections["locations"] = list.count
        }

        // Config sections pass through as they arrived. They are the part a
        // restore can actually put back, and they are already plaintext apart
        // from the encrypted target ids — which stay encrypted deliberately.
        //
        // Copied BY NAME, section by section: building the file from a fixed
        // list rather than by spreading the response is what stops a section
        // this build does not understand from leaking an unreadable blob into a
        // file the user believes is readable. Adding an export section means
        // adding it here too.
        if let v = raw.alerts {
            root["alerts"] = v.map { $0.anyValue }
            sections["alerts"] = v.count
        }
        if let v = raw.alertRules {
            root["alert_rules"] = v.map { $0.anyValue }
            sections["alert_rules"] = v.count
        }
        if let v = raw.inactivityAlerts {
            root["inactivity_alerts"] = v.map { $0.anyValue }
            sections["inactivity_alerts"] = v.count
        }
        if let v = raw.privacy {
            root["privacy"] = v.map { $0.anyValue }
            sections["privacy"] = v.count
        }
        if let v = raw.preferences {
            root["preferences"] = v.anyValue
        }

        // Further sections, copied the same way. Plaintext apart from the
        // boundary events' two sealed fields and the place shares' wrapped key,
        // both of which stay sealed: the first because this path has no
        // place-key unwrap, the second because it is key material rather than
        // content and does not belong in a readable file.
        if let v = raw.profile {
            root["profile"] = v.anyValue
            sections["profile"] = 1
        }
        if let v = raw.circleInvites {
            root["circle_invites"] = v.map { $0.anyValue }
            sections["circle_invites"] = v.count
        }
        if let v = raw.alertEvents {
            root["alert_events"] = v.map { $0.anyValue }
            sections["alert_events"] = v.count
        }
        if let v = raw.placeShares {
            root["place_shares"] = v.map { $0.anyValue }
            sections["place_shares"] = v.count
        }
        if let v = raw.webPushSubscriptions {
            root["web_push_subscriptions"] = v.map { $0.anyValue }
            sections["web_push_subscriptions"] = v.count
        }
        if let v = raw.boundaryEvents {
            root["boundary_events"] = v.map { $0.anyValue }
            sections["boundary_events"] = v.count
        }
        if let v = raw.destinations {
            root["destinations"] = v.map { $0.anyValue }
            sections["destinations"] = v.count
        }
        if let v = raw.circleNotifications {
            root["circle_notifications"] = v.map { $0.anyValue }
            sections["circle_notifications"] = v.count
        }
        if let v = raw.notificationHistory {
            root["notification_history"] = v.map { $0.anyValue }
            sections["notification_history"] = v.count
        }
        if let v = raw.circleActivity {
            root["circle_activity"] = v.map { $0.anyValue }
            sections["circle_activity"] = v.count
        }
        // Format 1.9: the addresses blocked from inviting this account, as its own list shows them.
        if let v = raw.blockedPeople {
            root["blocked_people"] = v.map { $0.anyValue }
            sections["blocked_people"] = v.count
        }

        var envelope: [String: Any] = [
            "format_version": raw.metadata.formatVersion,
            "product": product,
            "generated_at": generatedAt,
            "generated_by": generatedBy,
            "pages_fetched": pagesFetched,
            "is_complete": isComplete,
            "sections": sections,
        ]
        if let reason = incompleteReason {
            envelope["incomplete_reason"] = reason
        }
        root["export"] = envelope

        return root
    }

    /// Serialise to the bytes that get written. Sorted and pretty-printed to
    /// match what the other two clients produce, so the files diff against each
    /// other rather than only against themselves.
    static func encode(_ file: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: file,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Rows

    private static func device(_ d: Device) -> [String: Any] {
        var o: [String: Any] = [
            "id": d.id,
            "name": d.name,
            "day_bucket": d.registeredDayBucket,
        ]
        o["device_type"] = d.platform ?? NSNull()
        return o
    }

    private static func circle(_ c: Circle) -> [String: Any] {
        var o: [String: Any] = [
            "circle_id": c.circleId,
            "name": c.name,
            "role": c.role,
            "key_version": c.keyVersion,
        ]
        o["joined_day_bucket"] = c.joinedDayBucket ?? NSNull()
        // Only when set, as the web writes it. See `Circle.keyUnverified`.
        if c.keyUnverified { o["key_unverified"] = true }
        return o
    }

    private static func place(_ p: Place) -> [String: Any] {
        var o: [String: Any] = [
            "id": p.id,
            "name": p.name,
            // Nested, matching web and Android: the location is whatever JSON
            // the writer sealed, and a restore reads latitude/longitude back
            // out of it.
            "location": ["latitude": p.latitude, "longitude": p.longitude],
            "radius_meters": p.radiusMeters,
            "created_day_bucket": p.createdDayBucket,
        ]
        o["circle_id"] = p.circleId ?? NSNull()
        // The field the web client's restore skips a place on.
        if p.keyUnverified { o["key_unverified"] = true }
        return o
    }

    private static func checkIn(_ c: CheckIn) -> [String: Any] {
        var o: [String: Any] = [
            "id": c.id,
            "check_in_type": c.checkInType,
            "created_day_bucket": c.createdDayBucket,
        ]
        // Explicit NSNull, exactly as `place` does. NOT `if let`: the two are
        // different files, and the difference matters to a restore. `message`
        // and `location` below are absent when unset because "no message" and
        // "a message we could not decrypt" are the same to a reader either way;
        // a circle is not — absent would read as "this export predates the
        // field", and null says "this check-in belongs to no circle".
        //
        // The `?? NSNull()` is for legibility rather than correctness:
        // JSONSerialization does bridge a nil Optional here, so the shorter
        // form encodes the same bytes. Written out because the reader of this
        // line should not have to know that.
        o["circle_id"] = c.circleId ?? NSNull()
        if let m = c.message { o["message"] = m }
        if let lat = c.latitude, let lon = c.longitude {
            o["location"] = ["latitude": lat, "longitude": lon]
        }
        if c.keyUnverified { o["key_unverified"] = true }
        return o
    }

    private static func location(_ l: LocationRow) -> [String: Any] {
        var inner: [String: Any] = ["latitude": l.latitude, "longitude": l.longitude]
        if let a = l.accuracy { inner["accuracy"] = a }
        var o: [String: Any] = [
            "device_id": l.deviceId,
            "circle_id": l.circleId,
            "day_bucket": l.dayBucket,
            "key_id": l.keyId,
            "location": inner,
        ]
        if let t = l.timestamp { o["timestamp"] = t }
        // The key web's restore refuses to proceed without. See
        // `LocationRow.insertedAtMs`.
        if let ms = l.insertedAtMs { o["inserted_at_ms"] = ms }
        // What makes a second restore of this file a no-op rather than a
        // doubled history. See `LocationRow.rowKey`.
        if let rk = l.rowKey { o["row_key"] = rk }
        if l.keyUnverified { o["key_unverified"] = true }
        return o
    }
}
