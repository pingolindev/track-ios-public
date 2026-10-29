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

/// A device-local record of client-side inactivity firings. These rules are
/// client_only (their watcher set is E2EE, so the server can't evaluate or
/// record them), so a firing would otherwise leave no trace beyond a
/// transient tray notification. This store persists each firing so it
/// survives a process restart — the unresolved event doubles as the
/// "already fired" marker (fire-once-per-lapse) and feeds the in-app history
/// + bell. Mirrors the Android app's local_inactivity_events table.
struct LocalInactivityEvent: Codable, Identifiable, Equatable {
    /// "local-<ruleId>-<userId>-<triggeredMillis>" — the `local-` prefix
    /// marks it device-only so the bell skips the (404-ing) server round-trip
    /// on mark-read / dismiss.
    let id: String
    let ruleId: String
    let circleId: String
    let userId: String
    let memberName: String
    var triggeredAt: Date
    /// nil while the member is still silent (the "already fired" marker);
    /// set when they share location again. History shows Triggered -> Resolved.
    var resolvedAt: Date?
    var isRead: Bool

    var isResolved: Bool { resolvedAt != nil }
}

@MainActor
final class LocalInactivityStore: ObservableObject {
    static let shared = LocalInactivityStore()

    @Published private(set) var events: [LocalInactivityEvent] = []

    /// The same rule the server applies (the later of last-seen and the end of
    /// the latest not-sharing span): when this phone last saw each watched
    /// member not sharing in a circle, paused or with real-time off, or a timed
    /// pause's planned end. Their silence counts from the later of their
    /// last-seen and this, so a pause that runs out on a still phone isn't
    /// "hasn't shared since …" about the pause itself. "circle|member" (their
    /// one forms) -> instant.
    private(set) var notSharingSeen: [String: Date] = [:]

    private static let cacheKey = "inactivity.localEvents"
    private static let notSharingKey = "inactivity.notSharingSeen"
    /// Longer than any timeout (24 h): an older stretch decides nothing.
    nonisolated static let notSharingKeep: TimeInterval = 8 * 24 * 60 * 60
    private static let maxEvents = 50
    private var loaded = false

    private init() {}

