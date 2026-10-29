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

/// A device-local record of client-side low-battery firings.
///
/// The comparison that produces one happens here and is never reported: the
/// battery level is sealed inside the watched member's location payload and the
/// server holds no key for it, so there is no server row for the bell or the
/// history to fetch. This store is the record.
///
/// The unresolved event doubles as the fire-once marker. Without it a phone
/// sitting at 8% would re-notify on every wake-up and every periodic pass, and
/// an in-memory flag would re-fire after every relaunch. Mirrors
/// [LocalInactivityStore] and the Android app's local_battery_events table.
struct LocalBatteryEvent: Codable, Identifiable, Equatable {
    /// "local-batt-<ruleId>-<userId>-<triggeredMillis>" — the `local-` prefix
    /// marks it device-only so the bell skips the (404-ing) server round-trip
    /// on mark-read / dismiss.
    let id: String
    let ruleId: String
    let circleId: String
    let userId: String
    let memberName: String
    /// The level that tripped the rule, as a percentage.
    let batteryLevel: Int
    var triggeredAt: Date
    /// nil while the watched phone is still below the threshold (the "already
    /// fired" marker); set when it charges back above it.
    var resolvedAt: Date?
    var isRead: Bool

    var isResolved: Bool { resolvedAt != nil }
}

@MainActor
final class LocalBatteryStore: ObservableObject {
    static let shared = LocalBatteryStore()

    @Published private(set) var events: [LocalBatteryEvent] = []

    private static let cacheKey = "battery.localEvents"
    private static let maxEvents = 50
    private var loaded = false

    private init() {}

    /// Hydrate from disk once, so a fired-but-unresolved drain cannot re-fire
    /// after a relaunch.
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let cached = await CacheStore.shared.load([LocalBatteryEvent].self, forKey: Self.cacheKey) {
            events = cached
        }
    }

    /// True when there is an open (unresolved) firing for this rule+member —
    /// the fire-once guard.
    func hasUnresolved(ruleId: String, userId: String) -> Bool {
        events.contains { $0.ruleId == ruleId && $0.userId == userId && $0.resolvedAt == nil }
    }

    @discardableResult
    func record(
        ruleId: String,
        circleId: String,
        userId: String,
        memberName: String,
        batteryLevel: Int,
        triggeredAt: Date
    ) -> LocalBatteryEvent {
        let event = LocalBatteryEvent(
            id: "local-batt-\(ruleId)-\(userId)-\(Int(triggeredAt.timeIntervalSince1970 * 1000))",
            ruleId: ruleId,
            circleId: circleId,
            userId: userId,
            memberName: memberName,
            batteryLevel: batteryLevel,
            triggeredAt: triggeredAt,
            resolvedAt: nil,
            isRead: false
        )
        events.insert(event, at: 0)
        if events.count > Self.maxEvents { events = Array(events.prefix(Self.maxEvents)) }
        persist()
        return event
    }

    /// Resolve the open firing for this rule+member (they charged back above
    /// the threshold). Returns true if one was open, so the caller can cancel
    /// the now-stale tray notification and re-arm.
    @discardableResult
    func resolve(ruleId: String, userId: String, at date: Date = Date()) -> Bool {
        guard let idx = events.firstIndex(where: {
            $0.ruleId == ruleId && $0.userId == userId && $0.resolvedAt == nil
        }) else { return false }
        events[idx].resolvedAt = date
        persist()
        return true
    }

    func markRead(id: String) {
        guard let idx = events.firstIndex(where: { $0.id == id }), !events[idx].isRead else { return }
        events[idx].isRead = true
        persist()
    }

    func delete(id: String) {
        events.removeAll { $0.id == id }
        persist()
    }

    /// Events shown in the notifications bell — only OPEN firings, matching
    /// [LocalInactivityStore]: a phone that has been charged is no longer news.
    var bellEvents: [LocalBatteryEvent] { events.filter { !$0.isResolved } }
    var bellUnreadCount: Int { events.filter { !$0.isResolved && !$0.isRead }.count }

    func markAllRead() {
        var changed = false
        for i in events.indices where !events[i].isRead {
            events[i].isRead = true
            changed = true
        }
        if changed { persist() }
    }

    /// Wipe everything on logout. `loaded` resets too, so the next account
    /// re-hydrates from the (now empty) cache instead of an early return
    /// leaving account A's decrypted member names in memory for account B.
    func clear() {
        events = []
        loaded = false
        persist()
    }

    private func persist() {
        let snapshot = events
        Task { await CacheStore.shared.save(snapshot, forKey: Self.cacheKey) }
    }
}
