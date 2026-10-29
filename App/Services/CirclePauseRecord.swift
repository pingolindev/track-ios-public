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

/// Each circle's sharing modes over time, as this account set them: when it
/// was NOT sharing (paused, or real-time off), so that a point captured then is
/// never sent to that circle, and when it shared only approximately, so that
/// such a point goes coarsened as it was then (below). Ingest drops what
/// ARRIVES while a circle is paused, and it reads no capture time: a late
/// visit, a kept point, or a check-in carrying a fix taken during a pause would
/// otherwise reach the circle once the pause was over.
///
/// Fed by every privacy row this device learns from the server: each circle
/// refresh (a `privacy_check` wake's included), and the answer to each change
/// made here. A row says whether the account shares NOW. It also carries the
/// server's own record (`not_sharing_intervals`: every span not ended or ended
/// within 72 h), which knows a pause set and ended on another device while this
/// one was offline; it is kept beside this device's own, never instead of it.
/// From the rows alone:
/// - a change made here is exact;
/// - a pause first seen in a refresh starts where the server's own span says;
///   without one, when this account was last seen sharing with the circle, the
///   earliest it can have begun;
/// - it ends when a row next shows the account sharing, or at its planned end
///   (`paused_until`) if that comes first.
///
/// `withholds` is asked before any send to a circle. It answers yes for:
/// - a capture time inside an interval, with `skewMargin` either side (server
///   times against this device's clock), but none after a change made here
///   that ended it: that time is this device's own, so Send location right
///   after a Resume goes;
/// - a late point from before anything was known of the circle (fail closed).
/// The self circle is never asked about.
///
/// A point that waited (kept, or late) is also asked `awaitsRead`: it goes
/// only once a row READ from the server at least `skewMargin` after it was
/// taken has reached the record, because a pause set and ended on another
/// device while this one was offline is known only from the server's spans,
/// and ingest takes what arrives after the pause (the same rule as on
/// Android). Meanwhile it is kept, not withheld for what the record does not
/// know yet: that read decides. A save's own copy is no read. A live send does
/// not wait: ingest drops what arrives during a pause. A check-in does not wait
/// either, but it re-sends a HELD fix: after an offline stretch (a failed send,
/// a rebuilt stream, this process starting) a circle not read since then is
/// first read once (`PrivacyReadAfterOffline`), or skipped by that check-in.
///
/// A row is the server's word as of when it was learnt, so a span in the
/// server's record as last read that the row ends (sharing again, exact, or
/// another bubble) ended by then: a save made here answers with no spans.
///
/// The same rows say when the account shared APPROXIMATELY, and with what
/// bubble: a point captured then goes coarsened to that bubble whenever it is
/// sent, even after a switch to exact (`captureRadius`). Learnt the same way: a
/// change made here is exact; a switch first seen in a refresh starts when the
/// account was last seen sharing exactly, and a new bubble seen in a refresh
/// when the old one was last seen, so the two overlap and the larger counts;
/// the server's `approximate_intervals` are kept beside. A pause taken from
/// approximate keeps the stretch (nothing goes during it). Where nothing is
/// known, a late point goes in the largest bubble a member can set (fail
/// closed).
///
/// Kept `keepFor` after an interval ends: ingest stores a late point whose day
/// holds some instant in the last 48 h and 5 min, so up to ~72 h old. Per
/// account; another account's file is dropped. Emptied at sign-out with the
/// points kept for circles (`PendingCircleLocations`); what was before the next
/// sign-in is unknown then, and held back. Holds circle ids, times and bubble
/// sizes, never a position.
@MainActor
final class CirclePauseRecord {
    static let shared = CirclePauseRecord()

    /// Server boundaries against this device's clock: a point this
    /// close to an interval counts as inside it.
    nonisolated static let skewMargin: TimeInterval = 60
    /// How long an ended interval is kept.
    nonisolated static let keepFor: TimeInterval = 96 * 60 * 60
    /// How far back the server's `not_sharing_intervals` reach from its refresh.
    nonisolated static let serverWindow: TimeInterval = 72 * 60 * 60
    /// A bound on the file however often a circle is paused.
    nonisolated static let maxIntervals = 200
    /// A lastSharingAt-only change is written at most this often.
    nonisolated static let sharingWriteInterval: TimeInterval = 5 * 60
    /// The bubble a late point goes in when nothing says which one was in
    /// force when it was taken: the largest a member can set (fail closed).
    nonisolated static let unknownBubbleMiles = Double(ApproximateArea.senderRadii.upperBound)

