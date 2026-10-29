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
import UIKit
import UserNotifications

/// Own-battery reporting and the client-side evaluation of watch-a-member
/// battery and inactivity rules (E2EE compliant - client-side only).
///
/// There is no global on/off here: both alert kinds are governed in the
/// circle's permissions — `share_battery` (the per-circle "Share Battery
/// Level" consent, which also gates the wake in `wakeBatteryWatchers`) and
/// `allow_alerts_on_me` — which is the only place the Android app has them
/// too.
@MainActor
final class MonitoringManager: ObservableObject {
    static let shared = MonitoringManager()

    // MARK: - Published State

    @Published private(set) var batteryAlertsSent: [String: Date] = [:] // circleId -> lastSent

    // MARK: - Configuration

    struct Config {
        var batteryThreshold: Int = 15 // Percentage
        var inactivityThreshold: TimeInterval = 3600 // 1 hour
        var checkInterval: TimeInterval = 300 // 5 minutes
    }

    var config = Config()

    /// The highest battery threshold a rule can be set to, across clients: the
    /// web slider stops at 50 and the Android seekbar at 5 + 45. Above this no
    /// rule can be firing, which is what makes it both the point to start
    /// reporting from and the point to report a recovery at.
    private static let maxWatchableThreshold = 50
    /// The retired master switch's key. Cleared on start so a device that once
    /// turned it off does not carry a dead preference around.
    private static let retiredBatterySwitchKey = "monitoring.batteryEnabled"
    /// Report each further fall of this many points. Matches the step every
    /// client's threshold picker moves in, so no rule sits more than one step
    /// below the last reported level.
    private static let batteryReportStep = 5

    /// Last own-battery level we asked the server to wake watchers at; nil when
    /// we are above every watchable threshold. In memory only — a relaunch
    /// costs at most one extra wake, whereas persisting it would risk the
    /// opposite failure, a phone that never reports because it remembers
    /// having already done so.
    private var lastReportedBatteryLevel: Int?
    /// NotificationCenter tokens for the battery observers, so
    /// stopBatteryMonitoring can take them down and a restart cannot stack a
    /// second set on top.
    private var batteryObservers: [NSObjectProtocol] = []

    // MARK: - Dependencies

    private let api = APIService.shared
    private let locationService = LocationService.shared

    /// `locationService.locationUpdates` sink from startInactivityWatch.
    /// Cancelled in `reset()` because it re-subscribes after a logout (reset
    /// flips watchStarted back to false), so without this a duplicate sink
    /// would stack up per account switch.
    private var inactivityCancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Battery Monitoring

