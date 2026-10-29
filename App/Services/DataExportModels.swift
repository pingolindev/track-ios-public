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

/// Wire models for GET /api/v1/export.
///
/// Field names are decoded with `.convertFromSnakeCase`, matching the rest of
/// APIService, so `check_ins` arrives as `checkIns` without explicit keys.
///
/// Every truncation flag and every count defaults, so a response from a server
/// older than this build still decodes. An export that throws because the server
/// is older is indistinguishable to the user from an export that failed, and
/// this screen must tell the truth about whether it worked.

struct ExportMetadataResponse: Codable {
    let userId: String
    let exportedDayBucket: Int
    let startDayBucket: Int
    let endDayBucket: Int
    let formatVersion: String
    let locationCount: Int

    // Per-section truncation flags (format 1.1+). A section that merely LIMITs
    // cannot tell a full page from a truncated one, and a short export is only
    // discovered at restore time — when it is far too late.
    var devicesHasMore: Bool = false
    var circlesHasMore: Bool = false
    var placesHasMore: Bool = false
    var checkInsHasMore: Bool = false
    var locationsHasMore: Bool = false
    var alertsHasMore: Bool = false
    var alertRulesHasMore: Bool = false
    var inactivityAlertsHasMore: Bool = false
    var privacyHasMore: Bool = false
    var circleInvitesHasMore: Bool = false
    var alertEventsHasMore: Bool = false
    var placeSharesHasMore: Bool = false
    var webPushSubscriptionsHasMore: Bool = false
    var boundaryEventsHasMore: Bool = false
    var destinationsHasMore: Bool = false
    var circleNotificationsHasMore: Bool = false
    var notificationHistoryHasMore: Bool = false
    var circleActivityHasMore: Bool = false
    /// Format 1.9, "Blocked people". False whenever the section was not asked for.
    var blockedPeopleHasMore: Bool = false
    /// False when ANY section still has data to fetch.
    var isComplete: Bool = true

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        exportedDayBucket = try c.decodeIfPresent(Int.self, forKey: .exportedDayBucket) ?? 0
        startDayBucket = try c.decodeIfPresent(Int.self, forKey: .startDayBucket) ?? 0
        endDayBucket = try c.decodeIfPresent(Int.self, forKey: .endDayBucket) ?? 0
        formatVersion = try c.decodeIfPresent(String.self, forKey: .formatVersion) ?? "1.0"
        locationCount = try c.decodeIfPresent(Int.self, forKey: .locationCount) ?? 0
        devicesHasMore = try c.decodeIfPresent(Bool.self, forKey: .devicesHasMore) ?? false
        circlesHasMore = try c.decodeIfPresent(Bool.self, forKey: .circlesHasMore) ?? false
        placesHasMore = try c.decodeIfPresent(Bool.self, forKey: .placesHasMore) ?? false
        checkInsHasMore = try c.decodeIfPresent(Bool.self, forKey: .checkInsHasMore) ?? false
        locationsHasMore = try c.decodeIfPresent(Bool.self, forKey: .locationsHasMore) ?? false
        alertsHasMore = try c.decodeIfPresent(Bool.self, forKey: .alertsHasMore) ?? false
        alertRulesHasMore = try c.decodeIfPresent(Bool.self, forKey: .alertRulesHasMore) ?? false
        inactivityAlertsHasMore = try c.decodeIfPresent(Bool.self, forKey: .inactivityAlertsHasMore) ?? false
        privacyHasMore = try c.decodeIfPresent(Bool.self, forKey: .privacyHasMore) ?? false
        circleInvitesHasMore = try c.decodeIfPresent(Bool.self, forKey: .circleInvitesHasMore) ?? false
        alertEventsHasMore = try c.decodeIfPresent(Bool.self, forKey: .alertEventsHasMore) ?? false
        placeSharesHasMore = try c.decodeIfPresent(Bool.self, forKey: .placeSharesHasMore) ?? false
        webPushSubscriptionsHasMore = try c.decodeIfPresent(Bool.self, forKey: .webPushSubscriptionsHasMore) ?? false
        boundaryEventsHasMore = try c.decodeIfPresent(Bool.self, forKey: .boundaryEventsHasMore) ?? false
        destinationsHasMore = try c.decodeIfPresent(Bool.self, forKey: .destinationsHasMore) ?? false
        circleNotificationsHasMore = try c.decodeIfPresent(Bool.self, forKey: .circleNotificationsHasMore) ?? false
        notificationHistoryHasMore = try c.decodeIfPresent(Bool.self, forKey: .notificationHistoryHasMore) ?? false
        circleActivityHasMore = try c.decodeIfPresent(Bool.self, forKey: .circleActivityHasMore) ?? false
        blockedPeopleHasMore = try c.decodeIfPresent(Bool.self, forKey: .blockedPeopleHasMore) ?? false
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
    }
}

struct DeviceExportRow: Codable {
    let id: String
    /// Always an empty placeholder — the server does not store a device name.
    let encryptedName: EncryptedPayloadResponse?
    /// Push channel for this row (fcm, apns, webpush, direct).
    let deviceType: String?
    let dayBucket: Int?
    /// Registration time in ms. `dayBucket` is too coarse to page on — many rows
    /// share one — so this is the device cursor's key.
    let createdAtMs: Int64?
}