    struct CircleRecord: Codable, Equatable {
        /// The first time this device knew the circle's posture. Before it,
        /// unless the server's record reaches further, nothing is known.
        var knownSince: Date
        /// The last time a row showed this account sharing with the circle.
        var lastSharingAt: Date?
        /// The last time a row was READ from the server: a refresh, a fetch,
        /// the answer to a Resume (its spans); never a save's own copy.
        var lastReadAt: Date?
        /// When a change made here last ended a stretch of not sharing
        /// (a Resume, or real time switched back on), and of sharing
        /// approximately (exact again, or another bubble), by this
        /// device's own clock.
        var resumedHereAt: Date?
        var bubbleEndedHereAt: Date?
        /// Seen here: changes made here, and changes a refresh showed.
        var observed: [PauseInterval] = []
        /// The server's own record, as of `serverAsOf`.
        var server: [PauseInterval] = []
        var serverAsOf: Date?
        /// The last time any row of the circle was learnt.
        var lastObservedAt: Date?
        /// The last time a row showed this account not sharing approximately,
        /// nor in a pause that returns to it.
        var lastExactAt: Date?
        /// Stretches of sharing approximately, seen here and the server's.
        var observedApproximate: [ApproximateInterval] = []
        var serverApproximate: [ApproximateInterval] = []
        var approximateServerAsOf: Date?

        /// From when this device knows the circle's posture.
        var historyFrom: Date {
            min(knownSince, serverAsOf.map { $0.addingTimeInterval(-CirclePauseRecord.serverWindow) } ?? .distantFuture)
        }

        /// From when this device knows whether the account shared approximately.
        var approximateHistoryFrom: Date {
            min(knownSince, approximateServerAsOf.map { $0.addingTimeInterval(-CirclePauseRecord.serverWindow) }
                ?? .distantFuture)
        }
    }

    private struct Stored: Codable {
        var owner: String
        var circles: [String: CircleRecord]
    }

    private let directory: URL?
    private var loaded: Stored?
    private var lastWriteAt: Date?
    /// When this phone last lost the server, by its own clock: a failed send, a
    /// rebuilt stream, or this process starting (no wake reaches a process that
    /// is not running). A pause set and ended elsewhere since then reached this
    /// phone by no wake: only a read tells.
    private(set) var offlineSince: Date

    /// `directory` nil = Application Support. Tests pass a scratch directory,
    /// and when this process started.
    init(directory: URL? = nil, startedAt: Date = Date()) {
        self.directory = directory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        offlineSince = startedAt
    }

    // MARK: - The rule

    /// Whether a row says this account shares with the circle at `now`: not
    /// paused (a pause past its `paused_until` has lapsed), and real time on.
    /// The send gate's rule (`CircleManager.uploadTargets`), and ingest's.
    nonisolated static func shares(_ row: PrivacySettings, at now: Date) -> Bool {
        let paused = row.sharingMode == "paused" && (row.pausedUntil.map { $0 > now } ?? true)
        return !paused && row.shareRealtime
    }

    /// Whether `circle`'s record covers a point captured at `capturedAt`
    /// (`withholds`, with the record in hand). Nothing known of the time: a
    /// late point is held back (fail closed), unless it is `waiting` for a row
    /// read since it was taken (`awaitsRead`), which will tell.
    nonisolated static func covers(_ circle: CircleRecord?, capturedAt: Date, now: Date, waiting: Bool = false) -> Bool {
        let failClosed = !waiting && capturedAt < now.addingTimeInterval(-skewMargin)
        guard let circle else { return failClosed }
        if capturedAt < circle.historyFrom { return failClosed }
        return (circle.observed + circle.server).contains { interval in
            !endedHere(start: interval.start, end: interval.lastCovered, at: circle.resumedHereAt, capturedAt: capturedAt)
                && interval.start.addingTimeInterval(-skewMargin) <= capturedAt
                && capturedAt <= interval.lastCovered.addingTimeInterval(skewMargin)
        }
    }

    /// The bubble a point captured at `capturedAt` goes to the circle in
    /// (`captureRadius`, with the record in hand): the largest of the
    /// stretches of sharing approximately around it, `skewMargin` either side;
    /// nil when it was captured while sharing exactly. Where nothing is known
    /// of the time, a late point gets `unknownBubbleMiles` (fail closed).
    nonisolated static func captureRadius(_ circle: CircleRecord?, capturedAt: Date, now: Date) -> Double? {
        let late = capturedAt < now.addingTimeInterval(-skewMargin)
        guard let circle else { return late ? unknownBubbleMiles : nil }
        if capturedAt < circle.approximateHistoryFrom { return late ? unknownBubbleMiles : nil }
        return (circle.observedApproximate + circle.serverApproximate)
            .filter { span in
                !endedHere(start: span.start, end: span.end ?? .distantFuture, at: circle.bubbleEndedHereAt,
                           capturedAt: capturedAt)
                    && span.start.addingTimeInterval(-skewMargin) <= capturedAt
                    && capturedAt <= (span.end ?? .distantFuture).addingTimeInterval(skewMargin)
            }
            .map(\.radiusMiles)
            .max()
    }

