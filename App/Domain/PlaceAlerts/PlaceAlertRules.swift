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

/// Pure decision logic for SUBSCRIBER-SIDE place alerts.
///
/// The subscriber's device already receives and decrypts every circle member's
/// location — that is how it draws them on the map — so it can evaluate those
/// locations against its own private, never-shared place entirely locally. No
/// crossing is routed through the blind server, no circle-key hash is computed,
/// no `place_shares` row and no wrapped place key are needed.
///
/// Port of the Android app's `PlaceAlertRules`. Deliberately free of
/// UIKit/CoreLocation/persistence dependencies so the four correctness rules
/// can be tested directly:
///
///  1. Stateful, per member    -> `reconcile` carries `MemberPlaceState` (in/out
///     state + the timestamp of the last location already accounted for).
///  2. Reconcile in time order -> `reconcile` sorts oldest-to-newest and only
///     `classify` decides which transitions are recent enough to notify; older
///     ones come back marked `Decision.silent`.
///  3. Stamp with the real time-> every `Crossing` carries `crossedAt`, the
///     member location's OWN timestamp, and the copy builders render from it.
///  4. De-duplicate hard       -> `Crossing.ledgerId` is a deterministic identity
///     for a crossing, stable across process restarts, so the persistence layer
///     can claim it exactly once ever.
///
/// Times are epoch MILLISECONDS (`Int64`) throughout rather than `Date`. The
/// ledger id embeds the crossing time verbatim, and Android derives the same id
/// from the same millisecond value — using `Date` here would let rounding drift
/// silently break cross-platform identity of the same crossing.
enum PlaceAlertRules {

    // MARK: - Tuning constants

    /// How far back a missed crossing may be and still raise a notification.
    ///
    /// Product tuning knob. Two hours comfortably covers the outages that
    /// actually produce catch-up batches — a commute through poor coverage, a
    /// phone asleep in a bag, a brief connectivity drop — while staying short
    /// enough that a crossing surfaced as "2h ago" still reads as something
    /// worth knowing rather than archaeology. Anything older folds silently
    /// into history instead of a push, so a phone that was off all weekend does
    /// not reconnect and dump a pile of ancient pings.
    static let stalenessWindowMs: Int64 = 2 * 60 * 60 * 1000

    /// Lag below which a crossing is presented with no "ago" qualifier at all.
    /// Above it the copy carries the real elapsed time, so a delayed alert never
    /// claims to be live (Rule 3).
    static let liveLagToleranceMs: Int64 = 3 * 60 * 1000

    /// How far apart the two paths' views of the SAME crossing may be and still
    /// be treated as one event. The server-routed push carries no crossing
    /// timestamp, so cross-path de-duplication matches on
    /// (place, member, transition) within a window rather than on an exact id.
    ///
    /// Sized for PUSH LATENCY and nothing else — the two paths see the same
    /// crossing seconds apart, not minutes. It must stay well under the shortest
    /// realistic gap between two genuine crossings of the same place, because
    /// anything inside the window that matches the other path is treated as the
    /// same event. A 15-minute window, for instance, would silently swallow a
    /// real arrival whenever someone left and came back within a quarter of an
    /// hour — moving the car, walking the dog, a school run.
    static let crossPathDedupeWindowMs: Int64 = 90 * 1000

    /// How far BEFORE a shown server push the crossing it reported may have
    /// happened and still be superseded by the local copy — and how long the
    /// marker for it stays live.
    ///
    /// Distinct from `crossPathDedupeWindowMs`, which is sized for push latency
    /// alone. The local copy only exists once the mover's location has landed AND
    /// this device has evaluated it, which is minutes, not seconds; with the
    /// 90-second window the marker would always have expired by then, and the
    /// notification would stack beside the generic one instead of replacing it.
    static let serverPushSupersedeWindowMs: Int64 = 15 * 60 * 1000

    /// How far AFTER a shown push a crossing may be and still be treated as the
    /// one it reported. Clock skew only.
    ///
    /// This bound is the safety property, and it is why the window above can be
    /// generous: a push can only report a crossing that already happened, so a
    /// materially later one is a DIFFERENT crossing. Symmetric at 15 minutes, a
    /// departure could take an arrival's notification id and replace it in the
    /// tray — the user would never learn they arrived.
    static let serverPushSupersedeSkewMs: Int64 = 90 * 1000

