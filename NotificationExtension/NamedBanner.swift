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
import os
import PingolinTrackSDK
#if TRACK_TESTS
// The unit tests compile this file too, and reach the rules it shares with the
// app (`AccessHandover`, `NamedNotificationCopy` and the rest) through the app
// module.
@testable import Track
#endif

/// Names a check-in or a place alert on its banner, from this device's own
/// data.
///
/// The push names only the recipient's notification ROW (`notification_id`);
/// the row, fetched over the app's own connection, says which circle, who — by
/// id for a crossing, sealed by the sender for a check-in — and where
/// (`place_id`). The person is named only when the app's own roster pass shows
/// them (`AccessHandover.rosterPass`, as for an alarm's raiser) and their
/// sealed name opens here (`SOSCheck.openedName`): never the plaintext name the
/// server sends for older clients. The place only when its name opens here;
/// nothing else is fetched for it. `NamedNotificationCopy` has the words, at
/// the user's detail level.
///
/// The follow-ups to a request to be checked on name who is responding and who
/// closed it, by the same rule (`followUp`).
///
/// Read-only, and nothing is kept: no name is written anywhere, so no names
/// file sits in the app group. Generic level, no row id (an older server), no
/// session, keys unreadable (before the first unlock), or out of time: nil, and
/// the banner keeps the server's words.
enum NamedBanner {
    static let log = Logger(subsystem: "com.pingolin.track.NotificationExtension", category: "named")

    /// The whole naming, inside the extension's ~30 s; every request at most
    /// 8 s (`HandoverClient`).
    static let budget: TimeInterval = 10

    /// The pushes it names, by `alert_type`: a crossing (the server sends
    /// the directional pair; the row itself is "place_alert") and a
    /// check-in.
    static let placeAlertTypes: Set<String> = ["place_alert", "place_alert_enter", "place_alert_exit"]
    static let checkInType = "check_in"

    static func handles(_ alertType: String) -> Bool {
        placeAlertTypes.contains(alertType) || alertType == checkInType
    }

    /// The banner's words once named, and the row's circle.
    struct Named: Equatable {
        var title: String
        var body: String?
        var circleId: String
    }

    /// What naming takes: the signed-in account, its keys, and a client on
    /// the app's own connection.
    struct Session {
        let api: HandoverClient
        let me: String
        let shared: UserDefaults
        let crypto: PingolinTrackSDK.CryptoManager
    }

    /// The session: the app's token, refreshed behind the app's own lock when
    /// it has run out, for the account the app group says is signed in.
    static func session(deadline: Date, env: BackgroundHandover.Environment) async -> Session? {
        guard var token = env.accessToken(), TokenClaims(token) != nil else { return nil }
        if let expires = TokenClaims(token)?.expiresAt, expires <= env.now().addingTimeInterval(30) {
            guard let fresh = await env.refreshedToken(), TokenClaims(fresh) != nil else { return nil }
            token = fresh
        }
        guard let claims = TokenClaims(token), let me = env.keychainUserId().flatMap({ CanonicalId.of($0) }),
              CanonicalId.of(claims.subject) == me, let shared = env.shared(),
              let bridged = shared.string(forKey: ExtensionBridgeKeys.accountUserId), CanonicalId.of(bridged) == me,
              let base = shared.string(forKey: ExtensionBridgeKeys.apiBaseURL) else { return nil }
        guard let crypto = env.makeCrypto() else {
            log.info("named: keys not readable (before first unlock?)")
            return nil
        }
        let api = HandoverClient(base: base, token: token, transport: env.transport, deadline: deadline, now: env.now)
        return Session(api: api, me: me, shared: shared, crypto: crypto)
    }

