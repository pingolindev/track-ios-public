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
import UserNotifications

/// Subscriber-side place-alert evaluation.
///
/// The detector runs on the device that OWNS the alert, not on the mover's. That
/// device already receives and decrypts every circle member's location, so it can
/// evaluate them against its own private place with pure local geometry. Nothing
/// new is computed on or revealed to the server: no crossing is reported, no
/// circle-key hash is derived, no `place_shares` row and no wrapped place key are
/// required. A personal place therefore never has to be shared — and so never has
/// its name and coordinates made decryptable by every circle member — just to run
/// an alert on it.
///
/// Port of the Android app's `PlaceAlertEvaluator`.
///
/// ## Concurrency
///
/// `@MainActor`, and every decide-then-claim sequence is `await`-free so it runs
/// to completion without interleaving. Android needs two non-reentrant mutexes for
/// the same guarantee. See the header of `PlaceAlertLedger.swift` — an `await`
/// inside a critical section here would let two evaluations interleave and notify
/// twice for one crossing.
///
/// ## Fidelity note vs Android
///
/// Android feeds this from a Room `locations` table that holds batches (live poll,
/// history pages, own tracking). iOS has no location history table and
/// `CircleManager.loadMemberLocations` returns only the LATEST point per member,
/// so catch-up batches are thinner here: a member who entered and left entirely
/// between two refreshes is not observable at all, and no amount of local logic
/// can recover a point the device never received. The batch machinery
/// (`reconcile` walking oldest-to-newest, `passThrough` collapse) is ported intact
/// and correct; it simply has less to work with here.
@MainActor
final class PlaceAlertEvaluator {
    static let shared = PlaceAlertEvaluator()

    private init() {}

    /// A generic server push that has been SHOWN and may still be superseded by
    /// the richer local copy of the same crossing.
    ///
    /// Deliberately carries NO transition — that is the whole point. The push
    /// cannot know its own direction, so a marker that claimed one would let an
    /// enter and an exit share a notification id and silently replace each other.
    private struct ShownServerPush {
        let placeId: String
        let userId: String
        let shownAt: Int64
        /// The id the notification was posted under, so the local copy can reuse it.
        let notificationId: String
    }

    /// Markers awaiting supersession. In memory on purpose: the useful lifetime is
    /// one `crossPathDedupeWindowMs`, and losing them to process death degrades to
    /// one extra notification rather than to a swallowed alert. Persisting them
    /// would buy a rare duplicate at the cost of another table of cross-path state
    /// that can go stale.
    private var shownServerPushes: [ShownServerPush] = []

    /// Identifiers of server place-alert notifications currently sitting in the tray
    /// that a locally evaluated crossing may REPLACE.
    ///
    /// Refreshed immediately before each evaluation and consumed single-use, so one
    /// delivered push is superseded by exactly one crossing. Without the single-use
    /// rule, two crossings close together would reuse the same identifier and the
    /// second would silently overwrite the first — the user would see the later event
    /// and never learn about the earlier one.
    private var replaceableServerNotificationIds: [String] = []

    /// How recently a delivered server push must have arrived to be superseded.
    ///
    /// Both paths see the same crossing within seconds in the common case (a region
    /// crossing and the server's push race each other), so this only has to absorb a
    /// slow refresh. Kept short deliberately: the wider it is, the more likely an
    /// unrelated earlier notification gets replaced instead of the matching one.
    private static let replaceableWindow: TimeInterval = 5 * 60

