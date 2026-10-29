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
import CoreLocation
import UserNotifications
import PingolinTrackSDK

/// Observable view-state for the user's travel intentions. Wraps the
/// real /api/v1/destinations cluster end-to-end through the SDK
/// CryptoManager. Mirrors the Android app's DestinationsViewModel
/// and DestinationRepository: refresh, create, cancel, report
/// arrival, delete, auto-arrival, notification-copy resolution.
@MainActor
final class DestinationsManager: ObservableObject {
    static let shared = DestinationsManager()

    /// Auto-arrival fires when a fix lands within this distance of one
    /// of the user's own active destinations. Matches the Android app's
    /// DESTINATION_ARRIVAL_RADIUS_METERS.
    static let arrivalRadiusMeters: Double = 100

    /// A destination within this distance of a saved place is described
    /// by the place's name ("place name if possible, else address").
    /// Matches the auto-arrival radius so the two notions of "at" agree.
    private static let placeMatchRadiusMeters: Double = 100

    @Published private(set) var destinations: [Destination] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    /// The ids of the server's last WHOLE list: a live refresh that came back
    /// under the route's limit. Nil after a refresh that failed or served the
    /// saved copy, or one at the limit (it may be partial): a row missing
    /// from those proves nothing. What a waiting arrival is checked against.
    private(set) var listedIds: Set<String>?

    /// GET /api/v1/destinations answers at most this many rows (`LIMIT 100`).
    static let listLimit = 100

    var activeDestinations: [Destination] {
        Self.live(in: destinations)
    }

    /// The rows that count as LIVE — what the map draws (`MapView`'s
    /// `destinationMarkers` filters this list), what auto-arrival considers,
    /// and what the inbox files under "Active".
    ///
    /// Static so the marker rule is reachable from a test without standing the
    /// singleton up, and single-sourced so the six surfaces that discriminate
    /// on liveness cannot drift apart (a drifted surface would put `expired`
    /// destinations on the map).
    static func live(in all: [Destination]) -> [Destination] {
        all.filter { $0.status.isLive }
    }

    /// The current user's OWN destinations. The in-app list shows only
    /// these — other members' shared destinations stay
    /// on the map + via push, not in this list, and only the creator can
    /// arrive/cancel/delete.
    var myDestinations: [Destination] {
        guard let userId = AuthManager.shared.userId else { return [] }
        return destinations.filter { $0.isMine(userId) }
    }

    /// This account's own live destinations (`Destination.isMine`): the only
    /// ones an arrival is ever reported for by itself.
    static func ownLive(in all: [Destination], me: String?) -> [Destination] {
        live(in: all).filter { $0.isMine(me) }
    }

    private let api = APIService.shared
    private let cryptoManager = SDKCrypto.cryptoManager
    private var cancellables = Set<AnyCancellable>()

    /// Per-process re-entry guard: ids we've already reported this run,
    /// so a stream of fixes inside the radius doesn't fire N reports.
    /// Un-flagged on failure so a later fix can retry. Mirrors the
    /// Android app's autoArrivedDestinations.
    private var autoArrivedDestinations = Set<String>()

    private init() {
        // Auto-arrival rides the same fix pipeline the upload path uses.
        // The subscription goes live when anything first touches the
        // singleton (MainTabView.loadInitialData on launch).
        LocationService.shared.locationUpdates
            .sink { [weak self] location in
                Task { @MainActor [weak self] in
                    await self?.checkAutoArrival(location: location)
                }
            }
            .store(in: &cancellables)
    }

    /// Logout teardown for `AuthManager.logout()`: clear the decrypted
    /// destinations (coordinates + names) and the per-run auto-arrival guard
    /// so one account's travel intentions can't linger in memory for the next
    /// on the same device. Mirrors `CircleManager.reset()`. The on-disk cache
    /// is ciphertext-only and is wiped separately by
    /// `CacheStore.shared.clearAll()` in logout.
    func reset() {
        destinations = []
        listedIds = nil
        autoArrivedDestinations.removeAll()
        lastError = nil
    }

    /// The saved copy of the list: the server's rows, still sealed.
    static let cacheKey = "destinations.list"