struct CircleMembershipExportRow: Codable {
    let circleId: String
    let encryptedName: EncryptedPayloadResponse?
    let role: String?
    /// The circle key, wrapped to this user. An export is often the first time a
    /// device sees a given circle — the row carries its own key so the name can
    /// be opened without a separate sync.
    let encryptedCircleKey: EncryptedPayloadResponse?
    let ephemeralPublicKey: String?
    let keyVersion: Int?
    /// Nullable server-side, and the query orders a NULL bucket as 0, so the
    /// cursor must mirror that or rows are skipped.
    let joinedDayBucket: Int?
}

struct PlaceExportRow: Codable {
    let id: String
    let circleId: String?
    let encryptedName: EncryptedPayloadResponse?
    let encryptedLocation: EncryptedPayloadResponse?
    let radiusMeters: Int?
    let createdDayBucket: Int?
    /// Owner-side wrap of the per-place key under the self key. Present on every
    /// personal place; absent on legacy circle-owned rows whose fields
    /// are encrypted under the circle key directly. Without it, personal places
    /// would export undecryptable — the key is nowhere else in the file.
    let wrappedKey: String?
    let wrappedKeyNonce: String?
}

struct CheckInExportRow: Codable {
    let id: String
    /// NULL on a check-in that belongs to no circle: one made personally, or one
    /// whose circle was later deleted. Non-optional, `Codable` would THROW on the
    /// whole page — not just this row — so an account with one personal check-in
    /// could not export at all. `PlaceExportRow.circleId` is optional for the
    /// same reason.
    let circleId: String?
    let checkInType: String?
    let encryptedMessage: EncryptedPayloadResponse?
    let encryptedLocation: EncryptedPayloadResponse?
    let createdDayBucket: Int?
}

struct LocationExportRow: Codable {
    let deviceId: String?
    let circleId: String
    let dayBucket: Int?
    let encryptedTimestamp: EncryptedPayloadResponse?
    let encryptedPayload: EncryptedPayloadResponse
    let keyId: String?
    /// Second part of the locations cursor.
    let insertedAtMs: Int64?
    /// Row discriminator. `inserted_at` is assigned per insert BATCH, so many
    /// rows share one value and (day_bucket, inserted_at) is not a total order:
    /// without this, every row tied with the last of a page is skipped.
    let rowKey: String?
}

/// One page of the export.
///
/// The config sections (alerts, alert rules, inactivity alerts, privacy,
/// preferences) are held as raw JSON rather than typed models. This client only
/// carries them into the written file, and a typed model here would silently
/// drop any field it predates — the file is supposed to outlive the build that
/// wrote it.
struct DataExportResponse: Codable {
    let metadata: ExportMetadataResponse
    let devices: [DeviceExportRow]?
    let circles: [CircleMembershipExportRow]?
    let places: [PlaceExportRow]?
    let checkIns: [CheckInExportRow]?
    let locations: [LocationExportRow]?
    let alerts: [JSONValue]?
    let alertRules: [JSONValue]?
    let inactivityAlerts: [JSONValue]?
    let privacy: [JSONValue]?
    /// Singleton — both underlying tables are keyed by user_id alone.
    let preferences: JSONValue?
    /// Six sections the server sends by default. Undeclared, they would be
    /// dropped by Codable without complaint, since an absent field decodes to
    /// nil. Carried as JSONValue because the file writes them through
    /// unchanged — they are plaintext apart from the boundary events' two
    /// sealed fields and the place shares' wrapped key, both of which stay
    /// sealed deliberately.
    let profile: JSONValue?
    let circleInvites: [JSONValue]?
    let alertEvents: [JSONValue]?
    let placeShares: [JSONValue]?
    let webPushSubscriptions: [JSONValue]?
    let boundaryEvents: [JSONValue]?
    let destinations: [JSONValue]?
    let circleNotifications: [JSONValue]?
    let notificationHistory: [JSONValue]?
    let circleActivity: [JSONValue]?
    /// Format 1.9, "Blocked people": the addresses whose owners may not invite
    /// this account to a circle, as its own list shows them. The server
    /// serves it ONLY WHEN ASKED FOR (`include_blocked_people=true`), unlike
    /// every other section: nil here means it was not asked for, or the
    /// server is from before it.
    let blockedPeople: [JSONValue]?
}

/// A value of any JSON shape, carried through untouched.
///
/// Exists so the config sections survive a round trip without this build having
/// to know their schema. `Codable` synthesis cannot do that; an explicit
/// enum can.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrepresentable JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    /// Foundation representation, for JSONSerialization when writing the file.
    var anyValue: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() && abs(v) < 9_007_199_254_740_992 ? Int(v) : v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.anyValue }
        case .array(let v): return v.map { $0.anyValue }
        case .null: return NSNull()
        }
    }

    /// The `id`-ish field of an object, for cursor extraction.
    func string(_ key: String) -> String? {
        if case .object(let o) = self, case .string(let s)? = o[key] { return s }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if case .object(let o) = self, case .number(let n)? = o[key] { return Int64(n) }
        return nil
    }
}