    /// Snapshot the tray for server-delivered place alerts.
    ///
    /// This is why iOS needs no `place_id` in the push to de-duplicate. The push
    /// carries no identifiers to match, so we ask the system what it has already
    /// SHOWN and reuse that notification's identifier — iOS then replaces it in
    /// place, so the user's generic "Member arrived at a place" upgrades to "Sam
    /// arrived at Home" instead of being joined by it.
    ///
    /// Must be awaited BEFORE the critical section; see the file header.
    private func refreshReplaceableServerNotifications() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let cutoff = Date().addingTimeInterval(-Self.replaceableWindow)
        replaceableServerNotificationIds = delivered
            .filter { note in
                guard note.date >= cutoff else { return false }
                // Never supersede one of our OWN notifications: they already carry the
                // rich copy, and replacing one with another would lose a crossing.
                guard !note.request.identifier.hasPrefix("local-place:") else { return false }
                let info = note.request.content.userInfo
                let type = (info["type"] as? String) ?? (info["alert_type"] as? String) ?? ""
                return Self.serverPlaceAlertTypes.contains(type)
            }
            .sorted { $0.date < $1.date }
            .map(\.request.identifier)
    }

    /// Notification types the server emits for a place crossing. `place_alert` is the
    /// bare form the stored row carries; the directional pair are the push forms.
    private static let serverPlaceAlertTypes: Set<String> = [
        "place_alert_enter", "place_alert_exit", "place_alert",
    ]

    // MARK: - Entry point

    /// A decrypted location handed to the evaluator.
    ///
    /// Deliberately NOT `LocationData`: the device's own CoreLocation fix has no
    /// `LocationData` wrapper until it is synced to a circle, and the self case
    /// must be evaluated whether or not that sync ever happens — an alert on your
    /// own place works with no circle at all.
    struct Observation {
        let userId: String
        let latitude: Double
        let longitude: Double
        let timestamp: Date
        /// `allow_alerts_on_me` as the server reported it alongside this fix, or
        /// nil when unknown (which permits). See `PlaceAlertRules.alertWatches`.
        let allowAlertsOnMe: Bool?
        /// Reported accuracy of this fix, or nil when unknown. Carried so a fix too
        /// rough to say anything about a ring can be screened out — see
        /// `PlaceAlertRules.canResolve`. Defaulted to nil (= unknown = evaluate) so
        /// a caller with no accuracy to offer is always evaluated.
        let accuracyMeters: Double?

        init(
            userId: String,
            latitude: Double,
            longitude: Double,
            timestamp: Date,
            accuracyMeters: Double? = nil,
            allowAlertsOnMe: Bool? = nil
        ) {
            self.userId = userId
            self.latitude = latitude
            self.longitude = longitude
            self.timestamp = timestamp
            self.accuracyMeters = accuracyMeters
            self.allowAlertsOnMe = allowAlertsOnMe
        }
    }

    /// Evaluate freshly received decrypted member locations.
    ///
    /// `accuracy` rides through because a member sharing an approximate (bubble)
    /// location has theirs floored to the bubble cell by the sender, and that is
    /// the only signal a watcher has that the point it was handed is too coarse to
    /// judge a ring with. Dropping it here would let a snapped bubble point be
    /// tested against a true ring as though it were exact.
    func evaluate(locations: [LocationData]) async {
        await evaluate(Self.memberObservations(locations, me: AuthManager.shared.userId))
    }

    /// The server's rows this evaluator takes: never one naming this account,
    /// in any spelling. This account's own alerts come from this phone's own
    /// fixes alone (`evaluateOwn`, `surfaceOwnRegionCrossing`). With no
    /// account signed in, none.
    nonisolated static func memberObservations(_ locations: [LocationData], me: String?) -> [Observation] {
        guard CanonicalId.of(me) != nil else { return [] }
        return locations.filter { !CanonicalId.same($0.userId, me) }.map {
            Observation(
                userId: $0.userId,
                latitude: $0.latitude,
                longitude: $0.longitude,
                timestamp: $0.timestamp,
                accuracyMeters: $0.accuracy,
                allowAlertsOnMe: $0.allowAlertsOnMe
            )
        }
    }

    /// Evaluate this device's own fix, so "alert me when *I* arrive/leave" fires
    /// with no circle and no sharing. Silently no-ops when the session has no user
    /// id yet (pre-login fixes belong to nobody).
    ///
    /// DELIBERATELY passes no accuracy, which means UNKNOWN, which means evaluate.
    /// Self fixes are never coarsened — the bubble is applied per real circle
    /// before encryption and self is excluded — so there is no approximate-mode
    /// problem here, and screening them would silence a user's own alerts on a
    /// poor GPS fix with nothing on screen to say why.
    ///
    /// The Android app DOES screen its own fixes, but it also tells the user when
    /// that happens (`PlaceAlertEvaluator.noteCoarseFixes`). This app has no such
    /// notice, and screening without one would silence alerts with no
    /// explanation, so this is a deliberate divergence — see the parity note on
    /// `canResolve`.
    func evaluateOwn(latitude: Double, longitude: Double, timestamp: Date) async {
        guard let userId = AuthManager.shared.userId else { return }
        await evaluate([
            Observation(
                userId: userId,
                latitude: latitude,
                longitude: longitude,
                timestamp: timestamp
            )
        ])
    }

    /// Evaluate observations against every place this user holds an active alert
    /// on.
    ///
    /// Called for EVERY member location this device accepts, and for every fix of
    /// its own (`evaluateOwn`) — that is what makes the "alert me when *I*
    /// arrive/leave" case work with no circle and no sharing at all. Never for a
    /// server row naming this account (`memberObservations`).
    func evaluate(_ locations: [Observation]) async {
        guard !locations.isEmpty else { return }
        // Nothing to evaluate against: return before the hydrate below, whose
        // tray snapshot is an XPC round trip to the notification daemon. This is
        // reached on every accepted fix of our own and every member refresh, so
        // without this check a user with no place alerts would pay that call up
        // to ~180 times an hour while moving, for nothing. The same check is
        // repeated after the awaits, because the alert set can change while
        // they run.
        guard !PlaceManager.shared.placeAlerts.isEmpty else { return }

        // Hydrate BEFORE the critical section. Everything after the last `await`
        // in this function runs atomically on the main actor.
        await PlaceAlertMemberStateStore.shared.loadIfNeeded()
        await PlaceAlertEventLedger.shared.loadIfNeeded()
        await refreshReplaceableServerNotifications()

        let alertsByPlace = PlaceManager.shared.placeAlerts
        guard !alertsByPlace.isEmpty else { return }

        let now = PlaceAlertEventLedger.nowMs()
        let placesById = Dictionary(
            PlaceManager.shared.monitoredPlaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // One member's points for one place must be reconciled together and in
        // time order, so group before evaluating rather than walking row by row.
        let pointsByUser = Dictionary(grouping: locations, by: { $0.userId })

        for (placeId, placeAlerts) in alertsByPlace {
            guard let place = placesById[placeId] else { continue }
            let active = placeAlerts.filter { $0.isEnabled }
            guard !active.isEmpty else { continue }
            let geofence = geofence(for: place)

            for (userId, memberLocations) in pointsByUser {
                // Resolve circle membership ONCE per (member, alert-circle) and
                // pass it down: alertWatches is consulted again per decision, and
                // a roster scan per consultation would put work on the location
                // hot path.
                // Consent as the member's own latest fix reported it. These
                // observations all belong to one member and the flag rides on each
                // fix, so take the NEWEST non-nil value: a member who has just opted
                // out must not be judged on the strength of an older fix that
                // predates the change. nil (no fix said) leaves it unknown, which
                // permits.
                let latestConsent = memberLocations
                    .sorted { $0.timestamp < $1.timestamp }
                    .last { $0.allowAlertsOnMe != nil }?
                    .allowAlertsOnMe
                let watchedBy = active.filter { alert in
                    PlaceAlertRules.alertWatches(
                        alert,
                        userId: userId,
                        targetIsInAlertCircle: isMember(circleId: alert.circleId, userId: userId),
                        targetAllowsAlertsOnLatestFix: latestConsent
                    )
                }
                // Skip members no alert on this place watches, before any geometry.
                guard !watchedBy.isEmpty else { continue }

                evaluateMember(
                    geofence: geofence,
                    place: place,
                    alerts: watchedBy,
                    userId: userId,
                    locations: memberLocations,
                    now: now
                )
            }
        }
    }

    /// The alert fires on the place's effective geofence. iOS resolves that on the
    /// model already — `Place.radius` is documented as `boundary_radius` when a
    /// boundary is attached, else the marker radius — so unlike Android there is
    /// no precedence to re-apply here.
    private func geofence(for place: Place) -> PlaceAlertRules.PlaceGeofence {
        PlaceAlertRules.PlaceGeofence(
            placeId: place.id,
            latitude: place.latitude,
            longitude: place.longitude,
            radiusMeters: Int(place.radius.rounded())
        )
    }

    // MARK: - Own crossings detected by CoreLocation

    /// Surface a crossing that CoreLocation region monitoring already detected
    /// for THIS device.
    ///
    /// For the self case ("tell me when I get home") this is strictly better than
    /// per-fix evaluation on both axes at once:
    ///
    ///  - **Privacy**: the geofence is evaluated ON-DEVICE by the OS. Nothing is
    ///    reported, no push exists, and no third party — not the blind server,
    ///    not APNs — learns that a crossing happened at all. The place's
    ///    coordinates never leave the device even in pseudonymous form.
    ///  - **Reliability**: CoreLocation wakes even a terminated app, whereas the
    ///    location-driven path only runs when something refreshes member
    ///    locations. This is the one place where the private route is also the
    ///    more dependable one.
    ///
    /// Advancing the member state here is load-bearing, not bookkeeping: the
    /// location-driven path evaluates this device's own fixes too, and would
    /// otherwise re-detect the same physical crossing at a different timestamp.
    /// Because `ledgerId` embeds `crossedAt`, that would be a DIFFERENT ledger id
    /// and the user would get two notifications for one arrival. Flipping the
    /// state means the location path simply agrees and detects no transition —
    /// the state machine does the de-duplication, rather than a second window
    /// check that could swallow a genuine re-arrival.
    func surfaceOwnRegionCrossing(place: Place, isEnter: Bool, at: Date) async {
        guard let userId = AuthManager.shared.userId else { return }

        await PlaceAlertMemberStateStore.shared.loadIfNeeded()
        await PlaceAlertEventLedger.shared.loadIfNeeded()
        await refreshReplaceableServerNotifications()

        // Everything below this line is await-free; see the file header.
        let alerts = (PlaceManager.shared.placeAlerts[place.id] ?? []).filter { $0.isEnabled }
        let now = PlaceAlertEventLedger.nowMs()
        let crossedAt = Int64(at.timeIntervalSince1970 * 1000)

        // Advance state even when no alert wants this crossing, so the location
        // path stays consistent with what the OS observed.
        PlaceAlertMemberStateStore.shared.upsert(
            placeId: place.id,
            userId: userId,
            state: PlaceAlertRules.MemberPlaceState(isInside: isEnter, lastLocationAt: crossedAt)
        )
        guard !alerts.isEmpty else { return }

        let crossing = PlaceAlertRules.Crossing(
            placeId: place.id,
            userId: userId,
            transition: isEnter ? .enter : .exit,
            crossedAt: crossedAt
        )
        let surfacing: PlaceAlertRules.Surfacing = isEnter
            ? .arrival(crossing: crossing, stillInside: true)
            : .departure(crossing: crossing)
        let decision = PlaceAlertRules.Decision(
            surfacing: surfacing,
            silent: now - crossedAt > PlaceAlertRules.stalenessWindowMs
        )

        let wanting = alerts.filter { alert in
            PlaceAlertRules.alertWatches(
                alert,
                userId: userId,
                targetIsInAlertCircle: isMember(circleId: alert.circleId, userId: userId)
            )
                && PlaceAlertRules.isAlertLive(alert, at: crossedAt)
                && PlaceAlertRules.alertWants(alert, surfacing: surfacing)
                && PlaceAlertRules.isWithinSchedule(alert, at: crossedAt)
        }
        guard !wanting.isEmpty else { return }

        surface(
            place: place,
            userId: userId,
            memberName: displayName(for: userId),
            decision: decision,
            push: wanting.contains { $0.notifyPush },
            now: now
        )
    }

    // MARK: - Per-member reconciliation

    private func evaluateMember(
        geofence: PlaceAlertRules.PlaceGeofence,
        place: Place,
        alerts: [PlaceAlert],
        userId: String,
        locations: [Observation],
        now: Int64
    ) {
        let points = locations.map {
            PlaceAlertRules.Point(
                latitude: $0.latitude,
                longitude: $0.longitude,
                timestamp: Int64($0.timestamp.timeIntervalSince1970 * 1000),
                accuracyMeters: $0.accuracyMeters
            )
        }

        // Drop fixes too rough to say anything about THIS ring, before the geometry
        // rather than after it: a point that cannot resolve the ring must not
        // advance the member's state either, or a later usable fix would be judged
        // against a position we never believed. Filtering here (not inside
        // `reconcile`) is what keeps the `lastLocationAt` watermark advancing only
        // over points actually used — same placement as the Android app's
        // `PlaceAlertEvaluator`.
        let usable = points.filter {
            PlaceAlertRules.canResolve(geofence: geofence, accuracyMeters: $0.accuracyMeters)
        }
        guard !usable.isEmpty else { return }

        let prior = PlaceAlertMemberStateStore.shared.state(placeId: geofence.placeId, userId: userId)
        guard let reconciliation = PlaceAlertRules.reconcile(
            geofence: geofence,
            userId: userId,
            prior: prior,
            points: usable
        ) else {
            return // every point was at or before the watermark — nothing new
        }

        // Persist the advanced state FIRST. A crash between here and the
        // notification costs at most one missed alert; the other order would
        // re-drive the same transitions on the next batch.
        PlaceAlertMemberStateStore.shared.upsert(
            placeId: geofence.placeId,
            userId: userId,
            state: reconciliation.state
        )
        guard !reconciliation.crossings.isEmpty else { return }

        let decisions = PlaceAlertRules.classify(
            crossings: reconciliation.crossings,
            finalInside: reconciliation.state.isInside,
            now: now
        )
        let memberName = displayName(for: userId)

        for decision in decisions {
            // `alerts` is already scoped to those watching this member, so the
            // remaining tests are liveness, direction and schedule.
            let wanting = alerts.filter { alert in
                PlaceAlertRules.isAlertLive(alert, at: decision.surfacing.at)
                    && PlaceAlertRules.alertWants(alert, surfacing: decision.surfacing)
                    && PlaceAlertRules.isWithinSchedule(alert, at: decision.surfacing.at)
            }
            guard !wanting.isEmpty else { continue }

            // A crossing no alert wants a PUSH for (schedule matched but every
            // matching alert has notifyPush off) still gets a ledger row and a
            // bell entry — it just never reaches the notification centre.
            let push = wanting.contains { $0.notifyPush }
            surface(
                place: place,
                userId: userId,
                memberName: memberName,
                decision: decision,
                push: push,
                now: now
            )
        }
    }

    // MARK: - Surfacing

    /// Claim the crossing in the ledger and, if this device is the first path to
    /// see it, show it. Rule 4: a given crossing surfaces at most once, EVER.
    private func surface(
        place: Place,
        userId: String,
        memberName: String,
        decision: PlaceAlertRules.Decision,
        push: Bool,
        now: Int64
    ) {
        let surfacing = decision.surfacing
        let body = PlaceAlertRules.describe(
            surfacing: surfacing,
            memberName: memberName,
            placeName: place.name,
            now: now,
            isSelf: userId == AuthManager.shared.userId
        )
        // The banner's redacted variant. The FULL copy still goes to the ledger
        // below: the bell list sits behind the app lock and always shows
        // everything, exactly as it does on Android.
        let namesOnlyBody = PlaceAlertRules.describeNamesOnly(
            surfacing: surfacing,
            memberName: memberName,
            now: now,
            isSelf: userId == AuthManager.shared.userId
        )
        let title = PlaceAlertRules.title(for: surfacing)

        // Cross-path guard: a place that IS shared to a circle can still produce a
        // server-routed push for the same crossing. If that push already landed,
        // drop ours — whichever path is second loses. Checked for EVERY crossing
        // the decision covers: a collapsed pass-through would otherwise still
        // duplicate a server push for its enter half. A silent decision raises no
        // push, so it cannot double-notify.
        //
        // Only a SERVER row may suppress us. Our own earlier rows must not: an
        // enter shortly after a previous enter is a real second arrival, and
        // matching it against our own history is how a user who left and came back
        // loses their alert entirely. Re-surfacing the exact SAME crossing is
        // prevented by the ledger id, not here.
        if !decision.silent {
            let clash = surfacing.crossings.contains { crossing in
                PlaceAlertEventLedger.shared.alreadySurfacedNearby(
                    placeId: place.id,
                    userId: userId,
                    transition: crossing.transition.wire,
                    source: .server,
                    crossedAt: crossing.crossedAt
                )
            }
            if clash { return }
        }

        // Claim EVERY crossing this decision accounts for (a collapsed
        // pass-through covers two), so neither half can resurface later. Only the
        // first carries the copy — the pair is ONE bell entry, not two.
        var claimedFirst = false
        for (index, crossing) in surfacing.crossings.enumerated() {
            let inserted = PlaceAlertEventLedger.shared.claim(
                crossing: crossing,
                surfacedAt: now,
                source: .local,
                silent: decision.silent,
                title: index == 0 ? title : nil,
                body: index == 0 ? body : nil
            )
            if inserted { claimedFirst = true }
        }
        guard claimedFirst else { return }

        // Silent decisions are recorded and shown in the bell, but raise no push:
        // otherwise a phone that was off all weekend reconnects and dumps a pile
        // of ancient pings.
        guard !decision.silent, push else { return }

        // If a generic server push for this same crossing is already showing, take
        // its notification id so this richer copy REPLACES it rather than stacking
        // beside it. Consumed, so it can supersede only this one crossing.
        let localId = surfacing.crossings[0].ledgerId
        // Prefer an id from the in-memory marker list (set by claimServerCrossing,
        // which has no caller on iOS). Failing that, take one the SYSTEM reports as
        // delivered — which is what catches the real case, since a backgrounded APNs
        // alert is shown by iOS without this process ever seeing it. Consumed either
        // way, so one delivered push is superseded by exactly one crossing.
        let notificationId = takeSupersededServerPushId(
            placeId: place.id,
            userId: userId,
            at: surfacing.at
        )
            ?? (replaceableServerNotificationIds.isEmpty
                ? nil
                : replaceableServerNotificationIds.removeFirst())
            ?? "local-place:\(localId)"

        postNotification(
            id: notificationId,
            title: title,
            body: body,
            namesOnlyBody: namesOnlyBody,
            placeId: place.id,
            // WHEN THE CROSSING HAPPENED, not when this device noticed it.
            // surfacing.at is crossedAt, off the member's own location points.
            occurredAt: Date(timeIntervalSince1970: TimeInterval(surfacing.at) / 1000)
        )
    }

    private func postNotification(
        id: String,
        title: String,
        body: String,
        namesOnlyBody: String,
        placeId: String,
        occurredAt: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        // Stamped here rather than in PlaceAlertRules.describe, which also feeds
        // the in-app bell list — that list already renders its own timestamps, so
        // stamping the shared copy would show the time twice there.
        //
        // Stamped with the CROSSING time, not now: this path also replays another
        // member's shared location batch and only silences crossings older than
        // stalenessWindowMs (2h), so a crossing may be up to two hours old, and
        // the body must not claim it just happened.
        // Redact FIRST, stamp second — the order NotificationStamp's own doc
        // comment specifies, and the order that lets the time survive redaction.
        //
        // Redacting here makes these banners follow the user's chosen detail
        // level, as every other notification this app posts does
        // (MonitoringManager, DestinationsManager, PushNotificationManager all
        // call resolveBody), and as all three levels do on Android: without it,
        // the full "Sam arrived at Home" would reach the lock screen whatever
        // level the user chose. Titles stay unredacted by design — "Arrival"
        // names no one.
        content.body = NotificationStamp.appended(
            to: NotificationDetailLevel.resolveBody(detailed: body, namesOnly: namesOnlyBody),
            at: occurredAt
        )
        content.sound = .default
        content.userInfo = ["place_id": placeId, "local_evaluated": "true"]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Track] place-alert local notification failed: \(error)")
            }
        }
    }

    // MARK: - Server-push interop

    /// Claim a SERVER-routed place crossing before it is shown.
    ///
    /// Returns true when this push is the first path to surface the crossing and
    /// should be displayed, false when the local evaluator already showed it. The
    /// ledger row it writes also stops the local evaluator from re-showing the
    /// same crossing if it evaluates the matching location afterwards — so the
    /// guard holds in EITHER arrival order.
    ///
    /// A push we can't identify (no place id, or no member id) is always shown:
    /// dropping an unidentifiable alert would be worse than a rare duplicate.
    ///
    /// ## No caller on iOS — and why
    ///
    /// Android calls its equivalent from `AlertHandler.handlePlaceCrossing`,
    /// because an FCM data message carries the whole `data` map and the client
    /// builds the notification itself. iOS cannot do this:
    ///
    ///  - The APNs payload carries only routing keys (alert_type, alert_id,
    ///    circle_id, destination_id, arrived_user_id, route_id). `place_id` and
    ///    `crossing_user_id` are not among them, so an arriving place push cannot
    ///    say which place or which member it is about — there is nothing to
    ///    match a local crossing against. (The bell row does carry them, but
    ///    that is a separate API read, not the push.)
    ///  - Even identified, a backgrounded alert-style APNs push is rendered by
    ///    iOS itself; the app is never asked and cannot suppress it. Only
    ///    foreground `willPresent` is interceptable.
    ///
    /// Scope note: this does NOT affect the case local evaluation exists for. A
    /// server-routed push for a personal place only exists when the place is
    /// SHARED to a circle. An unshared personal place produces no server push at
    /// all, so local evaluation is the only path and there is nothing to
    /// duplicate. Duplicates are possible only for places shared to a circle.
    func claimServerCrossing(
        placeId: String?,
        userId: String?,
        isArrival: Bool,
        notificationId: String?
    ) async -> Bool {
        guard let placeId, !placeId.isEmpty, let userId, !userId.isEmpty else { return true }
        await PlaceAlertEventLedger.shared.loadIfNeeded()

        let transition: PlaceAlertRules.Transition = isArrival ? .enter : .exit
        let now = PlaceAlertEventLedger.nowMs()

        // Mirror of the local path: only a LOCAL row may suppress a push.
        if PlaceAlertEventLedger.shared.alreadySurfacedNearby(
            placeId: placeId,
            userId: userId,
            transition: transition.wire,
            source: .local,
            crossedAt: now
        ) {
            return false
        }

        // The push has no crossing time, so the claim is stamped with arrival
        // time. The window check above — not this id — is what de-duplicates it
        // against the local path.
        let crossing = PlaceAlertRules.Crossing(
            placeId: placeId,
            userId: userId,
            transition: transition,
            crossedAt: now
        )
        _ = PlaceAlertEventLedger.shared.claim(
            crossing: crossing,
            surfacedAt: now,
            source: .server,
            silent: false
        )
        if let notificationId {
            shownServerPushes.append(
                ShownServerPush(
                    placeId: placeId,
                    userId: userId,
                    shownAt: now,
                    notificationId: notificationId
                )
            )
        }
        return true
    }

    /// Consume a marker for a server push still showing for this (place, member),
    /// so the local copy can replace it in place instead of stacking beside it.
    ///
    /// The match is ASYMMETRIC, and that is the point: a marker reaches BACKWARD by
    /// `serverPushSupersedeWindowMs` — far enough to cover the mover's upload lag
    /// and the wait for this device to evaluate — but forward by no more than clock
    /// skew, because a crossing later than the push is a different crossing.
    ///
    /// Only `claimServerCrossing` adds markers to `shownServerPushes`, and it has
    /// no caller on iOS; the delivered-notification snapshot is what catches the
    /// real case.
    private func takeSupersededServerPushId(placeId: String, userId: String, at: Int64) -> String? {
        // Drop markers that can no longer be superseded while we are here.
        shownServerPushes.removeAll { at - $0.shownAt > PlaceAlertRules.serverPushSupersedeWindowMs }
        guard let index = shownServerPushes.firstIndex(where: {
            $0.placeId == placeId && $0.userId == userId
                && at >= $0.shownAt - PlaceAlertRules.serverPushSupersedeWindowMs
                && at <= $0.shownAt + PlaceAlertRules.serverPushSupersedeSkewMs
        }) else { return nil }
        let marker = shownServerPushes[index]
        shownServerPushes.remove(at: index)
        return marker.notificationId
    }

    // MARK: - Lookups

    /// Is `userId` a member of `circleId`? Used to scope a CIRCLE-WIDE alert to
    /// the circle it is homed to.
    ///
    /// Returns `nil` for UNKNOWN, which `alertWatches` treats as "do not scope".
    /// An EMPTY local roster means we never synced this circle's members, not that
    /// it has none — treating that as "not a member" would make a correctly
    /// configured alert silently never fire, which the user cannot tell apart from
    /// the feature being broken.
    private func isMember(circleId: String?, userId: String) -> Bool? {
        guard let circle = circleId?.trimmingCharacters(in: .whitespaces), !circle.isEmpty else {
            return nil
        }
        // The self sentinel is not a circle and has no roster to ask about — an
        // alert homed to it is circle-less by definition.
        if circle == SelfKeyManager.selfCircleUuid { return nil }
        guard let roster = CircleManager.shared.members[circle], !roster.isEmpty else { return nil }
        return roster.contains { $0.userId == userId }
    }

    private func displayName(for userId: String) -> String {
        if userId == AuthManager.shared.userId { return "You" }
        for (_, roster) in CircleManager.shared.members {
            if let member = roster.first(where: { $0.userId == userId }) {
                return member.displayName
            }
        }
        return "A member"
    }
}
