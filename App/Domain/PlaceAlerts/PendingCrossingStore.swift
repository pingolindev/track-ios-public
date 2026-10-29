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

/// Durable outbox for own-crossing reports that did not reach the server.
///
/// The iOS counterpart of the Android app's Room table `pending_crossings`, built
/// like `PlaceAlertLedger`: a Codable snapshot through `CacheStore`.
///
/// ## What it guards against
///
/// A crossing report can vanish in three independent ways, all silent, and an
/// alert that never fires is indistinguishable from one nobody subscribed to:
///
///  1. **The POST fails.** `PlaceManager.reportCrossing` holds a background-task
///     assertion, so a region-wake report is not suspended mid-request, and a
///     report that fails is enqueued here.
///  2. **The privacy posture can't be established.** A failed privacy GET on a
///     cold wake is `.unknown` (`CircleManager.presencePosture`), distinct from a
///     posture that says no: the send is suppressed, and the crossing is
///     enqueued here rather than dropped.
///  3. **A cold relaunch.** A region crossing that relaunches a killed app waits
///     on the whole place cache decrypting (`unwrapPlaceKey` plus up to 4x
///     `decryptWithPlaceKeyV2` per place, and premium users have unlimited
///     places, so this can take long). Such a crossing is kept on disk as well
///     (`PendingRegionEventStore`, below), so suspension during that wait does
///     not lose it.
///
/// ## Why the inputs, not a ciphertext
///
/// Same reason as Android's table: `reportOwnCrossing` derives the circle set, the
/// BLAKE3 hash and every blob from these plaintext values at SEND time, so
/// replaying the inputs re-derives everything under whatever key is current and a
/// rotation between crossing and replay is a non-event. Storing a sealed payload
/// would mean naming the key that sealed it.
///
/// Two consequences of replaying through `reportOwnCrossing`, both deliberate: the
/// privacy posture is re-evaluated at REPLAY time, so a circle paused since the
/// crossing is skipped; and the circle set is re-resolved, so a place un-shared in
/// the meantime emits nothing. Fail-closed is the right direction for a presence
/// signal.
///
/// ## Concurrency
///
/// `@MainActor`, like the rest of this directory. `enqueue` and `take` are
/// `await`-free so a decide-then-mutate sequence cannot interleave; persisting is
/// fire-and-forget off a value snapshot, exactly as `PlaceAlertLedger` does.
struct PendingCrossingRecord: Codable, Equatable {
    /// The region identifier is the place id, which is why a crossing can be
    /// queued before the place cache has decrypted — see feeder 3 above.
    let placeId: String
    let userId: String
    let deviceId: String
    /// "enter" / "exit", hashed at send time exactly as the live path does. This
    /// record never leaves the device.
    let eventType: String
    /// When the crossing HAPPENED. Replayed verbatim so the recipient stamps the
    /// real time rather than the retry time.
    let occurredAt: Date
    var attempts: Int
    let queuedAt: Date

    /// Identity of the crossing itself, so the same one cannot be queued twice by
    /// two feeders (a POST that failed for a circle whose posture was also
    /// unknown). Second-resolution: two genuine crossings of one place in the same
    /// second are not distinguishable by anything a user would call different.
    var key: String {
        "\(placeId)|\(eventType)|\(Int64(occurredAt.timeIntervalSince1970))"
    }
}

@MainActor
final class PendingCrossingStore {
    static let shared = PendingCrossingStore()

    private static let cacheKey = "placeAlerts.pendingCrossings"
    private static let log = Logger(subsystem: "com.pingolin.track", category: "PlaceAlerts")

    /// Past this a queued crossing is discarded rather than sent. Same bound and
    /// the same reasoning as the subscriber-side detector's staleness window: a
    /// crossing replayed as "2h ago" is still worth knowing, and one replayed a
    /// day later is archaeology delivered as news.
    ///
    /// Bounded on the CROSSING time, not on when it was queued — the two differ by
    /// however long the device was offline, and it is the crossing's own age that
    /// decides whether sending it still tells anyone anything.
    private static let maxAge: TimeInterval = TimeInterval(PlaceAlertRules.stalenessWindowMs) / 1000

