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
import UserNotifications
import PingolinTrackSDK
@testable import Track

/// Names in notifications, filled in by the app itself: the inbox rows
/// (`NotificationNames`) and the extension's check-in and crossing banners
/// (`NamedBanner`), in `NamedNotificationCopy`'s words.
///
/// Rows and pushes as the server writes them (the check-in metadata,
/// `notification_id`), real keys and sealed names; the network is a stub, the
/// app group a scratch suite.
final class NamedNotificationsTests: XCTestCase {
    private let circleId = "a7a70000-0000-4000-8000-0000000000c1"
    private let rowId = "a7a70000-0000-4000-8000-0000000000e1"
    private let placeId = "a7a70000-0000-4000-8000-0000000000d1"
    private let base = "https://track.test"
    private let now = Date()

    // MARK: - The words

    private func row(_ type: String, title: String, body: String? = nil, _ names: NamedNotificationCopy.Names,
                     level: String? = "full") -> (title: String, body: String?)? {
        NamedNotificationCopy.row(type: type, title: title, body: body, names: names, level: level)
    }

    private let arrived = "Member arrived at a place"
    private let left = "Member left a place"

    func testACrossingSaysWhoAndWhereAsTheAppsOwnAlertDoes() throws {
        let olivia = NamedNotificationCopy.Names(person: "Olivia", place: "Home")
        XCTAssertEqual(try XCTUnwrap(row("place_alert", title: arrived, olivia)).title, "Arrival")
        XCTAssertEqual(row("place_alert", title: arrived, olivia)?.body, "Olivia arrived at Home")
        XCTAssertEqual(row("place_alert", title: left, olivia)?.title, "Departure")
        XCTAssertEqual(row("place_alert", title: left, olivia)?.body, "Olivia left Home")
        XCTAssertEqual(row("place_alert", title: arrived, olivia, level: "names")?.body, "Olivia arrived at a place",
                       "names only never says where")
        XCTAssertNil(row("place_alert", title: arrived, olivia, level: "generic"), "generic: the server's words")
        XCTAssertEqual(row("place_alert", title: arrived, .init(personIsMe: true, place: "Home"))?.body,
                       "You arrived at Home")
        XCTAssertEqual(row("place_alert", title: arrived, .init(place: "Home"))?.body, "A member arrived at Home")
        XCTAssertNil(row("place_alert", title: arrived, .init()), "nothing to add")
        XCTAssertNil(row("place_alert", title: arrived, .init(place: "Home"), level: "names"),
                     "names only, and nobody named: nothing to add")
        XCTAssertNil(row("place_alert", title: "Something else", olivia), "a title the server doesn't write")
        XCTAssertEqual(row("place_alert", title: arrived, .init(person: "", place: ""))?.body, nil,
                       "an empty name is no name")
    }

