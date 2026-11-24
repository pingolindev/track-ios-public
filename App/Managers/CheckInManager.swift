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
import CoreLocation
import PingolinTrackSDK

/// Manages check-ins
@MainActor
final class CheckInManager: ObservableObject {
    static let shared = CheckInManager()

    // MARK: - Published State

    @Published private(set) var recentCheckIns: [CheckIn] = []
    @Published private(set) var isLoading = false
    /// This account's own check-ins per circle (its id in its one form), as
    /// the server has them: what the countdown on its own check-in rules
    /// counts from (`CheckInCountdown`). No entry: not read, or the read
    /// failed, and then no countdown is shown rather than a wrong one.
    @Published private(set) var myCheckIns: [String: CheckInCountdown.MyCheckIns] = [:]

    // MARK: - Dependencies

    private let api = APIService.shared
    private let cryptoManager = SDKCrypto.cryptoManager
    private let locationService = LocationService.shared
    private let placeManager = PlaceManager.shared

    private init() {}

    /// Logout teardown for `AuthManager.logout()`: clear the decrypted recent
    /// check-ins (messages + coordinates) so one account's check-ins can't
    /// linger in memory for the next on the same device. Mirrors
    /// `CircleManager.reset()`. The on-disk cache is ciphertext-only and is
    /// wiped separately by `CacheStore.shared.clearAll()` in logout.
    func reset() {
        recentCheckIns = []
        myCheckIns = [:]
    }

    // MARK: - Check-in Operations

    /// Nil when this iPhone is behind in the circle: the check-in then waits
    /// and goes out with the time the person checked in.
    @discardableResult
    func checkIn(
        circleId: String,
        type: CheckIn.CheckInType,
        message: String? = nil,
        includeLocation: Bool = true
    ) async throws -> CheckIn? {
        isLoading = true
        defer { isLoading = false }

        let checkedInAt = Date()
        var latitude: Double?
        var longitude: Double?
        var placeId: String?
        let privacy = Self.privacyNow(circleId: circleId)

        if includeLocation {
            if let location = try? await locationService.requestSingleLocation() {
                // Also what the liveness check-in re-sends, when newer (`adoptSentFix`).
                locationService.adoptSentFix(location)
                // Apply the SAME per-circle privacy gate + approximate
                // coarsening the realtime streamer uses (SDKLocationStreamer
                // .sendInner), so an explicit check-in can't leak an exact fix
                // to a circle the user paused, turned realtime off for, or set
                // to approximate. Self stays exact (mayStreamRealtime is
                // self-exempt). SOS is deliberately exempt and lives elsewhere.
                let circleManager = CircleManager.shared
                let settings = circleManager.privacySettings[circleId]
                if !circleManager.mayStreamRealtime(to: circleId) {
                    // Paused / realtime-off (or settings not loaded → fail
                    // CLOSED): omit the coordinates and the auto-detected place
                    // so the check-in reveals nothing about where the user is.
                    // createCheckInOverWire routes nil coords through its
                    // encrypted "location-omitted" placeholder.
                    latitude = nil
                    longitude = nil
                } else if let settings, settings.sharesApproximately {
                    // Approximate circle: snap to the bubble grid cell before
                    // encryption, and don't attribute an exact place id (which
                    // would defeat the coarsening).
                    let radiusMiles = settings.bubbleRadius > 0 ? settings.bubbleRadius : 1.0
                    let (coarseLat, coarseLng) = LocationCoarsener.coarsenLocation(
                        lat: location.coordinate.latitude,
                        lng: location.coordinate.longitude,
                        radiusMeters: radiusMiles * 1609.344
                    )
                    latitude = coarseLat
                    longitude = coarseLng
                } else {
                    latitude = location.coordinate.latitude
                    longitude = location.coordinate.longitude

                    // Check if at a known place (exact sharing only), and only
                    // one shared into this circle (`checkInPlace`): its id goes
                    // in clear.
                    if let place = placeManager.checkInPlace(at: location.coordinate, in: circleId) {
                        placeId = place.id
                    }
                }
            }
        }

        let checkIn: CheckIn
        do {
            checkIn = try await createCheckInOverWire(
                circleId: circleId,
                type: type,
                message: message,
                latitude: latitude,
                longitude: longitude,
                placeId: placeId,
                checkedInAt: checkedInAt
            )
        } catch CircleManager.CircleError.keyNotCurrent {
            // Refused only because this iPhone is behind in the circle: it
            // waits, with the position as the circle's setting allowed now.
            try PendingChanges.queue(
                .checkIn, circleId: circleId,
                inputs: .checkIn(.init(type: type.rawValue, message: message, latitude: latitude,
                                       longitude: longitude, placeId: placeId, checkedInAt: checkedInAt)),
                seen: .init(privacy: privacy))
            return nil
        }
        remember(checkIn)
        return checkIn
    }

