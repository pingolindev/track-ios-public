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
import Combine
import Security
import UIKit

/// The one thing wrong with location permission right now, ranked.
///
/// Every surface that warns about permission resolves through this, so they
/// cannot disagree about which problem to name. Independent conditions per
/// banner would not: "While Using" + Precise Off would light both, stacking
/// two orange banners with the blocking one second.
enum LocationPermissionWarning: Equatable {
    case notDetermined
    case whenInUse
    case denied
    case restricted
    /// Location granted, but "Precise Location" is off.
    case reducedAccuracy

    /// Reduced accuracy OUTRANKS the when-in-use warning, and is checked before
    /// `.authorizedAlways` returns nil. It blocks EVERY fix — the accuracy
    /// filter in `LocationService.didUpdateLocations` rejects the kilometre-
    /// scale ones iOS hands out — where when-in-use only blocks the background
    /// ones. Otherwise a user holding "Always" with Precise Location off would
    /// see no warning anywhere while their circle watched them stop moving.
    static func resolve(
        status: CLAuthorizationStatus,
        hasReducedAccuracy: Bool
    ) -> LocationPermissionWarning? {
        if hasReducedAccuracy { return .reducedAccuracy }
        switch status {
        case .authorizedAlways: return nil
        case .authorizedWhenInUse: return .whenInUse
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return nil
        }
    }
}

