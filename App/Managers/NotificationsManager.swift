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
import Combine
import PingolinTrackSDK

/// Observable view-state for the user's notification inbox. Wraps the
/// real /api/v1/notifications cluster: list (cursor-paginated), unread
/// count, mark-read, mark-all-read. Mirrors the Android app's
/// NotificationsViewModel; pagination is opt-in via loadMore().
@MainActor
final class NotificationsManager: ObservableObject {
    static let shared = NotificationsManager()

    @Published private(set) var notifications: [NotificationResponse] = []
    @Published private(set) var unreadCount: Int = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasMore = true
    /// Who and where each named row is about, by row id (`NotificationNames`).
    /// The names themselves are looked up when the row is drawn.
    @Published private(set) var subjects: [String: NotificationNames.Subject] = [:]
    /// The detail level the listed rows were personalised at (`personalize`):
    /// the inbox reloads when the setting has changed since.
    private(set) var personalizedAt: NamedNotificationCopy.Detail?

    /// The "Notification detail" setting, as `personalize` reads it.
    static var detailNow: NamedNotificationCopy.Detail {
        NamedNotificationCopy.Detail(level: UserSettings.shared.notificationDetailLevel.rawValue)
    }

    private let api = APIService.shared
    private var nextCursor: String?
    private let isoFormatter = ISO8601DateFormatter()

    private init() {}

    /// Logout teardown for `AuthManager.logout()`: drop the personalised
    /// (decrypted member/place names) notification inbox and its pagination
    /// state so one account's notifications can't linger in memory for the
    /// next on the same device. Mirrors `CircleManager.reset()`. The on-disk
    /// first-page cache is wiped separately by `CacheStore.shared.clearAll()`
    /// in logout.
    func reset() {
        notifications = []
        unreadCount = 0
        nextCursor = nil
        hasMore = true
        subjects = [:]
        raisers = [:]
        claimants = [:]
        rostersLoaded = []
        personalizedAt = nil
    }

    // MARK: - Local (client-only) inactivity firings in the bell

    /// Device-local inactivity firings surface in the bell alongside server
    /// rows (they're client_only — the server can't record them). They use a
    /// "local-" id so mark-read / dismiss route to LocalInactivityStore and
    /// skip the (404-ing) server round-trip. Mirrors android.
    private static func localRow(_ e: LocalInactivityEvent) -> NotificationResponse {
        NotificationResponse(
            id: e.id,
            circleId: e.circleId,
            notificationType: "inactivity_alert",
            title: "Inactivity alert",
            body: "\(e.memberName) hasn't sent a location recently",
            metadata: nil,
            isRead: e.isRead,
            createdDayBucket: Int(e.triggeredAt.timeIntervalSince1970 / 86_400),
            createdAt: ISO8601DateFormatter().string(from: e.triggeredAt)
        )
    }

    /// The battery equivalent. Same reasoning: the comparison happens on this
    /// device against a level the server cannot read, so there is no server row
    /// for the bell to fetch and a firing would otherwise leave nothing behind
    /// but a tray notification the user may have swiped away.
    private static func localRow(_ e: LocalBatteryEvent) -> NotificationResponse {
        NotificationResponse(
            id: e.id,
            circleId: e.circleId,
            notificationType: "low_battery",
            title: "Low battery",
            body: "\(e.memberName)'s phone is at \(e.batteryLevel)%",
            metadata: nil,
            isRead: e.isRead,
            createdDayBucket: Int(e.triggeredAt.timeIntervalSince1970 / 86_400),
            createdAt: ISO8601DateFormatter().string(from: e.triggeredAt)
        )
    }

    /// Merge open local firings into a server page, newest-first.
    private func mergeLocal(into serverRows: [NotificationResponse]) -> [NotificationResponse] {
        let local = LocalInactivityStore.shared.bellEvents.map { Self.localRow($0) }
            + LocalBatteryStore.shared.bellEvents.map { Self.localRow($0) }
        guard !local.isEmpty else { return serverRows }
        return (serverRows + local).sorted { sortDate($0) > sortDate($1) }
    }

    /// Both local stores are hydrated together: a bell that counted one and not
    /// the other would show a badge whose number the list cannot account for.
    private func loadLocalStores() async {
        await LocalInactivityStore.shared.loadIfNeeded()
        await LocalBatteryStore.shared.loadIfNeeded()
    }