    /// A check-in the server accepted: sent now, or one that waited and has
    /// gone out. A check-in queued while this iPhone is behind never comes
    /// here until it goes out.
    private func remember(_ checkIn: CheckIn) {
        recentCheckIns.insert(checkIn, at: 0)
        if recentCheckIns.count > 50 {
            recentCheckIns = Array(recentCheckIns.prefix(50))
        }
        // The server has it now: the countdown on my own rules restarts.
        myCheckIns[CanonicalId.key(checkIn.circleId)]?.accepted(at: checkIn.timestamp)
    }

    /// The circle's privacy setting for a position now, as a check-in applies
    /// it: paused, real-time off or not known is none; approximate is coarse.
    static func privacyNow(circleId: String) -> PendingChange.QueuedPrivacy {
        let circleManager = CircleManager.shared
        guard circleManager.mayStreamRealtime(to: circleId) else { return .none }
        if let settings = circleManager.privacySettings[circleId], settings.sharesApproximately {
            let radiusMiles = settings.bubbleRadius > 0 ? settings.bubbleRadius : 1.0
            return .approximate(radiusMeters: radiusMiles * 1609.344)
        }
        return .precise
    }

    /// A check-in that waited, sent through the same path with the time the
    /// person checked in and the change's request id (a resend is answered
    /// with the first row). Its position is already the stricter of the
    /// circle's setting when queued and now (`PendingChangeKinds`).
    func sendWaitingCheckIn(_ change: PendingChange) async throws {
        guard case .checkIn(let inputs) = change.inputs else { return }
        let checkIn = try await createCheckInOverWire(
            circleId: change.circleId,
            type: CheckIn.CheckInType(rawValue: inputs.type) ?? .general,
            message: inputs.message,
            latitude: inputs.latitude,
            longitude: inputs.longitude,
            placeId: inputs.placeId,
            checkedInAt: inputs.checkedInAt,
            clientRequestId: change.requestId()
        )
        remember(checkIn)
    }

    @discardableResult
    func safeArrivalCheckIn(circleId: String, placeName: String? = nil) async throws -> CheckIn? {
        var message = "I arrived safely"
        if let place = placeName {
            message += " at \(place)"
        }

        return try await checkIn(
            circleId: circleId,
            type: .safeArrival,
            message: message,
            includeLocation: true
        )
    }

    // MARK: - Load Check-ins

    func loadRecentCheckIns(for circleId: String) async throws {
        isLoading = true
        defer { isLoading = false }

        let cacheKey = "checkins.recent.\(circleId)"
        let responses: [CheckInResponse]
        do {
            responses = try await api.getCheckIns(circleId: circleId)
            await CacheStore.shared.save(responses, forKey: cacheKey)
        } catch {
            if let cached: [CheckInResponse] = await CacheStore.shared.load([CheckInResponse].self, forKey: cacheKey) {
                print("[Track] loadRecentCheckIns: serving \(cached.count) row(s) from cache after \(error)")
                ErrorBanner.shared.post(error)
                responses = cached
            } else {
                throw error
            }
        }
        // Truncate to the newest 50 BEFORE decrypting (older rows are never
        // shown) and hop the per-row decrypt off the Main actor:
        // decryptCheckInResponse runs 3× decryptDataV2 + 1× decryptLocation per
        // row. Mirrors PlaceManager / DestinationsManager; assigned back on the
        // Main actor after the await.
        let newest = Array(responses.prefix(50))
        // Only current check-ins are "recent": one that opened only under a
        // key version this device doesn't seal under could be a removed
        // member's forged "I'm safe", read as live. The history screen still
        // shows it, as history.
        let crypto = cryptoManager
        recentCheckIns = await Task.detached { [newest, circleId, crypto] in
            newest.compactMap { response -> CheckIn? in
                guard let opened = Self.openCheckIn(response, circleId: circleId, crypto: crypto) else { return nil }
                return opened.current ? opened.checkIn : nil
            }
        }.value
    }