    /// Mean Earth radius, matching the native BoundaryChecker (boundary.rs).
    private static let earthRadiusMeters: Double = 6_371_000

    // MARK: - Types

    /// A place's geofence as the local evaluator sees it.
    struct PlaceGeofence: Equatable {
        let placeId: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Int

        init(placeId: String, latitude: Double, longitude: Double, radiusMeters: Int) {
            self.placeId = placeId
            self.latitude = latitude
            self.longitude = longitude
            self.radiusMeters = radiusMeters
        }
    }

    enum Transition: String, Equatable {
        case enter
        case exit

        /// Wire/ledger form, matching Android's BoundaryRepository EVENT_TYPE_*.
        var wire: String { rawValue }
    }

    /// One detected in/out transition, stamped with when it ACTUALLY happened.
    struct Crossing: Equatable {
        let placeId: String
        let userId: String
        let transition: Transition
        /// The member location's own timestamp — never "now". Rule 3.
        let crossedAt: Int64

        /// Stable identity for this crossing. Keyed on (place, member,
        /// transition, crossing time) — never on a row id — so the same crossing
        /// re-derived after a restart, or from an overlapping batch, collapses
        /// onto the same ledger row and can be surfaced at most once, ever.
        /// Rule 4. Byte-identical to Android's `ledgerId`.
        var ledgerId: String { "\(placeId):\(userId):\(transition.wire):\(crossedAt)" }
    }

    /// Per-(place, member) reconciliation state. `lastLocationAt` is the
    /// watermark: the timestamp of the newest location already folded into
    /// `isInside`. Rule 1.
    struct MemberPlaceState: Equatable {
        let isInside: Bool
        let lastLocationAt: Int64
    }

    struct Reconciliation: Equatable {
        let state: MemberPlaceState
        /// Transitions detected in this batch, oldest to newest.
        let crossings: [Crossing]
    }

    /// A single point handed to the evaluator (a decrypted member location).
    struct Point: Equatable {
        let latitude: Double
        let longitude: Double
        let timestamp: Int64

        /// Reported horizontal accuracy in metres, or nil when the sender did not
        /// say. See `canResolve` for why it is read and what nil means.
        ///
        /// NIL IS "UNKNOWN", NOT "PERFECT" — and it must stay that way. A sender
        /// that omits the field (an older client, or one whose platform gave no
        /// accuracy) would otherwise have its watcher's alerts silently disabled,
        /// which is the same silent-loss failure this gate exists to avoid, moved
        /// somewhere new. Unknown means EVALUATE.
        ///
        /// Defaulted so the self path and callers with no accuracy to give keep
        /// the "unknown" behaviour rather than silently acquiring a new one.
        let accuracyMeters: Double?

        init(
            latitude: Double,
            longitude: Double,
            timestamp: Int64,
            accuracyMeters: Double? = nil
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.timestamp = timestamp
            self.accuracyMeters = accuracyMeters
        }
    }

    /// How a crossing (or a collapsed pair) should be presented.
    ///
    /// Kotlin models this as a sealed interface; a Swift enum with associated
    /// values gives the same exhaustiveness with a compiler-checked `switch`.
    enum Surfacing: Equatable {
        /// Arrived; `stillInside` means their latest known position is in the zone.
        case arrival(crossing: Crossing, stillInside: Bool)
        /// Left the place.
        case departure(crossing: Crossing)
        /// A complete pass-through the subscriber missed: enter AND exit landed
        /// in the same catch-up batch. Collapsed into ONE past-framed entry
        /// rather than two pings.
        case passThrough(enter: Crossing, exit: Crossing)

        /// Every crossing this surfacing accounts for — all must be claimed in
        /// the ledger, or the unclaimed half can resurface later as its own alert.
        var crossings: [Crossing] {
            switch self {
            case let .arrival(crossing, _): return [crossing]
            case let .departure(crossing): return [crossing]
            case let .passThrough(enter, exit): return [enter, exit]
            }
        }

        /// The crossing time the copy is stamped with / staleness is judged on.
        var at: Int64 {
            switch self {
            case let .arrival(crossing, _): return crossing.crossedAt
            case let .departure(crossing): return crossing.crossedAt
            case let .passThrough(_, exit): return exit.crossedAt
            }
        }
    }