    private var localUnreadCount: Int {
        LocalInactivityStore.shared.bellUnreadCount + LocalBatteryStore.shared.bellUnreadCount
    }

    private func sortDate(_ r: NotificationResponse) -> Date {
        if let s = r.createdAt, let d = isoFormatter.date(from: s) { return d }
        if let b = r.createdDayBucket { return Date(timeIntervalSince1970: TimeInterval(b) * 86_400) }
        return .distantPast
    }

    /// Replace the list with a fresh first page. Use after login or on
    /// pull-to-refresh.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await loadLocalStores()
        rostersLoaded = []
        do {
            let response = try await api.listNotifications(limit: 50)
            let detail = Self.detailNow
            notifications = mergeLocal(into: response.notifications.map { Self.personalize($0, detail: detail) })
            personalizedAt = detail
            unreadCount = response.unreadCount + localUnreadCount
            nextCursor = response.nextCursor
            hasMore = response.hasMore ?? (response.nextCursor != nil)
            // Cache the first page only — pagination state isn't worth
            // serializing for offline. Cached raw (un-personalised);
            // copy is re-resolved on load so it tracks key/member state.
            await CacheStore.shared.save(response.notifications, forKey: "notifications.firstPage")
            await name(response.notifications, replacing: true)
        } catch {
            if notifications.isEmpty,
               let cached: [NotificationResponse] = await CacheStore.shared.load(
                   [NotificationResponse].self,
                   forKey: "notifications.firstPage"
               ) {
                print("[Track] notifications refresh: serving \(cached.count) row(s) from cache after \(error)")
                ErrorBanner.shared.post(error)
                let detail = Self.detailNow
                notifications = mergeLocal(into: cached.map { Self.personalize($0, detail: detail) })
                personalizedAt = detail
                unreadCount = cached.filter { !$0.isRead }.count + localUnreadCount
                hasMore = false
                await name(cached, replacing: true)
            } else {
                print("[Track] notifications refresh failed: \(error)")
            }
        }
    }

    /// Append the next page when the user scrolls past the end.
    func loadMore() async {
        guard let cursor = nextCursor, hasMore else { return }
        do {
            let response = try await api.listNotifications(limit: 50, cursor: cursor)
            let detail = personalizedAt ?? Self.detailNow
            notifications.append(contentsOf: response.notifications.map { Self.personalize($0, detail: detail) })
            unreadCount = response.unreadCount
            nextCursor = response.nextCursor
            hasMore = response.hasMore ?? (response.nextCursor != nil)
            await name(response.notifications, replacing: false)
        } catch {
            print("[Track] notifications loadMore failed: \(error)")
        }
    }

    /// Best-effort E2EE personalisation for destination rows. The server
    /// stores only generic E2EE-safe text ("A circle member shared a new
    /// destination") plus circle-key ciphertexts in metadata; the client
    /// decrypts those into "Alice created a destination for Home" so the
    /// bell list reads like a real notification. Any failure (missing
    /// keys, unknown circle, departed member) keeps the server's generic
    /// copy. Mirrors the Android app's
    /// `NotificationRepository.personalizeDestinationCopy`.
    ///
    /// The "Notification detail" setting governs these names as it does every
    /// named row: Generic keeps the server's words, Names only names the
    /// person and never the place.
    private static func personalize(_ row: NotificationResponse,
                                    detail: NamedNotificationCopy.Detail) -> NotificationResponse {
        let type = row.notificationType

        // place_alert_removed: a deleted place cascades and silently drops
        // every member's alert on it. The server is E2EE-blind to the place
        // name (it's gone), so it sends generic copy + place_id; resolve the
        // still-cached name, falling back to the generic body. Mirrors the
        // Android app.
        if type == "place_alert_removed" {
            guard detail == .full, case .string(let placeId)? = row.metadata?["place_id"],
                  let body = placeAlertRemovedBody(
                      placeName: PlaceManager.shared.places.first(where: { $0.id == placeId })?.name,
                      detail: detail),
                  body != row.body
            else { return row }
            return NotificationResponse(
                id: row.id,
                circleId: row.circleId,
                notificationType: row.notificationType,
                title: row.title,
                body: body,
                metadata: row.metadata,
                isRead: row.isRead,
                createdDayBucket: row.createdDayBucket,
                createdAt: row.createdAt
            )
        }

        guard type == "destination_shared" || type == "destination_arrival", detail != .generic,
              let metadata = row.metadata else { return row }

        var meta: [String: String] = [:]
        for (key, value) in metadata {
            switch value {
            case .string(let v): meta[key] = v
            case .bool(let v): meta[key] = v ? "true" : "false"
            case .int(let v): meta[key] = String(v)
            case .double(let v): meta[key] = String(v)
            case .array, .object, .null: break
            }
        }

        let copy = DestinationsManager.shared.resolveNotificationCopy(metadata: meta)
        // Someone this device doesn't name is "Someone", never the server's
        // plaintext name.
        let actor = copy.actorName ?? (copy.actorKnown ? NamedNotificationCopy.someone : nil)
        guard let body = destinationBody(type: type, actor: actor, label: copy.destLabel,
                                         isSelf: meta["self"] == "true", detail: detail),
              body != row.body else { return row }

        return NotificationResponse(
            id: row.id,
            circleId: row.circleId,
            notificationType: row.notificationType,
            title: row.title,
            body: body,
            metadata: row.metadata,
            isRead: row.isRead,
            createdDayBucket: row.createdDayBucket,
            createdAt: row.createdAt
        )
    }

    /// A removed place's row at `detail`: its name only at "Names and
    /// places"; nil keeps the server's words.
    nonisolated static func placeAlertRemovedBody(placeName: String?,
                                                  detail: NamedNotificationCopy.Detail) -> String? {
        guard detail == .full, let placeName, !placeName.isEmpty else { return nil }
        return "A place alert on \(placeName) was removed because the place was deleted"
    }

    /// A destination row's body at `detail`: who at "Names only" and up, the
    /// destination's label at "Names and places" only; nil keeps the server's
    /// words (Generic, or nothing to name).
    nonisolated static func destinationBody(type: String, actor: String?, label: String?, isSelf: Bool,
                                            detail: NamedNotificationCopy.Detail) -> String? {
        guard detail != .generic else { return nil }
        let label = detail == .full ? label : nil
        switch (type, actor, label) {
        case ("destination_shared", let actor?, let label?):
            return "\(actor) created a destination for \(label)"
        case ("destination_shared", let actor?, nil):
            return "\(actor) shared a new destination"
        case ("destination_shared", nil, let label?):
            return "New destination: \(label)"
        case ("destination_arrival", _, let label?) where isSelf:
            return "You arrived at \(label)"
        case ("destination_arrival", let actor?, let label) where !isSelf:
            return label.map { "\(actor) arrived at \($0)" } ?? "\(actor) arrived at their destination"
        case ("destination_arrival", nil, let label?) where !isSelf:
            return "Arrived at \(label)"
        default:
            return nil
        }
    }

    // MARK: - Names

    /// Who asked to be checked on, by alert id, and who is asking to take a
    /// circle over, by claim id (both in their one form), as looked up: nil
    /// when the answer was that nobody can be named. A failure that may pass
    /// is not kept, so the next refresh asks again.
    private var raisers: [String: String?] = [:]
    private var claimants: [String: String?] = [:]
    /// Circles whose roster this refresh has loaded for a name it missed.
    private var rostersLoaded: Set<String> = []

    /// At most this many alerts and claims are looked up per page: the rest
    /// keep the server's words until a later refresh.
    static let lookupsPerPage = 10

    /// Work out who and where `rows` are about (`NotificationNames`), from
    /// this device's own data; then, for a person it doesn't name yet, load
    /// that circle's roster once per refresh — a rename or a newcomer since it
    /// last did. Only circles this account is in are ever asked about.
    private func name(_ rows: [NotificationResponse], replacing: Bool) async {
        let named = rows.filter { NamedNotificationCopy.namedTypes.contains($0.notificationType) }
        await lookUpRaisers(named)
        await lookUpClaimants(named)
        let crypto = SDKCrypto.cryptoManager
        let knownRaisers = raisers.compactMapValues { $0 }
        let knownClaimants = claimants.compactMapValues { $0 }
        var found = replacing ? [:] : subjects
        for row in named {
            found[row.id] = NotificationNames.subject(
                of: row,
                openSealedUserId: { circleId, nonce, sealed in
                    try? crypto.decryptDataV2(circleId: circleId,
                                              encryptedData: EncryptedData(nonce: nonce, ciphertext: sealed),
                                              fieldTag: "user_id")
                },
                raisers: knownRaisers, claimants: knownClaimants)
        }
        // How many others were already responding, counted over every row loaded.
        subjects = NotificationNames.respondersBefore(found, rows: notifications)

        let circleManager = CircleManager.shared
        let me = AuthManager.shared.userId
        let missed = Set(found.values.filter {
            NotificationNames.misses($0, me: me, members: circleManager.members, opened: circleManager.openedNames)
        }.map(\.circleId))
        for circleId in missed.sorted() where !rostersLoaded.contains(circleId)
            && circleManager.circles.contains(where: { CanonicalId.same($0.id, circleId) }) {
            rostersLoaded.insert(circleId)
            try? await circleManager.loadMembers(for: circleId)
        }
    }

    /// The raiser of each "needs attention" row's alert: from the open alerts
    /// this app holds, else the alert itself (`GET /api/v1/sos/{id}`, served
    /// while its raiser is still a member), opened here and named by the
    /// receivers' rules (`raiser(of:marks:)`).
    private func lookUpRaisers(_ rows: [NotificationResponse]) async {
        // A resolved row that says who closed it names the closer, not who asked.
        let ids = rows.filter { row in
            row.notificationType == "sos_alert"
                || (row.notificationType == "sos_resolved" && NotificationNames.strings(row.metadata)["closed_by"] == nil)
        }.compactMap { CanonicalId.of(NotificationNames.strings($0.metadata)["sos_id"]) }
        var asked = 0
        for sosId in Set(ids).sorted() where raisers[sosId] == nil {
            if let open = SOSManager.shared.activeAlerts.first(where: { CanonicalId.same($0.id, sosId) }) {
                raisers[sosId] = .some(CanonicalId.of(open.userId))
                continue
            }
            guard asked < Self.lookupsPerPage else { break }
            asked += 1
            do {
                let response = try await api.getSOSAlert(alertId: sosId)
                let me = AuthManager.shared.userId
                let opened = SOSReceiverRules.open(response, myUserId: me, myDeviceId: nil,
                                                   crypto: SDKCrypto.cryptoManager)
                let marks = me.map {
                    SOSManager.marksState(SOSAlarmMarks.shared.read(account: $0), circleId: response.circleId,
                                          sosId: response.id, hash: opened.payloadHash)
                } ?? .read(ended: false, seenCurrent: false)
                raisers[sosId] = .some(Self.raiser(of: opened, marks: marks))
            } catch let error as APIError where Self.isFinal(error) {
                raisers[sosId] = .some(nil)
            } catch {
                // Offline or a passing failure: asked again next refresh.
            }
        }
    }

    /// Who asked to be checked on, as the receivers' rules let a row name
    /// them: an alert whose parts opened under the version this device seals
    /// under (`current`), or one this phone saw current before (its "seen
    /// current" mark for this payload: sticky across a rotation). One that
    /// opened only under an older key — history, or a removed member's
    /// forgery a server lists — names nobody, as its alarm would not.
    nonisolated static func raiser(of opened: SOSReceiverRules.Opened, marks: SOSReceiverRules.Marks) -> String? {
        var seenCurrent = false
        if case .read(_, let seen) = marks { seenCurrent = seen }
        guard opened.current || seenCurrent else { return nil }
        return CanonicalId.of(opened.raiserId)
    }

    /// The claimant of each claim row, while that claim is the circle's live
    /// one (`GET …/claim-ownership` serves only a pending claim).
    private func lookUpClaimants(_ rows: [NotificationResponse]) async {
        var asked = 0
        for row in rows where row.notificationType == "circle_ownership_claim" {
            guard let claimId = CanonicalId.of(NotificationNames.strings(row.metadata)["claim_id"]),
                  claimants[claimId] == nil, let circleId = CanonicalId.circle(row.circleId) else { continue }
            guard asked < Self.lookupsPerPage else { break }
            asked += 1
            do {
                let claim = try await api.getOwnershipClaim(circleId: circleId)
                claimants[claimId] = .some(claim.flatMap {
                    CanonicalId.same($0.claimId, claimId) ? CanonicalId.of($0.claimantUserId) : nil
                })
            } catch let error as APIError where Self.isFinal(error) {
                claimants[claimId] = .some(nil)
            } catch {
                // Asked again next refresh.
            }
        }
    }

    /// An answer that will not change by asking again: the thing is gone, or
    /// not this account's to see.
    private static func isFinal(_ error: APIError) -> Bool {
        let codes = [error.code, error.errorCode].compactMap { $0 }
        return codes.contains { $0 == "http_404" || $0 == "http_403" || $0.hasSuffix("_not_found") }
    }

    /// Sync just the unread badge — cheap to poll without paying the
    /// full list cost.
    func refreshUnreadCount() async {
        await loadLocalStores()
        do {
            unreadCount = try await api.unreadNotificationCount().count
                + localUnreadCount
        } catch {
            // Surface nothing — failures here are best-effort polling.
        }
    }

    func markRead(_ notification: NotificationResponse) async {
        guard !notification.isRead else { return }
        // Local firings carry no server row — mark in the local store.
        if notification.id.hasPrefix("local-") {
            // "local-batt-" is a battery firing; anything else local is an
            // inactivity one. Routing every local id to the inactivity store
            // would silently drop the read flag for half of them.
            if notification.id.hasPrefix("local-batt-") {
                LocalBatteryStore.shared.markRead(id: notification.id)
            } else {
                LocalInactivityStore.shared.markRead(id: notification.id)
            }
            applyReadFlag(toId: notification.id)
            return
        }
        do {
            _ = try await api.markNotificationRead(notificationId: notification.id)
            applyReadFlag(toId: notification.id)
        } catch {
            print("[Track] markRead failed: \(error)")
        }
    }

    func markAllRead() async {
        // Optimistic: flip every row + the badge locally FIRST so the tap
        // responds instantly — the server returns {data:<count>}, which the
        // generic EmptyResponse decode handles inconsistently, and gating the
        // UI behind that await would make the checkmark look like it did
        // nothing.
        // Local firings have no server row — clear their read state too.
        LocalInactivityStore.shared.markAllRead()
        LocalBatteryStore.shared.markAllRead()
        notifications = notifications.map { row in
            guard !row.isRead else { return row }
            return NotificationResponse(
                id: row.id,
                circleId: row.circleId,
                notificationType: row.notificationType,
                title: row.title,
                body: row.body,
                metadata: row.metadata,
                isRead: true,
                createdDayBucket: row.createdDayBucket,
                createdAt: row.createdAt
            )
        }
        unreadCount = 0
        do {
            _ = try await api.markAllNotificationsRead()
        } catch {
            // Best-effort — a later refresh reconciles if the server didn't take it.
            print("[Track] markAllRead failed: \(error)")
        }
    }

    private func applyReadFlag(toId id: String) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else { return }
        let row = notifications[index]
        notifications[index] = NotificationResponse(
            id: row.id,
            circleId: row.circleId,
            notificationType: row.notificationType,
            title: row.title,
            body: row.body,
            metadata: row.metadata,
            isRead: true,
            createdDayBucket: row.createdDayBucket,
            createdAt: row.createdAt
        )
        unreadCount = max(0, unreadCount - 1)
    }

    /// Delete a notification (swipe-to-dismiss). Optimistic: drop the
    /// local row first so the list updates instantly, then call the
    /// server; on failure re-insert at its original index and surface
    /// the error. A 404 means the row is already gone server-side —
    /// treat that as success (leave it removed). Mirrors the Android
    /// app's NotificationRepository.deleteNotification; server route
    /// DELETE /api/v1/notifications/:id.
    func delete(_ notification: NotificationResponse) async {
        guard let index = notifications.firstIndex(where: { $0.id == notification.id }) else { return }
        let removed = notifications.remove(at: index)
        let wasUnread = !removed.isRead
        if wasUnread { unreadCount = max(0, unreadCount - 1) }
        // Local firing — drop it from the device store; no server row exists.
        if notification.id.hasPrefix("local-") {
            if notification.id.hasPrefix("local-batt-") {
                LocalBatteryStore.shared.delete(id: notification.id)
            } else {
                LocalInactivityStore.shared.delete(id: notification.id)
            }
            return
        }
        do {
            _ = try await api.deleteNotification(notificationId: notification.id)
        } catch let error as APIError where error.code == "http_404" {
            // Already gone server-side — the optimistic removal was right.
        } catch {
            // Revert: put the row back where it was.
            let target = min(index, notifications.count)
            notifications.insert(removed, at: target)
            if wasUnread { unreadCount += 1 }
            print("[Track] notification delete failed: \(error)")
            ErrorBanner.shared.post(error)
        }
    }
}
