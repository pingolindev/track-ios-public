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

/// Device-local persistence for subscriber-side place alerts — the iOS counterpart
/// of the Android app's Room tables `place_alert_member_state` and
/// `place_alert_events`.
///
/// iOS has no SQL layer, so both are Codable snapshots persisted through
/// `CacheStore`, like `LocalInactivityStore` (the other client-side-evaluation
/// feature that must survive a process restart).
///
/// ## Why everything here is `@MainActor` and synchronous
///
/// Android needs two separate mutexes: the per-member state read-modify-write and
/// the decide-then-claim sequence both have to be atomic, and its `Mutex` is not
/// reentrant so one shared lock would deadlock. The hazard is real — per-circle
/// location refreshes run concurrently, so a member reached through two shared
/// circles gets two overlapping evaluations of the same (place, member). Both read
/// the same pre-crossing state, both detect the SAME physical crossing, and
/// because the ledger id embeds `crossedAt` they claim two different rows and the
/// user gets two notifications for one event.
///
/// The iOS equivalent of that guarantee is the main actor itself: every mutating
/// entry point below is `@MainActor` **and contains no `await`**, so it runs to
/// completion without interleaving. Persisting is the only asynchronous part and
/// it is deliberately fire-and-forget off a value snapshot, exactly as
/// `LocalInactivityStore.persist()` does. An `await` inside one of these methods
/// would allow exactly that double notification — the atomicity here is a
/// property of the code shape, not of a lock you can see.

// MARK: - Member state

/// Per-(place, member) reconciliation state: their in/out standing plus the
/// watermark of the last location already folded into it. Rule 1 in
/// `PlaceAlertRules`. Mirrors `place_alert_member_state`.
struct PlaceAlertMemberStateRecord: Codable, Equatable {
    let placeId: String
    let userId: String
    var isInside: Bool
    var lastLocationAt: Int64

    /// Composite key, matching the Room table's primary key (placeId, userId),
    /// the member in their one form.
    var key: String { Self.key(placeId: placeId, userId: userId) }

    static func key(placeId: String, userId: String) -> String {
        "\(placeId)|\(CanonicalId.key(userId))"
    }
}

@MainActor
final class PlaceAlertMemberStateStore {
    static let shared = PlaceAlertMemberStateStore()

    private static let cacheKey = "placeAlerts.memberState"

    private var records: [String: PlaceAlertMemberStateRecord] = [:]
    private var loaded = false

    private init() {}

    /// Hydrate from disk once. Without this a relaunch has no watermark, and the
    /// first batch after restart re-seeds instead of continuing — which is safe
    /// (seeding emits no crossing) but loses the in/out standing, so the next
    /// genuine transition is missed.
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let cached = await CacheStore.shared.load([PlaceAlertMemberStateRecord].self, forKey: Self.cacheKey) {
            // Keys are the member's one form: two stored records under
            // two spellings of one member fold into one, the later
            // watermark's, rather than trapping.
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            records = Dictionary(cached.map { ($0.key, $0) }, uniquingKeysWith: { Self.later($0, $1, now: now) })
        }
    }

    /// Of two records for one member, the one with the later watermark, each
    /// bounded as it is read: a far-future one ranks lowest, so its standing
    /// never wins the fold.
    nonisolated static func later(_ a: PlaceAlertMemberStateRecord, _ b: PlaceAlertMemberStateRecord,
                                  now: Int64) -> PlaceAlertMemberStateRecord {
        func rank(_ r: PlaceAlertMemberStateRecord) -> Int64 {
            r.lastLocationAt > now + CircleManager.maxFutureSkewMs ? Int64.min : r.lastLocationAt
        }
        return rank(b) > rank(a) ? b : a
    }

    func state(placeId: String, userId: String,
               now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> PlaceAlertRules.MemberPlaceState? {
        guard let record = records[PlaceAlertMemberStateRecord.key(placeId: placeId, userId: userId)] else {
            return nil
        }
        return Self.boundedAtRead(
            PlaceAlertRules.MemberPlaceState(isInside: record.isInside, lastLocationAt: record.lastLocationAt),
            now: now
        )
    }

    /// A watermark beyond `CircleManager.maxFutureSkewMs` reads as absent, and
    /// the standing is KEPT: resetting it would re-fire an arrival for a member
    /// already inside. The member's next genuine fixes are then judged against
    /// the standing they had.
    nonisolated static func boundedAtRead(_ state: PlaceAlertRules.MemberPlaceState,
                                          now: Int64) -> PlaceAlertRules.MemberPlaceState {
        guard state.lastLocationAt > now + CircleManager.maxFutureSkewMs else { return state }
        return PlaceAlertRules.MemberPlaceState(isInside: state.isInside, lastLocationAt: Int64.min)
    }

    func upsert(placeId: String, userId: String, state: PlaceAlertRules.MemberPlaceState) {
        let record = PlaceAlertMemberStateRecord(
            placeId: placeId,
            userId: userId,
            isInside: state.isInside,
            lastLocationAt: state.lastLocationAt
        )
        records[record.key] = record
        persist()
    }

    /// Drop state for places that no longer exist locally, so a deleted place
    /// cannot strand rows that would resurrect stale in/out standing if the id
    /// were ever reused.
    func pruneToPlaces(_ placeIds: Set<String>) {
        let before = records.count
        records = records.filter { placeIds.contains($0.value.placeId) }
        if records.count != before { persist() }
    }

    /// Wipe on logout. Resets `loaded` so the next account re-hydrates from the
    /// (now empty) cache rather than keeping account A's in/out state in memory.
    func clear() {
        records = [:]
        loaded = false
        persist()
    }

    private func persist() {
        let snapshot = Array(records.values)
        Task { await CacheStore.shared.save(snapshot, forKey: Self.cacheKey) }
    }
}