    static func run(alertType: String, notificationId: String?, level: String?, deadline: Date,
                    env: BackgroundHandover.Environment) async -> Named? {
        let detail = NamedNotificationCopy.Detail(level: level)
        guard detail != .generic, handles(alertType), let rowId = CanonicalId.of(notificationId),
              let session = await session(deadline: deadline, env: env) else { return nil }
        let (api, me, shared, crypto) = (session.api, session.me, session.shared, session.crypto)

        // The row the push names, and only a row of the push's own kind.
        let fetched: HandoverClient.Fetched<NotificationRow> = await api.fetch("/api/v1/notifications/\(rowId)")
        let kind = alertType == checkInType ? "check_in" : "place_alert"
        guard case .value(let row) = fetched, row.notificationType == kind,
              let circleId = CanonicalId.circle(row.circleId), let title = row.title else {
            log.info("named: no row of its kind")
            return nil
        }

        var names = NamedNotificationCopy.Names()
        let person = kind == "place_alert"
            ? row.metadata?.targetUserId
            : openedSender(row.metadata, circleId: circleId, crypto: crypto)
        if let person {
            if person == me {
                names.personIsMe = true
            } else {
                names.person = await memberName(person, circleId: circleId, me: me, shared: shared, env: env,
                                                api: api, crypto: crypto)
            }
        }
        if detail == .full, let placeId = row.metadata?.placeId {
            names.place = await placeName(placeId, api: api, crypto: crypto)
        }
        guard let words = NamedNotificationCopy.row(type: kind, title: title, body: row.body, names: names,
                                                    level: level) else { return nil }
        return Named(title: words.title, body: words.body, circleId: circleId)
    }

    /// The first page of the account's notifications, newest first, as much
    /// as finding a row needs. A row naming someone by no id is dropped.
    struct RowList: Decodable {
        let notifications: [NotificationRow]

        private enum CodingKeys: String, CodingKey {
            case notifications
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notifications = try container.decode(ServedEntries<NotificationRow>.self, forKey: .notifications).items
        }
    }

    /// The newest rows a follow-up's own row is looked for among. The
    /// server writes its row just before it sends its push.
    static let followUpRows = 20

    /// A follow-up to a request to be checked on, told to the
    /// person who asked: who is responding (`acknowledged_by`, a row per
    /// responder) and who closed it (`closed_by`, on their row alone, when
    /// someone else did). The push names only the alert (`alert_id`), so its
    /// row is the newest of its kind for that alert; the responders on that
    /// alert's older rows are the others. With its key, the banner says what
    /// the inbox row says: named as `memberName` allows, else "Someone". A row
    /// without one (older, or another member's "resolved" row) keeps the
    /// server's words.
    static func followUp(alertType: String, alertId: String?, level: String?, deadline: Date,
                         env: BackgroundHandover.Environment) async -> Named? {
        guard NamedNotificationCopy.Detail(level: level) != .generic,
              SOSAlarmCopy.followUpTypes.contains(alertType), let alertId = CanonicalId.of(alertId),
              let session = await session(deadline: deadline, env: env) else { return nil }
        let fetched: HandoverClient.Fetched<RowList> = await session.api.fetch(
            "/api/v1/notifications", query: ["limit": String(followUpRows)])
        guard case .value(let list) = fetched else { return nil }
        let rows = list.notifications.filter { $0.notificationType == alertType && $0.metadata?.sosId == alertId }
        guard let row = rows.first, let circleId = CanonicalId.circle(row.circleId), let title = row.title else {
            log.info("named: no follow-up row")
            return nil
        }

        let responding = alertType == "sos_acknowledged"
        guard let person = responding ? row.metadata?.acknowledgedBy : row.metadata?.closedBy else {
            log.info("named: follow-up row names nobody")
            return nil
        }
        var names = NamedNotificationCopy.Names()
        names.personClosed = !responding
        if responding {
            let before = Set(rows.dropFirst().compactMap { $0.metadata?.acknowledgedBy })
            names.others = before.subtracting([person]).count
        }
        if person == session.me {
            names.personIsMe = true
        } else {
            names.person = await memberName(person, circleId: circleId, me: session.me, shared: session.shared,
                                            env: env, api: session.api, crypto: session.crypto)
        }
        let words = NamedNotificationCopy.row(type: alertType, title: title, body: row.body, names: names,
                                              level: level) ?? (title: title, body: row.body)
        return Named(title: words.title, body: words.body, circleId: circleId)
    }