    /// Decrypt the server-blind fields on a CheckInResponse using the circle
    /// key (already loaded via CircleManager.loadCircles -> SDK.storeCircleKey).
    /// Falls back to safe defaults when individual fields can't be decrypted,
    /// but not the time: one whose time doesn't open is nil (`openCheckIn`).
    ///
    /// `nonisolated` so callers can hop it off the Main actor via
    /// `Task.detached` (see loadCheckInHistory). It only touches the Sendable
    /// `cryptoManager` and value-type inputs, so it's race-safe off the actor,
    /// same shape as DestinationsManager.decryptResponse.
    private nonisolated func decryptCheckInResponse(_ response: CheckInResponse, circleId: String) -> CheckIn? {
        Self.openCheckIn(response, circleId: circleId, crypto: cryptoManager)?.checkIn
    }

    /// A check-in opened, and whether it is CURRENT: every sealed field that
    /// opened did so under the version this device seals the circle under
    /// (`isCurrentKeyVersion`, the one test). Pure apart from the SDK reads.
    /// Nil when its sealed time doesn't open: `encrypted_timestamp` is
    /// required, and the server's day bucket must never date a check-in (it
    /// could show a genuine one in "Recent" re-dated to any midnight). The
    /// Android app does the same.
    nonisolated static func openCheckIn(
        _ response: CheckInResponse, circleId: String, crypto: CryptoManager
    ) -> (checkIn: CheckIn, current: Bool)? {
        let owningCircleId = response.circleId ?? circleId
        var versions: [Int32] = []
        func opened(_ blob: EncryptedBlobResponse, _ fieldTag: String) -> String? {
            guard let text = try? crypto.decryptDataV2Opened(
                circleId: owningCircleId,
                encryptedData: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext),
                fieldTag: fieldTag
            ) else { return nil }
            versions.append(text.keyVersion)
            return text.text
        }
        let userId = opened(response.encryptedUserId, "user_id") ?? ""
        let message: String? = response.encryptedMessage.flatMap { opened($0, "message") }
        // `flatMap`, like `encryptedMessage` above: the field is absent on a
        // check-in that deliberately withheld its location, and `CheckIn`
        // already carries lat/lon as optionals for exactly that case.
        let location = response.encryptedLocation.flatMap { blob -> Location? in
            guard let point = try? crypto.decryptLocationOpened(
                circleId: owningCircleId,
                encryptedLocation: EncryptedData(nonce: blob.nonce, ciphertext: blob.ciphertext)
            ) else { return nil }
            versions.append(point.keyVersion)
            return point.location
        }
        guard let timestampMs = opened(response.encryptedTimestamp, "timestamp").flatMap({ Int64($0) }) else {
            return nil
        }
        let checkIn = CheckIn(
            id: response.id,
            circleId: owningCircleId,
            userId: userId,
            type: CheckIn.CheckInType(rawValue: response.checkInType) ?? .general,
            message: message,
            latitude: location?.latitude,
            longitude: location?.longitude,
            placeId: response.placeId,
            timestamp: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000),
            isSynced: true
        )
        let current = versions.allSatisfy { crypto.isCurrentKeyVersion(circleId: owningCircleId, keyVersion: $0) }
        return (checkIn, current)
    }

    func loadCheckInHistory(for circleId: String, from: Date, to: Date) async throws -> [CheckIn] {
        // Backend route GET /api/v1/circles/:circle_id/check-ins is the history
        // endpoint for a circle: authorized by active membership, keyset-paginated
        // on (day_bucket, id), rows sealed under the CIRCLE key. Walks cursor pages
        // back in time until the day bucket dips below `fromDayBucket`, decrypts
        // each row, and trims to the [from, to] window.
        //
        // Not the PERSONAL feed (`GET /api/v1/check-ins`) with a per-circle
        // `user_pseudonym`: the server checks that parameter against the
        // account's SELF-key pseudonym, a different pseudonym domain, so a
        // per-circle pseudonym is refused with 403 "Invalid user pseudonym".
        // The Android app calls the circle route here too (getCircleCheckIns).
        let fromDayBucket = Int(from.timeIntervalSince1970 / 86_400)

        var collected: [CheckIn] = []
        var cursorDayBucket: Int? = nil
        var cursorId: String? = nil
        // Cap the walk so an unbounded loop can't hang; matches Android.
        for _ in 0..<10 {
            let page = try await api.listCircleCheckIns(
                circleId: circleId,
                limit: 100,
                cursorDayBucket: cursorDayBucket,
                cursorId: cursorId
            )
            if page.isEmpty { break }
            // Decrypt the page off the Main actor: up to 100 rows/page × 10
            // pages, each doing 3× decryptDataV2 + 1× decryptLocation. Mirrors
            // PlaceManager / DestinationsManager; the [from, to] filter runs on
            // the Main actor after the await.
            let decrypted = await Task.detached { [self, page, circleId] in
                page.compactMap { self.decryptCheckInResponse($0, circleId: circleId) }
            }.value
            for item in decrypted {
                if item.timestamp >= from && item.timestamp <= to {
                    collected.append(item)
                }
            }
            if let oldest = page.last, oldest.dayBucket < fromDayBucket { break }
            cursorDayBucket = page.last?.dayBucket
            cursorId = page.last?.id
        }
        return collected
    }

    /// Each member's newest check-in in a circle, by their id in its one form:
    /// what the check-in alert rules judge (`MonitoringManager.evaluateCheckInAlerts`).
    /// The circle's route, read by `readNewestCheckIns`; `from`: a scheduled
    /// rule's window start, when the read must reach back that far.
    func newestCheckIns(circleId: String, from: Date? = nil, now: Date = Date()) async throws -> [String: Date] {
        let api = self.api
        return try await Self.readNewestCheckIns(circleId: circleId, now: now, from: from, crypto: cryptoManager) { cursorDayBucket, cursorId in
            try await api.listCircleCheckIns(
                circleId: circleId,
                limit: CheckInAlerts.pageSize,
                cursorDayBucket: cursorDayBucket,
                cursorId: cursorId
            )
        }
    }

    /// The read behind `newestCheckIns`, its pages fetched by `fetch` (from a
    /// cursor: the last row's day bucket and id).
    ///
    /// Newest first, page by page until a page comes back short, reaches a day
    /// older than any rule needs, or 5 pages (`CheckInAlerts.readsOn`). THROWS,
    /// never a partial answer, when a page fails or when a check-in inside the
    /// window doesn't open here (`openPage`): a failed read is not "no
    /// check-in", and nobody in the circle is judged on it. "Nobody has checked
    /// in" is an empty answer that succeeded. A row that never opens (a key this
    /// phone will never hold, a damaged row) pauses the circle's check-in rules
    /// until it falls out of the window, about a day: late rather than false.
    /// `from` reaches the window further back (a scheduled rule's window
    /// start, up to a week for a weekly pattern). Nonisolated, so the opening
    /// runs off the Main actor.
    nonisolated static func readNewestCheckIns(
        circleId: String,
        now: Date,
        from: Date? = nil,
        crypto: CryptoManager,
        fetch: (_ cursorDayBucket: Int?, _ cursorId: String?) async throws -> [CheckInResponse]
    ) async throws -> [String: Date] {
        let floor = CheckInAlerts.readFloorDayBucket(now: now, from: from)
        var newest: [String: Date] = [:]
        var cursorDayBucket: Int?
        var cursorId: String?
        for _ in 0..<CheckInAlerts.maxPages {
            let page = try await fetch(cursorDayBucket, cursorId)
            CheckInAlerts.merge(try openPage(page, circleId: circleId, crypto: crypto, floor: floor),
                                into: &newest, now: now)
            guard CheckInAlerts.readsOn(pageDayBuckets: page.map(\.dayBucket), floor: floor),
                  let last = page.last else { break }
            cursorDayBucket = last.dayBucket
            cursorId = last.id
        }
        return newest
    }

    /// One page of the read, opened. A row inside the window (its day bucket at
    /// or past `floor`) whose sender or sealed time doesn't open fails the read
    /// (`CheckInAlerts.UnopenedCheckIn`): it may be exactly the check-in that
    /// matters, sealed under a key this phone doesn't hold yet, and the
    /// location passes hold their alerts to the same rule (`isComplete`). One
    /// below the window is skipped: no rule's verdict turns on it. A message or
    /// a position that doesn't open changes nothing here.
    nonisolated static func openPage(
        _ page: [CheckInResponse], circleId: String, crypto: CryptoManager, floor: Int
    ) throws -> [CheckIn] {
        var opened: [CheckIn] = []
        for response in page {
            if let checkIn = openCheckIn(response, circleId: circleId, crypto: crypto)?.checkIn,
               !checkIn.userId.isEmpty {
                opened.append(checkIn)
            } else if response.dayBucket >= floor {
                throw CheckInAlerts.UnopenedCheckIn()
            }
        }
        return opened
    }

    // MARK: - My own check-ins, for the countdown

    /// Read this account's own check-ins again for every circle where one of
    /// its rules counts down (`CheckInCountdown.reads`), or only `circleId`'s.
    /// For a screen that shows a countdown, as it opens.
    func refreshMyCheckIns(for alerts: [InactivityAlertResponse], circleId: String? = nil) async {
        for (key, read) in CheckInCountdown.reads(for: alerts)
        where circleId.map({ CanonicalId.key($0) == key }) ?? true {
            await refreshMyCheckIns(circleId: read.circleId, sinceDay: read.sinceDay)
        }
    }

    /// Read this account's newest check-in in `circleId` from the server, back
    /// to `sinceDay`. A read that fails leaves no entry: no countdown rather
    /// than a wrong one.
    func refreshMyCheckIns(circleId: String, sinceDay: Int) async {
        let key = CanonicalId.key(circleId)
        guard let me = AuthManager.shared.userId else {
            myCheckIns.removeValue(forKey: key)
            return
        }
        let api = self.api
        do {
            let read = try await Self.readMyNewestCheckIn(
                circleId: circleId, userId: me, sinceDay: sinceDay, now: Date(), crypto: cryptoManager
            ) { cursorDayBucket, cursorId in
                try await api.listCircleCheckIns(
                    circleId: circleId,
                    limit: CheckInAlerts.pageSize,
                    cursorDayBucket: cursorDayBucket,
                    cursorId: cursorId
                )
            }
            // One accepted while the read was out may be newer than it saw.
            let held = myCheckIns[key]?.newest
            myCheckIns[key] = CheckInCountdown.MyCheckIns(newest: [read, held].compactMap { $0 }.max(),
                                                         sinceDay: sinceDay)
        } catch {
            myCheckIns.removeValue(forKey: key)
        }
    }

    /// This account's newest check-in in a circle that the server has, from
    /// `sinceDay` on (a rule's arming day: an older check-in moves no
    /// deadline), its pages fetched by `fetch`. Not the alert rules' read
    /// (`readNewestCheckIns`): that one stops a day back, and an overdue
    /// countdown may count from a check-in older than that.
    ///
    /// Newest day first, page by page, until it knows: a page comes back
    /// short, or it has read past `sinceDay`, or past the day of the newest
    /// of its own it found (rows within a day aren't in time order, so that
    /// day is read to its end). nil: none from `sinceDay` on. THROWS when it
    /// can't tell (`CheckInCountdown.CannotTell`): a page failed, a row that
    /// may be newer than what it found didn't open, or it ran out of pages
    /// first. A check-in dated further ahead than any clock may be is left
    /// out, as the alert rules leave it out (`CheckInAlerts.merge`).
    nonisolated static func readMyNewestCheckIn(
        circleId: String,
        userId: String,
        sinceDay: Int,
        now: Date,
        crypto: CryptoManager,
        fetch: (_ cursorDayBucket: Int?, _ cursorId: String?) async throws -> [CheckInResponse]
    ) async throws -> Date? {
        let me = CanonicalId.key(userId)
        let latestBelievable = now.addingTimeInterval(TimeInterval(CircleManager.maxFutureSkewMs) / 1000)
        var newest: Date?
        var newestDay: Int?
        var cursorDayBucket: Int?
        var cursorId: String?
        for _ in 0..<CheckInCountdown.maxPages {
            let page = try await fetch(cursorDayBucket, cursorId)
            for response in page {
                guard let checkIn = openCheckIn(response, circleId: circleId, crypto: crypto)?.checkIn,
                      !checkIn.userId.isEmpty else {
                    // It may be mine, and newer than what was found.
                    if response.dayBucket >= (newestDay ?? sinceDay) { throw CheckInCountdown.CannotTell() }
                    continue
                }
                guard CanonicalId.key(checkIn.userId) == me, checkIn.timestamp <= latestBelievable else { continue }
                newest = max(newest ?? checkIn.timestamp, checkIn.timestamp)
                newestDay = max(newestDay ?? response.dayBucket, response.dayBucket)
            }
            guard page.count >= CheckInAlerts.pageSize, let last = page.last else { return newest }
            if last.dayBucket < (newestDay ?? sinceDay) { return newest }
            cursorDayBucket = last.dayBucket
            cursorId = last.id
        }
        throw CheckInCountdown.CannotTell()
    }

    // MARK: - Past check-ins, for the Alerts history

    /// The past check-ins the Alerts history lists (`CheckInHistory`): the
    /// last 30 days of the people this account's check-in rules are about,
    /// read from the server now. `complete` is false when some couldn't be
    /// read (a circle's page, or the circle-mates' requests); what could is
    /// still returned.
    func historyCheckIns(rules: [InactivityAlertResponse]) async -> (entries: [CheckInHistory.Entry], complete: Bool) {
        let me = AuthManager.shared.userId
        let circleManager = CircleManager.shared
        let inactivity = InactivityAlertsManager.shared
        var complete = true
        let requests: [CircleSelfAlertResponse]
        do {
            requests = try await api.listCircleSelfAlerts()
        } catch {
            requests = []
            complete = false
        }
        let watched = CheckInHistory.watched(rules: rules, requests: requests, selfId: me) { rule in
            guard let spec = inactivity.watchSpec(for: rule) else { return nil }
            if spec == "all" || spec.isEmpty {
                return (circleManager.members[rule.circleId] ?? []).map { $0.userId }
            }
            return spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var read: [CheckIn] = []
        let api = self.api
        for circle in watched.values {
            let circleId = circle.circleId
            do {
                read += try await Self.readHistoryCheckIns(circleId: circleId, now: Date(), crypto: cryptoManager) {
                    cursorDayBucket, cursorId in
                    try await api.listCircleCheckIns(
                        circleId: circleId,
                        limit: CheckInAlerts.pageSize,
                        cursorDayBucket: cursorDayBucket,
                        cursorId: cursorId
                    )
                }
            } catch {
                complete = false
            }
        }
        let entries = CheckInHistory.entries(read, watched: watched, selfId: me) { circleId, userId in
            circleManager.members[circleId]?.first { CanonicalId.sameKey($0.userId, userId) }?.displayName
        }
        return (entries, complete)
    }

    /// One circle's check-ins of the last 30 days that open here, for the
    /// Alerts history, its pages fetched by `fetch`. Newest first, until a
    /// page comes back short, reaches a day older than that, or 5 pages. A row
    /// that doesn't open is skipped: the history shows what this phone can
    /// read and judges nothing. So is one dated further ahead than any clock
    /// may be. THROWS when a page fails.
    nonisolated static func readHistoryCheckIns(
        circleId: String,
        now: Date,
        crypto: CryptoManager,
        fetch: (_ cursorDayBucket: Int?, _ cursorId: String?) async throws -> [CheckInResponse]
    ) async throws -> [CheckIn] {
        let oldest = now.addingTimeInterval(-CheckInHistory.depth)
        let latestBelievable = now.addingTimeInterval(TimeInterval(CircleManager.maxFutureSkewMs) / 1000)
        let floor = CheckInCountdown.dayBucket(oldest)
        var found: [CheckIn] = []
        var cursorDayBucket: Int?
        var cursorId: String?
        for _ in 0..<CheckInHistory.maxPages {
            let page = try await fetch(cursorDayBucket, cursorId)
            for response in page {
                guard let checkIn = openCheckIn(response, circleId: circleId, crypto: crypto)?.checkIn,
                      !checkIn.userId.isEmpty, checkIn.timestamp >= oldest,
                      checkIn.timestamp <= latestBelievable else { continue }
                found.append(checkIn)
            }
            guard CheckInAlerts.readsOn(pageDayBuckets: page.map(\.dayBucket), floor: floor),
                  let last = page.last else { break }
            cursorDayBucket = last.dayBucket
            cursorId = last.id
        }
        return found
    }

    /// Build the E2EE CreateCheckInRequest, POST it, and assemble a CheckIn
    /// model from the response. Mirrors the Android CheckInRepository flow:
    /// encrypt user_id / device_id / timestamp / message / location with the
    /// circle key, derive a per-circle user pseudonym, send the day-bucket
    /// alongside.
    ///
    /// `checkedInAt`: when the person checked in, which is what the check-in
    /// says even when it waited. `clientRequestId`: only a waiting change
    /// sends one.
    private func createCheckInOverWire(
        circleId: String,
        type: CheckIn.CheckInType,
        message: String?,
        latitude: Double?,
        longitude: Double?,
        placeId: String?,
        checkedInAt: Date,
        clientRequestId: String? = nil
    ) async throws -> CheckIn {
        guard let userId = AuthManager.shared.userId else {
            throw APIError(code: "unauthorized", message: "No user id available")
        }
        // Nothing new is sealed under a key the circle has moved past.
        try CircleManager.shared.requireCurrentKey(for: circleId)
        // The server takes a check-in only from a device registered to this
        // account ("Device not found or not owned by user"). Registered here
        // when it isn't yet (a no-op once it is); a waiting check-in that still
        // can't be sent from a registered device waits instead of being refused.
        let registered = await DeviceRegistrar.ensure()
        if !registered, clientRequestId != nil {
            throw PendingChanges.NotReady()
        }
        let deviceId = AuthManager.shared.deviceId ?? "unknown"
        let now = checkedInAt
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let dayBucket = Int(now.timeIntervalSince1970 / 86_400)

        let encUserData = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: userId, fieldTag: "user_id")
        let encDeviceData = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: deviceId, fieldTag: "device_id")
        let encTimestamp = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: String(nowMs), fieldTag: "timestamp")
        let pseudonym = try cryptoManager.deriveUserPseudonym(circleId: circleId, userId: userId)

        var encLocation: EncryptedBlobRequest? = nil
        if let lat = latitude, let lng = longitude {
            let sdkLocation = PingolinTrackSDK.Location(
                latitude: lat,
                longitude: lng,
                altitude: nil,
                speed: nil,
                heading: nil,
                accuracy: nil,
                timestamp: nowMs,
                batteryLevel: nil,
                isCharging: nil as Bool?
            )
            let encrypted = try cryptoManager.encryptLocation(circleId: circleId, location: sdkLocation)
            encLocation = EncryptedBlobRequest(nonce: encrypted.nonce, ciphertext: encrypted.ciphertext)
        }

        var encMessage: EncryptedBlobRequest? = nil
        if let msg = message {
            let encrypted = try cryptoManager.encryptDataV2(circleId: circleId, plaintext: msg, fieldTag: "message")
            encMessage = EncryptedBlobRequest(nonce: encrypted.nonce, ciphertext: encrypted.ciphertext)
        }

        // Backend rejects the request without an encryptedLocation, so fall
        // back to encrypting the canonical "unknown" placeholder when the
        // caller didn't supply coordinates. A circle whose key isn't loaded
        // makes this throw (KeyNotFound); propagate it like the sibling
        // encrypts above rather than force-trying into a crash.
        let encryptedLocation: EncryptedBlobRequest = try encLocation ?? {
            let placeholder = try cryptoManager.encryptData(
                circleId: circleId,
                plaintext: "location-omitted"
            )
            return EncryptedBlobRequest(nonce: placeholder.nonce, ciphertext: placeholder.ciphertext)
        }()

        let request = CreateCheckInRequest(
            deviceId: deviceId,
            circleId: circleId,
            encryptedLocation: encryptedLocation,
            placeId: placeId,
            encryptedMessage: encMessage,
            checkInType: type.rawValue,
            encryptedUserId: EncryptedBlobRequest(nonce: encUserData.nonce, ciphertext: encUserData.ciphertext),
            encryptedDeviceId: EncryptedBlobRequest(nonce: encDeviceData.nonce, ciphertext: encDeviceData.ciphertext),
            dayBucket: dayBucket,
            encryptedTimestamp: EncryptedBlobRequest(nonce: encTimestamp.nonce, ciphertext: encTimestamp.ciphertext),
            userPseudonym: pseudonym,
            clientRequestId: clientRequestId
        )

        let response = try await api.createCheckIn(circleId: circleId, request: request)

        // We have the cleartext locally, assemble the model directly so the
        // UI doesn't need a decrypt round-trip just to render what we sent.
        return CheckIn(
            id: response.id,
            circleId: response.circleId ?? circleId,
            userId: userId,
            type: type,
            message: message,
            latitude: latitude,
            longitude: longitude,
            placeId: placeId,
            timestamp: now,
            isSynced: true
        )
    }
}