// MARK: - Event ledger

/// One surfaced crossing. The `id` IS the crossing's identity
/// (`place:user:transition:crossedAt`), so inserting it is an atomic
/// "have I already surfaced this?" test that survives restarts — Rule 4.
/// Mirrors `place_alert_events`.
struct PlaceAlertEventRecord: Codable, Equatable {
    /// `PlaceAlertRules.Crossing.ledgerId`.
    let id: String
    let placeId: String
    let userId: String
    /// `PlaceAlertRules.Transition.wire` — "enter" / "exit".
    let transition: String
    let crossedAt: Int64
    let surfacedAt: Int64
    /// `PlaceAlertLedgerSource` raw value.
    let source: String
    let silent: Bool

    // MARK: Presentation
    //
    // Android keeps de-duplication (`place_alert_events`) and history (its
    // `notifications` Room table) in two tables. iOS has no local
    // notifications table — `LocalInactivityStore` shows the idiom is one
    // Codable store per client-evaluated feature — so the rendered copy rides
    // here instead of in a third file.
    //
    // This is load-bearing, not cosmetic: a SILENT decision raises no push but
    // must still be recorded and visible, or a crossing the staleness window
    // suppressed disappears entirely and the feature silently misses that
    // someone came by.

    /// Rendered title ("Arrival" / "Departure" / "Visit"); nil for a bare
    /// server-push claim, which has no local copy to show.
    var title: String?
    /// Rendered body, stamped with the real crossing time.
    var body: String?
    var isRead: Bool = false

    /// Bell row id. The `local-` prefix is what tells the notifications layer to
    /// skip the (404-ing) server round-trip on mark-read / dismiss, matching
    /// `LocalInactivityStore`'s convention.
    var bellId: String { "local-place:\(id)" }
}

/// Which path surfaced a crossing. Cross-path de-duplication is asymmetric: only
/// a SERVER row may suppress a local copy, never one of our own earlier rows.
enum PlaceAlertLedgerSource: String {
    /// This device detected the crossing locally.
    case local
    /// The crossing arrived as a server-routed push.
    case server
}

@MainActor
final class PlaceAlertEventLedger {
    static let shared = PlaceAlertEventLedger()

    private static let cacheKey = "placeAlerts.events"

    /// Entries older than this are dropped on load. Far beyond both the staleness
    /// window (2h) and the cross-path dedupe window (90s), so pruning can never
    /// resurrect a crossing that is still eligible to notify — the worst case is a
    /// duplicate *silent* history row for something a month old.
    private static let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1000