    /// Watch our own battery so the people who asked to be told can be told.
    ///
    /// The server cannot raise low-battery alerts itself: the level is inside
    /// the encrypted location payload and it holds no key for it. The emission
    /// path is: notice our own level fall, ask the server to wake the watchers
    /// in each circle we share battery with, and tell it nothing else. Readings
    /// arrive from two places — this observer while the app is alive, and
    /// `noteOwnBattery` from the location paths that already read the level to
    /// put it in the payload, which is what covers background wake-ups. Started
    /// for everyone at launch; per-circle consent is the only control, as on
    /// Android.
    func startBatteryMonitoring() {
        UserDefaults.standard.removeObject(forKey: Self.retiredBatterySwitchKey)
        UIDevice.current.isBatteryMonitoringEnabled = true

        guard batteryObservers.isEmpty else { return }
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in await MonitoringManager.shared.readOwnBattery() }
            }
            batteryObservers.append(token)
        }
        Task { await readOwnBattery() }
    }

    func stopBatteryMonitoring() {
        batteryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        batteryObservers.removeAll()
    }

    /// Take a reading from the device and hand it to [noteOwnBattery].
    private func readOwnBattery() async {
        guard let level = locationService.getBatteryLevel() else { return }
        await noteOwnBattery(level: level, isCharging: locationService.isCharging())
    }

    /// Feed in a battery reading and wake the watchers if it has fallen far
    /// enough to be worth someone looking.
    ///
    /// Called by the location paths as well as the observer above, because they
    /// already read the level to seal into the payload and they run on
    /// background wake-ups, where an in-app observer does not.
    ///
    /// The ladder is a compromise forced by the privacy shape, and worth
    /// spelling out. This device cannot know anyone's threshold — that is the
    /// disclosure the design avoids — so it cannot wake exactly when someone's
    /// rule would fire. It instead reports each further 5-point fall below the
    /// highest threshold anyone can set, so any watcher is woken within one
    /// step of their own line. Watchers also evaluate on their own periodic
    /// pass, so a missed step is late rather than lost.
    func noteOwnBattery(level: Int, isCharging: Bool) async {
        // Back above every threshold anybody could have set: nobody's rule can
        // still be firing, so wake them once to clear it and re-arm. Charging
        // alone is not enough — a phone charging at 4% is still flat.
        if level > Self.maxWatchableThreshold {
            if lastReportedBatteryLevel != nil {
                lastReportedBatteryLevel = nil
                await wakeBatteryWatchers()
            }
            return
        }

        // Charging and climbing is somebody else's problem; don't spend a wake
        // on a phone that is visibly recovering.
        if isCharging { return }

        if let last = lastReportedBatteryLevel, level > last - Self.batteryReportStep { return }
        lastReportedBatteryLevel = level
        await wakeBatteryWatchers()
    }

    /// Ask the server to wake the watchers, once per circle we actually share
    /// battery with.
    ///
    /// Circles where `share_battery` is off are skipped: the level was stripped
    /// from the payload for them (SDKLocationStreamer does that on the way out),
    /// so nobody there can evaluate anything and the wake would be pure cost.
    /// One call per circle rather than one carrying a list, because a list of
    /// circle ids in a single request is a statement that one person is in all
    /// of them.
    private func wakeBatteryWatchers() async {
        let circleManager = CircleManager.shared
        for circle in circleManager.circles {
            if await circleManager.mayShareBattery(with: circle.id) == false { continue }
            do {
                _ = try await api.wakeWatchers(circleId: circle.id)
            } catch {
                // 429 is an ordinary answer, not a failure to chase: the
                // watchers were woken recently enough that another wake would
                // tell them nothing new.
                print("[Track] wake-watchers failed: \(error)")
            }
        }
    }

    // MARK: - Watched-member inactivity firing (client-only rules)

    // Self-inactivity alerts are emitted server-side (InactivityAlertsManager
    // creates server-eval rows); there is no client emission path for them and
    // no switch. The LIVE watched-member firing is startInactivityWatch().

    // Fire-once + dedup state lives in LocalInactivityStore (persisted),
    // so a process restart can't re-fire an open lapse.
    private var watchEvalTimer: Timer?
    private var lastWatchEvalAt: Date?
    /// When the timer last ran a full pass; the Battery Saver stretch reads it.
    private var lastTimerPassAt: Date?
    /// Min spacing between full evaluations triggered by location wakeups
    /// (the 15-min timer and foreground entry bypass this).
    private static let watchEvalMinInterval: TimeInterval = 600

    /// The timer's period. Every resident client runs it around the clock — the
    /// location request keeps the process alive — so each tick is a wake of its
    /// own, unrelated to the phase of any location send.
    nonisolated static var evaluationTimerInterval: TimeInterval { 900 }
    /// Let iOS fire the timer up to this late, so it can share a wake the
    /// system was making anyway instead of forcing one on the dot.
    nonisolated static var evaluationTimerTolerance: TimeInterval { 90 }
    /// How long a fetched rule list (our inactivity alerts, our battery rules,
    /// the circle-mates' "watch me" requests) is reused by the BACKGROUND pass.
    /// These change when someone edits a rule, which is rare, and every path
    /// that knows about an edit renews them sooner: our own create/update/delete
    /// refresh the list, the Alerts screen refreshes on appear, an
    /// `alerts_check` push and a return to the foreground invalidate. Without
    /// this the pass would fetch all of them every 15 minutes, rules or not.
    nonisolated static var ruleListMaxAge: TimeInterval { 3600 }

    /// Whether a timer tick should run the pass. Battery Saver stretches the
    /// pass to every other tick (30 min): the user there has already accepted
    /// 15-minute check-ins, and at that cadence this pass would double the
    /// scheduled radio wakes. Slack absorbs the timer's tolerance.
    nonisolated static func timerPassIsDue(lastPassAt: Date?, now: Date, batterySaver: Bool) -> Bool {
        guard batterySaver, let last = lastPassAt else { return true }
        let interval = evaluationTimerInterval * 2
        let slack = evaluationTimerTolerance + 30
        return now.timeIntervalSince(last) >= interval - slack
    }

    // MARK: Per-pass location cache
    //
    // Every evaluator on a pass needs the same thing — the latest locations of
    // the circles its rules live in. Within a pass each circle is fetched once
    // and the result shared, so a circle with rules in several families is
    // not fetched (or fed to the place-alert evaluator) once per family.
    // Nested and overlapping passes share one cache; it is dropped when the
    // last ends.
    private var passDepth = 0
    private var passRefreshes: [String: CircleManager.MemberLocationRefresh] = [:]
    private var passFailedCircles: Set<String> = []

    private struct PassFetchFailed: Error {}

    private func runPass(_ body: () async -> Void) async {
        passDepth += 1
        defer {
            passDepth -= 1
            if passDepth == 0 {
                passRefreshes = [:]
                passFailedCircles = []
            }
        }
        await body()
    }

    /// One circle's latest locations, fetched at most once per pass. Always
    /// `surfaceFailures: false` — every caller here runs in the background.
    private func memberRefresh(for circleId: String) async throws -> CircleManager.MemberLocationRefresh {
        if passDepth > 0 {
            if let hit = passRefreshes[circleId] { return hit }
            if passFailedCircles.contains(circleId) { throw PassFetchFailed() }
        }
        do {
            let refresh = try await CircleManager.shared.loadMemberLocations(for: circleId, surfaceFailures: false)
            if passDepth > 0 { passRefreshes[circleId] = refresh }
            return refresh
        } catch {
            if passDepth > 0 { passFailedCircles.insert(circleId) }
            throw error
        }
    }

    /// Make every rule list go back to the server on its next use.
    func invalidateRuleLists() {
        InactivityAlertsManager.shared.invalidate()
        AlertRulesManager.shared.invalidate()
        circleSelfAlertsFetchedAt = nil
    }

    /// A return to the foreground: rules may have been edited on another device.
    func noteForeground() {
        invalidateRuleLists()
    }

    /// The `alerts_check` push: the server noticed a silence and is asking this
    /// device to look. Fresh lists, then one pass across the three families.
    func evaluateForAlertsCheck() async {
        invalidateRuleLists()
        await runPass {
            await evaluateInactivityAlerts()
            await evaluateCircleSelfAlerts()
            await evaluateBatteryAlerts()
        }
    }

    /// Start evaluating client-only inactivity rules that watch OTHER
    /// members. The server can't read their watcher set (it's E2EE in
    /// encrypted_conditions, so the rule is client_only), so the client
    /// fires them. Runs on a 15-min timer plus opportunistically on
    /// background location wakeups. Mirrors the Android app's foreground-
    /// service evaluation loop within iOS execution limits:
    /// guaranteed while the app is active, best-effort in the background.
    private var watchStarted = false

    func startInactivityWatch() {
        guard !watchStarted else { return }   // idempotent — don't double-subscribe
        watchStarted = true
        let timer = Timer.scheduledTimer(withTimeInterval: Self.evaluationTimerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.timerTick() }
        }
        timer.tolerance = Self.evaluationTimerTolerance
        watchEvalTimer = timer
        // Opportunistic background coverage: the app already receives
        // location updates with Always permission; piggyback a throttled
        // evaluation (cached rule list) so a watched member's lapse
        // surfaces without waiting for the next 15-min tick.
        locationService.locationUpdates
            .sink { [weak self] _ in
                Task { @MainActor in await self?.evaluateInactivityAlertsThrottled() }
            }
            .store(in: &inactivityCancellables)
        Task { await refreshAndEvaluate() }
    }

    func stopInactivityWatch() {
        watchEvalTimer?.invalidate()
        watchEvalTimer = nil
        watchStarted = false
    }

    private func timerTick() async {
        let now = Date()
        guard Self.timerPassIsDue(
            lastPassAt: lastTimerPassAt, now: now,
            batterySaver: UserSettings.shared.batterySaverEnabled
        ) else { return }
        lastTimerPassAt = now
        await refreshAndEvaluate()
    }

    /// Timer / launch path. Each evaluator re-syncs its own rule list when it is
    /// older than `ruleListMaxAge` (picking up rules added or removed on other
    /// devices), and returns before any member fetch when it has no rules — so
    /// a user with no rules at all costs this pass nothing on the network
    /// between hourly list refreshes.
    private func refreshAndEvaluate() async {
        await runPass { await refreshAndEvaluatePass() }
    }

    private func refreshAndEvaluatePass() async {
        await evaluateInactivityAlerts()
        await evaluateCircleSelfAlerts()
        // Place alerts ride the same pass. Inactivity, circle-self and battery all
        // evaluate here off the background location residency this loop exists to
        // exploit; left to `BGAppRefresh` alone (hourly floor, "typically after
        // ~24h", active circle only), a member arriving at a watcher's UNSHARED
        // place could go unnoticed for hours.
        //
        // The Android app does the same: `runBackgroundEvaluationPass` puts
        // `placeAlertCircles` in its fetch union.
        await refreshPlaceAlertCircles()
        // Battery rides the same pass. The wake-up push is the timely path;
        // this is what still catches a drain when the wake-up was dropped,
        // throttled, or never sent because the watched phone died before it
        // could ask.
        await evaluateBatteryAlerts()
    }

    /// Fetch member locations for every circle carrying an active place alert on
    /// somebody else, which is all place alerts need from this loop: the fetch IS
    /// the evaluation. `CircleManager.loadMemberLocations` feeds every accepted
    /// location to `PlaceAlertEvaluator` (after the replay guard), so there is no
    /// second call to make here and adding one would double-evaluate.
    ///
    /// Deliberately skips self-targeted alerts. Those need nobody else's location —
    /// own fixes reach the evaluator through `CircleManager`'s own-location hook and
    /// through OS region monitoring — so fetching for them would be a request per
    /// tick that changes nothing.
    ///
    /// `surfaceFailures: false` is load-bearing. The default is `true`, which paints
    /// the "Couldn't reach server" banner, and this pass runs in the BACKGROUND: a
    /// failure here must not leave "Couldn't reach server" sitting on the user's map.
    /// The wake-path entry point.
    ///
    /// A watcher who does not share their own location has NO background location
    /// residency — `wakeForBackgroundLocationDelivery` is gated on background
    /// permission — so the 900 s timer and the `locationUpdates` sink both give them
    /// nothing, and place alerts on somebody else's movement would never evaluate
    /// between app opens.
    ///
    /// They do not need a new push. The server already wakes stale devices
    /// (`wake_location`), and a pure watcher is stale BY DEFINITION because they
    /// never upload. Staleness there is measured in whole days, so this covers a
    /// pure watcher roughly daily, not every 15 minutes. The same wake also runs
    /// `sendCurrentLocation`; this is the other half of the work it can do, at no
    /// additional cost to anyone's battery and with nothing new disclosed to the
    /// server.
    func refreshPlaceAlertsOnWake() async {
        await runPass { await refreshPlaceAlertCircles() }
    }

    private func refreshPlaceAlertCircles() async {
        let selfId = AuthManager.shared.userId
        let circleIds = Set(
            PlaceManager.shared.placeAlerts.values
                .flatMap { $0 }
                .filter { alert in
                    guard alert.isEnabled else { return false }
                    // A "Just me" alert carries no routing circle at all.
                    guard let circleId = alert.circleId, !circleId.isEmpty else { return false }
                    // Self-targeted: no member fetch required.
                    if let target = alert.targetUserId, target == selfId { return false }
                    return true
                }
                .compactMap { $0.circleId }
        )
        guard !circleIds.isEmpty else { return }

        for circleId in circleIds {
            // A failed fetch contributes no locations and is not an error worth
            // surfacing: the evaluator's per-member watermark means the next pass
            // picks up where this one left off. Shared with the other evaluators
            // on this pass, so a circle they already fetched costs nothing here.
            _ = try? await memberRefresh(for: circleId)
        }
    }

    private func evaluateInactivityAlertsThrottled() async {
        if let last = lastWatchEvalAt,
           Date().timeIntervalSince(last) < Self.watchEvalMinInterval { return }
        await runPass { await evaluateInactivityAlertsThrottledPass() }
    }

    private func evaluateInactivityAlertsThrottledPass() async {
        await evaluateInactivityAlerts()
        // The location-wake half of the pass, and the more valuable half for place
        // alerts: this fires while the user is MOVING, which is when a watched
        // member's crossing is worth hearing about promptly. The 900 s timer is the
        // floor, not the mechanism.
        //
        // `lastWatchEvalAt` is set by evaluateInactivityAlerts above, so both
        // families share one throttle and a tick cannot fetch twice.
        await refreshPlaceAlertCircles()
    }

    /// Evaluate every active client-only "watch others" inactivity rule and
    /// fire a local notification for each watched member who's been silent
    /// past the rule's timeout. Per-circle "healthy" gate (a successful,
    /// decryptable location refresh) prevents a connectivity/key gap from
    /// reading as "everyone went silent"; a never-seen member is skipped.
    func evaluateInactivityAlerts() async {
        lastWatchEvalAt = Date()
        let inactivity = InactivityAlertsManager.shared
        let store = LocalInactivityStore.shared
        await store.loadIfNeeded()
        await inactivity.refreshIfStale(maxAge: Self.ruleListMaxAge)

        // EVERY active watch-someone-else rule, not just the ones carrying an
        // encrypted watcher spec. The server applies no threshold and resolves
        // no target — it only notices silence and wakes us — so a rule skipped
        // here is a rule nothing fires. Rules without a spec watch their
        // single encrypted target; watchSpec falls back to it.
        let rules = inactivity.alerts.filter { $0.isActive && !$0.isSelfAlert }
        guard !rules.isEmpty else { return }   // nothing client-side to fire

        let now = Date()
        let selfId = AuthManager.shared.userId
        let circleManager = CircleManager.shared

        for circleId in Set(rules.map { $0.circleId }) {
            // Healthy gate, two tiers.
            //
            // A throw (network / whole-request failure) skips the circle. But a
            // throw is not enough: `loadMemberLocations` throws only when the
            // FETCH fails, and a per-member decrypt failure never throws — it
            // drops that member's row and returns normally. The member then keeps
            // their PREVIOUS entry in `memberLocations`, which is a cache and not
            // a snapshot, and their ageing timestamp reads as silence. So a key
            // gap could raise "this person may need attention" about someone
            // whose phone was reporting perfectly well.
            //
            // Tier 1 (circle): a refresh that failed to open any row cannot
            // distinguish "went quiet" from "we could not read it", so it judges
            // nobody. Same rule as the Android app's AlertsCheckWorker.
            let refresh: CircleManager.MemberLocationRefresh
            // `surfaceFailures: false`: this evaluator runs in the BACKGROUND, off
            // the 900 s timer and off location wakes, so the parameter's default of
            // `true` could paint "Couldn't reach server" onto the map of a user who
            // did not ask for anything. The banner belongs to interactions a user
            // initiated; the `catch` below is all this evaluator needs.
            do { refresh = try await memberRefresh(for: circleId) }
            catch { continue }
            guard refresh.isComplete else { continue }
            let members = circleManager.members[circleId] ?? []

            for rule in rules where rule.circleId == circleId {
                // Decode the watcher spec; an undecodable spec (key gap)
                // skips the rule rather than guessing "everyone".
                guard let spec = inactivity.watchSpec(for: rule) else { continue }
                let watched: [CircleMember]
                if spec == "all" || spec.isEmpty {
                    watched = members.filter { $0.userId != selfId }
                } else {
                    let set = Set(spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    watched = members.filter { set.contains($0.userId) }
                }
                guard !watched.isEmpty else { continue }

                let timeoutSec = Double(rule.timeoutHours) * 3600
                for member in watched {
                    // Paused, or real-time sharing off, in this circle: nothing
                    // goes off about them, whatever position this phone last
                    // had. The roster says so before a refresh does. When that
                    // stretch ended counts as activity (as the server counts
                    // it): this phone notes when it saw them off.
                    let sharing = member.sharing(at: now)
                    if sharing != .on {
                        store.noteNotSharing(circleId: circleId, userId: member.userId, status: sharing, now: now)
                        continue
                    }
                    store.noteSharing(circleId: circleId, userId: member.userId, now: now)
                    // Tier 2 (per member): judge only members THIS refresh
                    // produced a location for.
                    //
                    // A member absent from the response is paused, has never
                    // shared, or was filtered server-side for some other privacy
                    // reason — and in every one of those the correct action is
                    // the same: say nothing. Pausing sharing is the control a
                    // person reaches for when they do not want their whereabouts
                    // known; without this line, pausing would cause their circle
                    // to be told they may need attention, from the last position
                    // they had shared before pausing.
                    guard CircleManager.shouldJudge(member.userId, from: refresh) else { continue }
                    // CONSENT (`allow_alerts_on_me`). The member's own latest fix
                    // carries their posture for this circle; an explicit false
                    // withdraws consent to being alerted about, so say nothing.
                    // nil (the backend did not report it) permits, as at every
                    // consent gate — most members have no privacy row at all.
                    // THIS circle's row of them, never another circle's: consent,
                    // battery and time are each circle's own (`CircleRowMemory`).
                    let circleRow = circleManager.acceptedRow(of: member.userId, in: circleId)
                    if circleRow?.allowAlertsOnMe == false { continue }
                    // Never seen this member's location → can't judge fairly.
                    guard let lastSeen = circleRow?.timestamp else { continue }
                    let silentFor = now.timeIntervalSince(LocalInactivityStore.activeSince(
                        lastSeen: lastSeen,
                        notSharingSeen: store.notSharingSeen(circleId: circleId, userId: member.userId), now: now))
                    if silentFor > timeoutSec {
                        // Fire ONCE per lapse: the open (unresolved) event is
                        // the "already fired" marker, persisted so a restart
                        // can't re-fire. Cooldown does not gate inactivity.
                        if !store.hasUnresolved(ruleId: rule.id, userId: member.userId) {
                            store.record(
                                ruleId: rule.id, circleId: circleId,
                                userId: member.userId, memberName: member.displayName,
                                triggeredAt: now
                            )
                            notifyInactive(ruleId: rule.id, userId: member.userId,
                                           name: member.displayName, silentFor: silentFor)
                            await reportAlertEvent(
                                ruleId: rule.id, targetUserId: member.userId,
                                alertType: "inactivity", triggeredAt: now
                            )
                        }
                    } else {
                        // Active again → resolve the open event, cancel its
                        // now-stale tray notification, and re-arm for the
                        // next lapse. resolve() returns true only when a lapse
                        // was actually open, so the opt-in "back online" alert
                        // fires exactly once per recovery.
                        if store.resolve(ruleId: rule.id, userId: member.userId, fixAt: lastSeen) {
                            cancelInactivityNotification(ruleId: rule.id, userId: member.userId)
                            if rule.notifyOnReturn == true {
                                notifyBackOnline(ruleId: rule.id, userId: member.userId,
                                                 name: member.displayName)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reporting a firing

    /// Tell the server a firing happened, sealed, so the account's other
    /// devices and the web share one history.
    ///
    /// Best-effort and silent on failure: the local record and the notification
    /// have already happened, and this is the copy for elsewhere. Failing an
    /// evaluation because a history write did not land would trade something
    /// that works for something convenient.
    ///
    /// Sealed with the SELF key rather than the circle key, for two reasons
    /// pointing the same way. The row is only ever handed back to the account
    /// that wrote it — the list retrieves on user_id — so a per-user key is
    /// tighter at no cost. And it is what the reader expects: the web client
    /// decrypts these with SELF_CIRCLE_ID, and the web is the client that
    /// cannot produce them and most needs to read them, so sealing to a circle
    /// key would fill its history with rows it could not open.
    private func reportAlertEvent(
        ruleId: String,
        targetUserId: String,
        alertType: String,
        triggeredAt: Date
    ) async {
        guard let selfId = AuthManager.shared.userId else { return }
        let crypto = SDKCrypto.cryptoManager
        let keyId = SelfKeyManager.selfCircleUuid
        func seal(_ value: String) -> EncryptedBlobRequest? {
            guard let blob = try? crypto.encryptData(circleId: keyId, plaintext: value) else { return nil }
            return EncryptedBlobRequest(nonce: blob.nonce, ciphertext: blob.ciphertext)
        }
        guard let user = seal(selfId),
              let target = seal(targetUserId),
              let type = seal(alertType),
              // ISO-8601, not epoch millis. The exact moment, readable only by
              // the account that wrote it; the server's own triggered_at is
              // arrival time and differs whenever this reports late. A
              // JavaScript reader would render millis as "Invalid Date" —
              // `new Date("1755561234567")` parses a digit string as a date
              // string — so this sends the form every reader agrees on.
              let when = seal(ISO8601DateFormatter().string(from: triggeredAt))
        else { return }

        do {
            try await APIService.shared.createAlertEvent(request: CreateAlertEventRequest(
                alertRuleId: ruleId,
                dayBucket: Int(triggeredAt.timeIntervalSince1970 / 86_400),
                encryptedUserId: user,
                encryptedTargetUserId: target,
                encryptedAlertType: type,
                encryptedTriggeredAt: when
            ))
        } catch {
            print("[Track] alert-event report failed: \(error)")
        }
    }

    // MARK: - Low battery (watcher side)

    /// Evaluate every active low-battery rule we hold against the watched
    /// member's most recently reported level.
    ///
    /// The level rides inside their encrypted location payload, so this
    /// comparison can only happen on a device holding the circle key — which is
    /// why the server neither makes it nor is told the result. The per-circle
    /// "healthy" gate is the same one inactivity uses: a refresh that throws
    /// (network or key) skips the whole circle, so a connectivity gap cannot
    /// read as "their battery never came back".
    ///
    /// Fires once per drain and re-arms on recovery, with the open event as the
    /// persisted marker — a phone parked at 8% otherwise re-notifies on every
    /// wake-up and every pass.
    func evaluateBatteryAlerts() async {
        let rulesManager = AlertRulesManager.shared
        let store = LocalBatteryStore.shared
        await store.loadIfNeeded()
        await rulesManager.refreshIfStale(maxAge: Self.ruleListMaxAge)

        let rules = rulesManager.batteryRules.filter { $0.isActive && $0.circleId != nil }
        guard !rules.isEmpty else { return }

        let now = Date()
        let selfId = AuthManager.shared.userId
        let circleManager = CircleManager.shared

        for circleId in Set(rules.compactMap { $0.circleId }) {
            // Same two-tier gate as the inactivity pass, and needed for the same
            // reason with a different field: the stale entry a merge leaves behind
            // carries a stale batteryLevel as well as a stale timestamp, so an old
            // low reading from a member this refresh never heard from re-raises a
            // low-battery alert about a phone that may have been charged hours ago.
            let refresh: CircleManager.MemberLocationRefresh
            // `surfaceFailures: false` — background pass; see evaluateInactivityAlerts.
            do { refresh = try await memberRefresh(for: circleId) }
            catch { continue }
            guard refresh.isComplete else { continue }
            let members = circleManager.members[circleId] ?? []

            for rule in rules where rule.circleId == circleId {
                // A target we cannot decrypt is a rule we cannot judge; skipping
                // beats guessing at whom it is about.
                guard let targetId = rulesManager.target(for: rule), targetId != selfId else { continue }
                guard let member = members.first(where: { $0.userId == targetId }) else { continue }
                // Tier 2: only members this refresh actually produced a location
                // for. The cached batteryLevel of an absent member is as stale as
                // their cached timestamp.
                guard CircleManager.shouldJudge(targetId, from: refresh) else { continue }
                // No reading, or a location carrying no level because they do
                // not share battery with this circle: nothing to judge, and
                // silence is the right answer rather than an alarm.
                // CONSENT (`allow_alerts_on_me`) — see the inactivity pass above.
                // This circle's row of them, as there.
                let circleRow = circleManager.acceptedRow(of: targetId, in: circleId)
                if circleRow?.allowAlertsOnMe == false { continue }
                guard let level = circleRow?.batteryLevel else { continue }

                let threshold = rulesManager.threshold(for: rule)
                if level <= threshold {
                    if !store.hasUnresolved(ruleId: rule.id, userId: targetId) {
                        store.record(
                            ruleId: rule.id, circleId: circleId,
                            userId: targetId, memberName: member.displayName,
                            batteryLevel: level, triggeredAt: now
                        )
                        notifyLowBattery(ruleId: rule.id, userId: targetId,
                                         name: member.displayName, level: level)
                        await reportAlertEvent(
                            ruleId: rule.id, targetUserId: targetId,
                            alertType: "low_battery", triggeredAt: now
                        )
                    }
                } else if store.resolve(ruleId: rule.id, userId: targetId) {
                    // Charged back above the line: clear the stale notification
                    // so it isn't sitting there claiming 8% next to a phone on
                    // 90%, and re-arm for the next drain.
                    cancelLowBatteryNotification(ruleId: rule.id, userId: targetId)
                }
            }
        }
    }

    // MARK: - Circle self-alerts (somebody else's "watch me")

    private var cachedCircleSelfAlerts: [CircleSelfAlertResponse]?
    private var circleSelfAlertsFetchedAt: Date?

    /// Judge the self-alerts our circle-mates have asked us to watch.
    ///
    /// A self-alert is the one inactivity rule its owner's device cannot judge:
    /// the phone that has gone quiet is the phone that would have to notice. The
    /// server does not decide these, so ours is one of the devices that has to —
    /// and /inactivity-alerts/circle-self-alerts is how it learns the request was
    /// made. Being told is the entire purpose of the rule, which is why the
    /// disclosure is the feature rather than a cost of it.
    ///
    /// Reused for up to `ruleListMaxAge`, not fetched per pass. These are not
    /// our rules and they change without us, so a stale copy could, for at most
    /// that hour, have us alerting about somebody who cancelled — which is why
    /// every signal that something changed forces a fresh fetch: the
    /// `alerts_check` push (the server noticing a silence) and a return to the
    /// foreground both invalidate. Fetching per pass would cost every resident
    /// client a GET every 15 minutes, all night, almost always to learn "still
    /// none".
    /// Fires once per lapse against the same store the ordinary inactivity path
    /// uses, keyed on the alert id, so a member covered by both gets one
    /// notification per rule rather than one replacing the other.
    func evaluateCircleSelfAlerts() async {
        let store = LocalInactivityStore.shared
        await store.loadIfNeeded()

        let alerts: [CircleSelfAlertResponse]
        if let cached = cachedCircleSelfAlerts,
           !InactivityAlertsManager.isStale(
               lastRefreshedAt: circleSelfAlertsFetchedAt, maxAge: Self.ruleListMaxAge, now: Date()) {
            alerts = cached
        } else {
            do {
                alerts = try await APIService.shared.listCircleSelfAlerts()
                cachedCircleSelfAlerts = alerts
                circleSelfAlertsFetchedAt = Date()
            } catch {
                // A network blip must not read as "nobody asked".
                print("[Track] circle self-alerts fetch failed: \(error)")
                return
            }
        }
        guard !alerts.isEmpty else { return }

        let now = Date()
        let selfId = AuthManager.shared.userId
        let circleManager = CircleManager.shared

        for circleId in Set(alerts.map { $0.circleId }) {
            // Same two-tier gate as everything else here: a refresh that throws
            // or that half-failed skips the whole circle rather than reading as
            // "they went silent".
            let refresh: CircleManager.MemberLocationRefresh
            // `surfaceFailures: false` — background pass; see evaluateInactivityAlerts.
            do { refresh = try await memberRefresh(for: circleId) }
            catch { continue }
            guard refresh.isComplete else { continue }
            let members = circleManager.members[circleId] ?? []

            for alert in alerts where alert.circleId == circleId {
                // The server excludes our own; checked again because a rule
                // about us is not one this device should raise about us.
                if alert.userId == selfId { continue }
                guard let member = members.first(where: { $0.userId == alert.userId }) else { continue }
                // Paused, or real-time off, here: nothing goes off, and when that
                // ended counts as activity, as for the rules above.
                let sharing = member.sharing(at: now)
                if sharing != .on {
                    store.noteNotSharing(circleId: circleId, userId: alert.userId, status: sharing, now: now)
                    continue
                }
                store.noteSharing(circleId: circleId, userId: alert.userId, now: now)
                // Tier 2: only members this refresh heard from. These rules are
                // other people's requests to be watched, so the person who paused
                // is exactly the person a rule here is about.
                guard CircleManager.shouldJudge(alert.userId, from: refresh) else { continue }
                guard let lastSeen = circleManager.acceptedRow(of: alert.userId, in: circleId)?.timestamp else { continue }

                let silentFor = now.timeIntervalSince(LocalInactivityStore.activeSince(
                    lastSeen: lastSeen,
                    notSharingSeen: store.notSharingSeen(circleId: circleId, userId: alert.userId), now: now))
                if silentFor > Double(alert.timeoutHours) * 3600 {
                    if !store.hasUnresolved(ruleId: alert.id, userId: alert.userId) {
                        store.record(
                            ruleId: alert.id, circleId: circleId,
                            userId: alert.userId, memberName: member.displayName,
                            triggeredAt: now
                        )
                        notifyInactive(ruleId: alert.id, userId: alert.userId,
                                       name: member.displayName, silentFor: silentFor)
                        await reportAlertEvent(
                            ruleId: alert.id, targetUserId: alert.userId,
                            alertType: "inactivity", triggeredAt: now
                        )
                    }
                } else if store.resolve(ruleId: alert.id, userId: alert.userId, fixAt: lastSeen) {
                    cancelInactivityNotification(ruleId: alert.id, userId: alert.userId)
                    if alert.notifyOnReturn {
                        notifyBackOnline(ruleId: alert.id, userId: alert.userId,
                                         name: member.displayName)
                    }
                }
            }
        }
    }

    /// Stable per-(rule, member) id, distinct from the inactivity one so a
    /// member who is both silent and flat gets one notification for each rather
    /// than one quietly replacing the other.
    private func lowBatteryNotificationId(ruleId: String, userId: String) -> String {
        "low-battery-\(ruleId)-\(userId)"
    }

    private func notifyLowBattery(ruleId: String, userId: String, name: String, level: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Low battery"
        // Same detail-level gate as notifyInactive: `name` is a DECRYPTED
        // display name, so an ungated body would put it on the lock screen of
        // someone who chose "Generic". No place or message content here, so the
        // names-only string is also the detailed one.
        let detailed = "\(name)'s phone is at \(level)%."
        content.body = NotificationDetailLevel.resolveBody(detailed: detailed, namesOnly: detailed)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: lowBatteryNotificationId(ruleId: ruleId, userId: userId),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Track] notifyLowBattery add() failed: \(error)")
            }
        }
    }

    private func cancelLowBatteryNotification(ruleId: String, userId: String) {
        let id = lowBatteryNotificationId(ruleId: ruleId, userId: userId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Stable per-(rule, member) notification id so a re-post replaces rather
    /// than stacks (android's `stableNotificationId`).
    private func inactivityNotificationId(ruleId: String, userId: String) -> String {
        "inactivity-\(ruleId)-\(userId)"
    }

    private func notifyInactive(ruleId: String, userId: String, name: String, silentFor: TimeInterval) {
        let hours = Int(silentFor / 3600)
        let content = UNMutableNotificationContent()
        content.title = "Inactivity alert"
        // Route through the detail-level gate like every sibling builder
        // (DestinationsManager.postSelfArrivalNotification,
        // PushNotificationManager's circle-invite). `name` is a DECRYPTED
        // member display name, so an ungated body would put it on the lock
        // screen even for a user who had chosen "Generic". The copy carries
        // no place or message content, so names-only is the detailed string.
        let detailed = hours >= 1
            ? "\(name) hasn't sent a location in over \(hours)h."
            : "\(name) hasn't sent a location recently."
        content.body = NotificationDetailLevel.resolveBody(
            detailed: detailed,
            namesOnly: detailed
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: inactivityNotificationId(ruleId: ruleId, userId: userId),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Track] notifyInactive add() failed: \(error)")
            }
        }
    }

    /// Post the opt-in "back online" notification when a flagged member resumes
    /// sharing (client-only watch rules with notify_on_return). Mirrors
    /// notifyInactive; a distinct id so it doesn't collide with the offline banner.
    private func notifyBackOnline(ruleId: String, userId: String, name: String) {
        let content = UNMutableNotificationContent()
        content.title = "Back online"
        // Same detail-level gate as notifyInactive above — `name` is a
        // decrypted member display name. No place/message content, so the
        // names-only copy is the detailed copy.
        content.body = NotificationDetailLevel.resolveBody(
            detailed: "\(name) is sharing location again.",
            namesOnly: "\(name) is sharing location again."
        )
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "inactivity-recovered-\(ruleId)-\(userId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[Track] notifyBackOnline add() failed: \(error)")
            }
        }
    }

    private func cancelInactivityNotification(ruleId: String, userId: String) {
        let id = inactivityNotificationId(ruleId: ruleId, userId: userId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Reset

    /// Stop every monitoring timer/watcher and clear cached per-circle state
    /// on logout, so the next account doesn't inherit account A's
    /// battery-alert debounce map. The inactivity `locationUpdates` sink DOES
    /// get cancelled here: startInactivityWatch re-subscribes on the next
    /// login, so without this a duplicate sink would stack per account switch.
    func reset() {
        stopBatteryMonitoring()
        stopInactivityWatch()
        inactivityCancellables.removeAll()
        batteryAlertsSent = [:]
        lastWatchEvalAt = nil
        lastTimerPassAt = nil
        cachedCircleSelfAlerts = nil
        circleSelfAlertsFetchedAt = nil
        // Otherwise the next account inherits account A's "already reported at
        // this level" marker and stays silent through its own first drain.
        lastReportedBatteryLevel = nil
    }
}