    /// Whether a span that began before `here`, a change made on this device
    /// that ended it, and ended by then (the server's copy within
    /// `skewMargin`), is past for a point captured since: no margin after it.
    nonisolated static func endedHere(start: Date, end: Date, at here: Date?, capturedAt: Date) -> Bool {
        guard let here else { return false }
        return capturedAt >= here && start <= here && end <= here.addingTimeInterval(skewMargin)
    }

    // MARK: - Asking

    /// Whether a point captured at `capturedAt` that waited must wait on for
    /// `circleId`: no row has been read from the server since a minute after
    /// it (`awaitsRead`, with the record in hand).
    nonisolated static func awaitsRead(_ circle: CircleRecord?, capturedAt: Date) -> Bool {
        guard let read = circle?.lastReadAt else { return true }
        return read < capturedAt.addingTimeInterval(skewMargin)
    }

    /// Whether `circle` has had no row read from the server since `offlineSince`
    /// (`unreadSinceOffline`, with the record in hand).
    nonisolated static func unreadSince(_ circle: CircleRecord?, offlineSince: Date) -> Bool {
        guard let read = circle?.lastReadAt else { return true }
        return read < offlineSince
    }

    /// A send that failed on the way to the server, or a stream rebuilt.
    func noteOffline(at now: Date = Date()) {
        offlineSince = max(offlineSince, now)
    }

    /// Whether `circleId` has had no row read from the server since this phone
    /// was last offline. Personal history never waits.
    func unreadSinceOffline(circleId: String, owner: String?, now: Date = Date()) -> Bool {
        guard let circleId = CanonicalId.circle(circleId), let owner = CanonicalId.of(owner) else { return false }
        return Self.unreadSince(stored(owner: owner, now: now).circles[circleId], offlineSince: offlineSince)
    }

    /// Whether a point captured at `capturedAt` must not go to `circleId`; one
    /// `waiting` for a read is kept rather than dropped for what it will tell.
    func withholds(circleId: String, capturedAt: Date, owner: String?, now: Date = Date(),
                   waiting: Bool = false) -> Bool {
        guard let circleId = CanonicalId.circle(circleId), let owner = CanonicalId.of(owner) else { return false }
        return Self.covers(stored(owner: owner, now: now).circles[circleId], capturedAt: capturedAt, now: now,
                           waiting: waiting)
    }

    /// Whether a point captured at `capturedAt` that waited (kept, or late)
    /// waits on before it may go to `circleId`. The self circle never waits.
    func awaitsRead(circleId: String, capturedAt: Date, owner: String?, now: Date = Date()) -> Bool {
        guard let circleId = CanonicalId.circle(circleId), let owner = CanonicalId.of(owner) else { return false }
        return Self.awaitsRead(stored(owner: owner, now: now).circles[circleId], capturedAt: capturedAt)
    }

    /// The bubble, in miles, a point captured at `capturedAt` goes to
    /// `circleId` in whatever the mode now; nil when it goes exact. The self
    /// circle is never coarsened.
    func captureRadius(circleId: String, capturedAt: Date, owner: String?, now: Date = Date()) -> Double? {
        guard let circleId = CanonicalId.circle(circleId), let owner = CanonicalId.of(owner) else { return nil }
        return Self.captureRadius(stored(owner: owner, now: now).circles[circleId], capturedAt: capturedAt, now: now)
    }

    /// The record of one circle, for tests and diagnostics.
    func circle(_ circleId: String, owner: String?, now: Date = Date()) -> CircleRecord? {
        guard let circleId = CanonicalId.circle(circleId), let owner = CanonicalId.of(owner) else { return nil }
        return stored(owner: owner, now: now).circles[circleId]
    }

    // MARK: - Learning