/// Location tracking service with background support
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    // MARK: - Published State

    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    /// Whether iOS is handing us real fixes or the deliberately coarse ones the
    /// "Precise Location" switch produces.
    ///
    /// SEPARATE FROM `authorizationStatus`, and that is the whole point: the
    /// user can hold "Always" and still be delivering kilometre-scale fixes.
    /// Unobserved, the accuracy filter in `didUpdateLocations` would reject
    /// every single fix and the user would simply stop appearing on their
    /// circle's map — with no signal on either end.
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    @Published private(set) var isTracking = false
    @Published private(set) var lastError: Error?

    /// Whether tracking has been ASKED FOR, as opposed to `isTracking`, which
    /// is whether CLLocationManager is actually running. The two differ for
    /// exactly one window — permission requested but not yet answered — and
    /// that window is the whole of a first run. Deliberately in-memory: the
    /// intent is re-established by the `startTracking()` call on each login /
    /// session restore, so persisting it would only let a stale flag outlive
    /// the logout that cleared it.
    private(set) var wantsTracking = false

    /// Called when a location event — an SLC or visit delivery, a region
    /// crossing — reaches a process that has not been asked to track
    /// (`wantsTracking` is false): iOS woke or relaunched the app in the
    /// background for location while tracking was not running.
    /// `HeadlessTrackingResume` installs it at launch, so such a process can
    /// restart tracking instead of handling the one event and going quiet.
    var onLocationEventWhileIdle: (@MainActor () -> Void)?

    // MARK: - Publishers

    /// Every fix this device accepted, however it arrived. Five subscribers
    /// read it and only one of them uploads: place alerts, geofences,
    /// destinations and the inactivity watch all want to know that a fix
    /// happened, whatever the send gate decides to do with it. Deliberately
    /// not narrowed to what the gate passes: that would silently disarm four
    /// local features to save server rows.
    let locationUpdates = PassthroughSubject<CLLocation, Never>()

    /// The gated stream: fixes the send gate decided are worth putting on the
    /// wire, each tagged with WHICH kind of send it earned. `CircleManager`
    /// uploads off this and nothing else, so a stationary device's fixes stop
    /// at the gate instead of writing a history row per circle per poll.
    let locationSendRequests = PassthroughSubject<SendRequest, Never>()

    // MARK: - Private Properties

    /// The keep-alive request. It runs for the whole session at
    /// `keepAliveAccuracy`, and its job is residency, not position: a running
    /// location request is what keeps this process alive in the background. It
    /// also carries SLC, visits and region monitoring, which are per-manager.
    private let locationManager = CLLocationManager()
    /// Fires a poll — one fresh fix — at the Android cadence for the current
    /// profile and battery tier. See `pollInterval(...)`.
    private var pollTimer: Timer?
    /// Fires at the check-in cadence, but ONLY while the poll has stretched past
    /// it (a mid/low battery tier while still). Otherwise the poll tick is the
    /// check-in. See `reconcileLivenessTimer`.
    private var livenessTimer: Timer?
    private var motionSubscription: AnyCancellable?
    private var batteryObservers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// Whether the app is on screen, from the lifecycle notifications. False
    /// until the first `didBecomeActive`, which is right for a launch into the
    /// background (an SLC or push relaunch never becomes active).
    private var appInForeground = false
    private var lastBatteryTier: BatteryTier?
    private var lastBatterySaverActive = false

    /// Polls in a row that produced nothing usable: a failure, or a fix too
    /// coarse to use. Drives `pollBackoffMultiplier`. See `recordPollOutcome`.
    private var consecutiveUnusablePolls = 0
    /// Whether "polls skipped, Precise Location is off" has been logged since
    /// precision was last available — once per episode, not once per tick.
    private var loggedReducedAccuracySkip = false
    /// An SOS this user raised is live. See `setEmergencyMode`.
    private(set) var emergencyMode = false
    /// When the poll profile last became `.still`, or nil while it is not.
    private var stillProfileSince: Date?
    /// The newest coarse STILL fix that confirmed the phone is still at the
    /// precise position it already holds. A check-in can use this freshness
    /// without treating the coarse fix itself as a position.
    private var lastPresenceConfirmedAt: Date?
    /// The saver-sleep trial is holding the process suspended. See
    /// `enterSaverSleep`.
    private(set) var isSaverSleeping = false
    /// The keep-alive stop that ends a sleep's settle window.
    private var saverSleepKeepAliveStop: DispatchWorkItem?
    /// One-shot requests from `requestSingleLocation`, held strongly until they
    /// complete: Core Location keeps only a weak reference to a delegate.
    private var singleFixRequests: [UUID: FreshFixRequest] = [:]

    /// The config `startTracking()` applied.
    private var activeConfig: TrackingConfig = .highAccuracy
    /// The poll cadence the evidence currently calls for.
    private var pollProfile: PollProfile = .unknown
    /// The last classification `applyMotionState` received. Mirrored here rather
    /// than read back from the manager so the profile decision and the diag line
    /// agree about which reading they acted on.
    private var motionState: MotionDetectionManager.MotionState = .unknown
    /// Where the phone settled, and for how long its fixes have stayed there.
    private var stillInference = StillInference()
    /// The poll in flight, held strongly until it completes: Core Location keeps
    /// only a weak reference to a delegate.
    private var activePollRequest: FreshFixRequest?

    private let settings = UserSettings.shared
    /// Battery Saver is active when either the user selected it or iOS entered
    /// Low Power Mode. The latter is an explicit system-level request to spend
    /// less energy and deserves the same accuracy profile, not only a longer
    /// poll interval.
    var isBatterySaverActive: Bool {
        TrackingConfig.usesBatterySaver(
            userEnabled: settings.batterySaverEnabled,
            systemLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    // MARK: - Configuration

    struct TrackingConfig: Equatable {
        /// The accuracy a moving or unknown poll asks Core Location for.
        let pollAccuracy: CLLocationAccuracy
        /// The accuracy a STILL poll asks for. It only needs presence and
        /// departure evidence, not a navigation-grade fix.
        let stillPollAccuracy: CLLocationAccuracy
        /// The worst horizontal accuracy a fix may carry and still be used as a
        /// position. Coarser fixes are rejected — and with Precise Location off
        /// that is every fix; see `handleFix`.
        let acceptedAccuracy: CLLocationAccuracy
        /// STILL fixes may be coarser. Within this limit they confirm presence,
        /// but never replace the last precise position.
        let stillAcceptedAccuracy: CLLocationAccuracy
        let allowsBackgroundUpdates: Bool
        /// The user's "Send on time interval" when they have never touched the
        /// picker. It caps the poll while moving and floors the check-in cadence
        /// (`pollInterval`, `livenessInterval`), so it has to agree with the
        /// number the Settings screen shows them. `SettingsView`'s
        /// `@AppStorage("location.intervalSec") … = 60` is a read-side default
        /// that writes nothing to `UserDefaults` until the picker is touched, so
        /// on a device whose picker was never touched the stored value is absent
        /// and this fallback is what actually runs.
        let pollIntervalSeconds: TimeInterval

        static let highAccuracy = TrackingConfig(
            // The product accepts positions to 100 m. Asking for
            // Best would keep navigation-grade sensor fusion
            // alive for no product benefit; ten metres is still
            // well inside the acceptance rule. SOS explicitly
            // overrides both values with Best.
            pollAccuracy: kCLLocationAccuracyNearestTenMeters,
            stillPollAccuracy: kCLLocationAccuracyHundredMeters,
            acceptedAccuracy: 100,
            stillAcceptedAccuracy: 500,
            allowsBackgroundUpdates: true,
            // Taken FROM the Settings default rather than restated as a literal,
            // so the two cannot drift apart.
            pollIntervalSeconds: TimeInterval(LocationService.settingsDefaultIntervalSeconds)
        )

        static let batterySaver = TrackingConfig(
            pollAccuracy: kCLLocationAccuracyHundredMeters,
            stillPollAccuracy: kCLLocationAccuracyHundredMeters,
            acceptedAccuracy: 500,
            stillAcceptedAccuracy: 500,
            allowsBackgroundUpdates: true,
            pollIntervalSeconds: 300
        )

        static func requestedAccuracy(
            profile: PollProfile,
            config: TrackingConfig,
            emergency: Bool
        ) -> CLLocationAccuracy {
            if emergency { return kCLLocationAccuracyBest }
            return profile == .still ? config.stillPollAccuracy : config.pollAccuracy
        }

        static func acceptedAccuracy(
            profile: PollProfile,
            config: TrackingConfig,
            emergency: Bool
        ) -> CLLocationAccuracy {
            if emergency { return config.acceptedAccuracy }
            return profile == .still ? config.stillAcceptedAccuracy : config.acceptedAccuracy
        }

        /// The app's Battery Saver and iOS Low Power Mode both mean "use the
        /// battery-saving profile": accuracy as well as interval.
        static func usesBatterySaver(userEnabled: Bool, systemLowPower: Bool) -> Bool {
            userEnabled || systemLowPower
        }
    }

    // MARK: - Polling model (Android parity)
    //
    // A continuous stream at `kCLLocationAccuracyBest` would keep the GPS
    // receiver powered for as long as the user is signed in, wherever the phone
    // is and whether or not it is moving: a phone on a desk overnight would keep
    // it powered all night. Instead this is the Android app's model, knob for knob:
    //
    //   * The GPS is used by POLLS — one fresh fix per tick — at Android's
    //     cadence: 20 s moving, 30 s with no motion opinion, 5 min still
    //     (`LocationTrackingService` POLL_MOVING_MS / POLL_UNKNOWN_MS /
    //     POLL_STILL_MS), stretched 2x between 20% and 50% battery and 4x below
    //     20% unless charging, capped at the user's own interval while not
    //     still, clamped to [10 s, 30 min]. Between polls the receiver is off.
    //     Low Power Mode and a serious thermal state count as the low tier.
    //     Polls that keep failing back off (`pollBackoffMultiplier`), and an
    //     SOS overrides all of it with the moving cadence (`setEmergencyMode`).
    //     Battery saver replaces all of that with one flat 15-minute poll at
    //     balanced accuracy, which is also what Android's battery saver runs.
    //   * One request stays running the whole time, at an accuracy Core
    //     Location serves from cell towers and Wi-Fi with the receiver off. Its
    //     fixes are never positions — only movement hints (`handleKeepAliveHint`).
    //     It exists because a running request is what keeps this process
    //     resident in the background — stop it and iOS suspends the app within
    //     seconds, the timers with it, and the motion updates that would notice
    //     the next trip. Android's foreground service does the same job. It also
    //     carries SLC, visits and the geofences. (Dev builds trial stopping it
    //     while a battery-saver phone sits still — see `enterSaverSleep`.)
    //   * The check-in rides the poll: a fix that has not moved is offered to the
    //     gate as a liveness check-in. Only while a low battery stretches the
    //     poll past the check-in cadence does a separate timer re-offer the
    //     cached fix, so the phone does not read as dead (Android's
    //     maybeSendLivenessCheckIn), with the same honesty guard: a cache older
    //     than twice the poll is not dressed up as current.
    //
    // `pausesLocationUpdatesAutomatically` is false on every manager here, on
    // purpose: the system pause SUSPENDS a background app and nothing resumes
    // updates until the app itself does, which a suspended app cannot.

    /// Android POLL_MOVING_MS.
    static let pollMovingSeconds: TimeInterval = 20
    /// Android POLL_UNKNOWN_MS.
    static let pollUnknownSeconds: TimeInterval = 30
    /// Android POLL_STILL_MS. The same five minutes as the check-in cadence, so
    /// while still a check-in rides a fix the device was taking anyway.
    static let pollStillSeconds: TimeInterval = 5 * 60
    /// Android MIN_POLL_MS / MAX_POLL_MS.
    static let minPollSeconds: TimeInterval = 10
    static let maxPollSeconds: TimeInterval = 30 * 60
    /// Battery saver's whole cadence: one BALANCED — cell and Wi-Fi, no GPS —
    /// fix every 15 minutes.
    ///
    /// Android's battery saver is the same thing: a flat BALANCED subscription
    /// at the user's batch interval, 15 minutes by default. (Android's
    /// "Battery-saver mode skips streaming entirely" is about the upload
    /// stream, not about location.)
    ///
    /// iOS reaches the cadence with the ordinary poll timer rather than
    /// `BGTaskScheduler`, because `BGAppRefreshTask` cannot hold a 15-minute
    /// cadence — iOS fires it when it feels like it, "typically after ~24h of
    /// moderate usage" per `BackgroundTaskScheduler`'s own header. The
    /// keep-alive request is what lets a plain timer do the job: it keeps the
    /// process resident, which is the role Android's foreground service plays.
    static let pollBatterySaverSeconds: TimeInterval = 15 * 60
    /// Android BATTERY_MID_THRESHOLD / BATTERY_LOW_THRESHOLD.
    static let batteryMidThresholdPercent = 50
    static let batteryLowThresholdPercent = 20

    /// Android's battery tiers and their POLL_MULT_* multipliers.
    enum BatteryTier: Equatable {
        case normal, mid, low

        var pollMultiplier: Double {
            switch self {
            case .normal: return 1
            case .mid: return 2
            case .low: return 4
            }
        }

        /// Android `computeBatteryTier`: charging forces normal regardless of
        /// level, and an unknown level is not licence to slow down.
        ///
        /// Two inputs Android's tiering never reads come first, and both force
        /// the LOW tier whatever the level or charger says:
        /// - Low Power Mode: the user asked the OS to save power, so a phone in
        ///   Low Power Mode does not keep the full cadence, even above 50%. (iOS
        ///   turns it off on its own once a charging phone passes 80%, so this
        ///   never pins a phone on the charger.)
        /// - A serious or critical thermal state: the GPS is heat the phone is
        ///   already struggling to shed, and charging is a common cause.
        static func tier(
            levelPercent: Int?,
            isCharging: Bool,
            lowPowerMode: Bool = false,
            thermalSerious: Bool = false
        ) -> BatteryTier {
            if lowPowerMode || thermalSerious { return .low }
            if isCharging { return .normal }
            guard let level = levelPercent else { return .normal }
            if level < LocationService.batteryLowThresholdPercent { return .low }
            if level < LocationService.batteryMidThresholdPercent { return .mid }
            return .normal
        }
    }

    /// The poll cadence the evidence calls for. Three, like Android's motion
    /// states, because they poll at three different rates.
    enum PollProfile: Equatable {
        case moving
        /// No opinion from motion (denied, unavailable, not yet confident) and
        /// the fixes have not shown the phone holding one spot.
        case unknown
        case still
    }

    /// Motion's `.moving` is final: a trip is a trip. Its `.still` is trusted
    /// unless the fixes contradict it — a fix that left the anchor within the
    /// last `StillInference.minSpan` restores the moving cadence until the
    /// phone has demonstrably settled again. With no opinion from motion the
    /// fixes decide alone, which is Android's inferred STILL: the unknown
    /// cadence until they show the phone holding one spot.
    static func desiredPollProfile(
        motion: MotionDetectionManager.MotionState,
        held: Bool,
        anchorBrokenRecently: Bool
    ) -> PollProfile {
        switch motion {
        case .moving: return .moving
        case .still: return anchorBrokenRecently ? .moving : .still
        case .unknown: return held ? .still : .unknown
        }
    }

    /// Android `computePollIntervalMs`, in seconds.
    ///
    /// Battery saver ignores every one of those inputs and returns a flat
    /// `pollBatterySaverSeconds` — see the comment inside.
    ///
    /// `emergency` (an SOS this user raised is live) overrides everything,
    /// battery saver included: the moving cadence at the normal tier, still
    /// capped by the user's own interval. `backoffMultiplier` stretches a poll
    /// that keeps failing — see `pollBackoffMultiplier` — but never past the
    /// still cadence, and never an emergency.
    static func pollInterval(
        profile: PollProfile,
        batterySaver: Bool,
        batteryTier: BatteryTier,
        userInterval: TimeInterval,
        emergency: Bool = false,
        backoffMultiplier: Double = 1
    ) -> TimeInterval {
        if emergency {
            return pollInterval(
                profile: .moving, batterySaver: false, batteryTier: .normal, userInterval: userInterval
            )
        }
        // Battery saver is a FLAT cadence: no motion profile, no user cap, and
        // deliberately no tier multiplier either. Stretching it further would
        // be more efficient than Android and is still the wrong trade — Android
        // makes the same choice in the same mode, because a deferred tick can
        // let a phone go dark for hours, and "a heartbeat is one encrypted
        // sub-1KB message, a rounding error against the cost of the user
        // silently going dark". A phone conserving power is exactly the phone
        // whose watchers most need to know it is alive.
        //
        // It also lands the check-in cadence on the poll: `livenessInterval`
        // in battery saver is 900 s and the picker's longest choice is 900 s,
        // so the two are equal and a check-in rides a fix the device was taking
        // anyway — the same symmetry the still cadence has at five minutes.
        if batterySaver {
            return min(max(pollBatterySaverSeconds, minPollSeconds), maxPollSeconds)
        }
        let base: TimeInterval
        switch profile {
        case .moving: base = pollMovingSeconds
        case .unknown: base = pollUnknownSeconds
        case .still: base = pollStillSeconds
        }
        var interval = base * batteryTier.pollMultiplier
        // The cap exists so a scheduled send always has a fresh fix. While still
        // that reasoning inverts: a fix from five minutes ago describes the SAME
        // PLACE, so capping the poll at the send interval buys no accuracy and
        // costs a 5x GPS duty cycle. Exempting still is what makes the still
        // cadence reachable at all, since the interval defaults to 60 s.
        if profile != .still, userInterval > 0, userInterval < interval {
            interval = userInterval
        }
        // A run of polls that produces nothing usable — a subway, a phone in a
        // bag, indoors with no Wi-Fi position — would otherwise get no relief:
        // every tick would run the receiver for its whole timeout again.
        // Stretch it, but only up to the still cadence, which is what a phone
        // that genuinely is not getting anywhere would be polled at anyway.
        if backoffMultiplier > 1, interval < pollStillSeconds {
            interval = min(interval * backoffMultiplier, pollStillSeconds)
        }
        return min(max(interval, minPollSeconds), maxPollSeconds)
    }

    /// How many unusable polls in a row it takes before the poll backs off.
    static let pollBackoffThreshold = 3

    /// ×1 until `pollBackoffThreshold` unusable polls in a row, then ×2, ×4, …
    /// per further one. `pollInterval` caps the result at the still cadence, so
    /// the multiplier can grow without bound and the interval cannot.
    static func pollBackoffMultiplier(consecutiveUnusable: Int) -> Double {
        guard consecutiveUnusable >= pollBackoffThreshold else { return 1 }
        let doublings = min(consecutiveUnusable - pollBackoffThreshold + 1, 16)
        return pow(2, Double(doublings))
    }

    /// Battery saver checks in more slowly — 3x the floor — but it DOES check
    /// in: "save battery" must not read as "look dead". Android
    /// LIVENESS_CHECKIN_INTERVAL_BATTERY_SAVER_MS.
    static let livenessBatterySaverIntervalSeconds: TimeInterval = 3 * livenessIntervalSeconds

    /// How often a phone with a live SOS checks in when it is not moving. The
    /// circle is watching this dot more closely than at any other time, and a
    /// check-in is one small upload riding a poll the emergency takes anyway.
    static let livenessEmergencyIntervalSeconds: TimeInterval = 60

    /// Android `livenessIntervalMsFor`: the floor, or the user's own interval,
    /// whichever is LONGER — nobody checks in more often than they chose to
    /// send, so a 15-minute user gets exactly the cadence they picked. A live
    /// SOS overrides both.
    static func livenessInterval(
        userInterval: TimeInterval,
        batterySaver: Bool,
        emergency: Bool = false
    ) -> TimeInterval {
        if emergency { return livenessEmergencyIntervalSeconds }
        return max(batterySaver ? livenessBatterySaverIntervalSeconds : livenessIntervalSeconds, userInterval)
    }

    /// Whether the check-in needs a clock of its own. While the poll runs at
    /// least as often as the check-in cadence, every tick already offers a fix
    /// to the gate, so a second repeating timer only adds a wake-up of its own
    /// — about 12 an hour, phased independently of the poll so they rarely
    /// coalesce. Only a poll stretched past the cadence (the mid and low
    /// battery tiers while still) needs one. Android rides an existing tick for
    /// the same reason.
    static func needsDedicatedLivenessTimer(
        pollInterval: TimeInterval,
        livenessInterval: TimeInterval
    ) -> Bool {
        pollInterval > livenessInterval + livenessIntervalToleranceSeconds
    }

    /// Android `stillRefreshCacheTooOld`: a check-in re-sends the cached fix
    /// with a current timestamp, and it must never present an ancient position
    /// as current. If the cache is older than twice the poll (floor ten minutes)
    /// the GPS has stopped delivering, and the honest answer is to let the
    /// timestamp go stale.
    static func livenessCacheTooOld(cacheAge: TimeInterval, pollInterval: TimeInterval) -> Bool {
        // A cache stamped in the future: the clock was set back since it was
        // taken (`isFromTheFuture`), and its age says nothing honest about it.
        cacheAge < -futureFixToleranceSeconds || cacheAge > max(pollInterval * 2, 10 * 60)
    }

    /// The keep-alive request's accuracy: coarse enough that Core Location
    /// answers from cell and Wi-Fi with the receiver powered down — anything at
    /// or beyond a kilometre does. The coarsest request is the cheapest one, and
    /// its fixes are discarded anyway.
    static let keepAliveAccuracy: CLLocationAccuracy = kCLLocationAccuracyThreeKilometers
    /// Its delivery trigger. The fixes are only movement hints, and cell
    /// positioning wanders by tens of metres on its own. A smaller filter
    /// (100 m, say) would wake the process for every tower handoff and —
    /// whenever another app has the GPS on — for every 100 m of driving,
    /// although nothing short of `coarseMoveMeters` can ever act on a hint.
    /// Equal to that, so a delivery is always one that might matter.
    static let keepAliveDistanceFilter: CLLocationDistance = coarseMoveMeters

    /// How far a keep-alive fix must sit from the anchor, beyond its own error,
    /// before it is worth a poll to check: a 1.5 km cell fix has to move more
    /// than 1.5 km, or cell handoffs alone would wake the GPS in every building
    /// on a tower boundary.
    static let coarseMoveMeters: CLLocationDistance = 500

    static func coarseFixSuggestsMovement(
        distanceFromAnchor: CLLocationDistance,
        accuracy: CLLocationAccuracy
    ) -> Bool {
        distanceFromAnchor > max(coarseMoveMeters, accuracy > 0 ? accuracy : 0)
    }

    /// How long one poll may run the receiver before settling for what it has.
    /// A warm GPS delivers in a second or two; a cold one indoors may never
    /// satisfy the accuracy, and the poll then hands over its best fresh fix or
    /// the newest cached one — see `FreshFixRequest`.
    static let pollTimeoutSeconds: TimeInterval = 15

    /// The age past which `handleFix` no longer takes a fix as a position
    /// (the Android app rejects past 30 s; this gives the poll a little slack).
    static let staleFixAgeLimitSeconds = 60

    /// The timeout a poll at `interval` actually gets: at most 80% of the
    /// interval. A 15 s timeout on the 10 s tick a user can pick in Settings
    /// would keep the receiver on for 15 of every 20 seconds whenever fixes
    /// are slow — the continuous stream this model exists to prevent.
    static func pollTimeout(forInterval interval: TimeInterval) -> TimeInterval {
        min(pollTimeoutSeconds, interval * 0.8)
    }

    /// Android's `maybeInferStill`, as a value: the phone has demonstrably held
    /// one spot when every accepted fix for `minSpan` landed within `radius(for:)`
    /// of the first. A moving phone cannot satisfy it — its fixes leave the
    /// radius and re-anchor — so this can never under-serve someone who is
    /// driving. Pure so the rule is testable without Core Location.
    struct StillInference {
        /// Android STILL_INFER_RADIUS_M.
        static let radiusMeters: CLLocationDistance = 50
        /// Android STILL_INFER_MIN_SPAN_MS.
        static let minSpan: TimeInterval = 3 * 60

        private(set) var anchor: CLLocation?
        private(set) var anchorObservedAt: Date?
        private(set) var isHeld = false
        private(set) var lastBreakAt: Date?

        /// Android `stillInferRadiusFor`: judge at the ROUGHER of the fixed
        /// radius and the fixes' own accuracy. Holding a 65 m indoor fix to a
        /// 50 m anchor is not a strict test, it is an impossible one, and a rule
        /// that can never fire saves nothing. Unknown accuracy keeps the fixed
        /// radius.
        ///
        /// Both errors count. Widening by the NEW fix's accuracy only would
        /// make a 65 m Wi-Fi anchor followed by a 10 m GPS fix 55 m away —
        /// two readings that agree within the anchor's own error — count as
        /// leaving, and send a phone that motion said was still back to the
        /// moving cadence for three minutes.
        static func radius(
            for accuracy: CLLocationAccuracy,
            anchorAccuracy: CLLocationAccuracy = 0
        ) -> CLLocationDistance {
            max(radiusMeters, max(accuracy, 0) + max(anchorAccuracy, 0))
        }

        /// Adopt `fix` as the anchor without counting it as a break: where the
        /// phone was when motion reported it still.
        mutating func seed(_ fix: CLLocation, at now: Date) {
            anchor = fix
            anchorObservedAt = now
            isHeld = false
        }

        /// Feed an accepted fix. `now` is the wall clock, deliberately not the
        /// fix's own timestamp: a fix Core Location handed back from its cache
        /// because the phone has not moved is the best evidence of stillness
        /// there is, and its timestamp is old for exactly that reason.
        @discardableResult
        mutating func observe(_ fix: CLLocation, at now: Date) -> Bool {
            if let anchor, let since = anchorObservedAt,
               fix.distance(from: anchor) <= Self.radius(
                   for: fix.horizontalAccuracy, anchorAccuracy: anchor.horizontalAccuracy
               ) {
                isHeld = now.timeIntervalSince(since) >= Self.minSpan
                return isHeld
            }
            // Only a fix that LEAVES an anchor is a break. The first fix ever
            // seen is just the anchor.
            if anchor != nil { lastBreakAt = now }
            anchor = fix
            anchorObservedAt = now
            isHeld = false
            return false
        }

        /// A fix left the anchor less than `minSpan` ago.
        func brokenRecently(at now: Date) -> Bool {
            guard let lastBreakAt else { return false }
            return now.timeIntervalSince(lastBreakAt) < Self.minSpan
        }

        mutating func reset() {
            self = StillInference()
        }
    }

    // MARK: - Saver-sleep trial (dev builds only)
    //
    // The keep-alive request makes the process resident for as long as the user
    // is signed in, so every timer in the app runs all night. That residency is
    // the price of the five-minute (15 in battery saver) "still here" check-in,
    // not of background tracking as such: a phone that is not moving could let
    // iOS suspend the app and be woken by the hardware when it moves.
    //
    // This trial does exactly that, and only where the user has already traded
    // freshness for battery — Battery Saver — and only in DEBUG / RELEASE_DEV
    // builds, so App Store builds never run it. Once a saver phone has been
    // still for `saverSleepMinStillSeconds` it sends one check-in, arms an exit
    // region around where it sits, and stops the keep-alive request and its
    // timers. SLC and visits stay on. Any of these wakes it (see
    // `SaverSleepEvent`): leaving the region, an SLC or visit delivery, motion
    // reporting a trip, the app coming to the foreground, a push asking for a
    // fix, an SOS, or Battery Saver being switched off.
    //
    // THE TRADE-OFF, stated plainly: while it sleeps the phone sends nothing, so
    // its circle sees the last-seen age grow — minutes into hours overnight —
    // where it would otherwise refresh every 15 minutes. That is why it is a
    // trial and why it is Battery Saver only.
    //
    // A suspended app is terminated far more often than a resident one. The
    // region / SLC / visit event that later relaunches it restarts tracking
    // through `HeadlessTrackingResume` — the session restore itself runs only
    // when a scene appears, which a background relaunch never does.

    /// Compiled in for DEBUG and RELEASE_DEV (TestFlight) builds only.
    static let saverSleepTrialEnabled: Bool = {
        #if DEBUG || RELEASE_DEV
        return true
        #else
        return false
        #endif
    }()

    /// How long a battery-saver phone must have been still before it sleeps.
    static let saverSleepMinStillSeconds: TimeInterval = 10 * 60
    /// The exit region's radius: twice the anchor's error, at least 150 m so
    /// a GPS anchor is not a hair trigger, and at most 500 m so a Wi-Fi or cell
    /// anchor does not let a phone drive a kilometre before anything notices.
    static let saverSleepMinRadiusMeters: CLLocationDistance = 150
    static let saverSleepMaxRadiusMeters: CLLocationDistance = 500
    /// The one region this service monitors for itself. Never shown to
    /// `PlaceManager`, which reserves the slot (`maxMonitoredRegions` is 19).
    static let saverSleepRegionIdentifier = "track.saver-sleep"
    /// How long the keep-alive keeps the process up after the last check-in,
    /// so that check-in — which `CircleManager` uploads behind a debounce —
    /// actually leaves the phone before iOS suspends it.
    static let saverSleepSettleSeconds: TimeInterval = 30

    static func saverSleepRegionRadius(anchorAccuracy: CLLocationAccuracy) -> CLLocationDistance {
        min(max(saverSleepMinRadiusMeters, 2 * max(anchorAccuracy, 0)), saverSleepMaxRadiusMeters)
    }

    /// Whether a battery-saver phone may go to sleep now. Pure, so the rule is
    /// testable without Core Location. Every condition is a hard requirement:
    /// no Always permission means no wake-up from the region; no anchor means
    /// no region to arm; an SOS always keeps the phone awake; and a user who
    /// has the app open is looking at the map it would freeze.
    static func shouldEnterSaverSleep(
        trialEnabled: Bool,
        batterySaver: Bool,
        alwaysAuthorized: Bool,
        emergency: Bool,
        appInForeground: Bool,
        profile: PollProfile,
        stillSince: Date?,
        hasAnchor: Bool,
        regionMonitoringAvailable: Bool,
        now: Date
    ) -> Bool {
        guard trialEnabled, batterySaver, alwaysAuthorized, !emergency, !appInForeground,
              hasAnchor, regionMonitoringAvailable,
              profile == .still, let stillSince else { return false }
        return now.timeIntervalSince(stillSince) >= saverSleepMinStillSeconds
    }

    /// Everything that can reach a sleeping phone.
    enum SaverSleepEvent: Equatable {
        case regionExit(identifier: String)
        case significantChange
        case visit
        case motionMoving
        case appBecameActive
        case singleLocationRequest
        case emergency
        case restart
    }

    /// Whether `event` wakes a sleeping phone. Every event does except a
    /// crossing of some other region — a place geofence belongs to
    /// `PlaceManager` and says nothing about this phone having moved off its
    /// anchor.
    static func saverSleepShouldWake(on event: SaverSleepEvent) -> Bool {
        switch event {
        case .regionExit(let identifier):
            return identifier == saverSleepRegionIdentifier
        case .significantChange, .visit, .motionMoving, .appBecameActive,
             .singleLocationRequest, .emergency, .restart:
            return true
        }
    }

    // MARK: - Send Policy
    //
    // Not every accepted fix becomes a history row: one per fix, in every
    // circle the user shares with, at the poll cadence, would fill the location
    // store — a phone on a desk overnight would write the same coordinates
    // several hundred times.
    //
    // The rule: a green dot is legitimate if the phone is actually live and
    // COULD have sent a location. So how often the phone LOOKS at its position
    // is the poll model's business (see above), and this section only evaluates
    // the SEND. Moved far enough, a history row. Not moved, a liveness check-in
    // that the server files in its latest-position table alone. Stopped doing
    // either, genuinely inactive.

    /// What a fix is worth putting on the wire.
    enum SendMode: Equatable {
        /// A real position change: a trail point, stored in history.
        case history
        /// The device is alive but has not moved far enough for the position to
        /// be worth keeping. Latest-position table only, no history row.
        case liveness
        /// A true past position that is not the latest: a fix or a visit older
        /// than the one held. History alone on the wire (`history_only`), as the
        /// points kept for a circle waiting to sync are: the server keeps the
        /// last row INSERTED as the latest, so a late point never goes the live
        /// way.
        case pastHistory
    }

    /// A fix paired with the decision about what to do with it.
    struct SendRequest {
        let location: CLLocation
        let mode: SendMode
    }

    /// How often a device that is alive but not moving checks in.
    ///
    /// TUNE HERE. Five minutes is the trade: the inactivity alerts users
    /// actually configure are measured in tens of minutes and hours, so a
    /// five-minute check-in leaves a wide margin before any of them could
    /// misfire, while cutting a stationary phone from 60 rows an hour per
    /// circle to 12 — and those 12 are latest-position writes, not history.
    static let livenessIntervalSeconds: TimeInterval = 300

    /// Slack on the cadence above, because a tick that lands a hair early must
    /// still check in.
    ///
    /// This is not hypothetical: the still poll is 300 s and the battery-saver
    /// poll 900 s, each the same number as its check-in cadence, so a `Timer`
    /// firing a few milliseconds early would fail a bare `>=` and push the
    /// check-in to the NEXT tick — a phone going ten minutes silent, then
    /// twenty, for no reason but arithmetic.
    static let livenessIntervalToleranceSeconds: TimeInterval = 5

    /// The poll interval the Settings screen advertises when the user has never
    /// touched the picker — `SettingsView`'s
    /// `@AppStorage("location.intervalSec") … = 60`.
    ///
    /// `TrackingConfig.highAccuracy` reads its `pollIntervalSeconds` from here
    /// rather than restating the number: a second copy could disagree with the
    /// screen, and since the screen's default writes nothing to `UserDefaults`,
    /// the fallback is the one that runs.
    static let settingsDefaultIntervalSeconds = 60

    /// The movement the send gate requires before a fix earns a history row,
    /// when the user has not chosen a distance.
    ///
    /// Matches the Settings screen's own default (`SettingsView`'s
    /// `@AppStorage("location.distanceMeters") … = 100`) and the Android app.
    /// Deliberately NOT a Core Location distance filter such as
    /// `keepAliveDistanceFilter`: those are DELIVERY triggers, and reusing one
    /// as the send gate would let ordinary jitter on a stationary desk read as
    /// movement and write the history rows the gate exists to stop.
    static let settingsDefaultDistanceMeters: CLLocationDistance = 100

    /// UserDefaults keys, shared with `SettingsView`'s `@AppStorage` wrappers.
    static let intervalSecondsKey = "location.intervalSec"
    static let distanceMetersKey = "location.distanceMeters"

    /// Resolve the poll interval from what the user has (or has not) chosen.
    ///
    /// Three cases, and telling the first from the third is the point:
    ///
    /// - **Absent** (`stored == nil`): the user has never opened the picker, so
    ///   the number they are being shown is `SettingsView`'s `@AppStorage`
    ///   default — a read-side default that writes nothing. Honour the mode's
    ///   own default, which is 60 in high accuracy and 300 in battery saver.
    /// - **Present and positive**: a real choice from the picker. Used verbatim,
    ///   including a deliberate 30 — the user asked for it.
    /// - **Present and <= 0**: not a value the picker can produce (its tags are
    ///   10/30/60/300/600/900), so it is a corrupt or legacy write, not a
    ///   choice. Treated as no choice at all.
    ///
    /// `UserDefaults.integer(forKey:)` cannot separate the first case from the
    /// third — it answers 0 for both — so reading it that way makes "nobody
    /// chose" and "somebody stored zero" indistinguishable, and logic built on
    /// that sentinel would have to overwrite a genuine choice to be safe. The
    /// `Int?` from `object(forKey:)` is what keeps them apart.
    static func resolvedPollIntervalSeconds(
        stored: Int?,
        unsetDefault: TimeInterval
    ) -> TimeInterval {
        guard let stored else { return unsetDefault }
        return stored > 0 ? TimeInterval(stored) : unsetDefault
    }

    /// The send gate's distance threshold, resolved with the same
    /// unset-versus-stored-zero discipline as the interval above.
    static func resolvedSendDistanceMeters(stored: Int?) -> CLLocationDistance {
        guard let stored, stored > 0 else { return settingsDefaultDistanceMeters }
        return CLLocationDistance(stored)
    }

    /// Decide what a fix is worth sending, or `nil` for "send nothing".
    ///
    /// Pure and static so the decision is testable without Core Location, a
    /// timer, a live stream or a signed-in user.
    ///
    /// - `historyAllowed` is false for a fix whose COORDINATES are trustworthy
    ///   but whose timestamp is not — see `routeToSendGate`.
    /// - `lastHistorySent` is the last position actually sent as history, not
    ///   the previous fix. Measuring against the previous fix would let a drift
    ///   of sub-threshold steps walk the device across town without ever
    ///   tripping the gate.
    /// - `lastUploadAt` covers BOTH kinds. A history send refreshes the
    ///   latest-position row too, so it proves liveness just as well; one clock
    ///   for both is what stops a device that has only now stopped moving from
    ///   stacking a check-in on top of the row it sent seconds ago.
    static func decideSend(
        candidate: CLLocation,
        lastHistorySent: CLLocation?,
        distanceThresholdMeters: CLLocationDistance,
        historyAllowed: Bool,
        lastUploadAt: Date?,
        now: Date,
        livenessInterval: TimeInterval = livenessIntervalSeconds,
        tolerance: TimeInterval = livenessIntervalToleranceSeconds
    ) -> SendMode? {
        if historyAllowed {
            // Nothing sent yet this tracking session: the first fix
            // anchors the trail, unconditionally. Never rate-limited,
            // and checked before the cadence.
            guard let lastHistorySent else { return .history }
            if candidate.distance(from: lastHistorySent) >= distanceThresholdMeters {
                return .history
            }
        }
        guard let lastUploadAt else { return .liveness }
        return now.timeIntervalSince(lastUploadAt) >= livenessInterval - tolerance
            ? .liveness
            : nil
    }

    /// The timestamp the outgoing payload carries.
    ///
    /// A liveness check-in exists to say "this phone is alive NOW", and both the
    /// map and the inactivity logic read the decrypted timestamp — so carrying
    /// the fix's own time would make a check-in built from a cached fix land
    /// looking exactly as old as the fix it was built from, which defeats the
    /// check-in. A history row keeps the fix's time: it is a trail point and it
    /// belongs at the moment the device was actually there.
    static func payloadTimestamp(mode: SendMode, fixTimestamp: Date, now: Date) -> Date {
        switch mode {
        case .history, .pastHistory: return fixTimestamp
        case .liveness: return now
        }
    }

    /// The last position that went out as a history row, or nil before the first
    /// one. Cleared by `stopTracking()` so a new session anchors afresh rather
    /// than measuring today's movement against where the phone was at logout.
    private var lastHistorySentLocation: CLLocation?

    /// When anything last went to the server, history or liveness.
    private var lastUploadAt: Date?

    // MARK: - Initialization

    private override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
        accuracyAuthorization = locationManager.accuracyAuthorization
        // Foregrounding is a fresh start for two things: a poll that backed off
        // after failing indoors gets its cadence back, and a sleeping
        // battery-saver phone wakes (the user is looking at the map).
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appDidBecomeActive()
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appInForeground = false
        })
    }

    private func appDidBecomeActive() {
        appInForeground = true
        guard isTracking else { return }
        exitSaverSleep(on: .appBecameActive)
        resetPollBackoff(reason: "app active")
    }

    // MARK: - Authorization

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Key for the one-shot Always prompt, read by the Map and Settings banners
    /// to decide whether their button can still raise a native dialog or has to
    /// deep-link into Settings. The VALUE is load-bearing: renaming it strands
    /// the flag every existing install already carries.
    static let alwaysPromptAttemptedKey = "location.alwaysPromptAttempted"

    /// Whether asking for Always RIGHT NOW spends the one-shot native prompt.
    ///
    /// Only from `.authorizedWhenInUse`. From `.notDetermined` iOS shows the
    /// When-In-Use dialog — the Always dialog is not on offer until a
    /// when-in-use grant exists — and from `.denied` / `.restricted` /
    /// `.authorizedAlways` nothing is shown at all. Recording an attempt in
    /// those states burns a prompt the user never saw, after which every
    /// "Enable Background Tracking" tap is a trip to Settings.
    ///
    /// It is reachable: onboarding's `requestSingleLocation()` precondition is
    /// `try?`-swallowed, so tapping past the Location page without granting and
    /// then tapping Get Started asks from `.notDetermined`, which must not
    /// record the prompt as spent.
    ///
    /// The sibling precise-accuracy flag states the same rule the other way
    /// round — "only set on a DECLINE" — for the same reason: neither flag may
    /// be set merely because we intended to ask.
    static func alwaysPromptIsSpent(by status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse
    }

    /// Ask iOS to escalate When-In-Use to Always.
    ///
    /// The request itself is unconditional. What is conditional is recording
    /// the one-shot as spent, which happens HERE rather than at the call
    /// sites, which cannot know whether a dialog will appear.
    func requestAlwaysAuthorization() {
        let spendsThePrompt = Self.alwaysPromptIsSpent(by: authorizationStatus)
        locationManager.requestAlwaysAuthorization()
        if spendsThePrompt {
            UserDefaults.standard.set(true, forKey: Self.alwaysPromptAttemptedKey)
        }
    }

    var hasLocationPermission: Bool {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    var hasBackgroundPermission: Bool {
        authorizationStatus == .authorizedAlways
    }

    /// Location is granted, but iOS is coarsening every fix.
    ///
    /// Deliberately requires a live grant: with no permission at all the user
    /// has a different problem and a different prompt, and reporting reduced
    /// accuracy there would put two banners on one screen.
    var hasReducedAccuracy: Bool {
        hasLocationPermission && accuracyAuthorization == .reducedAccuracy
    }

    /// Purpose key for `requestTemporaryFullAccuracy`. MUST match a key inside
    /// `NSLocationTemporaryUsageDescriptionDictionary` in Info.plist. When it
    /// does not, iOS silently does nothing — no prompt, no error — which would
    /// leave the banner's button as dead as the state it is trying to fix.
    static let temporaryAccuracyPurposeKey = "ShareWithCircle"

    /// Set once a temporary-accuracy prompt has been shown and NOT granted.
    /// iOS suppresses a repeat prompt after a decline, so the banner switches
    /// to a Settings deep-link from then on — same escape hatch the
    /// when-in-use banner uses. A successful grant deliberately does not set
    /// it: temporary accuracy expires, and the next lapse deserves the same
    /// one-tap path rather than a trip to Settings.
    static let precisePromptAttemptedKey = "location.precisePromptAttempted"

    /// Ask iOS for full accuracy for the current session.
    ///
    /// Temporary by design: it lapses, and the permanent fix is the Precise
    /// Location switch in Settings. Worth offering anyway — it is one tap, and
    /// it restores the user to their circle's map immediately.
    func requestTemporaryFullAccuracy() {
        locationManager.requestTemporaryFullAccuracyAuthorization(
            withPurposeKey: Self.temporaryAccuracyPurposeKey
        ) { [weak self] (error: Error?) in
            guard let self = self else { return }
            // A DECLINE does not change the authorization, so
            // `locationManagerDidChangeAuthorization` never fires for it and
            // this is the only place the outcome is observable.
            self.accuracyAuthorization = self.locationManager.accuracyAuthorization
            if error != nil || self.locationManager.accuracyAuthorization == .reducedAccuracy {
                UserDefaults.standard.set(true, forKey: Self.precisePromptAttemptedKey)
                Self.writeLocationDiag("temporary full accuracy NOT granted (\(String(describing: error)))")
            } else {
                Self.writeLocationDiag("temporary full accuracy granted")
            }
        }
    }

    // MARK: - Tracking Control

    func startTracking() {
        // Never for an account not approved (yet): it has no Track to send to
        // (its token reaches the account service alone), and nothing of it is
        // tracked. The ONE predicate, here so every caller is held: sign-in, a
        // restore, a headless relaunch, a push.
        guard RegistrationGate.allowsTrack else {
            Self.writeLocationDiag("startTracking REFUSED registration=\(RegistrationGate.current.rawValue)")
            return
        }
        // Record the INTENT before the permission guard, and outside it.
        //
        // `isTracking` cannot stand in for this: it means "CLLocationManager is
        // running", and the early return below leaves it false. On a first run
        // this is called while the permission prompt is still unanswered, and
        // `locationManagerDidChangeAuthorization` acts on the grant that
        // arrives a moment later only because the intent is remembered here.
        // Without it the user would get NO location for the entire session: no
        // self marker, a silent fallback to MapLibre's stock GPS dot, and a
        // Settings screen still reporting "Status: Always".
        wantsTracking = true
        guard hasLocationPermission else {
            Self.writeLocationDiag("startTracking DEFERRED no permission (wantsTracking=true)")
            lastError = LocationError.notAuthorized
            return
        }

        // A restart re-arms everything below, so a sleeping battery-saver phone
        // is simply woken first — Battery Saver switched off lands here too,
        // through `applyTrackingSettingsChange`.
        clearSaverSleep(reason: "startTracking")

        let config: TrackingConfig = isBatterySaverActive ? .batterySaver : .highAccuracy
        applyTrackingConfig(config)
        lastBatterySaverActive = isBatterySaverActive

        locationManager.startUpdatingLocation()
        isTracking = true
        startBatteryObservation()
        armPollTimer(reason: "start", force: true)
        reconcileLivenessTimer(force: true)

        // Log the RESOLVED interval, not the raw integer. The raw read is 0 on
        // any device whose owner never touched the picker, so logging it would
        // say "interval=0s" while the poll actually runs at the fallback.
        let resolvedSendDistance = Self.resolvedSendDistanceMeters(
            stored: UserDefaults.standard.object(forKey: Self.distanceMetersKey) as? Int
        )
        Self.writeLocationDiag(
            "startTracking batterySaver=\(isBatterySaverActive) "
            + "userInterval=\(Int(resolvedUserInterval()))s "
            + "sendDistance=\(Int(resolvedSendDistance))m "
            + "liveness=\(Int(currentLivenessInterval()))s"
        )

        // The first fix of a session anchors the trail (decideSend).
        // Polls are the only source of fixes, so ask rather than wait
        // a tick.
        requestOneShotFix(reason: "start")

        // Start significant change monitoring for battery efficiency,
        // PLUS visit monitoring for low-power arrival/departure events.
        // SLC fires every ~500m of horizontal movement and is the
        // primary way iOS keeps continuous tracking alive across
        // termination; visits fire on stops/arrivals ("arrived at
        // home") and complement SLC during stationary
        // periods. Both require Always permission — `hasBackgroundPermission`
        // is exactly that gate.
        if hasBackgroundPermission {
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.startMonitoringVisits()
        }

        // Hook into the motion manager. It drives the poll cadence — see
        // applyMotionState — and buys promptness at the two edges: an immediate
        // poll when a trip starts, and a check-in look-in when the phone settles.
        Task { @MainActor in
            MotionDetectionManager.shared.start()
            observeMotionStateIfNeeded()
        }
    }

    func stopTracking() {
        // Clears the intent too, so a later authorization change doesn't
        // resurrect tracking the caller deliberately stopped. This is the
        // reason the authorization handler keys off `wantsTracking` rather
        // than simply dropping its guard.
        wantsTracking = false
        clearSaverSleep(reason: "stopTracking")
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        pollTimer?.invalidate()
        pollTimer = nil
        livenessTimer?.invalidate()
        livenessTimer = nil
        activePollRequest?.cancel()
        activePollRequest = nil
        oneShotStartedAt = nil
        stopBatteryObservation()
        isTracking = false
        consecutiveUnusablePolls = 0
        loggedReducedAccuracySkip = false
        stillProfileSince = nil
        lastPresenceConfirmedAt = nil
        // Forget the send gate's anchors. Carrying them across a logout would
        // measure the next session's first fix against wherever the phone was
        // when this one ended — so a user who signed out at home and back in at
        // work would have their first fix read as "has not moved".
        lastHistorySentLocation = nil
        lastUploadAt = nil
        // And the held position, which a check-in re-sends stamped now:
        // carried across a sign-out or a switch, the next account's first
        // check-in would put where this phone was during this session on
        // that account's circles, as current (as on Android).
        currentLocation = nil
        // And the poll's: the next session starts at the unknown cadence and
        // earns its still cadence afresh.
        pollProfile = .unknown
        motionState = .unknown
        stillInference.reset()
        Task { @MainActor in MotionDetectionManager.shared.stop() }
        motionSubscription?.cancel()
        motionSubscription = nil
    }

    /// Settings changed a tracking knob — Battery Saver, the interval or the
    /// distance picker. Re-apply to the RUNNING session.
    ///
    /// `startTracking()` runs only at sign-in, session restore and an
    /// authorization change, so without this a toggle would take effect at the
    /// next process restart and the row would be wrong until then. A session
    /// that is not running picks the values up when it starts.
    func applyTrackingSettingsChange() {
        guard isTracking else { return }
        startTracking()
    }

    /// Reattach SLC + Visit monitoring to this singleton's
    /// `CLLocationManager`. Called eagerly from
    /// `PushAppDelegate.application(_:didFinishLaunchingWithOptions:)`
    /// so the queued background-location event has somewhere to land.
    ///
    /// iOS terminates the app under memory pressure and queues
    /// significant-location and visit events while the process is
    /// dead; on relaunch (triggered by one of those events firing)
    /// we have a short grace window — roughly 10s — to rebind our
    /// delegate before the queued event is dropped. The regular
    /// `startTracking` codepath runs later via the auth flow, which
    /// is too late if iOS suspends us in between.
    ///
    /// Idempotent: SLC/Visit monitoring is process-wide on the
    /// `CLLocationManager` singleton — calling start again is a no-op
    /// when monitoring is already active. Permission-gated: noop if
    /// the user hasn't granted Always (when-in-use doesn't deliver
    /// background events).
    ///
    /// SESSION-gated too. SLC and visit registrations outlive the
    /// process, so re-arming them with nobody signed in would relaunch a
    /// signed-out user with Always granted in the background on every
    /// significant move and visit, indefinitely, for nothing: nothing can
    /// be uploaded without a session. With no session the launch TEARS
    /// those registrations down instead, which also cleans up after a
    /// logout in an earlier version.
    func wakeForBackgroundLocationDelivery() {
        // A fresh process is never asleep, so a trial region left behind by
        // the process iOS terminated is stale whatever else happens here.
        stopSaverSleepRegion()
        switch Self.storedSession() {
        case .absent:
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            Self.writeLocationDiag("launch without a session → SLC + visits stopped")
            return
        case .unknown:
            // Before the first unlock after a reboot the tokens
            // cannot be read at all. That is exactly when iOS
            // relaunches a signed-in app for an SLC event, so
            // "cannot tell" leaves the registrations in place
            // rather than tearing a signed-in user's down.
            Self.writeLocationDiag("launch before first unlock: session unknown, SLC + visits kept")
        case .present:
            break
        }
        // An account not approved (yet) tracks nothing: what another
        // account left registered goes, as with no session.
        guard RegistrationGate.allowsTrack else {
            locationManager.stopMonitoringSignificantLocationChanges()
            locationManager.stopMonitoringVisits()
            Self.writeLocationDiag("launch for an account not approved → SLC + visits stopped")
            return
        }
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        guard hasBackgroundPermission else { return }
        locationManager.startMonitoringSignificantLocationChanges()
        locationManager.startMonitoringVisits()
    }

    /// Whether anybody is signed in, from the keychain — the only session
    /// signal available this early in a background launch (the launch path
    /// gates the inactivity watch on the same keys, for the same reason).
    enum StoredSession: Equatable {
        case present
        case absent
        /// The keychain refused to answer: the tokens are
        /// `AfterFirstUnlockThisDeviceOnly`, and nothing has unlocked the
        /// phone since it booted.
        case unknown
    }

    /// `KeychainService`'s service name. `KeychainService` answers nil for
    /// "absent" and "locked" alike, which is the one distinction this needs,
    /// so the probe asks the keychain for the status itself. Pinned to the
    /// real value by `PollProfileTests`.
    static let keychainService = "com.pingolin.track"

    static func storedSession() -> StoredSession {
        let statuses = [KeychainService.Key.refreshToken, .accessToken].map { key -> OSStatus in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: key.rawValue,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            return SecItemCopyMatching(query as CFDictionary, nil)
        }
        return storedSession(fromStatuses: statuses)
    }

    /// Pure: any token found is a session; a refusal to answer is "unknown";
    /// only a keychain that answered and found nothing is "absent".
    static func storedSession(fromStatuses statuses: [OSStatus]) -> StoredSession {
        if statuses.contains(errSecSuccess) { return .present }
        if statuses.contains(errSecInteractionNotAllowed) { return .unknown }
        return .absent
    }

    /// Shape the keep-alive request. Coarse and never paused — see the polling
    /// model note above: its fixes are not positions, its job is to keep the
    /// process resident, and the system pause would suspend that process.
    private func applyTrackingConfig(_ config: TrackingConfig) {
        activeConfig = config
        locationManager.desiredAccuracy = Self.keepAliveAccuracy
        locationManager.distanceFilter = Self.keepAliveDistanceFilter
        locationManager.allowsBackgroundLocationUpdates = config.allowsBackgroundUpdates
        locationManager.pausesLocationUpdatesAutomatically = false
        // KEEP THIS TRUE: a decision, not a scaffold default.
        // With Always authorization iOS shows the blue background-location pill
        // ONLY when this is true — Apple: "This property affects only apps that
        // received Always authorization… Set this value to true to maintain
        // transparency with the user." Track has no other sign that it is
        // sharing location in the background: no Live Activity, no widget, no
        // persistent notification (Android's equivalent is its foreground-
        // service notification). So this pill is the user's only indicator that
        // Track is running, and turning it off to look lighter on battery would
        // hide exactly what the user should be able to see.
        locationManager.showsBackgroundLocationIndicator = true
    }

    /// The user's "Send on time interval", or the mode's own when they never
    /// chose one.
    private func resolvedUserInterval() -> TimeInterval {
        Self.resolvedPollIntervalSeconds(
            stored: UserDefaults.standard.object(forKey: Self.intervalSecondsKey) as? Int,
            unsetDefault: activeConfig.pollIntervalSeconds
        )
    }

    private func currentBatteryTier() -> BatteryTier {
        let thermal = ProcessInfo.processInfo.thermalState
        return BatteryTier.tier(
            levelPercent: getBatteryLevel(),
            isCharging: isCharging(),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalSerious: thermal == .serious || thermal == .critical
        )
    }

    private func currentPollInterval() -> TimeInterval {
        Self.pollInterval(
            profile: pollProfile,
            batterySaver: isBatterySaverActive,
            batteryTier: currentBatteryTier(),
            userInterval: resolvedUserInterval(),
            emergency: emergencyMode,
            backoffMultiplier: Self.pollBackoffMultiplier(consecutiveUnusable: consecutiveUnusablePolls)
        )
    }

    private func currentLivenessInterval() -> TimeInterval {
        Self.livenessInterval(
            userInterval: resolvedUserInterval(),
            batterySaver: isBatterySaverActive,
            emergency: emergencyMode
        )
    }

    /// Pick the poll profile the current evidence calls for and re-arm the poll
    /// if it changed. Android's applyPollingProfile.
    private func reevaluatePollProfile(reason: String, now: Date) {
        let desired = Self.desiredPollProfile(
            motion: motionState,
            held: stillInference.isHeld,
            anchorBrokenRecently: stillInference.brokenRecently(at: now)
        )
        guard desired != pollProfile else { return }
        pollProfile = desired
        stillProfileSince = desired == .still ? now : nil
        armPollTimer(reason: reason)
    }

    /// (Re)start the poll timer at the interval the profile, tier and Settings
    /// call for. A no-op when that interval is unchanged, so the per-fix
    /// re-evaluation costs nothing while the phone stays put. Re-decides
    /// whether the check-in needs its own clock every time, because both
    /// intervals move together.
    private func armPollTimer(reason: String, force: Bool = false) {
        guard isTracking, !isSaverSleeping else { return }
        let interval = currentPollInterval()
        if !force, let timer = pollTimer, timer.isValid, timer.timeInterval == interval {
            reconcileLivenessTimer()
            return
        }
        pollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestOneShotFix(reason: "poll")
        }
        // Let iOS coalesce this wake-up with others. A tenth of the interval is
        // Apple's suggested floor for background timers; a timer with tolerance
        // fires late, never early, so the send gate's own slack is untouched.
        timer.tolerance = interval * 0.1
        pollTimer = timer
        Self.writeLocationDiag(
            "poll every \(Int(interval))s profile=\(pollProfile) tier=\(currentBatteryTier()) "
            + "saver=\(isBatterySaverActive) emergency=\(emergencyMode) "
            + "unusable=\(consecutiveUnusablePolls) (\(reason))"
        )
        reconcileLivenessTimer()
    }

    /// The check-in clock, armed only while the poll is stretched past the
    /// check-in cadence (a mid or low battery tier while still). Then this is
    /// what keeps the phone reading as alive, from its cached fix — Android's
    /// maybeSendLivenessCheckIn. Otherwise every poll tick offers its fix to
    /// the gate, which checks in when due, and a second repeating timer would
    /// only be a wake-up of its own (`needsDedicatedLivenessTimer`).
    private func reconcileLivenessTimer(force: Bool = false) {
        let interval = currentLivenessInterval()
        guard isTracking, !isSaverSleeping,
              Self.needsDedicatedLivenessTimer(pollInterval: currentPollInterval(), livenessInterval: interval)
        else {
            if livenessTimer != nil {
                livenessTimer?.invalidate()
                livenessTimer = nil
                Self.writeLocationDiag("liveness rides the poll (no dedicated timer)")
            }
            return
        }
        if !force, let timer = livenessTimer, timer.isValid, timer.timeInterval == interval { return }
        livenessTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.requestLivenessCheckIn(reason: "liveness")
        }
        timer.tolerance = 10
        livenessTimer = timer
        Self.writeLocationDiag("liveness timer every \(Int(interval))s (poll stretched past it)")
    }

    // MARK: Battery tier

    /// Android keeps a sticky battery receiver and re-applies the polling
    /// profile whenever the tier crosses a threshold; the poll is a step
    /// function of the tier, so intra-tier changes are no-ops. Low Power Mode
    /// and the thermal state feed the same tier, so they are observed here
    /// too; their notifications arrive on arbitrary queues, hence `.main`.
    private func startBatteryObservation() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        lastBatteryTier = currentBatteryTier()
        guard batteryObservers.isEmpty else { return }
        for name in [UIDevice.batteryLevelDidChangeNotification,
                     UIDevice.batteryStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.batteryDidChange()
            }
            batteryObservers.append(token)
        }
    }

    private func stopBatteryObservation() {
        batteryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        batteryObservers.removeAll()
    }

    private func batteryDidChange() {
        let tier = currentBatteryTier()
        let saver = isBatterySaverActive
        guard tier != lastBatteryTier || saver != lastBatterySaverActive else { return }
        lastBatteryTier = tier
        lastBatterySaverActive = saver
        if isTracking {
            applyTrackingConfig(saver ? .batterySaver : .highAccuracy)
        }
        armPollTimer(
            reason: "battery tier \(tier) level=\(getBatteryLevel() ?? -1)% charging=\(isCharging()) "
                + "saver=\(saver) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled) "
                + "thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"
        )
        if saver {
            Task { @MainActor in SDKLocationStreamer.shared.enterBatterySaver() }
        }
    }

    // MARK: Emergency (SOS)

    /// An SOS this user raised is live (true) or over (false).
    ///
    /// While it is live the poll runs at the moving cadence at Best accuracy
    /// whatever the saver, tier or motion say, the check-in cadence drops to a
    /// minute, and a sleeping battery-saver phone wakes. `startTracking()` is
    /// not enough: it re-applies the NORMAL profile, so a still phone would
    /// stay at five minutes during its own emergency, and one in Battery
    /// Saver at fifteen.
    func setEmergencyMode(_ active: Bool) {
        guard emergencyMode != active else { return }
        emergencyMode = active
        Self.writeLocationDiag("emergency mode \(active ? "ON" : "OFF")")
        if active {
            exitSaverSleep(on: .emergency)
            consecutiveUnusablePolls = 0
        }
        guard isTracking else { return }
        armPollTimer(reason: active ? "emergency on" : "emergency off", force: true)
        reconcileLivenessTimer(force: true)
        if active {
            requestOneShotFix(reason: "emergency")
        }
    }

    // MARK: Poll backoff

    /// Feed one poll's outcome to the backoff: an unusable poll (a failure,
    /// or a fix too coarse to use) extends the run, an accepted fix ends it,
    /// and a stale cached fix — alive, just not moved — leaves it alone.
    private func recordPollOutcome(_ outcome: FixOutcome?, reason: String) {
        switch outcome {
        case .some(.accepted), .some(.presence), .some(.departure):
            resetPollBackoff(reason: "accepted fix")
        case .some(.rejectedAccuracy), .none:
            let before = Self.pollBackoffMultiplier(consecutiveUnusable: consecutiveUnusablePolls)
            consecutiveUnusablePolls += 1
            let after = Self.pollBackoffMultiplier(consecutiveUnusable: consecutiveUnusablePolls)
            if after != before {
                armPollTimer(reason: "backoff ×\(Int(after)) after \(consecutiveUnusablePolls) unusable polls (\(reason))")
            }
        case .some(.stale), .some(.movementHint), .some(.older):
            break
        }
    }

    private func resetPollBackoff(reason: String) {
        guard consecutiveUnusablePolls > 0 else { return }
        let wasBackedOff = Self.pollBackoffMultiplier(consecutiveUnusable: consecutiveUnusablePolls) > 1
        consecutiveUnusablePolls = 0
        if wasBackedOff {
            armPollTimer(reason: "backoff cleared (\(reason))")
        }
    }

    // MARK: Saver-sleep trial

    /// Go to sleep if the trial's conditions hold. Called after every poll and
    /// on each move of the profile, so a phone settles into it on its own.
    private func evaluateSaverSleep(now: Date = Date()) {
        guard isTracking, !isSaverSleeping else { return }
        let anchor = stillInference.anchor ?? currentLocation
        guard Self.shouldEnterSaverSleep(
            trialEnabled: Self.saverSleepTrialEnabled,
            batterySaver: isBatterySaverActive,
            alwaysAuthorized: hasBackgroundPermission,
            emergency: emergencyMode,
            appInForeground: appInForeground,
            profile: pollProfile,
            stillSince: stillProfileSince,
            hasAnchor: anchor != nil,
            regionMonitoringAvailable: CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
            now: now
        ), let anchor else { return }
        enterSaverSleep(anchor: anchor)
    }

    /// Check in once, arm the exit region, and let iOS suspend the process by
    /// stopping the timers and — after `saverSleepSettleSeconds`, so the
    /// check-in leaves first — the keep-alive request. See the trial note
    /// above `saverSleepTrialEnabled` for the trade-off this makes.
    private func enterSaverSleep(anchor: CLLocation) {
        // Last word before going quiet: the circle sees a fresh last-seen at
        // the moment the phone stops reporting.
        requestLivenessCheckIn(reason: "saver-sleep", force: true)

        let region = CLCircularRegion(
            center: anchor.coordinate,
            radius: min(
                Self.saverSleepRegionRadius(anchorAccuracy: anchor.horizontalAccuracy),
                locationManager.maximumRegionMonitoringDistance
            ),
            identifier: Self.saverSleepRegionIdentifier
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)

        isSaverSleeping = true
        pollTimer?.invalidate()
        pollTimer = nil
        livenessTimer?.invalidate()
        livenessTimer = nil
        activePollRequest?.cancel()
        activePollRequest = nil
        oneShotStartedAt = nil
        // SLC and visits stay registered; only the residency request stops —
        // after the settle window, so the check-in above gets out first.
        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.isSaverSleeping else { return }
            self.locationManager.stopUpdatingLocation()
            Self.writeLocationDiag("saver-sleep keep-alive stopped")
        }
        saverSleepKeepAliveStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saverSleepSettleSeconds, execute: stop)
        Self.writeLocationDiag(
            "saver-sleep ON radius=\(Int(region.radius))m anchorAcc=\(Int(anchor.horizontalAccuracy))"
        )
    }

    /// Wake a sleeping phone on `event`: stop the region, restart the keep-alive
    /// and the timers, and poll — unless the event is itself a request for a
    /// fix, which is already on its way.
    private func exitSaverSleep(on event: SaverSleepEvent) {
        guard isSaverSleeping, Self.saverSleepShouldWake(on: event) else { return }
        clearSaverSleep(reason: "\(event)")
        guard isTracking else { return }
        locationManager.startUpdatingLocation()
        armPollTimer(reason: "saver-sleep wake", force: true)
        reconcileLivenessTimer(force: true)
        if event != .singleLocationRequest {
            requestOneShotFix(reason: "wake")
        }
    }

    /// Forget the sleep: the flag, the region and the still clock, so a woken
    /// phone has to be still for another `saverSleepMinStillSeconds` first.
    /// Callers that restart tracking themselves use this directly.
    private func clearSaverSleep(reason: String) {
        stillProfileSince = pollProfile == .still ? Date() : nil
        guard isSaverSleeping else { return }
        isSaverSleeping = false
        saverSleepKeepAliveStop?.cancel()
        saverSleepKeepAliveStop = nil
        stopSaverSleepRegion()
        Self.writeLocationDiag("saver-sleep OFF (\(reason))")
    }

    private func stopSaverSleepRegion() {
        for region in locationManager.monitoredRegions
        where region.identifier == Self.saverSleepRegionIdentifier {
            locationManager.stopMonitoring(for: region)
        }
    }

    // MARK: Polls

    /// When the in-flight poll started, or nil. The next tick skips rather than
    /// stacking requests while Core Location is still thinking. Time-based, not
    /// a bare flag: the request has its own timeout, but if a callback is ever
    /// lost a bare flag would pin the poll dead for the rest of the session.
    private var oneShotStartedAt: Date?
    private static let oneShotStaleAfterSeconds: TimeInterval = 60

    /// Take ONE fresh fix on a poll manager and hand it to the same gate every
    /// fix goes through, so it is published on `locationUpdates` and reaches
    /// `CircleManager.syncLocation` like any other point. The receiver is on
    /// only for the duration of the request.
    ///
    /// Failures are logged, not surfaced: a timeout indoors is routine, and
    /// `lastError` drives banners.
    private func requestOneShotFix(reason: String) {
        guard isTracking, !isSaverSleeping else { return }
        // With "Precise Location" off every fix iOS hands out is kilometre-
        // scale, so a poll cannot finish early (nothing is ever usable) and
        // runs its full timeout for a fix `handleFix` then rejects — the
        // receiver on for a quarter to three quarters of every minute, for
        // nothing. Skip the poll. The keep-alive request and the banners
        // (`hasReducedAccuracy`) are untouched, and restoring precision fires
        // `locationManagerDidChangeAuthorization`, whose `startTracking()`
        // polls again at once. Android refuses to run on a coarse-only grant.
        if accuracyAuthorization == .reducedAccuracy {
            if !loggedReducedAccuracySkip {
                loggedReducedAccuracySkip = true
                Self.writeLocationDiag("\(reason): polls skipped — Precise Location is off")
            }
            // The machine-readable half, as a rejected fix sets it.
            if (lastError as? LocationError)?.isReducedAccuracy != true {
                lastError = LocationError.reducedAccuracy
            }
            // The tick is still the check-in: the newest position held,
            // for as long as the honesty guard allows, exactly as the
            // check-in timer offers it. That is the last precise fix, or
            // a coarser one a send outside the poll took since
            // (`adoptSentFix`) and already gave the circle: never the
            // older place again.
            if livenessTimer == nil {
                requestLivenessCheckIn(reason: "\(reason)/check-in")
            }
            return
        }
        loggedReducedAccuracySkip = false
        if let started = oneShotStartedAt,
           Date().timeIntervalSince(started) < Self.oneShotStaleAfterSeconds {
            Self.writeLocationDiag("\(reason): poll skipped, previous still in flight")
            return
        }
        oneShotStartedAt = Date()
        let request = FreshFixRequest(
            // An SOS asks for the best the receiver can do, battery saver or not.
            accuracy: TrackingConfig.requestedAccuracy(
                profile: pollProfile,
                config: activeConfig,
                emergency: emergencyMode
            ),
            acceptedAccuracy: TrackingConfig.acceptedAccuracy(
                profile: pollProfile,
                config: activeConfig,
                emergency: emergencyMode
            ),
            timeout: Self.pollTimeout(forInterval: currentPollInterval())
        ) { [weak self] result in
            guard let self = self else { return }
            self.activePollRequest = nil
            self.oneShotStartedAt = nil
            let outcome: FixOutcome?
            switch result {
            case .success(let fix):
                outcome = self.handleFix(fix, source: reason)
            case .failure(let error):
                outcome = nil
                Self.writeLocationDiag("\(reason): poll failed \(error.localizedDescription)")
            }
            self.recordPollOutcome(outcome, reason: reason)
            // With no dedicated check-in clock the poll tick IS the
            // check-in, so a poll that produced nothing still offers the
            // cached fix — under the same honesty guard as the check-in
            // timer. (A stale cached fix has already been offered by
            // `handleFix`.)
            if outcome != .accepted, outcome != .stale, outcome != .departure,
               self.livenessTimer == nil {
                self.requestLivenessCheckIn(reason: "\(reason)/check-in")
            }
            self.evaluateSaverSleep()
        }
        activePollRequest = request
        request.start()
    }

    /// What `handleFix` made of a fix, for the poll backoff.
    enum FixOutcome: Equatable {
        /// A position: published, and offered to the gate.
        case accepted
        /// A fresh coarse fix confirming the precise position already held.
        /// It refreshes liveness evidence, but is never published as a position.
        case presence
        /// A coarse STILL fix showed that the phone left its anchor. It drives
        /// the next profile but is never published as a position.
        case departure
        /// Too coarse to use (or of unknown accuracy).
        case rejectedAccuracy
        /// Accurate but cached: offered to the gate as proof of life only.
        case stale
        /// A keep-alive delivery — never a position, at most a reason to poll.
        case movementHint
        /// Older than the position held (a send outside the poll took a later
        /// one): nothing moves. The poll still offers its check-in, which carries
        /// the held fix.
        case older
    }

    /// Hand a fix to the send gate and publish the verdict, if any.
    ///
    /// `allowHistory: false` is for a fix whose COORDINATES are trustworthy but
    /// whose timestamp is not — the cached fix a poll hands back when the
    /// receiver could not do better, which on a stationary phone is precisely
    /// why it is stale. Such a fix must never anchor a history row or move
    /// `lastHistorySentLocation`, but it is perfectly good evidence that the
    /// phone is alive and sitting where the map already shows it.
    ///
    /// `forceCheckIn` skips the check-in cadence (never the history rule): the
    /// saver-sleep trial's last word before the phone goes quiet.
    private func routeToSendGate(
        _ location: CLLocation,
        source: String,
        allowHistory: Bool,
        forceCheckIn: Bool = false
    ) {
        let now = Date()
        let threshold = Self.resolvedSendDistanceMeters(
            stored: UserDefaults.standard.object(forKey: Self.distanceMetersKey) as? Int
        )
        let livenessInterval = forceCheckIn ? 0 : currentLivenessInterval()
        let mode = Self.decideSend(
            candidate: location,
            lastHistorySent: lastHistorySentLocation,
            distanceThresholdMeters: threshold,
            historyAllowed: allowHistory,
            lastUploadAt: lastUploadAt,
            now: now,
            livenessInterval: livenessInterval
        )
        guard let mode else {
            Self.writeLocationDiag(
                "gate src=\(source) → suppressed (not moved, within "
                + "\(Int(livenessInterval))s check-in window)"
            )
            return
        }
        if mode == .history {
            lastHistorySentLocation = location
        }
        lastUploadAt = now
        Self.writeLocationDiag("gate src=\(source) → \(mode) threshold=\(Int(threshold))m")
        locationSendRequests.send(SendRequest(location: location, mode: mode))
    }

    /// A fix or a visit older than the one held. Where the gate would have filed
    /// it in history, it goes there alone (`.pastHistory`), never as the latest
    /// position, and none of the gate's state moves for it. A check-in it might
    /// have earned would present an older position as current: the poll's own
    /// offer carries the held fix instead.
    private func routePastHistory(_ location: CLLocation, source: String) {
        guard let request = Self.pastHistoryRequest(
            for: location,
            lastHistorySent: lastHistorySentLocation,
            distanceThresholdMeters: Self.resolvedSendDistanceMeters(
                stored: UserDefaults.standard.object(forKey: Self.distanceMetersKey) as? Int
            ),
            lastUploadAt: lastUploadAt,
            now: Date()
        ) else {
            Self.writeLocationDiag("gate src=\(source)/older → nothing (no history point)")
            return
        }
        Self.writeLocationDiag("gate src=\(source)/older → pastHistory")
        locationSendRequests.send(request)
    }

    /// `routePastHistory`'s decision: a history-only request where the gate
    /// would file `location` in history, and nothing otherwise.
    static func pastHistoryRequest(
        for location: CLLocation,
        lastHistorySent: CLLocation?,
        distanceThresholdMeters: CLLocationDistance,
        lastUploadAt: Date?,
        now: Date
    ) -> SendRequest? {
        let mode = decideSend(
            candidate: location,
            lastHistorySent: lastHistorySent,
            distanceThresholdMeters: distanceThresholdMeters,
            historyAllowed: true,
            lastUploadAt: lastUploadAt,
            now: now
        )
        guard mode == .history else { return nil }
        return SendRequest(location: location, mode: .pastHistory)
    }

    /// Offer the most recent known position to the gate as a check-in candidate
    /// only. Rate-limited by the gate itself, so calling it speculatively is
    /// free — except when the cache is too old to be honest about, in which case
    /// nothing is offered and the timestamp is allowed to go stale.
    private func requestLivenessCheckIn(reason: String, force: Bool = false) {
        guard isTracking else { return }
        guard let location = currentLocation else {
            Self.writeLocationDiag("\(reason): no known position yet, nothing to check in with")
            return
        }
        let newestPresence = max(location.timestamp, lastPresenceConfirmedAt ?? .distantPast)
        let cacheAge = Date().timeIntervalSince(newestPresence)
        if Self.livenessCacheTooOld(cacheAge: cacheAge, pollInterval: currentPollInterval()) {
            Self.writeLocationDiag(
                "\(reason): check-in skipped, cached fix is \(Int(cacheAge))s old — letting the timestamp go stale rather than faking it"
            )
            return
        }
        routeToSendGate(location, source: reason, allowHistory: false, forceCheckIn: force)
    }

    @MainActor
    private func observeMotionStateIfNeeded() {
        guard motionSubscription == nil else { return }
        motionSubscription = MotionDetectionManager.shared.$motionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.applyMotionState(state)
            }
    }

    private func applyMotionState(_ state: MotionDetectionManager.MotionState) {
        guard isTracking else { return }
        // Android parity: motion drives the POLL CADENCE, never the
        // keep-alive request. Android keeps the FusedLocationProviderClient
        // subscribed continuously and only stretches its interval via
        // applyPollingProfile() (20s moving / 5min still / 30s unknown); the
        // poll profile is the same stretch, and the keep-alive stays as it is.
        motionState = state
        stillInference.reset()
        // A motion transition is new evidence: a poll that backed off after
        // failing on the platform has no reason to stay slow once the train
        // moves (or the phone is put down).
        resetPollBackoff(reason: "motion=\(state)")
        if state == .moving {
            exitSaverSleep(on: .motionMoving)
        }
        let now = Date()
        switch state {
        case .moving:
            // The cadence first, then the fix. On (any → moving) android sets
            // forceSendNextFix=true so the trip is anchored with an immediate
            // send; this poll is that.
            reevaluatePollProfile(reason: "motion=moving", now: now)
            Self.writeLocationDiag("motion=moving → immediate poll")
            requestOneShotFix(reason: "motion=moving")
        case .still:
            // Anchor where the phone settled, so a fix that later leaves
            // it — despite motion still reporting stationary — can bring
            // the moving cadence back (StillInference.brokenRecently).
            // Then the cadence.
            //
            // A stationary device's rows are suppressed, so settling is
            // exactly the moment the check-in clock starts mattering:
            // give the gate a look-in here. The gate rate-limits it, so
            // the common case — settling seconds after the history row
            // that ended the trip — is correctly nothing at all, while a
            // device that has been quiet longer than the cadence checks
            // in without waiting for its next poll tick.
            if let current = currentLocation {
                stillInference.seed(current, at: now)
            }
            reevaluatePollProfile(reason: "motion=still", now: now)
            Self.writeLocationDiag("motion=still → liveness look-in")
            requestLivenessCheckIn(reason: "motion=still")
        case .unknown:
            // No opinion from motion: denied, unavailable, or not yet confident.
            // The unknown cadence until the fixes themselves show the phone
            // holding one spot — Android's inferred STILL, fed from handleFix.
            reevaluatePollProfile(reason: "motion=unknown", now: now)
            Self.writeLocationDiag("motion=unknown → liveness look-in")
            requestLivenessCheckIn(reason: "motion=unknown")
        }
    }

    /// How hard a one-off fix should try.
    enum SingleFixPrecision {
        /// Best accuracy when a person is looking — the app is in the
        /// foreground (Send now, check-in, the foreground nudge, onboarding) or
        /// an SOS is live — and the active config's poll accuracy otherwise,
        /// which is what a background push asking for a fix gets.
        case automatic
        /// Best accuracy regardless: raising an SOS.
        case best
    }

    /// One fix, now, for a caller that needs it outside the poll: Send now, a
    /// check-in, SOS, the foreground nudge, onboarding and the wake-location
    /// push.
    ///
    /// It runs the poll's own `FreshFixRequest`: stops at the first fresh fix
    /// good enough to use, bounded by the poll timeout, at the accuracy
    /// `precision` resolves to. (`requestLocation()` at
    /// `kCLLocationAccuracyBest` would ramp towards full accuracy and "may take
    /// several seconds" whatever the fix is for — a push the SERVER sends would
    /// cost more GPS than a poll, and spend Best accuracy on a user who had
    /// chosen Battery Saver.) With Precise Location off no fix can ever
    /// improve, so the first fresh one is taken.
    @MainActor
    func requestSingleLocation(precision: SingleFixPrecision = .automatic) async throws -> CLLocation {
        guard hasLocationPermission else {
            throw LocationError.notAuthorized
        }
        // A push asking for a fix is a reason to wake a sleeping saver phone.
        exitSaverSleep(on: .singleLocationRequest)

        let wantsBest = precision == .best
            || emergencyMode
            || UIApplication.shared.applicationState == .active
        let base: TrackingConfig = wantsBest ? .highAccuracy : activeConfig
        let accepted: CLLocationAccuracy = accuracyAuthorization == .reducedAccuracy
            ? .greatestFiniteMagnitude
            : base.acceptedAccuracy
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            // Held strongly in `singleFixRequests` until it completes:
            // Core Location keeps only a weak reference to a delegate,
            // and a request released early never calls back — "Send
            // now" would hang forever with no toast.
            let request = FreshFixRequest(
                accuracy: base.pollAccuracy,
                acceptedAccuracy: accepted,
                timeout: Self.pollTimeoutSeconds
            ) { [weak self] result in
                self?.singleFixRequests[id] = nil
                continuation.resume(with: result)
            }
            singleFixRequests[id] = request
            request.start()
        }
    }

    // MARK: - An SOS raise's precise fix

    /// The precise fix an SOS raise asks for at the press: best accuracy,
    /// taken at or after `press` (within `FreshFixRequest.freshnessSlack`),
    /// and only that: never Core Location's cache, which a timed-out poll
    /// hands back. nil without permission, on a non-transient error, or when
    /// none came within `timeout`. Never awaited before the raise is sent.
    @MainActor
    func requestFreshFix(timeout: TimeInterval, after press: Date) async -> CLLocation? {
        guard hasLocationPermission else { return nil }
        exitSaverSleep(on: .singleLocationRequest)
        let base = TrackingConfig.highAccuracy
        let accepted: CLLocationAccuracy = accuracyAuthorization == .reducedAccuracy
            ? .greatestFiniteMagnitude
            : base.acceptedAccuracy
        let id = UUID()
        let fix: CLLocation? = await withCheckedContinuation { continuation in
            let request = FreshFixRequest(
                accuracy: base.pollAccuracy,
                acceptedAccuracy: accepted,
                timeout: timeout,
                freshOnly: true
            ) { [weak self] result in
                self?.singleFixRequests[id] = nil
                continuation.resume(returning: try? result.get())
            }
            singleFixRequests[id] = request
            request.start()
        }
        guard let fix, fix.horizontalAccuracy >= 0,
              fix.timestamp >= press.addingTimeInterval(-FreshFixRequest.freshnessSlack) else { return nil }
        return fix
    }

    /// Core Location's own newest fix, which the app never asks for otherwise:
    /// one of the two places an SOS raise looks for the newest held position,
    /// with `currentLocation`.
    var osCachedLocation: CLLocation? { locationManager.location }

    // MARK: - One fresh position after a refusal

    /// One fresh position for the uploads, after the server refused this
    /// device ("Device not found") and has just started taking it
    /// (`SDKLocationStreamer.deviceBecameAddressable`): the refused fix was
    /// lost, and the circle would otherwise first see this person at the next
    /// scheduled send. The send gate's cadence is skipped (it already counted
    /// the lost fix as sent); nothing else is:
    /// - It goes through the same uploads as every fix (`locationSendRequests`):
    ///   only the circles the person shares with in real time, never a paused
    ///   one, and an approximate circle gets it coarsened.
    /// - A FRESH fix only, sent as a trail point with its OWN capture time. A
    ///   fix older than the request (Core Location's cache, which a timed-out
    ///   request hands back) is not sent, nor anything when no fix comes within
    ///   the poll timeout: the schedule takes over.
    /// - Only within the accuracy limit every polled fix is held to
    ///   (`handleFix`): a request that times out hands back its roughest fresh
    ///   fix too, and with Precise Location off every fix is kilometre-scale.
    /// - Nothing while tracking isn't asked for.
    @MainActor
    @discardableResult
    func sendOneFreshFixAfterRefusal() async -> Bool {
        await sendOneFreshFix(reason: "after a refusal")
    }

    /// One fresh position for the uploads, by the rules above, for `reason`:
    /// after a refusal, or after a switch to approximate (the circle may still
    /// hold a precise fix of this person's, labelled approximate until a
    /// coarsened one replaces it).
    @MainActor
    @discardableResult
    func sendOneFreshFix(reason: String) async -> Bool {
        let sent = await Self.freshFixAfterRefusal(
            tracking: wantsTracking,
            acceptedAccuracy: activeConfig.acceptedAccuracy,
            now: Date.init,
            fix: { try await self.requestSingleLocation() },
            publish: {
                self.adoptSentFix($0.location)
                self.locationSendRequests.send($0)
            }
        )
        Self.writeLocationDiag("\(reason): \(sent ? "one fresh position sent" : "no fresh fix, left to the schedule")")
        return sent
    }

    /// `sendOneFreshFixAfterRefusal`, with what it reads handed in.
    @MainActor
    static func freshFixAfterRefusal(
        tracking: Bool,
        acceptedAccuracy: CLLocationAccuracy,
        now: () -> Date,
        fix: () async throws -> CLLocation,
        publish: (SendRequest) -> Void
    ) async -> Bool {
        guard tracking else { return false }
        let asked = now()
        guard let location = try? await fix(),
              let request = resendRequest(for: location, askedAt: asked, acceptedAccuracy: acceptedAccuracy)
        else { return false }
        publish(request)
        return true
    }

    /// A trail point for `fix` when it is fresh for a request made at
    /// `askedAt`, by the poll's own rule (`FreshFixRequest.freshnessSlack`),
    /// and within `acceptedAccuracy`, as `handleFix` requires of a polled fix;
    /// nil otherwise: a cached position is never sent as new, nor one too rough
    /// to be a position.
    static func resendRequest(for fix: CLLocation, askedAt: Date, acceptedAccuracy: CLLocationAccuracy) -> SendRequest? {
        guard fix.timestamp >= askedAt.addingTimeInterval(-FreshFixRequest.freshnessSlack) else { return nil }
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= acceptedAccuracy else { return nil }
        return SendRequest(location: fix, mode: .history)
    }

    // MARK: - Fixes taken outside the poll

    /// A fix a send outside the poll just took: the map's "Send location", the
    /// foreground nudge, a wake, a check-in, an alert, the fresh position after
    /// a refusal. It becomes `currentLocation` when it is newer by its own time
    /// (`adopts`).
    ///
    /// `requestLivenessCheckIn` re-sends `currentLocation` stamped NOW (a
    /// check-in says "alive, here"), and none of those fixes pass through
    /// `handleFix`: they come from `requestSingleLocation`'s own manager.
    /// Without this, after a send from a new place the next check-in (allowed
    /// up to `livenessCacheTooOld`, ten minutes or twice a stretched poll)
    /// would put the person back at the older place, "now", until a poll's fix
    /// replaced the cache. The Android app does the same with its service's
    /// lastKnownFix.
    @MainActor
    func adoptSentFix(_ fix: CLLocation) {
        guard Self.adopts(fix, held: currentLocation, tracking: wantsTracking, now: Date()) else { return }
        currentLocation = fix
        lastPresenceConfirmedAt = fix.timestamp
        // And to the checks that react to where this phone is, as a polled fix
        // goes: destination auto-arrival, own place alerts, the monitored-region
        // pick past 19 places, the inactivity watch. Otherwise only `handleFix`
        // and visits feed them, and an arrival whose first fix there was a
        // send-now would wait for the next poll's. All of them are local
        // (`handleFix`: "Everything on `locationUpdates` is local"); uploads
        // ride the gated stream. And only a fix that is a position by
        // `handleFix`'s own rules: a coarse or cached one-shot never stands in
        // for one there, so it cannot fake an arrival.
        guard Self.passesPositionRules(fix, acceptedAccuracy: activeConfig.acceptedAccuracy, now: Date()) else { return }
        locationUpdates.send(fix)
    }

    /// Whether `fix` is a position by `handleFix`'s rules: an accuracy within
    /// `acceptedAccuracy` (an invalid one never), and no older than
    /// `staleFixAgeLimitSeconds`.
    static func passesPositionRules(_ fix: CLLocation, acceptedAccuracy: CLLocationAccuracy, now: Date) -> Bool {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= acceptedAccuracy else { return false }
        return Int(now.timeIntervalSince(fix.timestamp)) <= staleFixAgeLimitSeconds
    }

    /// Whether a fix taken outside the poll replaces `held`: only while tracking
    /// is asked for, since a request still in flight at a sign-out lands after
    /// `stopTracking` forgot the held position and must not bring one back;
    /// and only when it is newer (`isNewer`).
    static func adopts(_ fix: CLLocation, held: CLLocation?, tracking: Bool, now: Date) -> Bool {
        guard tracking else { return false }
        return isNewer(fix, than: held, now: now)
    }

    /// Whether `fix` is newer than `held`, by their own capture times. An older
    /// one (Core Location's cache, which a timed-out request can hand back)
    /// never replaces a newer position; a held fix from the future never wins.
    static func isNewer(_ fix: CLLocation, than held: CLLocation?, now: Date) -> Bool {
        guard let held, !isFromTheFuture(held, now: now) else { return true }
        return fix.timestamp > held.timestamp
    }

    /// Whether `fix` was taken before `held`, by their own capture times; never
    /// when nothing is held, nor against a held fix from the future. The same
    /// fix again is not older.
    static func isOlder(_ fix: CLLocation, than held: CLLocation?, now: Date) -> Bool {
        guard let held, !isFromTheFuture(held, now: now) else { return false }
        return fix.timestamp < held.timestamp
    }

    /// How far past now a held fix may be stamped and still count: a few
    /// seconds of skew between Core Location and the clock is no clock change.
    static let futureFixToleranceSeconds: TimeInterval = 10

    /// A fix stamped later than now past `futureFixToleranceSeconds`: the clock
    /// was set back since it was taken. Compared by wall-clock times, every new
    /// fix would read as older than it, so the position would freeze on it, and
    /// the check-in would keep re-sending it as current until the clock caught
    /// up. Held, it wins nothing (`isNewer`, `isOlder`), and the check-in never
    /// re-sends it (`livenessCacheTooOld`).
    static func isFromTheFuture(_ fix: CLLocation, now: Date) -> Bool {
        fix.timestamp.timeIntervalSince(now) > futureFixToleranceSeconds
    }

    /// Offer a location event to `onLocationEventWhileIdle` when nothing is
    /// tracking. Delegate callbacks arrive on the main thread (the manager was
    /// created there), so the hook runs synchronously and a resume is already
    /// in place when the event itself is handled.
    private func noteLocationEventIfIdle() {
        guard !wantsTracking, let hook = onLocationEventWhileIdle else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { hook() }
        } else {
            Task { @MainActor in hook() }
        }
    }

    // MARK: - Battery Info

    func getBatteryLevel() -> Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int(level * 100)
    }

    func isCharging() -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging, .full:
            return true
        default:
            return false
        }
    }

    // MARK: - Geofencing

    /// Identifiers of every region Core Location is currently monitoring for
    /// this app. Region monitoring persists across app relaunches, so this
    /// reflects the live OS set — PlaceManager diffs its nearest-N selection
    /// against it to add/remove only what changed, rather than
    /// tearing every region down and back up on each recompute.
    ///
    /// The saver-sleep trial's own region is never included, here or in
    /// `monitoredCircularRegions`: PlaceManager's reconcile removes every
    /// monitored region it did not ask for, and would tear it down.
    var monitoredRegionIdentifiers: Set<String> {
        Set(placeRegions.map { $0.identifier })
    }

    /// Every monitored region except the saver-sleep trial's.
    private var placeRegions: [CLRegion] {
        locationManager.monitoredRegions.filter { $0.identifier != Self.saverSleepRegionIdentifier }
    }

    /// Every monitored region WITH its geometry (center + radius), for the
    /// differential reconcile in `PlaceManager.syncMonitoredRegions`: comparing
    /// an already-monitored region against the desired place lets the reconcile
    /// skip re-registering an IDENTICAL region (a CoreLocation no-op) while still
    /// re-registering one whose center/radius changed server-side (a peer/web
    /// edit moved or resized the place). Only CLCircularRegions are returned —
    /// SLC + Visit monitoring are separate subsystems — matching
    /// `monitoredRegionIdentifiers`.
    var monitoredCircularRegions: [CLCircularRegion] {
        placeRegions.compactMap { $0 as? CLCircularRegion }
    }

    func startMonitoring(region: CLCircularRegion) {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            lastError = LocationError.geofencingNotAvailable
            return
        }

        region.notifyOnEntry = true
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
    }

    func stopMonitoring(region: CLCircularRegion) {
        locationManager.stopMonitoring(for: region)
    }

    /// Every PLACE region. The saver-sleep trial's region is this service's
    /// own, and goes with the sleep (`clearSaverSleep`), not with a places
    /// rebuild — `PlaceManager.setupGeofences()` calls this on every reload.
    func stopMonitoringAll() {
        for region in placeRegions {
            locationManager.stopMonitoring(for: region)
        }
    }

    // MARK: - Errors

    enum LocationError: LocalizedError {
        case notAuthorized
        case locationUnavailable
        case geofencingNotAvailable
        case timeout
        /// "Precise Location" is off, so every fix is too coarse to share.
        case reducedAccuracy
        /// A fix was rejected on accuracy alone, with precise location ON —
        /// ordinary GPS noise, indoors or in a canyon, and it recovers.
        case inaccurate(meters: CLLocationAccuracy, limit: CLLocationAccuracy)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Location permission not granted"
            case .locationUnavailable:
                return "Unable to get current location"
            case .geofencingNotAvailable:
                return "Geofencing is not available on this device"
            case .timeout:
                return "Location request timed out"
            case .reducedAccuracy:
                return "Precise Location is off, so your position is too coarse to share"
            case .inaccurate(let meters, let limit):
                return "Location accurate to \(Int(meters))m, which is over the \(Int(limit))m limit"
            }
        }

        /// Case identity ignoring associated values — enough to tell a
        /// systemic cause (the switch is off, and stays off) from a transient
        /// one (a noisy fix, which the next one fixes) without making the
        /// whole enum Equatable over a CLLocationAccuracy that changes on
        /// every sample.
        var isReducedAccuracy: Bool {
            if case .reducedAccuracy = self { return true }
            return false
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        noteLocationEventIfIdle()
        // While the saver-sleep trial has stopped the keep-alive request, the
        // only thing that can deliver here is SLC — the phone has moved.
        exitSaverSleep(on: .significantChange)
        handleFix(location, source: "stream")
    }

    /// One gate for every fix however it arrived — a poll, the motion kick,
    /// the keep-alive request — so all of them share the accuracy and staleness
    /// rules and all of them publish the same way. Main thread: the delegate
    /// calls land there and the poll completes there, and everything below is
    /// `@Published` or the publisher.
    @discardableResult
    func handleFix(_ location: CLLocation, source: String) -> FixOutcome {
        // The keep-alive request's deliveries are movement HINTS, never
        // positions — whatever their accuracy, so this branch comes before
        // the accuracy guard. Whenever Core Location has the GPS on anyway
        // (another app navigating, one of our own polls), an accurate
        // delivery would otherwise fall through and run the whole position
        // path — the inference, `locationUpdates` and the send gate — once
        // per distance-filter step.
        if source == "stream" {
            handleKeepAliveHint(location)
            return .movementHint
        }
        // The request's profile decides how its answer is interpreted even if
        // this fix itself provides the evidence that changes the next profile.
        let profileAtRequest = pollProfile

        // Older than the fix held: a poll's fix lands seconds after its
        // capture, and a send outside the poll may have taken a later one
        // meanwhile (`adoptSentFix`). Taken anyway, the next check-in would
        // re-send the older place stamped now, and, published last, the
        // place alerts' debounce would end on it (the Android app's
        // freshFixIsNews makes the same check). Nothing moves for it. The
        // same fix again is no older: the cached fix a stationary phone's
        // poll hands back still proves it alive (the stale path below).
        guard !Self.isOlder(location, than: currentLocation, now: Date()) else {
            Self.writeLocationDiag("older than the held fix src=\(source): nothing moves")
            // Still a true past position. A fix this would have taken as one
            // goes to history alone where the gate would have filed it there.
            if Self.passesPositionRules(location, acceptedAccuracy: activeConfig.acceptedAccuracy, now: Date()) {
                routePastHistory(location, source: source)
            }
            return .older
        }

        // Filter by accuracy
        let minAccuracy = TrackingConfig.acceptedAccuracy(
            profile: profileAtRequest,
            config: activeConfig,
            emergency: emergencyMode
        )
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= minAccuracy else {
            Self.writeLocationDiag(
                "rejected src=\(source) accuracy=\(Int(location.horizontalAccuracy)) > limit=\(Int(minAccuracy))"
            )
            // Too coarse to be a position, but still evidence of stillness
            // whenever motion is not positively moving. A run of fresh fixes
            // that stay inside their own error of one spot is a phone that is
            // not going anywhere; a coarse fix outside it breaks the anchor just
            // like a precise one. Only fresh fixes count.
            if motionState != .moving, location.horizontalAccuracy >= 0,
               Date().timeIntervalSince(location.timestamp) <= 60 {
                let now = Date()
                stillInference.observe(location, at: now)
                reevaluatePollProfile(reason: "coarse fix src=\(source)", now: now)
            }
            // With "Precise Location" off, iOS coarsens every fix to
            // kilometre scale, so this guard rejects ALL of them and
            // the user vanishes from their circle's map. The
            // rejection itself is right — a fix that coarse would put
            // someone in the wrong part of town — but it must not be
            // SILENT: `writeLocationDiag` is `#if DEBUG` only, so
            // `lastError` is set as well. The banners key off
            // `hasReducedAccuracy`; this is the machine-readable half.
            let reason: LocationError = hasReducedAccuracy
                ? .reducedAccuracy
                : .inaccurate(meters: location.horizontalAccuracy, limit: minAccuracy)
            // Republish only when the KIND changes. Core Location keeps
            // delivering rejected fixes for as long as the cause lasts — every
            // poll, indefinitely while the switch is off — and each assignment
            // to an @Published churns every observing view.
            if (lastError as? LocationError)?.isReducedAccuracy != reason.isReducedAccuracy {
                lastError = reason
            }
            return .rejectedAccuracy
        }

        // Stillness evidence, BEFORE the staleness guard on purpose: a fix Core
        // Location returned from its cache because the phone has not moved is the
        // best evidence of stillness there is. While motion says moving the
        // inference is off — a trip is a trip, and it was reset on that edge.
        if motionState != .moving {
            let now = Date()
            stillInference.observe(location, at: now)
            reevaluatePollProfile(reason: "fix src=\(source)", now: now)
        }

        let ageSec = Int(Date().timeIntervalSince(location.timestamp))
        // Stale-fix guard — Android parity. The Android app's
        // handleLocationUpdate rejects fixes older than 30s so the
        // server never gets a payload tagged with an ancient timestamp.
        // A poll hands back its newest cached fix when the receiver
        // could not produce a fresh one within its timeout — without
        // this guard the marker could show "5h ago" while the streamer
        // happily sends every minute. 60s here (vs Android's 30s) gives
        // the poll a bit of slack.
        if ageSec > Self.staleFixAgeLimitSeconds {
            Self.writeLocationDiag(
                "rejected src=\(source) stale age=\(ageSec)s acc=\(Int(location.horizontalAccuracy))"
            )
            // Rejected as a POSITION REPORT, still accepted as proof of
            // life.
            //
            // This fix is stale for one overwhelmingly common reason: the
            // device has not moved, so the poll handed back the cached one
            // Core Location already had. Its coordinates are current; only
            // its timestamp is not. With stationary uploads gated it must
            // not be dropped outright: the stationary phone is exactly the
            // phone whose fixes are cached, so the gate would never see
            // anything and the phone would read as inactive while sitting
            // on a desk, fully alive.
            //
            // `allowHistory: false` keeps it out of the trail, and the
            // check-in it can earn is stamped with the current time by
            // `payloadTimestamp`, so nothing downstream ever sees this
            // fix's own stale timestamp. No stop/start "recovery" of the
            // keep-alive request: that request cannot produce a fresh GPS
            // fix by design, and the next poll is the retry.
            routeToSendGate(location, source: "\(source)/stale", allowHistory: false)
            return .stale
        }
        // A STILL poll deliberately asks for HundredMeters rather than Best.
        // A fresh 100...500 m fix proves the phone is still at the precise
        // position already held, but publishing it would drive alerts and
        // check-ins from cell/Wi-Fi error.
        if profileAtRequest == .still,
           location.horizontalAccuracy > activeConfig.acceptedAccuracy {
            guard pollProfile == .still else {
                Self.writeLocationDiag("departure src=\(source) from a coarse STILL fix")
                return .departure
            }
            lastPresenceConfirmedAt = location.timestamp
            Self.writeLocationDiag(
                "presence src=\(source) accuracy=\(Int(location.horizontalAccuracy)) "
                + "at held precise fix"
            )
            return .presence
        }
        Self.writeLocationDiag(
            "updated src=\(source) age=\(ageSec)s acc=\(Int(location.horizontalAccuracy)) "
            + "lat=\(String(format: "%.5f", location.coordinate.latitude)) "
            + "lng=\(String(format: "%.5f", location.coordinate.longitude))"
        )

        currentLocation = location
        lastPresenceConfirmedAt = location.timestamp
        locationUpdates.send(location)
        // Publish first, gate second. Everything on `locationUpdates` is local —
        // place alerts, geofences, destinations, the inactivity watch — and none
        // of it should care whether this particular fix earned a server row.
        routeToSendGate(location, source: source, allowHistory: true)
        return .accepted
    }

    /// A keep-alive delivery. Its one job is a coarse movement hint while
    /// still: far enough from where the phone settled, beyond the fix's own
    /// error, and a poll goes to check. That poll's fix decides, through the
    /// anchor rule; this one never does, and never reaches `lastError` either —
    /// the request ASKS for kilometre-scale fixes, so a coarse one is its
    /// expected shape, not a lapse to put a banner on. SLC events land here too
    /// and count.
    private func handleKeepAliveHint(_ location: CLLocation) {
        if pollProfile == .still, let anchor = stillInference.anchor {
            let away = location.distance(from: anchor)
            if Self.coarseFixSuggestsMovement(distanceFromAnchor: away, accuracy: location.horizontalAccuracy) {
                Self.writeLocationDiag(
                    "keep-alive fix \(Int(away))m from anchor acc=\(Int(location.horizontalAccuracy)) → poll"
                )
                requestOneShotFix(reason: "coarse-move")
                return
            }
        }
        Self.writeLocationDiag("keep-alive fix acc=\(Int(location.horizontalAccuracy)) ignored")
    }

    /// Per-region retry bookkeeping for `monitoringDidFailFor`. Static to match
    /// the existing delegate-state pattern; Core Location delivers delegate
    /// callbacks on the main runloop, so this is touched single-threaded
    /// alongside the rest of the delegate state.
    private static var monitoringRetryCounts: [String: Int] = [:]
    /// One retry per region: a registration can fail transiently, but a
    /// PERSISTENT failure (e.g. genuinely over the 20-region cap) must not spin.
    private static let maxMonitoringRetries = 1

    /// Append a line to Documents/send-location-diag.log (same file
    /// SDKLocationStreamer uses) so CL delivery events show up
    /// alongside the send-side events on one timeline.
    ///
    /// Debug builds only: these lines carry plaintext lat/lng, and
    /// Documents/ is backed up. In release this is a no-op so no GPS
    /// diagnostics are ever persisted to disk.
    fileprivate static func writeLocationDiag(_ message: String) {
        #if DEBUG
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent("send-location-diag.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) [cl] \(message)\n"
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: false, encoding: .utf8)
        }
        #endif
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Logged like every other Core Location event: without a diag
        // line, a heartbeat that never delivers stays invisible.
        // `locationUnknown` while indoors is routine.
        Self.writeLocationDiag("stream didFailWithError \(error.localizedDescription)")
        lastError = error
    }

    /// A monitored region failed to (re)register. Core Location silently caps an
    /// app at 20 simultaneously-monitored regions; without this delegate an
    /// over-cap registration just vanishes with NO signal at all, which is what
    /// makes silent unmonitoring so hard to catch. Log it (with the live region
    /// count) so an overflow is visible, then retry the region ONCE after a
    /// short delay to ride out a transient failure. A repeat failure is left
    /// alone after that single retry so we never spin; PlaceManager's nearest-N
    /// prioritization is what keeps the registered set under the cap.
    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let id = region?.identifier ?? "nil"
        Self.writeLocationDiag(
            "monitoringDidFailFor region=\(id) monitored=\(manager.monitoredRegions.count) error=\(error.localizedDescription)"
        )
        // The saver-sleep region is this service's own. Without it nothing
        // would notice the phone leaving, so a failure ends the sleep rather
        // than retrying through the PLACE wrapper (which would also arm it for
        // entry).
        if id == Self.saverSleepRegionIdentifier {
            exitSaverSleep(on: .regionExit(identifier: id))
            return
        }
        lastError = error
        guard let region = region as? CLCircularRegion else { return }
        let attempts = Self.monitoringRetryCounts[region.identifier, default: 0]
        guard attempts < Self.maxMonitoringRetries else {
            Self.monitoringRetryCounts[region.identifier] = nil
            return
        }
        Self.monitoringRetryCounts[region.identifier] = attempts + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            // Re-register through the wrapper so notifyOnEntry/Exit + the
            // availability guard are re-applied exactly like the first attempt.
            self?.startMonitoring(region: region)
        }
    }

    /// A region registered successfully — clear its retry bookkeeping so a
    /// later, unrelated transient failure on the same id gets a fresh retry
    /// budget instead of being written off immediately.
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        Self.monitoringRetryCounts[region.identifier] = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        // Fires for an accuracy change too, not just a grant/revoke — this is
        // how a user toggling "Precise Location" in iOS Settings reaches us.
        accuracyAuthorization = manager.accuracyAuthorization
        Self.writeLocationDiag(
            "authorization status=\(manager.authorizationStatus.rawValue) "
            + "accuracy=\(manager.accuracyAuthorization == .reducedAccuracy ? "reduced" : "full")"
        )

        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            // `wantsTracking`, NOT `isTracking`. This handler exists to act on
            // a grant, and the grant that matters most — the first one — always
            // arrives while `isTracking` is false, because the call that would
            // have set it was blocked by the very permission being granted
            // here. Keying off intent also covers the user who denies at the
            // prompt and enables the permission in iOS Settings later: the
            // status change on return to foreground lands here with the intent
            // still recorded.
            //
            // Also fires on a when-in-use → always upgrade, which re-runs
            // startTracking and picks up SLC + visit monitoring.
            if wantsTracking {
                startTracking()
            }
        }
    }

    /// CLVisit delegate. Fires on stops + departures from the
    /// system's low-power visit tracker. Each visit gets treated
    /// like a regular `didUpdateLocations` fix so the upload
    /// pipeline (CircleManager.syncLocation via `locationUpdates`)
    /// sends it to the server with the same encryption + circle
    /// scoping as a distance-triggered point. Visits land during
    /// stationary periods when SLC is silent, so they're the
    /// difference between "marker freezes at the gym all afternoon"
    /// and "marker updates as you arrive home, then again when you
    /// leave."
    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // A visit reaching a process that is not tracking may resume it first
        // (a background relaunch); only then is the guard below decided.
        noteLocationEventIfIdle()
        // Visits outlive the session (SLC too); nothing may upload without one.
        guard isTracking else { return }
        exitSaverSleep(on: .visit)
        // .distantFuture means "still here" — the visit started at
        // arrivalDate and hasn't ended yet. Otherwise it's a
        // departure and departureDate carries the timestamp.
        let stamp = visit.departureDate == .distantFuture
            ? visit.arrivalDate
            : visit.departureDate
        let location = CLLocation(
            coordinate: visit.coordinate,
            altitude: 0,
            horizontalAccuracy: visit.horizontalAccuracy,
            verticalAccuracy: -1,
            timestamp: stamp
        )
        // Older than the fix held (`handleFix`'s rule). A visit is delivered
        // late, often after newer fixes; taken anyway, a departure would move
        // the held position, the local checks and, through the gate, the
        // circle's latest back to where the phone was. A visit no older than
        // what is held (the stationary hours it exists for) goes on.
        guard !Self.isOlder(location, than: currentLocation, now: Date()) else {
            Self.writeLocationDiag("older than the held fix src=visit: nothing moves")
            // Still a true past position: to history alone, as the gate decides.
            routePastHistory(location, source: "visit")
            return
        }
        currentLocation = location
        locationUpdates.send(location)
        // This line is what keeps visits REACHING the uploader. A visit is the
        // one fix that skips `handleFix` (its timestamp is an arrival, often
        // minutes or hours old, so the staleness guard would throw it away),
        // and the uploader listens on the gated stream rather than on
        // `locationUpdates`. Without this an arrival or departure would still
        // fire place alerts and geofences locally and never reach the server at
        // all — the low-power path that covers exactly the stationary periods
        // the send gate keeps quiet.
        //
        // `allowHistory: true`: an arrival or departure is a real trail point,
        // and it keeps its own timestamp.
        routeToSendGate(location, source: "visit", allowHistory: true)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        noteLocationEventIfIdle()
        // The saver-sleep region is armed for exit only, and is never a place:
        // `PlaceManager` would buffer an unknown id as a crossing to replay.
        guard region.identifier != Self.saverSleepRegionIdentifier else { return }
        NotificationCenter.default.post(
            name: .didEnterRegion,
            object: nil,
            userInfo: ["region": region]
        )
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        noteLocationEventIfIdle()
        if region.identifier == Self.saverSleepRegionIdentifier {
            Self.writeLocationDiag("saver-sleep region exit")
            if isSaverSleeping {
                exitSaverSleep(on: .regionExit(identifier: region.identifier))
            } else {
                // Left over from a process iOS terminated while asleep.
                stopSaverSleepRegion()
            }
            return
        }
        NotificationCenter.default.post(
            name: .didExitRegion,
            object: nil,
            userInfo: ["region": region]
        )
    }
}