    /// Hydrate from disk once (survives process restart so a fired-but-
    /// unresolved lapse can't re-fire after a relaunch).
    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        if let cached = await CacheStore.shared.load([LocalInactivityEvent].self, forKey: Self.cacheKey) {
            events = cached
        }
        if let seen = await CacheStore.shared.load([String: Date].self, forKey: Self.notSharingKey) {
            let oldest = Date().addingTimeInterval(-Self.notSharingKeep)
            notSharingSeen = seen.filter { $0.value > oldest }
        }
    }

    /// A watched member the roster shows not sharing in `circleId` now.
    func noteNotSharing(circleId: String, userId: String, status: MemberSharingStatus, now: Date = Date()) {
        let key = Self.memberKey(circleId, userId)
        guard let until = Self.noted(notSharingSeen[key], status: status, now: now) else { return }
        notSharingSeen[key] = until
        let snapshot = notSharingSeen
        Task { await CacheStore.shared.save(snapshot, forKey: Self.notSharingKey) }
    }

    /// A watched member the roster shows sharing again in `circleId` now. A
    /// planned end still ahead was not the end (they resumed early), so the
    /// stretch ended by now at the latest, and their silence counts from then.
    func noteSharing(circleId: String, userId: String, now: Date = Date()) {
        let key = Self.memberKey(circleId, userId)
        guard let until = Self.resumed(notSharingSeen[key], now: now) else { return }
        notSharingSeen[key] = until
        let snapshot = notSharingSeen
        Task { await CacheStore.shared.save(snapshot, forKey: Self.notSharingKey) }
    }

    /// The record's value once they share again: now, when it was a planned
    /// end still ahead; nil when it stands.
    nonisolated static func resumed(_ noted: Date?, now: Date) -> Date? {
        guard let noted, noted > now else { return nil }
        return now
    }

    /// When `userId` was last seen not sharing in `circleId`, if ever.
    func notSharingSeen(circleId: String, userId: String) -> Date? {
        notSharingSeen[Self.memberKey(circleId, userId)]
    }

    /// The record's next value: now, or a timed pause's planned end when that
    /// is later; nil when it would not move later.
    nonisolated static func noted(_ previous: Date?, status: MemberSharingStatus, now: Date) -> Date? {
        var until = now
        if case .paused(let end?) = status, end > now { until = end }
        guard previous.map({ $0 < until }) ?? true else { return nil }
        return until
    }

    /// Whether a fix taken at `lastFix` resolves a lapse that fired at
    /// `triggeredAt`: only one taken after it.
    nonisolated static func resolvesLapse(triggeredAt: Date, lastFix: Date) -> Bool {
        lastFix > triggeredAt
    }

    /// When a member's silence starts: the later of their last-seen and the end
    /// of their latest stretch of not sharing, and never after now.
    nonisolated static func activeSince(lastSeen: Date, notSharingSeen: Date?, now: Date) -> Date {
        min(max(lastSeen, notSharingSeen ?? lastSeen), now)
    }

    nonisolated static func memberKey(_ circleId: String, _ userId: String) -> String {
        "\(CanonicalId.key(circleId))|\(CanonicalId.key(userId))"
    }

    /// True when there's an open (unresolved) firing for this rule+member —
    /// the fire-once guard.
    func hasUnresolved(ruleId: String, userId: String) -> Bool {
        events.contains { $0.ruleId == ruleId && $0.userId == userId && $0.resolvedAt == nil }
    }

    @discardableResult
    func record(ruleId: String, circleId: String, userId: String, memberName: String, triggeredAt: Date) -> LocalInactivityEvent {
        let event = LocalInactivityEvent(
            id: "local-\(ruleId)-\(userId)-\(Int(triggeredAt.timeIntervalSince1970 * 1000))",
            ruleId: ruleId,
            circleId: circleId,
            userId: userId,
            memberName: memberName,
            triggeredAt: triggeredAt,
            resolvedAt: nil,
            isRead: false
        )
        events.insert(event, at: 0)
        if events.count > Self.maxEvents { events = Array(events.prefix(Self.maxEvents)) }
        persist()
        return event
    }

    /// Resolve the open firing for this rule+member (the member shared
    /// location again). Returns true if one was open, so the caller can
    /// cancel the now-stale tray notification and re-arm.
    @discardableResult
    func resolve(ruleId: String, userId: String, fixAt: Date? = nil, at date: Date = Date()) -> Bool {
        guard let idx = events.firstIndex(where: {
            $0.ruleId == ruleId && $0.userId == userId && $0.resolvedAt == nil
        }) else { return false }
        // Only a NEW fix since it fired makes them active again: a pause that
        // ended with no fix is no "sharing location again".
        if let fixAt, !Self.resolvesLapse(triggeredAt: events[idx].triggeredAt, lastFix: fixAt) { return false }
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

    var unreadCount: Int { events.filter { !$0.isRead }.count }

    /// Events shown in the notifications bell — only OPEN firings (a resolve
    /// clears them from the bell, like cancelling the tray notification);
    /// the full Triggered->Resolved log lives in the Alerts history.
    var bellEvents: [LocalInactivityEvent] { events.filter { !$0.isResolved } }
    var bellUnreadCount: Int { events.filter { !$0.isResolved && !$0.isRead }.count }

    func markAllRead() {
        var changed = false
        for i in events.indices where !events[i].isRead {
            events[i].isRead = true
            changed = true
        }
        if changed { persist() }
    }

    /// Wipe all persisted + in-memory firings on logout. Resets `loaded` so
    /// the next account re-hydrates from the (now empty) cache instead of an
    /// early-return leaving account A's decrypted events (memberName is
    /// plaintext) in memory to re-surface in account B's bell via
    /// NotificationsManager.mergeLocal.
    func clear() {
        events = []
        notSharingSeen = [:]
        loaded = false
        persist()
        Task { await CacheStore.shared.remove(forKey: Self.notSharingKey) }
    }

    private func persist() {
        let snapshot = events
        Task { await CacheStore.shared.save(snapshot, forKey: Self.cacheKey) }
    }
}