    /// A row as the server stood at `now`: a refresh's, or the answer to a
    /// change made here (`exact`). Its `notSharingIntervals`, when the server
    /// sent them, replace the server's part of the record, never this device's.
    func observe(_ row: PrivacySettings, at now: Date, exact: Bool = false, owner: String?) {
        guard let circleId = CanonicalId.circle(row.circleId), let owner = CanonicalId.of(owner) else { return }
        var stored = stored(owner: owner, now: now)
        let before = stored.circles[circleId]
        stored.circles[circleId] = Self.observed(row, before: before, at: now, exact: exact)
        let changed = Self.intervalsChanged(before, stored.circles[circleId])
        save(stored, now: now, force: changed)
    }

    /// `observe`'s step, on one circle's record.
    nonisolated static func observed(_ row: PrivacySettings, before: CircleRecord?, at now: Date, exact: Bool) -> CircleRecord {
        var circle = before ?? CircleRecord(knownSince: now)
        let running = circle.observed.last.map { $0.end == nil } ?? false
        if let recent = row.notSharingIntervals {
            circle.server = Array(recent.suffix(maxIntervals))
            circle.serverAsOf = now
        }
        if shares(row, at: now) {
            if running {
                let last = circle.observed.count - 1
                let planned = circle.observed[last].plannedEnd
                // Seen ending in a refresh: it ended at most now, and a timed
                // pause no later than planned. A change made here: now.
                circle.observed[last].end = exact ? now : min(now, planned ?? now)
            }
            circle.lastSharingAt = now
            // A Resume or real time switched back on in a save made here: the
            // server's spans as last read still run, or are planned past now.
            var ended = running
            for index in circle.server.indices where circle.server[index].lastCovered > now {
                circle.server[index].end = now
                ended = true
            }
            if exact, ended { circle.resumedHereAt = now }
        } else if running {
            // Still running: a moved or added end is what this row says now.
            circle.observed[circle.observed.count - 1].plannedEnd = row.pausedUntil
        } else {
            let start = exact ? now
                : Self.running(row.notSharingIntervals, at: now)?.start ?? (circle.lastSharingAt ?? circle.knownSince)
            circle.observed.append(PauseInterval(start: start, end: nil, plannedEnd: row.pausedUntil))
            circle.observed = Array(circle.observed.suffix(maxIntervals))
        }
        observeApproximate(row, into: &circle, at: now, exact: exact)
        // Read from the server: anything but a save made here, whose copy
        // carries no spans; a Resume's answer is the server's own row.
        if !exact || row.notSharingIntervals != nil { circle.lastReadAt = now }
        circle.lastObservedAt = now
        return circle
    }

    /// `observed`'s step for sharing approximately.
    nonisolated static func observeApproximate(_ row: PrivacySettings, into circle: inout CircleRecord,
                                               at now: Date, exact: Bool) {
        // As the row shares, or a pause returns to. A bubble that is none: the
        // largest a member can set (fail closed).
        let approximate = row.sharesApproximately(at: now)
        let radius = row.bubbleRadius > 0 ? row.bubbleRadius : unknownBubbleMiles
        if let recent = row.approximateIntervals {
            circle.serverApproximate = Array(recent.suffix(maxIntervals))
            circle.approximateServerAsOf = now
        }
        // Exact, or another bubble, in a save made here: the server's spans as
        // last read still run.
        var ended = false
        for index in circle.serverApproximate.indices
        where (circle.serverApproximate[index].end ?? .distantFuture) > now
            && (!approximate || circle.serverApproximate[index].radiusMiles != radius) {
            circle.serverApproximate[index].end = now
            ended = true
        }
        let running = circle.observedApproximate.last.flatMap { $0.end == nil ? $0 : nil }
        if let running, !approximate || running.radiusMiles != radius {
            // Ended, or a new bubble: the old one was in force until now at most.
            circle.observedApproximate[circle.observedApproximate.count - 1].end = now
            ended = true
        }
        if exact, ended { circle.bubbleEndedHereAt = now }
        if approximate, running?.radiusMiles != radius {
            // Seen in a refresh, it began where the server's own stretch says;
            // without one, at most when the account was last seen not
            // approximate, or a new bubble when the old one was last seen. A
            // change made here: now.
            let start = exact ? now
                : Self.running(row.approximateIntervals, radius: radius, at: now)?.start
                    ?? (running != nil ? (circle.lastObservedAt ?? now) : (circle.lastExactAt ?? circle.knownSince))
            circle.observedApproximate.append(ApproximateInterval(start: start, end: nil, radiusMiles: radius))
            circle.observedApproximate = Array(circle.observedApproximate.suffix(maxIntervals))
        }
        if !approximate { circle.lastExactAt = now }
    }

