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
import PingolinTrackSDK

/// Track's data export (GDPR Article 20), iOS side.
///
/// WHY THIS EXISTS
///   Sections 8 and 13 of the Terms tell people to export before a deadline —
///   premium history at 30 days, termination for cause at 30, wind-down at 90
///   — so an iPhone-only user needs a real export on this device.
///
/// THE FILE IS THE SAME ONE THE WEB AND ANDROID WRITE. Format decisions live in
/// `TrackBackupFile`; this file is about getting the data and opening it.
///
/// DECRYPTION HAPPENS HERE, ON THE DEVICE. The server hands back ciphertext it
/// cannot read; the keys are in the SDK's keystore. Rows whose key this device
/// does not hold are dropped rather than written as blobs — a backup full of
/// unreadable ciphertext is not a backup, and the count in the envelope would
/// say otherwise.
///
/// THE EXPORT NEVER WRITES THIS DEVICE'S KEY STORE. The circle keys the file
/// carries are wraps with no signer, the server's word; storing one here would
/// make it a circle's first key on trust. They open in a key store of the
/// export's own instead (`ExportKeys`), and a row only such a key opened says
/// so in the file (`key_unverified`), for every restore to leave out.
///
/// Mirrors the Android app's `ExportRepository`. Where the two differ, the Kotlin
/// is the original and the difference is a bug in one of them.
actor DataExportService {

    /// Personal/self key, stored under the nil UUID. Device names and personal
    /// place keys live under it.
    private static let selfCircleUUID = "00000000-0000-0000-0000-000000000000"

    /// Stop rather than spin. The loop ends on the server's own has_more flags;
    /// this only catches a server that keeps claiming more without advancing.
    /// Hitting it FAILS the export rather than returning a short file, because a
    /// file that looks whole when it is not is only discovered at restore time.
    private static let maxPages = 500

    enum ExportError: LocalizedError {
        case incomplete(pages: Int)
        case noData

        var errorDescription: String? {
            switch self {
            case .incomplete(let pages):
                return "Export incomplete: stopped after \(pages) pages while the server still reported more data. Try a shorter date range."
            case .noData:
                return "Export returned no data."
            }
        }
    }

    struct Built {
        let fileName: String
        let data: Data
        let sectionCounts: [String: Int]
    }

    /// One page of the export: the server's, or a test's.
    typealias FetchPage = (
        _ startDayBucket: Int?,
        _ endDayBucket: Int?,
        _ include: Set<String>,
        _ includePreferences: Bool,
        _ cursors: [String: String]
    ) async throws -> DataExportResponse

    /// This device's key store. The export only ever READS it.
    private let crypto: CryptoManager
    /// This account's sharing private key, as the Keychain holds it (base64
    /// text), for the export's own key store. Read only when the file carries a
    /// circle key this device does not hold.
    private let privateKey: () -> Data?
    private let fetchPage: FetchPage

    init(
        api: APIService = .shared,
        crypto: CryptoManager,
        privateKey: @escaping () -> Data? = { KeychainService.shared.getData(for: .sharingPrivateKey) },
        fetchPage: FetchPage? = nil
    ) {
        self.crypto = crypto
        self.privateKey = privateKey
        self.fetchPage = fetchPage ?? { start, end, include, includePreferences, cursors in
            try await api.exportData(
                startDayBucket: start,
                endDayBucket: end,
                include: include,
                includePreferences: includePreferences,
                cursors: cursors
            )
        }
    }

    /// Fetch every page, decrypt, and build the file body.
    ///
    /// - Parameters:
    ///   - startDayBucket: days since the Unix epoch; nil exports the server
    ///     default (last 30 days).
    ///   - generatedAt: ISO-8601 stamp for the envelope, injectable for tests.
    func buildBackup(
        startDayBucket: Int? = nil,
        endDayBucket: Int? = nil,
        generatedAt: String = ISO8601DateFormatter().string(from: Date()),
        /// Non-nil seals the file under this passphrase. Nil keeps the readable
        /// export, which is what portability needs.
        passphrase: String? = nil
    ) async throws -> Built {
        var merged: DataExportResponse?
        // Config sections always travel: tiny next to the history sections, and
        // the part a restore can actually put back.
        var outstanding: Set<String> = [
            "devices", "circles", "places", "check_ins", "locations",
            "alerts", "alert_rules", "inactivity_alerts", "privacy",
            "circle_invites", "alert_events", "place_shares",
            "web_push_subscriptions", "boundary_events",
            "destinations", "circle_notifications", "notification_history", "circle_activity",
            // Format 1.9. The server serves it only when the request says so,
            // which every page's request does while it is outstanding.
            "blocked_people",
        ]
        var pages = 0

        while !outstanding.isEmpty {
            if pages >= Self.maxPages {
                throw ExportError.incomplete(pages: Self.maxPages)
            }
            pages += 1

            let last = merged
            let page = try await fetchPage(
                startDayBucket,
                endDayBucket,
                outstanding,
                // Singleton: asked for on the first request only, then carried
                // forward. Re-requesting refetches the same object.
                last?.preferences == nil,
                Self.cursors(from: last)
            )

            merged = Self.merge(merged, page, outstanding: outstanding)

            outstanding = Self.stillOutstanding(outstanding, after: page)
        }

        guard let raw = merged else { throw ExportError.noData }

        // The export's own key store: in memory only (never given storage,
        // never loaded), and a local of this call, so it goes when the call
        // returns (the SDK zeroizes its keys on drop). Not cleared with
        // `clearAllKeys`: every clear of a key store goes through `OwedWipe`,
        // which would note this one's state as the live store's.
        let fileKeys = CryptoManager()
        let keys = ExportKeys.open(raw.circles ?? [], live: crypto, file: fileKeys, privateKey: privateKey)
        let decrypted = decryptAll(raw, keys)
        let file = TrackBackupFile.build(
            raw: raw,
            decrypted: decrypted,
            pagesFetched: pages,
            // Reaching here means the paging loop ran to the end; it throws
            // rather than returning short.
            isComplete: true,
            generatedAt: generatedAt
        )
        var data = try TrackBackupFile.encode(file)

        // Sealing is OPT-IN. A plaintext export is what makes portability work
        // — another tool can read it — and a passphrase is what turns it into a
        // backup worth keeping. The SDK owns the container so a file sealed on a
        // phone opens on the website and the other way round.
        if let pass = passphrase, !pass.isEmpty {
            let sealed = try sealBackupFile(
                payload: String(decoding: data, as: UTF8.self),
                passphrase: pass,
                product: "pingolin-track",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            data = Data(sealed.utf8)
        }

        var counts: [String: Int] = [:]
        if let v = decrypted.devices { counts["devices"] = v.count }
        if let v = decrypted.circles { counts["circles"] = v.count }
        if let v = decrypted.places { counts["places"] = v.count }
        if let v = decrypted.checkIns { counts["check_ins"] = v.count }
        if let v = decrypted.locations { counts["locations"] = v.count }

        return Built(
            fileName: "pingolin-track-export-\(Self.fileStamp(generatedAt)).json",
            data: data,
            sectionCounts: counts
        )
    }

    // MARK: - Paging

    /// The sections still to be paged after `page`: every one that reported no
    /// more, or came back with no rows, has dropped out.
    ///
    /// Every section the loop asks for is named here, and that is the point of
    /// its being one function a test can call: a section that is asked for and
    /// never dropped is asked for again on every request, and the export ends
    /// at the page limit as "incomplete", for everyone.
    static func stillOutstanding(_ outstanding: Set<String>, after page: DataExportResponse) -> Set<String> {
        var left = outstanding
        let m = page.metadata
        dropFinished(&left, "devices", m.devicesHasMore, page.devices?.count ?? 0)
        dropFinished(&left, "circles", m.circlesHasMore, page.circles?.count ?? 0)
        dropFinished(&left, "places", m.placesHasMore, page.places?.count ?? 0)
        dropFinished(&left, "check_ins", m.checkInsHasMore, page.checkIns?.count ?? 0)
        dropFinished(&left, "locations", m.locationsHasMore, page.locations?.count ?? 0)
        dropFinished(&left, "alerts", m.alertsHasMore, page.alerts?.count ?? 0)
        dropFinished(&left, "alert_rules", m.alertRulesHasMore, page.alertRules?.count ?? 0)
        dropFinished(&left, "inactivity_alerts", m.inactivityAlertsHasMore, page.inactivityAlerts?.count ?? 0)
        dropFinished(&left, "privacy", m.privacyHasMore, page.privacy?.count ?? 0)
        dropFinished(&left, "circle_invites", m.circleInvitesHasMore, page.circleInvites?.count ?? 0)
        dropFinished(&left, "alert_events", m.alertEventsHasMore, page.alertEvents?.count ?? 0)
        dropFinished(&left, "place_shares", m.placeSharesHasMore, page.placeShares?.count ?? 0)
        dropFinished(&left, "web_push_subscriptions", m.webPushSubscriptionsHasMore, page.webPushSubscriptions?.count ?? 0)
        dropFinished(&left, "boundary_events", m.boundaryEventsHasMore, page.boundaryEvents?.count ?? 0)
        dropFinished(&left, "destinations", m.destinationsHasMore, page.destinations?.count ?? 0)
        dropFinished(&left, "circle_notifications", m.circleNotificationsHasMore, page.circleNotifications?.count ?? 0)
        dropFinished(&left, "notification_history", m.notificationHistoryHasMore, page.notificationHistory?.count ?? 0)
        dropFinished(&left, "circle_activity", m.circleActivityHasMore, page.circleActivity?.count ?? 0)
        dropFinished(&left, "blocked_people", m.blockedPeopleHasMore, page.blockedPeople?.count ?? 0)
        return left
    }

    /// Drop a section once the server stops reporting more, or hands back none.
    private static func dropFinished(
        _ outstanding: inout Set<String>,
        _ key: String,
        _ hasMore: Bool,
        _ rows: Int
    ) {
        guard outstanding.contains(key) else { return }
        if !hasMore || rows == 0 { outstanding.remove(key) }
    }

    /// Per-section keyset cursors: the (sort key, id) of the last row received.
    /// Half a cursor is a WRONG cursor — the server restarts a section given only
    /// one part — so each pair is set together or not at all.
    static func cursors(from last: DataExportResponse?) -> [String: String] {
        guard let last else { return [:] }
        var c: [String: String] = [:]

        if let d = last.devices?.last, let ms = d.createdAtMs {
            c["cursor_device_created_at_ms"] = String(ms)
            c["cursor_device_id"] = d.id
        }
        if let ci = last.circles?.last {
            // The server orders a NULL join bucket as 0; mirror it or the cursor
            // and the ORDER BY disagree and rows are skipped.
            c["cursor_circle_joined_bucket"] = String(ci.joinedDayBucket ?? 0)
            c["cursor_circle_id"] = ci.circleId
        }
        if let p = last.places?.last {
            c["cursor_place_created_bucket"] = String(p.createdDayBucket ?? 0)
            c["cursor_place_id"] = p.id
        }
        if let k = last.checkIns?.last {
            c["cursor_check_in_bucket"] = String(k.createdDayBucket ?? 0)
            c["cursor_check_in_id"] = k.id
        }
        if let a = last.alerts?.last, let id = a.string("id"), let ms = a.int64("created_at_ms") {
            c["cursor_alert_created_at_ms"] = String(ms)
            c["cursor_alert_id"] = id
        }
        if let a = last.alertRules?.last, let id = a.string("id"), let ms = a.int64("created_at_ms") {
            c["cursor_alert_rule_created_at_ms"] = String(ms)
            c["cursor_alert_rule_id"] = id
        }
        if let a = last.inactivityAlerts?.last, let id = a.string("id"), let ms = a.int64("created_at_ms") {
            c["cursor_inactivity_created_at_ms"] = String(ms)
            c["cursor_inactivity_id"] = id
        }
        // One row per (user, circle), so the circle id alone is a total order —
        // the only section needing no tiebreaker.
        if let pr = last.privacy?.last, let cid = pr.string("circle_id") {
            c["cursor_privacy_circle_id"] = cid
        }
        if let i = last.circleInvites?.last, let id = i.string("id"), let ms = i.int64("created_at_ms") {
            c["cursor_invite_created_at_ms"] = String(ms)
            c["cursor_invite_id"] = id
        }
        if let a = last.alertEvents?.last, let id = a.string("id"), let ms = a.int64("triggered_at_ms") {
            c["cursor_alert_event_triggered_at_ms"] = String(ms)
            c["cursor_alert_event_id"] = id
        }
        // Keyed by (place, circle) rather than a timestamp.
        if let ps = last.placeShares?.last, let pid = ps.string("place_id"), let cid = ps.string("circle_id") {
            c["cursor_place_share_place_id"] = pid
            c["cursor_place_share_circle_id"] = cid
        }
        if let w = last.webPushSubscriptions?.last, let id = w.string("id"), let ms = w.int64("created_at_ms") {
            c["cursor_web_push_created_at_ms"] = String(ms)
            c["cursor_web_push_id"] = id
        }
        if let b = last.boundaryEvents?.last, let id = b.string("id"), let ms = b.int64("occurred_at_ms") {
            c["cursor_boundary_event_occurred_at_ms"] = String(ms)
            c["cursor_boundary_event_id"] = id
        }
        if let v = last.destinations?.last, let id = v.string("id"), let ms = v.int64("created_at_ms") {
            c["cursor_destination_created_at_ms"] = String(ms)
            c["cursor_destination_id"] = id
        }
        if let v = last.circleNotifications?.last, let id = v.string("id"), let ms = v.int64("created_at_ms") {
            c["cursor_circle_notification_created_at_ms"] = String(ms)
            c["cursor_circle_notification_id"] = id
        }
        if let v = last.notificationHistory?.last, let id = v.string("id"), let ms = v.int64("created_at_ms") {
            c["cursor_notification_created_at_ms"] = String(ms)
            c["cursor_notification_id"] = id
        }
        if let v = last.circleActivity?.last, let id = v.string("id"), let ms = v.int64("created_at_ms") {
            c["cursor_circle_activity_created_at_ms"] = String(ms)
            c["cursor_circle_activity_id"] = id
        }
        if let v = last.blockedPeople?.last, let id = v.string("id"), let ms = v.int64("created_at_ms") {
            c["cursor_blocked_person_created_at_ms"] = String(ms)
            c["cursor_blocked_person_id"] = id
        }
        if let l = last.locations?.last {
            c["cursor_day_bucket"] = String(l.dayBucket ?? 0)
            if let ms = l.insertedAtMs { c["cursor_inserted_at_ms"] = String(ms) }
            if let rk = l.rowKey { c["cursor_row_key"] = rk }
        }
        return c
    }

    /// Accumulate a page onto what we already have, section by section.
    ///
    /// A section drops out of `outstanding` once finished, and a finished
    /// section is not re-appended — otherwise the last page of every section
    /// would be duplicated into the file.
    static func merge(
        _ soFar: DataExportResponse?,
        _ page: DataExportResponse,
        outstanding: Set<String>
    ) -> DataExportResponse {
        guard let soFar else { return page }
        func join<T>(_ a: [T]?, _ b: [T]?, _ active: Bool) -> [T]? {
            guard active else { return a }
            guard let b else { return a }
            return (a ?? []) + b
        }
        return DataExportResponse(
            metadata: page.metadata,
            devices: join(soFar.devices, page.devices, outstanding.contains("devices")),
            circles: join(soFar.circles, page.circles, outstanding.contains("circles")),
            places: join(soFar.places, page.places, outstanding.contains("places")),
            checkIns: join(soFar.checkIns, page.checkIns, outstanding.contains("check_ins")),
            locations: join(soFar.locations, page.locations, outstanding.contains("locations")),
            alerts: join(soFar.alerts, page.alerts, outstanding.contains("alerts")),
            alertRules: join(soFar.alertRules, page.alertRules, outstanding.contains("alert_rules")),
            inactivityAlerts: join(soFar.inactivityAlerts, page.inactivityAlerts, outstanding.contains("inactivity_alerts")),
            privacy: join(soFar.privacy, page.privacy, outstanding.contains("privacy")),
            preferences: soFar.preferences ?? page.preferences,
            profile: soFar.profile ?? page.profile,
            circleInvites: join(soFar.circleInvites, page.circleInvites, outstanding.contains("circle_invites")),
            alertEvents: join(soFar.alertEvents, page.alertEvents, outstanding.contains("alert_events")),
            placeShares: join(soFar.placeShares, page.placeShares, outstanding.contains("place_shares")),
            webPushSubscriptions: join(soFar.webPushSubscriptions, page.webPushSubscriptions, outstanding.contains("web_push_subscriptions")),
            boundaryEvents: join(soFar.boundaryEvents, page.boundaryEvents, outstanding.contains("boundary_events")),
            destinations: join(soFar.destinations, page.destinations, outstanding.contains("destinations")),
            circleNotifications: join(soFar.circleNotifications, page.circleNotifications, outstanding.contains("circle_notifications")),
            notificationHistory: join(soFar.notificationHistory, page.notificationHistory, outstanding.contains("notification_history")),
            circleActivity: join(soFar.circleActivity, page.circleActivity, outstanding.contains("circle_activity")),
            blockedPeople: join(soFar.blockedPeople, page.blockedPeople, outstanding.contains("blocked_people"))
        )
    }

    // MARK: - Keys

    /// Which key store reads a row.
    ///
    /// A circle this device holds a key for is read ONLY from this device's
    /// store, so a different key the file names for it is never used. Any other
    /// circle is read from the export's own store, and a row that opens there is
    /// marked. A row with no circle, or one naming the personal key's slot, reads
    /// the personal key from this device's store alone: the export's store never
    /// holds it. Circles are routed by their canonical id.
    struct ExportKeys {
        struct Reader {
            let store: CryptoManager
            /// Canonical: the id the key is stored and looked up under.
            let circleId: String
            /// Only the export's own key opens it.
            let unverified: Bool
        }

        /// This device's store: only ever read.
        let live: CryptoManager
        /// The export's own store.
        let file: CryptoManager
        /// Circles (canonical ids) whose wrap in the file opened in `file`.
        let opened: Set<String>

        /// A circle row's reader. Nil for the personal key's slot, an id that is
        /// no UUID, or a circle no key here opens.
        func circle(_ raw: String?) -> Reader? {
            guard let id = CanonicalId.circle(raw) else { return nil }
            if opened.contains(id) { return Reader(store: file, circleId: id, unverified: true) }
            guard live.hasCircleKey(circleId: id) else { return nil }
            return Reader(store: live, circleId: id, unverified: false)
        }

        /// The reader for a row that may have no circle: the personal key when it
        /// has none or names the personal key's slot, otherwise its circle's.
        func row(_ raw: String?) -> Reader? {
            guard let raw, !CanonicalId.isPersonalSlot(raw) else {
                guard live.hasCircleKey(circleId: DataExportService.selfCircleUUID) else { return nil }
                return Reader(store: live, circleId: DataExportService.selfCircleUUID, unverified: false)
            }
            return circle(raw)
        }

        /// Open the file's circle wraps in `file`: only a circle this device
        /// holds no key for, and never under the personal key's slot or an id
        /// that is no UUID. The wraps carry no sender and no signature, so the
        /// SDK takes each as a first key on trust, in a store nothing else reads.
        static func open(
            _ circles: [CircleMembershipExportRow],
            live: CryptoManager,
            file: CryptoManager,
            privateKey: () -> Data?
        ) -> ExportKeys {
            let wraps = circles.compactMap { c -> (circleId: String, key: String, sender: String, version: Int32)? in
                guard let id = CanonicalId.circle(c.circleId),
                      !live.hasCircleKey(circleId: id),
                      let wrapped = c.encryptedCircleKey,
                      let ephemeral = c.ephemeralPublicKey
                else { return nil }
                // hex(nonce || ciphertext), no separator, as the SDK expects.
                return (id, "\(wrapped.nonce)\(wrapped.ciphertext)", ephemeral, Int32(c.keyVersion ?? 1))
            }
            // Without this account's private key nothing opens, and those
            // circles' rows are left out.
            guard !wraps.isEmpty, loadPrivateKey(into: file, privateKey) else {
                return ExportKeys(live: live, file: file, opened: [])
            }
            for wrap in wraps {
                try? file.storeCircleKey(
                    circleId: wrap.circleId,
                    encryptedKey: wrap.key,
                    senderPublicKey: wrap.sender,
                    keyVersion: wrap.version,
                    senderUserId: "",
                    recipientUserId: "",
                    wrapSignatureHex: nil,
                    senderSigningPubkeyHex: nil
                )
            }
            let opened = Set(wraps.map { $0.circleId }.filter { file.hasCircleKey(circleId: $0) })
            return ExportKeys(live: live, file: file, opened: opened)
        }

        /// This account's private key into `file`, and the bytes read wiped
        /// straight after. Never logged.
        private static func loadPrivateKey(into file: CryptoManager, _ read: () -> Data?) -> Bool {
            guard var bytes = read() else { return false }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return (try? file.importPrivateKey(privateKeyBase64: String(decoding: bytes, as: UTF8.self))) != nil
        }
    }

    // MARK: - Decryption

    private func decryptAll(_ raw: DataExportResponse, _ keys: ExportKeys) -> TrackBackupFile.Decrypted {
        var out = TrackBackupFile.Decrypted()
        out.devices = raw.devices?.compactMap { decryptDevice($0) }
        out.circles = raw.circles?.compactMap { decryptCircle($0, keys) }
        out.places = raw.places?.compactMap { decryptPlace($0, keys) }
        out.checkIns = raw.checkIns?.compactMap { decryptCheckIn($0, keys) }
        out.locations = raw.locations?.compactMap { decryptLocation($0, keys) }
        return out
    }

    private func decryptDevice(_ d: DeviceExportRow) -> TrackBackupFile.Device? {
        // Device names are sealed under the user's self key, stored at the nil
        // UUID. A missing self key is not a reason to drop the row: the id and
        // the registration date are still the user's data.
        // The placeholder goes into a file the user opens later with no app
        // around to explain it, so it says what it is and nothing about why.
        var name = "[unavailable]"
        if let blob = d.encryptedName {
            if crypto.hasCircleKey(circleId: Self.selfCircleUUID) {
                name = (try? crypto.decryptDataV2(
                    circleId: Self.selfCircleUUID,
                    encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                    fieldTag: "device_name"
                )) ?? "[unavailable]"
            }
        } else {
            name = ""
        }
        return TrackBackupFile.Device(
            id: d.id,
            name: name,
            platform: d.deviceType,
            registeredDayBucket: d.dayBucket ?? 0
        )
    }

    private func decryptCircle(_ c: CircleMembershipExportRow, _ keys: ExportKeys) -> TrackBackupFile.Circle? {
        // Never the personal key's slot, or an id no circle has: an
        // export's circle row is the server's word. Written under its
        // canonical id.
        guard let reader = keys.circle(c.circleId),
              let blob = c.encryptedName,
              let name = try? reader.store.decryptDataV2(
                circleId: reader.circleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: "name"
              )
        else { return nil }

        return TrackBackupFile.Circle(
            circleId: reader.circleId,
            name: name,
            role: c.role ?? "member",
            keyVersion: c.keyVersion ?? 1,
            joinedDayBucket: c.joinedDayBucket,
            keyUnverified: reader.unverified
        )
    }

    private func decryptPlace(_ p: PlaceExportRow, _ keys: ExportKeys) -> TrackBackupFile.Place? {
        // A PERSONAL place carries circle_id: null and is sealed under a
        // per-place key wrapped to the self key. Treating a null circle id as
        // "skip" would drop every personal place from the export silently.
        var placeKey: String?
        if let wrapped = p.wrappedKey,
           let nonce = p.wrappedKeyNonce,
           crypto.hasCircleKey(circleId: Self.selfCircleUUID) {
            // A populated wrap on a row that is actually legacy is survivable —
            // fall through and try the circle key.
            placeKey = try? crypto.unwrapPlaceKey(
                targetId: Self.selfCircleUUID,
                wrappedKey: wrapped,
                wrappedKeyNonce: nonce
            )
        }

        guard let nameBlob = p.encryptedName, let locBlob = p.encryptedLocation else { return nil }
        let encName = EncryptedData(nonce: nameBlob.nonce, ciphertext: nameBlob.ciphertext)
        let encLoc = EncryptedData(nonce: locBlob.nonce, ciphertext: locBlob.ciphertext)

        let name: String
        let latitude: Double
        let longitude: Double
        var unverified = false

        if let key = placeKey {
            guard let n = try? crypto.decryptWithPlaceKeyV2(placeKeyHex: key, encryptedData: encName, fieldTag: "name"),
                  let json = try? crypto.decryptWithPlaceKeyV2(placeKeyHex: key, encryptedData: encLoc, fieldTag: "location"),
                  let point = Self.parseExportedLocation(json)
            else { return nil }
            name = n
            latitude = point.latitude
            longitude = point.longitude
        } else {
            // Only the legacy path needs the circle key, or the personal key's
            // for a place with no circle; the envelope path is already satisfied
            // by the unwrap above.
            guard let reader = keys.row(p.circleId),
                  let n = try? reader.store.decryptDataV2(circleId: reader.circleId, encryptedData: encName, fieldTag: "name"),
                  let loc = try? reader.store.decryptLocation(circleId: reader.circleId, encryptedLocation: encLoc)
            else { return nil }
            name = n
            latitude = loc.latitude
            longitude = loc.longitude
            unverified = reader.unverified
        }

        return TrackBackupFile.Place(
            id: p.id,
            circleId: p.circleId,
            name: name,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: p.radiusMeters ?? 0,
            createdDayBucket: p.createdDayBucket ?? 0,
            keyUnverified: unverified
        )
    }

    /// A place-key location decrypts to the JSON the writer stored, not to the
    /// SDK's Location type, so it is parsed rather than typed.
    static func parseExportedLocation(_ json: String) -> (latitude: Double, longitude: Double)? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let lat = (obj["latitude"] ?? obj["lat"]) as? Double
        let lon = (obj["longitude"] ?? obj["lng"] ?? obj["lon"]) as? Double
        guard let lat, let lon else { return nil }
        return (lat, lon)
    }

    private func decryptCheckIn(_ c: CheckInExportRow, _ keys: ExportKeys) -> TrackBackupFile.CheckIn? {
        // A check-in with no circle is sealed under the SELF key, the same way a
        // personal place is — `decryptPlace` resolves it identically. Treating a
        // null circle id as "skip" would drop every personal check-in from the
        // export silently.
        guard let reader = keys.row(c.circleId) else { return nil }

        let message = c.encryptedMessage.flatMap { blob in
            try? reader.store.decryptDataV2(
                circleId: reader.circleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: "message"
            )
        }
        let location = c.encryptedLocation.flatMap { blob in
            try? reader.store.decryptLocation(
                circleId: reader.circleId,
                encryptedLocation: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
            )
        }

        return TrackBackupFile.CheckIn(
            id: c.id,
            // The ORIGINAL, not the resolved one: the self-circle UUID is the
            // decryption domain, not this check-in's circle. `decryptPlace`
            // carries `p.circleId` through for the same reason.
            circleId: c.circleId,
            checkInType: c.checkInType ?? "general",
            message: message,
            latitude: location?.latitude,
            longitude: location?.longitude,
            createdDayBucket: c.createdDayBucket ?? 0,
            keyUnverified: reader.unverified
        )
    }

    private func decryptLocation(_ l: LocationExportRow, _ keys: ExportKeys) -> TrackBackupFile.LocationRow? {
        guard let reader = keys.row(l.circleId) else { return nil }

        let timestamp: Int64? = l.encryptedTimestamp.flatMap { blob in
            guard let s = try? reader.store.decryptDataV2(
                circleId: reader.circleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: "timestamp"
            ) else { return nil }
            return Int64(s)
        }

        guard let point = try? reader.store.decryptLocation(
            circleId: reader.circleId,
            encryptedLocation: EncryptedData(
                nonce: l.encryptedPayload.nonce,
                ciphertext: l.encryptedPayload.ciphertext
            )
        ) else { return nil }

        return TrackBackupFile.LocationRow(
            deviceId: l.deviceId ?? "",
            circleId: l.circleId,
            dayBucket: l.dayBucket ?? 0,
            timestamp: timestamp,
            latitude: point.latitude,
            longitude: point.longitude,
            accuracy: point.accuracy,
            keyId: l.keyId ?? "",
            // Carried through, not derived. It is the server's own insertion
            // stamp and the identity a restore keys the row on — web's
            // `restoreHistory` drops any point that arrives without it.
            insertedAtMs: l.insertedAtMs,
            // Carried through, and not re-derivable here: the server computes it
            // over the ciphertext this function has just decrypted away. Without
            // it, restoring the file a second time doubles the whole history.
            rowKey: l.rowKey,
            keyUnverified: reader.unverified
        )
    }

    // MARK: - Helpers

    /// Days since the Unix epoch, the unit every bucket in the export uses.
    static func dayBucket(_ date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// `YYYY-MM-DDTHH:MM:SSZ` -> `YYYY-MM-DD`, for the file name.
    private static func fileStamp(_ iso: String) -> String {
        String(iso.prefix(10))
    }
}