    /// Size bound. Small on purpose: a crossing is a transition, not a sample, so
    /// a device with hundreds queued is malfunctioning rather than offline.
    private static let maxRecords = 200

    private var records: [String: PendingCrossingRecord] = [:]
    private var loaded = false

    private init() {}

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let cached = await CacheStore.shared.load([PendingCrossingRecord].self, forKey: Self.cacheKey) {
            records = Dictionary(cached.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Queue a crossing whose report did not reach the server.
    ///
    /// `Logger`, not `PlaceManager.diag`: the diag helpers are `#if DEBUG`, so a
    /// queued crossing would have been invisible in exactly the builds where it
    /// matters. There is precedent for unguarded `Logger.error` on a path that has
    /// to be diagnosable from a shipped build (`SOSManager`).
    func enqueue(
        placeId: String,
        userId: String,
        deviceId: String,
        eventType: String,
        occurredAt: Date,
        reason: String
    ) {
        let record = PendingCrossingRecord(
            placeId: placeId,
            userId: userId,
            deviceId: deviceId,
            eventType: eventType,
            occurredAt: occurredAt,
            attempts: 0,
            queuedAt: Date()
        )

        // Keyed on the crossing's identity, so two feeders reporting the same
        // crossing queue one row. Keep the EXISTING record on collision — it
        // carries the attempt count already spent on it.
        if records[record.key] == nil {
            records[record.key] = record
            Self.log.error(
                "place-alert crossing queued for retry: place=\(placeId, privacy: .public) type=\(eventType, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        trim()
        persist()
    }

    /// Remove and return everything still worth sending, oldest crossing first.
    ///
    /// Take-and-clear rather than read-then-delete: the caller replays each record
    /// through `reportOwnCrossing`, which is async, and holding the rows across
    /// those awaits would let a second drain claim the same crossing. A record
    /// whose replay fails is re-queued by the failure feeder with its attempt
    /// count incremented, so nothing is lost by removing it first.
    ///
    /// Oldest first because order is meaning: an enter replayed after its own exit
    /// tells a subscriber somebody is still somewhere they have left.
    func take() -> [PendingCrossingRecord] {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let expired = records.values.filter { $0.occurredAt < cutoff }
        if !expired.isEmpty {
            // error!, not a debug line: these alerts will never be delivered. A
            // REPORTED loss, which is the whole point of this store, but a loss.
            Self.log.error(
                "discarding \(expired.count, privacy: .public) queued place-alert crossing(s) older than the delivery bound — their alerts will NOT fire"
            )
        }

        let due = records.values
            .filter { $0.occurredAt >= cutoff }
            .sorted { $0.occurredAt < $1.occurredAt }

        records = [:]
        persist()
        return due
    }

    /// Re-queue a record whose replay failed, counting the attempt.
    ///
    /// Eviction is by AGE, never by attempt count — a retry cap is exhausted in
    /// minutes of poor coverage and then discards everything for the rest of the
    /// outage, which is the trap the Android app's `PendingLocationDao` documents.
    func requeue(_ record: PendingCrossingRecord) {
        var next = record
        next.attempts += 1
        records[next.key] = next
        trim()
        persist()
    }

    /// Wipe on logout, so account A's crossings cannot be replayed under B's
    /// session.
    ///
    /// `async`, and it AWAITS the delete — unlike `PlaceAlertLedger.clear()`, whose
    /// fire-and-forget persist is fine because the worst case there is a stale
    /// in/out standing. Here the worst case is account A's crossing REPORTED under
    /// account B's session: if the process dies between clearing memory and the
    /// save landing, the file still holds A's rows and the next launch hydrates
    /// them. Awaiting the removal closes that window, and `purgeAccountData()` is
    /// already `async`.
    func clear() async {
        records = [:]
        loaded = false
        await CacheStore.shared.remove(forKey: Self.cacheKey)
    }

    var count: Int { records.count }

    private func trim() {
        guard records.count > Self.maxRecords else { return }
        let keep = records.values
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(Self.maxRecords)
        records = Dictionary(keep.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() {
        let snapshot = Array(records.values)
        Task { await CacheStore.shared.save(snapshot, forKey: Self.cacheKey) }
    }
}

// MARK: - Unresolved region events

/// A region crossing that arrived before the place cache had decrypted.
///
/// Distinct from `PendingCrossingRecord`, and the difference is which HALF of the
/// work is outstanding. A pending crossing has already been surfaced locally and
/// only its server report is owed. A pending region event has had NEITHER half
/// done: it could not even be resolved to a place, so the local notification — the
/// one the user actually sees — has not happened either. Replaying it therefore
/// goes back through the full handler, not through the report path.
///
/// `PlaceManager.pendingRegionEvents` holds these in memory only, so on its own
/// the crossing that relaunched a killed app is lost if suspension arrives before
/// `hydrateMonitoredFromCache` finishes — and that hydrate is `unwrapPlaceKey`
/// plus up to 4x `decryptWithPlaceKeyV2` per place, with unlimited places for
/// premium users, so the loop can be long. Persisting the identifiers here
/// closes that window.
///
/// Only the identifier is persisted, not the `CLRegion`: the identifier IS the
/// place id (`PlaceManager.addGeofence`), which is the only field the handler reads
/// from it.
struct PendingRegionEventRecord: Codable, Equatable {
    let placeId: String
    let isEnter: Bool
    let detectedAt: Date

    var key: String { "\(placeId)|\(isEnter)|\(Int64(detectedAt.timeIntervalSince1970))" }
}

@MainActor
final class PendingRegionEventStore {
    static let shared = PendingRegionEventStore()

    private static let cacheKey = "placeAlerts.pendingRegionEvents"
    private static let log = Logger(subsystem: "com.pingolin.track", category: "PlaceAlerts")

    /// Same bound and reasoning as `PendingCrossingStore`: past the staleness
    /// window a replayed crossing is archaeology delivered as news.
    private static let maxAge: TimeInterval = TimeInterval(PlaceAlertRules.stalenessWindowMs) / 1000

    /// Core Location caps monitoring at 20 regions, so this cannot legitimately
    /// grow large — a bigger number means events are arriving faster than the
    /// hydrate completes, which is a different problem than a full queue.
    private static let maxRecords = 40

    private var records: [String: PendingRegionEventRecord] = [:]
    private var loaded = false

    private init() {}

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let cached = await CacheStore.shared.load([PendingRegionEventRecord].self, forKey: Self.cacheKey) {
            records = Dictionary(cached.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func enqueue(placeId: String, isEnter: Bool, detectedAt: Date) {
        let record = PendingRegionEventRecord(placeId: placeId, isEnter: isEnter, detectedAt: detectedAt)
        guard records[record.key] == nil else { return }
        records[record.key] = record
        Self.log.error(
            "region crossing buffered before the place cache resolved: place=\(placeId, privacy: .public) enter=\(isEnter, privacy: .public)"
        )
        if records.count > Self.maxRecords {
            let keep = records.values.sorted { $0.detectedAt > $1.detectedAt }.prefix(Self.maxRecords)
            records = Dictionary(keep.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
        persist()
    }

    /// Take everything still worth replaying, oldest first. Cleared before the
    /// caller's awaits so a concurrent replay cannot claim the same event.
    func take() -> [PendingRegionEventRecord] {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        let expired = records.values.filter { $0.detectedAt < cutoff }
        if !expired.isEmpty {
            Self.log.error(
                "discarding \(expired.count, privacy: .public) buffered region crossing(s) older than the delivery bound — they will NOT be surfaced"
            )
        }
        let due = records.values
            .filter { $0.detectedAt >= cutoff }
            .sorted { $0.detectedAt < $1.detectedAt }
        records = [:]
        persist()
        return due
    }

    /// Awaited for the same reason as `PendingCrossingStore.clear()`.
    func clear() async {
        records = [:]
        loaded = false
        await CacheStore.shared.remove(forKey: Self.cacheKey)
    }

    private func persist() {
        let snapshot = Array(records.values)
        Task { await CacheStore.shared.save(snapshot, forKey: Self.cacheKey) }
    }
}