// MARK: - Fresh Fix Request (one poll)

/// One poll: run a manager at the requested accuracy until a FRESH fix good
/// enough to use arrives, then stop. Android's fused provider hands over one fix
/// per interval; this is that, on Core Location. `requestSingleLocation` runs
/// the same request for its one-off fixes.
///
/// Why not `requestLocation()`: it returns whatever Core Location deems
/// current, which on a stationary phone is routinely a cached fix minutes old,
/// and it offers no say over what counts. Here freshness is decided against the
/// moment the request started, and what a timed-out request hands over is
/// explicit: the newest cached fix if it is accurate (a check-in candidate), else
/// the best fresh one (`handleFix`'s accuracy rule decides), else the cached one
/// however rough, else a timeout.
///
/// `allowsBackgroundLocationUpdates` is set: this is the ONLY GPS use while the
/// app is in the background, and a manager without the flag has its updates
/// suspended there. `pausesLocationUpdatesAutomatically` is off for the reason
/// the polling model note gives. Held strongly by `LocationService` until it
/// completes — Core Location keeps only a weak reference to a delegate.
private final class FreshFixRequest: NSObject, CLLocationManagerDelegate {
    /// How much older than the request start a fix may be and still count as
    /// fresh: Core Location's first delivery is often the fix it took a moment
    /// before the request landed.
    static let freshnessSlack: TimeInterval = 2