    /// A circle this account is in no more (`CircleManager.circleGone`): its
    /// destinations leave the map and the list now, and the saved copy too,
    /// so a refresh that fails can't bring them back from it. The server no
    /// longer serves them.
    func forgetCircle(_ circleId: String) async {
        let kept = destinations.withoutCircle(circleId) { $0.circleId }
        if kept.count != destinations.count { destinations = kept }
        if let saved: [DestinationResponse] = await CacheStore.shared.load([DestinationResponse].self, forKey: Self.cacheKey) {
            let keptRows = saved.withoutCircle(circleId) { $0.circleId }
            if keptRows.count != saved.count { await CacheStore.shared.save(keptRows, forKey: Self.cacheKey) }
        }
    }

    /// Refresh the list. Decrypts each row's encryptedDestination /
    /// encryptedDestName / encryptedEta / encryptedUserId with the owning
    /// circle's key (already loaded via CircleManager.loadCircles).
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let cacheKey = Self.cacheKey
        do {
            let responses = try await api.listDestinations()
            // Prune hides HERE, against the raw server ids, and only on a
            // successful fetch. Never from view code: `destinations` is empty
            // until this method first completes, and `prune` is destructive on
            // an empty list, so a prune during view-body evaluation would
            // delete every hide for the active circle on each launch.
            //
            // Raw ids because a hide is a row id, not a decrypted destination:
            // whether a key happens to be loaded has nothing to do with
            // whether the row still exists (the decrypted rows come from
            // `compactMap { decrypt }`, so one transient missing circle key
            // would drop the hides too). Server ids only, never the cache
            // path below — a cached list can be arbitrarily old, and pruning
            // against stale data is the same class of mistake. The web client
            // prunes only after a successful fetch for exactly this reason.
            Self.pruneHides(against: responses)
            destinations = await Task.detached { [self, responses] in responses.compactMap { self.decryptResponse($0) } }.value
            listedIds = responses.count < Self.listLimit ? Set(responses.map(\.id)) : nil
            await CacheStore.shared.save(responses, forKey: cacheKey)
            lastError = nil
        } catch {
            listedIds = nil
            if let cached: [DestinationResponse] = await CacheStore.shared.load([DestinationResponse].self, forKey: cacheKey) {
                print("[Track] destinations refresh: serving \(cached.count) row(s) from cache after \(error)")
                ErrorBanner.shared.post(error)
                destinations = await Task.detached { [self, cached] in cached.compactMap { self.decryptResponse($0) } }.value
                lastError = nil
            } else {
                lastError = "Failed to load destinations: \(error.plainText)"
            }
        }
    }

    /// Forget hides for destinations the server no longer lists.
    ///
    /// Grouped per circle because that is the unit `HiddenDestinationsStore`
    /// prunes in: a circle absent from the response is left alone rather than
    /// treated as empty, since `/destinations` is `LIMIT 100` and a partial
    /// list must never be read as "these are gone".
    ///
    /// Every returned id counts as live, not just the active ones. The server
    /// already drops arrived rows and ages cancelled ones out after seven
    /// days, so "still in the response" is the real liveness test. Pruning
    /// against ACTIVE ids alone would silently un-hide anything the user hid
    /// from the inbox's "Past" section while that row was still on screen.
    ///
    /// `store` is injectable so the grouping can be tested against a scratch
    /// UserDefaults rather than the device's.
    static func pruneHides(
        against responses: [DestinationResponse],
        store: HiddenDestinationsStore = .shared
    ) {
        var idsByCircle: [String: [String]] = [:]
        for response in responses {
            idsByCircle[response.circleId, default: []].append(response.id)
        }
        for (circleId, ids) in idsByCircle {
            store.prune(circleId: circleId, liveIds: ids)
        }
    }

    /// Create a destination. Encrypts coordinate + creator user id (and
    /// optional name + ETA) with the circle key, POSTs to
    /// /api/v1/destinations.
    ///
    /// Nil when this iPhone is behind in the circle: the destination then
    /// waits. `waiting`: the waiting change being run now, whose id goes as
    /// the request id; a refusal while behind is then thrown, not queued
    /// again.
    @discardableResult
    func createDestination(
        circleId: String,
        name: String?,
        coordinate: CLLocationCoordinate2D,
        eta: Date? = nil,
        notifyArrival: Bool = true,
        waiting: PendingChange? = nil
    ) async throws -> Destination? {
        guard let userId = AuthManager.shared.userId else {
            throw APIError(code: "unauthorized", message: "No user id available")
        }
        // Nothing new is sealed under a key the circle has moved past.
        do {
            try CircleManager.shared.requireCurrentKey(for: circleId)
        } catch CircleManager.CircleError.keyNotCurrent where waiting == nil {
            let now = Date()
            try PendingChanges.queue(
                .destination, circleId: circleId,
                inputs: .destination(.init(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude,
                                           eta: eta, notifyArrival: notifyArrival)),
                subject: name,
                // 24 hours, or its arrival time.
                expiresAt: eta.map { max(now, $0) }, now: now)
            return nil
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let sdkLocation = PingolinTrackSDK.Location(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: nil,
            speed: nil,
            heading: nil,
            accuracy: nil,
            timestamp: nowMs,
            batteryLevel: nil,
            isCharging: nil as Bool?
        )
        let encDest = try cryptoManager.encryptLocation(circleId: circleId, location: sdkLocation)
        let encUser = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: userId, fieldTag: "user_id")

        var encName: EncryptedBlobRequest? = nil
        if let n = name, !n.isEmpty {
            let blob = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: n, fieldTag: "dest_name")
            encName = EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }

        var encEta: EncryptedBlobRequest? = nil
        var etaDayBucket: Int? = nil
        if let eta = eta {
            let etaMs = Int64(eta.timeIntervalSince1970 * 1000)
            let blob = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: String(etaMs), fieldTag: "eta")
            encEta = EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
            etaDayBucket = Int(eta.timeIntervalSince1970 / 86_400)
        }

        let request = CreateDestinationRequest(
            circleId: circleId,
            encryptedDestination: EncryptedBlobRequest(
                nonce: encDest.nonce,
                ciphertext: encDest.ciphertext
            ),
            encryptedDestName: encName,
            encryptedEta: encEta,
            etaDayBucket: etaDayBucket,
            notifyArrival: notifyArrival,
            encryptedUserId: EncryptedBlobRequest(nonce: encUser.nonce, ciphertext: encUser.ciphertext),
            clientRequestId: waiting?.requestId()
        )

        let response = try await api.createDestination(request: request)

        // We have the cleartext locally; assemble the model directly.
        let destination = Destination(
            id: response.id,
            circleId: circleId,
            userId: userId,
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            status: Destination.Status.from(response.status),
            notifyArrival: response.notifyArrival,
            estimatedArrivalAt: eta,
            startedAt: Date(timeIntervalSince1970: TimeInterval(response.startedDayBucket) * 86_400),
            arrivedAt: response.arrivedDayBucket
                .map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) },
            creatorId: response.userId
        )
        destinations.insert(destination, at: 0)
        return destination
    }

    /// Switch a destination's status to "cancelled" via PUT /api/v1/destinations/:id.
    func cancelDestination(_ destination: Destination) async throws {
        guard destination.isMine(AuthManager.shared.userId) else {
            throw APIError(code: "not_owner", message: "You can only cancel your own destinations")
        }
        let request = UpdateDestinationRequest(
            status: "cancelled",
            encryptedEta: nil,
            etaDayBucket: nil,
            notifyArrival: nil
        )
        do {
            _ = try await api.updateDestination(destinationId: destination.id, request: request)
        } catch let apiError as APIError where apiError.code == "http_404" {
            // The row is gone server-side — deleted from another device, or
            // never ours. Re-pull instead of leaving a phantom on screen; the
            // refresh IS how the list self-corrects. Same reasoning as
            // reportArrival's 404 path, and mirrors the Android app.
            await refresh()
            throw APIError(
                code: "destination_not_found",
                message: "This destination is no longer there — the list has been refreshed"
            )
        }
        if let index = destinations.firstIndex(where: { $0.id == destination.id }) {
            var updated = destinations[index]
            updated.status = .cancelled
            destinations[index] = updated
        }
    }

    /// Report arrival. The client detects this locally by comparing the
    /// current location to the encrypted destination; the server only
    /// learns the destination id + a BLAKE3-hashed event type so it can
    /// route notifications without learning what happened.
    ///
    /// `byPerson`: the person's own "I've arrived". Only that one waits while
    /// this iPhone is behind; an automatic arrival is not a person's request
    /// and keeps its own handling. `waiting`: the waiting change being run
    /// now, with the time the person arrived.
    @discardableResult
    func reportArrival(
        destination: Destination,
        currentLocation: CLLocationCoordinate2D? = nil,
        byPerson: Bool = false,
        waiting: PendingChange? = nil
    ) async throws -> Int {
        guard let userId = AuthManager.shared.userId else {
            throw APIError(code: "unauthorized", message: "No user id available")
        }
        guard destination.isMine(userId) else {
            throw APIError(code: "not_owner", message: "You can only report arrival for your own destinations")
        }
        let circleId = destination.circleId
        var arrivedAt = Date()
        if case .arrived(let inputs)? = waiting?.inputs { arrivedAt = inputs.arrivedAt }
        // Nothing new is sealed under a key the circle has moved past.
        do {
            try CircleManager.shared.requireCurrentKey(for: circleId)
        } catch CircleManager.CircleError.keyNotCurrent where byPerson && waiting == nil {
            try PendingChanges.queue(
                .arrived, circleId: circleId,
                inputs: .arrived(.init(destinationId: destination.id, arrivedAt: arrivedAt,
                                       latitude: nil, longitude: nil)),
                seen: .init(privacy: CheckInManager.privacyNow(circleId: circleId)),
                subject: destination.name)
            return 0
        }
        let nowMs = Int64(arrivedAt.timeIntervalSince1970 * 1000)

        let encUser = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: userId, fieldTag: "user_id")
        let encEventType = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: "arrival", fieldTag: "event_type")
        let eventTypeHash = try cryptoManager.computeEventTypeHash(
            circleId: circleId,
            eventType: "arrival"
        )

        // Privacy posture gate (parity with SDKLocationStreamer / CheckInManager):
        // a paused / realtime-off / posture-unknown circle gets the arrival EVENT
        // but NO coordinates; an approximate/bubble circle gets a coarsened,
        // motion-stripped fix; exact only for an exact-mode circle. Without this,
        // an (auto or manual) arrival would leak exact coords to an
        // approximate/paused circle, defeating the sender-side coarsening.
        var encLocation: EncryptedBlobRequest? = nil
        if let coord = currentLocation,
           CircleManager.shared.mayStreamRealtime(to: circleId) {
            let fixLat: Double
            let fixLng: Double
            let fixAccuracy: Double?
            if let privacy = CircleManager.shared.privacySettings[circleId], privacy.sharesApproximately {
                let radiusMiles = privacy.bubbleRadius > 0 ? privacy.bubbleRadius : 1.0
                let cellMeters = radiusMiles * 1609.344
                let (coarseLat, coarseLng) = LocationCoarsener.coarsenLocation(
                    lat: coord.latitude,
                    lng: coord.longitude,
                    radiusMeters: cellMeters
                )
                fixLat = coarseLat
                fixLng = coarseLng
                fixAccuracy = cellMeters
            } else {
                fixLat = coord.latitude
                fixLng = coord.longitude
                fixAccuracy = nil
            }
            let sdkLocation = PingolinTrackSDK.Location(
                latitude: fixLat,
                longitude: fixLng,
                altitude: nil,
                speed: nil,
                heading: nil,
                accuracy: fixAccuracy,
                timestamp: nowMs,
                batteryLevel: nil,
                isCharging: nil as Bool?
            )
            let blob = try cryptoManager.encryptLocation(circleId: circleId, location: sdkLocation)
            encLocation = EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }

        let request = ReportArrivalRequest(
            encryptedLocation: encLocation,
            encryptedUserId: EncryptedBlobRequest(nonce: encUser.nonce, ciphertext: encUser.ciphertext),
            eventTypeHash: eventTypeHash,
            encryptedEventType: EncryptedBlobRequest(
                nonce: encEventType.nonce,
                ciphertext: encEventType.ciphertext
            ),
            // `nowMs` is stamped at the top of this arrival, before the encryption
            // and the POST below. The server records arrived_at = NOW() on receipt,
            // so without this the subscriber is shown when the report LANDED.
            encryptedOccurredAt: (try? cryptoManager.encryptDataV2(
                circleId: circleId,
                plaintext: String(nowMs),
                fieldTag: "occurred_at"
            )).map { EncryptedBlobRequest(nonce: $0.nonce, ciphertext: $0.ciphertext) }
        )

        // Resolve the label BEFORE reporting: a successful report deletes
        // the local row (arrived destinations leave the list immediately),
        // after which the saved-place lookup loses the row to match.
        let arrivalLabel = labelForDestination(destination)
        do {
            let response = try await api.reportDestinationArrival(
                destinationId: destination.id,
                request: request
            )
            // Arrived destinations leave the list immediately: the
            // server's list endpoint does not return arrived rows, so
            // removing locally is exactly what the next refresh would do
            // anyway — this just makes it instant instead of waiting for
            // the next sync. Mirrors the Android app.
            destinations.removeAll { $0.id == destination.id }
            // Immediate local "You've arrived!" — the server deliberately
            // sends the creator no arrival push (their in-app record is
            // inserted server-side), so the device that reported the
            // arrival is the one that must surface it. Fires for BOTH the
            // manual "Arrived" button and auto-arrival; the stable dedupe
            // key means a later self=true tickle replaces rather than
            // stacks. Mirrors the Android app.
            Self.postSelfArrivalNotification(destinationId: destination.id, label: arrivalLabel)
            return response.notificationsSent
        } catch let apiError as APIError where apiError.code == "http_404" {
            // Server says the row is no longer active (already
            // cancelled / arrived / expired by another device, or
            // never matched the user's id in the first place).
            // Re-pull the list so the local cache reflects reality
            // instead of speculatively flipping status to .arrived
            // and racing the source of truth. Mirrors the Android app.
            await refresh()
            throw APIError(
                code: "destination_not_active",
                message: "This destination is no longer active — refresh the list"
            )
        }
    }

    /// Delete the row. Backend route DELETE /api/v1/destinations/:id.
    func deleteDestination(_ destination: Destination) async throws {
        guard destination.isMine(AuthManager.shared.userId) else {
            throw APIError(code: "not_owner", message: "You can only delete your own destinations")
        }
        do {
            _ = try await api.deleteDestination(destinationId: destination.id)
        } catch let apiError as APIError where apiError.code == "http_404" {
            // Already gone. Dropping it locally is what the next refresh would
            // do anyway, but re-pull so anything else that changed alongside it
            // comes back too.
            await refresh()
            throw APIError(
                code: "destination_not_found",
                message: "This destination is no longer there — the list has been refreshed"
            )
        }
        destinations.removeAll { $0.id == destination.id }
    }

    // MARK: - Auto-arrival

    /// Report arrival for any of the current user's own active
    /// destinations now within `arrivalRadiusMeters` of the fix. Matches
    /// the product intent "no need for the user to report that they
    /// arrived" — the server-side push pipeline notifies the other circle
    /// members. Mirrors the Android app's
    /// `checkOwnLocationAgainstDestinations`.
    private func checkAutoArrival(location: CLLocation) async {
        guard let userId = AuthManager.shared.userId else { return }
        let mine = Self.ownLive(in: destinations, me: userId)
        guard !mine.isEmpty else { return }

        for dest in mine where !autoArrivedDestinations.contains(dest.id) {
            let there = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
            let meters = location.distance(from: there)
            guard meters <= Self.arrivalRadiusMeters else { continue }

            // Honor the circle's per-circle privacy posture for the AUTOMATIC
            // path. reportArrival already omits the coordinate blob when the
            // circle is paused/realtime-off, but the arrival EVENT itself is an
            // ambient presence+timing signal — suppress it for a
            // paused/realtime-off/posture-unknown circle so auto-arrival can't
            // defeat a pause. Skip WITHOUT marking auto-arrived so a later fix
            // re-fires once the user un-pauses while still at the destination.
            // Mirrors PlaceManager.reportOwnCrossing's guard. The manual
            // "Arrived" button stays available as explicit user intent.
            // Prime-on-miss so a cold-wake auto-arrival isn't fail-closed and
            // lost before this circle's privacy GET has landed.
            guard await CircleManager.shared.mayStreamRealtimePrimed(to: dest.circleId) else {
                print("[Track] auto-arrival: skipping \(dest.id) — circle \(dest.circleId) paused/realtime-off")
                continue
            }

            // Presence + timing near an E2EE destination — never let it land in
            // the release unified log.
            #if DEBUG
            print("[Track] auto-arrival: within \(Int(meters))m of destination \(dest.id); reporting")
            #endif
            autoArrivedDestinations.insert(dest.id)
            do {
                // reportArrival resolves the label, removes the local row,
                // and posts the local "You've arrived!" notification on
                // success — shared with the manual "Arrived" button.
                _ = try await reportArrival(
                    destination: dest,
                    currentLocation: location.coordinate
                )
            } catch {
                print("[Track] auto-arrival report failed for \(dest.id): \(error)")
                // Un-flag so a later fix can retry.
                autoArrivedDestinations.remove(dest.id)
            }
        }
    }

    /// Local "You've arrived!" notification for the destination creator.
    /// The stable per-destination identifier means a second post (the
    /// arrival detector is re-entrant across process restarts) replaces
    /// rather than stacks. Key string matches the Android app's
    /// AlertHandler.showSelfArrival dedupe key.
    static func postSelfArrivalNotification(destinationId: String, label: String?) {
        let content = UNMutableNotificationContent()
        content.title = "You've arrived!"
        // Names-only drops the destination label (it's a place).
        content.body = NotificationStamp.appended(
            to: NotificationDetailLevel.resolveBody(
                detailed: label.map { "You arrived at \($0)" } ?? "You arrived at your destination",
                namesOnly: "You arrived at your destination"
            )
        )
        content.sound = .default
        content.userInfo = [
            "type": "destination_arrival",
            "destination_id": destinationId,
            "self": "true",
        ]
        let request = UNNotificationRequest(
            identifier: "self-arrival-\(destinationId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Track] postSelfArrivalNotification add() failed: \(error)")
            }
        }
    }

    // MARK: - Notification copy

    /// Personalised copy for a destination notification, resolved from
    /// the circle-key ciphertexts the server embeds in notification
    /// metadata (encrypted_dest_name / encrypted_user_id + nonces, hex).
    /// The server is E2EE-blind, so "Alice arrived at Home" can only be
    /// assembled client-side. Mirrors the Android app's
    /// DestinationRepository.resolveNotificationCopy.
    struct NotificationCopy {
        /// Who did it, only as this device names a member: shown here, by the
        /// sealed name that opened here (`destinationActor`); nil otherwise.
        let actorName: String?
        /// The row says who did it (its sealed id opened here), whether or not
        /// their name did: unnamed, they are "Someone".
        var actorKnown = false
        let destLabel: String?
    }

    /// The name a destination row gives `actorId` in `circleId`: a member this
    /// device shows, by the sealed name that opened here, the rule every named
    /// row follows (`SOSManager.openedName`). Never the plaintext name the
    /// server keeps for older clients, which a member's `displayName` holds
    /// when their sealed one didn't open.
    nonisolated static func destinationActor(actorId: String?, circleId: String,
                                             members: [String: [CircleMember]],
                                             opened: [String: Set<String>]) -> String? {
        guard let actorId, let circle = CanonicalId.circle(circleId) else { return nil }
        return SOSManager.openedName(of: actorId, in: members[circle], opened: opened[circle])
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Resolve actor display name + destination label from a
    /// notification's metadata map. Every part is best-effort: missing
    /// keys, an unknown circle key, or a departed member just degrade to
    /// nils and callers fall back to generic copy.
    ///
    /// The label prefers a saved place within `placeMatchRadiusMeters`
    /// of the destination ("place name if possible"), falling back to
    /// the decrypted destination name — which the create flow seeds with
    /// the tapped place / searched address.
    func resolveNotificationCopy(metadata: [String: String]) -> NotificationCopy {
        guard let circleId = metadata["circle_id"], !circleId.isEmpty else {
            return NotificationCopy(actorName: nil, destLabel: nil)
        }

        let decryptedName: String? = decryptMetadataBlob(
            circleId: circleId,
            ciphertext: metadata["encrypted_dest_name"],
            nonce: metadata["dest_name_nonce"],
            fieldTag: "dest_name"
        )

        let actorId: String? = decryptMetadataBlob(
            circleId: circleId,
            ciphertext: metadata["encrypted_user_id"],
            nonce: metadata["user_id_nonce"],
            fieldTag: "user_id"
        ).flatMap { CanonicalId.of($0) }
        let actorName = Self.destinationActor(actorId: actorId, circleId: circleId,
                                              members: CircleManager.shared.members,
                                              opened: CircleManager.shared.openedNames)

        // Saved-place match needs coordinates, which only exist on the
        // locally-synced destination row (the metadata carries no
        // location ciphertext). If the row is already pruned, the
        // decrypted name is still a solid label.
        let placeName: String? = metadata["destination_id"].flatMap { destId in
            destinations.first(where: { $0.id == destId }).flatMap { dest in
                nearestPlaceName(circleId: circleId, latitude: dest.latitude, longitude: dest.longitude)
            }
        }

        return NotificationCopy(actorName: actorName, actorKnown: actorId != nil, destLabel: placeName ?? decryptedName)
    }

    /// Label for one of the user's own destinations (self-arrival
    /// notification): saved place name when the destination sits on one,
    /// else the destination's own decrypted name.
    func labelForDestination(_ dest: Destination) -> String? {
        nearestPlaceName(circleId: dest.circleId, latitude: dest.latitude, longitude: dest.longitude)
            ?? dest.name
    }

    private func decryptMetadataBlob(circleId: String, ciphertext: String?, nonce: String?, fieldTag: String) -> String? {
        guard let ciphertext = ciphertext, !ciphertext.isEmpty,
              let nonce = nonce, !nonce.isEmpty else { return nil }
        return try? cryptoManager.decryptDataV2(
            circleId: circleId,
            encryptedData: EncryptedData(nonce: nonce, ciphertext: ciphertext),
            fieldTag: fieldTag
        )
    }

    private func nearestPlaceName(circleId: String, latitude: Double, longitude: Double) -> String? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return PlaceManager.shared.places
            .filter { $0.circleId == circleId }
            .map { (place: $0, meters: here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.meters <= Self.placeMatchRadiusMeters }
            .min(by: { $0.meters < $1.meters })?
            .place.name
    }

    // MARK: - Decryption

    private nonisolated func decryptResponse(_ response: DestinationResponse) -> Destination? {
        let circleId = response.circleId
        guard let location = try? cryptoManager.decryptLocation(
            circleId: circleId,
            encryptedLocation: EncryptedData(
                nonce: response.encryptedDestination.nonce,
                ciphertext: response.encryptedDestination.ciphertext
            )
        ) else {
            return nil
        }

        let userId = (try? cryptoManager.decryptDataV2(
            circleId: circleId,
            encryptedData: EncryptedData(
                nonce: response.encryptedUserId.nonce,
                ciphertext: response.encryptedUserId.ciphertext
            ),
            fieldTag: "user_id"
        )) ?? ""

        let name: String? = response.encryptedDestName.flatMap { blob in
            try? cryptoManager.decryptDataV2(
                circleId: circleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: "dest_name"
            )
        }

        let eta: Date? = {
            guard let blob = response.encryptedEta else { return nil }
            guard let ms = (try? cryptoManager.decryptDataV2(
                circleId: circleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: "eta"
            )).flatMap({ Int64($0) }) else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }()

        return Destination(
            id: response.id,
            circleId: circleId,
            userId: userId,
            name: name,
            latitude: location.latitude,
            longitude: location.longitude,
            status: Destination.Status.from(response.status),
            notifyArrival: response.notifyArrival,
            estimatedArrivalAt: eta,
            startedAt: Date(timeIntervalSince1970: TimeInterval(response.startedDayBucket) * 86_400),
            arrivedAt: response.arrivedDayBucket
                .map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) },
            creatorId: response.userId
        )
    }
}