    /// The server's span running at `now` (the latest to begin), when the row
    /// carried its spans and one runs.
    nonisolated static func running(_ spans: [PauseInterval]?, at now: Date) -> PauseInterval? {
        spans?.last { span in
            span.start <= now.addingTimeInterval(skewMargin) && span.lastCovered.addingTimeInterval(skewMargin) >= now
        }
    }

    /// The server's stretch of `radius` running at `now`, likewise.
    nonisolated static func running(_ spans: [ApproximateInterval]?, radius: Double, at now: Date) -> ApproximateInterval? {
        spans?.last { span in
            span.radiusMiles == radius && span.start <= now.addingTimeInterval(skewMargin)
                && (span.end ?? .distantFuture).addingTimeInterval(skewMargin) >= now
        }
    }

    // MARK: - Storage

    private var fileURL: URL? {
        directory?.appendingPathComponent("circle-pause-record.json", isDirectory: false)
    }

    /// This account's record, pruned. Another account's file is never read
    /// back: it is dropped.
    private func stored(owner: String, now: Date) -> Stored {
        if loaded == nil, let url = fileURL, let data = try? Data(contentsOf: url) {
            loaded = try? JSONDecoder().decode(Stored.self, from: data)
        }
        var stored = loaded?.owner == owner ? loaded! : Stored(owner: owner, circles: [:])
        stored.circles = stored.circles.mapValues { Self.pruned($0, now: now) }
        return stored
    }

    /// Intervals that ended more than `keepFor` ago are no use to any late point.
    nonisolated static func pruned(_ circle: CircleRecord, now: Date) -> CircleRecord {
        let oldest = now.addingTimeInterval(-keepFor)
        var circle = circle
        circle.observed.removeAll { $0.lastCovered < oldest }
        circle.server.removeAll { $0.lastCovered < oldest }
        circle.observedApproximate.removeAll { ($0.end ?? .distantFuture) < oldest }
        circle.serverApproximate.removeAll { ($0.end ?? .distantFuture) < oldest }
        return circle
    }

    nonisolated static func intervalsChanged(_ a: CircleRecord?, _ b: CircleRecord?) -> Bool {
        a?.observed != b?.observed || a?.server != b?.server || a?.knownSince != b?.knownSince
            || a?.observedApproximate != b?.observedApproximate || a?.serverApproximate != b?.serverApproximate
    }

    /// Written at once when an interval changed; a newer "last seen sharing" or
    /// server refresh time alone at most every `sharingWriteInterval`. Both
    /// only ever move later, so stale ones on disk err towards holding a point
    /// back: an earlier start for a pause seen later, and no knowledge claimed
    /// that the intervals on disk do not hold.
    private func save(_ stored: Stored, now: Date, force: Bool) {
        loaded = stored
        guard force || lastWriteAt.map({ now.timeIntervalSince($0) >= Self.sharingWriteInterval }) ?? true,
              let url = fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
        lastWriteAt = now
    }

    /// Sign-out: with the points kept for circles, the record of when they may
    /// not go. What comes before the next sign-in's first refresh is held back.
    func clearAll() {
        loaded = nil
        lastWriteAt = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}

/// After an offline stretch, ONE light privacy refresh before a check-in's held
/// fix or the kept points are judged: a pause set and ended on another device
/// while this phone was offline reached it by no wake, so the record has no
/// span for it until the server is read again. Shared by every caller (a
/// check-in, the drain), bounded inside a background wake's time, and never
/// tried again sooner than `retryAfter`: a failed one is retried by the next
/// caller, not in a loop.
@MainActor
final class PrivacyReadAfterOffline {
    static let shared = PrivacyReadAfterOffline {
        _ = try? await CircleManager.shared.loadCircles(light: true)
    }

    /// How long a check-in waits for it, inside a background wake's time.
    nonisolated static let waitAtMost: TimeInterval = 8
    /// The least time between two attempts.
    nonisolated static let retryAfter: TimeInterval = 60

    private let read: @MainActor () async -> Void
    private var running: Task<Void, Never>?
    private var lastAttemptAt: Date?

    init(read: @escaping @MainActor () async -> Void) {
        self.read = read
    }

    /// Starts the refresh unless one runs or the last attempt was less than
    /// `retryAfter` ago, then waits for the running one, `within` at most. The
    /// caller asks the record what it learnt.
    func refresh(within: TimeInterval = waitAtMost, now: Date = Date()) async {
        if running == nil {
            if let last = lastAttemptAt, now.timeIntervalSince(last) < Self.retryAfter { return }
            lastAttemptAt = now
            running = Task { @MainActor in
                await self.read()
                self.running = nil
            }
        }
        let deadline = Date().addingTimeInterval(within)
        while running != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