    /// A surfacing plus whether it may raise a notification.
    ///
    /// `silent` transitions still get a ledger row and a history entry — they are
    /// "accounted for", just not pushed. That is what stops a reconnect flood
    /// while keeping Rule 4's at-most-once guarantee for the same crossing.
    struct Decision: Equatable {
        let surfacing: Surfacing
        let silent: Bool
    }

    // MARK: - Geometry

    /// Great-circle distance in metres. Same formula and Earth radius as the
    /// native BoundaryChecker so the local evaluator and the mover-side
    /// detector can never disagree about whether a point is in the zone.
    static func distanceMeters(
        _ lat1: Double, _ lng1: Double,
        _ lat2: Double, _ lng2: Double
    ) -> Double {
        let lat1Rad = lat1 * .pi / 180
        let lat2Rad = lat2 * .pi / 180
        let deltaLat = (lat2 - lat1) * .pi / 180
        let deltaLng = (lng2 - lng1) * .pi / 180
        let sinLat = sin(deltaLat / 2)
        let sinLng = sin(deltaLng / 2)
        let a = sinLat * sinLat + cos(lat1Rad) * cos(lat2Rad) * sinLng * sinLng
        return earthRadiusMeters * 2 * asin(min(1, sqrt(a)))
    }

    /// Extra distance beyond the radius a member must travel before an EXIT is
    /// declared. 20% of the radius, floored at 20 m so small geofences still get
    /// a usable buffer, capped at 100 m so a large one doesn't swallow genuine
    /// departures.
    ///
    /// MUST match `exit_margin_meters` in mobile-sdk boundary.rs.
    private static let exitMarginFraction = 0.20
    private static let exitMarginMinM = 20.0
    private static let exitMarginMaxM = 100.0

    static func exitMarginMeters(radiusMeters: Double) -> Double {
        min(max(radiusMeters * exitMarginFraction, exitMarginMinM), exitMarginMaxM)
    }

    /// Whether a fix of this accuracy can say anything at all about this geofence.
    ///
    /// A fix whose own error exceeds the radius carries NO information about the
    /// ring: the true position is somewhere in a circle larger than the feature
    /// being tested, so "inside" and "outside" are both consistent with the
    /// measurement. Any alert fired from it is a guess, and a guess is not worth a
    /// banner — it is worth saying nothing.
    ///
    /// This is deliberately a SKIP and not a widened margin. Widening only ever
    /// moves the EXIT threshold (`isInside` keeps arrival at the true radius on
    /// purpose), so on its own it would stop spurious departures while leaving
    /// spurious ARRIVALS untouched — and then hold them, because the same widened
    /// margin prevents the exit that would clear them.
    ///
    /// Per-place, not global: the same 500 m fix is useless against a 100 m ring
    /// and perfectly usable against a 2 km one, so only rings smaller than the
    /// fix's own error go dark.
    ///
    /// WHY THIS IS NOT THEORETICAL, and why it is the bubble that makes it urgent.
    /// A circle sharing "approximate" has its members' coordinates snapped to a
    /// grid whose cell is the bubble radius, and the sender floors the reported
    /// accuracy to that cell so it never advertises sub-cell precision
    /// (`SDKLocationStreamer` coarsened branch; the Android app's
    /// `LocationRepository.motionFieldsFor`). Bubbles are 1-25 miles and rings are
    /// 50-25000 m, so a bubbled fix is usually far rougher than the ring it would
    /// be tested against. Judged against the true ring as though it were exact,
    /// that snapped point gives a STABLE wrong answer, because the grid is FIXED
    /// rather than jittered: a member's cell centre either sits inside the ring or
    /// it does not, and stays that way for as long as they remain in that cell.
    /// That is a permanent false "arrived", or a permanent silence for someone who
    /// visits daily. Every client must screen alike, or the same privacy setting
    /// protects users differently depending on the client their WATCHER runs.
    ///
    /// PARITY: must stay identical to the Android app's
    /// `PlaceAlertRules.canResolve` and to the web client's `canResolve`.
    ///
    /// Nil accuracy means UNKNOWN and evaluates — see `Point.accuracyMeters`.
    static func canResolve(geofence: PlaceGeofence, accuracyMeters: Double?) -> Bool {
        guard let accuracyMeters else { return true }
        return accuracyMeters <= Double(geofence.radiusMeters)
    }