    private let manager = CLLocationManager()
    private let acceptedAccuracy: CLLocationAccuracy
    private let timeout: TimeInterval
    /// A timeout hands back only a fresh fix (the best one), never the
    /// cache: an SOS's position after the press (`requestFreshFix`).
    private let freshOnly: Bool
    private let completion: (Result<CLLocation, Error>) -> Void
    private var startedAt = Date()
    private var bestFresh: CLLocation?
    private var newestCached: CLLocation?
    private var timeoutWork: DispatchWorkItem?
    private var finished = false

    init(
        accuracy: CLLocationAccuracy,
        acceptedAccuracy: CLLocationAccuracy,
        timeout: TimeInterval,
        freshOnly: Bool = false,
        completion: @escaping (Result<CLLocation, Error>) -> Void
    ) {
        self.acceptedAccuracy = acceptedAccuracy
        self.timeout = timeout
        self.freshOnly = freshOnly
        self.completion = completion
        super.init()
        manager.desiredAccuracy = accuracy
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.delegate = self
    }

    func start() {
        startedAt = Date()
        manager.startUpdatingLocation()
        let work = DispatchWorkItem { [weak self] in self?.timeOut() }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Tear down without reporting — for `stopTracking()`, whose caller has
    /// already forgotten this request.
    func cancel() {
        finish(nil)
    }

    private static func usable(_ fix: CLLocation, within accuracy: CLLocationAccuracy) -> Bool {
        fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= accuracy
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !finished else { return }
        for fix in locations {
            if fix.timestamp >= startedAt.addingTimeInterval(-Self.freshnessSlack) {
                if Self.usable(fix, within: acceptedAccuracy) {
                    finish(.success(fix))
                    return
                }
                // An invalid accuracy (negative) is the roughest there is.
                let quality = fix.horizontalAccuracy >= 0 ? fix.horizontalAccuracy : .greatestFiniteMagnitude
                let bestQuality = bestFresh.map {
                    $0.horizontalAccuracy >= 0 ? $0.horizontalAccuracy : .greatestFiniteMagnitude
                } ?? .greatestFiniteMagnitude
                if quality < bestQuality { bestFresh = fix }
            } else if newestCached == nil || fix.timestamp > newestCached!.timestamp {
                newestCached = fix
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard !finished else { return }
        // `locationUnknown` is transient — Core Location keeps trying, and the
        // timeout decides. Anything else (denied, restricted) ends the request.
        if let clError = error as? CLError, clError.code == .locationUnknown { return }
        finish(.failure(error))
    }

    private func timeOut() {
        guard !finished else { return }
        if freshOnly {
            finish(bestFresh.map { .success($0) } ?? .failure(LocationService.LocationError.timeout))
            return
        }
        if let cached = newestCached, Self.usable(cached, within: acceptedAccuracy) {
            finish(.success(cached))
        } else if let fresh = bestFresh {
            finish(.success(fresh))
        } else if let cached = newestCached {
            finish(.success(cached))
        } else {
            finish(.failure(LocationService.LocationError.timeout))
        }
    }

    private func finish(_ result: Result<CLLocation, Error>?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        timeoutWork = nil
        manager.stopUpdatingLocation()
        manager.delegate = nil
        if let result {
            completion(result)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let didEnterRegion = Notification.Name("didEnterRegion")
    static let didExitRegion = Notification.Name("didExitRegion")
}