    /// Who checked in: the id the sender sealed with the circle key (field tag
    /// "user_id"), opened here.
    static func openedSender(_ metadata: NotificationRow.Metadata?, circleId: String,
                             crypto: PingolinTrackSDK.CryptoManager) -> String? {
        guard let sealed = metadata?.encryptedUserId, let nonce = metadata?.userIdNonce,
              !sealed.isEmpty, !nonce.isEmpty else { return nil }
        return CanonicalId.of(try? crypto.decryptDataV2(
            circleId: circleId, encryptedData: EncryptedData(nonce: nonce, ciphertext: sealed), fieldTag: "user_id"))
    }

    /// `person`'s name in `circleId`, the way the app names a member: someone
    /// this device's own roster pass shows (confirmed), by the sealed
    /// name that opens here. This device's approval record for the circle is
    /// read, never written.
    static func memberName(_ person: String, circleId: String, me: String, shared: UserDefaults,
                           env: BackgroundHandover.Environment, api: HandoverClient,
                           crypto: PingolinTrackSDK.CryptoManager) async -> String? {
        guard case .record(let stored) = ApprovalRecordStore.stored(
                  in: shared, owner: me, circleId: circleId, deviceTag: env.deviceTag()),
              let email = shared.string(forKey: ExtensionBridgeKeys.accountEmail) else { return nil }
        let roster: HandoverClient.Fetched<Page<CircleMemberResponse>> = await api.fetch(
            "/api/v1/circles/\(circleId)/members", query: ["limit": "100"])
        guard case .value(let page) = roster else { return nil }
        let decided = AccessHandover.rosterPass(
            circleId: circleId, me: .own(userId: me, email: email, crypto: crypto), roster: page.items,
            rosterComplete: page.hasMore != true,
            activeVersion: (try? crypto.getActiveVersion(circleId: circleId)).map { Int($0) },
            stored: stored, checker: crypto, now: env.now())
        guard let row = page.items.first(where: { CanonicalId.same($0.userId, person) }),
              decided.result.verdicts[row.userId]?.isShown == true else { return nil }
        return SOSCheck.openedName(row, circleId: circleId, crypto: crypto)
    }

    /// A served place, as much as naming it needs (`GET /api/v1/places`).
    struct PlaceRow: Decodable {
        let id: String
        let circleId: String?
        let encryptedName: EncryptedBlobResponse
        let wrappedKey: String?
        let wrappedKeyNonce: String?
        let wrapViaCircle: String?
    }

    /// The name of place `placeId` when it opens here: from one page of the
    /// account's places (the app's own read), its key unwrapped the way the app
    /// does (`PlaceManager.decodePlaces`: shared places through their circle,
    /// one's own through the personal key; an older place sealed straight
    /// under the circle key). Not listed or not opening: nil.
    static func placeName(_ placeId: String, api: HandoverClient,
                          crypto: PingolinTrackSDK.CryptoManager) async -> String? {
        let fetched: HandoverClient.Fetched<[PlaceRow]> = await api.fetch(
            "/api/v1/places", query: ["limit": "100", "offset": "0"])
        guard case .value(let places) = fetched,
              let place = places.first(where: { CanonicalId.same($0.id, placeId) }) else { return nil }
        let target = place.wrapViaCircle ?? place.circleId ?? CanonicalId.personalSlot
        let sealed = EncryptedData(nonce: place.encryptedName.nonce, ciphertext: place.encryptedName.ciphertext)
        let name: String?
        if let wrappedKey = place.wrappedKey, let wrappedKeyNonce = place.wrappedKeyNonce {
            guard let key = try? crypto.unwrapPlaceKey(
                targetId: target, wrappedKey: wrappedKey, wrappedKeyNonce: wrappedKeyNonce) else { return nil }
            name = try? crypto.decryptWithPlaceKeyV2(placeKeyHex: key, encryptedData: sealed, fieldTag: "name")
        } else {
            name = try? crypto.decryptDataV2(circleId: target, encryptedData: sealed, fieldTag: "name")
        }
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}