    /// Whether a point counts as inside the geofence, given what we believed a
    /// moment ago.
    ///
    /// ASYMMETRIC on purpose. You ARRIVE at the true radius, but you must get
    /// clearly clear of it before we call it a departure. A bare
    /// `distance <= radius` flips on a single noisy fix, and because this feeds a
    /// state machine that costs the user BOTH a spurious departure and a spurious
    /// arrival when the next fix lands back inside — two false alerts from one
    /// wobble. Ordinary GPS error at the edge of a 150 m geofence is ample.
    ///
    /// Arrival deliberately keeps the true radius: widening it too would make
    /// people arrive early, which is a worse failure than the flapping this
    /// prevents.
    ///
    /// PARITY: must stay identical to `check_location` in mobile-sdk boundary.rs
    /// and to Android's `isInside`. The detectors judge the same fixes, so a
    /// margin on one side only makes them disagree about who is inside.
    ///
    /// - Parameter wasInside: what we believed before this fix; `nil` when there
    ///   is no prior state, in which case the plain radius applies.
    /// - Parameter accuracyMeters: reported accuracy of THIS fix, widening the
    ///   exit margin when the fix is rougher than the margin already allows for. A
    ///   fix precise enough to be evaluated at all (`canResolve`) can still be
    ///   rougher than a 20 m floor, and a departure declared on noise costs the
    ///   user two false alerts. Only ever WIDENS: `max` with the geometric margin,
    ///   so a precise fix gets exactly the geometric margin.
    static func isInside(
        geofence: PlaceGeofence,
        latitude: Double,
        longitude: Double,
        wasInside: Bool?,
        accuracyMeters: Double? = nil
    ) -> Bool {
        let distance = distanceMeters(latitude, longitude, geofence.latitude, geofence.longitude)
        let radius = Double(geofence.radiusMeters)
        if wasInside == true {
            let margin = max(exitMarginMeters(radiusMeters: radius), accuracyMeters ?? 0)
            return distance <= radius + margin
        }
        return distance <= radius
    }

    // MARK: - Reconciliation

    /// Fold a batch of a single member's locations into their state for one
    /// place, walking OLDEST to NEWEST (Rule 2).
    ///
    /// - Points at or before the watermark (`MemberPlaceState.lastLocationAt`)
    ///   are already accounted for and are skipped, so an overlapping batch or a
    ///   replayed page can never re-drive a transition.
    /// - With no prior state the first point SEEDS the state and emits no
    ///   crossing: a first-ever fix is not a transition. Defaulting to "outside"
    ///   instead would make a cold start while already inside a geofence report
    ///   a phantom ARRIVAL. The shared mobile-sdk primes on first observation
    ///   exactly as here. A device that restarts inside a place must not be told
    ///   it just got there.
    ///
    /// Returns `nil` when the batch contributes nothing (all points already
    /// accounted for), so the caller can skip the write entirely.
    static func reconcile(
        geofence: PlaceGeofence,
        userId: String,
        prior: MemberPlaceState?,
        points: [Point]
    ) -> Reconciliation? {
        let fresh = points
            .filter { prior == nil || $0.timestamp > prior!.lastLocationAt }
            .sorted { $0.timestamp < $1.timestamp }
        guard !fresh.isEmpty else { return nil }

        var state = prior
        var crossings: [Crossing] = []

        for point in fresh {
            let inside = isInside(
                geofence: geofence,
                latitude: point.latitude,
                longitude: point.longitude,
                wasInside: state?.isInside,
                accuracyMeters: point.accuracyMeters
            )
            if let previous = state, inside != previous.isInside {
                crossings.append(
                    Crossing(
                        placeId: geofence.placeId,
                        userId: userId,
                        transition: inside ? .enter : .exit,
                        crossedAt: point.timestamp
                    )
                )
            }
            state = MemberPlaceState(isInside: inside, lastLocationAt: point.timestamp)
        }

        // `fresh` is non-empty, so the loop always assigned `state`.
        guard let final = state else { return nil }
        return Reconciliation(state: final, crossings: crossings)
    }