    private var events: [String: PlaceAlertEventRecord] = [:]
    private var loaded = false

    private init() {}

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let cached = await CacheStore.shared.load([PlaceAlertEventRecord].self, forKey: Self.cacheKey) else { return }
        let cutoff = Self.nowMs() - Self.retentionMs
        let kept = cached.filter { $0.crossedAt >= cutoff }
        events = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
        if kept.count != cached.count { persist() }
    }

    /// Claim a crossing. Returns `true` only for the FIRST claim of that exact
    /// crossing, ever — the insert-or-ignore semantics Rule 4 depends on.
    ///
    /// Synchronous and `@MainActor` on purpose; see the file header.
    func claim(
        crossing: PlaceAlertRules.Crossing,
        surfacedAt: Int64,
        source: PlaceAlertLedgerSource,
        silent: Bool,
        title: String? = nil,
        body: String? = nil
    ) -> Bool {
        let id = crossing.ledgerId
        if events[id] != nil { return false }
        events[id] = PlaceAlertEventRecord(
            id: id,
            placeId: crossing.placeId,
            userId: crossing.userId,
            transition: crossing.transition.wire,
            crossedAt: crossing.crossedAt,
            surfacedAt: surfacedAt,
            source: source.rawValue,
            silent: silent,
            title: title,
            body: body
        )
        persist()
        return true
    }

    // MARK: Bell / history

    /// Rows the notifications bell shows: every locally surfaced crossing that
    /// rendered copy, newest crossing first. Silent ones are INCLUDED — that is
    /// how a crossing older than the staleness window still reaches the user
    /// without a push. Bare server-push claims carry no copy and are excluded.
    var bellEvents: [PlaceAlertEventRecord] {
        events.values
            .filter { $0.title != nil && $0.source == PlaceAlertLedgerSource.local.rawValue }
            .sorted { $0.crossedAt > $1.crossedAt }
    }

    var bellUnreadCount: Int { bellEvents.filter { !$0.isRead }.count }

    func markRead(bellId: String) {
        guard let key = events.first(where: { $0.value.bellId == bellId })?.key,
              events[key]?.isRead == false else { return }
        events[key]?.isRead = true
        persist()
    }

    func markAllRead() {
        var changed = false
        for (key, event) in events where event.title != nil && !event.isRead {
            events[key]?.isRead = true
            changed = true
        }
        if changed { persist() }
    }

    func delete(bellId: String) {
        guard let key = events.first(where: { $0.value.bellId == bellId })?.key else { return }
        // Clear the COPY but keep the dedup row: dismissing a notification must
        // not make the crossing eligible to surface again.
        events[key]?.title = nil
        events[key]?.body = nil
        persist()
    }

    /// Whether a crossing from `source` for the same (place, member, transition)
    /// was already surfaced within `PlaceAlertRules.crossPathDedupeWindowMs` of
    /// `crossedAt`.
    ///
    /// The source filter is the primary defence and the window the secondary one.
    /// Matching against our OWN earlier rows here would be wrong: an enter shortly
    /// after a previous enter is a real second arrival, and suppressing it would
    /// cost a user who left and came back their alert. Re-surfacing the exact
    /// SAME crossing is prevented by the id in `claim`, not here.
    func alreadySurfacedNearby(
        placeId: String,
        userId: String,
        transition: String,
        source: PlaceAlertLedgerSource,
        crossedAt: Int64
    ) -> Bool {
        let window = PlaceAlertRules.crossPathDedupeWindowMs
        return events.values.contains { event in
            event.placeId == placeId
                && event.userId == userId
                && event.transition == transition
                && event.source == source.rawValue
                && abs(event.crossedAt - crossedAt) <= window
        }
    }

    /// Wipe on logout, for the same reason as `LocalInactivityStore.clear()` —
    /// a ledger row names a place and a member, and must not leak into the next
    /// account's history.
    func clear() {
        events = [:]
        loaded = false
        persist()
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func persist() {
        let snapshot = Array(events.values)
        Task { await CacheStore.shared.save(snapshot, forKey: Self.cacheKey) }
    }
}