    func testACheckInSaysWhoInTheServersOwnSentence() {
        let olivia = NamedNotificationCopy.Names(person: "Olivia", place: "Home")
        // The server's three check-in bodies, and an older row's.
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member has checked in.", olivia)?.body,
                       "Olivia has checked in at Home.")
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member has checked in safely.", olivia)?.body,
                       "Olivia has checked in safely at Home.")
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member has confirmed they are OK.",
                           olivia)?.body, "Olivia has confirmed they are OK.")
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member checked in (emergency_ok)",
                           olivia)?.body, "Olivia has confirmed they are OK.")
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member has checked in.", olivia)?.title,
                       "Check-in")
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member has checked in safely.", olivia,
                           level: "names")?.body, "Olivia has checked in safely.")
        XCTAssertEqual(row("check_in", title: "Check-in", body: "A circle member has checked in.",
                           .init(place: "Home"))?.body, "A member has checked in at Home.")
        XCTAssertNil(row("check_in", title: "Check-in", body: "A circle member has confirmed they are OK.",
                         .init(place: "Home")), "nobody named, and that sentence names no place")
        XCTAssertNil(row("check_in", title: "Check-in", body: "Somebody did something", olivia))
        XCTAssertNil(row("check_in", title: "Check-in", body: "A circle member has checked in.", olivia,
                         level: "generic"))
        XCTAssertNil(row("check_in", title: "Check-in", body: "A circle member has checked in.",
                         .init(personIsMe: true)), "nobody gets a row for their own check-in")
    }

    func testTheOtherRowsSayWhoInTheAppsWords() {
        let olivia = NamedNotificationCopy.Names(person: "Olivia", circle: "Family")
        // The alarm's own words (SOSAlarmCopy), so the row matches its banner.
        let raised = row("sos_alert", title: "Someone needs attention",
                         body: "A circle member asked their circle to check on them", olivia)
        XCTAssertEqual(raised?.title, "Olivia needs attention")
        XCTAssertEqual(raised?.body, "Asked their circle to check on them in Family")
        XCTAssertEqual(row("sos_alert", title: "Someone needs attention", olivia, level: "names")?.body,
                       "Olivia needs attention")
        XCTAssertNil(row("sos_alert", title: "Someone needs attention", .init(circle: "Family")))
        XCTAssertEqual(row("sos_resolved", title: "Alert resolved", olivia)?.body,
                       "Olivia's request to be checked on was marked resolved")
        XCTAssertEqual(row("sos_resolved", title: "Alert resolved", .init(personIsMe: true))?.body,
                       "Your request to be checked on was marked resolved")
        XCTAssertNil(row("sos_acknowledged", title: "Someone is responding", .init()),
                     "an older row that names nobody keeps the server's words")

        let joined = "Someone joined a circle you are in. They can see its location history."
        XCTAssertEqual(row("member_joined", title: "New circle member", body: joined, olivia)?.body,
                       "Olivia joined Family. They can see its location history.")
        XCTAssertEqual(row("member_joined", title: "New circle member", body: joined, olivia, level: "names")?.body,
                       "Olivia joined your circle. They can see its location history.")
        XCTAssertNil(row("member_joined", title: "New circle member", body: joined, .init(circle: "Family")))

        let others = "This circle has a new owner. The previous owner did not respond to a request to take it over."
        let former = "You did not respond to the request, so this circle has been transferred to an admin."
        XCTAssertEqual(row("circle_ownership_transferred", title: "Circle ownership changed", body: others, olivia)?.body,
                       "Olivia is now this circle's owner. The previous owner did not respond to a request to take it over.")
        XCTAssertEqual(row("circle_ownership_transferred", title: "Circle ownership changed", body: former, olivia)?.body,
                       "You did not respond to the request, so this circle has been transferred to Olivia.")
        XCTAssertEqual(row("circle_ownership_transferred", title: "Circle ownership changed", body: others,
                           .init(personIsMe: true))?.body,
                       "You are now this circle's owner. The previous owner did not respond to a request to take it over.")
        let claim = row("circle_ownership_claim", title: "Someone asked to take over your circle",
                        body: "Open Pingolin to refuse.", olivia)
        XCTAssertEqual(claim?.title, "Olivia asked to take over your circle")
        XCTAssertEqual(claim?.body, "Open Pingolin to refuse.")
        XCTAssertNil(row("destination_arrival", title: "Arrived", olivia), "not a type this names")
    }

    /// Never "SOS" in anything a person reads.
    func testNoSentenceSaysSOS() {
        let everyone: [NamedNotificationCopy.Names] = [
            .init(person: "Olivia", place: "Home", circle: "Family"), .init(personIsMe: true), .init(place: "Home"),
        ]
        for type in NamedNotificationCopy.namedTypes {
            for names in everyone {
                for level in ["full", "names", "generic", nil] {
                    for body in ["A circle member has checked in safely.", "You did not respond", nil] {
                        guard let words = row(type, title: arrived, body: body, names, level: level) else { continue }
                        XCTAssertFalse("\(words.title) \(words.body ?? "")".localizedCaseInsensitiveContains("SOS"),
                                       "\(type): \(words)")
                    }
                }
            }
        }
    }

    // MARK: - Keys, as members' phones hold them

    private final class Storage: KeyStorageCallback, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredKeyData?
        init(_ data: StoredKeyData? = nil) { stored = data }
        var data: StoredKeyData? { lock.lock(); defer { lock.unlock() }; return stored }
        func loadKeys() throws -> StoredKeyData? { data }
        func storeKeys(data: StoredKeyData) throws { lock.lock(); stored = data; lock.unlock() }
        func deleteKeys() throws { lock.lock(); stored = nil; lock.unlock() }
    }

    private static func hex(_ b64: String) -> String {
        Data(base64Encoded: b64)!.map { String(format: "%02x", $0) }.joined()
    }

    private struct Party {
        let userId: String
        let name: String
        let storage = Storage()
        let sdk = CryptoManager()
        let sharing: String
        let signing: String

        init(_ name: String, _ userId: String) {
            self.name = name
            self.userId = userId
            sdk.registerSecureStorage(storage: storage)
            sharing = NamedNotificationsTests.hex(sdk.generateKeypair().publicKey)
            signing = NamedNotificationsTests.hex(sdk.generateSigningKeypair().verifyingKeyB64)
        }
    }

    /// The owner makes the circle and gives it to this device; a stranger
    /// holds a circle of the same id that this device never had.
    private func world() throws -> (owner: Party, me: Party, stranger: Party) {
        let owner = Party("Olivia", "a7a70000-0000-4000-8000-00000000000a")
        let me = Party("Me", "a7a70000-0000-4000-8000-00000000000b")
        let stranger = Party("Stranger", "a7a70000-0000-4000-8000-00000000000c")
        _ = try me.sdk.pinMemberKeys(circleId: circleId, userId: owner.userId,
                                     sharingPubkeyHex: owner.sharing, signingPubkeyHex: owner.signing)
        let creation = try owner.sdk.prepareCircleCreation()
        try owner.sdk.finalizeCircleCreation(tempCircleId: creation.tempCircleId, realCircleId: circleId)
        let bundle = try owner.sdk.wrapCircleKeyForMemberFull(
            circleId: circleId, memberPublicKeyHex: me.sharing, senderUserId: owner.userId,
            recipientUserId: me.userId, recipientSigningPubkeyHex: me.signing)
        try me.sdk.storeCircleKey(
            circleId: circleId, encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey, keyVersion: 1, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: bundle.wrapSignature, senderSigningPubkeyHex: owner.signing)
        let theirs = try stranger.sdk.prepareCircleCreation()
        try stranger.sdk.finalizeCircleCreation(tempCircleId: theirs.tempCircleId, realCircleId: circleId)
        return (owner, me, stranger)
    }

    private func blob(_ e: EncryptedData) -> [String: Any] { ["nonce": e.nonce, "ciphertext": e.ciphertext] }

    // MARK: - Rows as the server writes them

    /// One notification row, every field as the server serves it.
    private func notificationRow(_ type: String, title: String, body: String?, metadata: [String: Any],
                                 id: String? = nil) -> [String: Any] {
        [
            "id": id ?? rowId, "circle_id": circleId, "notification_type": type, "title": title,
            "body": body ?? NSNull(), "metadata": metadata, "is_read": false, "created_day_bucket": 20_740,
            "created_at": "2026-10-14T13:05:09.512Z",
        ]
    }

    /// A crossing's row, as the server writes it.
    private func crossingRow(of userId: String, arrived: Bool = true) -> [String: Any] {
        notificationRow("place_alert", title: arrived ? "Member arrived at a place" : "Member left a place", body: nil,
                        metadata: [
                            "place_alert_id": "a7a70000-0000-4000-8000-0000000000f1", "place_id": placeId,
                            "target_user_id": userId, "event_type_hash": String(repeating: "ab", count: 32),
                        ])
    }

    /// A check-in's row with its metadata: who checked in, sealed by them.
    private func checkInRow(sealedBy sealer: CryptoManager, userId: String, place: Bool = true,
                            body: String = "A circle member has checked in safely.") throws -> [String: Any] {
        let sealed = try sealer.encryptDataV2(circleId: circleId, plaintext: userId, fieldTag: "user_id")
        var metadata: [String: Any] = [
            "check_in_id": "a7a70000-0000-4000-8000-0000000000f2",
            "encrypted_user_id": sealed.ciphertext, "user_id_nonce": sealed.nonce,
        ]
        if place { metadata["place_id"] = placeId }
        return notificationRow("check_in", title: "Check-in", body: body, metadata: metadata)
    }

    private func decodedRows(_ rows: [[String: Any]]) throws -> [NotificationResponse] {
        let body = try JSONSerialization.data(withJSONObject: [
            "success": true,
            "data": ["notifications": rows, "unread_count": rows.count, "has_more": false],
        ])
        let list: NotificationsListResponse = try APIService.decodeResponseBody(body)
        return list.notifications
    }

    // MARK: - The inbox

    func testTheInboxReadsWhoAndWhereOffTheServersRows() throws {
        let (owner, me, stranger) = try world()
        let raiser = "a7a70000-0000-4000-8000-00000000000d"
        let claimant = "a7a70000-0000-4000-8000-00000000000e"
        let rows = try decodedRows([
            crossingRow(of: owner.userId.uppercased()),
            try checkInRow(sealedBy: owner.sdk, userId: owner.userId),
            try checkInRow(sealedBy: stranger.sdk, userId: owner.userId, place: false),
            notificationRow("sos_alert", title: "Someone needs attention",
                            body: "A circle member asked their circle to check on them",
                            metadata: ["sos_id": "a7a70000-0000-4000-8000-0000000000f3", "circle_id": circleId]),
            notificationRow("member_joined", title: "New circle member",
                            body: "Someone joined a circle you are in. They can see its location history.",
                            metadata: ["needs_key_rotation": false, "needs_delivery": true, "send_location": true,
                                       "joined_user_id": owner.userId]),
            notificationRow("circle_ownership_transferred", title: "Circle ownership changed", body: "x",
                            metadata: ["claim_id": "a7a70000-0000-4000-8000-0000000000f4", "new_owner_id": me.userId]),
            notificationRow("circle_ownership_claim", title: "Someone asked to take over your circle", body: "x",
                            metadata: ["claim_id": "a7a70000-0000-4000-8000-0000000000f5",
                                       "resolves_at": "2026-10-28T13:05:09Z"]),
            notificationRow("sos_acknowledged", title: "Someone is responding", body: "x",
                            metadata: ["sos_id": "a7a70000-0000-4000-8000-0000000000f3"]),
        ])
        let open: (String, String, String) -> String? = { circle, nonce, sealed in
            try? me.sdk.decryptDataV2(circleId: circle, encryptedData: EncryptedData(nonce: nonce, ciphertext: sealed),
                                      fieldTag: "user_id")
        }
        let subjects = rows.map {
            NotificationNames.subject(of: $0, openSealedUserId: open,
                                      raisers: ["a7a70000-0000-4000-8000-0000000000f3": raiser],
                                      claimants: ["a7a70000-0000-4000-8000-0000000000f5": claimant])
        }
        typealias S = NotificationNames.Subject
        XCTAssertEqual(subjects[0], S(circleId: circleId, personId: owner.userId, placeId: placeId),
                       "a crossing: its member, in the one form, and its place")
        XCTAssertEqual(subjects[1], S(circleId: circleId, personId: owner.userId, placeId: placeId),
                       "a check-in: who sealed it, opened here")
        XCTAssertEqual(subjects[2], S(circleId: circleId, personId: nil, placeId: nil),
                       "a sealed id that doesn't open here names nobody")
        XCTAssertEqual(subjects[3], S(circleId: circleId, personId: raiser))
        XCTAssertEqual(subjects[4], S(circleId: circleId, personId: owner.userId))
        XCTAssertEqual(subjects[5], S(circleId: circleId, personId: me.userId))
        XCTAssertEqual(subjects[6], S(circleId: circleId, personId: claimant))
        XCTAssertEqual(subjects[7], S(circleId: circleId, personId: nil, alertId: "a7a70000-0000-4000-8000-0000000000f3"),
                       "an older row without `acknowledged_by`: the alert, nobody named")
        let unknownAlert = NotificationNames.subject(of: rows[3], openSealedUserId: open)
        XCTAssertEqual(unknownAlert, S(circleId: circleId, personId: nil), "an alert this device didn't open")
    }

    // MARK: - Who is responding, who closed it

    /// The person who asked sees who is responding — one row per responder,
    /// the newest counting the others — and everyone told of the close sees
    /// who closed it. Named only as the rules allow (a shown member, by a
    /// sealed name that opened here), else "Someone"; generic keeps the
    /// server's words. Rows as the server writes them (`acknowledged_by`,
    /// `closed_by`, beside `sos_id` and `circle_id`).
    func testThePersonWhoAskedSeesWhoIsRespondingAndWhoClosedIt() throws {
        let (owner, me, _) = try world()
        let alert = "a7a70000-0000-4000-8000-0000000000f3"
        let ben = "a7a70000-0000-4000-8000-00000000000d", cy = "a7a70000-0000-4000-8000-00000000000e"
        func acknowledged(by userId: String, at: String, id: String) -> [String: Any] {
            var row = notificationRow("sos_acknowledged", title: "Someone is responding",
                                      body: "A circle member acknowledged your request to check on you",
                                      metadata: ["sos_id": alert, "circle_id": circleId, "acknowledged_by": userId], id: id)
            row["created_at"] = at
            return row
        }
        let rows = try decodedRows([
            acknowledged(by: cy, at: "2026-10-14T13:07:00Z", id: "a7a70000-0000-4000-8000-0000000000a3"),
            acknowledged(by: owner.userId, at: "2026-10-14T13:05:00Z", id: "a7a70000-0000-4000-8000-0000000000a1"),
            acknowledged(by: ben, at: "2026-10-14T13:06:00Z", id: "a7a70000-0000-4000-8000-0000000000a2"),
            notificationRow("sos_resolved", title: "Alert resolved",
                            body: "A circle member marked the request to check on them resolved",
                            metadata: ["sos_id": alert, "circle_id": circleId, "closed_by": owner.userId.uppercased()],
                            id: "a7a70000-0000-4000-8000-0000000000a4"),
        ])
        var found: [String: NotificationNames.Subject] = [:]
        for row in rows {
            found[row.id] = NotificationNames.subject(of: row, openSealedUserId: { _, _, _ in nil })
        }
        let counted = NotificationNames.respondersBefore(found, rows: rows)
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a1"]?.others, 0, "the first responder")
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a2"]?.others, 1)
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a3"]?.others, 2, "the newest counts the others")
        let closed = try XCTUnwrap(counted["a7a70000-0000-4000-8000-0000000000a4"])
        XCTAssertEqual(closed.personId, owner.userId, "who closed it, in the one form")
        XCTAssertTrue(closed.personClosed)

        // Olivia is a shown member whose name opened here; Ben is on the roster
        // by a name that didn't open; Cy isn't shown at all.
        let shown = [circleId: [member(owner, name: "Olivia"), member(me, name: "Me"),
                                CircleMember(circleId: circleId, userId: ben, displayName: "Ben", role: .member,
                                             canSeeRealtime: true, canSeeHistory: true, canRotateKeys: false,
                                             joinedAt: now)]]
        let opened = [circleId: Set([owner.userId])]
        func words(_ id: String, _ level: String? = "full") -> (title: String, body: String?)? {
            let row = try! XCTUnwrap(rows.first { $0.id == id })
            let names = NotificationNames.names(for: try! XCTUnwrap(counted[id]), me: me.userId, members: shown,
                                                opened: opened, places: [], circleName: "Family")
            return NamedNotificationCopy.row(type: row.notificationType, title: row.title, body: row.body,
                                             names: names, level: level)
        }
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a1")?.title, "Olivia is responding")
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a1")?.body,
                       "Olivia acknowledged your request to check on you")
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a2")?.title, "Someone and 1 other are responding",
                       "a name that didn't open is no name")
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a2")?.body,
                       "A circle member acknowledged your request to check on you")
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a3")?.title, "Someone and 2 others are responding",
                       "someone this device doesn't show is not named")
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a4")?.body, "Olivia closed the alert")
        XCTAssertEqual(words("a7a70000-0000-4000-8000-0000000000a1", "names")?.title, "Olivia is responding",
                       "a name, no place: names-only keeps it")
        XCTAssertNil(words("a7a70000-0000-4000-8000-0000000000a1", "generic"))
        XCTAssertNil(words("a7a70000-0000-4000-8000-0000000000a4", "generic"))

        // The words themselves.
        XCTAssertEqual(row("sos_acknowledged", title: "Someone is responding", .init(person: "Ana", others: 3))?.title,
                       "Ana and 3 others are responding")
        XCTAssertNil(row("sos_acknowledged", title: "Someone is responding", .init(personIsMe: true)))
        XCTAssertEqual(row("sos_resolved", title: "Alert resolved", .init(personClosed: true))?.body,
                       "Someone closed the alert")
        XCTAssertEqual(row("sos_resolved", title: "Alert resolved", .init(personIsMe: true, personClosed: true))?.body,
                       "You closed the alert")
        XCTAssertEqual(row("sos_resolved", title: "Alert resolved", .init(person: "Ana"))?.body,
                       "Ana's request to be checked on was marked resolved", "an older row: who asked")
    }

    /// One "needs attention" alert as `GET /api/v1/sos/{id}` serves it, every
    /// part sealed by `sealer` under the version it seals under now.
    private func alert(sealedBy sealer: CryptoManager, raiser: String) throws -> SOSResponse {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let row: [String: Any] = [
            "id": "a7a70000-0000-4000-8000-0000000000f3", "circle_id": circleId, "status": "active",
            "day_bucket": 20_740,
            "encrypted_user_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: raiser, fieldTag: "user_id")),
            "encrypted_device_id": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: "device-1",
                                                                 fieldTag: "device_id")),
            "encrypted_timestamp": blob(try sealer.encryptDataV2(circleId: circleId, plaintext: String(nowMs - 60_000),
                                                                 fieldTag: "timestamp")),
            "encrypted_location": blob(try sealer.encryptLocation(circleId: circleId, location: Location(
                latitude: 37.3349, longitude: -122.009, altitude: nil, speed: nil, heading: nil, accuracy: 5,
                timestamp: nowMs - 60_000, batteryLevel: nil, isCharging: nil))),
        ]
        return try APIService.makeWireDecoder().decode(SOSResponse.self,
                                                       from: try JSONSerialization.data(withJSONObject: row))
    }

    /// A row names who asked only by the receivers' rules, as the alarm
    /// would. An alert that opens only under an older key (history, or a
    /// removed member's forgery a server lists) names nobody, unless this
    /// phone saw it current before (its "seen current" mark: sticky across a
    /// rotation); a current one names its raiser.
    func testANeedsAttentionRowNamesWhoAskedOnlyByTheReceiversRules() throws {
        let (owner, me, _) = try world()
        let old = try alert(sealedBy: owner.sdk, raiser: owner.userId)
        let v2 = try owner.sdk.prepareKeyRotation(
            circleId: circleId, senderUserId: owner.userId, memberUserIds: [owner.userId, me.userId],
            memberPublicKeysHex: [owner.sharing, me.sharing], memberSigningPubkeysHex: [owner.signing, me.signing],
            currentCircleNamePlaintext: "Family")
        let bundle = try XCTUnwrap(v2.memberKeys.first { $0.userId == me.userId }).bundle
        try me.sdk.storeCircleKey(
            circleId: circleId, encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: bundle.wrapSignature, senderSigningPubkeyHex: owner.signing)
        let fresh = try alert(sealedBy: owner.sdk, raiser: owner.userId)

        let openedOld = SOSReceiverRules.open(old, myUserId: me.userId, myDeviceId: nil, crypto: me.sdk)
        XCTAssertEqual(openedOld.raiserId, owner.userId, "it opens here, under the older key")
        XCTAssertFalse(openedOld.current)
        XCTAssertNil(NotificationsManager.raiser(of: openedOld, marks: .read(ended: false, seenCurrent: false)),
                     "opened only under an older key: nobody")
        XCTAssertNil(NotificationsManager.raiser(of: openedOld, marks: .unreadable), "marks unreadable: nobody")
        XCTAssertEqual(NotificationsManager.raiser(of: openedOld, marks: .read(ended: false, seenCurrent: true)),
                       owner.userId, "seen current here before: sticky, named")

        let openedFresh = SOSReceiverRules.open(fresh, myUserId: me.userId, myDeviceId: nil, crypto: me.sdk)
        XCTAssertTrue(openedFresh.current)
        XCTAssertEqual(NotificationsManager.raiser(of: openedFresh, marks: .read(ended: false, seenCurrent: false)),
                       owner.userId, "current: named")
    }

    private func member(_ party: Party, name: String) -> CircleMember {
        CircleMember(circleId: circleId, userId: party.userId, displayName: name, role: .member,
                     canSeeRealtime: true, canSeeHistory: true, canRotateKeys: false, joinedAt: now)
    }

    private func place(_ name: String) -> Place {
        Place(id: placeId, circleId: circleId, name: name, latitude: 37.3349, longitude: -122.009, radius: 100,
              placeType: "place", boundaryRadius: 100, alertsEnabled: true, icon: .custom, color: "#3B82F6",
              createdAt: now, address: nil, notes: nil, wrappedKey: nil, wrappedKeyNonce: nil, wrapTargetId: nil)
    }

    /// Only a member this device shows, by a name that opened here; this
    /// account is "you"; a place only when it opened here.
    func testTheInboxNamesOnlyWhatOpenedHere() throws {
        let (owner, me, _) = try world()
        let subject = NotificationNames.Subject(circleId: circleId, personId: owner.userId, placeId: placeId)
        let shown = [circleId: [member(owner, name: "Olivia"), member(me, name: "Me")]]
        let opened = [circleId: Set([owner.userId])]
        let named = NotificationNames.names(for: subject, me: me.userId, members: shown, opened: opened,
                                            places: [place("Home")], circleName: "Family")
        XCTAssertEqual(named, .init(person: "Olivia", place: "Home", circle: "Family"))
        XCTAssertFalse(NotificationNames.misses(subject, me: me.userId, members: shown, opened: opened))

        let plaintextOnly = NotificationNames.names(for: subject, me: me.userId, members: shown, opened: [:],
                                                    places: [], circleName: nil)
        XCTAssertNil(plaintextOnly.person, "the server's plaintext name: never")
        XCTAssertTrue(NotificationNames.misses(subject, me: me.userId, members: shown, opened: [:]),
                      "a miss: one roster load may fix it")
        let notShown = NotificationNames.names(for: subject, me: me.userId, members: [circleId: [member(me, name: "Me")]],
                                               opened: opened, places: [], circleName: nil)
        XCTAssertNil(notShown.person, "someone this device doesn't show (left, or not confirmed)")

        let mine = NotificationNames.Subject(circleId: circleId, personId: me.userId.uppercased())
        XCTAssertEqual(NotificationNames.names(for: mine, me: me.userId, members: shown, opened: opened, places: [],
                                               circleName: nil), .init(personIsMe: true))
        XCTAssertFalse(NotificationNames.misses(mine, me: me.userId, members: shown, opened: opened))

        let unopened = NotificationNames.names(for: subject, me: me.userId, members: shown, opened: opened,
                                               places: [place(Place.unopenedName)], circleName: nil)
        XCTAssertNil(unopened.place, "a place whose name didn't open is no name")
        XCTAssertNil(NotificationNames.names(for: subject, me: me.userId, members: shown, opened: opened,
                                             places: [], circleName: nil).place, "a place this device doesn't hold")

        // End to end, at each level.
        let rows = try decodedRows([crossingRow(of: owner.userId)])
        let decoded = try XCTUnwrap(NotificationNames.subject(of: rows[0], openSealedUserId: { _, _, _ in nil }))
        let names = NotificationNames.names(for: decoded, me: me.userId, members: shown, opened: opened,
                                            places: [place("Home")], circleName: "Family")
        func words(_ level: String) -> String? {
            NamedNotificationCopy.row(type: rows[0].notificationType, title: rows[0].title, body: rows[0].body,
                                      names: names, level: level)?.body
        }
        XCTAssertEqual(words("full"), "Olivia arrived at Home")
        XCTAssertEqual(words("names"), "Olivia arrived at a place")
        XCTAssertNil(words("generic"))
    }

    // MARK: - The server's own follow-up rows

    /// `GET /api/v1/notifications` items exactly as the server serializes
    /// them: the asker's "someone is responding" row, the asker's "resolved"
    /// row when an owner closed it, and another member's "resolved" row for
    /// the same close.
    private static let servedAcknowledged = #"{"body":"A circle member acknowledged your request to check on you","circle_id":"3f732f98-6e9d-45e2-a971-30f72e786cb1","created_at":"2026-10-14T20:39:21.845429Z","created_day_bucket":20740,"id":"37a1ae94-afdb-4043-b41a-776076058ef8","is_read":false,"metadata":{"acknowledged_by":"339661a0-9a37-4988-b3a5-bd6a112c8b8c","circle_id":"3f732f98-6e9d-45e2-a971-30f72e786cb1","sos_id":"32162662-6a12-4c71-be95-9f88171aed27"},"notification_type":"sos_acknowledged","title":"Someone is responding"}"#
    private static let servedResolvedForAsker = #"{"body":"A circle member marked the request to check on them resolved","circle_id":"3f732f98-6e9d-45e2-a971-30f72e786cb1","created_at":"2026-10-14T20:39:22.659969Z","created_day_bucket":20740,"id":"8e09fc14-59aa-429e-9dd4-28adfee0ce08","is_read":false,"metadata":{"circle_id":"3f732f98-6e9d-45e2-a971-30f72e786cb1","closed_by":"9b3a161c-c1b1-4790-91a4-12b76f597f1a","sos_id":"32162662-6a12-4c71-be95-9f88171aed27"},"notification_type":"sos_resolved","title":"Alert resolved"}"#
    private static let servedResolvedForOthers = #"{"body":"A circle member marked the request to check on them resolved","circle_id":"3f732f98-6e9d-45e2-a971-30f72e786cb1","created_at":"2026-10-14T20:39:22.659969Z","created_day_bucket":20740,"id":"5207c992-acf1-4b37-8754-76bf02d87abe","is_read":false,"metadata":{"circle_id":"3f732f98-6e9d-45e2-a971-30f72e786cb1","sos_id":"32162662-6a12-4c71-be95-9f88171aed27"},"notification_type":"sos_resolved","title":"Alert resolved"}"#
    private static let servedCircle = "3f732f98-6e9d-45e2-a971-30f72e786cb1"
    private static let servedAlert = "32162662-6a12-4c71-be95-9f88171aed27"
    private static let servedResponder = "339661a0-9a37-4988-b3a5-bd6a112c8b8c"
    private static let servedCloser = "9b3a161c-c1b1-4790-91a4-12b76f597f1a"

    /// One of those rows as served, its ids swapped for a test's (served id →
    /// test id).
    private func served(_ json: String, ids: [String: String] = [:]) throws -> [String: Any] {
        var text = json
        for (from, to) in ids { text = text.replacingOccurrences(of: from, with: to) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// The server's own rows, read by the inbox: the asker sees who is
    /// responding and who closed it; another member's "resolved" row, which
    /// never says who closed it, keeps the plain words (who asked).
    func testTheServersOwnFollowUpRowsNameWhoRespondedAndWhoClosed() throws {
        let rows = try decodedRows([served(Self.servedAcknowledged), served(Self.servedResolvedForAsker),
                                    served(Self.servedResolvedForOthers)])
        let raiser = "a7a70000-0000-4000-8000-0000000000aa"
        var found: [String: NotificationNames.Subject] = [:]
        for row in rows {
            found[row.id] = NotificationNames.subject(of: row, openSealedUserId: { _, _, _ in nil },
                                                      raisers: [Self.servedAlert: raiser])
        }
        let counted = NotificationNames.respondersBefore(found, rows: rows)
        typealias S = NotificationNames.Subject
        XCTAssertEqual(counted[rows[0].id], S(circleId: Self.servedCircle, personId: Self.servedResponder,
                                              alertId: Self.servedAlert))
        XCTAssertEqual(counted[rows[1].id], S(circleId: Self.servedCircle, personId: Self.servedCloser,
                                              personClosed: true))
        XCTAssertEqual(counted[rows[2].id], S(circleId: Self.servedCircle, personId: raiser), "who asked")

        func shownMember(_ userId: String, _ name: String) -> CircleMember {
            CircleMember(circleId: Self.servedCircle, userId: userId, displayName: name, role: .member,
                         canSeeRealtime: true, canSeeHistory: true, canRotateKeys: false, joinedAt: now)
        }
        let shown = [Self.servedCircle: [shownMember(Self.servedResponder, "Olivia"),
                                         shownMember(Self.servedCloser, "Ben"), shownMember(raiser, "Ana")]]
        let opened = [Self.servedCircle: Set([Self.servedResponder, Self.servedCloser, raiser])]
        func words(_ index: Int, opened: [String: Set<String>],
                   level: String? = "full") throws -> (title: String, body: String?)? {
            let row = rows[index]
            let names = NotificationNames.names(for: try XCTUnwrap(counted[row.id]),
                                                me: "a7a70000-0000-4000-8000-0000000000bb", members: shown,
                                                opened: opened, places: [], circleName: nil)
            return NamedNotificationCopy.row(type: row.notificationType, title: row.title, body: row.body,
                                             names: names, level: level)
        }
        XCTAssertEqual(try words(0, opened: opened)?.title, "Olivia is responding")
        XCTAssertEqual(try words(0, opened: opened)?.body, "Olivia acknowledged your request to check on you")
        XCTAssertNil(try words(0, opened: [:]), "a name that didn't open: the row's own \"Someone is responding\"")
        XCTAssertEqual(try words(1, opened: opened)?.title, "Alert resolved")
        XCTAssertEqual(try words(1, opened: opened)?.body, "Ben closed the alert")
        XCTAssertEqual(try words(1, opened: [:])?.body, "Someone closed the alert")
        XCTAssertEqual(try words(2, opened: opened)?.body, "Ana's request to be checked on was marked resolved",
                       "another member's row: the usual sentence")
        XCTAssertNil(try words(0, opened: opened, level: "generic"))
        XCTAssertNil(try words(1, opened: opened, level: "generic"))
    }

    /// The server writes `created_at` with 0, 3 or 6 decimals, so responders
    /// are counted by the PARSED time, then the id: as text, a whole second
    /// ("…:21Z") sorts after "…:21.250Z" although it is earlier.
    func testRespondersAreCountedByTheirParsedTimeWhateverItsPrecision() throws {
        let alert = "a7a70000-0000-4000-8000-0000000000f3"
        func responding(_ userId: String, at: String, id: String) throws -> [String: Any] {
            var row = try served(Self.servedAcknowledged, ids: [Self.servedCircle: circleId, Self.servedAlert: alert,
                                                                Self.servedResponder: userId])
            row["id"] = id
            row["created_at"] = at
            return row
        }
        let rows = try decodedRows([
            responding("a7a70000-0000-4000-8000-00000000000d", at: "2026-10-14T20:39:21.250Z",
                       id: "a7a70000-0000-4000-8000-0000000000a2"),
            responding("a7a70000-0000-4000-8000-00000000000e", at: "2026-10-14T20:39:21.250000Z",
                       id: "a7a70000-0000-4000-8000-0000000000a3"),
            responding("a7a70000-0000-4000-8000-00000000000a", at: "2026-10-14T20:39:21Z",
                       id: "a7a70000-0000-4000-8000-0000000000a9"),
            responding("a7a70000-0000-4000-8000-00000000000c", at: "2026-10-14T20:39:21.100500Z",
                       id: "a7a70000-0000-4000-8000-0000000000a1"),
        ])
        var found: [String: NotificationNames.Subject] = [:]
        for row in rows {
            found[row.id] = NotificationNames.subject(of: row, openSealedUserId: { _, _, _ in nil })
        }
        let counted = NotificationNames.respondersBefore(found, rows: rows)
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a9"]?.others, 0, "the whole second is the earliest")
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a1"]?.others, 1)
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a2"]?.others, 2)
        XCTAssertEqual(counted["a7a70000-0000-4000-8000-0000000000a3"]?.others, 3, "the same instant: the id decides")
    }

    // MARK: - The extension

    private final class StubServer: HandoverTransport, @unchecked Sendable {
        private let lock = NSLock()
        var responses: [String: (status: Int, body: Any)] = [:]
        private var seen: [String] = []
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
            lock.lock()
            seen.append(key)
            let answer = responses[key] ?? (404, ["success": false])
            lock.unlock()
            return (try JSONSerialization.data(withJSONObject: answer.body),
                    HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func token(sub: String, expires: Date = Date().addingTimeInterval(3600)) -> String {
        func b64(_ object: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(b64(["alg": "RS256"])).\(b64(["sub": sub, "exp": Int(expires.timeIntervalSince1970)])).signature"
    }

    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private struct Scene {
        let me: Party
        let server = StubServer()
        let defaults: UserDefaults
        var token: String?
        var keysReadable = true

        func environment(clock: Date) -> BackgroundHandover.Environment {
            let (persisted, token, readable) = (me.storage.data, token, keysReadable)
            let lock = AppGroupLock(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("named-\(UUID().uuidString).lock"))
            return BackgroundHandover.Environment(
                accessToken: { token },
                refreshedToken: { nil },
                keychainUserId: { me.userId },
                shared: { defaults },
                deviceTag: { "device-tag" },
                approvalsLock: { lock },
                makeCrypto: {
                    guard readable else { return nil }
                    let manager = CryptoManager()
                    manager.registerSecureStorage(storage: Storage(persisted))
                    return (try? manager.loadPersistedKeys()) == true ? manager : nil
                },
                transport: server,
                now: { clock })
        }
    }

    /// A roster row; the plaintext `display_name` older clients send always,
    /// the sealed one when `sealedName` is given.
    private func rosterRow(_ party: Party, role: String = "member", sealedName: EncryptedData? = nil) -> [String: Any] {
        var row: [String: Any] = [
            "user_id": party.userId, "display_name": party.name, "role": role,
            "encrypted_circle_key": ["nonce": "", "ciphertext": ""], "ephemeral_public_key": "",
            "can_see_history": true, "can_see_realtime": true, "status": "active",
            "joined_day_bucket": Int(now.timeIntervalSince1970 / 86_400) - 30, "key_version": 1,
            "sharing_public_key": party.sharing, "signing_public_key": party.signing,
        ]
        if let sealedName { row["encrypted_display_name"] = blob(sealedName) }
        return row
    }

    /// A place shared with the circle, as `GET /api/v1/places` serves it: its
    /// name sealed under its own key, wrapped for the circle by `sharer`.
    private func sharedPlace(_ name: String, by sharer: Party) throws -> [String: Any] {
        let key = sharer.sdk.generatePlaceKey()
        let sealedName = try sharer.sdk.encryptWithPlaceKeyV2(placeKeyHex: key, plaintext: name, fieldTag: "name")
        let wrap = try sharer.sdk.wrapPlaceKey(targetId: circleId, placeKeyHex: key, senderUserId: sharer.userId,
                                               placeId: placeId)
        return [
            "id": placeId, "user_id": sharer.userId, "circle_id": NSNull(), "encrypted_name": blob(sealedName),
            "encrypted_location": ["nonce": "00", "ciphertext": "00"], "radius_meters": 100,
            "created_day_bucket": 20_000, "updated_day_bucket": 20_000, "shared_circles": [circleId],
            "wrapped_key": wrap.wrappedKey, "wrapped_key_nonce": wrap.wrappedKeyNonce, "wrap_via_circle": circleId,
        ]
    }

    /// This device, signed in; the server serving `row` as the push's row, the
    /// circle's roster and the account's places. `confirmed`: whom this
    /// device's approval record confirms.
    private func scene(_ me: Party, row: [String: Any], roster: [[String: Any]], places: [[String: Any]] = [],
                       confirmed: [String] = []) throws -> Scene {
        let suite = "NamedNotificationsTests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(me.userId, forKey: ExtensionBridgeKeys.accountUserId)
        defaults.set("me@example.com", forKey: ExtensionBridgeKeys.accountEmail)
        defaults.set(base, forKey: ExtensionBridgeKeys.apiBaseURL)
        var record = CircleApprovalRecord()
        for userId in confirmed { record.entries[userId] = .ownAction }
        record.deviceTag = "device-tag"
        defaults.set(try JSONEncoder().encode(record), forKey: ApprovalRecordStore.key(owner: me.userId, circleId: circleId))
        let scene = Scene(me: me, defaults: defaults, token: Self.token(sub: me.userId))
        scene.server.responses["GET /api/v1/notifications/\(rowId)"] = (200, ["success": true, "data": row])
        scene.server.responses["GET /api/v1/circles/\(circleId)/members"] =
            (200, ["success": true, "data": ["items": roster, "has_more": false]])
        scene.server.responses["GET /api/v1/places"] = (200, ["success": true, "data": places])
        return scene
    }

    private func named(_ scene: Scene, alertType: String = "place_alert_enter", level: String? = "full",
                       notificationId: String? = nil) async -> NamedBanner.Named? {
        await NamedBanner.run(alertType: alertType, notificationId: notificationId ?? rowId, level: level,
                              deadline: now.addingTimeInterval(NamedBanner.budget), env: scene.environment(clock: now))
    }

    private var rowPath: String { "GET /api/v1/notifications/\(rowId)" }
    private var rosterPath: String { "GET /api/v1/circles/\(circleId)/members" }
    private let placesPath = "GET /api/v1/places"

    func testACrossingBannerIsNamedFromTheRowThePushNames() async throws {
        let (owner, me, _) = try world()
        let sealedName = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let roster = [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)]
        let places = [try sharedPlace("Home", by: owner)]

        let full = try scene(me, row: crossingRow(of: owner.userId), roster: roster, places: places,
                             confirmed: [owner.userId])
        let fullWords = await named(full)
        XCTAssertEqual(fullWords, NamedBanner.Named(title: "Arrival", body: "Olivia arrived at Home", circleId: circleId))
        XCTAssertEqual(full.server.requests, [rowPath, rosterPath, placesPath])

        let leaving = try scene(me, row: crossingRow(of: owner.userId, arrived: false), roster: roster, places: places,
                                confirmed: [owner.userId])
        let leavingWords = await named(leaving, alertType: "place_alert_exit")
        XCTAssertEqual(leavingWords?.title, "Departure")
        XCTAssertEqual(leavingWords?.body, "Olivia left Home")

        let namesOnly = try scene(me, row: crossingRow(of: owner.userId), roster: roster, places: places,
                                  confirmed: [owner.userId])
        let namesOnlyWords = await named(namesOnly, level: "names")
        XCTAssertEqual(namesOnlyWords?.body, "Olivia arrived at a place")
        XCTAssertEqual(namesOnly.server.requests, [rowPath, rosterPath], "where is never asked for")

        let generic = try scene(me, row: crossingRow(of: owner.userId), roster: roster, places: places,
                                confirmed: [owner.userId])
        let genericWords = await named(generic, level: "generic")
        XCTAssertNil(genericWords)
        XCTAssertEqual(generic.server.requests, [], "generic: nothing is fetched")

        let mine = try scene(me, row: crossingRow(of: me.userId), roster: roster, places: places)
        let mineWords = await named(mine)
        XCTAssertEqual(mineWords?.body, "You arrived at Home")
        XCTAssertEqual(mine.server.requests, [rowPath, placesPath], "no roster for oneself")
    }

    func testACheckInBannerNamesWhoSealedIt() async throws {
        let (owner, me, stranger) = try world()
        let sealedName = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let roster = [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)]
        let places = [try sharedPlace("Home", by: owner)]

        let safe = try scene(me, row: try checkInRow(sealedBy: owner.sdk, userId: owner.userId), roster: roster,
                             places: places, confirmed: [owner.userId])
        let safeWords = await named(safe, alertType: "check_in")
        XCTAssertEqual(safeWords, NamedBanner.Named(title: "Check-in", body: "Olivia has checked in safely at Home.",
                                                    circleId: circleId))

        let noPlace = try scene(me, row: try checkInRow(sealedBy: owner.sdk, userId: owner.userId, place: false,
                                                        body: "A circle member has checked in."),
                                roster: roster, confirmed: [owner.userId])
        let noPlaceWords = await named(noPlace, alertType: "check_in")
        XCTAssertEqual(noPlaceWords?.body, "Olivia has checked in.")
        XCTAssertEqual(noPlace.server.requests, [rowPath, rosterPath], "no place on the row: none asked for")

        let unopened = try scene(me, row: try checkInRow(sealedBy: stranger.sdk, userId: owner.userId), roster: roster,
                                 places: places, confirmed: [owner.userId])
        let unopenedWords = await named(unopened, alertType: "check_in")
        XCTAssertEqual(unopenedWords?.body, "A member has checked in safely at Home.",
                       "a sealed sender that doesn't open here is nobody")
        XCTAssertFalse(unopened.server.requests.contains(rosterPath))
    }

    /// A follow-up's banner says what its inbox row says, told to the person
    /// who asked: who is responding, counting those before, and who closed it.
    /// Its row is the newest of its kind for the alert the push names, among
    /// the account's newest rows as the server lists them; the person is
    /// named only as `memberName` allows, else "Someone". Rows are the
    /// server's own, with this test's ids.
    func testAFollowUpBannerSaysWhoIsRespondingAndWhoClosedIt() async throws {
        let (owner, me, _) = try world()
        let sealedName = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let roster = [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)]
        let alert = "a7a70000-0000-4000-8000-0000000000f3", otherAlert = "a7a70000-0000-4000-8000-0000000000f6"
        let ben = "a7a70000-0000-4000-8000-00000000000d", cy = "a7a70000-0000-4000-8000-00000000000e"
        let ours = [Self.servedCircle: circleId, Self.servedAlert: alert]
        /// The server's "someone is responding" row; `userId` nil: an older row
        /// without a responder id.
        func responding(_ userId: String?, on sosId: String? = nil, id: String) throws -> [String: Any] {
            var row = try served(Self.servedAcknowledged, ids: [Self.servedCircle: circleId,
                                                                Self.servedAlert: sosId ?? alert])
            var metadata = try XCTUnwrap(row["metadata"] as? [String: Any])
            metadata["acknowledged_by"] = userId
            row["metadata"] = metadata
            row["id"] = id
            return row
        }
        /// The asker's "resolved" row; `userId` nil: an older row
        /// without the closer's id.
        func closed(by userId: String?) throws -> [String: Any] {
            var row = try served(Self.servedResolvedForAsker, ids: ours)
            var metadata = try XCTUnwrap(row["metadata"] as? [String: Any])
            metadata["closed_by"] = userId
            row["metadata"] = metadata
            return row
        }
        let listPath = "GET /api/v1/notifications"
        func followUp(_ rows: [[String: Any]], type: String = "sos_acknowledged", alertId: String? = nil,
                      level: String = "full", confirmed: [String]? = nil) async throws -> (NamedBanner.Named?, [String]) {
            let scene = try self.scene(me, row: crossingRow(of: owner.userId), roster: roster,
                                       confirmed: confirmed ?? [owner.userId])
            scene.server.responses[listPath] = (200, ["success": true, "data": [
                "notifications": rows, "unread_count": rows.count, "has_more": false]])
            let words = await NamedBanner.followUp(alertType: type, alertId: alertId ?? alert.uppercased(),
                                                   level: level, deadline: now.addingTimeInterval(NamedBanner.budget),
                                                   env: scene.environment(clock: now))
            return (words, scene.server.requests)
        }

        // Newest first; another alert's responder and a crossing in between.
        let three = try [responding(owner.userId, id: "a7a70000-0000-4000-8000-0000000000a3"),
                         crossingRow(of: owner.userId),
                         responding(cy, on: otherAlert, id: "a7a70000-0000-4000-8000-0000000000a5"),
                         responding(ben, id: "a7a70000-0000-4000-8000-0000000000a2"),
                         responding(cy, id: "a7a70000-0000-4000-8000-0000000000a1")]
        var (words, requests) = try await followUp(three)
        XCTAssertEqual(words, NamedBanner.Named(title: "Olivia and 2 others are responding",
                                                body: "Olivia acknowledged your request to check on you",
                                                circleId: circleId))
        XCTAssertEqual(requests, [listPath, rosterPath])
        (words, _) = try await followUp(three, level: "names")
        XCTAssertEqual(words?.title, "Olivia and 2 others are responding", "a name, no place: names-only keeps it")
        (words, requests) = try await followUp(three, level: "generic")
        XCTAssertNil(words)
        XCTAssertEqual(requests, [], "generic: nothing is fetched")
        (words, _) = try await followUp(three, confirmed: [])
        XCTAssertEqual(words?.title, "Someone and 2 others are responding", "not confirmed here: no name")

        let one = try [responding(owner.userId, id: "a7a70000-0000-4000-8000-0000000000a1")]
        (words, _) = try await followUp(one)
        XCTAssertEqual(words?.title, "Olivia is responding")
        (words, _) = try await followUp(one, confirmed: [])
        XCTAssertEqual(words, NamedBanner.Named(title: "Someone is responding",
                                                body: "A circle member acknowledged your request to check on you",
                                                circleId: circleId), "nobody named: the row's own words")
        (words, requests) = try await followUp([responding(nil, id: "a7a70000-0000-4000-8000-0000000000a1")])
        XCTAssertNil(words, "a row naming no responder: the server's words")
        XCTAssertEqual(requests, [listPath], "nobody to name: no roster")
        (words, _) = try await followUp([responding("not-an-id", id: "a7a70000-0000-4000-8000-0000000000a2")] + one)
        XCTAssertEqual(words?.title, "Olivia is responding", "a row naming someone by no id is dropped")

        // Who closed it, on the asker's row alone.
        (words, requests) = try await followUp([closed(by: owner.userId)], type: "sos_resolved")
        XCTAssertEqual(words, NamedBanner.Named(title: "Alert resolved", body: "Olivia closed the alert",
                                                circleId: circleId))
        XCTAssertEqual(requests, [listPath, rosterPath])
        (words, _) = try await followUp([closed(by: owner.userId)], type: "sos_resolved", confirmed: [])
        XCTAssertEqual(words?.body, "Someone closed the alert")
        (words, _) = try await followUp([closed(by: me.userId.uppercased())], type: "sos_resolved")
        XCTAssertEqual(words?.body, "You closed the alert")
        (words, requests) = try await followUp([closed(by: nil)], type: "sos_resolved")
        XCTAssertNil(words, "a row naming nobody who closed it: the server's words")
        XCTAssertEqual(requests, [listPath])
        (words, requests) = try await followUp([served(Self.servedResolvedForOthers, ids: ours)], type: "sos_resolved")
        XCTAssertNil(words, "another member's row never says who closed it: the server's words")
        XCTAssertEqual(requests, [listPath])

        // Nothing found, or nothing to look for: the server's words.
        (words, _) = try await followUp(three, type: "sos_resolved")
        XCTAssertNil(words, "no row of its kind for the alert")
        (words, _) = try await followUp([responding(owner.userId, on: otherAlert, id: "a7a70000-0000-4000-8000-0000000000a1")])
        XCTAssertNil(words, "another alert's row")
        (words, requests) = try await followUp(three, alertId: "../circles")
        XCTAssertNil(words)
        XCTAssertEqual(requests, [], "ids only go into a path")
    }

    /// Only a member this device's own roster pass shows, by the sealed name
    /// that opens here.
    func testOnlyAConfirmedMemberIsNamedByTheirSealedName() async throws {
        let (owner, me, stranger) = try world()
        let sealedName = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let places = [try sharedPlace("Home", by: owner)]

        let unconfirmed = try scene(me, row: crossingRow(of: owner.userId),
                                    roster: [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)],
                                    places: places)
        let unconfirmedWords = await named(unconfirmed)
        XCTAssertEqual(unconfirmedWords?.body, "A member arrived at Home", "not confirmed here: no name")

        let plaintextOnly = try scene(me, row: crossingRow(of: owner.userId),
                                      roster: [rosterRow(owner, role: "owner"), rosterRow(me)], places: places,
                                      confirmed: [owner.userId])
        let plaintextWords = await named(plaintextOnly)
        XCTAssertEqual(plaintextWords?.body, "A member arrived at Home", "the server's plaintext name: never")

        let foreign = try stranger.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let notOpening = try scene(me, row: crossingRow(of: owner.userId),
                                   roster: [rosterRow(owner, role: "owner", sealedName: foreign), rosterRow(me)],
                                   places: places, confirmed: [owner.userId])
        let notOpeningWords = await named(notOpening)
        XCTAssertEqual(notOpeningWords?.body, "A member arrived at Home", "a sealed name that doesn't open")

        let departed = try scene(me, row: crossingRow(of: owner.userId), roster: [rosterRow(me)], places: places,
                                 confirmed: [owner.userId])
        let departedWords = await named(departed)
        XCTAssertEqual(departedWords?.body, "A member arrived at Home", "off the roster: left")

        let foreignPlace = try scene(me, row: crossingRow(of: owner.userId),
                                     roster: [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)],
                                     places: [try sharedPlace("Home", by: stranger)], confirmed: [owner.userId])
        let foreignPlaceWords = await named(foreignPlace)
        XCTAssertEqual(foreignPlaceWords?.body, "Olivia arrived at a place", "a place that doesn't open here")

        let unlisted = try scene(me, row: crossingRow(of: owner.userId),
                                 roster: [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)],
                                 confirmed: [owner.userId])
        let unlistedWords = await named(unlisted)
        XCTAssertEqual(unlistedWords?.body, "Olivia arrived at a place", "a place this account doesn't list")
    }

    /// Without what it takes, nothing is named and the banner keeps the
    /// server's words.
    func testWithoutWhatItTakesTheBannerKeepsTheServersWords() async throws {
        let (owner, me, _) = try world()
        let sealedName = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let roster = [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)]
        func fresh() throws -> Scene {
            try scene(me, row: crossingRow(of: owner.userId), roster: roster, confirmed: [owner.userId])
        }

        let noId = try fresh()
        let noIdWords = await NamedBanner.run(alertType: "place_alert_enter", notificationId: nil, level: "full",
                                              deadline: now.addingTimeInterval(10), env: noId.environment(clock: now))
        XCTAssertNil(noIdWords, "an older server: no row id")
        XCTAssertEqual(noId.server.requests, [])
        let notAnId = try fresh()
        let notAnIdWords = await named(notAnId, notificationId: "../circles")
        XCTAssertNil(notAnIdWords)
        XCTAssertEqual(notAnId.server.requests, [], "ids only go into a path")

        var locked = try fresh()
        locked.keysReadable = false
        let lockedWords = await named(locked)
        XCTAssertNil(lockedWords, "before the first unlock: generic")
        var signedOut = try fresh()
        signedOut.token = nil
        let signedOutWords = await named(signedOut)
        XCTAssertNil(signedOutWords)
        var otherAccount = try fresh()
        otherAccount.token = Self.token(sub: owner.userId)
        let otherAccountWords = await named(otherAccount)
        XCTAssertNil(otherAccountWords, "a token for another account")
        var expired = try fresh()
        expired.token = Self.token(sub: me.userId, expires: now.addingTimeInterval(-60))
        let expiredWords = await named(expired)
        XCTAssertNil(expiredWords, "ran out, and no refresh")
        let switched = try fresh()
        switched.defaults.set(owner.userId, forKey: ExtensionBridgeKeys.accountUserId)
        let switchedWords = await named(switched)
        XCTAssertNil(switchedWords, "the app group is another account's")
        for quiet in [locked, signedOut, otherAccount, expired, switched] {
            XCTAssertEqual(quiet.server.requests, [], "nothing asked")
        }

        let otherKind = try scene(me, row: crossingRow(of: owner.userId), roster: roster, confirmed: [owner.userId])
        let otherKindWords = await named(otherKind, alertType: "check_in")
        XCTAssertNil(otherKindWords, "a row of another kind than the push")
        let gone = try fresh()
        gone.server.responses[rowPath] = (404, ["success": false])
        let goneWords = await named(gone)
        XCTAssertNil(goneWords)
        let notOurs = try fresh()
        let sosWords = await named(notOurs, alertType: "sos")
        XCTAssertNil(sosWords, "a type it doesn't name")
        XCTAssertEqual(notOurs.server.requests, [])
    }

    /// The banner as the extension hands it over: named, and a crossing still
    /// stamped with its time.
    func testTheBannerCarriesTheNamesAndTheStamp() async throws {
        let (owner, me, _) = try world()
        let sealedName = try owner.sdk.encryptDataV2(circleId: circleId, plaintext: "Olivia", fieldTag: "display_name")
        let roster = [rosterRow(owner, role: "owner", sealedName: sealedName), rosterRow(me)]
        let places = [try sharedPlace("Home", by: owner)]
        let sentAt = "2026-10-14T13:05:09Z"
        func original(_ type: String, title: String) -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "Tap to view"
            content.userInfo = ["alert_type": type, "alert_id": UUID().uuidString, "notification_id": rowId,
                                "sent_at": sentAt]
            return content
        }

        let crossing = try scene(me, row: crossingRow(of: owner.userId), roster: roster, places: places,
                                 confirmed: [owner.userId])
        let banner = await NotificationService.banner(
            for: original("place_alert_enter", title: "Place Alert"), alertType: "place_alert_enter",
            userInfo: original("place_alert_enter", title: "Place Alert").userInfo, level: "full",
            env: crossing.environment(clock: now))
        let stamp = NotificationService.shortStamp(try XCTUnwrap(NotificationService.parseRFC3339(sentAt)))
        XCTAssertEqual(banner.title, "Arrival")
        XCTAssertEqual(banner.body, "Olivia arrived at Home · \(stamp)")

        let checkIn = try scene(me, row: try checkInRow(sealedBy: owner.sdk, userId: owner.userId, place: false,
                                                        body: "A circle member has checked in."),
                                roster: roster, confirmed: [owner.userId])
        let checkInBanner = await NotificationService.banner(
            for: original("check_in", title: "Check-in"), alertType: "check_in",
            userInfo: original("check_in", title: "Check-in").userInfo, level: "full",
            env: checkIn.environment(clock: now))
        XCTAssertEqual(checkInBanner.title, "Check-in")
        XCTAssertEqual(checkInBanner.body, "Olivia has checked in.", "a check-in carries no stamp")

        let generic = try scene(me, row: crossingRow(of: owner.userId), roster: roster, places: places,
                                confirmed: [owner.userId])
        let genericBanner = await NotificationService.banner(
            for: original("place_alert_enter", title: "Place Alert"), alertType: "place_alert_enter",
            userInfo: original("place_alert_enter", title: "Place Alert").userInfo, level: "generic",
            env: generic.environment(clock: now))
        XCTAssertEqual(genericBanner.title, "Place Alert")
        XCTAssertEqual(genericBanner.body, "Tap to view · \(stamp)", "generic: the server's words, stamped")
    }

    // MARK: - This account's own sealed name (what lets the others name it)

    /// The name sealed is this account's own, as web and Android pick it: the
    /// display name, else the address; nothing when there is neither.
    func testThisAccountsNameIsItsOwnDisplayNameElseItsAddress() {
        XCTAssertEqual(CircleManager.ownName(displayName: " RV Dana ", email: "dana@example.test"), "RV Dana")
        XCTAssertEqual(CircleManager.ownName(displayName: "  ", email: "dana@example.test"), "dana@example.test")
        XCTAssertEqual(CircleManager.ownName(displayName: nil, email: "dana@example.test"), "dana@example.test")
        XCTAssertNil(CircleManager.ownName(displayName: nil, email: ""))
    }

    /// Owed only when it would not open here as this name under the current
    /// version, and only while this device can seal under that version.
    func testThisAccountsSealedNameIsOwedOnlyWhenItWouldNotOpenAsItsName() {
        XCTAssertTrue(CircleManager.ownNameOwed(name: "Dana", opened: nil, holdsCurrentKey: true), "none on its row")
        XCTAssertFalse(CircleManager.ownNameOwed(name: "Dana", opened: (text: "Dana", current: true),
                                                 holdsCurrentKey: true), "there, current, the same: nothing to do")
        XCTAssertTrue(CircleManager.ownNameOwed(name: "Dana", opened: (text: "Dana", current: false),
                                                holdsCurrentKey: true), "sealed under an older key: a newcomer can't open it")
        XCTAssertTrue(CircleManager.ownNameOwed(name: "Dana B", opened: (text: "Dana", current: true),
                                                holdsCurrentKey: true), "renamed since")
        XCTAssertFalse(CircleManager.ownNameOwed(name: "Dana", opened: nil, holdsCurrentKey: false),
                       "behind: nothing is sealed under a key that isn't current")
        for blank in [nil, "", "   "] as [String?] {
            XCTAssertFalse(CircleManager.ownNameOwed(name: blank, opened: nil, holdsCurrentKey: true), "no name to send")
        }
        // The rotation trigger: only when this device's key moved on.
        XCTAssertTrue(CircleManager.versionAdvanced(from: 1, to: 2))
        XCTAssertTrue(CircleManager.versionAdvanced(from: nil, to: 1), "a first key")
        XCTAssertFalse(CircleManager.versionAdvanced(from: 2, to: 2), "nothing rotated")
        XCTAssertFalse(CircleManager.versionAdvanced(from: 2, to: nil))
    }

    /// The request is the route's (`PUT /circles/{id}/display-name`, the body
    /// web and Android send), and what it carries opens through every path a
    /// reader uses: the extension's (`SOSCheck.openedName`,
    /// `BackgroundHandover.displayNames`) and the app's roster load
    /// (`decryptDataV2(…, "display_name")`). A name already sealed under the
    /// current version — by this account's other device or its web session,
    /// with the same SDK call — is not sent again; one sealed under an older
    /// version is.
    func testThisAccountsSealedNameIsWhatTheOthersOpen() throws {
        let (owner, me, _) = try world()
        let sealed = try me.sdk.encryptDataV2(circleId: circleId, plaintext: "RV Dana", fieldTag: "display_name")
        let body = try APIService.makeWireEncoder().encode(
            SetCircleDisplayNameRequest(encryptedDisplayName: EncryptedBlobRequest(nonce: sealed.nonce,
                                                                                   ciphertext: sealed.ciphertext)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["encrypted_display_name"])
        let blobJSON = try XCTUnwrap(json["encrypted_display_name"] as? [String: String])
        XCTAssertEqual(blobJSON, ["nonce": sealed.nonce, "ciphertext": sealed.ciphertext])

        // The owner's apps read it off the roster, as every surface does.
        let rowData = try JSONSerialization.data(withJSONObject: rosterRow(me, sealedName: sealed))
        let row = try APIService.makeWireDecoder().decode(CircleMemberResponse.self, from: rowData)
        XCTAssertEqual(SOSCheck.openedName(row, circleId: circleId, crypto: owner.sdk), "RV Dana")
        XCTAssertEqual(BackgroundHandover.displayNames([row], circleId: circleId, crypto: owner.sdk)[me.userId], "RV Dana")
        XCTAssertEqual(try owner.sdk.decryptDataV2(circleId: circleId, encryptedData: sealed, fieldTag: "display_name"),
                       "RV Dana")

        // Current here: not sent again. After a rotation: sent again.
        func opened(_ blob: EncryptedData) throws -> (text: String, current: Bool) {
            let text = try me.sdk.decryptDataV2Opened(circleId: circleId, encryptedData: blob, fieldTag: "display_name")
            return (text.text, me.sdk.isCurrentKeyVersion(circleId: circleId, keyVersion: text.keyVersion))
        }
        XCTAssertFalse(CircleManager.ownNameOwed(name: "RV Dana", opened: try opened(sealed), holdsCurrentKey: true))
        let v2 = try owner.sdk.prepareKeyRotation(
            circleId: circleId, senderUserId: owner.userId, memberUserIds: [owner.userId, me.userId],
            memberPublicKeysHex: [owner.sharing, me.sharing], memberSigningPubkeysHex: [owner.signing, me.signing],
            currentCircleNamePlaintext: "Family")
        let bundle = try XCTUnwrap(v2.memberKeys.first { $0.userId == me.userId }).bundle
        try me.sdk.storeCircleKey(
            circleId: circleId, encryptedKey: bundle.encryptedCircleKey.nonce + bundle.encryptedCircleKey.ciphertext,
            senderPublicKey: bundle.ephemeralPublicKey, keyVersion: 2, senderUserId: owner.userId,
            recipientUserId: me.userId, wrapSignatureHex: bundle.wrapSignature, senderSigningPubkeyHex: owner.signing)
        XCTAssertTrue(CircleManager.ownNameOwed(name: "RV Dana", opened: try opened(sealed), holdsCurrentKey: true),
                      "sealed under v1, and v2 is current now")
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The extension names with the app's words and keeps nothing: no names
    /// file in the app group, nothing written anywhere.
    func testTheExtensionKeepsNoNames() throws {
        let named = try source("NotificationExtension/NamedBanner.swift")
        for write in [".set(", "write(", "persist", "FileManager", "UserDefaults(", "storeKeys", "put("] {
            XCTAssertFalse(named.contains(write), write)
        }
        let project = try source("project.yml")
        let extensionTarget = try XCTUnwrap(project.range(of: "  NotificationExtension:\n"))
        let copy = try XCTUnwrap(project.range(of: "      - path: App/Notifications/NamedNotificationCopy.swift\n",
                                               range: extensionTarget.upperBound..<project.endIndex))
        let nextTarget = try XCTUnwrap(project.range(of: "\n  Track", range: extensionTarget.upperBound..<project.endIndex))
        XCTAssertLessThan(copy.lowerBound, nextTarget.lowerBound, "compiled into the extension")
        let service = try source("NotificationExtension/NotificationService.swift")
        XCTAssertTrue(service.contains("let banner = await Self.banner(for: original, alertType: alertType, "
                                       + "userInfo: userInfo, level: level)"))
        let inbox = try source("App/Views/Notifications/NotificationsView.swift")
        XCTAssertTrue(inbox.contains(
            "row.summaryRow(titleOverride: named?.title, bodyOverride: named?.body ?? inviteBody(for: row))"))
        // This account's own sealed name: after creating, joining and a
        // rotation, and checked on every roster load.
        let circles = try source("App/Managers/CircleManager.swift")
        XCTAssertTrue(circles.contains("Task { await self.sealOwnNameIfOwed(circleId: circleId, ownRow: ownRow) }"))
        XCTAssertTrue(circles.contains("        circles.append(circle)\n        // This account's name, sealed for the circle it just made.\n"
                                       + "        Task { await self.sealOwnName(circleId: circle.id) }\n"))
        XCTAssertTrue(circles.contains("if Self.versionAdvanced(from: versionBefore, to: try? cryptoManager.getActiveVersion(circleId: circleId)) {\n"
                                       + "                Task { await self.sealOwnName(circleId: circleId) }"))
        XCTAssertTrue(try source("App/Managers/InvitesManager.swift")
            .contains("Task { await CircleManager.shared.sealOwnName(circleId: invite.circleId) }"))
        XCTAssertTrue(try source("App/Services/APIService.swift")
            .contains("return try await put(path: \"/api/v1/circles/\\(circleId)/display-name\","))
        // A fetched alert names its raiser only through the receivers' rules.
        let manager = try source("App/Managers/NotificationsManager.swift")
        XCTAssertTrue(manager.contains("raisers[sosId] = .some(Self.raiser(of: opened, marks: marks))"))
        XCTAssertFalse(manager.contains("raisers[sosId] = .some(CanonicalId.of(opened.raiserId))"))
    }
}