    /// Turn the batch's transitions into presentation decisions.
    ///
    /// Transitions alternate by construction, so a consecutive (ENTER, EXIT) pair
    /// is a complete pass-through and collapses into a single past-framed entry.
    /// A trailing unpaired ENTER means they are still there. A leading EXIT means
    /// they were already inside when the batch started.
    ///
    /// Staleness is judged on the MOST RECENT crossing the decision covers — a
    /// visit that started three hours ago but ended five minutes ago is a recent
    /// miss and still worth surfacing.
    static func classify(
        crossings: [Crossing],
        finalInside: Bool,
        now: Int64,
        stalenessWindowMs: Int64 = PlaceAlertRules.stalenessWindowMs
    ) -> [Decision] {
        let ordered = crossings.sorted { $0.crossedAt < $1.crossedAt }
        var decisions: [Decision] = []
        var i = 0
        while i < ordered.count {
            let current = ordered[i]
            let next = i + 1 < ordered.count ? ordered[i + 1] : nil
            let surfacing: Surfacing
            if current.transition == .enter, let next, next.transition == .exit {
                i += 2
                surfacing = .passThrough(enter: current, exit: next)
            } else {
                i += 1
                switch current.transition {
                case .enter: surfacing = .arrival(crossing: current, stillInside: finalInside)
                case .exit: surfacing = .departure(crossing: current)
                }
            }
            decisions.append(
                Decision(surfacing: surfacing, silent: now - surfacing.at > stalenessWindowMs)
            )
        }
        return decisions
    }

    // MARK: - Alert matching

    /// Whether `alert` is a live subscription at the moment the crossing happened.
    ///
    /// An `expiresAt` that fails to parse is treated as NO expiry rather than as
    /// expired. Both are wrong in some sense, but a silently-never-firing alert is
    /// indistinguishable from the feature being broken — which is the exact
    /// failure this whole model exists to eliminate — while an over-firing one is
    /// visible and reportable.
    static func isAlertLive(_ alert: PlaceAlert, at millis: Int64) -> Bool {
        guard alert.isEnabled else { return false }
        guard let raw = alert.expiresAt, let expiry = parseTimestampMs(raw) else { return true }
        return millis <= expiry
    }

    /// Whether `alert` watches `userId` — an explicit target, or circle-wide.
    ///
    /// A CIRCLE-WIDE alert means "everyone in THIS circle", so it must be scoped
    /// to the circle it is homed to. Without that scope it matches every member
    /// whose location the device happens to hold: an alert set for your family
    /// circle also fires when a coworker from an unrelated work circle reaches
    /// your home. Not a data leak — those locations were already decrypted here —
    /// but the wrong set of people, and surprising.
    ///
    /// NOTE the iOS/Android model difference: Android uses a `"all"` sentinel in a
    /// non-optional `targetUserId`; iOS uses `targetUserId == nil` for circle-wide.
    /// Both spellings are accepted here so a row synced from either platform reads
    /// the same way.
    ///
    /// - Parameter targetIsInAlertCircle: whether `userId` is a member of the
    ///   alert's own circle, or `nil` when the roster is UNKNOWN locally.
    ///   Deliberately a required parameter with no default: membership needs a
    ///   lookup the caller must do, and a default would let a new call site
    ///   silently over-match.
    ///
    ///   The `nil` case is load-bearing. A device that hasn't synced the roster
    ///   holds nothing; treating that as "not a member" makes a correctly
    ///   configured alert silently never fire. Absence of knowledge is not
    ///   knowledge of absence.
    static func alertWatches(
        _ alert: PlaceAlert,
        userId: String,
        targetIsInAlertCircle: Bool?,
        /// `allow_alerts_on_me` as carried by the member's OWN latest fix, for the
        /// circle that fix arrived on (`LocationData.allowAlertsOnMe`).
        ///
        /// The never-stale half of the consent check. `alert.suppressedByTarget` is
        /// authoritative about the ANCHOR circle but only as fresh as the last alert
        /// sync; this one rides on the location itself, so it closes the window
        /// between the target flipping the switch and this device re-fetching alerts.
        ///
        /// `false` withholds consent. `true` and `nil` both permit — a member with no
        /// privacy row at all is the DEFAULT state, so reading absence as denial
        /// would silently disable alerts across the estate, and a silently disabled
        /// alert is indistinguishable from a broken feature.
        targetAllowsAlertsOnLatestFix: Bool? = nil
    ) -> Bool {
        // CONSENT FIRST, and it beats every targeting rule below: a circle-wide
        // alert names nobody, so a check wired into the targeted branch alone would
        // let it sweep up someone who has opted out.
        if alert.suppressedByTarget { return false }
        if targetAllowsAlertsOnLatestFix == false { return false }
        let target = alert.targetUserId
        let isCircleWide = target == nil || target == circleWideTarget
        if !isCircleWide {
            // An explicitly targeted alert names a PERSON. Which circle's feed
            // carried the fix is irrelevant — it is the same human at the same
            // place — and the backend already verified that target shares the
            // alert's circle.
            return target == userId
        }
        // Circle-wide with no home circle: only reachable for rows created before
        // the backend required one. Left UNSCOPED on purpose — silently matching
        // nobody would turn a legacy alert into one that never fires.
        guard let circleId = alert.circleId, !circleId.isEmpty else { return true }
        // Roster unknown → do NOT scope, per the parameter doc above.
        guard let known = targetIsInAlertCircle else { return true }
        return known
    }

    /// Target sentinel Android uses for a circle-wide alert. iOS spells the same
    /// thing as `targetUserId == nil`; both are honoured.
    static let circleWideTarget = "all"

    /// Whether `alert` opted into the direction this surfacing represents.
    static func alertWants(_ alert: PlaceAlert, surfacing: Surfacing) -> Bool {
        switch surfacing {
        case .arrival: return alert.alertsOnArrival
        case .departure: return alert.alertsOnDeparture
        // A pass-through IS an arrival that has since ended, so an arrival-only
        // alert still wants it; a departure-only alert wants it for the exit
        // half. Either way it stays ONE entry, never two.
        case .passThrough: return alert.alertsOnArrival || alert.alertsOnDeparture
        }
    }

    // MARK: - Schedule

    /// Whether the crossing falls inside the alert's active schedule, evaluated at
    /// the REAL crossing time rather than "now" — a catch-up batch must be judged
    /// against the window that was in force when the member actually crossed.
    ///
    /// An overnight window (e.g. 22:00-06:00) belongs to the day it STARTS on, so
    /// a 02:00 crossing is matched against the previous day's entry in
    /// `activeDays`. iOS carries no `isOvernight` flag (Android does), so it is
    /// derived from `start > end` — which is the same fallback Android applies
    /// when its flag was never set.
    static func isWithinSchedule(
        _ alert: PlaceAlert,
        at millis: Int64,
        calendar: Calendar = .current
    ) -> Bool {
        let days = Set(
            (alert.activeDays ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        let start = parseMinuteOfDay(alert.activeStartTime)
        let end = parseMinuteOfDay(alert.activeEndTime)
        if days.isEmpty && start == nil && end == nil { return true }

        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday else { return true }
        let minuteOfDay = hour * 60 + minute

        let overnight: Bool = {
            guard let start, let end else { return false }
            return start > end
        }()

        let inWindow: Bool
        switch (start, end) {
        case (nil, nil):
            inWindow = true
        case let (start?, nil):
            inWindow = minuteOfDay >= start
        case let (nil, end?):
            inWindow = minuteOfDay <= end
        case let (start?, end?):
            inWindow = overnight
                ? (minuteOfDay >= start || minuteOfDay <= end)
                : (minuteOfDay >= start && minuteOfDay <= end)
        }
        if !inWindow { return false }
        if days.isEmpty { return true }

        // Calendar weekday is 1=Sunday...7=Saturday; the names array is
        // Monday-based, so shift before indexing.
        var index = (weekday + 5) % 7
        // For an overnight window, the small hours belong to the PREVIOUS day's slot.
        if overnight, let end, minuteOfDay <= end {
            index = (index + 6) % 7
        }
        return days.contains(dayNames[index])
    }

    private static let dayNames = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    /// "HH:mm" -> minutes since midnight. Rejects out-of-range values rather than
    /// clamping, so a malformed window degrades to "no constraint" instead of to a
    /// silently wrong one.
    private static func parseMinuteOfDay(_ raw: String?) -> Int? {
        guard let parts = raw?.trimmingCharacters(in: .whitespaces).split(separator: ":"),
              let hour = parts.first.flatMap({ Int($0) }) else { return nil }
        let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// Parse an RFC3339 timestamp to epoch millis. iOS carries `expiresAt` as a
    /// string where Android has a Long, so the comparison needs this first.
    /// Fractional seconds are optional on the wire, hence the two attempts.
    static func parseTimestampMs(_ raw: String) -> Int64? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }

    // MARK: - Copy

    /// "5 minutes ago" / "2 hours ago" — correctly singularised.
    static func agoLabel(elapsedMs: Int64) -> String {
        let minutes = max(elapsedMs / 60_000, 1)
        let (n, unit): (Int64, String)
        if minutes < 60 {
            (n, unit) = (minutes, "minute")
        } else if minutes < 1440 {
            (n, unit) = (minutes / 60, "hour")
        } else {
            (n, unit) = (minutes / 1440, "day")
        }
        return "\(n) \(unit)\(n == 1 ? "" : "s") ago"
    }

    /// Notification body for a surfacing. Past crossings always carry their real
    /// elapsed time or clock range and never live-sounding language (Rule 3); a
    /// pass-through renders as a single "was at X" span, not two pings.
    ///
    /// - Parameter isSelf: true when the subject is the reader themselves ("You"),
    ///   which takes a second-person verb — "you ARE still there", not "you IS".
    static func describe(
        surfacing: Surfacing,
        memberName: String,
        placeName: String,
        now: Int64,
        calendar: Calendar = .current,
        isSelf: Bool = false
    ) -> String {
        describe(
            surfacing: surfacing,
            memberName: memberName,
            placeLabel: placeName,
            now: now,
            calendar: calendar,
            isSelf: isSelf
        )
    }

    /// Stands in for the place name at the "Names only" detail level.
    static let anonymousPlaceLabel = "a place"

    /// The same body with the PLACE withheld, for `NotificationDetailLevel.names`.
    ///
    /// Shares every other word with `describe` by construction rather than by
    /// copy — the two wordings drifting apart is how a redacted variant quietly
    /// stops matching the thing it is supposed to be a redaction OF.
    ///
    /// The elapsed time and the clock range survive redaction on purpose, for the
    /// same reason `NotificationStamp` does: a time says nothing about who or
    /// where, and when a crossing happened is exactly what a late-delivered alert
    /// needs to convey.
    static func describeNamesOnly(
        surfacing: Surfacing,
        memberName: String,
        now: Int64,
        calendar: Calendar = .current,
        isSelf: Bool = false
    ) -> String {
        describe(
            surfacing: surfacing,
            memberName: memberName,
            placeLabel: anonymousPlaceLabel,
            now: now,
            calendar: calendar,
            isSelf: isSelf
        )
    }

    private static func describe(
        surfacing: Surfacing,
        memberName: String,
        placeLabel placeName: String,
        now: Int64,
        calendar: Calendar,
        isSelf: Bool
    ) -> String {
        switch surfacing {
        case let .arrival(crossing, stillInside):
            let lag = now - crossing.crossedAt
            if lag <= liveLagToleranceMs {
                return "\(memberName) arrived at \(placeName)"
            }
            if stillInside {
                let verb = isSelf ? "are" : "is"
                return "\(memberName) arrived at \(placeName) \(agoLabel(elapsedMs: lag)) and \(verb) still there"
            }
            return "\(memberName) arrived at \(placeName) \(agoLabel(elapsedMs: lag))"
        case let .departure(crossing):
            let lag = now - crossing.crossedAt
            if lag <= liveLagToleranceMs {
                return "\(memberName) left \(placeName)"
            }
            return "\(memberName) left \(placeName) \(agoLabel(elapsedMs: lag))"
        case let .passThrough(enter, exit):
            let from = clockLabel(enter.crossedAt, calendar: calendar)
            let to = clockLabel(exit.crossedAt, calendar: calendar)
            return "\(memberName) was at \(placeName), \(from)-\(to)"
        }
    }

    /// Notification title for a surfacing.
    static func title(for surfacing: Surfacing) -> String {
        switch surfacing {
        case .arrival: return "Arrival"
        case .departure: return "Departure"
        case .passThrough: return "Visit"
        }
    }

    private static func clockLabel(_ millis: Int64, calendar: Calendar) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

// MARK: - PlaceAlert adapters

extension PlaceAlert {
    /// Android stores two independent booleans; iOS stores a single `alertType`.
    /// Bridged here so the shared rule logic reads the same on both platforms.
    var alertsOnArrival: Bool { alertType == .arrival || alertType == .both }
    var alertsOnDeparture: Bool { alertType == .departure || alertType == .both }
}
